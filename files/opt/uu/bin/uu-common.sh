# shellcheck shell=sh
# uu-monitor.sh / uu-gateway.sh / uuctl 共用的函数与变量

UU_HOME="/opt/uu"
UU_CONF="/etc/uu/uu.conf"
UU_FACTORYINFO="/etc/uu/factoryinfo"
UU_STATE_DIR="${UU_STATE_DIR:-/var/lib/uu}"   # 持久化：插件安装包缓存（断网时也能启动）；Docker 镜像里在 /etc/uu/cache
UU_RUN_DIR="/run/uu"

# 以下路径是插件二进制里写死的，不能改
RUNNING_DIR="/var/tmp/uu"
PLUGIN_MOUNT_DIR="/var/tmp/plugmnt/uu"
H3C_INFO="/var/tmp/uu/h3c_info"
PID_FILE="/var/run/uuplugin.pid"
LANDEV_FILE="/var/run/landevname.txt"
PLUGIN_EXE="uuplugin"
# 内核进程名最长 15 个字符，xuplugin-guardian 显示为 xuplugin-guardi（pkill -x 按这个匹配）
GUARDIAN_COMM="xuplugin-guardi"
PLUGIN_CONF="uu.conf"
UPDATE_FILE="uu.update"

# Docker 镜像里没有 journald，入口脚本设置 UU_LOG_FILE，uuctl log 读这个文件
log() {
    echo "$*"
    [ -n "$UU_LOG_FILE" ] && echo "$(date '+%F %T') $*" >> "$UU_LOG_FILE"
    return 0
}

# 是否由 systemd 管理（否则是 Docker 镜像，由 uu-docker.sh 管理）
under_systemd() {
    [ -d /run/systemd/system ]
}

load_conf() {
    LAN_IF=""
    GATEWAY=1
    MASQUERADE=1
    DNS=1
    DNS_UPSTREAM=""
    FILTER_AAAA=1
    UPDATE_ON_START=1
    UPDATE_WAIT=120
    # shellcheck disable=SC1090
    [ -f "$UU_CONF" ] && . "$UU_CONF"
    # Docker 镜像：容器环境变量覆盖 uu.conf（uu-docker.sh 启动时生成）
    # shellcheck disable=SC1090
    [ -f "$UU_RUN_DIR/env.conf" ] && . "$UU_RUN_DIR/env.conf"
    return 0
}

# 网卡（按主名或 altname）是否存在
iface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

# 取网卡主名（参数可以是 altname）
iface_main_name() {
    ip -o link show dev "$1" 2>/dev/null | awk -F': ' '{print $2; exit}' | cut -d@ -f1
}

# 结果写入 LAN_IF。配置为空时取 IPv4 默认路由所在网卡
detect_lan_if() {
    if [ -z "$LAN_IF" ]; then
        LAN_IF=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    fi
    [ -n "$LAN_IF" ] || return 1
    iface_exists "$LAN_IF" || return 1
    LAN_IF=$(iface_main_name "$LAN_IF")
    [ -n "$LAN_IF" ]
}

# 输出 LAN 口第一个 IPv4 地址/前缀，如 192.168.1.2/24
lan_addr() {
    ip -4 -o addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{print $4; exit}'
}

# 输出 LAN 网段，如 192.168.1.0/24
lan_cidr() {
    ip -4 -o route show dev "$LAN_IF" scope link proto kernel 2>/dev/null | awk '$1 ~ /\// {print $1; exit}'
}

# ---------- 架构 ----------
# 只用 H3C 品牌版插件（通用 OpenWrt 版不支持 PC 加速）：
#   aarch64  H3C NX30Pro 版（musl）
#   arm      H3C BX54 版（armv7，musl，soft-float ABI）

# 本机应使用的插件架构
detect_plugin_arch() {
    case "$(uname -m)" in
        aarch64|arm64)  echo aarch64 ;;
        armv7*|armv8l)  echo arm ;;
        *) return 1 ;;
    esac
}

# 插件架构 -> H3C 型号（决定下载哪个插件包）
arch_model() {
    case "$1" in
        aarch64) echo NX30Pro ;;
        arm)     echo BX54 ;;
    esac
}

# H3C 型号 -> 插件架构
model_arch() {
    case "$(echo "$1" | tr 'A-Z' 'a-z')" in
        nx30pro)    echo aarch64 ;;
        bx54|bx30)  echo arm ;;
    esac
}

arch_ldso() {
    case "$1" in
        aarch64) echo ld-musl-aarch64.so.1 ;;
        arm)     echo ld-musl-arm.so.1 ;;
    esac
}

# ELF 文件的架构：aarch64 / arm / 其它
elf_arch() {
    case "$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')" in
        b700) echo aarch64 ;;
        2800) echo arm ;;
        *)    echo unknown ;;
    esac
}

factory_get() {
    grep "^$1=" "$UU_FACTORYINFO" 2>/dev/null | head -n1 | cut -d'=' -f2-
}
