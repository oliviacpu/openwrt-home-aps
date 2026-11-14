#!/usr/bin/env bash
# Build one AP image for one OpenWrt release:
#   official packages (OpenWrt Image Builder) + overlay/common + overlay/<profile> + the preinit
#   address patch + Oh My Posh / Oh My Zsh built from pinned sources.
# Writes the image(s), its package manifest, a per-device content key (devkey) and build logs to
# OUT. Signing and the release happen in publish.sh, across all devices.
# Usage: build.sh <profile> <openwrt-version> <serial> <out-dir>   (needs docker, curl, unsquashfs, git)
set -euo pipefail

PROFILE=${1:?profile}; V=${2:?openwrt version}; SERIAL=${3:?build serial}; OUT=${4:?output dir}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "build[$PROFILE]: $*" >&2; exit 1; }

# ---------- device definition ----------
CONF=$ROOT/devices/$PROFILE.conf
[ -r "$CONF" ] || die "no devices/$PROFILE.conf"
TARGET='' AP_ID='' GOARCH='' GOMIPS='' INSTALL_HOUR=4 FACTORY_IMAGE=0
# shellcheck disable=SC1090
. "$CONF"
[ -n "$TARGET" ] && [ -n "$AP_ID" ] && [ -n "$GOARCH" ] || die "devices/$PROFILE.conf needs TARGET, AP_ID and GOARCH"
IB=ghcr.io/openwrt/imagebuilder:${TARGET/\//-}-v$V
TAG=openwrt-$V-b$SERIAL
PI_IP=192.168.255.1
PI_BCAST=192.168.255.255

# Packages: one shared list + this device's extras (comments and blank lines ignored).
pkglist() { [ -r "$1" ] && sed -e 's/#.*//' "$1" | tr -s ' \t\n' ' '; return 0; }
PACKAGES=$(echo "$(pkglist "$ROOT/packages/common.txt") $(pkglist "$ROOT/packages/$PROFILE.txt")" | xargs)

# Shell extras built/fetched from pinned upstream sources (no OpenWrt packages for them).
POSH_VERSION=32.0.0                                       # Oh My Posh
POSH_COMMIT=d01ca021d6ceb899e252884f3a95db5969a4b8fd      # = tag v32.0.0
OMZ_COMMIT=2100c630ba4bd67bb48802c3e7da893a4fdaa1a0       # Oh My Zsh core
GO_IMAGE=golang:1.27                                      # oh-my-posh's go.mod needs Go >= 1.27

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

# ---------- 1) files: shared overlay, then the device's own on top ----------
cp -a "$ROOT/overlay/common/." "$FILES/"
[ -d "$ROOT/overlay/$PROFILE" ] && cp -a "$ROOT/overlay/$PROFILE/." "$FILES/"
echo "$AP_ID" > "$FILES/etc/ap-id"
sed -i.bak -e "s/^\(\toption hour \)'[0-9]*'/\1'$INSTALL_HOUR'/" "$FILES/etc/config/ghupdate" && rm -f "$FILES/etc/config/ghupdate.bak"
grep -q "option hour '$INSTALL_HOUR'" "$FILES/etc/config/ghupdate" || die "could not set the install hour"

# ---------- 2) preinit: this release's own 00_preinit.conf, only the address lines changed ----------
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
cp "$WORK/$off" "$OUT/official-sysupgrade.bin"     # kept for package-parity verification

# ---------- 3) Oh My Posh (static, this device's arch) and Oh My Zsh core ----------
# No MIPS release upstream, so every arch is built the same way from the pinned tag. Flags follow
# upstream's src/.goreleaser.yml. Built as the calling user so the output stays removable.
git clone -q --depth 1 --branch "v$POSH_VERSION" https://github.com/JanDeDobbeleer/oh-my-posh.git "$WORK/posh"
[ "$(git -C "$WORK/posh" rev-parse HEAD)" = "$POSH_COMMIT" ] || die "oh-my-posh v$POSH_VERSION is not commit $POSH_COMMIT"
posh_date=$(git -C "$WORK/posh" log -1 --format=%cI)
mkdir -p "$FILES/usr/bin" "$WORK/gotmp"
docker run --rm --user "$(id -u):$(id -g)" \
	-v "$WORK/posh:/src" -v "$FILES/usr/bin:/out" -v "$WORK/gotmp:/gotmp" -w /src/src \
	-e HOME=/gotmp -e GOCACHE=/gotmp/cache -e GOPATH=/gotmp/path -e GOFLAGS=-modcacherw \
	-e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$GOARCH" -e GOMIPS="$GOMIPS" -e GOEXPERIMENT=greenteagc,jsonv2 \
	"$GO_IMAGE" go build -a -trimpath -tags netgo,osusergo,static_build,timetzdata \
	-ldflags "-s -w -X github.com/jandedobbeleer/oh-my-posh/src/build.Version=$POSH_VERSION -X github.com/jandedobbeleer/oh-my-posh/src/build.Date=$posh_date" \
	-o /out/oh-my-posh . > "$OUT/oh-my-posh-build.log" 2>&1 || { tail -30 "$OUT/oh-my-posh-build.log" >&2; die "oh-my-posh build failed"; }

curl -fsSL "https://github.com/ohmyzsh/ohmyzsh/archive/$OMZ_COMMIT.tar.gz" | tar -xz -C "$WORK"
mkdir -p "$FILES/usr/share/oh-my-zsh"
for p in lib tools custom oh-my-zsh.sh LICENSE.txt; do cp -a "$WORK/ohmyzsh-$OMZ_COMMIT/$p" "$FILES/usr/share/oh-my-zsh/"; done

# ---------- 3b) usteer built from a pinned upstream commit (build/usteer.sh) ----------
# Falls back to the feed's usteer if the SDK build fails; the image's 98-usteer-policy then keeps the
# zero-kick settings, and publish's version gate refuses a release where the APs' usteer differ.
USTEER_APK='' USTEER_PIN=feed
if "$ROOT/build/usteer.sh" "$TARGET" "$V" "$OUT/usteer" > "$OUT/usteer.log" 2>&1; then
	USTEER_APK=$(ls "$OUT"/usteer/usteer-[0-9]*.apk | head -n 1)
	USTEER_PIN=$(cat "$ROOT/build/usteer.sh" "$ROOT"/build/usteer/patches/* | sha256sum | cut -c1-16)
	echo "build[$PROFILE]: $(tail -n 1 "$OUT/usteer.log")"
else
	echo "build[$PROFILE]: WARNING usteer source build failed, using the feed's usteer (zero-kick policy):" >&2
	tail -n 8 "$OUT/usteer.log" >&2
fi
IBMOUNTS=()
[ -n "$USTEER_APK" ] && IBMOUNTS=(-v "$USTEER_APK:/builder/packages/${USTEER_APK##*/}:ro")

# ---------- 4) devkey: what this device's image consists of ----------
# Resolved package versions (Image Builder's dry run) + every file we add + the source pins. ghupdate
# offers a release to a device only if its devkey differs from the installed one, so a change for
# one AP never reflashes the other, while feed (security) updates still do.
chmod -R a+rX "$FILES"
mkdir -p "$WORK/bin"; chmod 0777 "$WORK/bin"
ib() { docker run --rm --platform linux/amd64 ${IBMOUNTS[@]+"${IBMOUNTS[@]}"} -v "$FILES:/builder/files:ro" -v "$WORK/bin:/builder/bin" "$IB" "$@"; }
ib make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES" STRIP_ABI=1 > "$WORK/manifest.raw" 2> "$OUT/manifest.log" \
	|| { tail -30 "$OUT/manifest.log" >&2; die "image builder could not resolve the package set"; }
grep -E '^[A-Za-z0-9._+-]+ - [^ ]+$' "$WORK/manifest.raw" | sort > "$WORK/manifest"
[ -s "$WORK/manifest" ] || die "empty package manifest"
DEVKEY=$( {
	echo "openwrt $V $PROFILE posh $POSH_COMMIT omz $OMZ_COMMIT usteer $USTEER_PIN"
	cat "$WORK/manifest"
	(cd "$FILES" && find . -type f ! -path ./usr/bin/oh-my-posh ! -path ./etc/ghupdate/build | LC_ALL=C sort | xargs sha256sum)
} | sha256sum | cut -c1-16)

cat > "$FILES/etc/ghupdate/build" <<EOF
GHU_TAG='$TAG'
GHU_SERIAL='$SERIAL'
GHU_OPENWRT='$V'
GHU_PROFILE='$PROFILE'
GHU_DEVKEY='$DEVKEY'
EOF

# ---------- 5) image ----------
ib make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES=files EXTRA_IMAGE_NAME="b$SERIAL" \
	> "$OUT/imagebuilder.log" 2>&1 || { tail -40 "$OUT/imagebuilder.log" >&2; die "image builder failed"; }

src=$WORK/bin/targets/$TARGET
cp "$src"/*-"$PROFILE"-squashfs-sysupgrade.bin "$src"/*-"$PROFILE".manifest "$OUT/"
[ "$FACTORY_IMAGE" = 1 ] && cp "$src"/*-"$PROFILE"-squashfs-factory.img "$OUT/"
echo "$PROFILE $DEVKEY" > "$OUT/devkey"

# ---------- 6) verify the image before anything is signed ----------
"$ROOT/build/verify.sh" "$OUT" "$PROFILE" "$V" "$SERIAL" "$OUT/official-sysupgrade.bin"
rm -f "$OUT/official-sysupgrade.bin"

echo "build[$PROFILE]: $TAG (devkey $DEVKEY) ready in $OUT"
ls -l "$OUT"
