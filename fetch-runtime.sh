#!/bin/sh
# 从 Alpine Linux 仓库下载 H3C 版 uuplugin 需要的 musl 运行时：
#   ld-musl-aarch64.so.1（musl libc + 动态链接器）、libgcc_s.so.1、libstdc++.so.6
# 用法: fetch-runtime.sh <输出目录>

set -e
OUT=${1:-runtime}
BRANCH=${ALPINE_BRANCH:-v3.22}
MIRRORS="${ALPINE_MIRROR:-} https://mirrors.tuna.tsinghua.edu.cn/alpine https://mirrors.ustc.edu.cn/alpine https://dl-cdn.alpinelinux.org/alpine"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for m in $MIRRORS; do
    base="$m/$BRANCH/main/aarch64"
    if curl -fsS -m 30 -o "$tmp/APKINDEX.tar.gz" "$base/APKINDEX.tar.gz"; then
        break
    fi
    base=""
done
[ -n "$base" ] || { echo "无法访问 Alpine 镜像" >&2; exit 1; }

tar xzf "$tmp/APKINDEX.tar.gz" -C "$tmp" APKINDEX
mkdir -p "$tmp/x" "$OUT"
for p in musl libgcc libstdc++; do
    v=$(awk -F: -v p="$p" '/^P:/{n=$2} /^V:/{if (n == p) {print $2; exit}}' "$tmp/APKINDEX")
    [ -n "$v" ] || { echo "APKINDEX 中找不到 $p" >&2; exit 1; }
    echo "下载 $p-$v.apk"
    curl -fsS -m 120 -o "$tmp/$p.apk" "$base/$p-$v.apk"
    tar xzf "$tmp/$p.apk" -C "$tmp/x" 2>/dev/null || true
done

cp -L "$tmp/x/lib/ld-musl-aarch64.so.1" "$OUT/"
cp -L "$tmp/x/usr/lib/libgcc_s.so.1" "$OUT/"
cp -L "$tmp/x/usr/lib/libstdc++.so.6" "$OUT/"
chmod 755 "$OUT"/*
echo "musl 运行时已保存到 $OUT"
