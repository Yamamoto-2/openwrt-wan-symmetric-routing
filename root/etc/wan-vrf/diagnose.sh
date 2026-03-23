#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/core.sh"

PUBLIC_MODE="$(wan_vrf_get_cfg public_mode zone)"
PUBLIC_ZONE="$(wan_vrf_get_cfg public_zone wan)"
PUBLIC_IFACES="$(wan_vrf_get_cfg public_ifaces '')"
LAN_NETWORK="$(wan_vrf_get_cfg lan_network lan)"
ROUTE_TABLE_BASE="$(wan_vrf_get_cfg route_table_public 100)"
FWMARK_BASE="$(wan_vrf_get_cfg fwmark_public 0x100)"
RULE_PRIORITY_BASE="$(wan_vrf_get_cfg rule_priority 10000)"

LAN_DEVS=""
for _lan_net in $LAN_NETWORK; do
	_lan_d="$(wan_vrf_get_iface_device "$_lan_net")"
	[ -n "$_lan_d" ] && LAN_DEVS="${LAN_DEVS:+$LAN_DEVS }${_lan_d}"
done
ZONE_NETWORKS="$(wan_vrf_get_firewall_zone_networks "$PUBLIC_ZONE")"
ZONE_DEVICES="$(wan_vrf_get_firewall_zone_devices "$PUBLIC_ZONE")"

print_header() {
	printf '\n== %s ==\n' "$1"
}

print_value() {
	printf '%-20s %s\n' "$1" "$2"
}

run_cmd() {
	local arg

	printf '$'
	for arg in "$@"; do
		printf ' %s' "$arg"
	done
	printf '\n'
	"$@" 2>&1
}

print_state_tables() {
	local line entry old_ifs

	if [ ! -f "$WAN_VRF_STATE_FILE" ]; then
		run_cmd ip -4 route show table "$ROUTE_TABLE_BASE"
		return
	fi

	while IFS= read -r line; do
		case "$line" in
			member=*)
				entry="${line#member=}"
				old_ifs="$IFS"
				IFS='|'
				set -- $entry
				IFS="$old_ifs"
				[ -n "$5" ] || continue
				run_cmd ip -4 route show table "$5"
			;;
		esac
	done < "$WAN_VRF_STATE_FILE"
}

print_header "Config"
print_value "enabled" "$(wan_vrf_get_cfg enabled 0)"
print_value "mode" "$(wan_vrf_get_cfg mode fwmark)"
print_value "public_mode" "$PUBLIC_MODE"
print_value "public_zone" "$PUBLIC_ZONE"
print_value "public_ifaces" "$PUBLIC_IFACES"
print_value "zone_networks" "$ZONE_NETWORKS"
print_value "zone_devices" "$ZONE_DEVICES"
print_value "lan_network" "$LAN_NETWORK"
print_value "lan_devs" "$LAN_DEVS"
print_value "route_table_base" "$ROUTE_TABLE_BASE"
print_value "fwmark_base" "$FWMARK_BASE"
print_value "rule_priority" "$RULE_PRIORITY_BASE"
print_value "default_route_dev" "$(wan_vrf_get_default_route_device)"

print_header "Last Apply State"
if [ -f "$WAN_VRF_STATE_FILE" ]; then
	cat "$WAN_VRF_STATE_FILE"
else
	printf 'No state file at %s\n' "$WAN_VRF_STATE_FILE"
fi

print_header "Policy Rules"
run_cmd ip -4 rule show

print_header "Public Route Tables"
print_state_tables

print_header "Main Default Route"
run_cmd ip -4 route show default

print_header "Mangle Rules"
run_cmd iptables -t mangle -S WAN_VRF_PREROUTING
run_cmd iptables -t mangle -S WAN_VRF_OUTPUT

print_header "Mangle Counters"
run_cmd iptables -t mangle -L WAN_VRF_PREROUTING -n -v
run_cmd iptables -t mangle -L WAN_VRF_OUTPUT -n -v

if wan_vrf_command_exists logread; then
	print_header "Recent Logs"
	printf '$ logread | grep wan-vrf | tail -n 50\n'
	logread 2>&1 | grep 'wan-vrf' | tail -n 50
fi