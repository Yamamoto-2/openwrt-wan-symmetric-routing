#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/core.sh"

NFT_TABLE="inet wan_vrf"

ACTION="${1:-apply}"
EVENT_CLASS="${2:-}"
EVENT_NAME="${3:-}"

MODE=""
PUBLIC_MODE=""
PUBLIC_ZONE=""
PUBLIC_IFACES=""
LAN_NETWORK=""
ROUTE_TABLE_BASE=""
FWMARK_BASE=""
FWMARK_BASE_DEC="0"
RULE_PRIORITY_BASE=""
LAN_DEVS=""
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
	LAN_NETWORK="$(wan_vrf_get_cfg lan_network lan)"
	ROUTE_TABLE_BASE="$(wan_vrf_get_cfg route_table_public 100)"
	FWMARK_BASE="$(wan_vrf_get_cfg fwmark_public 0x100)"
	FWMARK_BASE_DEC="$((FWMARK_BASE))"
	RULE_PRIORITY_BASE="$(wan_vrf_get_cfg rule_priority 10000)"
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

flush_nft_table() {
	nft delete table $NFT_TABLE >/dev/null 2>&1 || true
}

flush_legacy_iptables() {
	command -v iptables >/dev/null 2>&1 || return 0
	local chain parent
	for parent in PREROUTING OUTPUT FORWARD; do
		for chain in WAN_VRF_PREROUTING WAN_VRF_OUTPUT WAN_VRF_MSS; do
			while iptables -t mangle -D "$parent" -j "$chain" >/dev/null 2>&1; do :; done
		done
	done
	for chain in WAN_VRF_PREROUTING WAN_VRF_OUTPUT WAN_VRF_MSS; do
		iptables -t mangle -F "$chain" >/dev/null 2>&1 || true
		iptables -t mangle -X "$chain" >/dev/null 2>&1 || true
	done
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
	flush_nft_table
	flush_legacy_iptables
	flush_policy_routing
	flush_state
}

resolve_runtime() {
	local iface device

	LAN_DEVS=""
	ACTIVE_MEMBERS=""
	ACTIVE_MEMBER_COUNT=0
	SEEN_PUBLIC_DEVICES=""
	PUBLIC_ZONE_NETWORKS=""
	PUBLIC_ZONE_DEVICES=""
	PUBLIC_TARGETS=""

	for _lan_net in $LAN_NETWORK; do
		_lan_d="$(wan_vrf_get_iface_device "$_lan_net")"
		if [ -n "$_lan_d" ]; then
			LAN_DEVS="${LAN_DEVS:+$LAN_DEVS }${_lan_d}"
		else
			wan_vrf_log warning "Unable to resolve device for lan_network entry '${_lan_net}'; skipping"
		fi
	done

	[ -n "$LAN_DEVS" ] || {
		wan_vrf_log err "Unable to resolve any device for lan_network='${LAN_NETWORK}'"
		return 1
	}

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

get_device_mtu() {
	local dev mtu
	dev="$1"
	mtu="$(cat "/sys/class/net/${dev}/mtu" 2>/dev/null)"
	printf '%s' "${mtu:-1500}"
}

apply_nft_rules() {
	local dev_mtu dev_mss ruleset

	# Build prerouting rules: restore ct mark from LAN, set ct mark on WAN NEW
	local prerouting_rules=""
	for _lan_d in $LAN_DEVS; do
		prerouting_rules="${prerouting_rules}
		iifname \"${_lan_d}\" counter meta mark set ct mark"
	done

	local IFS_SAVE="$IFS"
	while IFS='|' read -r _kind _name _dev _mark _table _priority _gateway; do
		[ -n "$_mark" ] || continue
		prerouting_rules="${prerouting_rules}
		iifname \"${_dev}\" ct state new counter ct mark set ${_mark}"
	done <<EOF
$(printf '%s\n' "$ACTIVE_MEMBERS")
EOF
	IFS="$IFS_SAVE"

	# Build MSS clamping rules per WAN device
	local mss_rules=""
	while IFS='|' read -r _kind _name _dev _mark _table _priority _gateway; do
		[ -n "$_dev" ] || continue
		dev_mtu="$(get_device_mtu "$_dev")"
		dev_mss=$((dev_mtu - 40))
		mss_rules="${mss_rules}
		iifname \"${_dev}\" tcp flags syn / syn,rst counter tcp option maxseg size set ${dev_mss}
		oifname \"${_dev}\" tcp flags syn / syn,rst counter tcp option maxseg size set ${dev_mss}"
	done <<EOF
$(printf '%s\n' "$ACTIVE_MEMBERS")
EOF

	# Apply atomically
	ruleset="table ${NFT_TABLE}
delete table ${NFT_TABLE}
table ${NFT_TABLE} {
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;${prerouting_rules}
	}
	chain output {
		type route hook output priority mangle; policy accept;
		counter meta mark set ct mark
	}
	chain forward_mss {
		type filter hook forward priority mangle; policy accept;${mss_rules}
	}
}"

	printf '%s\n' "$ruleset" | nft -f - || return 1
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
		printf 'lan_network=%s\n' "$LAN_NETWORK"
		printf 'lan_devs=%s\n' "$LAN_DEVS"
		printf 'route_table_public=%s\n' "$ROUTE_TABLE_BASE"
		printf 'fwmark_public=%s\n' "$FWMARK_BASE"
		printf 'rule_priority=%s\n' "$RULE_PRIORITY_BASE"
		printf 'member_count=%s\n' "$ACTIVE_MEMBER_COUNT"
		printf 'event=%s %s\n' "$EVENT_CLASS" "$EVENT_NAME"
		printf 'default_route_dev=%s\n' "$(wan_vrf_get_default_route_device)"

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

	wan_vrf_require_commands ip nft jsonfilter ubus uci sed awk || exit 1
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

	apply_nft_rules || {
		flush_all
		wan_vrf_log err "Failed to install nftables rules"
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