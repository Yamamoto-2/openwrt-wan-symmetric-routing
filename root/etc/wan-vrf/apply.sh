#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/core.sh"

CHAIN_PREROUTING="WAN_VRF_PREROUTING"
CHAIN_OUTPUT="WAN_VRF_OUTPUT"

ACTION="${1:-apply}"
EVENT_CLASS="${2:-}"
EVENT_NAME="${3:-}"

MODE=""
FAST_WAN=""
PUBLIC_WAN=""
LAN_NETWORK=""
ROUTE_TABLE_PUBLIC=""
FWMARK_PUBLIC=""
RULE_PRIORITY=""
PUBLIC_DEV=""
LAN_DEV=""
FAST_DEV=""
PUBLIC_GW=""
MARK_SPEC=""

load_config() {
	MODE="$(wan_vrf_get_cfg mode fwmark)"
	FAST_WAN="$(wan_vrf_get_cfg fast_wan wan10g)"
	PUBLIC_WAN="$(wan_vrf_get_cfg public_wan wan_pppoe)"
	LAN_NETWORK="$(wan_vrf_get_cfg lan_network lan)"
	ROUTE_TABLE_PUBLIC="$(wan_vrf_get_cfg route_table_public 100)"
	FWMARK_PUBLIC="$(wan_vrf_get_cfg fwmark_public 0x100)"
	RULE_PRIORITY="$(wan_vrf_get_cfg rule_priority 10000)"
	MARK_SPEC="${FWMARK_PUBLIC}/${FWMARK_PUBLIC}"
}

remove_jump_rule() {
	local chain parent

	chain="$1"
	parent="$2"

	while iptables -t mangle -D "$parent" -j "$chain" >/dev/null 2>&1; do
		:
	done
}

reset_chain() {
	local chain

	chain="$1"
	iptables -t mangle -N "$chain" >/dev/null 2>&1 || true
	iptables -t mangle -F "$chain" >/dev/null 2>&1 || return 1
}

flush_mangle_rules() {
	remove_jump_rule "$CHAIN_PREROUTING" PREROUTING
	remove_jump_rule "$CHAIN_OUTPUT" OUTPUT

	iptables -t mangle -F "$CHAIN_PREROUTING" >/dev/null 2>&1 || true
	iptables -t mangle -X "$CHAIN_PREROUTING" >/dev/null 2>&1 || true
	iptables -t mangle -F "$CHAIN_OUTPUT" >/dev/null 2>&1 || true
	iptables -t mangle -X "$CHAIN_OUTPUT" >/dev/null 2>&1 || true
}

flush_policy_routing() {
	while ip -4 rule del fwmark "$MARK_SPEC" lookup "$ROUTE_TABLE_PUBLIC" priority "$RULE_PRIORITY" >/dev/null 2>&1; do
		:
	done

	ip -4 route flush table "$ROUTE_TABLE_PUBLIC" >/dev/null 2>&1 || true
}

flush_state() {
	rm -f "$WAN_VRF_STATE_FILE"
}

flush_all() {
	flush_mangle_rules
	flush_policy_routing
	flush_state
}

resolve_runtime() {
	PUBLIC_DEV="$(wan_vrf_get_iface_device "$PUBLIC_WAN")"
	LAN_DEV="$(wan_vrf_get_iface_device "$LAN_NETWORK")"
	FAST_DEV="$(wan_vrf_get_iface_device "$FAST_WAN")"
	PUBLIC_GW="$(wan_vrf_get_gateway_for_device "$PUBLIC_DEV")"

	[ -n "$PUBLIC_DEV" ] || {
		wan_vrf_log err "Unable to resolve device for public_wan=${PUBLIC_WAN}"
		return 1
	}

	[ -n "$LAN_DEV" ] || {
		wan_vrf_log err "Unable to resolve device for lan_network=${LAN_NETWORK}"
		return 1
	}

	if ! wan_vrf_iface_is_up "$PUBLIC_WAN"; then
		wan_vrf_log notice "Public WAN ${PUBLIC_WAN} is currently down; rules flushed"
		return 2
	fi

	return 0
}

apply_mangle_rules() {
	reset_chain "$CHAIN_PREROUTING" || return 1
	reset_chain "$CHAIN_OUTPUT" || return 1

	iptables -t mangle -A "$CHAIN_PREROUTING" -i "$LAN_DEV" -j CONNMARK --restore-mark || return 1
	iptables -t mangle -A "$CHAIN_PREROUTING" -i "$PUBLIC_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-xmark "$MARK_SPEC" || return 1
	iptables -t mangle -A "$CHAIN_OUTPUT" -j CONNMARK --restore-mark || return 1

	remove_jump_rule "$CHAIN_PREROUTING" PREROUTING
	remove_jump_rule "$CHAIN_OUTPUT" OUTPUT
	iptables -t mangle -I PREROUTING 1 -j "$CHAIN_PREROUTING" || return 1
	iptables -t mangle -I OUTPUT 1 -j "$CHAIN_OUTPUT" || return 1
}

apply_policy_routing() {
	flush_policy_routing

	if [ -n "$PUBLIC_GW" ]; then
		ip -4 route replace table "$ROUTE_TABLE_PUBLIC" default via "$PUBLIC_GW" dev "$PUBLIC_DEV" onlink || return 1
	else
		ip -4 route replace table "$ROUTE_TABLE_PUBLIC" default dev "$PUBLIC_DEV" || return 1
	fi

	ip -4 rule add fwmark "$MARK_SPEC" lookup "$ROUTE_TABLE_PUBLIC" priority "$RULE_PRIORITY" || return 1
}

write_state() {
	{
		printf 'last_apply=%s\n' "$(wan_vrf_now)"
		printf 'mode=%s\n' "$MODE"
		printf 'fast_wan=%s\n' "$FAST_WAN"
		printf 'fast_dev=%s\n' "$FAST_DEV"
		printf 'public_wan=%s\n' "$PUBLIC_WAN"
		printf 'public_dev=%s\n' "$PUBLIC_DEV"
		printf 'public_gateway=%s\n' "$PUBLIC_GW"
		printf 'lan_network=%s\n' "$LAN_NETWORK"
		printf 'lan_dev=%s\n' "$LAN_DEV"
		printf 'route_table_public=%s\n' "$ROUTE_TABLE_PUBLIC"
		printf 'fwmark_public=%s\n' "$FWMARK_PUBLIC"
		printf 'rule_priority=%s\n' "$RULE_PRIORITY"
		printf 'event=%s %s\n' "$EVENT_CLASS" "$EVENT_NAME"
		printf 'default_route_dev=%s\n' "$(wan_vrf_get_default_route_device)"
	} >"$WAN_VRF_STATE_FILE"
}

main() {
	local rc

	wan_vrf_require_commands ip iptables jsonfilter ubus uci || exit 1
	load_config

	case "$ACTION" in
		apply|reload)
			:
		;;
		hotplug)
			ACTION="apply"
		;;
		flush|stop)
			flush_all
			wan_vrf_log notice "WAN symmetric routing rules flushed"
			exit 0
		;;
		*)
			wan_vrf_log err "Unsupported action: ${ACTION}"
			exit 1
		;;
	esac

	if [ "$(wan_vrf_get_cfg enabled 0)" != "1" ]; then
		flush_all
		wan_vrf_debug "Configuration disabled; nothing to apply"
		exit 0
	fi

	if [ "$MODE" != "fwmark" ]; then
		flush_all
		wan_vrf_log err "Mode ${MODE} is not implemented yet; only fwmark is supported"
		exit 1
	fi

	resolve_runtime
	rc="$?"

	case "$rc" in
		0)
			:
		;;
		2)
			flush_all
			exit 0
		;;
		*)
			flush_all
			exit 1
		;;
	esac

	apply_mangle_rules || {
		flush_all
		wan_vrf_log err "Failed to install mangle rules"
		exit 1
	}

	apply_policy_routing || {
		flush_all
		wan_vrf_log err "Failed to install policy routing"
		exit 1
	}

	write_state
	wan_vrf_log notice "Applied WAN symmetric routing for public_wan=${PUBLIC_WAN} (${PUBLIC_DEV}) via table ${ROUTE_TABLE_PUBLIC}"
}

main "$@"
