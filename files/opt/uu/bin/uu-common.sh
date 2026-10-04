# shellcheck shell=sh
# uu-monitor.sh / uu-gateway.sh / uuctl 共用的函数与变量

UU_HOME="/opt/uu"
UU_CONF="/etc/uu/uu.conf"
UU_FACTORYINFO="/etc/uu/factoryinfo"
UU_STATE_DIR="/var/lib/uu"           # 持久化：插件安装包缓存（断网时也能启动）
UU_RUN_DIR="/run/uu"

# 以下路径是插件二进制里写死的，不能改
RUNNING_DIR="/var/tmp/uu"
PLUGIN_MOUNT_DIR="/var/tmp/plugmnt/uu"
H3C_INFO="/var/tmp/uu/h3c_info"
PID_FILE="/var/run/uuplugin.pid"
LANDEV_FILE="/var/run/landevname.txt"
PLUGIN_EXE="uuplugin"
PLUGIN_CONF="uu.conf"
UPDATE_FILE="uu.update"

log() {
    echo "$*"
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

factory_get() {
    grep "^$1=" "$UU_FACTORYINFO" 2>/dev/null | head -n1 | cut -d'=' -f2-
}
