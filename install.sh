#!/bin/sh
# 网易 UU 加速插件（H3C NX30Pro 移植版）Linux arm64 安装脚本
#
#   sudo ./install.sh                         # 安装并启动，开机自启
#   sudo ./install.sh --factoryinfo FILE      # 使用已有的 SN 文件（默认按本机 LAN 网卡 MAC 生成）
#   sudo ./install.sh --lan-if eth0           # 指定局域网网卡（默认取默认路由所在网卡）
#   sudo ./install.sh --ipv6                  # 同时作为 IPv6 旁路网关（见 /etc/uu/uu.conf 的 IPV6 说明）
#   sudo ./install.sh --no-start              # 只安装不启动

set -e
cd "$(dirname "$0")"
SRC=$(pwd)

FACTORYINFO=""
LAN_IF_ARG=""
IPV6_ARG=""
NO_START=0
while [ $# -gt 0 ]; do
    case "$1" in
        --factoryinfo) FACTORYINFO=$2; shift 2 ;;
        --lan-if)      LAN_IF_ARG=$2; shift 2 ;;
        --ipv6)        IPV6_ARG=1; shift ;;
        --no-start)    NO_START=1; shift ;;
        -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

info() { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 运行（sudo $0）"
[ "$(uname -m)" = aarch64 ] || die "仅支持 aarch64 (arm64)，当前为 $(uname -m)"
[ -d /run/systemd/system ] || die "需要 systemd"

# ---------- 依赖 ----------
need=""
command -v curl     >/dev/null 2>&1 || need="$need curl"
command -v iptables >/dev/null 2>&1 || need="$need iptables"
command -v ip       >/dev/null 2>&1 || need="$need iproute2"
command -v dnsmasq  >/dev/null 2>&1 || need="$need dnsmasq"
command -v ip6tables >/dev/null 2>&1 || need="$need iptables"
command -v md5sum   >/dev/null 2>&1 || need="$need coreutils"
command -v pkill    >/dev/null 2>&1 || need="$need procps"
command -v tar      >/dev/null 2>&1 || need="$need tar"
if [ -n "$need" ]; then
    info "安装依赖:$need"
    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu 上只要 dnsmasq 程序本体，不装会占用 53 端口的 dnsmasq 系统服务
        pkgs=$(echo "$need" | sed 's/dnsmasq/dnsmasq-base/')
        apt-get update -qq || true
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs
    elif command -v dnf >/dev/null 2>&1; then
        # shellcheck disable=SC2046
        dnf install -y $(echo "$need" | sed 's/iproute2/iproute/')
    elif command -v pacman >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        pacman -S --noconfirm --needed $need
    else
        die "请手动安装:$need"
    fi
fi

# ---------- musl 运行时（H3C 版插件是 musl 动态链接程序）----------
MUSL_DIR=/opt/uu/musl/lib
LDSO=/lib/ld-musl-aarch64.so.1
mkdir -p "$MUSL_DIR"
if [ ! -f "$SRC/runtime/ld-musl-aarch64.so.1" ]; then
    info "包内无 musl 运行时，从 Alpine 镜像下载"
    sh "$SRC/fetch-runtime.sh" "$SRC/runtime" || die "下载 musl 运行时失败"
fi
cp -f "$SRC/runtime/ld-musl-aarch64.so.1" "$SRC/runtime/libgcc_s.so.1" "$SRC/runtime/libstdc++.so.6" "$MUSL_DIR/"
chmod 755 "$MUSL_DIR"/*
if [ -e "$LDSO" ] && [ "$(readlink -f "$LDSO")" != "$MUSL_DIR/ld-musl-aarch64.so.1" ]; then
    info "系统已有 $LDSO，保留并复用"
else
    ln -sf "$MUSL_DIR/ld-musl-aarch64.so.1" "$LDSO"
fi
# musl 动态链接器的库搜索路径（不影响 glibc 程序）
touch /etc/ld-musl-aarch64.path
grep -qx "$MUSL_DIR" /etc/ld-musl-aarch64.path || echo "$MUSL_DIR" >> /etc/ld-musl-aarch64.path

# ---------- 程序文件 ----------
info "安装程序到 /opt/uu"
mkdir -p /opt/uu/bin /opt/uu/shim
cp -f "$SRC"/files/opt/uu/bin/* /opt/uu/bin/
chmod 755 /opt/uu/bin/*
rm -f /opt/uu/shim/*
cp -f "$SRC/files/opt/uu/shim/uu-shim" /opt/uu/shim/
chmod 755 /opt/uu/shim/uu-shim
for n in iptables ip6tables xtables-nft-multi brctl; do
    ln -sf uu-shim "/opt/uu/shim/$n"
done
ln -sf /opt/uu/bin/uuctl /usr/local/bin/uuctl
cp -f "$SRC/README.md" /opt/uu/README.md

# ---------- 配置 ----------
mkdir -p /etc/uu
if [ ! -f /etc/uu/uu.conf ]; then
    cp "$SRC/files/etc/uu/uu.conf" /etc/uu/uu.conf
elif ! cmp -s "$SRC/files/etc/uu/uu.conf" /etc/uu/uu.conf; then
    cp "$SRC/files/etc/uu/uu.conf" /etc/uu/uu.conf.new
    info "保留现有 /etc/uu/uu.conf，新版默认配置见 /etc/uu/uu.conf.new"
fi
if [ -n "$LAN_IF_ARG" ]; then
    ip link show dev "$LAN_IF_ARG" >/dev/null 2>&1 || die "网卡 $LAN_IF_ARG 不存在"
    sed -i "s/^LAN_IF=.*/LAN_IF=\"$LAN_IF_ARG\"/" /etc/uu/uu.conf
fi

if [ -n "$IPV6_ARG" ]; then
    if grep -q '^IPV6=' /etc/uu/uu.conf; then
        sed -i 's/^IPV6=.*/IPV6=1/' /etc/uu/uu.conf
    else
        echo 'IPV6=1' >> /etc/uu/uu.conf
    fi
fi

. /opt/uu/bin/uu-common.sh
load_conf
detect_lan_if || die "找不到局域网网卡，请用 --lan-if 指定"
info "局域网网卡: $LAN_IF $(lan_addr)"

if [ -n "$FACTORYINFO" ]; then
    [ -f "$FACTORYINFO" ] || die "$FACTORYINFO 不存在"
    cp "$FACTORYINFO" /etc/uu/factoryinfo
    info "使用指定的 SN 文件"
elif [ ! -f /etc/uu/factoryinfo ]; then
    mac=$(cat "/sys/class/net/$LAN_IF/address")
    cat > /etc/uu/factoryinfo <<EOF
productname=NX30Pro
ethaddr=$mac
hardversion=VER.A
bootversion=100
manucode=$mac
EOF
    info "已按 $LAN_IF 的 MAC ($mac) 生成 SN 文件 /etc/uu/factoryinfo"
fi
chmod 644 /etc/uu/factoryinfo

# ---------- 内核模块 ----------
cat > /etc/modules-load.d/uu.conf <<'EOF'
tun
nf_conntrack_netlink
EOF
modprobe tun 2>/dev/null || true
modprobe nf_conntrack_netlink 2>/dev/null || true
[ -c /dev/net/tun ] || die "/dev/net/tun 不可用（内核需要 TUN 支持）"

# ---------- 自检：musl 运行时 ----------
"$LDSO" 2>&1 | grep -qi musl || die "musl 动态链接器无法运行"

# ---------- systemd ----------
info "安装 systemd 服务"
cp -f "$SRC/files/etc/systemd/system/uu.service" "$SRC/files/etc/systemd/system/uu-dns.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable uu.service >/dev/null 2>&1
if [ "$NO_START" = 0 ]; then
    systemctl restart uu.service
    info "已启动。首次启动会从网易服务器下载插件（约 3MB），稍候用 'uuctl status' 查看"
fi

ip4=$(lan_addr | cut -d/ -f1)
if [ "$IPV6" = "1" ]; then
    v6note="
IPv6：已开启。本机会向局域网通告自己为 IPv6 默认路由器和 DNS，设备的 IPv6 无需手动设置。"
else
    v6note="
IPv6：未开启（设备的 IPv6 仍走主路由）。如需加速 IPv6 流量，在 /etc/uu/uu.conf 设 IPV6=1 后 uuctl restart。"
fi
cat <<EOF

安装完成。
  管理命令: uuctl status | log | restart | update
  配置文件: /etc/uu/uu.conf    SN 文件: /etc/uu/factoryinfo

局域网设备（游戏机/PC/手机）手动设置：
  IP 地址: 与本机同网段的空闲地址     子网掩码: 同主路由
  网关:    ${ip4}
  DNS:     ${ip4}
然后在手机 UU 主机加速 App 中添加路由器/绑定设备即可加速。
${v6note}
EOF
