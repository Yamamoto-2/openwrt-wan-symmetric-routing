# WAN Symmetric Routing

Shell-first OpenWrt/iStoreOS package for symmetric return-path routing in dual-WAN or multi-WAN deployments.

Current scope:

- `fwmark + ip rule` symmetric return-path helper
- Explicit public-member selection via `public_mode=zone|iface_list`
- Explicit LAN reply-source selection via `lan_mode=zone|iface_list`
- One `mark + table + rule` set per active public-WAN member
- Core runtime package plus optional LuCI frontend package
- UCI-based configuration in `/etc/config/wan_vrf`
- `init.d` service and hotplug auto-reapply hooks
- `diagnose.sh` for fast field debugging

Current non-goals:

- VRF production mode
- IPv6 policy routing
- Deep coexistence with `mwan3` or other policy-routing packages

## Package layout

```text
.
├── Makefile
├── README.md
├── luci
│   ├── htdocs
│   │   └── luci-static
│   │       └── resources
│   │           └── view
│   │               └── wan-symmetric-routing
│   │                   └── settings.js
│   └── root
│       └── usr
│           └── share
│               ├── luci
│               │   └── menu.d
│               │       └── luci-app-wan-symmetric-routing.json
│               └── rpcd
│                   └── acl.d
│                       └── luci-app-wan-symmetric-routing.json
└── root
    └── etc
        ├── config
        │   └── wan_vrf
        ├── hotplug.d
        │   ├── firewall
        │   │   └── 95-wan-vrf
        │   └── iface
        │       └── 95-wan-vrf
        ├── init.d
        │   └── wan_vrf
        └── wan-vrf
            ├── apply.sh
            ├── core.sh
            └── diagnose.sh
```

## Packages

This repository builds two installable packages:

- `wan-symmetric-routing`: core shell runtime, config, service, hotplug hooks, and diagnostics
- `luci-app-wan-symmetric-routing`: LuCI page and ACL/menu wiring, depending on the core package

## What the package does

The implementation tags new inbound connections on each selected IPv4 WAN member, restores the tag on reply traffic from the selected LAN side, and sends that reply through a per-member policy-routing table.

That means any selected WAN member can keep a symmetric return path without forcing normal outbound traffic onto that WAN.

## Configuration model

The package has two independent selector groups.

Public side:

1. `public_mode 'zone'`
   Uses every active IPv4 member inside a firewall zone such as `wan`.
2. `public_mode 'iface_list'`
   Uses a space-separated list of logical OpenWrt interfaces.

LAN side:

1. `lan_mode 'zone'`
   Restores connmark on every active member inside a LAN firewall zone such as `lan`.
2. `lan_mode 'iface_list'`
   Restores connmark on a space-separated list of logical OpenWrt interfaces such as `lan iot guest`.

## Examples

Example 1: public zone + LAN zone

```uci
config settings 'main'
    option enabled '1'
    option mode 'fwmark'
    option public_mode 'zone'
    option public_zone 'wan'
    option public_ifaces ''
    option lan_mode 'zone'
    option lan_zone 'lan'
    option lan_ifaces ''
    option route_table_public '100'
    option fwmark_public '0x100'
    option rule_priority '10000'
```

Example 2: explicit WAN list + multiple internal zones via interface list

```uci
config settings 'main'
    option enabled '1'
    option mode 'fwmark'
    option public_mode 'iface_list'
    option public_zone 'wan'
    option public_ifaces 'wan wan2'
    option lan_mode 'iface_list'
    option lan_zone 'lan'
    option lan_ifaces 'lan iot guest'
    option route_table_public '100'
    option fwmark_public '0x100'
    option rule_priority '10000'
```

Example 3: single WAN + a default LAN zone

```uci
config settings 'main'
    option enabled '1'
    option mode 'fwmark'
    option public_mode 'iface_list'
    option public_ifaces 'wan2'
    option lan_mode 'zone'
    option lan_zone 'lan'
```

Notes:

- `public_mode` decides whether public members come from a firewall zone or from `public_ifaces`.
- `lan_mode` decides whether LAN reply sources come from a firewall zone or from `lan_ifaces`.
- `public_zone` is only used when `public_mode 'zone'`.
- `public_ifaces` is only used when `public_mode 'iface_list'`.
- `lan_zone` is only used when `lan_mode 'zone'`.
- `lan_ifaces` is only used when `lan_mode 'iface_list'`.
- `lan_zone` accepts one firewall zone name. If replies may leave through multiple internal zones such as `lan`, `iot`, and `guest`, use `lan_mode 'iface_list'` with `lan_ifaces 'lan iot guest'`.
- `route_table_public`, `fwmark_public`, and `rule_priority` are treated as base values. Additional active public members use the next numbers in sequence.
- Members without IPv4 addresses, such as a standalone `wan6`, are skipped automatically on the public side.

## LuCI UI

The LuCI frontend exposes the same core options:

- `Enable`
- `Public Member Source`
- `Public Firewall Zone` or `Public Interface List`
- `LAN Source`
- `LAN Firewall Zone` or `LAN Interface List`
- `Route Table Base`
- `FWMark Base`
- `Rule Priority Base`
- `Auto Apply`
- `Debug Logging`

The page is installed at `Network` -> `WAN Symmetric Routing`.

## Build and install

Inside an OpenWrt build tree, place this repository under `package/` and run:

```sh
make package/wan-symmetric-routing/compile V=s
```

That build produces both IPKs from the same package directory:

- `wan-symmetric-routing_*.ipk`
- `luci-app-wan-symmetric-routing_*.ipk`

Typical install flow on a target router:

```sh
opkg install wan-symmetric-routing_*.ipk
opkg install luci-app-wan-symmetric-routing_*.ipk
/etc/init.d/wan_vrf enable
/etc/init.d/wan_vrf start
```

## Release checklist

- Verify `public_mode 'zone'` on a multi-member `wan` firewall zone
- Verify `public_mode 'iface_list'` with one and multiple WAN interfaces
- Verify `lan_mode 'zone'` on a multi-member LAN firewall zone
- Verify `lan_mode 'iface_list'` with multiple LAN interfaces such as `lan iot guest`
- Verify same-subnet access on static WANs such as `wan2`
- Verify LuCI Save & Apply updates `/etc/config/wan_vrf`
- Confirm both generated IPKs install cleanly on the target OpenWrt/iStoreOS release

## Notes

- The current implementation assumes an `iptables`-based firewall compatibility layer is available.
- `mode 'vrf'` is reserved for later work and is not implemented yet.
- When the selected source contains multiple WAN members, each active member receives its own mark and route table.
- When the selected LAN source contains multiple members, each member receives its own `CONNMARK --restore-mark` rule.

## License

This project is released under the MIT License. See LICENSE.
