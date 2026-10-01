#!/usr/local/bin/php
<?php

/*
 * Copyright (C) 2026 os-fritzbox-failover contributors
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Helper for fritzbox_failover.sh: exposes the MVC configuration in a
 * shell-safe way and changes the gateway monitor IP through the native
 * OPNsense\Routing\Gateways model.
 *
 * usage: fritzfailover_helper.php config|curlcfg|gwinfo|setmonitor <ipv4>
 */

require_once('script/load_phalcon.php');

use OPNsense\Core\Config;
use OPNsense\FritzFailover\FritzFailover;
use OPNsense\Routing\Gateways;

function sh_quote($value)
{
    return "'" . str_replace("'", "'\\''", (string)$value) . "'";
}

function emit($key, $value)
{
    echo $key . '=' . sh_quote($value) . "\n";
}

function is_ipv4($value)
{
    return filter_var($value, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false;
}

function fail($message, $code = 1)
{
    fwrite(STDERR, $message . "\n");
    exit($code);
}

function find_gateway($name)
{
    foreach ((new Gateways())->getGateways() as $gw) {
        if (isset($gw['name']) && $gw['name'] === $name) {
            return $gw;
        }
    }
    return null;
}

function resolve_device(FritzFailover $mdl, $gw)
{
    $ifname = (string)$mdl->interface;
    if ($ifname !== '') {
        $cfg = Config::getInstance()->object();
        if (isset($cfg->interfaces->$ifname) && !empty((string)$cfg->interfaces->$ifname->if)) {
            return (string)$cfg->interfaces->$ifname->if;
        }
    }
    return $gw !== null && !empty($gw['if']) ? $gw['if'] : '';
}

function find_persisted_gateway(Gateways $gwmdl, $name)
{
    foreach ($gwmdl->gateway_item->iterateItems() as $uuid => $item) {
        if ((string)$item->name === $name) {
            return $uuid;
        }
    }
    return null;
}

$mdl = new FritzFailover();
$cmd = $argv[1] ?? '';

switch ($cmd) {
    case 'config':
        emit('FF_ENABLED', (string)$mdl->enabled);
        emit('FF_DRY_RUN', (string)$mdl->dry_run);
        emit('FF_FRITZBOX_IP', (string)$mdl->fritzbox_ip);
        emit('FF_CHECK_MODE', (string)$mdl->check_mode);
        emit('FF_TR064_PORT', (int)(string)$mdl->tr064_port);
        emit('FF_TR064_HAS_AUTH', ((string)$mdl->tr064_username !== '' && (string)$mdl->tr064_password !== '') ? '1' : '0');
        emit('FF_GATEWAY', (string)$mdl->gateway);
        emit('FF_GOOD_MONITOR', (string)$mdl->good_monitor);
        emit('FF_BAD_MONITOR', (string)$mdl->bad_monitor);
        $targets = array_filter(explode(',', (string)$mdl->probe_targets), 'is_ipv4');
        emit('FF_PROBE_TARGETS', implode(' ', $targets));
        emit('FF_PING_COUNT', (int)(string)$mdl->ping_count);
        emit('FF_PING_TIMEOUT', (int)(string)$mdl->ping_timeout);
        emit('FF_FAIL_THRESHOLD', (int)(string)$mdl->fail_threshold);
        emit('FF_RECOVER_THRESHOLD', (int)(string)$mdl->recover_threshold);
        emit('FF_CHECK_INTERVAL', (int)(string)$mdl->check_interval);
        break;

    case 'curlcfg':
        /* curl config read from stdin, keeps credentials out of argv and off disk */
        $user = (string)$mdl->tr064_username;
        $pass = (string)$mdl->tr064_password;
        if ($user === '' || $pass === '') {
            exit(0);
        }
        $cred = str_replace(['\\', '"'], ['\\\\', '\\"'], $user . ':' . $pass);
        echo 'user = "' . $cred . "\"\n";
        break;

    case 'gwinfo':
        $gw = find_gateway((string)$mdl->gateway);
        emit('GW_FOUND', $gw !== null ? '1' : '0');
        emit('GW_PERSISTED', find_persisted_gateway(new Gateways(), (string)$mdl->gateway) !== null ? '1' : '0');
        emit('GW_ADDR', $gw !== null && is_ipv4($gw['gateway'] ?? '') ? $gw['gateway'] : '');
        emit('GW_MONITOR', $gw !== null ? ($gw['monitor'] ?? '') : '');
        emit('GW_MONITOR_DISABLED', $gw !== null && !empty($gw['monitor_disable']) ? '1' : '0');
        emit('GW_DEVICE', resolve_device($mdl, $gw));
        /* default "force gw" rule sends traffic sourced from an interface address via its gateway */
        $sys = Config::getInstance()->object()->system;
        emit('GW_FORCE_GW', empty((string)$sys->pf_disable_force_gw) ? '1' : '0');
        break;

    case 'setmonitor':
        /* only the monitor IP of an existing, persisted gateway is changed, nothing is ever created */
        $ip = $argv[2] ?? '';
        if (!is_ipv4($ip)) {
            fail('invalid monitor address');
        }
        $name = (string)$mdl->gateway;
        $gwmdl = new Gateways();
        $uuid = find_persisted_gateway($gwmdl, $name);
        if ($uuid === null) {
            fail("gateway {$name} is not saved in System > Gateways, refusing to change it");
        }
        $gwmdl->createOrUpdateGateway(['monitor' => $ip], $uuid);
        Config::getInstance()->save();
        echo "ok\n";
        break;

    default:
        fail('usage: fritzfailover_helper.php config|curlcfg|gwinfo|setmonitor <ipv4>', 2);
}
