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

        const eventLabels = {
            'failover': ['label-danger', '{{ lang._("Switched to backup") }}'],
            'failback': ['label-success', '{{ lang._("Switched back to cable") }}'],
            'test_start': ['label-warning', '{{ lang._("Test failover started") }}'],
            'test_end': ['label-info', '{{ lang._("Test failover finished") }}'],
            'restore': ['label-info', '{{ lang._("Normal monitor IP restored") }}'],
            'sim_failover': ['label-default', '{{ lang._("TEST MODE: would switch to backup") }}'],
            'sim_failback': ['label-default', '{{ lang._("TEST MODE: would switch back") }}'],
            'dns': ['label-primary', '{{ lang._("Cloudflare DNS updated") }}']
        };
        let backupSince = 0;

        function fmtTime(epoch) {
            const d = new Date(epoch * 1000);
            const p = function (n) { return ('0' + n).slice(-2); };
            return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
        }

        function fmtDuration(sec) {
            sec = Math.max(0, Math.floor(sec));
            const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
            return (d > 0 ? d + 'd ' : '') + ('0' + h).slice(-2) + ':' + ('0' + m).slice(-2) + ':' + ('0' + s).slice(-2);
        }

        function renderBackupSince() {
            if (backupSince) {
                $('#ff_backup_since').text(fmtTime(backupSince) + ' ({{ lang._("for") }} ' + fmtDuration(Date.now() / 1000 - backupSince) + ')');
            } else {
                $('#ff_backup_since').text('{{ lang._("not active") }}');
            }
        }
        setInterval(renderBackupSince, 1000);

        function renderEvents(data) {
            const events = data.events || [];
            const toBackup = data.dry_run ? ['failover', 'test_start', 'sim_failover'] : ['failover', 'test_start'];
            const last = events.find(function (e) { return toBackup.indexOf(e.kind) >= 0; });
            $('#ff_last_switch').text(last ? fmtTime(last.time) + ' - ' + (eventLabels[last.kind] || ['', last.kind])[1] : '{{ lang._("never") }}');
            const onBackup = ['failover', 'recovering', 'test_failover'].indexOf(data.status) >= 0;
            backupSince = (onBackup && last) ? last.time : 0;
            renderBackupSince();
            const tbody = $('#ff_events tbody').empty();
            events.forEach(function (e) {
                const lbl = eventLabels[e.kind] || ['label-default', e.kind];
                tbody.append($('<tr/>')
                    .append($('<td style="white-space:nowrap"/>').text(fmtTime(e.time)))
                    .append($('<td/>').append($('<span class="label"/>').addClass(lbl[0]).text(lbl[1])))
                    .append($('<td/>').text(e.detail || '')));
            });
            if (!events.length) {
                tbody.append($('<tr/>').append($('<td colspan="3"/>').text('{{ lang._("No switches recorded yet.") }}')));
            }
        }

        let testEnd = 0;
        let testTotal = 0;

        function renderCountdown() {
            if (!testEnd) {
                return;
            }
            const left = Math.max(0, Math.round((testEnd - Date.now()) / 1000));
            const pct = testTotal > 0 ? Math.round(100 * left / testTotal) : 0;
            $('#ff_countdown_bar').css('width', pct + '%').attr('aria-valuenow', pct);
            $('#ff_countdown_text').text(left > 0
                ? '{{ lang._("Switching back to the cable line in") }} ' + Math.floor(left / 60) + ':' + ('0' + (left % 60)).slice(-2)
                : '{{ lang._("Switching back now ...") }}');
        }
        setInterval(renderCountdown, 1000);

        function updateState() {
            ajaxGet('/api/fritzfailover/service/state', {}, function (data) {
                const state = (data && data.status && stateLabels[data.status]) ? data.status : 'unknown';
                $('#ff_state').attr('class', 'label ' + stateLabels[state][0]).text(stateLabels[state][1]);
                $('#ff_tr064').text(data.tr064 || '-');
                $('#ff_ping').text(data.ping || '-');
                $('#ff_monitor').text(data.monitor || '-');
                $('#ff_counters').text((data.failures !== undefined ? data.failures : '-') + ' / ' + (data.successes !== undefined ? data.successes : '-'));
                $('#ff_last').text(data.last_check || '-');
                // watchdog: warn when the monitor runs but has not checked for a while
                const age = data.last_check_epoch ? Math.round(Date.now() / 1000 - data.last_check_epoch) : 0;
                const limit = 3 * (data.interval || 10) + 60;
                if (state !== 'stopped' && data.last_check_epoch && age > limit) {
                    $('#ff_stale').text('{{ lang._("Warning: no check for") }} ' + age + ' {{ lang._("seconds. The monitor may hang, see System > Log Files > General (fritzfailover) or restart the service.") }}').show();
                } else {
                    $('#ff_stale').hide();
                }
                $('#ff_message').text(data.message || '');
                renderEvents(data || {});
                $('#ff_selfheal').text(data.last_selfheal ? fmtTime(data.last_selfheal) : '{{ lang._("not yet") }}');
                if (state === 'test_failover' && data.test_total) {
                    testEnd = Date.now() + (data.test_left || 0) * 1000;
                    testTotal = data.test_total;
                    renderCountdown();
                    $('#ff_countdown').show();
                } else {
                    testEnd = 0;
                    $('#ff_countdown').hide();
                }
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

        function gatewayDropdown(fieldId, gateways, allowEmpty) {
            const input = $('#fritzfailover\\.' + fieldId);
            if (!input.length || !gateways.length) {
                return;
            }
            const selectId = 'ff_select_' + fieldId;
            $('#' + selectId).remove();
            const select = $('<select class="form-control"/>').attr('id', selectId);
            const current = input.val();
            let found = !current && allowEmpty;
            if (allowEmpty) {
                select.append($('<option/>').val('').text('{{ lang._("(none)") }}'));
            }
            gateways.forEach(function (gw) {
                let text = gw.name + ' (' + (gw.interface || '?') + (gw.address ? ', ' + gw.address : '') + ')';
                if (!gw.saved && !allowEmpty) {
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
        }

        function setupGatewayDropdown() {
            ajaxGet('/api/fritzfailover/service/gateways', {}, function (data) {
                const gateways = (data && data.gateways) || [];
                gatewayDropdown('gateway', gateways, false);
                gatewayDropdown('backup_gateway', gateways, true);
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

        function renderDebug(d) {
            d = d || {};
            const kb = Math.round((d.size || 0) / 1024);
            if (d.active) {
                $('#ff_debug_state').attr('class', 'label label-warning').text('{{ lang._("active until") }} ' + fmtTime(d.until));
            } else {
                $('#ff_debug_state').attr('class', 'label label-default').text('{{ lang._("off") }}');
            }
            $('#ff_debug_size').text(kb + ' KB');
            $('#debugStartAct').toggle(!d.active);
            $('#debugStopAct').toggle(!!d.active);
            if (d.scheduled) {
                $('#ff_debug_sched').text('{{ lang._("starts at") }} ' + fmtTime(d.scheduled) + ' {{ lang._("(runs 12 hours)") }}');
                $('#debugUnscheduleAct').show();
            } else {
                $('#ff_debug_sched').text('');
                $('#debugUnscheduleAct').hide();
            }
            if (d.active) {
                $('#ff_debug_badge').text('{{ lang._("active") }}').show();
            } else if (d.scheduled) {
                $('#ff_debug_badge').text('{{ lang._("scheduled") }} ' + fmtTime(d.scheduled)).show();
            } else {
                $('#ff_debug_badge').hide();
            }
        }
        function debugCall(what) {
            ajaxCall('/api/fritzfailover/service/debug/' + what, {}, renderDebug);
        }
        $('#debugStartAct').click(function () { debugCall('start'); });
        $('#debugStopAct').click(function () { debugCall('stop'); });
        $('#debugClearAct').click(function () {
            stdDialogConfirm('{{ lang._("Debug log") }}', '{{ lang._("Delete the recorded debug log?") }}',
                '{{ lang._("Delete") }}', '{{ lang._("Cancel") }}', function () { debugCall('clear'); }, 'warning');
        });
        $('#debugDownloadAct').click(function () {
            ajaxGet('/api/fritzfailover/service/debuglog', {}, function (data) {
                const blob = new Blob([(data && data.log) || ''], {type: 'text/plain'});
                const a = document.createElement('a');
                const d = new Date();
                const p = function (n) { return ('0' + n).slice(-2); };
                a.href = URL.createObjectURL(blob);
                a.download = 'fritzfailover-debug-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes()) + '.log';
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(a.href);
            });
        });
        $('.ff-toggle').click(function () {
            const target = $($(this).data('target'));
            target.toggle();
            $(this).find('i').first().toggleClass('fa-chevron-down', target.is(':visible')).toggleClass('fa-chevron-right', !target.is(':visible'));
        });
        $('#debugScheduleAct').click(function () {
            const val = $('#ff_debug_at').val();
            const ts = val ? Math.floor(new Date(val).getTime() / 1000) : 0;
            if (!ts || ts <= Date.now() / 1000) {
                BootstrapDialog.show({type: BootstrapDialog.TYPE_WARNING, title: '{{ lang._("Debug mode") }}',
                    message: '{{ lang._("Please choose a date and time in the future.") }}'});
                return;
            }
            ajaxCall('/api/fritzfailover/service/debug/schedule/' + ts, {}, renderDebug);
        });
        $('#debugUnscheduleAct').click(function () { debugCall('unschedule'); });

        function refreshDebug() { ajaxGet('/api/fritzfailover/service/debug/status', {}, renderDebug); }
        refreshDebug();
        setInterval(refreshDebug, 30000);

        $('#resetStatsAct').click(function () {
            ajaxCall('/api/fritzfailover/service/resetstats', {}, function () {
                updateState();
            });
        });

        function saveAndCall(btn, endpoint, title) {
            const icon = btn.find('i');
            const orig = icon.attr('class');
            btn.prop('disabled', true);
            icon.attr('class', 'fa fa-spinner fa-pulse fa-fw');
            const done = function () { btn.prop('disabled', false); icon.attr('class', orig); };
            saveFormToEndpoint('/api/fritzfailover/settings/set', 'frm_general', function () {
                ajaxCall(endpoint, {}, function (data) {
                    done();
                    BootstrapDialog.show({
                        type: (data && data.status === 'ok') ? BootstrapDialog.TYPE_SUCCESS : BootstrapDialog.TYPE_WARNING,
                        title: title,
                        message: $('<div/>').text((data && data.message) || '{{ lang._("No answer") }}'),
                        buttons: [{label: '{{ lang._("Close") }}', action: function (d) { d.close(); }}]
                    });
                });
            }, true, done);
        }
        $('#cfCheckAct').click(function () { saveAndCall($(this), '/api/fritzfailover/service/cfcheck', '{{ lang._("Cloudflare check") }}'); });
        $('#pushTestAct').click(function () { saveAndCall($(this), '/api/fritzfailover/service/pushtest', '{{ lang._("Pushover test") }}'); });

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
        setInterval(updateState, 3000);
    });
</script>

<div class="content-box" style="padding-bottom: 1.5em;">
    <div class="col-md-12">
        <div class="pull-right" style="margin-top: 1em;">
            <a href="{{ pluginWebsite }}" target="_blank" rel="noopener noreferrer" title="{{ lang._('Project page and releases on GitHub') }}">
                <i class="fa fa-github fa-fw"></i> os-fritzbox-failover {{ pluginVersion }}
            </a>
        </div>
        <div id="ff_dryrun" class="alert alert-warning" role="alert" style="display:none; margin-top: 1em;">
            <b>{{ lang._('TEST MODE active:') }}</b>
            {{ lang._('All checks run, but nothing on OPNsense is changed. The state below shows what the plugin would do. Switch test mode off in the settings to activate the failover.') }}
        </div>
        <h2>{{ lang._('Status') }}</h2>
        <div id="ff_stale" class="alert alert-danger" role="alert" style="display:none;"></div>
        <table class="table table-condensed">
            <tbody>
                <tr><td style="width:22%">{{ lang._('State') }}</td><td><span id="ff_state" class="label label-default">-</span></td></tr>
                <tr><td>{{ lang._('FRITZ!Box line status') }}</td><td id="ff_tr064">-</td></tr>
                <tr><td>{{ lang._('Test ping via cable') }}</td><td id="ff_ping">-</td></tr>
                <tr><td>{{ lang._('Active monitor IP') }}</td><td id="ff_monitor">-</td></tr>
                <tr><td>{{ lang._('Failures / successes in a row') }}</td><td id="ff_counters">-</td></tr>
                <tr><td>{{ lang._('Last check') }}</td><td id="ff_last">-</td></tr>
                <tr><td>{{ lang._('Last switch to backup') }}</td><td id="ff_last_switch">-</td></tr>
                <tr><td>{{ lang._('Backup active since') }}</td><td id="ff_backup_since">-</td></tr>
                <tr><td>{{ lang._('Last self-healing restart') }}</td><td id="ff_selfheal">-</td></tr>
                <tr><td>{{ lang._('Info') }}</td><td id="ff_message"></td></tr>
            </tbody>
        </table>
        <div id="ff_countdown" style="display:none; margin: 0.5em 0 1em 0;">
            <div><b>{{ lang._('Test failover') }}:</b> <span id="ff_countdown_text"></span></div>
            <div class="progress" style="margin: 0.3em 0 0 0;">
                <div id="ff_countdown_bar" class="progress-bar progress-bar-danger progress-bar-striped active" role="progressbar"
                     aria-valuemin="0" aria-valuemax="100" aria-valuenow="100" style="width: 100%;"></div>
            </div>
        </div>
        <button class="btn btn-danger btn-xs" id="testFailoverAct" type="button">
            <i class="fa fa-bolt fa-fw"></i> {{ lang._('Test failover (2 minutes)') }}
        </button>
        <button class="btn btn-default btn-xs" id="restoreAct" type="button">
            <i class="fa fa-undo fa-fw"></i> {{ lang._('Restore normal monitor IP') }}
        </button>
        <h2 class="ff-toggle" data-target="#ff_sec_history" style="cursor:pointer; user-select:none;">
            <i class="fa fa-fw fa-chevron-down"></i> {{ lang._('Switch history') }}
        </h2>
        <div id="ff_sec_history" class="ff-section">
        <table id="ff_events" class="table table-condensed table-striped">
            <thead>
                <tr>
                    <th>{{ lang._('Time') }}</th>
                    <th>{{ lang._('Event') }}</th>
                    <th>{{ lang._('Details') }}</th>
                </tr>
            </thead>
            <tbody></tbody>
        </table>
        </div>
        <h2 class="ff-toggle" data-target="#ff_sec_stats" style="cursor:pointer; user-select:none;">
            <i class="fa fa-fw fa-chevron-down"></i> {{ lang._('Internet test addresses (statistics)') }}
        </h2>
        <div id="ff_sec_stats" class="ff-section">
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
        <h2 class="ff-toggle" data-target="#ff_sec_debug" style="cursor:pointer; user-select:none;">
            <i class="fa fa-fw fa-chevron-right"></i> {{ lang._('Debug mode') }} <span id="ff_debug_badge" class="label label-warning" style="display:none; font-size:60%; vertical-align:middle;"></span>
        </h2>
        <div id="ff_sec_debug" class="ff-section" style="display:none;">
        <p>{{ lang._('Records one detailed line per check: plugin decision, raw FRITZ!Box values (connection status, last error, physical link), every test ping, how OPNsense sees both gateways and the default route of the firewall. Lines in which something relevant changed start with *. Use it e.g. while a technician works on the line, then download the log. Switches itself off after 12 hours. Daily self-healing deletes the log, except while debug mode is running.') }}</p>
        <table class="table table-condensed">
            <tbody>
                <tr><td style="width:22%">{{ lang._('State') }}</td><td><span id="ff_debug_state" class="label label-default">-</span></td></tr>
                <tr><td>{{ lang._('Log size') }}</td><td id="ff_debug_size">-</td></tr>
                <tr><td>{{ lang._('Scheduled start') }}</td><td>
                    <input type="datetime-local" id="ff_debug_at" class="form-control" style="display:inline-block; width:auto;"/>
                    <button class="btn btn-default btn-xs" id="debugScheduleAct" type="button"><i class="fa fa-clock-o fa-fw"></i> {{ lang._('Schedule') }}</button>
                    <button class="btn btn-default btn-xs" id="debugUnscheduleAct" type="button" style="display:none"><i class="fa fa-times fa-fw"></i> {{ lang._('Cancel schedule') }}</button>
                    <span id="ff_debug_sched"></span>
                </td></tr>
            </tbody>
        </table>
        <button class="btn btn-warning btn-xs" id="debugStartAct" type="button"><i class="fa fa-bug fa-fw"></i> {{ lang._('Start debug mode (12 hours)') }}</button>
        <button class="btn btn-default btn-xs" id="debugStopAct" type="button" style="display:none"><i class="fa fa-stop fa-fw"></i> {{ lang._('Stop debug mode') }}</button>
        <button class="btn btn-default btn-xs" id="debugDownloadAct" type="button"><i class="fa fa-download fa-fw"></i> {{ lang._('Download debug log') }}</button>
        <button class="btn btn-default btn-xs" id="debugClearAct" type="button"><i class="fa fa-trash fa-fw"></i> {{ lang._('Delete debug log') }}</button>
        </div>
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
            <button class="btn btn-default" id="cfCheckAct" type="button">
                <i class="fa fa-cloud fa-fw"></i> {{ lang._('Check Cloudflare') }}
            </button>
            <button class="btn btn-default" id="pushTestAct" type="button">
                <i class="fa fa-bell fa-fw"></i> {{ lang._('Send test push') }}
            </button>
            <br/><br/>
        </div>
    </div>
</section>
