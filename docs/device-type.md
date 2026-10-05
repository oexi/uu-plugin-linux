# Device type detection (Linux PCs show up as Android phones)

The UU app lists each LAN device with a type (Windows PC, Android/iOS phone, console …), and the type decides which games
can be accelerated. A Linux PC is detected as an **Android phone** by default, so only a short list of games is offered.
Making it look like Windows fixes that.

## How the plugin decides

The plugin captures LAN traffic with a raw packet socket and looks at the initial IP TTL of the device's packets
(analysed on v14.9.4):

| Initial TTL | Detected as |
|---|---|
| 128 | `windows` |
| 64 | `android` |
| 255 | `apple` |

Linux uses TTL 64 like Android, hence the misdetection. Which packets count:

- **A DHCP packet from the device was captured**: the TTL of the DHCP packet is used, and `windows` additionally requires the
  DHCP vendor class to contain `MSFT` and a DHCP hostname
- **Otherwise** (e.g. static IP): the TTL of the device's DNS queries is used; depending on server-side rules, the TCP TTL must match as well

The packets are captured before netfilter, so rewriting the TTL with iptables / tc on this box has no effect;
the change has to be made on the PC.

## Fix (on the Linux PC)

1. Set the default TTL to 128, persistently:

   ```sh
   echo 'net.ipv4.ip_default_ttl = 128' | sudo tee /etc/sysctl.d/99-ttl128.conf
   sudo sysctl --system
   ```

2. Use a **static IP** (gateway and DNS = this box). Then no DHCP packet is involved and step 1 is enough.

   With DHCP, `sysctl` does not apply: most DHCP clients hard-code the TTL of their packets.
   systemd-networkd, NetworkManager's internal client, dhcpcd and udhcpc always send 64 (detected as Android).
   ISC `dhclient` sends 128; add `send vendor-class-identifier "MSFT 5.0";` to `/etc/dhcp/dhclient.conf` and make sure it sends
   a hostname. NetworkManager can use it with `[main] dhcp=dhclient` and `ipv4.dhcp-vendor-class-identifier "MSFT 5.0"`.

3. Run `uuctl restart` on this box and refresh the device list in the app; if the old type sticks, remove and re-add the device.

Part of the detection rules is delivered by the server and may change in later versions.
