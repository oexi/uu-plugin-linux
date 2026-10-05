# Third-party notices

This project redistributes the following third-party software, unmodified unless noted.
Their licenses are in [`licenses/`](licenses/).

| Component | Where | Version / origin | License |
|---|---|---|---|
| musl libc (`ld-musl-aarch64.so.1`) | `runtime/aarch64/`, amd64 Docker image | 1.2.5, Alpine Linux 3.22 package `musl` | MIT ([musl-COPYRIGHT.txt](licenses/musl-COPYRIGHT.txt)) |
| libstdc++, libgcc_s | `runtime/aarch64/`, amd64 Docker image | GCC 14.2.0, Alpine Linux 3.22 packages `libstdc++`, `libgcc` | GPL-3.0 with the GCC Runtime Library Exception 3.1 ([GPL-3.0.txt](licenses/GPL-3.0.txt), [GCC-exception-3.1.txt](licenses/GCC-exception-3.1.txt)) |
| musl libc (`ld-musl-arm.so.1`) | `runtime/arm/`, armv7 Docker image | 1.2.6, Bootlin toolchain `armv5-eabi--musl--stable-2026.08-1` | MIT ([musl-COPYRIGHT.txt](licenses/musl-COPYRIGHT.txt)) |
| libstdc++, libgcc_s | `runtime/arm/`, armv7 Docker image | GCC 15.3.0, Bootlin toolchain `armv5-eabi--musl--stable-2026.08-1` | GPL-3.0 with the GCC Runtime Library Exception 3.1 |
| OpenSSL (`libssl.so.1.1`, `libcrypto.so.1.1`) | `runtime/arm/`, armv7 Docker image | 1.1.1w, OpenWrt 22.03.7 package `libopenssl1.1_1.1.1w-1_arm_arm926ej-s`. **Modified**: `libcrypto.so.1.1` has a 2-byte patch that renames its imported `atexit` symbol to `sched_yield` (see [docs/implementation.md](docs/implementation.md)) | OpenSSL License and SSLeay License ([OpenSSL-1.1.1.txt](licenses/OpenSSL-1.1.1.txt)) |
| QEMU (`/opt/uu/qemu/qemu-aarch64`) | amd64 Docker image | 11.1.2 with [`docker/qemu/qemu-user-uu.patch`](docker/qemu/qemu-user-uu.patch), built by [`docker/Dockerfile`](docker/Dockerfile) | GPL-2.0-or-later ([GPL-2.0.txt](licenses/GPL-2.0.txt)) |

The Docker images additionally contain Alpine Linux packages (busybox, iptables, iproute2, dnsmasq, curl, tini, glib and others
statically linked into QEMU) under their own licenses; their sources are available from Alpine Linux
(<https://gitlab.alpinelinux.org/alpine/aports>).

## Source code

- **QEMU**: <https://download.qemu.org/qemu-11.1.2.tar.xz> (sha256 `731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016`)
  plus [`docker/qemu/qemu-user-uu.patch`](docker/qemu/qemu-user-uu.patch); `docker/Dockerfile` (stage `qemu`) is the complete build recipe
- **GCC / musl (aarch64)**: Alpine Linux aports, packages `gcc` and `musl` of the 3.22 branch
- **GCC / musl (arm)**: the Bootlin toolchain above is built with Buildroot; sources: <https://toolchains.bootlin.com>
- **OpenSSL 1.1.1w**: <https://www.openssl.org/source/old/1.1.1/openssl-1.1.1w.tar.gz>; the OpenWrt package recipe is in the OpenWrt 22.03 source tree

## Not included

The NetEase UU plugin (`uuplugin`, `xuplugin-guardian`) is proprietary software of NetEase. It is neither stored in this repository nor in the Docker images;
it is downloaded from NetEase's servers when the service starts.
