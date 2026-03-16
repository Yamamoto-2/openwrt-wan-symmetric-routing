#!/bin/sh

WAN_VRF_TAG="wan-vrf"
WAN_VRF_UCI_PACKAGE="wan_vrf"
WAN_VRF_UCI_SECTION="main"
WAN_VRF_STATE_FILE="/tmp/wan-vrf.last_apply"

wan_vrf_command_exists() {
	command -v "$1" >/dev/null 2>&1
}

wan_vrf_log() {
	local level message

	level="${1:-info}"
	shift
	message="$*"

	if wan_vrf_command_exists logger; then
		logger -t "$WAN_VRF_TAG" -p "user.${level}" "$message"
	fi

	printf '%s\n' "$message" >&2
}

wan_vrf_debug() {
	[ "$(wan_vrf_get_cfg debug 0)" = "1" ] || return 0
	wan_vrf_log notice "$@"
}

wan_vrf_require_commands() {
	local cmd missing

	missing=0
	for cmd in "$@"; do
		if ! wan_vrf_command_exists "$cmd"; then
			wan_vrf_log err "Missing required command: ${cmd}"
			missing=1
		fi
	done

	return "$missing"
}

wan_vrf_get_cfg() {
	local option value default

	option="$1"
	default="$2"
	value="$(uci -q get "${WAN_VRF_UCI_PACKAGE}.${WAN_VRF_UCI_SECTION}.${option}" 2>/dev/null)"

	if [ -n "$value" ]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default"
	fi
}

wan_vrf_get_iface_status_json() {
	local iface

	iface="$1"
	ubus call "network.interface.${iface}" status 2>/dev/null
}

wan_vrf_get_iface_field() {
	local iface field json

	iface="$1"
	field="$2"
	json="$(wan_vrf_get_iface_status_json "$iface")"

	[ -n "$json" ] || return 1
	printf '%s\n' "$json" | jsonfilter -e "@[\"${field}\"]" 2>/dev/null
}

wan_vrf_get_iface_device() {
	local iface device

	iface="$1"
	device="$(wan_vrf_get_iface_field "$iface" l3_device)"

	if [ -z "$device" ]; then
		device="$(wan_vrf_get_iface_field "$iface" device)"
	fi

	printf '%s\n' "$device"
}

wan_vrf_iface_is_up() {
	[ "$(wan_vrf_get_iface_field "$1" up)" = "true" ]
}

wan_vrf_get_default_route_device() {
	ip -4 route show default 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

wan_vrf_get_gateway_for_device() {
	local device

	device="$1"
	ip -4 route show default dev "$device" 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

wan_vrf_now() {
	date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date 2>/dev/null
}
