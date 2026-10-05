# syntax=docker/dockerfile:1
#
# 网易 UU 加速插件（H3C 路由器版）旁路网关镜像，linux/arm64、linux/arm/v7 和 linux/amd64
#
#   docker buildx build --platform linux/arm64,linux/arm/v7,linux/amd64 -f docker/Dockerfile .
#
# H3C 没有 x86 版插件（通用 OpenWrt x86 版不支持 PC 加速），amd64 镜像用 qemu-user 模拟运行 aarch64 的 H3C NX30Pro 版。

ARG ALPINE_VERSION=3.22

# ---------- amd64：打补丁的静态 qemu-aarch64（见 docker/qemu/qemu-user-uu.patch）----------
# Alpine 3.22 的 musl 头文件缺 MADV_POPULATE_READ/WRITE（Linux 5.14），用 extra-cflags 补上
FROM alpine:${ALPINE_VERSION} AS qemu
ARG QEMU_VERSION=11.1.2
ARG QEMU_SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
RUN apk add --no-cache build-base linux-headers python3 samurai pkgconf bash perl curl xz \
        glib-dev glib-static pcre2-dev pcre2-static zlib-static
RUN curl -fsSL -o /tmp/qemu.tar.xz "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
    && echo "${QEMU_SHA256}  /tmp/qemu.tar.xz" | sha256sum -c - \
    && mkdir /src && tar xJf /tmp/qemu.tar.xz -C /src --strip-components=1 && rm /tmp/qemu.tar.xz
COPY docker/qemu/qemu-user-uu.patch /tmp/
RUN cd /src && patch -p1 < /tmp/qemu-user-uu.patch \
    && ./configure --static --target-list=aarch64-linux-user --disable-system --disable-tools \
        --disable-docs --disable-plugins --disable-werror \
        --extra-cflags="-DMADV_POPULATE_READ=22 -DMADV_POPULATE_WRITE=23" \
    && ninja -C build qemu-aarch64 \
    && strip -o /qemu-aarch64 build/qemu-aarch64

# ---------- 各架构共用 ----------
FROM alpine:${ALPINE_VERSION} AS base
RUN apk add --no-cache curl dnsmasq iproute2 iptables iptables-legacy tini
COPY files/opt/uu/bin/ /opt/uu/bin/
COPY files/opt/uu/shim/uu-shim /opt/uu/shim/
COPY files/etc/uu/uu.conf /opt/uu/uu.conf.default
COPY docker/uu-docker.sh /usr/local/bin/
# 许可证和第三方声明（amd64 镜像里的 QEMU 是 GPL，补丁一并附上）
COPY LICENSE THIRD_PARTY_NOTICES.md docker/qemu/qemu-user-uu.patch /usr/share/doc/uu-plugin-linux/
COPY licenses/ /usr/share/doc/uu-plugin-linux/licenses/
RUN for n in iptables ip6tables xtables-nft-multi brctl; do ln -s uu-shim "/opt/uu/shim/$n"; done \
    && ln -s /opt/uu/bin/uuctl /usr/local/bin/uuctl

# aarch64：H3C NX30Pro 版插件用 Alpine 自己的 musl、libstdc++、libgcc
FROM base AS image-arm64
RUN apk add --no-cache libstdc++ libgcc && echo aarch64 > /opt/uu/plugin-arch

# armv7：H3C BX54 版是 soft-float ABI（ld-musl-arm.so.1），Alpine armv7 是 hard-float（ld-musl-armhf.so.1），
#        两者互不影响：用包内 runtime/arm 的运行时，/etc/ld-musl-arm.path 只对 soft-float 程序生效
FROM base AS image-arm
COPY runtime/arm/ /opt/uu/musl/arm/
RUN ln -s /opt/uu/musl/arm/ld-musl-arm.so.1 /lib/ld-musl-arm.so.1 \
    && echo /opt/uu/musl/arm > /etc/ld-musl-arm.path \
    && echo arm > /opt/uu/plugin-arch

# amd64：aarch64 插件 + 包内 runtime/aarch64 的 musl 运行时，由 /opt/uu/qemu/qemu-aarch64 模拟运行
FROM base AS image-amd64
COPY runtime/aarch64/ /opt/uu/musl/aarch64/
COPY --from=qemu /qemu-aarch64 /opt/uu/qemu/qemu-aarch64
RUN ln -sf /opt/uu/musl/aarch64/ld-musl-aarch64.so.1 /lib/ld-musl-aarch64.so.1 \
    && echo /opt/uu/musl/aarch64 > /etc/ld-musl-aarch64.path \
    && echo aarch64 > /opt/uu/plugin-arch

FROM image-${TARGETARCH}

ENV UU_STATE_DIR=/etc/uu/cache \
    UU_LOG_FILE=/var/log/uu.log

# 配置、SN 文件和插件包缓存
VOLUME /etc/uu

# tini 回收插件 guardian 等孤儿进程，并把 SIGTERM 转给入口脚本
ENTRYPOINT ["/sbin/tini", "--", "uu-docker.sh"]
