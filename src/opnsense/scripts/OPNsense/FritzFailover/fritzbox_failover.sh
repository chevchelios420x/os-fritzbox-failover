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
# line really works, using the FRITZ!Box connection status (TR-064 or UPnP)
# and/or pings sourced from the cable interface. When the line is dead, the
# gateway monitor IP is switched to an unreachable address so dpinger reports
# 100% loss and the gateway groups fail over natively; when it is healthy
# again the normal monitor IP is restored. The gateway itself is never
# disabled, and nothing but its monitor IP is ever changed.
#
# Test mode (dry run): all checks run and every lost ping is recorded per test
# address, but nothing on OPNsense is changed; the decision is only simulated.
#
# usage: fritzbox_failover.sh run|check|test|state|stopped|restore|resetstats|testfailover
#
#   run         monitor loop (started by rc.d via daemon(8))
#   check       single check including the decision
#   test        single diagnostic check, never changes anything
#   state       print the last state as JSON
#   stopped     rc.d post-stop hook: restores the normal monitor IP only if the
#               plugin no longer manages the gateway (disabled or test mode);
#               a plain restart keeps an active failover
#   restore     unconditionally restore the normal monitor IP
#   resetstats  clear the per test address statistics
#   testfailover      start a real test failover for TEST_DURATION seconds:
#                     exactly the same switch as a real failover (monitor IP
#                     changed, dpinger restarted, OPNsense fails over natively),
#                     followed by the same switch back
#   testfailover-end  end a running test failover (called by its timer)

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
umask 077

HELPER="/usr/local/opnsense/scripts/OPNsense/FritzFailover/fritzfailover_helper.php"
RUNDIR="/var/run"
STATE_FILE="${RUNDIR}/fritzfailover.state"
COUNTER_FILE="${RUNDIR}/fritzfailover.counters"
STATS_FILE="${RUNDIR}/fritzfailover.stats"
BACKOFF_FILE="${RUNDIR}/fritzfailover.tr064_backoff"
PIDFILE="${RUNDIR}/fritzfailover.pid"
LOCK_FILE="${RUNDIR}/fritzfailover.lck"
TEST_FILE="${RUNDIR}/fritzfailover.testfailover"
# switch history, kept across reboots
HISTORY_DIR="/var/db/fritzfailover"
HISTORY_FILE="${HISTORY_DIR}/history"
HISTORY_KEEP=50
# time of the last self-healing restart (kept across reboots)
SELFHEAL_FILE="${HISTORY_DIR}/last_selfheal"
# debug mode: one detailed line per check, switches itself off
# first of two own routing tables (FIBs): base = cable line, base+1 = backup
FIB_BASE_FILE="${HISTORY_DIR}/fib_base"
DEBUG_UNTIL_FILE="${HISTORY_DIR}/debug_until"
DEBUG_AT_FILE="${HISTORY_DIR}/debug_at"
DEBUG_LOG="${HISTORY_DIR}/debug.log"
DEBUG_LAST="${RUNDIR}/fritzfailover.debug_last"
# verbose debug: also firewall route-to rules, routing tables and pf states
DEBUG_VERBOSE_FILE="${HISTORY_DIR}/debug_verbose"
DEBUG_VERBOSE_LAST="${RUNDIR}/fritzfailover.debug_verbose_last"
# last automatic filter reload because the test ping rules were missing
FW_RELOAD_FILE="${RUNDIR}/fritzfailover.fw_reload"
FW_RELOAD_PAUSE=900
DEBUG_HOURS=12
DEBUG_MAX_BYTES=20971520
# desired Cloudflare DNS target (normal|failover) until the update succeeded
CF_PENDING_FILE="${RUNDIR}/fritzfailover.cf_pending"
# Pushover messages not delivered yet:
#   "<epoch><TAB><failover|failback><TAB><title><TAB><message>"
PUSH_QUEUE_FILE="${RUNDIR}/fritzfailover.push_queue"
TAG="fritzfailover"

# no switching during the first seconds after boot (WAN may still be coming up)
STARTUP_GRACE=120
# pause TR-064 logins after a failed login to avoid a FRITZ!Box login lockout
TR064_BACKOFF=900
# duration of a manually started test failover
TEST_DURATION=120

TR064_SERVICE="urn:dslforum-org:service:WANIPConnection:1"
TR064_URL_PATH="/upnp/control/wanipconnection1"
IGD_SERVICE="urn:schemas-upnp-org:service:WANIPConnection:1"
IGD_URL_PATH="/igdupnp/control/WANIPConn1"
# physical line state, available without login on all verified models
IGD_LINK_SERVICE="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"
IGD_LINK_PATH="/igdupnp/control/WANCommonIFC1"

FAILS=0
OKS=0
SIM_MONITOR=""
USE_TR064=1
USE_PING=1
TR_STATE="unknown"
TR_TEXT="-"
PING_OK=0
PING_TEXT="-"
MESSAGE=""
FW_TEXT="-"
RECORD_STATS=0
FORCE_TR064=0
TEST_LEFT=""
LAST_STATUS=""

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

# Appends one switch event: "<epoch> <kind> <details>".
#   kinds: failover, failback, test_start, test_end, restore,
#          sim_failover, sim_failback (test mode, nothing changed)
record_event()
{
	mkdir -p "${HISTORY_DIR}" 2>/dev/null || return 0
	_detail=$(printf '%s' "$2" | tr -d '"\\\000-\037' | cut -c1-200)
	printf '%s %s %s\n' "$(date +%s)" "$1" "${_detail}" >> "${HISTORY_FILE}"
	tail -n "${HISTORY_KEEP}" "${HISTORY_FILE}" > "${HISTORY_FILE}.tmp" 2>/dev/null &&
	    mv -f "${HISTORY_FILE}.tmp" "${HISTORY_FILE}"
	chmod 644 "${HISTORY_FILE}" 2>/dev/null
}

# Human readable reason for a switch event (FRITZ!Box status and/or pings).
event_detail()
{
	_d=""
	[ "${TR_TEXT}" != "not used" ] && [ "${TR_TEXT}" != "-" ] && _d="FRITZ!Box: ${TR_TEXT}"
	[ "${PING_TEXT}" != "not used" ] && [ "${PING_TEXT}" != "-" ] && _d="${_d}${_d:+; }Ping: ${PING_TEXT}"
	printf '%s' "${_d}"
}

is_uint()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

uptime_seconds()
{
	_boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')
	if is_uint "${_boot}"; then
		echo $(($(date +%s) - _boot))
	else
		echo 999999
	fi
}

load_config()
{
	_cfg=$(${HELPER} config 2>/dev/null) || return 1
	eval "${_cfg}"
	case "${FF_CHECK_MODE:-}" in
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
	LAST_STATUS="$1"
	{
		printf '{"status":"%s",' "$(json_escape "${_status}")"
		printf '"gateway":"%s",' "$(json_escape "${FF_GATEWAY:-}")"
		printf '"device":"%s",' "$(json_escape "${GW_DEVICE:-}")"
		printf '"monitor":"%s",' "$(json_escape "${GW_MONITOR:-}")"
		printf '"tr064":"%s",' "$(json_escape "${TR_TEXT}")"
		printf '"ping":"%s",' "$(json_escape "${PING_TEXT}")"
		printf '"fwrules":"%s",' "$(json_escape "${FW_TEXT}")"
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
		# newest 20 switch events, newest first
		printf '"events":['
		if [ -f "${HISTORY_FILE}" ]; then
			tail -n 20 "${HISTORY_FILE}" | awk 'BEGIN { n = 0 } { l[NR] = $0 } END {
			    for (i = NR; i >= 1; i--) {
			        split(l[i], f, " ");
			        if (f[1] !~ /^[0-9]+$/) continue;
			        d = l[i]; sub(/^[^ ]+ [^ ]+ ?/, "", d);
			        printf "%s{\"time\":%s,\"kind\":\"%s\",\"detail\":\"%s\"}", (n++ ? "," : ""), f[1], f[2], d
			    } }'
		fi
		printf '],'
		if [ -n "${TEST_LEFT}" ]; then
			printf '"test_left":%s,"test_total":%s,' "${TEST_LEFT}" "${TEST_DURATION}"
		fi
		printf '"last_selfheal":%s,' "$(_l=$(cat "${SELFHEAL_FILE}" 2>/dev/null); is_uint "${_l}" && echo "${_l}" || echo 0)"
		printf '"last_check":"%s","last_check_epoch":%s,"interval":%s,' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" "${FF_CHECK_INTERVAL:-10}"
		printf '"message":"%s"}\n' "$(json_escape "${MESSAGE}")"
	} > "${STATE_FILE}.tmp" && chmod 644 "${STATE_FILE}.tmp" && mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

# SOAP GetStatusInfo request. With authentication the credentials are passed
# to curl via stdin (-K -) so they never appear in the process list or on disk.
# Prints the response body followed by the HTTP status code on the last line.
soap_call()
{
	_service="$1"
	_path="$2"
	_auth="$3"
	_action="${4:-GetStatusInfo}"
	_body="<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:${_action} xmlns:u=\"${_service}\"></u:${_action}></s:Body></s:Envelope>"
	if [ "${_auth}" = "1" ]; then
		${HELPER} curlcfg 2>/dev/null | curl -sS -K - --anyauth \
		    --connect-timeout 3 --max-time 6 \
		    -H 'Content-Type: text/xml; charset="utf-8"' \
		    -H "SoapAction: ${_service}#${_action}" \
		    --data-binary "${_body}" -w '\n%{http_code}' \
		    "http://${FF_FRITZBOX_IP}:${FF_TR064_PORT}${_path}" 2>/dev/null
	else
		curl -sS --connect-timeout 3 --max-time 6 \
		    -H 'Content-Type: text/xml; charset="utf-8"' \
		    -H "SoapAction: ${_service}#${_action}" \
		    --data-binary "${_body}" -w '\n%{http_code}' \
		    "http://${FF_FRITZBOX_IP}:${FF_TR064_PORT}${_path}" 2>/dev/null
	fi
}

parse_status()
{
	printf '%s' "$1" | tr -d '\r' | sed -n 's/.*<NewConnectionStatus>\([A-Za-z]*\)<\/NewConnectionStatus>.*/\1/p' | head -n 1
}

backoff_until()
{
	_u=$(cat "${BACKOFF_FILE}" 2>/dev/null)
	is_uint "${_u}" && echo "${_u}" || echo 0
}

# Reads NewConnectionStatus from the FRITZ!Box.
#   with TR-064 login:    authenticated TR-064 (WANIPConnection:1), UPnP as fallback
#   without TR-064 login: UPnP IGD only, no credentials needed
# After a failed TR-064 login, TR-064 is paused for TR064_BACKOFF seconds
# (UPnP is still used meanwhile). Sets TR_STATE to up|down|unknown and TR_TEXT.
tr064_check()
{
	TR_STATE="unknown"
	if [ "${USE_TR064}" != "1" ]; then
		TR_TEXT="not used"
		return 0
	fi

	_status=""
	_source=""
	_tr_code=""
	_igd_code=""
	_note=""

	if [ "${FF_TR064_HAS_AUTH}" = "1" ]; then
		_until=$(backoff_until)
		if [ "${FORCE_TR064}" != "1" ] && [ "$(date +%s)" -lt "${_until}" ]; then
			_note="TR-064 login paused after a failed login until $(date -r "${_until}" '+%H:%M')"
		else
			_resp=$(soap_call "${TR064_SERVICE}" "${TR064_URL_PATH}" 1)
			_tr_code=$(printf '%s' "${_resp}" | tail -n 1)
			_status=$(parse_status "${_resp}")
			if [ -n "${_status}" ]; then
				_source="TR-064"
				rm -f "${BACKOFF_FILE}"
			elif [ "${_tr_code}" = "401" ]; then
				_note="TR-064 login failed (check user/password)"
				if [ "${FORCE_TR064}" != "1" ]; then
					echo $(($(date +%s) + TR064_BACKOFF)) > "${BACKOFF_FILE}"
					_note="${_note}, paused for $((TR064_BACKOFF / 60)) minutes"
					log_err "TR-064 login to ${FF_FRITZBOX_IP} failed, pausing TR-064 for $((TR064_BACKOFF / 60)) minutes"
				fi
			fi
		fi
	fi

	if [ -z "${_status}" ]; then
		_resp=$(soap_call "${IGD_SERVICE}" "${IGD_URL_PATH}" 0)
		_igd_code=$(printf '%s' "${_resp}" | tail -n 1)
		_status=$(parse_status "${_resp}")
		[ -n "${_status}" ] && _source="UPnP"
	fi

	case "${_status}" in
	Connected)
		TR_STATE="up"
		TR_TEXT="Connected (${_source})"
		;;
	Connecting|Disconnected|Disconnecting|PendingDisconnect|Unconfigured|Authenticating)
		TR_STATE="down"
		TR_TEXT="${_status} (${_source})"
		;;
	'')
		if [ "${_igd_code}" = "000" ] && { [ -z "${_tr_code}" ] || [ "${_tr_code}" = "000" ]; }; then
			TR_TEXT="FRITZ!Box not reachable"
		elif [ -n "${_note}" ]; then
			TR_TEXT="${_note}; no UPnP status either"
		else
			TR_TEXT="no status: enter a TR-064 login or enable 'Transmit status information over UPnP' on the FRITZ!Box"
		fi
		[ -n "${_note}" ] && [ "${TR_TEXT#"${_note}"}" = "${TR_TEXT}" ] && TR_TEXT="${_note}; ${TR_TEXT}"
		;;
	*)
		TR_TEXT="unknown status ${_status} (${_source})"
		;;
	esac
	if [ -n "${_note}" ] && [ -n "${_status}" ]; then
		TR_TEXT="${TR_TEXT}; ${_note}"
	fi

	# Physical line (cable sync / DSL / mobile / Ethernet WAN) via UPnP
	# GetCommonLinkProperties: "Down" means the line is gone, whatever the
	# connection status says. No answer is ignored (older or other models).
	_resp=$(soap_call "${IGD_LINK_SERVICE}" "${IGD_LINK_PATH}" 0 GetCommonLinkProperties)
	_link=$(printf '%s' "${_resp}" | tr -d '\r' | sed -n 's/.*<NewPhysicalLinkStatus>\([A-Za-z]*\)<\/NewPhysicalLinkStatus>.*/\1/p' | head -n 1)
	case "${_link}" in
	Down)
		TR_STATE="down"
		TR_TEXT="${TR_TEXT}; physical link Down"
		;;
	Up|Initializing|Unavailable)
		TR_TEXT="${TR_TEXT}; link ${_link}"
		;;
	esac
	return 0
}

# Own routing tables ---------------------------------------------------------
#
# The test pings must leave through the cable line even while the firewall's
# default route points to the backup line. A source address alone is not
# enough (the packet would follow the default route out of the backup
# interface and be NATed there). So the plugin keeps two small routing tables
# (FIBs) of its own: one whose only default route is the cable gateway and
# one for the backup gateway. Processes started with setfib(1) use them; the
# rest of the firewall keeps using table 0 and is not affected.

fib_base()
{
	_b=$(cat "${FIB_BASE_FILE}" 2>/dev/null)
	if ! is_uint "${_b}" || [ "${_b}" -lt 1 ]; then
		_b=$(sysctl -n net.fibs 2>/dev/null)
		is_uint "${_b}" || _b=1
		[ "${_b}" -lt 1 ] && _b=1
		mkdir -p "${HISTORY_DIR}" 2>/dev/null
		echo "${_b}" > "${FIB_BASE_FILE}"
	fi
	# make sure both tables exist (net.fibs can only grow, at runtime)
	_n=$(sysctl -n net.fibs 2>/dev/null)
	if is_uint "${_n}" && [ "${_n}" -lt $((_b + 2)) ]; then
		if sysctl net.fibs=$((_b + 2)) >/dev/null 2>&1; then
			log "created routing tables ${_b} (cable) and $((_b + 1)) (backup) for test pings"
		else
			return 1
		fi
	fi
	echo "${_b}"
}

# ensure_fib <fib> <gateway address> <device>: table holds exactly a host
# route to the gateway on that device and a default route via the gateway
ensure_fib()
{
	_f="$1"; _g="$2"; _d="$3"
	[ -n "${_f}" ] && [ -n "${_g}" ] && [ -n "${_d}" ] || return 1
	_cur=$(setfib "${_f}" route -n get -inet default 2>/dev/null | awk '$1 == "gateway:" { g = $2 } $1 == "interface:" { i = $2 } END { print g " " i }')
	[ "${_cur}" = "${_g} ${_d}" ] && return 0
	setfib "${_f}" route -q -n delete -inet default >/dev/null 2>&1
	setfib "${_f}" route -q -n delete -inet -host "${_g}" >/dev/null 2>&1
	setfib "${_f}" route -q -n add -inet -host "${_g}" -iface "${_d}" >/dev/null 2>&1
	setfib "${_f}" route -q -n add -inet default "${_g}" >/dev/null 2>&1
	_cur=$(setfib "${_f}" route -n get -inet default 2>/dev/null | awk '$1 == "gateway:" { g = $2 } $1 == "interface:" { i = $2 } END { print g " " i }')
	[ "${_cur}" = "${_g} ${_d}" ]
}

# routing table of the cable line ('' if it cannot be set up)
cable_fib()
{
	_b=$(fib_base) || return 1
	ensure_fib "${_b}" "${GW_ADDR}" "${GW_DEVICE}" && echo "${_b}"
}

# routing table of the backup line ('' if not configured / not possible)
backup_fib()
{
	_b=$(fib_base) || return 1
	ensure_fib $((_b + 1)) "${BK_ADDR:-}" "${BK_DEVICE:-}" && echo $((_b + 1))
}

# One probe against a single target through the cable routing table, so the
# result reflects the cable line even during a failover. Prints the replies.
probe_one()
{
	_t="$1"
	_s="$2"
	_f="$3"
	_o=$(setfib "${_f}" ping -n -q -c "${FF_PING_COUNT}" -W "$((FF_PING_TIMEOUT * 1000))" \
	    -t "$((FF_PING_COUNT * FF_PING_TIMEOUT + 1))" -S "${_s}" "${_t}" 2>&1)
	_r=$(printf '%s\n' "${_o}" | sed -n 's/.* \([0-9][0-9]*\) packets received.*/\1/p' | head -n 1)
	echo "${_r:-0}"
}

# Per test address statistics, one line per address:
#   target checks failed_checks sent lost last_loss since
# (timestamps use "_" instead of a blank). Addresses no longer configured are
# dropped, new ones start at zero. Lost pings are logged, except while the
# cable line is known to be down (failover), to keep the log readable.
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
			if [ "${GW_MONITOR}" != "${FF_BAD_MONITOR}" ]; then
				log "probe loss ${_t}: ${_rx}/${FF_PING_COUNT} replies via ${GW_DEVICE}"
			fi
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
	PING_UNUSABLE=0
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

	_fib=$(cable_fib)
	if [ -z "${_fib}" ]; then
		# without the own routing table a ping could leave through the backup
		# line and wrongly report the cable as working: no ping result then
		PING_TEXT="cable routing table could not be set up (gateway address of ${FF_GATEWAY} unknown?), ping not usable"
		PING_UNUSABLE=1
		return 1
	fi
	_dir=$(mktemp -d "${RUNDIR}/fritzfailover.XXXXXX") || return 1
	_i=0
	for _t in ${FF_PROBE_TARGETS}; do
		_i=$((_i + 1))
		probe_one "${_t}" "${_src}" "${_fib}" > "${_dir}/${_i}" &
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
	if [ "${RECORD_STATS}" = "1" ]; then
		update_stats "${_dir}"
	fi
	rm -rf "${_dir}"
	PING_TEXT="${PING_TEXT} (via ${GW_DEVICE}, table ${_fib})"
	if [ "${_up}" -gt 0 ]; then
		PING_OK=1
		return 0
	fi
	return 1
}

# Combines both checks into fail|ok|unknown.
#   fail:    FRITZ!Box reports no connection, or no test address answers
#   ok:      nothing failed and at least one check positively confirmed it
#   unknown: nothing failed but nothing confirmed either (e.g. FRITZ!Box
#            status unreadable in "FRITZ!Box only" mode); counters untouched
evaluate()
{
	if [ "${USE_TR064}" = "1" ] && [ "${TR_STATE}" = "down" ]; then
		echo fail
	elif [ "${USE_PING}" = "1" ] && [ "${PING_UNUSABLE:-0}" = "1" ]; then
		echo unknown
	elif [ "${USE_PING}" = "1" ] && [ "${PING_OK}" != "1" ]; then
		echo fail
	elif [ "${USE_PING}" = "1" ] || [ "${TR_STATE}" = "up" ]; then
		echo ok
	else
		echo unknown
	fi
}

# Cloudflare DNS: brings the record to the pending target; retried on every
# check until it succeeds, so a temporary API problem is caught up later.
cf_sync()
{
	[ -f "${CF_PENDING_FILE}" ] || return 0
	if [ "${FF_CF_ENABLED:-0}" != "1" ]; then
		rm -f "${CF_PENDING_FILE}"
		return 0
	fi
	_want=$(cat "${CF_PENDING_FILE}" 2>/dev/null)
	case "${_want}" in normal|failover) ;; *) rm -f "${CF_PENDING_FILE}"; return 0 ;; esac
	if _out=$(${HELPER} cfsync "${_want}" 2>&1); then
		rm -f "${CF_PENDING_FILE}"
		log "Cloudflare: ${_out}"
		case "${_out}" in *"now points"*) record_event dns "${_out}" ;; esac
	else
		log_err "Cloudflare DNS update (${_want}) failed, will retry: ${_out}"
		MESSAGE="${MESSAGE}${MESSAGE:+; }Cloudflare DNS update failed, retrying: ${_out}"
	fi
}

# Sends queued Pushover messages once OPNsense has really switched: a
# failover message waits until OPNsense reports the cable gateway as not
# online, a failback message until it is online again (so the message and
# the public IP reflect the line actually in use). After 5 minutes a message
# is sent anyway with a note. Undelivered messages are retried on every check;
# messages older than a day are dropped.
push_sync()
{
	[ -s "${PUSH_QUEUE_FILE}" ] || return 0
	if [ "${FF_PO_ENABLED:-0}" != "1" ]; then
		rm -f "${PUSH_QUEUE_FILE}"
		return 0
	fi
	_now=$(date +%s)
	_slept=""
	unset _rtif
	_cable=$(${HELPER} gwstatus 2>/dev/null | awk '{ print $1 }')
	_keep="${PUSH_QUEUE_FILE}.tmp"
	: > "${_keep}"
	_tab=$(printf '\t')
	while IFS="${_tab}" read -r _ts _kind _title _msg; do
		is_uint "${_ts}" || continue
		_age=$((_now - _ts))
		[ "${_age}" -gt 86400 ] && continue
		_ready=0
		case "${_kind}:${_cable}" in
		failover:none|failover:unknown|failover:) ;;
		failover:*) _ready=1 ;;
		failback:none) _ready=1 ;;
		esac
		# OPNsense already routes via the expected line (its default route
		# follows the gateway state), even if dpinger still reports loss/delay
		if [ "${_ready}" != "1" ]; then
			[ -n "${_rtif+x}" ] || _rtif=$(route -n get -inet default 2>/dev/null | awk '$1 == "interface:" { print $2 }')
			if [ "${_kind}" = "failback" ] && [ -n "${_rtif}" ] && [ "${_rtif}" = "${GW_DEVICE:-}" ]; then
				_ready=1
			elif [ "${_kind}" = "failover" ] && [ -n "${_rtif}" ] && [ -n "${BK_DEVICE:-}" ] && [ "${_rtif}" = "${BK_DEVICE}" ]; then
				_ready=1
			fi
		fi
		_note=""
		if [ "${_ready}" != "1" ]; then
			if [ "${_age}" -lt 300 ]; then
				printf '%s\t%s\t%s\t%s\n' "${_ts}" "${_kind}" "${_title}" "${_msg}" >> "${_keep}"
				continue
			fi
			_note=" (note: OPNsense did not report the expected gateway state within 5 minutes, current state: ${_cable:-unknown})"
		fi
		if [ "${_ready}" = "1" ] && [ -z "${_slept:-}" ]; then
			# let routing settle after OPNsense switched (once per run)
			_d=${FF_PO_DELAY:-5}
			is_uint "${_d}" || _d=5
			sleep "${_d}"
			_slept=1
		fi
		_when=$(date -r "${_ts}" '+%H:%M:%S')
		_pfib=""
		if [ "${_kind}" = "failover" ]; then
			_pfib=$(backup_fib)
		else
			_pfib=$(cable_fib)
		fi
		if _out=$(${HELPER} pushover "${_title}" "${_when}: ${_msg}${_note}" "${_kind}" "${_pfib}" 2>&1); then
			log "Pushover: sent '${_title}'"
		else
			log_err "Pushover notification failed, will retry: ${_out}"
			printf '%s\t%s\t%s\t%s\n' "${_ts}" "${_kind}" "${_title}" "${_msg}" >> "${_keep}"
		fi
	done < "${PUSH_QUEUE_FILE}"
	mv -f "${_keep}" "${PUSH_QUEUE_FILE}"
	[ -s "${PUSH_QUEUE_FILE}" ] || rm -f "${PUSH_QUEUE_FILE}"
}

# Side effects of a real switch: Cloudflare DNS and Pushover. Never in test
# mode. $1 = failover|failback, $2 = text for the notification.
notify_switch()
{
	[ "${FF_DRY_RUN}" = "1" ] && return 0
	if [ "${FF_CF_ENABLED:-0}" = "1" ]; then
		_t=normal
		[ "$1" = "failover" ] && _t=failover
		echo "${_t}" > "${CF_PENDING_FILE}"
		cf_sync
	fi
	if [ "${FF_PO_ENABLED:-0}" = "1" ]; then
		if [ "$1" = "failover" ] || [ "${FF_PO_FAILBACK:-1}" = "1" ]; then
			if [ "$1" = "failover" ]; then
				_title="Failover: backup line active"
			else
				_title="Cable line active again"
			fi
			printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "${_title}" "$(printf '%s' "$2" | tr -d '\t\n')" >> "${PUSH_QUEUE_FILE}"
			push_sync
		fi
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

# Checks that the plugin's firewall rules for the test pings are loaded:
# one "pass out quick route-to (<cable device> ...) proto icmp ... to <target>"
# per test address. Missing rules trigger a filter reload, at most every
# FW_RELOAD_PAUSE seconds. Result in FW_TEXT.
fw_check()
{
	_repair="${1:-1}"
	if [ "${FF_FW_RULES:-0}" != "1" ]; then
		FW_TEXT="off"
		return 0
	fi
	if [ -z "${GW_DEVICE:-}" ] || [ -z "${FF_PROBE_TARGETS:-}" ]; then
		FW_TEXT="unknown"
		return 0
	fi
	_all=$(pfctl -sr 2>/dev/null)
	_rules=$(printf '%s\n' "${_all}" | grep -n '^pass out' | grep 'proto icmp' | grep -F "route-to (${GW_DEVICE} ")
	_missing=""
	_first=""
	_n=0
	for _t in ${FF_PROBE_TARGETS}; do
		_n=$((_n + 1))
		_ln=$(printf '%s\n' "${_rules}" | grep -F " to ${_t} " | head -n 1 | cut -d: -f1)
		if [ -z "${_ln}" ]; then
			_missing="${_missing} ${_t}"
		elif [ -z "${_first}" ] || [ "${_ln}" -lt "${_first}" ]; then
			_first=${_ln}
		fi
	done
	if [ -z "${_missing}" ]; then
		FW_TEXT="ok (${_n} rules)"
		# another rule with route-to loaded before the plugin's rules could
		# still redirect the test pings: name it, so the user knows where to look
		_before=$(printf '%s\n' "${_all}" | head -n $((_first - 1)) | grep -E 'route-to|reply-to' | grep -vF "route-to (${GW_DEVICE} " | head -n 1)
		if [ -n "${_before}" ]; then
			_lbl=$(printf '%s' "${_before}" | sed -n 's/.* label "\([^"]*\)".*/\1/p')
			_descr=""
			[ -n "${_lbl}" ] && _descr=$(grep -F "label \"${_lbl}\"" /tmp/rules.debug 2>/dev/null | head -n 1 | sed -n 's/.*# *//p')
			FW_TEXT="warning: a rule with a gateway is loaded before the plugin's rules (${_descr:-$(printf '%s' "${_before}" | sed 's/ label "[^"]*"//; s/ ridentifier [0-9]*//' | cut -c1-120)}), check Firewall > Rules > Floating and plugins with own rules"
		fi
		return 0
	fi
	FW_TEXT="missing for${_missing}"
	[ "${_repair}" = "1" ] || return 0
	_last=$(cat "${FW_RELOAD_FILE}" 2>/dev/null)
	is_uint "${_last}" || _last=0
	if [ $(($(date +%s) - _last)) -ge ${FW_RELOAD_PAUSE} ]; then
		date +%s > "${FW_RELOAD_FILE}"
		log "firewall rules for the test pings missing for${_missing}, reloading the filter"
		configctl filter reload skip_alias >/dev/null 2>&1 &
		FW_TEXT="${FW_TEXT}, filter reload started"
	fi
	return 0
}

run_check()
{
	run_check_inner
	_rc=$?
	debug_record
	return ${_rc}
}

run_check_inner()
{
	MESSAGE=""
	# leftovers of checks that were killed hard (normally removed right away)
	find "${RUNDIR}" -maxdepth 1 -type d -name 'fritzfailover.??????' -mmin +10 -exec rm -rf {} + 2>/dev/null
	if ! load_config; then
		MESSAGE="configuration could not be read, nothing changed"
		log_err "unable to read configuration"
		write_state "unknown"
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

	fw_check

	# catch up DNS updates / notifications that failed earlier
	cf_sync
	push_sync

	if [ -f "${TEST_FILE}" ]; then
		_end=$(cat "${TEST_FILE}" 2>/dev/null)
		is_uint "${_end}" || _end=0
		_left=$((_end - $(date +%s)))
		if [ "${_left}" -gt 0 ]; then
			# keep measuring (shows that the cable line is still probed through
			# the cable while the firewall uses the backup), but no decisions
			tr064_check
			RECORD_STATS=1
			probe_ping
			RECORD_STATS=0
			MESSAGE="TEST FAILOVER active, no decisions until it ends (cable check: $(evaluate))"
			TEST_LEFT=${_left}
			write_state "test_failover"
			return 0
		fi
		# timer missed (e.g. killed): end the test here
		do_testfailover_end
		load_gateway || return 1
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
	_uptime=$(uptime_seconds)

	if [ "${_uptime}" -lt "${STARTUP_GRACE}" ]; then
		# just booted: measure, but do not count or switch yet
		_status="starting"
		MESSAGE="startup: measuring only for another $((STARTUP_GRACE - _uptime)) seconds (current result: ${_result})"
	elif [ "${_result}" = "unknown" ]; then
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
					if [ "${FF_DRY_RUN}" = "1" ]; then
						record_event sim_failback "$(event_detail)"
					else
						record_event failback "$(event_detail)"
						notify_switch failback "Cable line ${FF_GATEWAY} is healthy again, switched back. $(event_detail)"
					fi
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
					if [ "${FF_DRY_RUN}" = "1" ]; then
						record_event sim_failover "$(event_detail)"
					else
						record_event failover "$(event_detail)"
						notify_switch failover "Cable line ${FF_GATEWAY} is down, switched to the backup line. $(event_detail)"
					fi
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

# Unconditionally restores the normal monitor IP if the fake one is active.
do_restore()
{
	load_config || return 0
	load_gateway || return 0
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		log "restoring monitor ${FF_GOOD_MONITOR} on ${FF_GATEWAY}"
		record_event restore "normal monitor IP restored manually or on stop"
		FF_DRY_RUN=0
		apply_monitor "${FF_GOOD_MONITOR}" && notify_switch failback "Normal monitor IP restored on ${FF_GATEWAY}, switched back to the cable line."
	fi
	rm -f "${COUNTER_FILE}" "${TEST_FILE}"
	FAILS=0
	OKS=0
	MESSAGE="normal monitor IP active"
	write_state "stopped"
	return 0
}

# rc.d post-stop hook. Restoring is only done when the plugin will no longer
# manage the gateway (disabled, or test mode active). A plain restart ("Apply"
# in the GUI, reboot) keeps an active failover; the next start resumes it and
# switches back only once the cable line is really healthy.
do_stopped()
{
	if ! load_config; then
		log_err "monitor stopped, configuration unreadable, gateway left unchanged"
		return 0
	fi
	if [ "${FF_ENABLED}" != "1" ] || [ "${FF_DRY_RUN}" = "1" ] || [ -f "${TEST_FILE}" ]; then
		# a test failover must never outlive the monitor
		do_restore
		return 0
	fi
	load_gateway || return 0
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		log "monitor stopped, keeping the active failover on ${FF_GATEWAY}"
		MESSAGE="monitor stopped, failover kept (monitor IP ${GW_MONITOR}); start the service again or use 'Restore normal monitor IP'"
	else
		MESSAGE="monitor stopped"
	fi
	write_state "stopped"
	return 0
}

# Starts a test failover: the very same switch as a real failover. The fake
# monitor IP is written to the gateway, its dpinger restarted, and OPNsense's
# gateway watcher fails over natively. A detached timer ends the test after
# TEST_DURATION seconds with the very same switch back. Works in test mode
# too, because it is an explicit request by the user.
do_testfailover()
{
	if ! load_config || ! load_gateway; then
		printf '{"status":"failed","message":"configuration or gateway not readable"}\n'
		return 0
	fi
	if [ "${GW_PERSISTED}" != "1" ]; then
		printf '{"status":"failed","message":"%s"}\n' "$(json_escape "Gateway ${FF_GATEWAY} is not saved yet: open it once under System > Gateways and click Save.")"
		return 0
	fi
	if [ "${GW_MONITOR_DISABLED}" = "1" ]; then
		printf '{"status":"failed","message":"%s"}\n' "$(json_escape "Monitoring is disabled on gateway ${FF_GATEWAY}.")"
		return 0
	fi
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ] || [ -f "${TEST_FILE}" ]; then
		printf '{"status":"failed","message":"A failover is already active."}\n'
		return 0
	fi
	echo $(($(date +%s) + TEST_DURATION)) > "${TEST_FILE}"
	log "TEST FAILOVER started by the user for ${TEST_DURATION} seconds, setting monitor ${FF_BAD_MONITOR} on ${FF_GATEWAY}"
	record_event test_start "test failover for ${TEST_DURATION} seconds"
	FF_DRY_RUN=0
	if ! apply_monitor "${FF_BAD_MONITOR}"; then
		rm -f "${TEST_FILE}"
		printf '{"status":"failed","message":"could not change the monitor IP, see the system log"}\n'
		return 0
	fi
	notify_switch failover "TEST FAILOVER started by the user for ${TEST_DURATION} seconds on ${FF_GATEWAY}."
	/usr/sbin/daemon -f /bin/sh -c "sleep ${TEST_DURATION}; exec $0 testfailover-end"
	MESSAGE="TEST FAILOVER active, switching back in ${TEST_DURATION} seconds"
	TR_TEXT="-"
	PING_TEXT="-"
	TEST_LEFT=${TEST_DURATION}
	write_state "test_failover"
	printf '{"status":"ok","duration":%s,"message":"%s"}\n' "${TEST_DURATION}" "$(json_escape "Test failover started: monitor IP of ${FF_GATEWAY} set to ${FF_BAD_MONITOR}. OPNsense should switch to the backup gateway within the dpinger loss interval. Switching back automatically in ${TEST_DURATION} seconds.")"
}

# Ends a test failover with the very same switch back as a real recovery.
do_testfailover_end()
{
	[ -f "${TEST_FILE}" ] || return 0
	rm -f "${TEST_FILE}" "${COUNTER_FILE}"
	load_config || return 0
	load_gateway || return 0
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		log "TEST FAILOVER finished, restoring monitor ${FF_GOOD_MONITOR} on ${FF_GATEWAY}"
		record_event test_end "test failover finished"
		_dry=${FF_DRY_RUN}
		FF_DRY_RUN=0
		apply_monitor "${FF_GOOD_MONITOR}" && notify_switch failback "TEST FAILOVER finished on ${FF_GATEWAY}, switched back to the cable line."
		FF_DRY_RUN=${_dry}
	fi
	MESSAGE="test failover finished, switched back to cable"
	TR_TEXT="-"
	PING_TEXT="-"
	write_state "ok"
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
	FORCE_TR064=1
	fw_check 0
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
	if [ "${GW_PERSISTED}" != "1" ]; then
		MESSAGE="${MESSAGE} The gateway is not saved yet: open it once under System > Gateways and click Save, otherwise the plugin cannot change it."
	fi
	case "${FW_TEXT}" in
	missing*)
		MESSAGE="${MESSAGE} The firewall rules for the test pings are not loaded (${FW_TEXT}): click Apply or reload the firewall rules."
		;;
	esac
	if [ "${GW_MONITOR}" = "${FF_BAD_MONITOR}" ]; then
		MESSAGE="${MESSAGE} Failover is currently active."
	elif [ "${GW_MONITOR}" != "${FF_GOOD_MONITOR}" ]; then
		MESSAGE="${MESSAGE} Note: the gateway currently monitors ${GW_MONITOR}; after the first failover the plugin sets ${FF_GOOD_MONITOR}. Better set it yourself under System > Gateways."
	fi
	printf '{"status":"%s","gateway":"%s","device":"%s","monitor":"%s","tr064":"%s","ping":"%s","message":"%s","fwrules":"%s"}\n' \
	    "${_res}" "$(json_escape "${FF_GATEWAY}")" "$(json_escape "${GW_DEVICE}")" \
	    "$(json_escape "${GW_MONITOR}")" "$(json_escape "${TR_TEXT}")" \
	    "$(json_escape "${PING_TEXT}")" "$(json_escape "${MESSAGE}")" "$(json_escape "${FW_TEXT}")"
}

do_state()
{
	if [ ! -f "${STATE_FILE}" ]; then
		printf '{"status":"stopped"}\n'
		return 0
	fi
	_json=$(cat "${STATE_FILE}")
	if [ -f "${TEST_FILE}" ]; then
		# live countdown of a running test failover
		_end=$(cat "${TEST_FILE}" 2>/dev/null)
		is_uint "${_end}" || _end=0
		_left=$((_end - $(date +%s)))
		[ "${_left}" -lt 0 ] && _left=0
		_json=$(printf '%s\n' "${_json}" | sed "s/\"test_left\":[0-9]*/\"test_left\":${_left}/")
	elif ! { [ -f "${PIDFILE}" ] && pgrep -F "${PIDFILE}" >/dev/null 2>&1; }; then
		_json=$(printf '%s\n' "${_json}" | sed 's/^{"status":"[a-z_]*"/{"status":"stopped"/')
	fi
	printf '%s\n' "${_json}"
}

# Serialises all actions. lockf(1) from the base system holds the lock itself
# and closes the lock descriptor in the command it runs, so long-lived
# processes started from there (dpinger via pluginctl, the test failover
# timer) can never inherit and keep the lock.
# Debug mode ---------------------------------------------------------------

debug_active()
{
	_until=$(cat "${DEBUG_UNTIL_FILE}" 2>/dev/null)
	is_uint "${_until}" || return 1
	if [ "$(date +%s)" -ge "${_until}" ]; then
		rm -f "${DEBUG_UNTIL_FILE}" "${DEBUG_LAST}"
		printf '%s === debug mode ended automatically ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "${DEBUG_LOG}"
		log "debug mode ended automatically"
		return 1
	fi
	return 0
}

# all New* values of one UPnP action as "key=value key=value"
upnp_values()
{
	soap_call "$1" "$2" 0 "$3" | tr -d '\r' | tr '<' '\n' |
	    sed -n 's/^New\([A-Za-z0-9_]*\)>\(.*\)$/\1=\2/p' |
	    grep -v '^ExternalIPAddress=' | tr '\n' ' ' | sed 's/ $//'
}

# One line per check with everything needed to analyse an outage. Lines in
# which a relevant value changed against the previous check start with "*".
debug_record()
{
	# scheduled start reached?
	_at=$(cat "${DEBUG_AT_FILE}" 2>/dev/null)
	if is_uint "${_at}" && [ "$(date +%s)" -ge "${_at}" ]; then
		rm -f "${DEBUG_AT_FILE}"
		do_debug start scheduled
	fi
	debug_active || return 0
	[ -n "${FF_FRITZBOX_IP:-}" ] || return 0
	_fb=$(upnp_values "${IGD_SERVICE}" "${IGD_URL_PATH}" GetStatusInfo)
	_ln=$(upnp_values "${IGD_LINK_SERVICE}" "${IGD_LINK_PATH}" GetCommonLinkProperties)
	_gw=$(${HELPER} gwdebug 2>/dev/null)
	_rt=$(route -n get -inet default 2>/dev/null | awk '$1 == "gateway:" { g = $2 } $1 == "interface:" { i = $2 } END { print g " via " i }')
	_key="${LAST_STATUS}|${GW_MONITOR:-}|$(printf '%s' "${_fb}" | sed 's/Uptime=[0-9]*//')|$(printf '%s' "${_ln}" | sed 's/MaxBitRate=[0-9]*//g')|$(printf '%s' "${_gw}" | sed 's/ loss=[^ ;]*//g; s/ delay=[^ ;]*//g')|$(printf '%s' "${PING_TEXT:-}" | sed 's/ (via.*//')|${_rt}"
	_mark=" "
	[ "${_key}" != "$(cat "${DEBUG_LAST}" 2>/dev/null)" ] && _mark="*"
	printf '%s' "${_key}" > "${DEBUG_LAST}"
	printf '%s %s status=%s fails=%s oks=%s monitor=%s | fritzbox: %s | link: %s | ping: %s | fw rules: %s | opnsense: %s | default route: %s | info: %s\n' \
	    "${_mark}" "$(date '+%Y-%m-%d %H:%M:%S')" "${LAST_STATUS:-?}" "${FAILS:-?}" "${OKS:-?}" "${GW_MONITOR:-?}" \
	    "${_fb:-no answer}" "${_ln:-no answer}" "${PING_TEXT:--}" "${FW_TEXT:--}" "${_gw:-?}" "${_rt:-?}" "${MESSAGE:-}" >> "${DEBUG_LOG}"
	[ -f "${DEBUG_VERBOSE_FILE}" ] && debug_verbose
	# size limit: keep the newer half
	_size=$(stat -f %z "${DEBUG_LOG}" 2>/dev/null || wc -c < "${DEBUG_LOG}")
	if is_uint "${_size}" && [ "${_size}" -gt "${DEBUG_MAX_BYTES}" ]; then
		tail -c $((DEBUG_MAX_BYTES / 2)) "${DEBUG_LOG}" > "${DEBUG_LOG}.tmp" && mv -f "${DEBUG_LOG}.tmp" "${DEBUG_LOG}"
	fi
	chmod 600 "${DEBUG_LOG}" 2>/dev/null
}

# Verbose debug: pf rules with route-to/reply-to, the plugin's routing tables
# and the main default route are written when they changed; the pf states of
# the test addresses on every check.
debug_verbose()
{
	_ts=$(date '+%Y-%m-%d %H:%M:%S')
	_snap=$(
		echo "    pf rules with route-to/reply-to:"
		pfctl -sr 2>/dev/null | grep -E 'route-to|reply-to' | sed 's/ label "[^"]*"//g; s/ ridentifier [0-9]*//g; s/^/      /'
		_b=$(cat "${FIB_BASE_FILE}" 2>/dev/null)
		for _f in 0 ${_b:+${_b} $((_b + 1))}; do
			echo "    routing table fib ${_f} (net.fibs=$(sysctl -n net.fibs 2>/dev/null)):"
			setfib "${_f}" netstat -rn -f inet 2>/dev/null | awk 'NR > 3 && ($1 == "default" || $3 ~ /S/) { print "      " $1 " " $2 " " $3 " " $NF }'
		done
	)
	_sum=$(printf '%s' "${_snap}" | md5 2>/dev/null || printf '%s' "${_snap}" | cksum)
	if [ "${_sum}" != "$(cat "${DEBUG_VERBOSE_LAST}" 2>/dev/null)" ]; then
		printf '%s' "${_sum}" > "${DEBUG_VERBOSE_LAST}"
		printf '* %s verbose: firewall/routing changed\n%s\n' "${_ts}" "${_snap}" >> "${DEBUG_LOG}"
	fi
	_states=""
	for _t in ${FF_PROBE_TARGETS:-}; do
		_st=$(pfctl -ss 2>/dev/null | grep -F " ${_t}:" | grep icmp | head -n 4 | sed 's/  */ /g' | tr '\n' ';')
		_states="${_states} ${_t}: ${_st:-no state};"
	done
	printf '  %s verbose: pf states:%s\n' "${_ts}" "${_states}" >> "${DEBUG_LOG}"
}

do_debug()
{
	mkdir -p "${HISTORY_DIR}" 2>/dev/null
	case "$1" in
	schedule)
		if is_uint "${2:-}" && [ "$2" -gt "$(date +%s)" ]; then
			echo "$2" > "${DEBUG_AT_FILE}"
			log "debug mode scheduled for $(date -r "$2" '+%Y-%m-%d %H:%M')"
		fi
		;;
	unschedule)
		rm -f "${DEBUG_AT_FILE}"
		;;
	start)
		rm -f "${DEBUG_AT_FILE}"
		_until=$(($(date +%s) + DEBUG_HOURS * 3600))
		echo "${_until}" > "${DEBUG_UNTIL_FILE}"
		rm -f "${DEBUG_LAST}" "${DEBUG_VERBOSE_LAST}"
		_ver=$(sed -n 's/.*"product_version": *"\([^"]*\)".*/\1/p' /usr/local/opnsense/version/fritzbox-failover 2>/dev/null)
		load_config >/dev/null 2>&1
		{
			printf '%s === debug mode started%s, ends %s (plugin %s, %s) ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
			    "$([ "${2:-}" = "scheduled" ] && echo ' (scheduled)')" \
			    "$(date -r "${_until}" '+%Y-%m-%d %H:%M')" "${_ver:-?}" "$(/usr/local/sbin/opnsense-version 2>/dev/null)"
			printf '    settings: mode=%s gateway=%s backup=%s fritzbox=%s targets=%s interval=%ss fail=%s recover=%s test_mode=%s\n' \
			    "${FF_CHECK_MODE:-?}" "${FF_GATEWAY:-?}" "${FF_BACKUP_GATEWAY:--}" "${FF_FRITZBOX_IP:-?}" \
			    "${FF_PROBE_TARGETS:-?}" "${FF_CHECK_INTERVAL:-?}" "${FF_FAIL_THRESHOLD:-?}" "${FF_RECOVER_THRESHOLD:-?}" "${FF_DRY_RUN:-?}"
			printf '    firewall rules for test pings: %s, verbose logging: %s\n' "$([ "${FF_FW_RULES:-0}" = "1" ] && echo on || echo off)" "$([ -f "${DEBUG_VERBOSE_FILE}" ] && echo on || echo off)"
			printf '    legend: "*" = a relevant value changed since the previous check\n'
		} >> "${DEBUG_LOG}"
		chmod 600 "${DEBUG_LOG}"
		log "debug mode started for ${DEBUG_HOURS} hours"
		;;
	stop)
		if [ -f "${DEBUG_UNTIL_FILE}" ]; then
			rm -f "${DEBUG_UNTIL_FILE}" "${DEBUG_LAST}"
			printf '%s === debug mode stopped by the user ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "${DEBUG_LOG}"
			log "debug mode stopped"
		fi
		;;
	clear)
		rm -f "${DEBUG_LOG}" "${DEBUG_LAST}" "${DEBUG_VERBOSE_LAST}"
		;;
	verbose)
		if [ "${2:-}" = "on" ]; then
			touch "${DEBUG_VERBOSE_FILE}"
			rm -f "${DEBUG_VERBOSE_LAST}"
			[ -f "${DEBUG_UNTIL_FILE}" ] && printf '%s === verbose logging on ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "${DEBUG_LOG}"
		else
			[ -f "${DEBUG_VERBOSE_FILE}" ] && [ -f "${DEBUG_UNTIL_FILE}" ] && \
			    printf '%s === verbose logging off ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "${DEBUG_LOG}"
			rm -f "${DEBUG_VERBOSE_FILE}" "${DEBUG_VERBOSE_LAST}"
		fi
		;;
	status)
		_until=$(cat "${DEBUG_UNTIL_FILE}" 2>/dev/null)
		is_uint "${_until}" || _until=0
		[ "${_until}" -gt "$(date +%s)" ] || _until=0
		_size=0
		[ -f "${DEBUG_LOG}" ] && _size=$(stat -f %z "${DEBUG_LOG}" 2>/dev/null || wc -c < "${DEBUG_LOG}")
		_at=$(cat "${DEBUG_AT_FILE}" 2>/dev/null)
		is_uint "${_at}" || _at=0
		printf '{"active":%s,"until":%s,"scheduled":%s,"size":%s,"verbose":%s}\n' "$([ "${_until}" -gt 0 ] && echo true || echo false)" "${_until}" "${_at}" "$(echo ${_size} | tr -dc 0-9)" "$([ -f "${DEBUG_VERBOSE_FILE}" ] && echo true || echo false)"
		;;
	log)
		[ -f "${DEBUG_LOG}" ] && tail -c 10485760 "${DEBUG_LOG}"
		;;
	esac
	return 0
}

# Decides whether the monitor process may restart itself now (self-healing):
# enabled, in the configured hour (and on Sunday for weekly), at most once per
# slot, and only while everything is fine and nothing is pending. Statistics
# and history are kept; daemon(8) starts the process again.
selfheal_due()
{
	[ "${FF_SELFHEAL:-0}" = "1" ] || return 1
	is_uint "${FF_SELFHEAL_HOUR:-}" || return 1
	[ "$(date +%H | sed 's/^0//')" = "${FF_SELFHEAL_HOUR}" ] || return 1
	if [ "${FF_SELFHEAL_INTERVAL}" = "weekly" ]; then
		[ "$(date +%u)" = "7" ] || return 1
	fi
	# once per slot: not again within the last 20 hours
	_last=$(cat "${SELFHEAL_FILE}" 2>/dev/null)
	is_uint "${_last}" && [ $(($(date +%s) - _last)) -lt 72000 ] && return 1
	# only while everything is fine and nothing is pending
	grep -q '^{"status":"ok"' "${STATE_FILE}" 2>/dev/null || return 1
	[ -f "${TEST_FILE}" ] && return 1
	[ -s "${PUSH_QUEUE_FILE}" ] && return 1
	[ -f "${CF_PENDING_FILE}" ] && return 1
	return 0
}

locked()
{
	/usr/bin/lockf -k -s -t 60 "${LOCK_FILE}" "$0" "$@"
}

case "${1:-}" in
run)
	log "monitor started"
	# fresh start: no counters from a previous run or mode, retry TR-064 login
	rm -f "${COUNTER_FILE}" "${BACKOFF_FILE}"
	trap 'log "monitor stopped"; exit 0' INT TERM
	while :; do
		# run in the background so a stop request is handled immediately
		locked check-locked &
		wait $! || true
		_interval=10
		if load_config >/dev/null 2>&1; then
			_interval=${FF_CHECK_INTERVAL}
			if selfheal_due; then
				mkdir -p "${HISTORY_DIR}" 2>/dev/null
				date +%s > "${SELFHEAL_FILE}"
				# flush runtime files, keep statistics and history
				rm -f "${COUNTER_FILE}" "${BACKOFF_FILE}" "${STATE_FILE}"
				# daily clean-up of the debug log, but never during a running
				# debug session (it may span the self-healing hour)
				if ! debug_active; then
					rm -f "${DEBUG_LOG}" "${DEBUG_LAST}"
				fi
				find "${RUNDIR}" -maxdepth 1 -type d -name 'fritzfailover.??????' -exec rm -rf {} + 2>/dev/null
				log "self-healing: restarting the monitor process (statistics and history are kept)"
				# daemon(8) starts a fresh process
				exit 0
			fi
		fi
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
stopped)
	locked stopped-locked
	;;
stopped-locked)
	do_stopped
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
debug)
	do_debug "${2:-status}" "${3:-}"
	;;
testfailover)
	locked testfailover-locked
	;;
testfailover-locked)
	do_testfailover
	;;
testfailover-end)
	locked testfailover-end-locked
	;;
testfailover-end-locked)
	do_testfailover_end
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
	echo "usage: $0 run|check|test|state|stopped|restore|resetstats|testfailover|debug start|stop|clear|status|log" >&2
	exit 2
	;;
esac
