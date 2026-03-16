# WAN Symmetric Routing

Shell-first OpenWrt/iStoreOS package for symmetric return-path routing in dual-WAN deployments.

Current scope:

- `fwmark + ip rule` MVP for symmetric return traffic
- UCI-based configuration in `/etc/config/wan_vrf`
- `init.d` service and hotplug auto-reapply hooks
- `diagnose.sh` for fast field debugging

Current non-goals:

- LuCI pages
- VRF production mode
- IPv6 policy routing
- Deep coexistence with `mwan3` or other policy-routing packages

## Package layout

```text
.
├── Makefile
├── README.md
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

## What the MVP does

The first version only handles the core asymmetric-routing problem:

1. New inbound connections that arrive on `public_wan` are tagged with a `connmark`.
2. Reply packets from `lan_network` restore that mark before routing.
3. An `ip rule` sends marked traffic into a dedicated routing table.
4. That routing table points back to the public WAN, so reply packets leave on the same WAN they entered.

The main routing table is intentionally left untouched. Your normal outbound default route should still be managed by OpenWrt and point at the fast WAN.

## Default workflow on target router

1. Install the package.
2. Adjust `/etc/config/wan_vrf`.
3. Enable the service with `/etc/init.d/wan_vrf enable`.
4. Apply with `/etc/init.d/wan_vrf start`.
5. Inspect state with `/etc/wan-vrf/diagnose.sh`.

## Notes

- The current implementation assumes an `iptables`-based firewall environment.
- `mode 'vrf'` is reserved for later work and is not implemented yet.
- `lan_network` currently expects a single logical OpenWrt network such as `lan`.
