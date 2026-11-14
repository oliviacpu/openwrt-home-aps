#!/usr/bin/env bash
# Build the WAX214v2 image for one OpenWrt release:
#   official packages (OpenWrt Image Builder) + overlay/ + the preinit address patch.
# Writes the images, SHA256SUMS and (with USIGN_SECRET_KEY set) SHA256SUMS.sig into OUT.
# Usage: build.sh <openwrt-version> <serial> <out-dir>     (needs docker, curl, unsquashfs)
set -euo pipefail

V=${1:?openwrt version}; SERIAL=${2:?build serial}; OUT=${3:?output dir}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET=ramips/mt7621
PROFILE=netgear_wax214v2
IB=ghcr.io/openwrt/imagebuilder:${TARGET/\//-}-v$V
TAG=openwrt-$V-b$SERIAL
PI_IP=192.168.255.1
PI_BCAST=192.168.255.255
die() { echo "build: $*" >&2; exit 1; }

if [ -n "${GITHUB_ACTIONS:-}" ] && [ -z "${USIGN_SECRET_KEY:-}" ]; then
	die "USIGN_SECRET_KEY secret is not set; refusing to publish unsigned builds"
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FILES=$WORK/files
mkdir -p "$FILES" "$OUT"
cp -a "$ROOT/overlay/." "$FILES/"

# 1) Preinit: take THIS release's own 00_preinit.conf and change only the address lines.
base=https://downloads.openwrt.org/releases/$V/targets/$TARGET
off=openwrt-$V-${TARGET/\//-}-$PROFILE-squashfs-sysupgrade.bin
curl -fsSL -o "$WORK/$off" "$base/$off"
curl -fsSL -o "$WORK/sha256sums" "$base/sha256sums"
want=$(awk -v f="$off" '{ n = $2; sub(/^\*/, "", n) } n == f { print $1 }' "$WORK/sha256sums")
[ -n "$want" ] && [ "$(sha256sum "$WORK/$off" | cut -d' ' -f1)" = "$want" ] || die "official image checksum mismatch"
mkdir "$WORK/official"
tar -xf "$WORK/$off" -C "$WORK/official"
unsquashfs -q -n -d "$WORK/official/root" "$WORK/official/sysupgrade-$PROFILE/root" lib/preinit/00_preinit.conf >/dev/null
orig=$WORK/official/root/lib/preinit/00_preinit.conf
grep -qx 'pi_ip="192.168.1.1"' "$orig" || die "upstream pi_ip changed; review the patch"
grep -qx 'pi_broadcast="192.168.1.255"' "$orig" || die "upstream pi_broadcast changed; review the patch"
mkdir -p "$FILES/lib/preinit"
sed -e "s/^pi_ip=\"192\.168\.1\.1\"\$/pi_ip=\"$PI_IP\"/" \
    -e "s/^pi_broadcast=\"192\.168\.1\.255\"\$/pi_broadcast=\"$PI_BCAST\"/" \
    "$orig" > "$FILES/lib/preinit/00_preinit.conf"
[ "$(diff "$orig" "$FILES/lib/preinit/00_preinit.conf" | grep -c '^>')" = 2 ] || die "preinit patch did not change exactly 2 lines"
cp "$WORK/$off" "$WORK/official.bin"     # kept for package-parity verification

# 2) Build identity, read by /usr/sbin/ghupdate on the device.
cat > "$FILES/etc/ghupdate/build" <<EOF
GHU_TAG='$TAG'
GHU_SERIAL='$SERIAL'
GHU_OPENWRT='$V'
GHU_PROFILE='$PROFILE'
EOF

# 3) Image Builder: default + device packages + LuCI (with HTTPS, as in official images), our files
#    on top. Attended Sysupgrade is deliberately not included (see verify.sh).
chmod -R a+rX "$FILES"
mkdir -p "$WORK/bin"; chmod 0777 "$WORK/bin"
docker run --rm --platform linux/amd64 \
	-v "$FILES:/builder/files:ro" -v "$WORK/bin:/builder/bin" \
	"$IB" make image PROFILE="$PROFILE" PACKAGES="luci luci-ssl" FILES=files EXTRA_IMAGE_NAME="b$SERIAL" \
	> "$OUT/imagebuilder.log" 2>&1 || { tail -40 "$OUT/imagebuilder.log" >&2; die "image builder failed"; }

src=$WORK/bin/targets/$TARGET
cp "$src"/*-"$PROFILE"-squashfs-sysupgrade.bin "$src"/*-"$PROFILE"-squashfs-factory.img "$src"/*-"$PROFILE".manifest "$OUT/"
(cd "$OUT" && sha256sum -- *-squashfs-sysupgrade.bin *-squashfs-factory.img > SHA256SUMS)

# 4) Verify the image contents before anything is signed.
"$ROOT/build/verify.sh" "$OUT" "$V" "$SERIAL" "$WORK/official.bin"

# 5) Sign SHA256SUMS with usign (the same tool the device verifies with), then verify it.
if [ -n "${USIGN_SECRET_KEY:-}" ]; then
	mkdir -m 0700 "$WORK/key"
	printf '%s\n' "$USIGN_SECRET_KEY" > "$WORK/key/release.sec"
	cp "$ROOT/overlay/etc/ghupdate/release.pub" "$WORK/key/release.pub"
	usign() { docker run --rm --platform linux/amd64 --user 0 -v "$WORK/key:/k:ro" -v "$(cd "$OUT" && pwd):/out" \
		--entrypoint /builder/staging_dir/host/bin/usign "$IB" "$@"; }
	usign -S -m /out/SHA256SUMS -s /k/release.sec -x /out/SHA256SUMS.sig
	rm -f "$WORK/key/release.sec"
	usign -V -m /out/SHA256SUMS -p /k/release.pub -x /out/SHA256SUMS.sig \
		|| die "signature does not verify against overlay/etc/ghupdate/release.pub"
fi

echo "build: $TAG ready in $OUT"
ls -l "$OUT"
