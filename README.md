# OpenWrt for two home access points, with signed self-updates

Automated builds of official [OpenWrt](https://openwrt.org) for the access points on one home network.
Every device gets the same OpenWrt release, the same package versions and the same tooling, so roaming
between them and their Home Assistant sensors match. A GitHub Actions workflow checks for new OpenWrt
releases and package updates every day, then builds, verifies, signs and publishes **one release for
all devices**. Each AP sees the update in LuCI and installs it with one click, or by itself after a soak
period.

| Device | Profile | Target | Status |
|---|---|---|---|
| Netgear WAX214v2 | `netgear_wax214v2` | `ramips/mt7621` (mipsel_24kc) | built |
| GL.iNet Beryl AX (GL-MT3000) | `glinet_gl-mt3000` | `mediatek/filogic` (aarch64) | being added |

No OpenWrt fork: images come from the upstream **Image Builder** with the official packages, plus the
package lists and files in this repo. Packages installed with `apk` don't survive a sysupgrade, so
anything that should stay belongs in [`packages/`](packages).

## Layout

```
devices/<profile>.conf     target, AP id (/etc/ap-id), Go arch for Oh My Posh, auto-install hour, size limit
packages/common.txt        packages for every device (one list → identical versions everywhere)
packages/<profile>.txt     that device's extras (prefix with - to remove a default package)
overlay/common/            files added to every image
overlay/<profile>/         files added to one device's image (on top of common)
build/decide.sh            should this run build? (new OpenWrt release or changed inputs)
build/build.sh             one device: Image Builder + overlays + preinit patch + Oh My Posh/Zsh
build/verify.sh            fails the build unless every piece is in place (incl. a secret scan)
build/publish.sh           all devices: version-drift gate, SHA256SUMS, usign signature, release
```

## What's different from stock OpenWrt

1. **Preinit/failsafe address moved off the LAN.** Stock OpenWrt puts `192.168.1.1` on the LAN port
   for a few seconds early in every boot, while it waits for failsafe. On a network whose gateway *is*
   `192.168.1.1`, the access point briefly impersonates the router at every reboot. Clients that look
   up the gateway in that window lose connectivity until their ARP cache refreshes. These builds use
   **`192.168.255.1`** instead: [`build/build.sh`](build/build.sh) takes each release's own
   `/lib/preinit/00_preinit.conf` from that device's official image and changes just the two address lines.
2. **DHCP-client LAN by default.** On a fresh install, LAN becomes a DHCP client and the DHCP/RA servers
   are disabled, so the AP joins an existing network instead of acting as a router
   ([`99-lan-dhcp`](overlay/common/etc/uci-defaults/99-lan-dhcp)). Existing settings are never touched.
3. **`ghupdate`, signed updates from this repo.** [`/usr/sbin/ghupdate`](overlay/common/usr/sbin/ghupdate)
   checks this repo's latest release every hour. It verifies the `usign` signature on `SHA256SUMS`, the
   image checksum and `sysupgrade -T`, then upgrades with settings kept. OpenWrt's Attended Sysupgrade is
   deliberately left out, because it would offer official images without fix 1.

## Extras baked in

| Package(s) | What for |
|---|---|
| `luci`, `luci-ssl` | Web UI on http **and** https (no forced redirect) |
| `zsh`, `zoneinfo-america` | Shell; full timezone data |
| `htop`, `tmux`, `nano`, `curl`, `iperf3`, `tcpdump-mini` | Everyday CLI |
| `mtr-nojson`, `ethtool`, `drill` | Network diagnostics: per-hop loss, link/PoE port errors, DNS queries |
| `lldpd` | Announces the AP to the switch via LLDP/CDP (name, IP, model, port) |
| `usteer`, `luci-app-usteer`, `wpad-mbedtls` | Roaming between the APs on the same SSID with 802.11k/v hints; full hostapd for 802.11v (replaces `wpad-basic-mbedtls`). usteer is built from a pinned upstream commit ([`build/usteer.sh`](build/usteer.sh), SDK of the same release) with its startup aggressiveness patched to 1: 802.11v suggestions only, never a forced disconnect. The shared policy ([`98-usteer-policy`](overlay/common/etc/uci-defaults/98-usteer-policy)) enables polite roaming only with that build, and falls back to zero-kick settings with any other usteer. |
| Oh My Posh, Oh My Zsh (core), `/root/.zshrc`, `ap-status` | Root logs in to zsh with an Oh My Posh prompt and a status card (firmware, health, LLDP uplink, radios, roaming peers). Oh My Posh is built from a pinned upstream tag for each device's architecture; Oh My Zsh is a pinned commit, core only. The prompt's host name comes from `/etc/ap-id`. |
| `luci-mod-rpc`, `mosquitto-client-nossl` | Home Assistant: the LuCI JSON-RPC endpoint used by HA's OpenWrt integration, and the MQTT client for `ha-mqtt` |
| `ha-mqtt` (+ `/etc/config/ha_mqtt`) | Publishes AP health to Home Assistant via MQTT discovery (firmware update, temperatures, channel load/noise, clients, tx retries/drops, roams, weak clients, uplink). Ships **disabled with no broker credentials**; set them on the device only (`/etc/config/ha_mqtt` is kept across updates). |

Also included: a fix for NTP on dumb APs ([`95-resolv-for-jails`](overlay/common/etc/hotplug.d/iface/95-resolv-for-jails)).
With dnsmasq off, the sandboxed `sysntpd` can't follow the `/tmp/resolv.conf` symlink and never sets
the clock.

## Using it

- **Overview page**: Status → Overview shows a *Firmware Updates* box with **Install now** when a
  newer build exists.
- **Settings**: System → Firmware Updates. Auto-install on/off, minimum release age (default 3 days),
  install hour (staggered per device: Netgear 04:00, Beryl 05:00), and whether a new release series
  (e.g. 25.12 → 26.x) may auto-install (default: no, click to install).
- **Shell**: `ghupdate check | prepare | apply | install | auto | status`.

**Automatic installs wait** while any hook in `/etc/ghupdate/inhibit.d/` objects. The hook's message is
shown as `auto.blocked`. The shared `50-peer-down` hook holds an install while the other AP is
unreachable (usteer sees no peer), so at least one AP always serves Wi-Fi. **Install now** in LuCI
bypasses the hooks.

**Install from Home Assistant.** `ha-mqtt` gives each AP's firmware update entity an Install button when the image's `ghupdate` supports `remote-install`. A press is checked like an automatic install (newer build for this device, inhibit hooks, signature, checksum, `sysupgrade -T`), skips the soak and install hour, and is limited to one per 15 minutes.

**Only changed devices update.** Each image carries a content key (`GHU_DEVKEY`: OpenWrt version,
resolved package versions, every added file). A release lists one key per device, and a device offers
a release only when the release is newer *and* its key differs from the installed one. A change for one
AP never reflashes the other; package (security) updates still reach both.

### Home Assistant

`ha-mqtt` creates the entities via MQTT discovery. The AP also serves its update status at
`http://<ap-address>/cgi-bin/ghupdate-status`; `auto.next` is the Unix time of the next automatic
install (0 = none planned), and `auto.blocked` says why one won't happen.

## Installing the first time

- **From another OpenWrt build:** System → Backup / Flash Firmware → upload the release's
  `*-<profile>-squashfs-sysupgrade.bin`, with *Keep settings* on.
- **Netgear from stock firmware, or to recover:** flash `*-squashfs-factory.img` to the bootloader with
  [nmrpflash](https://github.com/jclehner/nmrpflash).
- **Failsafe mode** is at `192.168.255.1`. Give your computer `192.168.255.2/24` to reach it.

## Releases

Tags are `openwrt-<version>-b<build>`, one release for all devices. The build number only increases. To
**pull a bad build**, delete the release or mark it as a pre-release: devices only look at GitHub's
*latest* release.

A run builds when OpenWrt publishes a new stable release or when anything under `overlay/`,
`packages/`, `devices/`, `build/` or the workflow changes. It publishes only if at least one device's
image actually changed. Publishing fails if a package shared by several devices resolved to different
versions (per-architecture feeds can lag; the next daily run retries). Run the workflow manually with
*force* to rebuild and publish anyway.

## Signing key

`SHA256SUMS` is signed with `usign`. The secret key lives only in the `USIGN_SECRET_KEY` Actions secret
(and an offline backup). The public key is [`overlay/common/etc/ghupdate/release.pub`](overlay/common/etc/ghupdate/release.pub)
and is baked into every image. To rotate it: publish one build that contains the new public key, signed
with the old key, then switch the secret.
