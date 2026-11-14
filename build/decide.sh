#!/usr/bin/env bash
# Decide whether a build is needed. Prints KEY=VALUE lines for $GITHUB_OUTPUT:
#   version  current stable OpenWrt release
#   serial   next build number (monotonic across all releases of this repo)
#   key      OpenWrt version + hash of everything that shapes the images
#   devices  JSON array of profiles to build (one per devices/*.conf)
#   build    true|false
# Usage: decide.sh [force=true|false]
set -euo pipefail

FORCE=${1:-false}
REPO=${GITHUB_REPOSITORY:-oliviacpu/openwrt-home-aps}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
note() { echo "$*" >&2; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

V=$(curl -fsSL https://downloads.openwrt.org/.versions.json | jq -r .stable_version)
[[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { note "Unexpected stable_version '$V'"; exit 1; }

# Every device must still exist upstream and have its Image Builder published.
DEVICES=()
IB_MISSING=()
for conf in "$ROOT"/devices/*.conf; do
	PROFILE='' TARGET=''
	# shellcheck disable=SC1090
	. "$conf"
	curl -fsSL "https://downloads.openwrt.org/releases/$V/targets/$TARGET/profiles.json" \
		| jq -e --arg p "$PROFILE" '.profiles[$p].images[] | select(.type == "sysupgrade")' >/dev/null \
		|| { note "OpenWrt $V has no $PROFILE sysupgrade image"; exit 1; }
	docker manifest inspect "ghcr.io/openwrt/imagebuilder:${TARGET/\//-}-v$V" >/dev/null 2>&1 || IB_MISSING+=("$TARGET")
	DEVICES+=("$PROFILE")
done
[ "${#DEVICES[@]}" -gt 0 ] || { note "no devices/*.conf"; exit 1; }

# Everything that shapes the images: overlays, package lists, device definitions, build scripts, workflow.
SHAPE=$(cd "$ROOT" && git rev-parse HEAD:overlay HEAD:packages HEAD:devices HEAD:build HEAD:.github/workflows/build.yml | sha256sum | cut -c1-12)
KEY="$V-$SHAPE"

releases=$(gh api "repos/$REPO/releases?per_page=100" 2>/dev/null) || releases='[]'
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$releases" || releases='[]'
SERIAL=$(jq -r '[.[].tag_name | capture("-b(?<n>[0-9]+)$").n | tonumber] | (max // 0) + 1' <<<"$releases")
EXISTING=$(jq -r --arg k "$KEY" '[.[] | select((.body // "") | contains("build-key: " + $k)) | .tag_name][0] // ""' <<<"$releases")

BUILD=true
if [ -n "$EXISTING" ] && [ "$FORCE" != true ]; then
	BUILD=false
	note "OpenWrt $V with these inputs is already released as $EXISTING; nothing to do."
elif [ "${#IB_MISSING[@]}" -gt 0 ]; then
	BUILD=false
	note "Image Builder for OpenWrt $V is not published yet for: ${IB_MISSING[*]}; will retry on the next run."
else
	note "Building OpenWrt $V as build $SERIAL for ${DEVICES[*]} (key $KEY)${EXISTING:+, forced}."
fi

echo "version=$V"
echo "serial=$SERIAL"
echo "key=$KEY"
echo "devices=$(printf '%s\n' "${DEVICES[@]}" | jq -Rnc '[inputs]')"
echo "build=$BUILD"
