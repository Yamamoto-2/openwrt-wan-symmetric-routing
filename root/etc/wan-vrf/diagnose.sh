#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/core.sh"

MODE="$(wan_vrf_get_cfg mode fwmark)"
FAST_WAN="$(wan_vrf_get_cfg fast_wan wan10g)"
PUBLIC_WAN="$(wan_vrf_get_cfg public_wan wan_pppoe)"
LAN_NETWORK="$(wan_vrf_get_cfg lan_network lan)"
ROUTE_TABLE_PUBLIC="$(wan_vrf_get_cfg route_table_public 100)"
FWMARK_PUBLIC="$(wan_vrf_get_cfg fwmark_public 0x100)"
RULE_PRIORITY="$(wan_vrf_get_cfg rule_priority 10000)"

FAST_DEV="$(wan_vrf_get_iface_device "$FAST_WAN")"
PUBLIC_DEV="$(wan_vrf_get_iface_device "$PUBLIC_WAN")"
LAN_DEV="$(wan_vrf_get_iface_device "$LAN_NETWORK")"

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

print_header "Config"
print_value "enabled" "$(wan_vrf_get_cfg enabled 0)"
print_value "mode" "$MODE"
print_value "fast_wan" "$FAST_WAN"
print_value "fast_dev" "$FAST_DEV"
print_value "public_wan" "$PUBLIC_WAN"
print_value "public_dev" "$PUBLIC_DEV"
print_value "public_gateway" "$(wan_vrf_get_gateway_for_device "$PUBLIC_DEV")"
print_value "lan_network" "$LAN_NETWORK"
print_value "lan_dev" "$LAN_DEV"
print_value "route_table_public" "$ROUTE_TABLE_PUBLIC"
print_value "fwmark_public" "$FWMARK_PUBLIC"
print_value "rule_priority" "$RULE_PRIORITY"
print_value "default_route_dev" "$(wan_vrf_get_default_route_device)"
print_value "fast_wan_up" "$(wan_vrf_get_iface_field "$FAST_WAN" up)"
print_value "public_wan_up" "$(wan_vrf_get_iface_field "$PUBLIC_WAN" up)"

print_header "Last Apply State"
if [ -f "$WAN_VRF_STATE_FILE" ]; then
	cat "$WAN_VRF_STATE_FILE"
else
	printf 'No state file at %s\n' "$WAN_VRF_STATE_FILE"
fi

print_header "Policy Rules"
run_cmd ip -4 rule show

print_header "Public Route Table"
run_cmd ip -4 route show table "$ROUTE_TABLE_PUBLIC"

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
