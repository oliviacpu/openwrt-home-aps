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
# Packages on top of the defaults. Anything meant to survive auto-updates must be listed here.
PACKAGES="luci luci-ssl"                                           # web UI, http + https
PACKAGES="$PACKAGES zsh zoneinfo-america"                          # shell and full timezone data
PACKAGES="$PACKAGES htop tcpdump-mini iperf3 curl nano tmux"       # everyday CLI tools
PACKAGES="$PACKAGES mtr-nojson ethtool drill lldpd"                # network diagnostics; LLDP to the switch
PACKAGES="$PACKAGES usteer luci-app-usteer"                        # band steering / roaming between APs
PACKAGES="$PACKAGES wpad-mbedtls -wpad-basic-mbedtls"             # full hostapd: 802.11v (bss_transition) for usteer
PACKAGES="$PACKAGES prometheus-node-exporter-lua prometheus-node-exporter-lua-wifi"
PACKAGES="$PACKAGES prometheus-node-exporter-lua-wifi_stations prometheus-node-exporter-lua-hostapd_stations"
# Shell extras built/fetched from pinned upstream sources (no OpenWrt packages for them).
POSH_VERSION=32.0.0                                       # Oh My Posh, cross-compiled for mipsle
POSH_COMMIT=d01ca021d6ceb899e252884f3a95db5969a4b8fd      # = tag v32.0.0
OMZ_COMMIT=2100c630ba4bd67bb48802c3e7da893a4fdaa1a0       # Oh My Zsh core
GO_IMAGE=golang:1.27                                      # oh-my-posh's go.mod needs Go >= 1.27
die() { echo "build: $*" >&2; exit 1; }

if [ -n "${GITHUB_ACTIONS:-}" ] && [ -z "${USIGN_SECRET_KEY:-}" ]; then
	die "USIGN_SECRET_KEY secret is not set; refusing to publish unsigned builds"
fi

WORK=$(mktemp -d)
cleanup() {
	local rc=$?
	# Image Builder writes bin/ as its own container user; remove that from inside a container.
	[ -d "$WORK/bin" ] && docker run --rm --platform linux/amd64 --user 0 -v "$WORK:/w" --entrypoint rm "$IB" -rf /w/bin >/dev/null 2>&1
	rm -rf "$WORK" 2>/dev/null || true
	exit "$rc"
}
trap cleanup EXIT
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

# 2b) Oh My Posh: no MIPS release upstream, so build the pinned tag as a static mipsle binary.
#     GOMIPS=softfloat because the MT7621's 1004Kc cores have no FPU. Flags follow upstream's
#     src/.goreleaser.yml. Built as the calling user so the output stays removable.
git clone -q --depth 1 --branch "v$POSH_VERSION" https://github.com/JanDeDobbeleer/oh-my-posh.git "$WORK/posh"
[ "$(git -C "$WORK/posh" rev-parse HEAD)" = "$POSH_COMMIT" ] || die "oh-my-posh v$POSH_VERSION is not commit $POSH_COMMIT"
posh_date=$(git -C "$WORK/posh" log -1 --format=%cI)
mkdir -p "$FILES/usr/bin" "$WORK/gotmp"
docker run --rm --user "$(id -u):$(id -g)" \
	-v "$WORK/posh:/src" -v "$FILES/usr/bin:/out" -v "$WORK/gotmp:/gotmp" -w /src/src \
	-e HOME=/gotmp -e GOCACHE=/gotmp/cache -e GOPATH=/gotmp/path -e GOFLAGS=-modcacherw \
	-e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=mipsle -e GOMIPS=softfloat -e GOEXPERIMENT=greenteagc,jsonv2 \
	"$GO_IMAGE" go build -a -trimpath -tags netgo,osusergo,static_build,timetzdata \
	-ldflags "-s -w -X github.com/jandedobbeleer/oh-my-posh/src/build.Version=$POSH_VERSION -X github.com/jandedobbeleer/oh-my-posh/src/build.Date=$posh_date" \
	-o /out/oh-my-posh . > "$OUT/oh-my-posh-build.log" 2>&1 || { tail -30 "$OUT/oh-my-posh-build.log" >&2; die "oh-my-posh build failed"; }

# 2c) Oh My Zsh core only (prompt comes from Oh My Posh; no themes or plugins).
curl -fsSL "https://github.com/ohmyzsh/ohmyzsh/archive/$OMZ_COMMIT.tar.gz" | tar -xz -C "$WORK"
mkdir -p "$FILES/usr/share/oh-my-zsh"
for p in lib tools custom oh-my-zsh.sh LICENSE.txt; do cp -a "$WORK/ohmyzsh-$OMZ_COMMIT/$p" "$FILES/usr/share/oh-my-zsh/"; done

# 3) Image Builder: default + device packages + LuCI (with HTTPS, as in official images) + zsh and
#    zoneinfo-america (used on this AP; installing them via apk would not survive upgrades), our files
#    on top. Attended Sysupgrade is deliberately not included (see verify.sh).
chmod -R a+rX "$FILES"
mkdir -p "$WORK/bin"; chmod 0777 "$WORK/bin"
docker run --rm --platform linux/amd64 \
	-v "$FILES:/builder/files:ro" -v "$WORK/bin:/builder/bin" \
	"$IB" make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES=files EXTRA_IMAGE_NAME="b$SERIAL" \
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
