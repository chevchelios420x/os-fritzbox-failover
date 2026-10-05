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
 * usage: fritzfailover_helper.php config|curlcfg|gwinfo|gwlist|setmonitor <ipv4>
 *        cfsync normal|failover | cfcheck | pushover <title> <message> | pushtest
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

/* HTTPS request with JSON response; credentials only live in this process */
function http_json($method, $url, $headers = [], $body = null, $form = null)
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => 10,
        CURLOPT_HTTPHEADER => $headers,
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    } elseif ($form !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($form));
    }
    $raw = curl_exec($ch);
    $err = curl_error($ch);
    curl_close($ch);
    if ($raw === false) {
        return [null, 'connection failed: ' . $err];
    }
    $data = json_decode($raw, true);
    return is_array($data) ? [$data, null] : [null, 'invalid response'];
}

function cf_call(FritzFailover $mdl, $method, $path, $body = null)
{
    list($data, $err) = http_json($method, 'https://api.cloudflare.com/client/v4' . $path, [
        'Authorization: Bearer ' . (string)$mdl->cf_token,
        'Content-Type: application/json',
    ], $body);
    if ($data === null) {
        return [null, $err];
    }
    if (empty($data['success'])) {
        $msgs = [];
        foreach ($data['errors'] ?? [] as $e) {
            $msgs[] = ($e['code'] ?? '') . ' ' . ($e['message'] ?? '');
        }
        return [null, 'Cloudflare: ' . (implode('; ', $msgs) ?: 'request failed')];
    }
    return [$data['result'] ?? null, null];
}

/* zone of the record: try wg.domain.com, domain.com, ... (needs Zone:Read) */
function cf_find_zone(FritzFailover $mdl, $record)
{
    $labels = explode('.', $record);
    for ($i = 0; count($labels) - $i >= 2; $i++) {
        $candidate = implode('.', array_slice($labels, $i));
        list($zones, $err) = cf_call($mdl, 'GET', '/zones?name=' . rawurlencode($candidate));
        if ($err !== null) {
            return [null, $err];
        }
        if (!empty($zones[0]['id'])) {
            return [$zones[0]['id'], null];
        }
    }
    return [null, "no Cloudflare zone found for {$record} (check the token's Zone Resources)"];
}

function cf_get_record(FritzFailover $mdl, $zone, $record)
{
    list($recs, $err) = cf_call($mdl, 'GET', "/zones/{$zone}/dns_records?name=" . rawurlencode($record));
    if ($err !== null) {
        return [null, $err];
    }
    return [$recs[0] ?? [], null];
}

/* IPv4 address of an interface device, e.g. vtnet5 */
function iface_ipv4($dev)
{
    if (!preg_match('/^[a-zA-Z0-9_.]+$/', (string)$dev)) {
        return '';
    }
    $out = (string)shell_exec('/sbin/ifconfig ' . escapeshellarg($dev) . ' inet 2>/dev/null');
    return preg_match('/\binet (\d+\.\d+\.\d+\.\d+)/', $out, $m) ? $m[1] : '';
}

/* device of a gateway, '' when unknown */
function gateway_device($name)
{
    $gw = $name !== '' ? find_gateway($name) : null;
    return $gw !== null && !empty($gw['if']) ? $gw['if'] : '';
}

/* dpinger status per gateway name: none (online), down, loss, delay, ... */
function gateway_states()
{
    $data = json_decode((string)shell_exec('/usr/local/opnsense/scripts/routes/gateway_status.php 2>/dev/null'), true);
    $result = [];
    foreach (is_array($data) ? $data : [] as $gw) {
        if (!empty($gw['name'])) {
            $result[$gw['name']] = $gw['status'] ?? '';
        }
    }
    return $result;
}

/* asks the configured services in order (IPv4 only, plain text answer);
 * with a source address the request leaves through that line (force gw rule) */
function public_ipv4($services, $source = '')
{
    foreach (array_filter(explode(',', $services)) as $url) {
        $ch = curl_init(trim($url));
        if ($source !== '') {
            curl_setopt($ch, CURLOPT_INTERFACE, $source);
        }
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_TIMEOUT => 6,
            CURLOPT_IPRESOLVE => CURL_IPRESOLVE_V4,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_USERAGENT => 'curl/8.0',
            CURLOPT_HTTPHEADER => ['Accept: text/plain'],
        ]);
        $raw = curl_exec($ch);
        curl_close($ch);
        $ip = is_string($raw) ? trim($raw) : '';
        if (is_ipv4($ip)) {
            return $ip;
        }
    }
    return 'unknown';
}

function out_json($status, $message, $extra = [])
{
    echo json_encode(array_merge(['status' => $status, 'message' => $message], $extra)) . "\n";
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
        emit('FF_CF_ENABLED', (string)$mdl->cf_enabled);
        emit('FF_PO_ENABLED', (string)$mdl->po_enabled);
        emit('FF_PO_FAILBACK', (string)$mdl->po_failback);
        emit('FF_PO_DELAY', (int)(string)$mdl->po_delay);
        emit('FF_SELFHEAL', (string)$mdl->selfheal_enabled);
        emit('FF_SELFHEAL_INTERVAL', (string)$mdl->selfheal_interval);
        emit('FF_SELFHEAL_HOUR', (int)(string)$mdl->selfheal_hour);
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

    case 'gwlist':
        /* IPv4 gateways for the GUI dropdown; only saved ones can be managed */
        $persisted = [];
        foreach ((new Gateways())->gateway_item->iterateItems() as $item) {
            $persisted[(string)$item->name] = true;
        }
        $list = [];
        foreach ((new Gateways())->getGateways() as $gw) {
            if (empty($gw['name']) || ($gw['ipprotocol'] ?? 'inet') !== 'inet') {
                continue;
            }
            $list[] = [
                'name' => $gw['name'],
                'interface' => $gw['if'] ?? '',
                'address' => $gw['gateway'] ?? '',
                'monitor' => $gw['monitor'] ?? '',
                'saved' => isset($persisted[$gw['name']]),
            ];
        }
        echo json_encode($list) . "\n";
        break;

    case 'gwstatus':
        /* "<cable status> <backup status>" as reported by OPNsense (dpinger) */
        $states = gateway_states();
        echo ($states[(string)$mdl->gateway] ?? 'unknown') . ' ' .
            ((string)$mdl->backup_gateway !== '' ? ($states[(string)$mdl->backup_gateway] ?? 'unknown') : '-') . "\n";
        break;

    case 'cfsync':
        /* point the CNAME to the normal or failover destination */
        $which = $argv[2] ?? '';
        $record = strtolower((string)$mdl->cf_record);
        $target = strtolower((string)($which === 'failover' ? $mdl->cf_failover_target : $mdl->cf_normal_target));
        if (!in_array($which, ['normal', 'failover']) || $record === '' || $target === '' || (string)$mdl->cf_token === '') {
            fail('Cloudflare DNS switch is not configured');
        }
        list($zone, $err) = cf_find_zone($mdl, $record);
        if ($err !== null) {
            fail($err);
        }
        list($rec, $err) = cf_get_record($mdl, $zone, $record);
        if ($err !== null) {
            fail($err);
        }
        $payload = ['type' => 'CNAME', 'name' => $record, 'content' => $target,
            'ttl' => (int)(string)$mdl->cf_ttl, 'proxied' => false];
        if (empty($rec)) {
            list(, $err) = cf_call($mdl, 'POST', "/zones/{$zone}/dns_records", $payload);
        } elseif (($rec['type'] ?? '') !== 'CNAME') {
            fail("{$record} exists as {$rec['type']} record, refusing to change it; delete it or make it a CNAME");
        } elseif (strtolower($rec['content'] ?? '') === $target && (int)($rec['ttl'] ?? 0) === $payload['ttl'] && empty($rec['proxied'])) {
            echo "{$record} already points to {$target}\n";
            exit(0);
        } else {
            list(, $err) = cf_call($mdl, 'PATCH', "/zones/{$zone}/dns_records/{$rec['id']}", $payload);
        }
        if ($err !== null) {
            fail($err);
        }
        echo "{$record} now points to {$target}\n";
        break;

    case 'cfcheck':
        /* read-only check for the GUI */
        $record = strtolower((string)$mdl->cf_record);
        if ($record === '' || (string)$mdl->cf_token === '') {
            out_json('failed', 'Please enter API token and record first and save.');
            break;
        }
        list($zone, $err) = cf_find_zone($mdl, $record);
        if ($err !== null) {
            out_json('failed', $err);
            break;
        }
        list($rec, $err) = cf_get_record($mdl, $zone, $record);
        if ($err !== null) {
            out_json('failed', $err);
        } elseif (empty($rec)) {
            out_json('ok', "Token works. {$record} does not exist yet, it will be created as CNAME on the first switch.");
        } elseif (($rec['type'] ?? '') !== 'CNAME') {
            out_json('failed', "{$record} exists as {$rec['type']} record. Delete it or change it to a CNAME, the plugin only manages CNAME records.");
        } else {
            out_json('ok', "Token works. {$record} is a CNAME pointing to {$rec['content']} (TTL {$rec['ttl']}" . (!empty($rec['proxied']) ? ', PROXIED - will be set to DNS only' : '') . ').');
        }
        break;

    case 'pushover':
    case 'pushtest':
        if ((string)$mdl->po_token === '' || (string)$mdl->po_user === '') {
            if ($cmd === 'pushtest') {
                out_json('failed', 'Please enter API token and user key first and save.');
                break;
            }
            fail('Pushover is not configured');
        }
        $title = $cmd === 'pushtest' ? 'OPNsense FRITZ!Box failover' : ($argv[2] ?? 'OPNsense FRITZ!Box failover');
        $message = $cmd === 'pushtest' ? 'Test notification: Pushover works.' : ($argv[3] ?? '');
        /* public IPv4 of the line now in use: backup line after a failover,
         * cable line after switching back (request sourced from that line) */
        $which = $argv[4] ?? '';
        $dev = $which === 'failover' ? gateway_device((string)$mdl->backup_gateway)
            : ($which === 'failback' ? gateway_device((string)$mdl->gateway) : '');
        $src = $dev !== '' ? iface_ipv4($dev) : '';
        $pubip = public_ipv4((string)$mdl->pubip_services, $src);
        if ($which === 'failover' && $src !== '') {
            $pubip .= ' (backup line)';
        } elseif ($which === 'failback' && $src !== '') {
            $pubip .= ' (cable line)';
        }
        $message .= "\nPublic IP: {$pubip}";
        list($data, $err) = http_json('POST', 'https://api.pushover.net/1/messages.json', [], null, [
            'token' => (string)$mdl->po_token,
            'user' => (string)$mdl->po_user,
            'title' => $title,
            'message' => $message,
        ]);
        $ok = $data !== null && (int)($data['status'] ?? 0) === 1;
        $msg = $ok ? 'Notification sent.' : ($err ?? implode('; ', $data['errors'] ?? ['request failed']));
        if ($cmd === 'pushtest') {
            out_json($ok ? 'ok' : 'failed', $msg);
        } elseif (!$ok) {
            fail('Pushover: ' . $msg);
        }
        break;

    case 'setmonitor':
        /* only the monitor IP of an existing, persisted gateway is changed, nothing is ever created */
        $ip = $argv[2] ?? '';
        if (!is_ipv4($ip)) {
            fail('invalid monitor address');
        }
        $name = (string)$mdl->gateway;
        /* exclusive config lock and fresh reload, like the core API controllers, so a
         * concurrent save from the GUI cannot be overwritten; save() releases the lock */
        Config::getInstance()->lock();
        $gwmdl = new Gateways();
        $uuid = find_persisted_gateway($gwmdl, $name);
        if ($uuid === null) {
            Config::getInstance()->unlock();
            fail("gateway {$name} is not saved in System > Gateways, refusing to change it");
        }
        $gwmdl->createOrUpdateGateway(['monitor' => $ip], $uuid);
        /* no history backup: frequent switching must not push real backups out of the history */
        Config::getInstance()->save(null, false);
        Config::getInstance()->unlock();
        echo "ok\n";
        break;

    default:
        fail('usage: fritzfailover_helper.php config|curlcfg|gwinfo|gwlist|setmonitor <ipv4>', 2);
}
