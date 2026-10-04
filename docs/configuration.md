# Configuration

Configuration file `/etc/uu/uu.conf` (run `uuctl restart` after editing):

| Key | Default | Description |
|---|---|---|
| `LAN_IF` | empty | LAN interface; empty = interface of the default route |
| `GATEWAY` | 1 | Enable bypass gateway forwarding |
| `MASQUERADE` | 1 | NAT forwarded traffic (standard for bypass gateways; keeps return traffic from skipping this machine) |
| `DNS` | 1 | Run dnsmasq on port 53 of `LAN_IF`; set to 0 if another DNS service (AdGuard Home etc.) already runs here |
| `FILTER_AAAA` | 1 | Local DNS returns no IPv6 addresses, see [IPv6](ipv6.md) (needs dnsmasq 2.87+) |
| `DNS_UPSTREAM` | empty | Upstream DNS servers (space-separated); empty = the system's current upstream |
| `UPDATE_ON_START` | 1 | Check for and install plugin updates on start |
| `UPDATE_WAIT` | 120 | Max seconds to wait for the update server on start; after that, start with the cached version |

SN file `/etc/uu/factoryinfo`:

```
productname=NX30Pro
ethaddr=<this machine's MAC>
hardversion=VER.A
bootversion=100
manucode=<this machine's MAC>
```

- `productname` selects the plugin to download: `https://router.uu.163.com/api/plugin?type=h3c-<lowercase productname>&sn=<manucode>`.
  It is `NX30Pro` on arm64 and `BX54` on armv7; `install.sh` corrects it to match this machine's architecture (only the model changes, the SN stays)
- `manucode` is the SN that UU uses to identify the device. **Never use the same SN on two devices at the same time**
  (they conflict and kick each other off). To keep the binding of an old OpenWrt device, copy its file with `--factoryinfo` and disable the plugin on the old device.
