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

function fritzfailover_services()
{
    $services = [];
    $mdl = new \OPNsense\FritzFailover\FritzFailover();

    if ((string)$mdl->enabled == '1') {
        $services[] = [
            'description' => gettext('FRITZ!Box WAN Failover'),
            'configd' => [
                'start' => ['fritzfailover start'],
                'restart' => ['fritzfailover restart'],
                'stop' => ['fritzfailover stop'],
            ],
            'name' => 'fritzfailover',
            'pidfile' => '/var/run/fritzfailover.pid',
        ];
    }

    return $services;
}

/*
 * Test pings to the probe targets must always leave through the monitored
 * (cable) line. A policy rule with a gateway group (route-to) would otherwise
 * send them out through the backup line during a failover, so the cable
 * line would never be seen as healthy again. One quick outbound pass rule per
 * probe target, sourced from the cable interface address, routed to the cable
 * gateway. Nothing else is matched.
 */
function fritzfailover_firewall($fw)
{
    global $config;

    $mdl = new \OPNsense\FritzFailover\FritzFailover();
    if ((string)$mdl->enabled != '1' || (string)$mdl->fw_rules != '1') {
        return;
    }
    $gwname = (string)$mdl->gateway;
    if ($gwname === '') {
        return;
    }
    $gw = null;
    foreach ((new \OPNsense\Routing\Gateways())->getGateways() as $item) {
        if (($item['name'] ?? '') === $gwname) {
            $gw = $item;
            break;
        }
    }
    if ($gw === null || empty($gw['interface']) || ($gw['ipprotocol'] ?? 'inet') != 'inet') {
        return;
    }
    $ifname = (string)$mdl->interface !== '' ? (string)$mdl->interface : $gw['interface'];
    if (!preg_match('/^(wan|lan|opt[0-9]+)$/', $ifname)) {
        return;
    }
    foreach (explode(',', (string)$mdl->probe_targets) as $target) {
        $target = trim($target);
        if (filter_var($target, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
            continue;
        }
        $fw->registerFilterRule(
            1,
            [
                'ipprotocol'     => 'inet',
                'protocol'       => 'icmp',
                'statetype'      => 'keep',
                'type'           => 'pass',
                'disablereplyto' => 1,
                'quick'          => true,
                'direction'      => 'out',
                'from'           => $ifname . 'ip',
                'to'             => $target,
                'gateway'        => $gwname,
                'descr'          => 'FRITZ!Box failover: test ping via ' . $gwname,
                'log'            => false,
                '#ref'           => 'ui/fritzfailover',
            ]
        );
    }
}
