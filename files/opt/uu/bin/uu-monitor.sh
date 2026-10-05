#!/bin/sh
# 网易 UU 加速插件守护 / 更新脚本（由 H3C NX30Pro 的 h3c_uuplugin_monitor.sh 移植）
#
# 由 systemd（uu.service）前台运行：
#   1. 启动时向网易服务器查询最新插件版本，md5 与本地缓存不同则先下载更新（UPDATE_ON_START）
#   2. 拉起 uuplugin，挂了 5 秒内重新拉起
#   3. 插件发现新版本时会写 uu.update 标记并退出，本脚本下载新包、校验 md5、替换后重启插件
#   4. 收到 SIGTERM 时先让插件自行退出（清理它自己加的 iptables/路由规则）

. /opt/uu/bin/uu-common.sh

DOWNLOAD_URL="https://router.uu.163.com/api/plugin?type=h3c-"
BACKTAR="${UU_STATE_DIR}/uu.tar.gz"
BACKTAR_MD5="${UU_STATE_DIR}/uu.tar.gz.md5"

PLUGIN_PID=""
CHECK_PENDING=0
LAST_CHECK=0

now() {
    cut -d. -f1 /proc/uptime
}

# 可被 SIGTERM 打断的 sleep
nap() {
    sleep "$1" &
    wait $! 2>/dev/null
}

system_init() {
    ulimit -HS -s 8192 2>/dev/null

    local productname sn
    productname=$(factory_get productname | tr 'A-Z' 'a-z')
    sn=$(factory_get manucode)
    if [ -z "$productname" ] || [ -z "$sn" ]; then
        log "ERROR: ${UU_FACTORYINFO} 缺少 productname 或 manucode"
        exit 1
    fi
    DOWNLOAD_URL="${DOWNLOAD_URL}${productname}&sn=${sn}"

    # 插件子进程（iptables 等）走垫片，见 /opt/uu/shim/uu-shim
    PATH="${UU_HOME}/shim:${PATH}"
    UU_LAN_IF="$LAN_IF"
    export PATH UU_LAN_IF
}

check_dir() {
    mkdir -p "$RUNNING_DIR" "$PLUGIN_MOUNT_DIR" "$UU_STATE_DIR" /tmp/uu
}

# 插件启动时从 h3c_info 读取设备 SN，缺失会直接退出
ensure_h3c_info() {
    if ! cmp -s "$UU_FACTORYINFO" "$H3C_INFO"; then
        cp "$UU_FACTORYINFO" "$H3C_INFO"
        chmod 644 "$H3C_INFO"
    fi
    echo "$LAN_IF" > "$LANDEV_FILE"
}

# H3C 版插件默认把 LAN 口当作 br-lan，通过插件配置项 lan_ifname 指定真实网卡。
# uu.conf 随插件包发布，每次解压/更新后都要重新写入。
ensure_lan_ifname() {
    local conf="${RUNNING_DIR}/${PLUGIN_CONF}"
    [ -f "$conf" ] || return 0
    grep -qx "lan_ifname=${LAN_IF}" "$conf" && return 0
    sed -i '/^lan_ifname=/d' "$conf"
    [ -n "$(tail -c1 "$conf")" ] && echo >> "$conf"
    echo "lan_ifname=${LAN_IF}" >> "$conf"
}

file_md5() {
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

# 本地缓存包有效则输出其 md5
backtar_md5() {
    [ -f "$BACKTAR" ] && [ -f "$BACKTAR_MD5" ] || return 1
    local m
    m=$(file_md5 "$BACKTAR")
    [ -n "$m" ] && [ "$m" = "$(cat "$BACKTAR_MD5")" ] || return 1
    echo "$m"
}

# 查询服务器最新版本，设置 REMOTE_URL / REMOTE_MD5 / REMOTE_URL2
fetch_info() {
    local info
    info=$(curl -s -k -m 15 --connect-timeout 10 -H "Accept:text/plain" "$DOWNLOAD_URL") || return 1
    REMOTE_URL=$(echo "$info" | cut -d ',' -f 1)
    REMOTE_MD5=$(echo "$info" | cut -d ',' -f 2)
    REMOTE_URL2=$(echo "$info" | cut -d ',' -f 3)
    case "$REMOTE_URL" in
        http://*|https://*) ;;
        *) log "插件信息接口返回异常: $(echo "$info" | head -c 200)"; return 1 ;;
    esac
    echo "$REMOTE_MD5" | grep -qE '^[0-9a-f]{32}$' || { log "插件 md5 异常: $REMOTE_MD5"; return 1; }
    return 0
}

# 下载最新插件包到缓存。$1=force 时即使 md5 相同也重新下载
# 返回 0：缓存已是最新（UPDATED=1 表示本次有更新）；非 0：失败
update_backtar() {
    UPDATED=0
    fetch_info || return 1

    if [ "$1" != "force" ] && [ "$(backtar_md5)" = "$REMOTE_MD5" ]; then
        return 0
    fi

    local tmp="${BACKTAR}.download" url
    for url in "$REMOTE_URL" "$REMOTE_URL2"; do
        [ -n "$url" ] || continue
        rm -f "$tmp"
        if curl -s -k -m 300 --connect-timeout 10 -o "$tmp" "$url" && [ "$(file_md5 "$tmp")" = "$REMOTE_MD5" ] \
            && tar tzf "$tmp" 2>/dev/null | grep -qx "\(\./\)\?${PLUGIN_EXE}"; then
            mv -f "$tmp" "$BACKTAR"
            echo "$REMOTE_MD5" > "$BACKTAR_MD5"
            UPDATED=1
            log "插件包下载成功: $(echo "$url" | sed 's/?.*//') md5=${REMOTE_MD5}"
            return 0
        fi
        log "下载失败或 md5 不符: $(echo "$url" | sed 's/?.*//')"
    done
    rm -f "$tmp"
    return 1
}

# 把缓存包解压到运行目录（保留 h3c_info）
install_backtar() {
    backtar_md5 >/dev/null || { log "本地插件包缺失或损坏"; return 1; }
    local f
    for f in "$RUNNING_DIR"/* "$RUNNING_DIR"/.[!.]*; do
        [ -e "$f" ] || continue
        [ "$f" = "$H3C_INFO" ] && continue
        rm -rf "$f"
    done
    if ! tar xzf "$BACKTAR" -C "$RUNNING_DIR"; then
        log "解压插件包失败"
        return 1
    fi
    chmod 755 "${RUNNING_DIR}/${PLUGIN_EXE}" "${RUNNING_DIR}/xuplugin-guardian" 2>/dev/null
    local arch
    arch=$(elf_arch "${RUNNING_DIR}/${PLUGIN_EXE}")
    if [ ! -e "/lib/$(arch_ldso "$arch")" ]; then
        log "ERROR: 插件是 ${arch} 架构，本机没有对应的 musl 运行时（/lib/$(arch_ldso "$arch")）。" \
            "请检查 ${UU_FACTORYINFO} 的 productname 是否与本机架构匹配，或重新运行 install.sh"
    fi
    log "已安装插件 $(plugin_version)（${arch}$([ -n "$(plugin_qemu "$arch")" ] && echo "，qemu 模拟运行")）"
    return 0
}

plugin_version() {
    sed -n 's/^version=//p' "${RUNNING_DIR}/${PLUGIN_CONF}" 2>/dev/null
}

pid_alive() {
    [ -n "$1" ] || return 1
    local st
    st=$(sed -n 's/^[0-9]* (.*) \([A-Za-z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != "Z" ] && [ "$(cat "/proc/$1/comm" 2>/dev/null)" = "$PLUGIN_EXE" ]
}

# 输出正在运行的 uuplugin pid
running_pid() {
    local p
    p=$(head -n1 "$PID_FILE" 2>/dev/null | tr -cd '0-9')
    if pid_alive "$p"; then echo "$p"; return 0; fi
    if pid_alive "$PLUGIN_PID"; then echo "$PLUGIN_PID"; return 0; fi
    return 1
}

check_running() {
    running_pid >/dev/null
}

start_acc() {
    ensure_h3c_info
    if [ ! -x "${RUNNING_DIR}/${PLUGIN_EXE}" ]; then
        install_backtar || return 1
    fi
    ensure_lan_ifname
    rm -f "$PID_FILE"
    local qemu
    qemu=$(plugin_qemu "$(elf_arch "${RUNNING_DIR}/${PLUGIN_EXE}")")
    # shellcheck disable=SC2086
    (cd "$RUNNING_DIR" && exec $qemu "./${PLUGIN_EXE}" "${RUNNING_DIR}/${PLUGIN_CONF}" >/dev/null 2>&1) &
    PLUGIN_PID=$!
    log "uuplugin $(plugin_version) 已启动 (pid ${PLUGIN_PID})"
}

stop_acc() {
    local p i
    p=$(running_pid)
    if [ -n "$p" ]; then
        kill -TERM "$p" 2>/dev/null
        i=0
        while pid_alive "$p" && [ $i -lt 20 ]; do
            sleep 0.5
            i=$((i + 1))
        done
        pid_alive "$p" && kill -KILL "$p" 2>/dev/null
    fi
    # 兜底：清理残留进程（包括上一次运行遗留的）
    pkill -x "$PLUGIN_EXE" 2>/dev/null
    pkill -x "$GUARDIAN_COMM" 2>/dev/null
    sleep 0.5
    pkill -KILL -x "$PLUGIN_EXE" 2>/dev/null
    pkill -KILL -x "$GUARDIAN_COMM" 2>/dev/null
    PLUGIN_PID=""
}

on_term() {
    log "收到停止信号，停止 uuplugin"
    stop_acc
    exit 0
}

# 启动阶段的版本检查：在 UPDATE_WAIT 秒内反复尝试（开机时网络可能还没就绪）
boot_update() {
    local deadline
    deadline=$(( $(now) + UPDATE_WAIT ))
    while :; do
        if update_backtar; then
            if [ "$UPDATED" = "1" ]; then
                log "启动检查：已更新到最新插件"
            else
                log "启动检查：插件已是最新 (md5=${REMOTE_MD5})"
            fi
            CHECK_PENDING=0
            return 0
        fi
        [ "$(now)" -ge "$deadline" ] && break
        nap 5
    done
    CHECK_PENDING=1
    LAST_CHECK=$(now)
    if backtar_md5 >/dev/null; then
        log "启动检查：暂时无法连接更新服务器，先使用本地缓存版本，稍后后台重试"
    else
        log "启动检查：无法连接更新服务器且本地无缓存，等待网络恢复后自动下载"
    fi
    return 1
}

# 插件运行中：若启动时没检查成功，每 10 分钟重试一次，发现新版立即切换
deferred_update() {
    [ "$CHECK_PENDING" = "1" ] || return 0
    [ $(( $(now) - LAST_CHECK )) -ge 600 ] || return 0
    LAST_CHECK=$(now)
    update_backtar || return 0
    CHECK_PENDING=0
    if [ "$UPDATED" = "1" ]; then
        log "后台检查发现新版本，重启插件"
        stop_acc
        install_backtar && start_acc
    fi
}

# 插件退出后的处理（对应原脚本 check_acc）
check_acc() {
    check_running && return 0

    if [ -f "${RUNNING_DIR}/${UPDATE_FILE}" ]; then
        log "插件请求更新 (${UPDATE_FILE})"
        stop_acc
        if update_backtar force; then
            install_backtar
        else
            log "更新失败，继续使用当前版本"
            rm -f "${RUNNING_DIR}/${UPDATE_FILE}"
        fi
    fi

    if ! backtar_md5 >/dev/null; then
        # 无缓存时每 5 秒重试，日志每分钟最多一条
        if [ $(( $(now) - ${LAST_NOPKG_LOG:-0} )) -ge 60 ]; then
            log "本地无可用插件包，尝试下载..."
            LAST_NOPKG_LOG=$(now)
        fi
        update_backtar force || return 1
        CHECK_PENDING=0
        install_backtar || return 1
    fi

    stop_acc
    start_acc
}

trap on_term TERM INT HUP

load_conf
if ! detect_lan_if; then
    log "ERROR: 找不到局域网网卡（LAN_IF=${LAN_IF:-自动}），请检查 ${UU_CONF}"
    exit 1
fi
system_init
check_dir
stop_acc
ensure_h3c_info
log "LAN 网卡 ${LAN_IF}，下载类型 $(echo "$DOWNLOAD_URL" | sed 's/.*type=\([^&]*\).*/\1/')"

if [ "$UPDATE_ON_START" = "1" ]; then
    boot_update
fi
# 每次启动都从缓存包重新解压，保证运行的就是刚检查过的版本
if backtar_md5 >/dev/null; then
    install_backtar
fi

while :; do
    check_acc
    nap 1
    if check_running; then
        "${UU_HOME}/bin/uu-gateway.sh" ensure
        deferred_update
        nap 60
    else
        nap 5
    fi
done
