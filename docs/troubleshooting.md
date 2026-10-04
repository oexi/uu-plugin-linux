# Troubleshooting

| Symptom | Fix |
|---|---|
| `uuctl status` shows the plugin not running | Check `uuctl log`; confirm the runtime exists with `ls -l /lib/ld-musl-*.so.1` |
| On armv7 the plugin runs but never logs in | Check that the md5 of `/opt/uu/musl/arm/libcrypto.so.1.1` is `fd1e47ba15e2d33a7a2a1909df518159` (atexit patch applied); re-run `install.sh` |
| Log keeps saying no local plugin package, retrying download | This machine cannot reach `router.uu.163.com` / `uurouter.gdl.netease.com`; check network and DNS |
| uu-dns fails with `Address already in use` | Port 53 is taken by another DNS service: set `DNS=0` in `/etc/uu/uu.conf` and point clients at that service |
| Clients have no internet after setting the gateway | Check the counters with `iptables -L UU_GW_FWD -v -n`; make sure clients use the gateway/DNS shown by `uuctl status` |
| The app cannot find the device | Phone and this machine must be on the same LAN; also set the phone's gateway to this machine and retry |
| This machine's IP changed | Nothing to do, the monitor updates the rules within a minute; remember to update the clients' gateway/DNS |
| Accelerated devices still resolve IPv6 addresses | The device also uses the IPv6 DNS from the main router: disable IPv6 on the device or stop the main router from announcing IPv6 DNS |
| Log says dnsmasq does not support FILTER_AAAA | System dnsmasq is older than 2.87 (e.g. Debian 11): upgrade the OS or disable IPv6 on game devices |
