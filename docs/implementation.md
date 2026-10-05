# Implementation notes (changes from the OpenWrt port)

## File layout

| Path | Description |
|---|---|
| `/opt/uu/bin/uu-monitor.sh` | Supervisor / updater (rewritten from `h3c_uuplugin_monitor.sh`), main process of `uu.service` |
| `/opt/uu/bin/uu-gateway.sh` | Bypass gateway rules, dnsmasq launcher |
| `/opt/uu/bin/uuctl` | Management command (`/usr/local/bin/uuctl`) |
| `/opt/uu/shim/` | Command shims used only by uuplugin (see below) |
| `/opt/uu/musl/<arch>/` | musl runtime; `/lib/ld-musl-aarch64.so.1` or `/lib/ld-musl-arm.so.1` points here |
| `/opt/uu/qemu/qemu-aarch64` | amd64 Docker image only: patched QEMU that runs the aarch64 plugin ([x86_64](x86_64.md)) |
| `/opt/uu/LICENSE`, `THIRD_PARTY_NOTICES.md`, `licenses/` | Licenses (`/usr/share/doc/uu-plugin-linux/` in the Docker image) |
| `/etc/uu/` | Configuration and SN file |
| `/var/lib/uu/uu.tar.gz` | Plugin package cache (persistent, so the plugin also starts when booting offline) |
| `/var/tmp/uu/` | Plugin working directory (path hard-coded in the plugin) |
| `/etc/systemd/system/uu.service`, `uu-dns.service` | systemd services |

## Porting details

1. **musl runtime**: the H3C `uuplugin` is dynamically linked against musl and cannot run on glibc distributions as is.
   The package ships the required libraries in `runtime/<arch>/` (`fetch-runtime.sh` can re-download and rebuild them).
   They are installed to `/opt/uu/musl/<arch>`, and `/etc/ld-musl-<arch>.path` sets the search path, without affecting glibc programs on the system.

   | Architecture | Plugin | Runtime source |
   |---|---|---|
   | aarch64 | H3C NX30Pro | `ld-musl-aarch64.so.1`, libstdc++, libgcc_s: Alpine 3.22 |
   | armv7 | H3C BX54 (soft-float ABI) | `ld-musl-arm.so.1`, libstdc++, libgcc_s: Bootlin armv5-eabi musl toolchain; libssl/libcrypto 1.1: OpenWrt 22.03 `arm_arm926ej-s` |

   armv7 pitfalls: the plugin uses the soft-float ABI (`ld-musl-arm.so.1`), while Alpine only ships hard-float;
   OpenWrt's libstdc++ is built without the C++11 ABI (missing `std::__cxx11` symbols), so Bootlin's is used;
   and libcrypto carries a 2-byte patch (next item).
2. **OpenSSL initialization on armv7**: the H3C BX54 `uuplugin` exports its own `atexit`, whose body is just
   `return -1`. Under musl, libcrypto's `atexit(OPENSSL_cleanup)` binds to this stub, so OpenSSL 1.1.1 considers
   initialization failed and every `SSL_CTX_new` returns NULL. The symptom is that the plugin opens a TCP connection to the server,
   closes it immediately and never logs in. The bundled libcrypto points its imported `atexit` symbol at the existing
   `sched_yield` string in its string table (no arguments, always returns 0), i.e. "registration succeeds but does nothing",
   which matches H3C's intent of not registering exit handlers (`fetch-runtime.sh` verifies the md5 and applies this patch automatically).
   The aarch64 plugin links OpenSSL statically and is not affected.
3. **iptables extensions**: the plugin runs commands as `XTABLES_LIBDIR=/lib iptables ...`. On Debian/Ubuntu the iptables
   extensions are not in `/lib`, so every `--dport`, `-j MARK` and `-j DNAT` rule fails. The monitor puts `/opt/uu/shim`
   first in the plugin's PATH; the shim clears that variable and then calls the system iptables.
4. **LAN interface**: the H3C plugin assumes the LAN interface is `br-lan` (the OpenWrt bridge) and guesses the bridge with
   `brctl show | grep br-` (which would pick a docker `br-xxxx` bridge on the host). The plugin config supports a
   `lan_ifname` key; after every extraction/update the monitor writes `lan_ifname=<LAN_IF>` into `uu.conf`,
   and the `brctl` shim returns nothing. Plain interfaces (eth0/end0 etc.) do not need to be turned into bridges.
5. **Process detection**: the original script parsed busybox `ps` output; this one reads `/proc/<pid>` (note that the kernel
   truncates the process name of `xuplugin-guardian` to 15 characters: `xuplugin-guardi`). The original bug that deleted `h3c_info`
   (already fixed in the OpenWrt port) is avoided here as well: `h3c_info` is kept and refreshed from `/etc/uu/factoryinfo` before every start.
6. **Automatic updates**:
   - On start: query the latest package md5 from `router.uu.163.com`; if it differs from the cache, download it (primary/backup URLs),
     verify the md5 and that the package contains `uuplugin`, then replace the cache. Every start re-extracts from the cache, so the latest version always runs
   - Network not ready at boot: wait up to `UPDATE_WAIT` seconds, then start with the cached version and retry in the background every 10 minutes,
     switching as soon as a new version appears; without a cache, keep retrying until a download succeeds
   - While running: when the plugin finds a new version it writes `uu.update` and exits; the monitor downloads the new package and restarts the plugin (same as the original)
7. **Bypass gateway** (`uu-gateway.sh`; all rules live in dedicated chains `UU_GW_IN` / `UU_GW_FWD` / `UU_GW_NAT`):
   - `net.ipv4.ip_forward=1`
   - `send_redirects` disabled: clients share the subnet with the main router, otherwise this machine would send ICMP redirects pointing clients back to the main router
   - Strict `rp_filter` (1) relaxed to loose (2), so replies from the plugin's tun interface are not dropped
   - `FORWARD` accepts LAN traffic (for hosts where docker / ufw set the FORWARD policy to DROP)
   - MASQUERADE for LAN traffic to the internet
   - `INPUT` accepts port 53 on the LAN interface
   - The monitor checks every minute and re-applies the rules if a firewall reload flushed them or the LAN address changed; everything is removed when the service stops
   - IPv4 only; IPv6 is not forwarded, and `ip6tables` only allows LAN access to the local DNS
8. **DNS**: `uu-dns.service` runs a separate dnsmasq instance (`--conf-file=/dev/null`, ignoring the system dnsmasq configuration),
   listening only on the LAN interface addresses (IPv4 and IPv6), without DHCP, and coexisting with systemd-resolved (127.0.0.53);
   `--filter-AAAA` is on by default, see [IPv6](ipv6.md).
