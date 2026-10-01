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

namespace OPNsense\FritzFailover;

use OPNsense\Base\BaseModel;
use OPNsense\Base\Messages\Message;

/**
 * Class FritzFailover
 * @package OPNsense\FritzFailover
 */
class FritzFailover extends BaseModel
{
    /**
     * {@inheritdoc}
     */
    public function performValidation($validateFullModel = false)
    {
        $messages = parent::performValidation($validateFullModel);

        if ((string)$this->good_monitor === (string)$this->bad_monitor) {
            $messages->appendMessage(new Message(
                gettext('The normal and the fake monitor IP must be different.'),
                'bad_monitor'
            ));
        }

        if ((string)$this->bad_monitor === (string)$this->fritzbox_ip) {
            $messages->appendMessage(new Message(
                gettext('The fake monitor IP must not be the FRITZ!Box address, it has to be unreachable.'),
                'bad_monitor'
            ));
        }

        $period = (int)(string)$this->ping_count * (int)(string)$this->ping_timeout;
        if ($period >= (int)(string)$this->check_interval) {
            $messages->appendMessage(new Message(
                gettext('Ping count multiplied by ping timeout must be lower than the check interval.'),
                'check_interval'
            ));
        }

        if ((string)$this->enabled === '1' && (string)$this->tr064_enabled === '1') {
            if ((string)$this->tr064_username === '' || (string)$this->tr064_password === '') {
                $messages->appendMessage(new Message(
                    gettext('Please enter the TR-064 username and password or disable the FRITZ!Box status query.'),
                    'tr064_username'
                ));
            }
        }

        return $messages;
    }
}
