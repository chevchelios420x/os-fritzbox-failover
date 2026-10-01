#!/bin/sh

#
# Copyright (C) 2026 os-fritzbox-failover contributors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
# OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

# FRITZ!Box Cable WAN failover monitor for OPNsense.
#
# The cable gateway is normally monitored against the FRITZ!Box itself (stable,
# no false alarms). This script decides whether the internet behind the cable
# line really works, using the FRITZ!Box TR-064 status and/or pings sourced
# from the cable interface. When the line is dead, the gateway monitor IP is
# switched to an unreachable address so dpinger reports 100% loss and the
# gateway groups fail over natively; when it is healthy again the normal
# monitor IP is restored. The gateway itself is never disabled.
#
# Test mode (dry run): all checks run and every lost ping is recorded per test
# address, but nothing on OPNsense is changed; the decision is only simulated.
#
# usage: fritzbox_failover.sh run|check|test|state|restore|resetstats

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
umask 077

HELPER="/usr/local/opnsense/scripts/OPNsense/FritzFailover/fritzfailover_helper.php"
RUNDIR="/var/run"
STATE_FILE="${RUNDIR}/fritzfailover.state"
COUNTER_FILE="${RUNDIR}/fritzfailover.counters"
STATS_FILE="${RUNDIR}/fritzfailover.stats"
PIDFILE="${RUNDIR}/fritzfailover.pid"
LOCK_FILE="${RUNDIR}/fritzfailover.lock"
TAG="fritzfailover"

TR064_SERVICE="urn:dslforum-org:service:WANIPConnection:1"
TR064_URL_PATH="/upnp/control/wanipconnection1"
IGD_SERVICE="urn:schemas-upnp-org:service:WANIPConnection:1"
IGD_URL_PATH="/igdupnp/control/WANIPConn1"

FAILS=0
OKS=0
USE_TR064=1
USE_PING=1
TR_STATE="unknown"
TR_TEXT="-"
PING_OK=0
PING_TEXT="-"
MESSAGE=""

log()
{
	logger -t "${TAG}" -p daemon.notice -- "$*"
}

log_err()
{
	logger -t "${TAG}" -p daemon.err -- "$*"
}

json_escape()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

is_uint()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

load_config()
{
	_cfg=$(${HELPER} config 2>/dev/null) || return 1
	eval "${_cfg}"
	case "${FF_CHECK_MODE}" in
	fritzbox_ping) USE_TR064=1; USE_PING=1 ;;
	fritzbox) USE_TR064=1; USE_PING=0 ;;
	ping) USE_TR064=0; USE_PING=1 ;;
	*) return 1 ;;
	esac
	for _v in "${FF_PING_COUNT}" "${FF_PING_TIMEOUT}" "${FF_FAIL_THRESHOLD}" \
	    "${FF_RECOVER_THRESHOLD}" "${FF_CHECK_INTERVAL}" "${FF_TR064_PORT}"; do
		is_uint "${_v}" || return 1
	done
	return 0
}

load_gateway()
{
	_gw=$(${HELPER} gwinfo 2>/dev/null) || return 1
	eval "${_gw}"
	[ "${GW_FOUND}" = "1" ]
}

load_counters()
{
	FAILS=0
	OKS=0
	SIM_MONITOR=""
	if [ -f "${COUNTER_FILE}" ]; then
		read -r _f _o _m _rest < "${COUNTER_FILE}" || true
		is_uint "${_f:-}" && FAILS=${_f}
		is_uint "${_o:-}" && OKS=${_o}
		case "${_m:-}" in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*) SIM_MONITOR=${_m} ;;
		esac
	fi
}

save_counters()
{
	printf '%s %s %s\n' "${FAILS}" "${OKS}" "${SIM_MONITOR:--}" > "${COUNTER_FILE}.tmp" &&
	    mv -f "${COUNTER_FILE}.tmp" "${COUNTER_FILE}"
}

write_state()
{
	_status="$1"
	{
		printf '{"status":"%s",' "$(json_escape "${_status}")"
		printf '"gateway":"%s",' "$(json_escape "${FF_GATEWAY:-}")"
		printf '"device":"%s",' "$(json_escape "${GW_DEVICE:-}")"
		printf '"monitor":"%s",' "$(json_escape "${GW_MONITOR:-}")"
		printf '"tr064":"%s",' "$(json_escape "${TR_TEXT}")"
		printf '"ping":"%s",' "$(json_escape "${PING_TEXT}")"
		printf '"failures":%s,"successes":%s,' "${FAILS}" "${OKS}"
		printf '"dry_run":%s,' "$([ "${FF_DRY_RUN:-0}" = "1" ] && echo true || echo false)"
		printf '"targets":['
		if [ -f "${STATS_FILE}" ]; then
			awk 'BEGIN { n = 0 } NF >= 6 {
			    gsub(/_/, " ", $6); gsub(/_/, " ", $7);
			    printf "%s{\"target\":\"%s\",\"checks\":%d,\"failed_checks\":%d,\"sent\":%d,\"lost\":%d,\"last_loss\":\"%s\",\"since\":\"%s\"}", (n++ ? "," : ""), $1, $2, $3, $4, $5, ($6 == "-" ? "" : $6), (NF >= 7 ? $7 : "") }' \
			    "${STATS_FILE}"
		fi
		printf '],'

		printf '"last_check":"%s",' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '"message":"%s"}\n' "$(json_escape "${MESSAGE}")"
	} > "${STATE_FILE}.tmp" && chmod 644 "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

# SOAP request against the FRITZ!Box, credentials are passed to curl via
# stdin (-K -) so they never appear in the process list or on disk.
soap_call()
{
	_service="$1"
	_path="$2"
	_auth="$3"
	_body="<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:GetStatusInfo xmlns:u=\"${_service}\"></u:GetStatusInfo></s:Body></s:Envelope>"
	if [ "${_auth}" = "1" ]; then
		${HELPER} curlcfg 2>/dev/null | curl -sS -K - --anyauth \
		    --connect-timeout 3 --max-time 6 \
		    -H 'Content-Type: text/xml; charset="utf-8"' \
		    -H "SoapAction: ${_service}#GetStatusInfo" \
		    --data-binary "${_body}" -w '\n%{http_code}' \
		    "http://${FF_FRITZBOX_IP}:${FF_TR064_PORT}${_path}" 2>/dev/null
	else
		curl -sS --connect-timeout 3 --max-time 6 \
		    -H 'Content-Type: text/xml; charset="utf-8"' \
		    -H "SoapAction: ${_service}#GetStatusInfo" \
		    --data-binary "${_body}" -w '\n%{http_code}' \
		    "http://${FF_FRITZBOX_IP}:${FF_TR064_PORT}${_path}" 2>/dev/null
	fi
}

parse_status()
{
	printf '%s' "$1" | tr -d '\r' | sed -n 's/.*<NewConnectionStatus>\([A-Za-z]*\)<\/NewConnectionStatus>.*/\1/p' | head -n 1
}

# Sets TR_STATE to up|down|unknown and TR_TEXT to a readable description.
tr064_check()
{
	TR_STATE="unknown"
	if [ "${USE_TR064}" != "1" ]; then
		TR_TEXT="not used"
		return 0
	fi

	_resp=$(soap_call "${TR064_SERVICE}" "${TR064_URL_PATH}" "${FF_TR064_HAS_AUTH}")
	_code=$(printf '%s' "${_resp}" | tail -n 1)
	_status=$(parse_status "${_resp}")

	if [ -z "${_status}" ]; then
		# fall back to the unauthenticated IGD service if TR-064 is unavailable
		_resp2=$(soap_call "${IGD_SERVICE}" "${IGD_URL_PATH}" 0)
		_status=$(parse_status "${_resp2}")
		[ -n "${_status}" ] && _code="igd"
	fi

	case "${_status}" in
	Connected)
		TR_STATE="up"
		TR_TEXT="Connected"
		;;
	Connecting|Disconnected|Disconnecting|PendingDisconnect|Unconfigured|Authenticating)
		TR_STATE="down"
		TR_TEXT="${_status}"
		;;
	'')
		case "${_code}" in
		401) TR_TEXT="authentication failed (check TR-064 user/password)" ;;
		000|'') TR_TEXT="FRITZ!Box not reachable" ;;
		*) TR_TEXT="no status (HTTP ${_code})" ;;
		esac
		;;
	*)
		TR_TEXT="unknown status ${_status}"
		;;
	esac
	[ "${_code}" = "igd" ] && TR_TEXT="${TR_TEXT} (IGD fallback)"
	return 0
}

# One probe against a single target, sourced from the cable interface
# address. OPNsense's default "force gw" rule (let out anything from firewall
# host itself) then sends it through the cable gateway regardless of the
# routing table, so the result reflects the cable line even during failover.
# Prints the number of replies.
probe_one()
{
	_t="$1"
	_s="$2"
	_added=0
	if [ "${GW_FORCE_GW}" != "1" ] && [ -n "${GW_ADDR}" ]; then
		# force gw rule disabled by the user: fall back to a temporary host route
		_rif=$(route -n get -inet "${_t}" 2>/dev/null | awk '$1 == "interface:" { print $2 }')
		if [ "${_rif}" != "${GW_DEVICE}" ] &&
		    route -q -n add -inet -host "${_t}" "${GW_ADDR}" >/dev/null 2>&1; then
			_added=1
		fi
	fi
	_o=$(ping -n -q -c "${FF_PING_COUNT}" -W "$((FF_PING_TIMEOUT * 1000))" \
	    -t "$((FF_PING_COUNT * FF_PING_TIMEOUT + 1))" -S "${_s}" "${_t}" 2>&1)
	if [ "${_added}" = "1" ]; then
		route -q -n delete -inet -host "${_t}" "${GW_ADDR}" >/dev/null 2>&1
	fi
	_r=$(printf '%s\n' "${_o}" | sed -n 's/.* \([0-9][0-9]*\) packets received.*/\1/p' | head -n 1)
	echo "${_r:-0}"
}

# Per test address statistics, one line per address:
#   target checks failed_checks sent lost last_loss since
# (timestamps use "_" instead of a blank). Addresses no longer configured are
# dropped, new ones start at zero. Every lost ping is also logged.
update_stats()
{
	_sdir="$1"
	_now=$(date '+%Y-%m-%d_%H:%M:%S')
	_new="${STATS_FILE}.tmp"
	: > "${_new}"
	_i=0
	for _t in ${FF_PROBE_TARGETS}; do
		_i=$((_i + 1))
		_rx=$(cat "${_sdir}/${_i}" 2>/dev/null)
		is_uint "${_rx}" || _rx=0
		[ "${_rx}" -gt "${FF_PING_COUNT}" ] && _rx=${FF_PING_COUNT}
		_lost=$((FF_PING_COUNT - _rx))
		_line=$(awk -v t="${_t}" '$1 == t { print; exit }' "${STATS_FILE}" 2>/dev/null)
		if [ -n "${_line}" ]; then
			set -- ${_line}
			_c=$2; _fc=$3; _se=$4; _lo=$5; _ll=$6; _since=${7:-${_now}}
		else
			_c=0; _fc=0; _se=0; _lo=0; _ll="-"; _since=${_now}
		fi
		_c=$((_c + 1))
		_se=$((_se + FF_PING_COUNT))
		if [ "${_lost}" -gt 0 ]; then
			_lo=$((_lo + _lost))
			_ll=${_now}
			[ "${_rx}" -eq 0 ] && _fc=$((_fc + 1))
			log "probe loss ${_t}: ${_rx}/${FF_PING_COUNT} replies via ${GW_DEVICE}"
		fi
		printf '%s %s %s %s %s %s %s\n' "${_t}" "${_c}" "${_fc}" "${_se}" "${_lo}" "${_ll}" "${_since}" >> "${_new}"
	done
	mv -f "${_new}" "${STATS_FILE}"
}

# Pings all test addresses in parallel. The line counts as reachable as soon
# as one address answers; it only counts as dead when none answers.
probe_ping()
{
	PING_OK=0
	if [ "${USE_PING}" != "1" ]; then
		PING_TEXT="not used"
		return 0
	fi
	if [ -z "${FF_PROBE_TARGETS}" ]; then
		PING_TEXT="no test addresses configured"
		return 1
	fi
	if [ -z "${GW_DEVICE}" ] || ! ifconfig "${GW_DEVICE}" >/dev/null 2>&1; then
		PING_TEXT="interface '${GW_DEVICE}' not found"
		return 1
	fi
	_src=$(ifconfig "${GW_DEVICE}" inet 2>/dev/null | awk '$1 == "inet" { print $2; exit }')
	if [ -z "${_src}" ]; then
		PING_TEXT="no IPv4 address on ${GW_DEVICE}"
		return 1
	fi

	_dir=$(mktemp -d "${RUNDIR}/fritzfailover.XXXXXX") || return 1
	_i=0
	for _t in ${FF_PROBE_TARGETS}; do
		_i=$((_i + 1))
		probe_one "${_t}" "${_src}" > "${_dir}/${_i}" &
	done
	wait

	_i=0
	_up=0
	PING_TEXT=""
	for _t in ${FF_PROBE_TARGETS}; do
		_i=$((_i + 1))
		_rx=$(cat "${_dir}/${_i}" 2>/dev/null)
		is_uint "${_rx}" || _rx=0
		[ "${_rx}" -gt 0 ] && _up=$((_up + 1))
		PING_TEXT="${PING_TEXT}${PING_TEXT:+, }${_t} ${_rx}/${FF_PING_COUNT}"
	done
	if [ "${RECORD_STATS:-0}" = "1" ]; then
		update_stats "${_dir}"
	fi
	rm -rf "${_dir}"
	PING_TEXT="${PING_TEXT} (via ${GW_DEVICE}, source ${_src})"
	if [ "${_up}" -gt 0 ]; then
		PING_OK=1
		return 0
	fi
	return 1
}

# Combines both checks into fail|ok|unknown.
#   fail:    FRITZ!Box reports no connection, or no test address answers
#   ok:      nothing failed and at least one check positively confirmed it
#   unknown: nothing failed but nothing confirmed either (e.g. TR-064 login
#            broken in "FRITZ!Box only" mode); counters stay untouched
evaluate()
{
	if [ "${USE_TR064}" = "1" ] && [ "${TR_STATE}" = "down" ]; then
		echo fail
	elif [ "${USE_PING}" = "1" ] && [ "${PING_OK}" != "1" ]; then
		echo fail
	elif [ "${USE_PING}" = "1" ] || [ "${TR_STATE}" = "up" ]; then
		echo ok
	else
		echo unknown
	fi
}

# Only the monitor IP of the cable gateway is changed and only its dpinger
# instance is restarted. Routing and firewall are not touched: dpinger then
# reports the loss (or recovery) itself and OPNsense's own gateway watcher
# performs the native failover/failback of the gateway groups.
# In test mode nothing is changed, the new monitor IP is only simulated.
apply_monitor()
{
	_new="$1"
	if [ "${FF_DRY_RUN}" = "1" ]; then
		log "TEST MODE: would set monitor IP of ${FF_GATEWAY} to ${_new} (nothing changed)"
		SIM_MONITOR="${_new}"
		GW_MONITOR="${_new}"
		return 0
	fi
	if ! ${HELPER} setmonitor "${_new}" >/dev/null 2>&1; then
		log_err "could not set monitor IP of ${FF_GATEWAY} to ${_new}"
		MESSAGE="could not change monitor IP"
		return 1
	fi
	/usr/local/sbin/pluginctl -c monitor "${FF_GATEWAY}" >/dev/null 2>&1
	GW_MONITOR="${_new}"
	return 0
}

run_check()
{
	MESSAGE=""
	if ! load_config; then
		log_err "unable to read configuration"
		return 1
	fi
	if [ "${FF_ENABLED}" != "1" ]; then
		GW_DEVICE=""
		GW_MONITOR=""
		MESSAGE="disabled"
		write_state "stopped"
		return 0
	fi
	if ! load_gateway; then
		GW_DEVICE=""
		GW_MONITOR=""
		MESSAGE="gateway ${FF_GATEWAY} not found, check the gateway name"
		log_err "${MESSAGE}"
		write_state "unknown"
		return 1
	fi
	if [ "${GW_PERSISTED}" != "1" ]; then
		MESSAGE="gateway ${FF_GATEWAY} is not saved yet: open it once under System > Gateways and click Save"
		log_err "${MESSAGE}"
		write_state "unknown"
		return 1
	fi
	if [ "${GW_MONITOR_DISABLED}" = "1" ]; then
		MESSAGE="monitoring is disabled on gateway ${FF_GATEWAY}, enable it under System > Gateways"
		log_err "${MESSAGE}"
		write_state "unknown"
		return 1
	fi

	load_counters
	REAL_MONITOR="${GW_MONITOR}"
	if [ "${FF_DRY_RUN}" = "1" ]; then
		# simulate the monitor IP; a real failover left over is shown as is
		[ -n "${SIM_MONITOR}" ] || SIM_MONITOR="${GW_MONITOR}"
		GW_MONITOR="${SIM_MONITOR}"
	else
		SIM_MONITOR=""
	fi

	tr064_check
	RECORD_STATS=1
	probe_ping
	RECORD_STATS=0

	_result=$(evaluate)

	if [ "${_result}" = "unknown" ]; then
		MESSAGE="FRITZ!Box status unavailable (${TR_TEXT}), no decision possible"
		if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
			_status="failover"
		else
			_status="ok"
		fi
	elif [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		FAILS=0
		if [ "${_result}" = "ok" ]; then
			OKS=$((OKS + 1))
			_status="recovering"
			if [ "${OKS}" -ge "${FF_RECOVER_THRESHOLD}" ]; then
				log "cable line healthy for ${OKS} checks (${TR_TEXT}; ${PING_TEXT}), restoring monitor ${FF_GOOD_MONITOR} on ${FF_GATEWAY}"
				if apply_monitor "${FF_GOOD_MONITOR}"; then
					OKS=0
					_status="ok"
					MESSAGE="switched back to cable"
					[ "${FF_DRY_RUN}" = "1" ] && MESSAGE="TEST MODE: would switch back to cable now"
				fi
			fi
		else
			OKS=0
			_status="failover"
		fi
	else
		OKS=0
		if [ "${_result}" = "ok" ]; then
			FAILS=0
			_status="ok"
		else
			FAILS=$((FAILS + 1))
			_status="degraded"
			if [ "${FAILS}" -ge "${FF_FAIL_THRESHOLD}" ]; then
				log "cable line failed ${FAILS} checks (${TR_TEXT}; ${PING_TEXT}), setting monitor ${FF_BAD_MONITOR} on ${FF_GATEWAY}"
				if apply_monitor "${FF_BAD_MONITOR}"; then
					FAILS=0
					_status="failover"
					MESSAGE="switched to backup line"
					[ "${FF_DRY_RUN}" = "1" ] && MESSAGE="TEST MODE: would fail over to the backup line now"
				fi
			fi
		fi
	fi

	save_counters
	if [ "${FF_DRY_RUN}" = "1" ]; then
		[ -n "${MESSAGE}" ] || MESSAGE="TEST MODE: nothing is changed (real monitor IP ${REAL_MONITOR})"
	fi
	write_state "${_status}"
	return 0
}

do_restore()
{
	load_config || return 0
	load_gateway || return 0
	# undoing a real failover is always allowed, also when test mode was just enabled
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		log "restoring monitor ${FF_GOOD_MONITOR} on ${FF_GATEWAY}"
		FF_DRY_RUN=0
		apply_monitor "${FF_GOOD_MONITOR}"
	fi
	rm -f "${COUNTER_FILE}"
	FAILS=0
	OKS=0
	MESSAGE="monitor stopped"
	write_state "stopped"
	return 0
}

do_test()
{
	if ! load_config; then
		printf '{"status":"failed","message":"unable to read configuration"}\n'
		return 0
	fi
	if ! load_gateway; then
		printf '{"status":"failed","message":"%s"}\n' \
		    "$(json_escape "Gateway '${FF_GATEWAY}' not found. Check the name under System > Gateways > Configuration.")"
		return 0
	fi
	tr064_check
	probe_ping
	_result=$(evaluate)
	_res="failed"
	case "${_result}" in
	ok)
		_res="ok"
		MESSAGE="The cable line works."
		;;
	fail)
		MESSAGE="The cable line does not work right now."
		;;
	*)
		MESSAGE="No decision possible: the FRITZ!Box status could not be read."
		;;
	esac
	if [ "${GW_FORCE_GW}" != "1" ]; then
		MESSAGE="${MESSAGE} Note: 'Disable force gateway' is set in Firewall > Settings > Advanced, test pings use temporary host routes."
	fi
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		MESSAGE="${MESSAGE} Failover is currently active."
	fi
	printf '{"status":"%s","gateway":"%s","device":"%s","monitor":"%s","tr064":"%s","ping":"%s","message":"%s"}\n' \
	    "${_res}" "$(json_escape "${FF_GATEWAY}")" "$(json_escape "${GW_DEVICE}")" \
	    "$(json_escape "${GW_MONITOR}")" "$(json_escape "${TR_TEXT}")" \
	    "$(json_escape "${PING_TEXT}")" "$(json_escape "${MESSAGE}")"
}

do_state()
{
	if [ -f "${STATE_FILE}" ]; then
		if [ -f "${PIDFILE}" ] && pgrep -F "${PIDFILE}" >/dev/null 2>&1; then
			cat "${STATE_FILE}"
		else
			sed 's/^{"status":"[a-z]*"/{"status":"stopped"/' "${STATE_FILE}"
		fi
	else
		printf '{"status":"stopped"}\n'
	fi
}

locked()
{
	/usr/local/bin/flock -w 60 "${LOCK_FILE}" "$0" "$@"
}

case "${1:-}" in
run)
	log "monitor started"
	trap 'log "monitor stopped"; exit 0' INT TERM
	while :; do
		locked check-locked || true
		_interval=${FF_CHECK_INTERVAL:-10}
		load_config >/dev/null 2>&1 && _interval=${FF_CHECK_INTERVAL}
		sleep "${_interval}" &
		wait $!
	done
	;;
check)
	locked check-locked
	;;
check-locked)
	run_check
	;;
restore)
	locked restore-locked
	;;
restore-locked)
	do_restore
	;;
resetstats)
	rm -f "${STATS_FILE}"
	;;
test)
	locked test-locked
	;;
test-locked)
	do_test
	;;
state)
	do_state
	;;
*)
	echo "usage: $0 run|check|test|state|restore|resetstats" >&2
	exit 2
	;;
esac
