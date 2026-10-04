# syntax=docker/dockerfile:1
#
# 网易 UU 加速插件（H3C 路由器版）旁路网关镜像，linux/arm64 和 linux/arm/v7
#
#   docker buildx build --platform linux/arm64,linux/arm/v7 -f docker/Dockerfile .

FROM alpine:3.22

ARG TARGETARCH

RUN apk add --no-cache curl dnsmasq iproute2 iptables iptables-legacy tini

# aarch64：H3C NX30Pro 版插件用 Alpine 自己的 musl、libstdc++、libgcc。
# armv7：H3C BX54 版是 soft-float ABI（ld-musl-arm.so.1），Alpine armv7 是 hard-float（ld-musl-armhf.so.1），
#        两者互不影响：用包内 runtime/arm 的运行时，/etc/ld-musl-arm.path 只对 soft-float 程序生效
RUN --mount=type=bind,source=runtime,target=/tmp/runtime \
    mkdir -p /opt/uu && case "$TARGETARCH" in \
        arm64) apk add --no-cache libstdc++ libgcc \
            && echo aarch64 > /opt/uu/plugin-arch ;; \
        arm) mkdir -p /opt/uu/musl/arm \
            && cp /tmp/runtime/arm/* /opt/uu/musl/arm/ \
            && ln -s /opt/uu/musl/arm/ld-musl-arm.so.1 /lib/ld-musl-arm.so.1 \
            && echo /opt/uu/musl/arm > /etc/ld-musl-arm.path \
            && echo arm > /opt/uu/plugin-arch ;; \
        *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac

COPY files/opt/uu/bin/ /opt/uu/bin/
COPY files/opt/uu/shim/uu-shim /opt/uu/shim/
COPY files/etc/uu/uu.conf /opt/uu/uu.conf.default
COPY docker/uu-docker.sh /usr/local/bin/
RUN for n in iptables ip6tables xtables-nft-multi brctl; do ln -s uu-shim "/opt/uu/shim/$n"; done \
    && ln -s /opt/uu/bin/uuctl /usr/local/bin/uuctl

ENV UU_STATE_DIR=/etc/uu/cache \
    UU_LOG_FILE=/var/log/uu.log

# 配置、SN 文件和插件包缓存
VOLUME /etc/uu

# tini 回收插件 guardian 等孤儿进程，并把 SIGTERM 转给入口脚本
ENTRYPOINT ["/sbin/tini", "--", "uu-docker.sh"]
