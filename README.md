# 网易 UU 加速器插件（H3C 路由器版）— Linux ARM 旁路网关移植

把 H3C 路由器固件中的 UU 加速插件（已移植到 OpenWrt 的版本）移植到通用 Linux ARM 设备
（arm64 和 armv7，Debian / Ubuntu / Armbian 等 systemd 发行版）。部署后本机即为“UU 旁路网关”：
局域网设备把 **网关和 DNS 设为本机 IP** 即可通过 UU 主机加速 App 绑定并加速。

- 开机自启（systemd `uu.service`）
- 每次启动先向网易服务器检查插件版本，有新版自动下载、校验 md5 后再启动；
  运行中插件发现新版本时也会自动更新重启
- 自动配置旁路网关：IP 转发、MASQUERADE、关闭 ICMP 重定向、放行 DNS，并内置 dnsmasq 提供 DNS
- IPv6 防绕过：本机 DNS 不返回 IPv6 地址，避免被加速设备的游戏流量走 IPv6 绕过加速
- 使用 H3C 品牌版插件（支持主机和 PC 加速），不用网易通用 OpenWrt 版（不支持 PC 加速，见第 7 节）

## 1. 要求

| 项目 | 要求 |
|---|---|
| 架构 | **aarch64 (arm64)**：使用 H3C NX30Pro 版插件<br>**armv7（32 位 ARM）**：使用 H3C BX54 版插件（需 ARMv7 及以上 CPU，树莓派 1/Zero 等 ARMv6 不支持）<br>x86_64、MIPS 等不支持 |
| 系统 | systemd 发行版（Debian/Ubuntu/Armbian 等，已在 Ubuntu 24.04 arm64 / armhf 上测试） |
| 内核 | 支持 TUN、netfilter（发行版内核默认都有） |
| 网络 | 本机与主路由、局域网设备在同一网段，**建议本机使用固定 IP** |

依赖（`curl iptables iproute2 dnsmasq`）缺失时 `install.sh` 会通过 apt/dnf/pacman 自动安装。
Debian/Ubuntu 上只装 `dnsmasq-base`（只有程序本体，不会启动占用 53 端口的系统 dnsmasq 服务）。

插件二进制不在本包内，首次启动时从网易服务器下载。

## 2. 安装

```sh
tar xzf uu-plugin-linux-arm64.tar.gz
cd uu-plugin-linux-arm64
sudo ./install.sh
```

可选参数：

```sh
sudo ./install.sh --lan-if eth0                  # 指定局域网网卡（默认：默认路由所在网卡）
sudo ./install.sh --factoryinfo ./factoryinfo    # 使用指定的 SN 文件（默认按本机 MAC 生成）
sudo ./install.sh --arch arm                     # 指定插件架构 aarch64|arm（默认按 uname -m 自动选择）
sudo ./install.sh --no-start                     # 只安装不启动
```

安装完成后查看状态：

```sh
uuctl status
```

```
服务:       active / 开机自启 enabled
DNS 服务:   active
插件进程:   2401
插件版本:   v14.9.4
uu_status:  0  (0 = 正常)
设备型号:   NX30Pro  SN: 0a:fb:37:75:0a:d5
插件架构:   aarch64（本机 aarch64）
LAN 网卡:   eth0 192.168.1.2/24
过滤 AAAA:  开启  (DNS 指向本机的设备只走 IPv4)

局域网设备设置：网关 = 192.168.1.2    DNS = 192.168.1.2
```

## 3. 局域网设备设置

在需要加速的设备（Switch / PS5 / Xbox / PC 等）上手动设置网络：

| 项 | 值 |
|---|---|
| IP 地址 | 与主路由同网段的空闲地址（或保持 DHCP 分配的地址） |
| 子网掩码 | 与主路由相同 |
| **网关** | **本机 IP** |
| **DNS** | **本机 IP** |

然后打开 UU 主机加速 App → 添加路由器 / 绑定设备即可加速。手机需连同一局域网（手机本身也可按上表设置）。

也可以在主路由的 DHCP 设置里把网关、DNS 下发为本机 IP，让全部设备自动走旁路网关。
注意这样本机宕机时全网都会断网，一般只建议对游戏设备单独设置。

## 4. IPv6

**插件只加速 IPv4。** 从插件二进制看（`unsupport pkt v6`、`ip6_rx_dropped`），加速隧道会丢弃 IPv6 包。
它的“IPv6 支持”是防止加速失效：在主路由上通过 `ip -6 neigh` 找到被加速设备的 IPv6 地址，
用 `ip6tables -m mac --mac-source <设备> --dport 53 -j DROP` 拦截设备的 IPv6 DNS，
迫使设备改用已被插件劫持的 IPv4 DNS，游戏因此解析到 IPv4 地址，走进加速。

旁路网关模式下，设备的 IPv6 DNS 和 IPv6 流量直接走主路由，不经过本机，上面这条拦截规则不起作用。
本包用等效的办法：本机 dnsmasq 开启 `--filter-AAAA`（`FILTER_AAAA=1`，默认），不返回 IPv6 地址。

- 只影响把 DNS 设为本机的设备（也就是你指定要加速的设备），其它设备的 IPv6 完全不受影响
- 这些设备会失去 IPv6 解析，访问网站、游戏都走 IPv4，对游戏机一般没有影响
- 设备若同时使用主路由经 IPv6 下发的 DNS（部分电脑、手机会这样），仍可能拿到 IPv6 地址；
  这种设备可以在系统里关闭 IPv6，或在主路由上关闭 IPv6 DNS 下发
- 本机不转发 IPv6，也不发送路由通告，不会改变局域网其它设备的 IPv6 路由

## 5. 管理

```sh
uuctl status      # 状态
uuctl log         # 实时日志（monitor + dnsmasq）
uuctl restart     # 重启（会重新检查更新）
uuctl update      # 立即强制重新下载插件并重启（60 秒内生效）
uuctl enable|disable   # 开机自启开关
```

或直接使用 `systemctl {start|stop|restart|status} uu`，`journalctl -u uu`。

配置文件 `/etc/uu/uu.conf`（修改后执行 `uuctl restart`）：

| 配置 | 默认 | 说明 |
|---|---|---|
| `LAN_IF` | 空 | 局域网网卡，空 = 默认路由所在网卡 |
| `GATEWAY` | 1 | 开启旁路网关转发 |
| `MASQUERADE` | 1 | 转发流量做 NAT（旁路网关标准做法，避免回程绕过本机） |
| `DNS` | 1 | 在 `LAN_IF` 的 53 端口运行 dnsmasq；本机已有 DNS 服务（AdGuard Home 等）时设为 0 |
| `FILTER_AAAA` | 1 | 本机 DNS 不返回 IPv6 地址，见第 4 节（需要 dnsmasq 2.87+） |
| `DNS_UPSTREAM` | 空 | 上游 DNS（空格分隔），空 = 系统当前上游 |
| `UPDATE_ON_START` | 1 | 启动时检查并更新插件 |
| `UPDATE_WAIT` | 120 | 启动时等待更新服务器的最长秒数，超时先用本地缓存版本启动 |

SN 文件 `/etc/uu/factoryinfo`：

```
productname=NX30Pro
ethaddr=<本机MAC>
hardversion=VER.A
bootversion=100
manucode=<本机MAC>
```

- `productname` 决定下载的插件类型：`https://router.uu.163.com/api/plugin?type=h3c-<productname 小写>&sn=<manucode>`。
  arm64 为 `NX30Pro`，armv7 为 `BX54`，`install.sh` 会按本机架构自动修正（只改型号，SN 不变）
- `manucode` 是 UU 识别设备的 SN。**同一个 SN 不要同时用在两台设备上**（会注册冲突/互踢）。
  要沿用旧 OpenWrt 设备上的绑定，可 `--factoryinfo` 拷贝旧文件，并停用旧设备上的插件。

## 6. 卸载

```sh
sudo ./uninstall.sh            # 保留 /etc/uu
sudo ./uninstall.sh --purge    # 连配置和 SN 文件一起删除
```

## 7. 实现说明（相对 OpenWrt 版的改动）

### 文件布局

| 路径 | 说明 |
|---|---|
| `/opt/uu/bin/uu-monitor.sh` | 守护 / 更新脚本（由 `h3c_uuplugin_monitor.sh` 改写），`uu.service` 主进程 |
| `/opt/uu/bin/uu-gateway.sh` | 旁路网关规则、dnsmasq 启动 |
| `/opt/uu/bin/uuctl` | 管理命令（`/usr/local/bin/uuctl`） |
| `/opt/uu/shim/` | 只给 uuplugin 使用的命令垫片（见下） |
| `/opt/uu/musl/<arch>/` | musl 运行时；`/lib/ld-musl-aarch64.so.1` 或 `/lib/ld-musl-arm.so.1` 指向这里 |
| `/etc/uu/` | 配置和 SN 文件 |
| `/var/lib/uu/uu.tar.gz` | 插件包缓存（持久化，断网开机也能启动） |
| `/var/tmp/uu/` | 插件运行目录（路径写死在插件里） |
| `/etc/systemd/system/uu.service`, `uu-dns.service` | systemd 服务 |

### 移植要点

1. **musl 运行时**：H3C 版 `uuplugin` 是 musl 动态链接程序，glibc 发行版上不能直接运行。
   包内 `runtime/<arch>/` 自带所需的库（`fetch-runtime.sh` 可重新下载生成），安装到 `/opt/uu/musl/<arch>`，
   通过 `/etc/ld-musl-<arch>.path` 指定搜索路径，不影响系统里的 glibc 程序。

   | 架构 | 插件 | 运行时来源 |
   |---|---|---|
   | aarch64 | H3C NX30Pro | `ld-musl-aarch64.so.1`、libstdc++、libgcc_s：Alpine 3.22 |
   | armv7 | H3C BX54（soft-float ABI） | `ld-musl-arm.so.1`、libstdc++、libgcc_s：Bootlin armv5-eabi musl 工具链；libssl/libcrypto 1.1：OpenWrt 22.03 `arm_arm926ej-s` |

   armv7 的几个坑：插件是 soft-float ABI（`ld-musl-arm.so.1`），Alpine 只有 hard-float；
   OpenWrt 的 libstdc++ 关闭了 C++11 新 ABI（缺 `std::__cxx11` 符号），只能用 Bootlin 的；
   另外 libcrypto 打了一个 2 字节补丁（见下一条）。
2. **armv7 的 OpenSSL 初始化问题**：H3C BX54 版 `uuplugin` 自己导出了一个 `atexit`，实现只有
   `return -1`。musl 下 libcrypto 里的 `atexit(OPENSSL_cleanup)` 会绑定到这个空函数，OpenSSL 1.1.1
   因此判定初始化失败，`SSL_CTX_new` 全部返回 NULL，表现为插件 TCP 连上服务器后立即断开、始终登录不上。
   包内的 libcrypto 把导入符号 `atexit` 改指向字符串表里已有的 `sched_yield`（无参数、恒返回 0），
   相当于“注册成功但不做任何事”，与 H3C 不注册退出处理的意图一致（`fetch-runtime.sh` 会校验 md5 后自动打这个补丁）。
   aarch64 版把 OpenSSL 静态链接进了插件，没有这个问题。
3. **iptables 扩展**：插件用 `XTABLES_LIBDIR=/lib iptables ...` 执行命令，在 Debian/Ubuntu 上
   iptables 扩展不在 `/lib`，所有 `--dport`、`-j MARK`、`-j DNAT` 规则都会失败。monitor 把
   `/opt/uu/shim` 放到插件的 PATH 最前面，垫片清掉该变量后再调用系统 iptables。
4. **LAN 网卡**：H3C 版默认把 LAN 口当作 `br-lan`（OpenWrt 网桥），而且会用
   `brctl show | grep br-` 猜网桥（宿主机上 docker 的 `br-xxxx` 会被误选）。插件配置支持
   `lan_ifname` 项，monitor 每次解压/更新插件包后都往 `uu.conf` 写入 `lan_ifname=<LAN_IF>`，
   并让 `brctl` 垫片返回空。普通网卡（eth0/end0 等）无需改成网桥。
5. **进程检测**：原脚本解析 busybox `ps` 输出，改为读 `/proc/<pid>`（注意 `xuplugin-guardian`
   的内核进程名被截断为 15 字符的 `xuplugin-guardi`）；原 `h3c_info` 误删问题
   （OpenWrt 移植版已修复）这里同样保留 `h3c_info`，每次启动前从 `/etc/uu/factoryinfo` 校正。
6. **自动更新**：
   - 启动时：查询 `router.uu.163.com` 最新包 md5，与缓存不同则下载（主/备两个下载地址），
     校验 md5 并确认包内有 `uuplugin` 后替换缓存，每次启动都从缓存重新解压，保证运行的是最新版
   - 开机网络未就绪：最多等 `UPDATE_WAIT` 秒，超时用缓存版本先启动，之后每 10 分钟后台重试，
     发现新版立即切换；无缓存时持续重试直到下载成功
   - 运行中：插件自己发现新版本时写 `uu.update` 并退出，monitor 下载新包后重启插件（与原版一致）
7. **旁路网关**（`uu-gateway.sh`，规则都在独立链 `UU_GW_IN` / `UU_GW_FWD` / `UU_GW_NAT` 中）：
   - `net.ipv4.ip_forward=1`
   - 关闭 `send_redirects`：客户端与主路由同网段，否则本机会发 ICMP 重定向把客户端“指回”主路由
   - 严格 `rp_filter`(1) 放宽为 loose(2)，防止插件 tun 口回包被丢
   - `FORWARD` 放行 LAN 口流量（兼容 docker / ufw 把 FORWARD 默认策略设为 DROP 的主机）
   - LAN 网段访问外网做 MASQUERADE
   - `INPUT` 放行 LAN 口 53 端口
   - monitor 每分钟检查一次，规则被防火墙重载冲掉或 LAN 地址变化时自动补回；服务停止时全部撤销
   - 只接管 IPv4，不转发 IPv6；`ip6tables` 只放行 LAN 口访问本机 DNS
8. **DNS**：`uu-dns.service` 运行独立的 dnsmasq 实例（`--conf-file=/dev/null`，不读系统 dnsmasq 配置），
   只监听 LAN 网卡地址（IPv4 和 IPv6），不提供 DHCP，可与 systemd-resolved（127.0.0.53）共存；
   默认开启 `--filter-AAAA`，见第 4 节。

### 为什么只用 H3C 版，而不用网易通用 OpenWrt 版

网易官方提供 `openwrt-aarch64/arm/x86_64/mipsel` 等通用版，但通用版不支持 PC 加速。对比同版本（v14.9.4）
的 H3C 版与通用版二进制：设备识别（如 `may_be_windows`）、设备记录、`console_device_block_reason` 等
代码两边都有，差别只在编译时写死的渠道信息：

| | H3C 版 | 通用 OpenWrt 版 |
|---|---|---|
| 登录时上报的 `plugin_type` | `h3c-nx30pro` / `h3c-bx54` | `openwrt-x86_64` 等 |
| 远程链路服务器 | `h3crglg.uu.163.com` | `rglg.uu.netease.com` |
| 设备 SN 来源 | `/var/tmp/uu/h3c_info`（`manucode`） | `/usr/sbin/uu/.sn` / 网卡 MAC |

插件登录（Connect 消息）时会上报 `sn`、`model`、`type`、`plugin_type`、`real_sn`、`firmware_type`，
能加速哪些设备由服务器按渠道决定，H3C 渠道放开了 PC 加速。所以能不能加速 PC 取决于用的是哪个渠道的插件，
跟 CPU 架构无关。H3C 只有 aarch64（NX30Pro）、armv7（BX54/BX30）和 MIPS（NX15，uClibc）三种插件，
没有 x86_64 版，所以本包只支持 arm64 和 armv7。

## 8. 常见问题

| 现象 | 处理 |
|---|---|
| `uuctl status` 插件未运行 | `uuctl log` 看日志；`ls -l /lib/ld-musl-*.so.1` 确认运行时存在 |
| armv7 上插件在运行但一直登录不上 | 确认 `/opt/uu/musl/arm/libcrypto.so.1.1` 的 md5 为 `fd1e47ba15e2d33a7a2a1909df518159`（打过 atexit 补丁），重新运行 `install.sh` |
| 一直“本地无可用插件包，尝试下载” | 本机无法访问 `router.uu.163.com` / `uurouter.gdl.netease.com`，检查网络和 DNS |
| uu-dns 启动失败 `Address already in use` | 本机 53 端口被其它 DNS 服务占用：`/etc/uu/uu.conf` 设 `DNS=0`，客户端 DNS 指向那个服务 |
| 客户端设了网关后上不了网 | `iptables -L UU_GW_FWD -v -n` 看计数；确认客户端网关/DNS 填的是 `uuctl status` 显示的地址 |
| App 搜不到设备 | 手机和本机在同一局域网；手机也把网关设为本机后再试 |
| 本机 IP 改了 | 无需操作，monitor 1 分钟内自动更新规则；记得同步修改客户端网关/DNS |
| 加速设备仍解析到 IPv6 地址 | 设备同时用了主路由下发的 IPv6 DNS：在设备上关闭 IPv6，或在主路由关闭 IPv6 DNS 下发 |
| 日志提示 dnsmasq 不支持 FILTER_AAAA | 系统 dnsmasq 低于 2.87（如 Debian 11），升级系统，或给游戏设备关闭 IPv6 |

## 9. 测试情况

在 Ubuntu 24.04 arm64 和 armhf（systemd 容器 + 模拟局域网）上验证：

- 安装 / 重复安装 / 卸载
- 开机自启
- 启动时自动更新（缓存为旧版本时自动下载 v14.9.4）
- 插件请求更新（`uu.update`）后重新下载并重启
- 开机断网（有缓存先启动；无缓存时持续重试，网络恢复后自动下载启动）
- 插件连上网易服务器（`106.2.95.34:16000`），`uu_status=0`；iptables 自检规则可正常添加/删除
- 局域网客户端网关/DNS 指向本机后正常上网（含 FORWARD 默认 DROP 的情况）、DNS 解析正常
- 防火墙规则被删除后 1 分钟内自动恢复；停止服务后插件和网关规则全部清理
- armv7（H3C BX54 版，32 位 ARM 用户态）：安装、登录网易服务器、局域网客户端经本机上网和 DNS、
  插件异常退出后自动拉起（旧 guardian 进程被清理）、重启自启、卸载
- 从旧版本目录结构（`/opt/uu/musl/lib`）升级到按架构分目录
- 双栈网络：DNS 指向本机时 AAAA 查询返回空、A 查询正常；本机不转发 IPv6、不发送路由通告；从旧版 RA 方式升级后残留的 IPv6 转发规则被自动清理

**未验证**：手机 App 绑定和实际游戏加速（需要真实局域网、UU 账号和游戏设备），请部署后实测。
