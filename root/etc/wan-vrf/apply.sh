#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/core.sh"

CHAIN_PREROUTING="WAN_VRF_PREROUTING"
CHAIN_OUTPUT="WAN_VRF_OUTPUT"

ACTION="${1:-apply}"
EVENT_CLASS="${2:-}"
EVENT_NAME="${3:-}"

MODE=""
PUBLIC_MODE=""
PUBLIC_ZONE=""
PUBLIC_IFACES=""
LAN_MODE=""
LAN_ZONE=""
LAN_IFACES=""
LEGACY_LAN_NETWORK=""
ROUTE_TABLE_BASE=""
FWMARK_BASE=""
FWMARK_BASE_DEC="0"
RULE_PRIORITY_BASE=""
LAN_ZONE_NETWORKS=""
LAN_ZONE_DEVICES=""
LAN_TARGETS=""
LAN_MEMBERS=""
LAN_MEMBER_COUNT=0
SEEN_LAN_DEVICES=""
PUBLIC_ZONE_NETWORKS=""
PUBLIC_ZONE_DEVICES=""
PUBLIC_TARGETS=""
ACTIVE_MEMBERS=""
ACTIVE_MEMBER_COUNT=0
PREVIOUS_MEMBERS=""
SEEN_PUBLIC_DEVICES=""
RULE_FWMARK_MASK="0xffffffff"

load_config() {
	MODE="$(wan_vrf_get_cfg mode fwmark)"
	PUBLIC_MODE="$(wan_vrf_get_cfg public_mode zone)"
	PUBLIC_ZONE="$(wan_vrf_get_cfg public_zone wan)"
	PUBLIC_IFACES="$(wan_vrf_get_cfg public_ifaces '')"
	LAN_MODE="$(wan_vrf_get_cfg lan_mode '')"
	LAN_ZONE="$(wan_vrf_get_cfg lan_zone lan)"
	LAN_IFACES="$(wan_vrf_get_cfg lan_ifaces '')"
	LEGACY_LAN_NETWORK="$(wan_vrf_get_cfg lan_network '')"
	ROUTE_TABLE_BASE="$(wan_vrf_get_cfg route_table_public 100)"
	FWMARK_BASE="$(wan_vrf_get_cfg fwmark_public 0x100)"
	FWMARK_BASE_DEC="$((FWMARK_BASE))"
	RULE_PRIORITY_BASE="$(wan_vrf_get_cfg rule_priority 10000)"

	if [ -z "$LAN_MODE" ]; then
		if [ -n "$LEGACY_LAN_NETWORK" ]; then
			LAN_MODE="iface_list"
		else
			LAN_MODE="zone"
		fi
	fi

	if [ "$LAN_MODE" = "iface_list" ] && [ -z "$LAN_IFACES" ] && [ -n "$LEGACY_LAN_NETWORK" ]; then
		LAN_IFACES="$LEGACY_LAN_NETWORK"
	fi
}

append_active_member() {
	local line

	line="$1"
	if [ -n "$ACTIVE_MEMBERS" ]; then
		ACTIVE_MEMBERS="${ACTIVE_MEMBERS}
${line}"
	else
		ACTIVE_MEMBERS="$line"
	fi
	ACTIVE_MEMBER_COUNT=$((ACTIVE_MEMBER_COUNT + 1))
}

append_lan_member() {
	local line

	line="$1"
	if [ -n "$LAN_MEMBERS" ]; then
		LAN_MEMBERS="${LAN_MEMBERS}
${line}"
	else
		LAN_MEMBERS="$line"
	fi
	LAN_MEMBER_COUNT=$((LAN_MEMBER_COUNT + 1))
}

member_device_seen() {
	case " ${SEEN_PUBLIC_DEVICES} " in
		*" $1 "*)
			return 0
		;;
		*)
			return 1
		;;
	esac
}

lan_device_seen() {
	case " ${SEEN_LAN_DEVICES} " in
		*" $1 "*)
			return 0
		;;
		*)
			return 1
		;;
	esac
}

add_lan_iface_member() {
	local iface dev up line

	iface="$1"
	dev="$(wan_vrf_get_iface_device "$iface")"
	up="$(wan_vrf_get_iface_field "$iface" up)"

	[ -n "$dev" ] || {
		wan_vrf_debug "Skipping LAN iface ${iface}: no device"
		return 1
	}

	wan_vrf_device_exists "$dev" || {
		wan_vrf_debug "Skipping LAN iface ${iface}: device ${dev} missing"
		return 1
	}

	[ "$up" = "true" ] || {
		wan_vrf_debug "Skipping LAN iface ${iface}: down"
		return 1
	}

	lan_device_seen "$dev" && return 1

	line="iface|${iface}|${dev}"
	append_lan_member "$line"
	SEEN_LAN_DEVICES="${SEEN_LAN_DEVICES} ${dev}"
	return 0
}

add_lan_device_member() {
	local dev line

	dev="$1"
	wan_vrf_device_exists "$dev" || {
		wan_vrf_debug "Skipping LAN device ${dev}: link missing"
		return 1
	}

	lan_device_seen "$dev" && return 1

	line="device|${dev}|${dev}"
	append_lan_member "$line"
	SEEN_LAN_DEVICES="${SEEN_LAN_DEVICES} ${dev}"
	return 0
}

add_iface_member() {
	local iface dev up proto ipv4_addr gateway mark table priority line

	iface="$1"
	dev="$(wan_vrf_get_iface_device "$iface")"
	up="$(wan_vrf_get_iface_field "$iface" up)"
	proto="$(wan_vrf_get_iface_field "$iface" proto)"
	ipv4_addr="$(wan_vrf_get_iface_ipv4_address "$iface")"

	[ -n "$dev" ] || {
		wan_vrf_debug "Skipping public iface ${iface}: no device"
		return 1
	}

	wan_vrf_device_exists "$dev" || {
		wan_vrf_debug "Skipping public iface ${iface}: device ${dev} missing"
		return 1
	}

	[ "$up" = "true" ] || {
		wan_vrf_debug "Skipping public iface ${iface}: down"
		return 1
	}

	member_device_seen "$dev" && return 1

	[ -n "$ipv4_addr" ] || {
		wan_vrf_debug "Skipping public iface ${iface}: no IPv4 address"
		return 1
	}

	case "$proto" in
		pppoe|ppp|pptp|l2tp)
			gateway=""
		;;
		*)
			gateway="$(wan_vrf_sanitize_ipv4_gateway "$(wan_vrf_get_iface_default_gateway "$iface")")"
			[ -n "$gateway" ] || gateway="$(wan_vrf_sanitize_ipv4_gateway "$(wan_vrf_get_gateway_for_device "$dev")")"
		;;
	esac

	mark="$(printf '0x%x' $((FWMARK_BASE_DEC + ACTIVE_MEMBER_COUNT)))"
	table=$((ROUTE_TABLE_BASE + ACTIVE_MEMBER_COUNT))
	priority=$((RULE_PRIORITY_BASE + ACTIVE_MEMBER_COUNT))
	line="iface|${iface}|${dev}|${mark}|${table}|${priority}|${gateway}"

	append_active_member "$line"
	SEEN_PUBLIC_DEVICES="${SEEN_PUBLIC_DEVICES} ${dev}"
	return 0
}

add_device_member() {
	local dev gateway mark table priority line

	dev="$1"
	wan_vrf_device_exists "$dev" || {
		wan_vrf_debug "Skipping public device ${dev}: link missing"
		return 1
	}

	wan_vrf_device_has_ipv4_default_route "$dev" || {
		wan_vrf_debug "Skipping public device ${dev}: no IPv4 default route"
		return 1
	}

	member_device_seen "$dev" && return 1

	gateway="$(wan_vrf_sanitize_ipv4_gateway "$(wan_vrf_get_gateway_for_device "$dev")")"
	mark="$(printf '0x%x' $((FWMARK_BASE_DEC + ACTIVE_MEMBER_COUNT)))"
	table=$((ROUTE_TABLE_BASE + ACTIVE_MEMBER_COUNT))
	priority=$((RULE_PRIORITY_BASE + ACTIVE_MEMBER_COUNT))
	line="device|${dev}|${dev}|${mark}|${table}|${priority}|${gateway}"

	append_active_member "$line"
	SEEN_PUBLIC_DEVICES="${SEEN_PUBLIC_DEVICES} ${dev}"
	return 0
}

load_previous_members() {
	local line entry

	PREVIOUS_MEMBERS=""
	[ -f "$WAN_VRF_STATE_FILE" ] || return 0

	while IFS= read -r line; do
		case "$line" in
			member=*)
				entry="${line#member=}"
				if [ -n "$PREVIOUS_MEMBERS" ]; then
					PREVIOUS_MEMBERS="${PREVIOUS_MEMBERS}
${entry}"
				else
					PREVIOUS_MEMBERS="$entry"
				fi
			;;
		esac
	done < "$WAN_VRF_STATE_FILE"
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

flush_member_policy() {
	local members kind name dev mark table priority gateway

	members="$1"
	[ -n "$members" ] || return 0

	printf '%s\n' "$members" | while IFS='|' read -r kind name dev mark table priority gateway; do
		[ -n "$mark" ] || continue

		while ip -4 rule del fwmark "${mark}/${RULE_FWMARK_MASK}" lookup "$table" priority "$priority" >/dev/null 2>&1; do
			:
		done

		ip -4 route flush table "$table" >/dev/null 2>&1 || true
	done
}

flush_policy_routing() {
	flush_member_policy "$PREVIOUS_MEMBERS"
	flush_member_policy "$ACTIVE_MEMBERS"
}

flush_state() {
	rm -f "$WAN_VRF_STATE_FILE"
}

flush_all() {
	flush_mangle_rules
	flush_policy_routing
	flush_state
}

resolve_lan_runtime() {
	local iface device

	LAN_MEMBERS=""
	LAN_MEMBER_COUNT=0
	SEEN_LAN_DEVICES=""
	LAN_ZONE_NETWORKS=""
	LAN_ZONE_DEVICES=""
	LAN_TARGETS=""

	case "$LAN_MODE" in
		zone)
			LAN_ZONE_NETWORKS="$(wan_vrf_get_firewall_zone_networks "$LAN_ZONE")"
			LAN_ZONE_DEVICES="$(wan_vrf_get_firewall_zone_devices "$LAN_ZONE")"

			if [ -n "$LAN_ZONE_NETWORKS" ]; then
				LAN_TARGETS="$LAN_ZONE_NETWORKS"
			fi

			if [ -n "$LAN_ZONE_DEVICES" ]; then
				if [ -n "$LAN_TARGETS" ]; then
					LAN_TARGETS="${LAN_TARGETS} ${LAN_ZONE_DEVICES}"
				else
					LAN_TARGETS="$LAN_ZONE_DEVICES"
				fi
			fi

			[ -n "$LAN_TARGETS" ] || {
				wan_vrf_log err "Unable to resolve any members from lan_zone=${LAN_ZONE}"
				return 1
			}

			for iface in $LAN_ZONE_NETWORKS; do
				add_lan_iface_member "$iface"
			done

			for device in $LAN_ZONE_DEVICES; do
				add_lan_device_member "$device"
			done

			[ "$LAN_MEMBER_COUNT" -gt 0 ] || {
				wan_vrf_log err "No active LAN members found in lan_zone=${LAN_ZONE}"
				return 1
			}
		;;
		iface_list)
			LAN_TARGETS="$LAN_IFACES"
			[ -n "$LAN_TARGETS" ] || {
				wan_vrf_log err "lan_mode=iface_list requires lan_ifaces"
				return 1
			}

			for iface in $LAN_TARGETS; do
				add_lan_iface_member "$iface"
			done

			[ "$LAN_MEMBER_COUNT" -gt 0 ] || {
				wan_vrf_log err "No active LAN members found in lan_ifaces=${LAN_IFACES}"
				return 1
			}
		;;
		*)
			wan_vrf_log err "Unsupported lan_mode=${LAN_MODE}; expected zone or iface_list"
			return 1
		;;
	esac

	return 0
}

resolve_runtime() {
	local iface device

	ACTIVE_MEMBERS=""
	ACTIVE_MEMBER_COUNT=0
	SEEN_PUBLIC_DEVICES=""
	PUBLIC_ZONE_NETWORKS=""
	PUBLIC_ZONE_DEVICES=""
	PUBLIC_TARGETS=""

	resolve_lan_runtime || return 1

	case "$PUBLIC_MODE" in
		zone)
			PUBLIC_ZONE_NETWORKS="$(wan_vrf_get_firewall_zone_networks "$PUBLIC_ZONE")"
			PUBLIC_ZONE_DEVICES="$(wan_vrf_get_firewall_zone_devices "$PUBLIC_ZONE")"

			if [ -n "$PUBLIC_ZONE_NETWORKS" ]; then
				PUBLIC_TARGETS="$PUBLIC_ZONE_NETWORKS"
			fi

			if [ -n "$PUBLIC_ZONE_DEVICES" ]; then
				if [ -n "$PUBLIC_TARGETS" ]; then
					PUBLIC_TARGETS="${PUBLIC_TARGETS} ${PUBLIC_ZONE_DEVICES}"
				else
					PUBLIC_TARGETS="$PUBLIC_ZONE_DEVICES"
				fi
			fi

			[ -n "$PUBLIC_TARGETS" ] || {
				wan_vrf_log err "Unable to resolve any members from public_zone=${PUBLIC_ZONE}"
				return 1
			}

			for iface in $PUBLIC_ZONE_NETWORKS; do
				add_iface_member "$iface"
			done

			for device in $PUBLIC_ZONE_DEVICES; do
				add_device_member "$device"
			done

			[ "$ACTIVE_MEMBER_COUNT" -gt 0 ] || {
				wan_vrf_log notice "No active public members found in public_zone=${PUBLIC_ZONE}; rules flushed"
				return 2
			}
		;;
		iface_list)
			PUBLIC_TARGETS="$PUBLIC_IFACES"
			[ -n "$PUBLIC_TARGETS" ] || {
				wan_vrf_log err "public_mode=iface_list requires public_ifaces"
				return 1
			}

			for iface in $PUBLIC_TARGETS; do
				add_iface_member "$iface"
			done

			[ "$ACTIVE_MEMBER_COUNT" -gt 0 ] || {
				wan_vrf_log notice "No active public members found in public_ifaces=${PUBLIC_IFACES}; rules flushed"
				return 2
			}
		;;
		*)
			wan_vrf_log err "Unsupported public_mode=${PUBLIC_MODE}; expected zone or iface_list"
			return 1
		;;
	esac

	return 0
}

apply_mangle_rules() {
	reset_chain "$CHAIN_PREROUTING" || return 1
	reset_chain "$CHAIN_OUTPUT" || return 1

	printf '%s\n' "$LAN_MEMBERS" | while IFS='|' read -r kind name dev; do
		[ -n "$dev" ] || continue
		iptables -t mangle -A "$CHAIN_PREROUTING" -i "$dev" -j CONNMARK --restore-mark || exit 1
	done
	[ "$?" -eq 0 ] || return 1

	printf '%s\n' "$ACTIVE_MEMBERS" | while IFS='|' read -r kind name dev mark table priority gateway; do
		[ -n "$mark" ] || continue
		iptables -t mangle -A "$CHAIN_PREROUTING" -i "$dev" -m conntrack --ctstate NEW -j CONNMARK --set-xmark "${mark}/${mark}" || exit 1
	done
	[ "$?" -eq 0 ] || return 1

	iptables -t mangle -A "$CHAIN_OUTPUT" -j CONNMARK --restore-mark || return 1

	remove_jump_rule "$CHAIN_PREROUTING" PREROUTING
	remove_jump_rule "$CHAIN_OUTPUT" OUTPUT
	iptables -t mangle -I PREROUTING 1 -j "$CHAIN_PREROUTING" || return 1
	iptables -t mangle -I OUTPUT 1 -j "$CHAIN_OUTPUT" || return 1
}

install_member_link_routes() {
	local dev table route prefix rest

	dev="$1"
	table="$2"

	ip -4 route show dev "$dev" scope link 2>/dev/null | while IFS= read -r route; do
		[ -n "$route" ] || continue
		case "$route" in
			default*)
				continue
			;;
		esac

		case " $route " in
			*" dev "*)
				ip -4 route replace table "$table" $route || exit 1
			;;
			*)
				prefix="${route%% *}"
				rest="${route#${prefix}}"
				if [ "$rest" = "$route" ]; then
					ip -4 route replace table "$table" "$prefix" dev "$dev" || exit 1
				else
					rest="${rest# }"
					ip -4 route replace table "$table" "$prefix" dev "$dev" $rest || exit 1
				fi
			;;
		esac
	done

	return "$?"
}

apply_policy_routing() {
	flush_policy_routing

	printf '%s\n' "$ACTIVE_MEMBERS" | while IFS='|' read -r kind name dev mark table priority gateway; do
		[ -n "$mark" ] || continue

		wan_vrf_device_exists "$dev" || {
			wan_vrf_log err "Selected public member ${name} resolved to missing device ${dev}"
			exit 1
		}

		if [ -n "$gateway" ]; then
			install_member_link_routes "$dev" "$table" || exit 1
			ip -4 route replace table "$table" default via "$gateway" dev "$dev" onlink || exit 1
		else
			ip -4 route replace table "$table" default dev "$dev" || exit 1
		fi

		ip -4 rule add fwmark "${mark}/${RULE_FWMARK_MASK}" lookup "$table" priority "$priority" || exit 1
	done
	[ "$?" -eq 0 ] || return 1
}

write_state() {
	local kind name dev mark table priority gateway

	{
		printf 'last_apply=%s\n' "$(wan_vrf_now)"
		printf 'mode=%s\n' "$MODE"
		printf 'public_mode=%s\n' "$PUBLIC_MODE"
		printf 'public_zone=%s\n' "$PUBLIC_ZONE"
		printf 'public_ifaces=%s\n' "$PUBLIC_IFACES"
		printf 'public_targets=%s\n' "$PUBLIC_TARGETS"
		printf 'lan_mode=%s\n' "$LAN_MODE"
		printf 'lan_zone=%s\n' "$LAN_ZONE"
		printf 'lan_ifaces=%s\n' "$LAN_IFACES"
		printf 'lan_targets=%s\n' "$LAN_TARGETS"
		printf 'route_table_public=%s\n' "$ROUTE_TABLE_BASE"
		printf 'fwmark_public=%s\n' "$FWMARK_BASE"
		printf 'rule_priority=%s\n' "$RULE_PRIORITY_BASE"
		printf 'lan_member_count=%s\n' "$LAN_MEMBER_COUNT"
		printf 'member_count=%s\n' "$ACTIVE_MEMBER_COUNT"
		printf 'event=%s %s\n' "$EVENT_CLASS" "$EVENT_NAME"
		printf 'default_route_dev=%s\n' "$(wan_vrf_get_default_route_device)"

		printf '%s\n' "$LAN_MEMBERS" | while IFS='|' read -r kind name dev; do
			[ -n "$dev" ] || continue
			printf 'lan_member=%s|%s|%s\n' "$kind" "$name" "$dev"
		done

		printf '%s\n' "$ACTIVE_MEMBERS" | while IFS='|' read -r kind name dev mark table priority gateway; do
			[ -n "$mark" ] || continue
			printf 'member=%s|%s|%s|%s|%s|%s|%s\n' "$kind" "$name" "$dev" "$mark" "$table" "$priority" "$gateway"
		done
	} > "$WAN_VRF_STATE_FILE"
}

build_summary() {
	printf '%s\n' "$ACTIVE_MEMBERS" | awk -F'|' 'NF >= 5 && $4 != "" { if (out) out = out ", "; out = out $2 "(" $3 " " $4 "->" $5 ")" } END { print out }'
}

main() {
	local rc summary

	wan_vrf_require_commands ip iptables jsonfilter ubus uci sed awk || exit 1
	load_config
	load_previous_members

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
	summary="$(build_summary)"

	case "$PUBLIC_MODE" in
		zone)
			wan_vrf_log notice "Applied WAN symmetric routing for public_zone=${PUBLIC_ZONE}: ${summary}"
		;;
		iface_list)
			wan_vrf_log notice "Applied WAN symmetric routing for public_ifaces=${PUBLIC_IFACES}: ${summary}"
		;;
	esac
}

main "$@"