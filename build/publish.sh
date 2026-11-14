#!/usr/bin/env bash
# Publish one release for all devices built in this run.
# - fails if a package shared by several devices resolved to different versions (drift gate)
# - skips the release if no device's image changed since the latest release (devkeys equal)
# - checksums every image, signs SHA256SUMS with usign, verifies the signature, then publishes
# Usage: publish.sh <openwrt-version> <serial> <build-key> <artifacts-dir> [force=true|false]
#   artifacts-dir holds one directory per device (as written by build.sh)
set -euo pipefail

V=$1; SERIAL=$2; KEY=$3; ART=$4; FORCE=${5:-false}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${GITHUB_REPOSITORY:-oliviacpu/openwrt-home-aps}
TAG=openwrt-$V-b$SERIAL
SERIES=${V%.*}
die() { echo "publish: $*" >&2; exit 1; }
note() { echo "$*" >&2; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

if [ -n "${GITHUB_ACTIONS:-}" ] && [ -z "${USIGN_SECRET_KEY:-}" ]; then
	die "USIGN_SECRET_KEY secret is not set; refusing to publish unsigned builds"
fi

# One directory per device, each with the devkey file build.sh writes last (artifact names don't matter).
mapfile -t DEVDIRS < <(find "$ART" -mindepth 2 -maxdepth 2 -name devkey -exec dirname {} \; | sort)
[ "${#DEVDIRS[@]}" -gt 0 ] || die "no device artifacts in $ART"
prof_of() { cut -d' ' -f1 "$1/devkey"; }
REL=$(mktemp -d); trap 'rm -rf "$REL"' EXIT

# 1) Version-drift gate: a package present on several devices must have the same version on all.
#    The kernel and kmods are per-target builds (their versions carry the target's vermagic), so skipped.
for d in "${DEVDIRS[@]}"; do
	m=$(ls "$d"/*.manifest) || die "no manifest in $d"
	awk -v dev="$(prof_of "$d")" '$2 == "-" && $1 != "kernel" && $1 !~ /^kmod-/ { print $1, $3, dev }' "$m"
done | sort > "$REL/allpkgs"
drift=$(awk '{ v[$1] = v[$1] ? v[$1] : $2; if (v[$1] != $2) bad[$1] = 1; vers[$1] = vers[$1] " " $3 "=" $2 }
	END { for (p in bad) print p ":" vers[p] }' "$REL/allpkgs" | sort)
[ -z "$drift" ] || die "shared packages resolved to different versions across devices (feed lag?); retry later:
$drift"

# 2) Devkeys; skip if no device's image changed since the latest release.
: > "$REL/devkeys"
for d in "${DEVDIRS[@]}"; do cat "$d/devkey" >> "$REL/devkeys"; done
latest=$(gh api "repos/$REPO/releases/latest" --jq .body 2>/dev/null || true)
changed=0
while read -r prof key; do
	grep -q "devkey $prof $key" <<<"$latest" || changed=1
done < "$REL/devkeys"
if [ "$changed" = 0 ] && [ "$FORCE" != true ]; then
	note "No device image changed since the latest release (identical devkeys); not publishing $TAG."
	exit 0
fi

# 3) Collect, checksum, sign, verify.
for d in "${DEVDIRS[@]}"; do
	cp "$d"/*-squashfs-sysupgrade.bin "$d"/*.manifest "$REL/"
	cp "$d"/*-squashfs-factory.img "$REL/" 2>/dev/null || true
done
(cd "$REL" && sha256sum -- *-squashfs-sysupgrade.bin $(ls *-squashfs-factory.img 2>/dev/null) > SHA256SUMS)

if [ -n "${USIGN_SECRET_KEY:-}" ]; then
	# usign from the Image Builder of the first device (the same tool the APs verify with)
	TARGET=''; . "$ROOT/devices/$(prof_of "${DEVDIRS[0]}").conf"
	IB=ghcr.io/openwrt/imagebuilder:${TARGET/\//-}-v$V
	K=$(mktemp -d); chmod 700 "$K"
	printf '%s\n' "$USIGN_SECRET_KEY" > "$K/release.sec"
	cp "$ROOT/overlay/common/etc/ghupdate/release.pub" "$K/release.pub"
	usign() { docker run --rm --platform linux/amd64 --user 0 -v "$K:/k:ro" -v "$REL:/out" \
		--entrypoint /builder/staging_dir/host/bin/usign "$IB" "$@"; }
	usign -S -m /out/SHA256SUMS -s /k/release.sec -x /out/SHA256SUMS.sig
	rm -rf "$K/release.sec"
	usign -V -m /out/SHA256SUMS -p /k/release.pub -x /out/SHA256SUMS.sig \
		|| die "signature does not verify against overlay/common/etc/ghupdate/release.pub"
	rm -rf "$K"
fi
[ -s "$REL/SHA256SUMS.sig" ] || die "SHA256SUMS.sig missing"

# 4) Release notes (devkey and build-key lines are machine-read by ghupdate and decide.sh).
notes=$REL/notes.md
{
	echo "OpenWrt **$V**, build $SERIAL, for:"
	while read -r prof key; do echo "- \`$prof\` (devkey \`$key\`)"; done < "$REL/devkeys"
	cat <<EOF

Official OpenWrt $V packages from the upstream Image Builder, plus:
- preinit/failsafe address moved from 192.168.1.1 to **192.168.255.1**, so an AP never claims the LAN gateway's address while it boots
- first boot makes LAN a DHCP client with no DHCP/RA server (fresh installs only; existing settings are kept)
- \`ghupdate\`: signed self-updates from this repo, shown in LuCI (Status > Overview, System > Firmware Updates) and in Home Assistant
- shared roaming policy (802.11k/v hints, zero forced disconnects), shell, status card and Home Assistant publisher

A device only offers this release if its devkey differs from the installed build's.

Upstream release notes: https://openwrt.org/releases/$SERIES/notes-$V

**SHA256**
\`\`\`
$(cat "$REL/SHA256SUMS")
\`\`\`

EOF
	while read -r prof key; do echo "<!-- devkey $prof $key -->"; done < "$REL/devkeys"
	echo "<!-- build-key: $KEY -->"
} > "$notes"

gh release create "$TAG" --repo "$REPO" \
	--title "OpenWrt $V (build $SERIAL)" \
	--notes-file "$notes" \
	--latest \
	"$REL"/*-squashfs-sysupgrade.bin $(ls "$REL"/*-squashfs-factory.img 2>/dev/null) "$REL"/*.manifest \
	"$REL/SHA256SUMS" "$REL/SHA256SUMS.sig"

echo "published $TAG"
