# WAN Symmetric Routing

Shell-first OpenWrt/iStoreOS package for symmetric return-path routing in dual-WAN or multi-WAN deployments.

Current scope:

- `fwmark + ip rule` symmetric return-path helper
- Explicit public-member selection via `public_mode=zone|iface_list`
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

This repository now builds two installable packages:

- `wan-symmetric-routing`: core shell runtime, config, service, hotplug hooks, and diagnostics
- `luci-app-wan-symmetric-routing`: LuCI page and ACL/menu wiring, depending on the core package

## What the package does

The current implementation tags new inbound connections on each selected IPv4 WAN member, restores the tag on reply traffic from `lan_network`, and sends that reply through a per-member policy-routing table.

That means any selected WAN member can keep a symmetric return path without forcing normal outbound traffic onto that WAN.

## Configuration model

The package supports two explicit selection modes:

1. `public_mode 'zone'`
   Uses every active IPv4 member inside a firewall zone such as `wan`.
2. `public_mode 'iface_list'`
   Uses a space-separated list of logical OpenWrt interfaces.

Zone mode example:

```uci
config settings 'main'
    option enabled '1'
    option mode 'fwmark'
    option public_mode 'zone'
    option public_zone 'wan'
    option public_ifaces ''
    option lan_network 'lan'
    option route_table_public '100'
    option fwmark_public '0x100'
    option rule_priority '10000'
```

Interface-list mode example:

```uci
config settings 'main'
    option enabled '1'
    option mode 'fwmark'
    option public_mode 'iface_list'
    option public_zone 'wan'
    option public_ifaces 'wan wan_10g'
    option lan_network 'lan'
    option route_table_public '100'
    option fwmark_public '0x100'
    option rule_priority '10000'
```

Notes:

- `public_mode` decides whether members come from a firewall zone or from `public_ifaces`.
- `public_zone` is only used when `public_mode 'zone'`.
- `public_ifaces` is only used when `public_mode 'iface_list'`.
- `route_table_public`, `fwmark_public`, and `rule_priority` are treated as base values. Additional active members use the next numbers in sequence.
- Members without IPv4 addresses, such as a standalone `wan6`, are skipped automatically.

## LuCI UI

The LuCI frontend exposes the same core options:

- `Enable`
- `Public Member Source`
- `Firewall Zone` or `Interface List`
- `LAN Network`
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

- Verify `zone` mode on a multi-member `wan` firewall zone
- Verify `iface_list` mode with one and multiple interfaces
- Verify same-subnet access on static WANs such as `wan_10g`
- Verify LuCI Save & Apply updates `/etc/config/wan_vrf`
- Confirm both generated IPKs install cleanly on the target OpenWrt/iStoreOS release

## Notes

- The current implementation assumes an `iptables`-based firewall compatibility layer is available.
- `mode 'vrf'` is reserved for later work and is not implemented yet.
- `lan_network` currently expects a single logical OpenWrt network such as `lan`.
- When the selected source contains multiple WAN members, each active member receives its own mark and route table.

## License

This project is released under the MIT License. See LICENSE.