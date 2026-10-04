# Why the H3C build and not NetEase's generic OpenWrt build

NetEase publishes generic builds (`openwrt-aarch64/arm/x86_64/mipsel` etc.), but they do not support PC acceleration.
Comparing the H3C and generic binaries of the same version (v14.9.4): device classification (e.g. `may_be_windows`), device records,
`console_device_block_reason` and so on exist in both. The only differences are the channel details compiled into the binary:

| | H3C build | Generic OpenWrt build |
|---|---|---|
| `plugin_type` reported at login | `h3c-nx30pro` / `h3c-bx54` | `openwrt-x86_64` etc. |
| Remote link server | `h3crglg.uu.163.com` | `rglg.uu.netease.com` |
| Device SN source | `/var/tmp/uu/h3c_info` (`manucode`) | `/usr/sbin/uu/.sn` / interface MAC |

At login (the Connect message) the plugin reports `sn`, `model`, `type`, `plugin_type`, `real_sn` and `firmware_type`,
and the server decides per channel which devices may be accelerated; the H3C channel allows PCs. So PC acceleration depends on
which channel's plugin is used, not on the CPU architecture. H3C only ships aarch64 (NX30Pro), armv7 (BX54/BX30) and
MIPS (NX15, uClibc) plugins and no x86_64 one, which is why this package supports arm64 and armv7 only.
