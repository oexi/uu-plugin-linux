# Docker image (RouterOS container)

`ghcr.io/oexi/uu-plugin-linux-arm64:latest` runs the same bypass gateway in a container, for platforms without systemd
such as RouterOS `/container`. It is a multi-arch image: `linux/arm64` (H3C NX30Pro plugin), `linux/arm/v7` (H3C BX54 plugin) and `linux/amd64`
(H3C NX30Pro plugin emulated by QEMU, see [x86_64](x86_64.md)); the plugin is chosen by the image architecture, not the kernel.

The container needs its **own IP on the LAN subnet**; LAN devices use that IP as gateway and DNS, exactly as with the native install.

## Requirements

- `NET_ADMIN` and `/dev/net/tun` (RouterOS containers have both)
- `net.ipv4.ip_forward=1` in the container's network namespace (the entrypoint sets it when `/proc/sys` is writable,
  which is the case on RouterOS and with `--privileged`; otherwise pass `--sysctl net.ipv4.ip_forward=1`)
- A persistent volume on `/etc/uu`: it holds `uu.conf`, the SN file `factoryinfo` and the plugin package cache (`cache/`).
  Without it, a new SN is generated from the MAC every time the container is recreated, and the device must be bound again in the app

## RouterOS

Example for a LAN bridge `bridge` on `192.168.88.0/24` with the router at `192.168.88.1`, container IP `192.168.88.2`
and a disk mounted as `usb1` (RouterOS 7.20+ syntax; on older versions use `name=` instead of `list=` and `mounts=` instead of `mountlists=`):

```routeros
# The container's interface, attached to the LAN bridge
/interface/veth add name=veth-uu address=192.168.88.2/24 gateway=192.168.88.1
/interface/bridge/port add bridge=bridge interface=veth-uu

# Persistent /etc/uu
/container/mounts add list=uu src=/usb1/uu dst=/etc/uu

/container/config set registry-url=https://ghcr.io tmpdir=/usb1/pull
/container add remote-image=oexi/uu-plugin-linux-arm64:latest interface=veth-uu \
    root-dir=/usb1/containers/uu mountlists=uu dns=192.168.88.1 logging=yes start-on-boot=yes
/container start [find interface=veth-uu]
```

- The veth must be a port of the **LAN bridge**, not of a separate container bridge (e.g. `docker0` with its own subnet):
  devices can only use a gateway on their own subnet, so a container on another subnet logs in fine but clients get no internet
- Do **not** set `cmd` or `entrypoint`: RouterOS then runs the command directly and skips the image's entrypoint
- `logging=yes` sends the log to `/log`; inside the container, `uuctl status` and `uuctl log` work as on the native install
  (`/container shell [find interface=veth-uu]`)
- To point only some devices at the container, give their DHCP leases their own gateway/DNS (DHCP options 3 and 6) instead of changing the whole network:

  ```routeros
  /ip/dhcp-server/option add name=uu-gw code=3 value="'192.168.88.2'"
  /ip/dhcp-server/option add name=uu-dns code=6 value="'192.168.88.2'"
  /ip/dhcp-server/option/sets add name=uu options=uu-gw,uu-dns
  /ip/dhcp-server/lease set [find mac-address=AA:BB:CC:DD:EE:FF] dhcp-option-set=uu
  ```

- If the image is private, add `username=<GitHub user> password=<token with read:packages>` to `/container/config`

## Docker

[`docker/docker-compose.yml`](../docker/docker-compose.yml) gives the container a LAN IP with macvlan:

```sh
docker compose -f docker/docker-compose.yml up -d
docker exec uu uuctl status
```

With `network_mode: host` the container behaves like the native install and changes the host's iptables rules and sysctls.

## Configuration

Every key of [`uu.conf`](configuration.md) can also be set as an environment variable, which takes precedence over `/etc/uu/uu.conf`
(e.g. `DNS_UPSTREAM=223.5.5.5`, `FILTER_AAAA=0`). In addition:

| Variable | Default | Description |
|---|---|---|
| `USE_IPTABLES_NFT_BACKEND` | auto | `1` = iptables-nft, `0` = iptables-legacy. By default nft is used unless the kernel lacks nf_tables or the legacy tables already hold more rules; the choice is logged as `iptables 后端: ...` |

An SN file from another device can be copied to `/etc/uu/factoryinfo` before the first start (see [Configuration](configuration.md));
`productname` is corrected to match the image architecture.

## Differences from the native install

- No systemd: `uu-docker.sh` (run by `tini`) sets up the gateway, runs dnsmasq and `uu-monitor.sh`, and removes the rules on `SIGTERM`
- `uuctl start|stop|enable|disable` are not available; start and stop the container instead. `uuctl restart` / `update` restart the plugin within a minute
- The plugin package cache lives in `/etc/uu/cache` instead of `/var/lib/uu`
- On arm64 the runtime comes from Alpine's own musl/libstdc++; on armv7 the bundled soft-float runtime (`runtime/arm`) is used next to Alpine's hard-float musl;
  on amd64 the bundled aarch64 runtime (`runtime/aarch64`) is run by `/opt/uu/qemu/qemu-aarch64`
