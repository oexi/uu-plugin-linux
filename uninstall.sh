#!/bin/sh
# 卸载 UU 加速插件。--purge 同时删除 /etc/uu（配置和 SN 文件）
[ "$(id -u)" = 0 ] || { echo "请用 root 运行" >&2; exit 1; }

systemctl disable --now uu.service 2>/dev/null
systemctl stop uu-dns.service 2>/dev/null
rm -f /etc/systemd/system/uu.service /etc/systemd/system/uu-dns.service
systemctl daemon-reload

# 服务停止时 uu-gateway.sh down 已清理规则，这里再兜底一次
[ -x /opt/uu/bin/uu-gateway.sh ] && /opt/uu/bin/uu-gateway.sh down >/dev/null 2>&1
pkill -KILL -x uuplugin 2>/dev/null
pkill -KILL -x xuplugin-guardian 2>/dev/null

if [ "$(readlink -f /lib/ld-musl-aarch64.so.1)" = /opt/uu/musl/lib/ld-musl-aarch64.so.1 ]; then
    rm -f /lib/ld-musl-aarch64.so.1
fi
if [ -f /etc/ld-musl-aarch64.path ]; then
    sed -i '\#^/opt/uu/musl/lib$#d' /etc/ld-musl-aarch64.path
    [ -s /etc/ld-musl-aarch64.path ] || rm -f /etc/ld-musl-aarch64.path
fi

rm -rf /opt/uu /var/lib/uu /var/tmp/uu /var/tmp/plugmnt /tmp/uu
rm -f /usr/local/bin/uuctl /etc/modules-load.d/uu.conf /var/run/uuplugin.pid /var/run/landevname.txt
[ "$1" = "--purge" ] && rm -rf /etc/uu

if [ "$1" = "--purge" ]; then
    echo "已卸载（含配置）。"
else
    echo "已卸载。配置保留在 /etc/uu（--purge 可删除）"
fi
echo "注意：ip_forward 等内核参数未还原（其它服务可能依赖），如需还原请重启或手动设置。"
