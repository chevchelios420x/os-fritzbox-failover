{#
Copyright (C) 2026 os-fritzbox-failover contributors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

#}

<script>
    $(document).ready(function () {
        const stateLabels = {
            'ok': ['label-success', '{{ lang._("Cable line OK") }}'],
            'degraded': ['label-warning', '{{ lang._("Cable line unstable, counting failures") }}'],
            'failover': ['label-danger', '{{ lang._("Failover active (backup line in use)") }}'],
            'recovering': ['label-info', '{{ lang._("Cable line back, waiting before switching back") }}'],
            'stopped': ['label-default', '{{ lang._("Monitor not running") }}'],
            'unknown': ['label-default', '{{ lang._("Unknown") }}']
        };

        function updateState() {
            ajaxGet('/api/fritzfailover/service/state', {}, function (data) {
                const state = (data && data.status && stateLabels[data.status]) ? data.status : 'unknown';
                $('#ff_state').attr('class', 'label ' + stateLabels[state][0]).text(stateLabels[state][1]);
                $('#ff_tr064').text(data.tr064 || '-');
                $('#ff_ping').text(data.ping || '-');
                $('#ff_monitor').text(data.monitor || '-');
                $('#ff_counters').text((data.failures !== undefined ? data.failures : '-') + ' / ' + (data.successes !== undefined ? data.successes : '-'));
                $('#ff_last').text(data.last_check || '-');
                $('#ff_message').text(data.message || '');
            });
        }

        mapDataToFormUI({'frm_general': '/api/fritzfailover/settings/get'}).done(function () {
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
            updateServiceControlUI('fritzfailover');
        });

        $('#reconfigureAct').SimpleActionButton({
            onPreAction: function () {
                const dfObj = $.Deferred();
                saveFormToEndpoint('/api/fritzfailover/settings/set', 'frm_general', function () {
                    dfObj.resolve();
                }, true, function () {
                    dfObj.reject();
                });
                return dfObj;
            },
            onAction: function () {
                updateServiceControlUI('fritzfailover');
                setTimeout(updateState, 2000);
            }
        });

        $('#testAct').click(function () {
            const btn = $(this);
            btn.prop('disabled', true).find('i').removeClass('fa-stethoscope').addClass('fa-spinner fa-pulse');
            saveFormToEndpoint('/api/fritzfailover/settings/set', 'frm_general', function () {
                ajaxCall('/api/fritzfailover/service/test', {}, function (data) {
                    btn.prop('disabled', false).find('i').removeClass('fa-spinner fa-pulse').addClass('fa-stethoscope');
                    const ok = data && data.status === 'ok';
                    BootstrapDialog.show({
                        type: ok ? BootstrapDialog.TYPE_SUCCESS : BootstrapDialog.TYPE_WARNING,
                        title: '{{ lang._("Connection test") }}',
                        message: $('<pre/>').text(
                            '{{ lang._("FRITZ!Box (TR-064)") }}: ' + (data.tr064 || '-') + '\n' +
                            '{{ lang._("Test ping via cable") }}: ' + (data.ping || '-') + '\n' +
                            '{{ lang._("Gateway") }}: ' + (data.gateway || '-') + '\n' +
                            '{{ lang._("Interface") }}: ' + (data.device || '-') + '\n' +
                            '{{ lang._("Current monitor IP") }}: ' + (data.monitor || '-') + '\n\n' +
                            (data.message || '')
                        ),
                        buttons: [{label: '{{ lang._("Close") }}', action: function (d) { d.close(); }}]
                    });
                });
            }, true, function () {
                btn.prop('disabled', false).find('i').removeClass('fa-spinner fa-pulse').addClass('fa-stethoscope');
            });
        });

        updateState();
        setInterval(updateState, 5000);
    });
</script>

<div class="content-box" style="padding-bottom: 1.5em;">
    <div class="col-md-12">
        <h2>{{ lang._('Status') }}</h2>
        <table class="table table-condensed">
            <tbody>
                <tr><td style="width:22%">{{ lang._('State') }}</td><td><span id="ff_state" class="label label-default">-</span></td></tr>
                <tr><td>{{ lang._('FRITZ!Box line status') }}</td><td id="ff_tr064">-</td></tr>
                <tr><td>{{ lang._('Test ping via cable') }}</td><td id="ff_ping">-</td></tr>
                <tr><td>{{ lang._('Active monitor IP') }}</td><td id="ff_monitor">-</td></tr>
                <tr><td>{{ lang._('Failures / successes in a row') }}</td><td id="ff_counters">-</td></tr>
                <tr><td>{{ lang._('Last check') }}</td><td id="ff_last">-</td></tr>
                <tr><td>{{ lang._('Info') }}</td><td id="ff_message"></td></tr>
            </tbody>
        </table>
    </div>
</div>

<div class="content-box">
    <div class="col-md-12">
        <div class="alert alert-info" role="alert" style="margin-top: 1em;">
            {{ lang._('Quick start: 1) Create a gateway group with the cable gateway as Tier 1 and your backup (5G/LTE) gateway as Tier 2 and use it in your LAN firewall rules. 2) Fill in the fields below. 3) Click "Test connection", then "Apply". The plugin never disables your gateway, it only changes its monitor IP.') }}
        </div>
    </div>
    {{ partial("layout_partials/base_form", ['fields': generalForm, 'id': 'frm_general']) }}
</div>

<section class="page-content-main">
    <div class="content-box">
        <div class="col-md-12">
            <br/>
            <button class="btn btn-primary" id="reconfigureAct"
                    data-endpoint="/api/fritzfailover/service/reconfigure"
                    data-label="{{ lang._('Apply') }}"
                    data-error-title="{{ lang._('Error applying FRITZ!Box failover settings') }}"
                    type="button"></button>
            <button class="btn btn-default" id="testAct" type="button">
                <i class="fa fa-stethoscope fa-fw"></i> {{ lang._('Test connection') }}
            </button>
            <br/><br/>
        </div>
    </div>
</section>
