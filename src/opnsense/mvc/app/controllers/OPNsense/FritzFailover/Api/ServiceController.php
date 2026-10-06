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

namespace OPNsense\FritzFailover\Api;

use OPNsense\Base\ApiMutableServiceControllerBase;
use OPNsense\Core\Backend;

/**
 * Class ServiceController
 * @package OPNsense\FritzFailover\Api
 */
class ServiceController extends ApiMutableServiceControllerBase
{
    protected static $internalServiceClass = '\OPNsense\FritzFailover\FritzFailover';
    protected static $internalServiceTemplate = 'OPNsense/FritzFailover';
    protected static $internalServiceEnabled = 'enabled';
    protected static $internalServiceName = 'fritzfailover';

    /**
     * current failover state as written by the backend monitor
     * @return array
     */
    public function stateAction()
    {
        $response = trim((new Backend())->configdRun('fritzfailover state'));
        $state = json_decode($response, true);
        if (!is_array($state)) {
            return ['status' => 'unknown'];
        }
        return $state;
    }

    /**
     * restore the normal monitor IP of the cable gateway right now
     * @return array
     */
    public function restoreAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        (new Backend())->configdRun('fritzfailover restore');
        return ['status' => 'ok'];
    }

    /**
     * start a real test failover (same switch as a real failover, ends automatically)
     * @return array
     */
    public function testfailoverAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $response = trim((new Backend())->configdRun('fritzfailover testfailover'));
        $result = json_decode($response, true);
        if (!is_array($result)) {
            return ['status' => 'failed', 'message' => $response];
        }
        return $result;
    }

    /**
     * read-only check of the Cloudflare token and record
     * @return array
     */
    public function cfcheckAction()
    {
        return $this->jsonAction('fritzfailover cfcheck');
    }

    /**
     * send a Pushover test notification
     * @return array
     */
    public function pushtestAction()
    {
        return $this->jsonAction('fritzfailover pushtest');
    }

    /**
     * run a configd action returning JSON (POST only)
     * @param string $action configd action
     * @return array
     */
    private function jsonAction($action)
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $response = trim((new Backend())->configdRun($action));
        $result = json_decode($response, true);
        return is_array($result) ? $result : ['status' => 'failed', 'message' => $response];
    }

    /**
     * debug mode: start (12 hours), stop, clear (POST)
     * @param string $what start|stop|clear
     * @return array
     */
    public function debugAction($what = 'status')
    {
        if (in_array($what, ['start', 'stop', 'clear'])) {
            if (!$this->request->isPost()) {
                return ['status' => 'failed', 'message' => 'POST required'];
            }
            (new Backend())->configdRun('fritzfailover debug ' . $what);
        }
        $status = json_decode(trim((new Backend())->configdRun('fritzfailover debug status')), true);
        return is_array($status) ? $status : ['active' => false, 'until' => 0, 'size' => 0];
    }

    /**
     * debug log content for download
     * @return array
     */
    public function debuglogAction()
    {
        return ['log' => (string)(new Backend())->configdRun('fritzfailover debug log')];
    }

    /**
     * list IPv4 gateways for the gateway dropdown
     * @return array
     */
    public function gatewaysAction()
    {
        $result = json_decode(trim((new Backend())->configdRun('fritzfailover gateways')), true);
        return ['gateways' => is_array($result) ? $result : []];
    }

    /**
     * reset the per test address statistics
     * @return array
     */
    public function resetstatsAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        (new Backend())->configdRun('fritzfailover resetstats');
        return ['status' => 'ok'];
    }

    /**
     * run a single diagnostic check without changing anything
     * @return array
     */
    public function testAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $response = trim((new Backend())->configdRun('fritzfailover test'));
        $result = json_decode($response, true);
        if (!is_array($result)) {
            return ['status' => 'failed', 'message' => $response];
        }
        return $result;
    }
}
