# IPv6

**The plugin accelerates IPv4 only.** Judging from the plugin binary (`unsupport pkt v6`, `ip6_rx_dropped`),
the acceleration tunnel drops IPv6 packets. Its "IPv6 support" exists to keep acceleration from failing: on the main router it finds
the accelerated device's IPv6 addresses via `ip -6 neigh` and blocks the device's IPv6 DNS with
`ip6tables -m mac --mac-source <device> --dport 53 -j DROP`, forcing the device onto the IPv4 DNS that the plugin hijacks,
so games resolve IPv4 addresses and go through acceleration.

In bypass gateway mode, a device's IPv6 DNS and IPv6 traffic go straight to the main router and never pass through this machine,
so that blocking rule has no effect. This package uses an equivalent approach: the local dnsmasq runs with `--filter-AAAA`
(`FILTER_AAAA=1`, default) and returns no IPv6 addresses.

- Only devices whose DNS points to this machine (i.e. the devices you chose to accelerate) are affected; IPv6 for all other devices is untouched
- Those devices lose IPv6 name resolution, so websites and games use IPv4, which is normally fine for consoles
- A device that also uses the IPv6 DNS announced by the main router (some PCs and phones do) may still get IPv6 addresses;
  disable IPv6 on such a device, or stop the main router from announcing IPv6 DNS
- This machine neither forwards IPv6 nor sends router advertisements, so IPv6 routing of other LAN devices is unchanged
