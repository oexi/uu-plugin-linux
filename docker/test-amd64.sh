#!/bin/sh
# amd64 镜像冒烟测试（CI 用，也可在 x86_64 Docker 主机上手动运行）：
#   插件下载、经 qemu-aarch64 启动、拉起 guardian、登录网易服务器（106.2.95.34:16000）
#
#   sh docker/test-amd64.sh <镜像>
#
# 宿主机不能注册 aarch64 的 binfmt_misc，否则 guardian 不经镜像自带的 qemu 也能运行，测不出问题。

IMAGE=${1:?用法: $0 <镜像>}
NAME=uu-test-amd64
TIMEOUT=${TIMEOUT:-300}

fail() {
    echo "FAIL: $*"
    docker logs "$NAME" 2>&1 | tail -n 50
    docker exec "$NAME" uuctl status 2>/dev/null
    exit 1
}

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1
    docker network rm "$NAME" >/dev/null 2>&1
}
trap cleanup EXIT

if grep -qs '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64; then
    echo "宿主机已注册 qemu-aarch64 的 binfmt_misc，测试无效"
    exit 1
fi

cleanup
docker network create "$NAME" >/dev/null || exit 1
docker run -d --name "$NAME" --privileged --network "$NAME" "$IMAGE" >/dev/null || exit 1

# 登录成功：与服务器 16000 端口（0x3E80）的 TCP 连接处于 ESTABLISHED（01）
logged_in() {
    docker exec "$NAME" awk 'NR > 1 && $3 ~ /:3E80$/ && $4 == "01" {f = 1} END {exit !f}' /proc/net/tcp
}

t=0
until logged_in; do
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || fail "容器已退出"
    [ "$t" -ge "$TIMEOUT" ] && fail "${TIMEOUT} 秒内没有登录"
    sleep 5
    t=$((t + 5))
done
echo "插件已登录（${t} 秒）"

comms=$(docker exec "$NAME" sh -c 'cat /proc/[0-9]*/comm' 2>/dev/null)
echo "$comms" | grep -qx uuplugin || fail "没有名为 uuplugin 的进程"
echo "$comms" | grep -qx xuplugin-guardi || fail "guardian 没有运行"
docker exec "$NAME" iptables -S | grep -q -- '--dport 16363' || fail "插件没有添加 iptables 规则"

docker exec "$NAME" uuctl status
docker logs "$NAME" 2>&1 | tail -n 20

# 停止插件后 monitor 应能重新拉起（pkill -x 能按进程名找到模拟运行的插件）
old=$(docker exec "$NAME" cat /var/run/uuplugin.pid)
docker exec "$NAME" uuctl restart
t=0
until docker exec "$NAME" sh -c 'p=$(cat /var/run/uuplugin.pid 2>/dev/null) && [ "$p" != "$1" ] &&
        [ "$(cat /proc/$p/comm 2>/dev/null)" = uuplugin ]' sh "$old" \
    && logged_in; do
    [ "$t" -ge 180 ] && fail "uuctl restart 后插件没有重新登录"
    sleep 5
    t=$((t + 5))
done
echo "uuctl restart 后已重新登录（${t} 秒）"

docker stop -t 30 "$NAME" >/dev/null
docker logs "$NAME" 2>&1 | grep -q '已停止' || fail "容器没有正常停止"
echo "PASS"
