# Testing

Verified on Ubuntu 24.04 arm64 and armhf (systemd containers + simulated LAN):

- Install / reinstall / uninstall
- Start on boot
- Update on start (a stale cache is replaced with v14.9.4 automatically)
- Re-download and restart after the plugin requests an update (`uu.update`)
- Booting offline (starts from the cache if present; without a cache, keeps retrying and starts once the network is back)
- The plugin connects to NetEase's servers (`106.2.95.34:16000`) with `uu_status=0`; the iptables self-test rules are added/removed correctly
- LAN clients with gateway/DNS pointed at this machine get internet access (including with a FORWARD DROP policy) and DNS resolution
- Firewall rules are restored within a minute after being deleted; stopping the service removes the plugin and all gateway rules
- armv7 (H3C BX54 plugin, 32-bit ARM userland): install, login to NetEase's servers, LAN client internet and DNS via this machine,
  automatic restart after the plugin crashes (stale guardian process cleaned up), start on boot, uninstall
- Upgrade from the old directory layout (`/opt/uu/musl/lib`) to per-architecture directories
- Non-4K page kernel: on Ubuntu's 64K-page arm64 kernel (QEMU VM) the plugin and guardian run normally and log in to NetEase's servers
- Dual-stack network: AAAA queries to this machine return no addresses while A queries work; no IPv6 forwarding or router advertisements;
  leftover IPv6 forwarding rules from the earlier RA-based version are removed on upgrade

**Not verified**: binding in the phone app and real game acceleration (requires a real LAN, a UU account and game devices); please test after deployment.
