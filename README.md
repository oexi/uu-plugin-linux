# NetEase UU Accelerator Plugin (H3C router build) for Linux ARM

Runs the NetEase UU game accelerator plugin from H3C router firmware on a regular Linux ARM box
(arm64 / armv7, systemd distributions such as Debian, Ubuntu, Armbian and Raspberry Pi OS).
The box becomes a **UU bypass gateway**: point a device's gateway and DNS at it, then bind and accelerate the device in the UU console accelerator app.

- Starts on boot, and checks for plugin updates on every start
- Configures the bypass gateway (forwarding, NAT, DNS) automatically
- Uses the H3C-branded plugin, which accelerates consoles **and PCs** ([why](docs/why-h3c.md))

## Requirements

- **arm64** (H3C NX30Pro plugin) or **armv7** (H3C BX54 plugin); x86_64, MIPS and ARMv6 are not supported.
  4K/16K/64K page kernels all work, including Raspberry Pi 5 (BCM2712)
- A systemd-based distribution
- Same subnet as the main router and the LAN devices; a static IP is recommended

Missing dependencies (`curl iptables iproute2 dnsmasq`) are installed automatically.
The plugin binary is downloaded from NetEase on first start.

## Install

```sh
git clone https://github.com/oexi/uu-plugin-linux-arm64.git
cd uu-plugin-linux-arm64
sudo ./install.sh
```

Options: `--lan-if eth0` (LAN interface), `--factoryinfo FILE` (reuse an existing SN file), `--arch aarch64|arm`, `--no-start`.

## Set up LAN devices

On each device to accelerate (Switch / PS5 / Xbox / PC …):

| Setting | Value |
|---|---|
| IP / subnet mask | Same subnet as the main router (or keep DHCP) |
| **Gateway** | **This box's IP** |
| **DNS** | **This box's IP** |

Then add the router / bind the device in the UU app. `uuctl status` shows the address to use.

## Manage

```sh
uuctl status | log | restart | update | enable | disable
sudo ./uninstall.sh            # keeps /etc/uu; add --purge to remove it
```

## Docs

- [Configuration](docs/configuration.md): `/etc/uu/uu.conf` options and the SN file
- [IPv6](docs/ipv6.md): how IPv6 is handled
- [Why the H3C build](docs/why-h3c.md): why the generic OpenWrt build cannot accelerate PCs
- [Implementation notes](docs/implementation.md): file layout and porting details
- [Troubleshooting](docs/troubleshooting.md)
- [Testing](docs/testing.md): what has and has not been verified
