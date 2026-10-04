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
            'starting': ['label-info', '{{ lang._("Starting up (measuring only)") }}'],
            'test_failover': ['label-danger', '{{ lang._("TEST FAILOVER active (backup line in use)") }}'],
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
                $('#ff_dryrun').toggle(data.dry_run === true);
                const tbody = $('#ff_targets tbody').empty();
                (data.targets || []).forEach(function (t) {
                    const pct = t.sent > 0 ? (100 * t.lost / t.sent).toFixed(2) : '0.00';
                    const row = $('<tr/>');
                    row.append($('<td/>').text(t.target));
                    row.append($('<td/>').text(t.checks));
                    const lostCell = $('<td/>');
                    if (t.lost > 0) {
                        lostCell.append($('<span class="label label-warning"/>').text(t.lost + ' / ' + t.sent + ' (' + pct + ' %)'));
                    } else {
                        lostCell.text(t.lost + ' / ' + t.sent + ' (' + pct + ' %)');
                    }
                    row.append(lostCell);
                    const failCell = $('<td/>');
                    if (t.failed_checks > 0) {
                        failCell.append($('<span class="label label-danger"/>').text(t.failed_checks));
                    } else {
                        failCell.text(t.failed_checks);
                    }
                    row.append(failCell);
                    row.append($('<td/>').text(t.last_loss || '-'));
                    row.append($('<td/>').text(t.since || '-'));
                    tbody.append(row);
                });
                if (!(data.targets || []).length) {
                    tbody.append($('<tr/>').append($('<td colspan="6"/>').text('{{ lang._("No data yet. Enable the plugin and click Apply.") }}')));
                }
            });
        }

        function setupGatewayDropdown() {
            const input = $('#fritzfailover\\.gateway');
            ajaxGet('/api/fritzfailover/service/gateways', {}, function (data) {
                const gateways = (data && data.gateways) || [];
                if (!input.length || !gateways.length) {
                    return;
                }
                $('#ff_gateway_select').remove();
                const select = $('<select id="ff_gateway_select" class="form-control"/>');
                const current = input.val();
                let found = false;
                gateways.forEach(function (gw) {
                    let text = gw.name + ' (' + (gw.interface || '?') + (gw.address ? ', ' + gw.address : '') + ')';
                    if (!gw.saved) {
                        text += ' - {{ lang._("not saved yet, open it once under System > Gateways and click Save") }}';
                    }
                    const opt = $('<option/>').val(gw.name).text(text);
                    if (gw.name === current) {
                        opt.prop('selected', true);
                        found = true;
                    }
                    select.append(opt);
                });
                if (current && !found) {
                    select.prepend($('<option/>').val(current).text(current + ' - {{ lang._("not found") }}').prop('selected', true));
                }
                select.on('change', function () {
                    input.val($(this).val()).trigger('change');
                });
                input.val(select.val()).hide().after(select);
            });
        }

        mapDataToFormUI({'frm_general': '/api/fritzfailover/settings/get'}).done(function () {
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
            updateServiceControlUI('fritzfailover');
            setupGatewayDropdown();
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

        $('#testFailoverAct').click(function () {
            stdDialogConfirm(
                '{{ lang._("Test failover") }}',
                '{{ lang._("This performs a REAL failover for 2 minutes, exactly like during an outage: the monitor IP of the cable gateway is set to the fake monitor IP, OPNsense detects 100% loss and switches to the backup gateway. After 2 minutes the normal monitor IP is restored and OPNsense switches back. Connections may be interrupted briefly. Start now?") }}',
                '{{ lang._("Start test failover") }}',
                '{{ lang._("Cancel") }}',
                function () {
                    ajaxCall('/api/fritzfailover/service/testfailover', {}, function (data) {
                        BootstrapDialog.show({
                            type: (data && data.status === 'ok') ? BootstrapDialog.TYPE_INFO : BootstrapDialog.TYPE_WARNING,
                            title: '{{ lang._("Test failover") }}',
                            message: $('<div/>').text((data && data.message) || ''),
                            buttons: [{label: '{{ lang._("Close") }}', action: function (d) { d.close(); }}]
                        });
                        updateState();
                    });
                },
                'danger'
            );
        });

        $('#restoreAct').click(function () {
            stdDialogConfirm(
                '{{ lang._("Restore normal monitor IP") }}',
                '{{ lang._("Set the monitor IP of the cable gateway back to the normal monitor IP now? OPNsense then switches back to the cable line. If the monitor is running and the cable line is still dead, it will fail over again after the configured number of failed checks.") }}',
                '{{ lang._("Restore") }}',
                '{{ lang._("Cancel") }}',
                function () {
                    ajaxCall('/api/fritzfailover/service/restore', {}, function () {
                        updateState();
                    });
                },
                'warning'
            );
        });

        $('#resetStatsAct').click(function () {
            ajaxCall('/api/fritzfailover/service/resetstats', {}, function () {
                updateState();
            });
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
        <div id="ff_dryrun" class="alert alert-warning" role="alert" style="display:none; margin-top: 1em;">
            <b>{{ lang._('TEST MODE active:') }}</b>
            {{ lang._('All checks run, but nothing on OPNsense is changed. The state below shows what the plugin would do. Switch test mode off in the settings to activate the failover.') }}
        </div>
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
        <button class="btn btn-danger btn-xs" id="testFailoverAct" type="button">
            <i class="fa fa-bolt fa-fw"></i> {{ lang._('Test failover (2 minutes)') }}
        </button>
        <button class="btn btn-default btn-xs" id="restoreAct" type="button">
            <i class="fa fa-undo fa-fw"></i> {{ lang._('Restore normal monitor IP') }}
        </button>
        <h2>{{ lang._('Internet test addresses (statistics)') }}</h2>
        <p>{{ lang._('Every lost ping per test address, measured through the cable line. If an address loses pings while the others answer, that address is unreliable as monitor target (e.g. the 9.9.9.9 timeouts). A failed check means no reply at all from this address in that check.') }}</p>
        <table id="ff_targets" class="table table-condensed table-striped">
            <thead>
                <tr>
                    <th>{{ lang._('Address') }}</th>
                    <th>{{ lang._('Checks') }}</th>
                    <th>{{ lang._('Lost pings') }}</th>
                    <th>{{ lang._('Failed checks') }}</th>
                    <th>{{ lang._('Last loss') }}</th>
                    <th>{{ lang._('Measuring since') }}</th>
                </tr>
            </thead>
            <tbody></tbody>
        </table>
        <button class="btn btn-default btn-xs" id="resetStatsAct" type="button">
            <i class="fa fa-eraser fa-fw"></i> {{ lang._('Reset statistics') }}
        </button>
    </div>
</div>

<div class="content-box">
    <div class="col-md-12">
        <div class="alert alert-info" role="alert" style="margin-top: 1em;">
            {{ lang._('Quick start: 1) Create a gateway group with the cable gateway as Tier 1 and your backup (5G/LTE) gateway as Tier 2 and use it in your LAN firewall rules. 2) Set the monitor IP of the cable gateway to the FRITZ!Box address (e.g. 192.168.0.1). 3) Fill in the fields below, click "Test connection", then "Apply". The plugin never disables your gateway, it only changes its monitor IP when the cable line is really dead.') }}
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
