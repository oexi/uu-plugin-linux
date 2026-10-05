#!/bin/sh
# Docker 镜像入口（代替 systemd 的 uu.service / uu-dns.service）
#
#   1. 容器环境变量覆盖 /etc/uu/uu.conf，首次启动生成 uu.conf 和 SN 文件
#   2. 选择 iptables 后端（内核没有 nf_tables 时用 legacy，例如部分 RouterOS）
#   3. uu-gateway.sh up，后台运行 dnsmasq（DNS=1）和 uu-monitor.sh
#   4. 收到 SIGTERM 时先停 monitor（它让插件自行退出并清理规则），再撤销网关规则

# 插件包缓存放进 /etc/uu，容器只需挂载这一个目录
UU_STATE_DIR=${UU_STATE_DIR:-/etc/uu/cache}
UU_LOG_FILE=${UU_LOG_FILE:-/var/log/uu.log}
export UU_STATE_DIR UU_LOG_FILE

. /opt/uu/bin/uu-common.sh

CONF_KEYS="LAN_IF GATEWAY MASQUERADE DNS DNS_UPSTREAM FILTER_AAAA UPDATE_ON_START UPDATE_WAIT"
MONITOR_PID=""
DNS_PID=""

die() {
    log "ERROR: $*"
    exit 1
}

# 容器里设置了的环境变量写入 env.conf，load_conf 在 uu.conf 之后读取
write_env_conf() {
    local k v
    mkdir -p "$UU_RUN_DIR"
    : > "$UU_RUN_DIR/env.conf"
    for k in $CONF_KEYS; do
        eval "[ -n \"\${$k+x}\" ]" || continue
        eval "v=\$$k"
        # 单引号转义，值原样保留
        printf "%s='%s'\n" "$k" "$(printf '%s' "$v" | sed "s/'/'\\\\''/g")" >> "$UU_RUN_DIR/env.conf"
    done
    if [ -s "$UU_RUN_DIR/env.conf" ]; then
        log "环境变量覆盖配置: $(cut -d= -f1 "$UU_RUN_DIR/env.conf" | tr '\n' ' ')"
    fi
}

# USE_IPTABLES_NFT_BACKEND=1 用 nft，0 用 legacy；默认：nf_tables 可用且 legacy 里没有更多规则时用 nft
select_iptables_backend() {
    local backend nft legacy n
    case "$USE_IPTABLES_NFT_BACKEND" in
        1) backend=nft ;;
        0) backend=legacy ;;
        *)
            if ! iptables-nft -w 10 -S >/dev/null 2>&1; then
                backend=legacy
            else
                nft=$({ iptables-nft-save; ip6tables-nft-save; } 2>/dev/null | grep -c '^-A')
                legacy=$({ iptables-legacy-save; ip6tables-legacy-save; } 2>/dev/null | grep -c '^-A')
                if [ "$legacy" -gt "$nft" ]; then backend=legacy; else backend=nft; fi
            fi
            ;;
    esac
    # 插件和 uu-gateway.sh 都调用 iptables / ip6tables，直接把这些命令指向选定的后端
    for n in iptables ip6tables; do
        ln -sf "xtables-${backend}-multi" "/usr/sbin/$n"
        ln -sf "xtables-${backend}-multi" "/usr/sbin/$n-save"
        ln -sf "xtables-${backend}-multi" "/usr/sbin/$n-restore"
    done
    UU_IPT_BACKEND=$backend
    export UU_IPT_BACKEND
    log "iptables 后端: ${backend}"
}

# 首次启动按 LAN 网卡 MAC 生成 SN 文件；productname 与本机架构匹配
ensure_factoryinfo() {
    local arch model mac cur
    # 按镜像架构而不是内核：arm64 内核上跑 armv7 镜像时 uname -m 仍是 aarch64
    arch=$(cat /opt/uu/plugin-arch)
    model=$(arch_model "$arch")
    if [ ! -f "$UU_FACTORYINFO" ]; then
        mac=$(cat "/sys/class/net/$LAN_IF/address")
        cat > "$UU_FACTORYINFO" <<EOT
productname=$model
ethaddr=$mac
hardversion=VER.A
bootversion=100
manucode=$mac
EOT
        log "已按 $LAN_IF 的 MAC ($mac) 生成 SN 文件 $UU_FACTORYINFO（请把 /etc/uu 挂载到持久化目录，否则重建容器后 SN 会变）"
    fi
    cur=$(factory_get productname)
    if [ "$(model_arch "$cur")" != "$arch" ]; then
        sed -i "s/^productname=.*/productname=$model/" "$UU_FACTORYINFO"
        log "SN 文件 productname 由 ${cur:-空} 改为 $model（与本机架构匹配）"
    fi
    log "架构: ${arch}（内核 $(uname -m)$([ -n "$(plugin_qemu "$arch")" ] && echo "，qemu 模拟运行")），H3C ${model} 版插件，SN $(factory_get manucode)"
}

check_env() {
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null && chmod 666 /dev/net/tun
    fi
    [ -c /dev/net/tun ] || die "/dev/net/tun 不可用（docker 需要 --device /dev/net/tun）"
    iptables -w -S >/dev/null 2>&1 || die "无法操作 iptables（docker 需要 --cap-add NET_ADMIN）"
}

# dnsmasq 退出后 5 秒重启（对应 uu-dns.service 的 Restart=always）
dns_loop() {
    trap 'kill "$child" 2>/dev/null; exit 0' TERM
    while :; do
        /opt/uu/bin/uu-gateway.sh dns &
        child=$!
        wait "$child"
        sleep 5
    done
}

cleanup() {
    trap - TERM INT
    [ -n "$MONITOR_PID" ] && kill -TERM "$MONITOR_PID" 2>/dev/null && wait "$MONITOR_PID"
    [ -n "$DNS_PID" ] && kill -TERM "$DNS_PID" 2>/dev/null && wait "$DNS_PID"
    /opt/uu/bin/uu-gateway.sh down
    log "已停止"
}

on_term() {
    log "收到停止信号"
    cleanup
    exit 0
}

# 日志文件只保留本次启动的内容
: > "$UU_LOG_FILE"

mkdir -p /etc/uu "$UU_STATE_DIR"
[ -f "$UU_CONF" ] || cp /opt/uu/uu.conf.default "$UU_CONF"
write_env_conf
load_conf
detect_lan_if || die "找不到局域网网卡（LAN_IF=${LAN_IF:-自动}）"
select_iptables_backend
check_env
ensure_factoryinfo

trap on_term TERM INT
/opt/uu/bin/uu-gateway.sh up || die "网关环境配置失败"
if [ "$GATEWAY" = 1 ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then
    log "WARN: net.ipv4.ip_forward 未开启，局域网设备无法通过本容器上网" \
        "（docker 用 --privileged 或 --sysctl net.ipv4.ip_forward=1）"
fi

if [ "$DNS" = 1 ]; then
    dns_loop &
    DNS_PID=$!
fi
/opt/uu/bin/uu-monitor.sh &
MONITOR_PID=$!

ip4=$(lan_addr | cut -d/ -f1)
log "局域网设备设置：网关 = ${ip4}    DNS = ${ip4}"

# monitor 正常情况下不会退出；退出了就让容器退出，由容器运行时重启
wait "$MONITOR_PID"
code=$?
MONITOR_PID=""
log "uu-monitor.sh 退出 (${code})"
cleanup
exit 1
