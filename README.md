# OpenWrt for Netgear WAX214v2, with signed self-updates

Automated builds of official [OpenWrt](https://openwrt.org) for the **Netgear WAX214v2** access point
(`ramips/mt7621`, profile `netgear_wax214v2`), with three small additions. A GitHub Actions workflow
checks for new OpenWrt releases every day, then builds, verifies, signs and publishes them. Devices
running these builds see the update in LuCI and install it with one click, or by themselves after a
soak period.

No OpenWrt fork: images come from the upstream **Image Builder** with the official packages. Only the
files under [`overlay/`](overlay) are added.

## What's different from stock OpenWrt

1. **Preinit/failsafe address moved off the LAN.** Stock OpenWrt puts `192.168.1.1` on the LAN port
   for a few seconds early in every boot, while it waits for failsafe. On a network whose gateway *is*
   `192.168.1.1`, the access point briefly impersonates the router at every reboot. Clients that look
   up the gateway in that window lose connectivity until their ARP cache refreshes. These builds use
   **`192.168.255.1`** instead: [`build/build.sh`](build/build.sh) takes that release's own
   `/lib/preinit/00_preinit.conf` and changes just the two address lines.
2. **DHCP-client LAN by default.** On a fresh install, LAN becomes a DHCP client and the DHCP/RA servers
   are disabled, so the AP joins an existing network instead of acting as a router
   ([`99-lan-dhcp`](overlay/etc/uci-defaults/99-lan-dhcp)). Existing settings are never touched.
3. **`ghupdate`, signed updates from this repo.** [`/usr/sbin/ghupdate`](overlay/usr/sbin/ghupdate)
   checks this repo's latest release every hour. It verifies the `usign` signature on `SHA256SUMS`, the
   image checksum and `sysupgrade -T`, then upgrades with settings kept. OpenWrt's Attended Sysupgrade is
   deliberately left out, because it would offer official images without fix 1.

## Using it

- **Overview page**: Status → Overview shows a *Firmware Updates* box with **Install now** when a
  newer build exists.
- **Settings**: System → Firmware Updates. Auto-install on/off, minimum release age (default 3 days),
  install hour (default 04:00), and whether a new release series (e.g. 25.12 → 26.x) may auto-install
  (default: no, click to install).
- **Shell**: `ghupdate check | prepare | apply | install | auto | status`.

### Home Assistant

The AP serves its update status at `http://<ap-address>/cgi-bin/ghupdate-status`:

```yaml
rest:
  - resource: http://<ap-address>/cgi-bin/ghupdate-status
    scan_interval: 900
    sensor:
      - name: Access point firmware
        value_template: "{{ value_json.installed.openwrt }} (build {{ value_json.installed.serial }})"
        json_attributes: [state, message, latest, auto, last_check]
    binary_sensor:
      - name: Access point firmware update available
        device_class: update
        value_template: "{{ value_json.update_available }}"
```

`auto.next` is the Unix time of the next automatic install (0 = none planned), and `auto.blocked` says
why one won't happen.

## Installing the first time

- **From another OpenWrt build:** System → Backup / Flash Firmware → upload the release's
  `*-squashfs-sysupgrade.bin`, with *Keep settings* on.
- **From Netgear stock firmware, or to recover:** flash `*-squashfs-factory.img` to the bootloader with
  [nmrpflash](https://github.com/jclehner/nmrpflash).
- **Failsafe mode** is at `192.168.255.1`. Give your computer `192.168.255.2/24` to reach it.

## Releases

Tags are `openwrt-<version>-b<build>`. The build number only increases, and devices install any build
newer than their own. To **pull a bad build**, delete the release or mark it as a pre-release: devices
only look at GitHub's *latest* release.

Each run rebuilds when OpenWrt publishes a new stable release, or when `overlay/`, `build/` or the
workflow changes. Run the workflow manually with *force* to rebuild anyway.

## Signing key

`SHA256SUMS` is signed with `usign`. The secret key lives only in the `USIGN_SECRET_KEY` Actions secret
(and an offline backup). The public key is [`overlay/etc/ghupdate/release.pub`](overlay/etc/ghupdate/release.pub)
and is baked into every image. To rotate it: publish one build that contains the new public key, signed
with the old key, then switch the secret.
