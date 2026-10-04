#!/bin/sh
# 旁路网关 / 插件运行环境配置
#
#   uu-gateway.sh up           开启转发、NAT、放行 DNS
#   uu-gateway.sh down         撤销 up 添加的规则
#   uu-gateway.sh ensure       规则被防火墙重载冲掉 / LAN 地址变化时自动补回（monitor 每分钟调用）
#   uu-gateway.sh dns          前台运行 dnsmasq：DNS 和 IPv6 路由通告（uu-dns.service 调用）
#   uu-gateway.sh dns-enabled  需要运行 dnsmasq（DNS=1 或 IPV6=1）时返回 0

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

# 开启 IPv6 转发后，内核默认不再处理 RA（accept_ra=1 时），本机会丢掉自己的 SLAAC 地址和
# IPv6 默认路由。把由内核处理 RA 的网卡改为 accept_ra=2（转发时仍接收 RA）。
# accept_ra=0 的网卡（systemd-networkd / NetworkManager 在用户态处理 RA）不受影响，保持不动。
sysctl6_up() {
    local d n
    for d in /proc/sys/net/ipv6/conf/*; do
        n=${d##*/}
        [ "$n" = all ] || [ "$n" = lo ] && continue
        [ "$(cat "$d/accept_ra" 2>/dev/null)" = "1" ] && echo 2 > "$d/accept_ra"
    done
    sysctl_set net/ipv6/conf/all/forwarding 1
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

# 放行 LAN 口访问本机 DNS
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

    command -v ip6tables >/dev/null 2>&1 || return 0
    rules_in "$IP6T"
    if [ "$GATEWAY" = "1" ] && [ "$IPV6" = "1" ]; then
        rules_fwd "$IP6T"
        # IPv6 没有关闭 ICMP 重定向的 sysctl：本机从同一网卡转发时会发重定向，
        # 让客户端改为直接找主路由，绕过本机。在出口丢弃。
        chain_reset "$IP6T" filter UU_GW_OUT
        $IP6T -A UU_GW_OUT -o "$LAN_IF" -p icmpv6 --icmpv6-type redirect -j DROP
        jump_add "$IP6T" filter OUTPUT UU_GW_OUT
    else
        jump_del "$IP6T" filter FORWARD UU_GW_FWD
        jump_del "$IP6T" filter OUTPUT UU_GW_OUT
    fi
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
    if [ "$GATEWAY" = "1" ] && [ "$IPV6" = "1" ]; then
        $IP6T -C FORWARD -j UU_GW_FWD 2>/dev/null || return 1
        $IP6T -C OUTPUT -j UU_GW_OUT 2>/dev/null || return 1
    fi
    return 0
}

# ---------- 命令 ----------

signature() {
    echo "${LAN_IF} $(lan_cidr) gw=${GATEWAY} masq=${MASQUERADE} dns=${DNS} ipv6=${IPV6}"
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
    if [ "$GATEWAY" = "1" ]; then
        sysctl_up
        [ "$IPV6" = "1" ] && sysctl6_up
    fi
    rules_up "$(lan_cidr)"
    mkdir -p "$UU_RUN_DIR"
    signature > "$STATE_FILE"
    log "网关环境就绪：LAN ${LAN_IF} $(lan_addr)，转发=${GATEWAY} NAT=${MASQUERADE} DNS=${DNS} IPv6=${IPV6}"
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
    local user group up port
    command -v dnsmasq >/dev/null 2>&1 || { log "ERROR: 未安装 dnsmasq"; exit 1; }

    if id dnsmasq >/dev/null 2>&1; then user=dnsmasq; else user=nobody; fi
    if getent group dnsmasq >/dev/null 2>&1; then group=dnsmasq
    elif getent group nogroup >/dev/null 2>&1; then group=nogroup
    else group=nobody; fi

    if [ "$DNS" = "1" ]; then port=53; else port=0; fi
    set -- --keep-in-foreground --conf-file=/dev/null --pid-file= \
        --interface="$LAN_IF" --except-interface=lo --bind-dynamic --port="$port" \
        --cache-size=2048 --user="$user" --group="$group" --log-facility=-

    if [ "$GATEWAY" = "1" ] && [ "$IPV6" = "1" ]; then
        # IPv6 路由通告：把本机通告为高优先级 IPv6 默认路由器（并通告本机为 IPv6 DNS）。
        # 前缀沿用 LAN 口上主路由下发的前缀（constructor），不另起地址段，只做 SLAAC，不跑 DHCPv6。
        # 每 30 秒通告一次，路由器生存期 180 秒：本机停机后客户端最多 3 分钟回落到主路由。
        set -- "$@" --enable-ra --dhcp-range="::,constructor:${LAN_IF},ra-only" \
            --ra-param="${LAN_IF},high,30,180" --quiet-ra
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

    log "启动 dnsmasq：${LAN_IF} DNS=${DNS} IPv6路由通告=$([ "$GATEWAY$IPV6" = 11 ] && echo 1 || echo 0)"
    exec dnsmasq "$@"
}

load_conf
case "$1" in
    dns-enabled)
        [ "$DNS" = "1" ] || { [ "$GATEWAY" = "1" ] && [ "$IPV6" = "1" ]; }
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
