#!/bin/sh
# 旁路网关 / 插件运行环境配置
#
#   uu-gateway.sh up           开启转发、NAT、放行 DNS
#   uu-gateway.sh down         撤销 up 添加的规则
#   uu-gateway.sh ensure       规则被防火墙重载冲掉 / LAN 地址变化时自动补回（monitor 每分钟调用）
#   uu-gateway.sh dns          前台运行 dnsmasq（uu-dns.service 调用）
#   uu-gateway.sh dns-enabled  DNS=1 时返回 0

PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /opt/uu/bin/uu-common.sh

STATE_FILE="${UU_RUN_DIR}/gateway.state"
IPT="iptables -w"
IP6T="ip6tables -w"

# ---------- sysctl ----------

sysctl_set() {
    local f="/proc/sys/$1"
    [ -w "$f" ] && [ "$(cat "$f")" != "$2" ] && echo "$2" > "$f"
    return 0
}

# 严格反向路径过滤会丢弃插件 tun 口回来的包，放宽为 loose
rp_loose() {
    local f="/proc/sys/net/ipv4/conf/$1/rp_filter"
    [ -w "$f" ] && [ "$(cat "$f")" = "1" ] && echo 2 > "$f"
    return 0
}

sysctl_up() {
    sysctl_set net/ipv4/ip_forward 1
    # 客户端和主路由在同一网段，不能让本机发 ICMP 重定向把客户端"指"回主路由
    sysctl_set net/ipv4/conf/all/send_redirects 0
    sysctl_set net/ipv4/conf/default/send_redirects 0
    sysctl_set "net/ipv4/conf/${LAN_IF}/send_redirects" 0
    rp_loose all
    rp_loose default
    rp_loose "$LAN_IF"
}

# ---------- iptables ----------

# 以下函数第一个参数为 "$IPT" 或 "$IP6T"

chain_reset() {
    $1 -t "$2" -N "$3" 2>/dev/null || $1 -t "$2" -F "$3"
}

jump_add() {
    $1 -t "$2" -C "$3" -j "$4" 2>/dev/null || $1 -t "$2" -I "$3" 1 -j "$4"
}

jump_del() {
    while $1 -t "$2" -D "$3" -j "$4" 2>/dev/null; do :; done
    $1 -t "$2" -F "$4" 2>/dev/null
    $1 -t "$2" -X "$4" 2>/dev/null
}

# 放行 LAN 口访问本机 DNS（IPv4 和 IPv6）
rules_in() {
    chain_reset "$1" filter UU_GW_IN
    if [ "$DNS" = "1" ]; then
        $1 -A UU_GW_IN -i "$LAN_IF" -p udp --dport 53 -j ACCEPT
        $1 -A UU_GW_IN -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT
    fi
    jump_add "$1" filter INPUT UU_GW_IN
}

# 放行 LAN 口转发（兼容 docker/ufw 把 FORWARD 默认策略设为 DROP 的主机）
rules_fwd() {
    chain_reset "$1" filter UU_GW_FWD
    $1 -A UU_GW_FWD -i "$LAN_IF" -j ACCEPT
    $1 -A UU_GW_FWD -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    jump_add "$1" filter FORWARD UU_GW_FWD
}

rules_up() {
    local cidr="$1"
    rules_in "$IPT"

    if [ "$GATEWAY" = "1" ]; then
        rules_fwd "$IPT"
        chain_reset "$IPT" nat UU_GW_NAT
        if [ "$MASQUERADE" = "1" ] && [ -n "$cidr" ]; then
            $IPT -t nat -A UU_GW_NAT -s "$cidr" ! -d "$cidr" -o "$LAN_IF" -j MASQUERADE
        fi
        jump_add "$IPT" nat POSTROUTING UU_GW_NAT
    else
        jump_del "$IPT" filter FORWARD UU_GW_FWD
        jump_del "$IPT" nat POSTROUTING UU_GW_NAT
    fi

    # 只接管 IPv4：IPv6 不转发，只放行本机 DNS
    command -v ip6tables >/dev/null 2>&1 || return 0
    rules_in "$IP6T"
    # 清理旧版本（RA 方式 IPv6 网关）留下的规则
    jump_del "$IP6T" filter FORWARD UU_GW_FWD
    jump_del "$IP6T" filter OUTPUT UU_GW_OUT
}

rules_down() {
    jump_del "$IPT" filter INPUT UU_GW_IN
    jump_del "$IPT" filter FORWARD UU_GW_FWD
    jump_del "$IPT" nat POSTROUTING UU_GW_NAT
    command -v ip6tables >/dev/null 2>&1 || return 0
    jump_del "$IP6T" filter INPUT UU_GW_IN
    jump_del "$IP6T" filter FORWARD UU_GW_FWD
    jump_del "$IP6T" filter OUTPUT UU_GW_OUT
}

rules_present() {
    $IPT -C INPUT -j UU_GW_IN 2>/dev/null || return 1
    if [ "$GATEWAY" = "1" ]; then
        $IPT -C FORWARD -j UU_GW_FWD 2>/dev/null || return 1
        $IPT -t nat -C POSTROUTING -j UU_GW_NAT 2>/dev/null || return 1
    fi
    command -v ip6tables >/dev/null 2>&1 || return 0
    $IP6T -C INPUT -j UU_GW_IN 2>/dev/null || return 1
    return 0
}

# ---------- 命令 ----------

signature() {
    echo "${LAN_IF} $(lan_cidr) gw=${GATEWAY} masq=${MASQUERADE} dns=${DNS}"
}

wait_lan_addr() {
    local i=0
    while [ -z "$(lan_addr)" ] && [ $i -lt 60 ]; do
        [ $i = 0 ] && log "等待 ${LAN_IF} 获取 IPv4 地址..."
        sleep 1
        i=$((i + 1))
    done
}

cmd_up() {
    wait_lan_addr
    [ "$GATEWAY" = "1" ] && sysctl_up
    rules_up "$(lan_cidr)"
    mkdir -p "$UU_RUN_DIR"
    signature > "$STATE_FILE"
    log "网关环境就绪：LAN ${LAN_IF} $(lan_addr)，转发=${GATEWAY} NAT=${MASQUERADE} DNS=${DNS}"
}

cmd_down() {
    rules_down
    rm -f "$STATE_FILE"
}

cmd_ensure() {
    if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$(signature)" ] && rules_present; then
        return 0
    fi
    log "检测到网关规则缺失或 LAN 地址变化，重新应用"
    cmd_up
}

cmd_dns() {
    local user group up
    command -v dnsmasq >/dev/null 2>&1 || { log "ERROR: 未安装 dnsmasq"; exit 1; }

    if id dnsmasq >/dev/null 2>&1; then user=dnsmasq; else user=nobody; fi
    if getent group dnsmasq >/dev/null 2>&1; then group=dnsmasq
    elif getent group nogroup >/dev/null 2>&1; then group=nogroup
    else group=nobody; fi

    set -- --keep-in-foreground --conf-file=/dev/null --pid-file= \
        --interface="$LAN_IF" --except-interface=lo --bind-dynamic --port=53 \
        --cache-size=2048 --user="$user" --group="$group" --log-facility=-

    # 插件只加速 IPv4（隧道丢弃 IPv6 包）。设备从主路由拿到 IPv6 时，游戏解析到 AAAA
    # 就可能直接走 IPv6 出主路由、绕过加速。官方插件在主路由上靠拦截设备的 IPv6 DNS 解决，
    # 旁路网关看不到那部分流量，改为在本机 DNS 不返回 AAAA：只影响把 DNS 指向本机的设备。
    local filter=0
    if [ "$FILTER_AAAA" = "1" ]; then
        if dnsmasq --help 2>/dev/null | grep -q -- '--filter-AAAA'; then
            set -- "$@" --filter-AAAA
            filter=1
        else
            log "WARN: dnsmasq 版本过旧（需要 2.87+），不支持 FILTER_AAAA，已忽略"
        fi
    fi

    if [ -n "$DNS_UPSTREAM" ]; then
        set -- "$@" --no-resolv
        for up in $DNS_UPSTREAM; do
            set -- "$@" --server="$up"
        done
    elif grep -qs '^nameserver' /run/systemd/resolve/resolv.conf; then
        # systemd-resolved 的真实上游
        set -- "$@" --resolv-file=/run/systemd/resolve/resolv.conf
    else
        set -- "$@" --resolv-file=/etc/resolv.conf
    fi

    log "启动 dnsmasq，监听 ${LAN_IF} 的 53 端口，过滤 AAAA=${filter}"
    exec dnsmasq "$@"
}

load_conf
case "$1" in
    dns-enabled)
        [ "$DNS" = "1" ]
        exit
        ;;
esac

if ! detect_lan_if; then
    log "ERROR: 找不到局域网网卡（LAN_IF=${LAN_IF:-自动}），请检查 ${UU_CONF}"
    [ "$1" = "down" ] && { rules_down; exit 0; }
    exit 1
fi

case "$1" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    ensure) cmd_ensure ;;
    dns)    cmd_dns ;;
    *)
        echo "用法: $0 {up|down|ensure|dns|dns-enabled}" >&2
        exit 2
        ;;
esac
