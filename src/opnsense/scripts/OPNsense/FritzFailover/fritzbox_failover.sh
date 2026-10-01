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
# Instead of disabling the cable gateway (which breaks policy based routing),
# the gateway monitor IP is switched to an unreachable address so dpinger
# reports 100% loss and gateway groups fail over natively. A probe ping is
# forced out of the cable interface to detect when the line is usable again.
#
# usage: fritzbox_failover.sh run|check|test|state|restore

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
umask 077

HELPER="/usr/local/opnsense/scripts/OPNsense/FritzFailover/fritzfailover_helper.php"
RUNDIR="/var/run"
STATE_FILE="${RUNDIR}/fritzfailover.state"
COUNTER_FILE="${RUNDIR}/fritzfailover.counters"
PIDFILE="${RUNDIR}/fritzfailover.pid"
LOCK_FILE="${RUNDIR}/fritzfailover.lock"
TAG="fritzfailover"

TR064_SERVICE="urn:dslforum-org:service:WANIPConnection:1"
TR064_URL_PATH="/upnp/control/wanipconnection1"
IGD_SERVICE="urn:schemas-upnp-org:service:WANIPConnection:1"
IGD_URL_PATH="/igdupnp/control/WANIPConn1"

FAILS=0
OKS=0
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
	if [ -f "${COUNTER_FILE}" ]; then
		read -r _f _o _rest < "${COUNTER_FILE}" || true
		is_uint "${_f:-}" && FAILS=${_f}
		is_uint "${_o:-}" && OKS=${_o}
	fi
}

save_counters()
{
	printf '%s %s\n' "${FAILS}" "${OKS}" > "${COUNTER_FILE}.tmp" &&
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
	if [ "${FF_TR064_ENABLED}" != "1" ]; then
		TR_TEXT="disabled"
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

# Forced probe through the cable interface: source address of the cable
# interface and, if needed, a temporary host route via the cable gateway so
# the probe never leaves through the backup line.
probe_ping()
{
	PING_OK=0
	_target="${FF_GOOD_MONITOR}"

	if [ -z "${GW_DEVICE}" ] || ! ifconfig "${GW_DEVICE}" >/dev/null 2>&1; then
		PING_TEXT="interface '${GW_DEVICE}' not found"
		return 1
	fi

	_src=$(ifconfig "${GW_DEVICE}" inet 2>/dev/null | awk '$1 == "inet" { print $2; exit }')
	if [ -z "${_src}" ]; then
		PING_TEXT="no IPv4 address on ${GW_DEVICE}"
		return 1
	fi

	_added=0
	_rif=$(route -n get -inet "${_target}" 2>/dev/null | awk '$1 == "interface:" { print $2 }')
	if [ "${_rif}" != "${GW_DEVICE}" ] && [ -n "${GW_ADDR}" ]; then
		if route -q -n add -inet -host "${_target}" "${GW_ADDR}" >/dev/null 2>&1; then
			_added=1
		fi
	fi

	_wait_ms=$((FF_PING_TIMEOUT * 1000))
	_total=$((FF_PING_COUNT * FF_PING_TIMEOUT + 1))
	_out=$(ping -n -q -c "${FF_PING_COUNT}" -W "${_wait_ms}" -t "${_total}" \
	    -S "${_src}" "${_target}" 2>&1)
	_rc=$?

	if [ "${_added}" = "1" ]; then
		route -q -n delete -inet -host "${_target}" "${GW_ADDR}" >/dev/null 2>&1
	fi

	_rx=$(printf '%s\n' "${_out}" | sed -n 's/.* \([0-9][0-9]*\) packets received.*/\1/p' | head -n 1)
	_rx=${_rx:-0}
	if [ "${_rc}" -eq 0 ] && [ "${_rx}" -gt 0 ]; then
		PING_OK=1
		PING_TEXT="${_rx}/${FF_PING_COUNT} replies from ${_target} via ${GW_DEVICE}"
		return 0
	fi
	PING_TEXT="0/${FF_PING_COUNT} replies from ${_target} via ${GW_DEVICE}"
	return 1
}

# Only the dpinger instance of the cable gateway is restarted with the new
# monitor IP. Routing and firewall are not touched: dpinger then reports the
# loss (or recovery) itself and OPNsense's own gateway watcher performs the
# native failover/failback of the gateway groups.
apply_monitor()
{
	_new="$1"
	_old="${GW_MONITOR}"
	if ! ${HELPER} setmonitor "${_new}" >/dev/null 2>&1; then
		log_err "could not set monitor IP of ${FF_GATEWAY} to ${_new}"
		MESSAGE="could not change monitor IP"
		return 1
	fi
	/usr/local/sbin/pluginctl -c monitor "${FF_GATEWAY}" >/dev/null 2>&1
	# drop the stale host route of the previous monitor IP via the cable gateway
	if [ -n "${_old}" ] && [ "${_old}" != "${_new}" ] && [ -n "${GW_ADDR}" ]; then
		_rgw=$(route -n get -inet "${_old}" 2>/dev/null | awk '$1 == "gateway:" { print $2 }')
		if [ "${_rgw}" = "${GW_ADDR}" ] && [ "${_old}" != "${GW_ADDR}" ]; then
			route -q -n delete -inet -host "${_old}" "${GW_ADDR}" >/dev/null 2>&1
		fi
	fi
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
	if [ "${GW_MONITOR_DISABLED}" = "1" ]; then
		MESSAGE="monitoring is disabled on gateway ${FF_GATEWAY}, enable it under System > Gateways"
		log_err "${MESSAGE}"
		write_state "unknown"
		return 1
	fi

	load_counters

	tr064_check
	probe_ping

	_healthy=0
	if [ "${PING_OK}" = "1" ] && [ "${TR_STATE}" != "down" ]; then
		_healthy=1
	fi

	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		FAILS=0
		if [ "${_healthy}" = "1" ]; then
			OKS=$((OKS + 1))
			_status="recovering"
			if [ "${OKS}" -ge "${FF_RECOVER_THRESHOLD}" ]; then
				log "cable line healthy for ${OKS} checks (${TR_TEXT}; ${PING_TEXT}), restoring monitor ${FF_GOOD_MONITOR} on ${FF_GATEWAY}"
				if apply_monitor "${FF_GOOD_MONITOR}"; then
					OKS=0
					_status="ok"
					MESSAGE="switched back to cable"
				fi
			fi
		else
			OKS=0
			_status="failover"
		fi
	else
		OKS=0
		if [ "${_healthy}" = "1" ]; then
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
				fi
			fi
		fi
	fi

	save_counters
	write_state "${_status}"
	return 0
}

do_restore()
{
	load_config || return 0
	load_gateway || return 0
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		log "restoring monitor ${FF_GOOD_MONITOR} on ${FF_GATEWAY}"
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
	_res="failed"
	if [ "${PING_OK}" = "1" ] && [ "${TR_STATE}" != "down" ]; then
		_res="ok"
	fi
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		MESSAGE="Failover is currently active."
	elif [ "${_res}" = "ok" ]; then
		MESSAGE="Everything looks fine."
	else
		MESSAGE="The cable line does not look healthy right now."
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
	echo "usage: $0 run|check|test|state|restore" >&2
	exit 2
	;;
esac
