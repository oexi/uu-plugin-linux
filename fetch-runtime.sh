#!/bin/sh
# 下载 H3C 版 uuplugin 需要的 musl 运行时（包内 runtime/ 已自带，一般不需要手动运行）
#
#   fetch-runtime.sh aarch64 <输出目录>   H3C NX30Pro 版：ld-musl-aarch64.so.1、libgcc_s、libstdc++（Alpine）
#   fetch-runtime.sh arm     <输出目录>   H3C BX54 版（armv7，soft-float ABI）：
#                                         ld-musl-arm.so.1、libgcc_s、libstdc++（Bootlin armv5-eabi musl 工具链）
#                                         + libssl/libcrypto 1.1（OpenWrt 22.03 arm_arm926ej-s）
#
# arm 版插件是 soft-float ABI（ld-musl-arm.so.1），Alpine 只有 hard-float；OpenWrt 的 libstdc++
# 关闭了 C++11 新 ABI（缺 std::__cxx11 符号），所以 libstdc++ 取自 Bootlin 工具链 sysroot。
#
# libcrypto 需要打一个 2 字节的补丁：H3C BX54 版 uuplugin 自己导出了一个永远返回 -1 的 atexit，
# musl 下 libcrypto 的 atexit(OPENSSL_cleanup) 会绑定到它，OpenSSL 1.1.1 因此认为初始化失败，
# 所有 SSL_CTX_new 返回 NULL，插件连上服务器后无法发起 TLS。补丁把 libcrypto 导入的 atexit
# 符号名改指向 dynstr 里已有的 "sched_yield"（无参数、恒返回 0），即“注册成功但什么也不做”，
# 与 H3C 不注册退出处理的意图一致。

set -e
ARCH=$1
OUT=${2:-runtime/$ARCH}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$OUT"

fetch_aarch64() {
    local branch="${ALPINE_BRANCH:-v3.22}" m base="" p v
    for m in ${ALPINE_MIRROR:-} https://mirrors.tuna.tsinghua.edu.cn/alpine https://mirrors.ustc.edu.cn/alpine https://dl-cdn.alpinelinux.org/alpine; do
        if curl -fsS -m 30 -o "$tmp/APKINDEX.tar.gz" "$m/$branch/main/aarch64/APKINDEX.tar.gz"; then
            base="$m/$branch/main/aarch64"
            break
        fi
    done
    [ -n "$base" ] || { echo "无法访问 Alpine 镜像" >&2; exit 1; }

    tar xzf "$tmp/APKINDEX.tar.gz" -C "$tmp" APKINDEX
    mkdir -p "$tmp/x"
    for p in musl libgcc libstdc++; do
        v=$(awk -F: -v p="$p" '/^P:/{n=$2} /^V:/{if (n == p) {print $2; exit}}' "$tmp/APKINDEX")
        [ -n "$v" ] || { echo "APKINDEX 中找不到 $p" >&2; exit 1; }
        echo "下载 $p-$v.apk"
        curl -fsS -m 120 -o "$tmp/$p.apk" "$base/$p-$v.apk"
        tar xzf "$tmp/$p.apk" -C "$tmp/x" 2>/dev/null || true
    done
    cp -L "$tmp/x/lib/ld-musl-aarch64.so.1" "$tmp/x/usr/lib/libgcc_s.so.1" "$tmp/x/usr/lib/libstdc++.so.6" "$OUT/"
}

fetch_arm() {
    local bl="${BOOTLIN_TOOLCHAIN:-armv5-eabi--musl--stable-2026.08-1}"
    local owrt="${OPENWRT_MIRROR:-https://downloads.openwrt.org}"/releases/22.03.7/packages/arm_arm926ej-s/base
    local sysroot="$bl/arm-buildroot-linux-musleabi/sysroot"

    echo "下载 Bootlin 工具链 $bl（约 80MB，只提取运行库）"
    curl -fsS -m 1200 "https://toolchains.bootlin.com/downloads/releases/toolchains/armv5-eabi/tarballs/$bl.tar.xz" \
        | tar xJ -C "$tmp" "$sysroot/lib/libc.so" "$sysroot/lib/libgcc_s.so.1" \
            "$sysroot/usr/lib/libstdc++.so.6" "$sysroot/usr/lib/libstdc++.so.6.0.34"
    cp -L "$tmp/$sysroot/lib/libc.so" "$OUT/ld-musl-arm.so.1"
    cp -L "$tmp/$sysroot/lib/libgcc_s.so.1" "$tmp/$sysroot/usr/lib/libstdc++.so.6" "$OUT/"

    echo "下载 OpenWrt libopenssl1.1"
    curl -fsS -m 120 -o "$tmp/ssl.ipk" "$owrt/libopenssl1.1_1.1.1w-1_arm_arm926ej-s.ipk"
    mkdir -p "$tmp/ssl"
    (cd "$tmp/ssl" && tar xzf ../ssl.ipk ./data.tar.gz && tar xzf data.tar.gz)
    cp -L "$tmp/ssl/usr/lib/libssl.so.1.1" "$tmp/ssl/usr/lib/libcrypto.so.1.1" "$OUT/"

    # libcrypto: 导入符号 atexit（第 28 个动态符号，st_name 位于文件偏移 0x118f4）-> "sched_yield"（dynstr+535）
    [ "$(md5sum < "$OUT/libcrypto.so.1.1" | cut -d' ' -f1)" = 75c185860af2d8ef11bd64af247e78da ] \
        || { echo "libcrypto.so.1.1 版本不符，无法打补丁" >&2; exit 1; }
    printf '\027\002\000\000' | dd of="$OUT/libcrypto.so.1.1" bs=1 seek=$((0x118f4)) conv=notrunc 2>/dev/null
    [ "$(md5sum < "$OUT/libcrypto.so.1.1" | cut -d' ' -f1)" = fd1e47ba15e2d33a7a2a1909df518159 ] \
        || { echo "libcrypto.so.1.1 补丁失败" >&2; exit 1; }

    # 工具链里的库带调试信息，能剥离就剥离（不影响运行）
    if command -v llvm-strip >/dev/null 2>&1; then
        llvm-strip --strip-unneeded "$OUT/ld-musl-arm.so.1" "$OUT/libgcc_s.so.1" "$OUT/libstdc++.so.6" || true
    else
        strip --strip-unneeded "$OUT/ld-musl-arm.so.1" "$OUT/libgcc_s.so.1" "$OUT/libstdc++.so.6" 2>/dev/null || true
    fi
}

case "$ARCH" in
    aarch64) fetch_aarch64 ;;
    arm)     fetch_arm ;;
    *) echo "用法: $0 {aarch64|arm} [输出目录]" >&2; exit 2 ;;
esac
chmod 755 "$OUT"/*
echo "musl 运行时已保存到 $OUT"
