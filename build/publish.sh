#!/usr/bin/env bash
# Publish a verified, signed build as the repo's latest GitHub release.
# Usage: publish.sh <openwrt-version> <serial> <build-key> <out-dir>
set -euo pipefail

V=$1; SERIAL=$2; KEY=$3; OUT=$4
TAG=openwrt-$V-b$SERIAL
SERIES=${V%.*}

for f in SHA256SUMS SHA256SUMS.sig; do [ -s "$OUT/$f" ] || { echo "publish: missing $f" >&2; exit 1; }; done

notes=$(mktemp)
cat > "$notes" <<EOF
OpenWrt **$V** for the Netgear WAX214v2, build $SERIAL.

Official OpenWrt $V packages from the upstream Image Builder, plus:
- preinit/failsafe address moved from 192.168.1.1 to **192.168.255.1**, so the access point never claims the LAN gateway's address while it boots
- first boot makes LAN a DHCP client with no DHCP/RA server (fresh installs only; existing settings are kept)
- \`ghupdate\`: signed self-updates from this repo, shown in LuCI under Status > Overview and System > Firmware Updates

Upstream release notes: https://openwrt.org/releases/$SERIES/notes-$V

**Installing**
- Devices already on a build from this repo pick this one up by themselves: click *Install now*, or it installs automatically after the soak period.
- From any other OpenWrt build, upload the \`sysupgrade.bin\` under System > Backup / Flash Firmware (keep settings).
- From stock firmware or for recovery, flash \`factory.img\` with nmrpflash.

**SHA256**
\`\`\`
$(cat "$OUT/SHA256SUMS")
\`\`\`

<!-- build-key: $KEY -->
EOF

gh release create "$TAG" \
	--title "OpenWrt $V for WAX214v2 (build $SERIAL)" \
	--notes-file "$notes" \
	--latest \
	"$OUT"/*-squashfs-sysupgrade.bin "$OUT"/*-squashfs-factory.img "$OUT"/*.manifest \
	"$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig"

echo "published $TAG"
