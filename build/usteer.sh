#!/usr/bin/env bash
# Build usteer from a pinned upstream commit with this release's OpenWrt SDK, for one target, so every
# AP runs the same newer usteer (aggressiveness levels: 1 = BSS-TM hints only, never a kick).
# The feed's usteer (2025.10.04~1d6524c6) hard-kicks 10 s after any roam trigger.
# Writes usteer-*.apk and sdk logs to OUT. Exits non-zero on any failure; build.sh then keeps the
# feed usteer, and the image's 98-usteer-policy keeps the zero-kick settings for it.
# Usage: usteer.sh <target> <openwrt-version> <out-dir>
set -euo pipefail

TARGET=${1:?target}; V=${2:?openwrt version}; OUT=${3:?out dir}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=ghcr.io/openwrt/sdk:${TARGET/\//-}-v$V

USTEER_COMMIT=7532e1252fb937fe34b6da05e86fd34babd91ef5   # 2026-05-19 "ubus: added reassoc_delay and reason code"
USTEER_DATE=2026-05-19

mkdir -p "$OUT"; chmod 0777 "$OUT"
docker run --rm --platform linux/amd64 \
	-v "$ROOT/build/usteer:/pkg:ro" -v "$(cd "$OUT" && pwd):/out" \
	-e USTEER_COMMIT="$USTEER_COMMIT" -e USTEER_DATE="$USTEER_DATE" \
	--entrypoint /bin/bash "$SDK" -ec '
	cd /builder
	# The two feeds usteer needs, at the commits this SDK release pins, fetched shallow from the
	# GitHub mirrors (a full clone of openwrt.git takes far longer).
	fetch() { # name url commit dir
		git init -q "$4"; git -C "$4" fetch -q --depth 1 "$2" "$3"; git -C "$4" checkout -q FETCH_HEAD
	}
	base=$(sed -n "s/^src-git --root=package base .*\^\([0-9a-f]*\)$/\1/p" feeds.conf.default)
	pkgs=$(sed -n "s/^src-git packages .*\^\([0-9a-f]*\)$/\1/p" feeds.conf.default)
	[ -n "$base" ] && [ -n "$pkgs" ] || { echo "cannot read feed pins" >&2; exit 1; }
	fetch base https://github.com/openwrt/openwrt.git "$base" /tmp/base
	fetch packages https://github.com/openwrt/packages.git "$pkgs" /tmp/packages
	printf "src-link base /tmp/base/package\nsrc-link packages /tmp/packages\n" > feeds.conf
	./scripts/feeds update -a > /out/sdk-feeds.log 2>&1
	./scripts/feeds install usteer >> /out/sdk-feeds.log 2>&1

	mk=feeds/packages/net/usteer/Makefile
	[ -f "$mk" ] || { echo "no $mk" >&2; exit 1; }
	sed -i -e "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=$USTEER_DATE/" \
	       -e "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$USTEER_COMMIT/" \
	       -e "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=skip/" \
	       -e "s/^PKG_RELEASE:=.*/PKG_RELEASE:=100/" "$mk"   # -r100 marks this build (98-usteer-policy keys on it)
	mkdir -p "${mk%/Makefile}/patches"; cp /pkg/patches/*.patch "${mk%/Makefile}/patches/"

	make defconfig > /out/sdk-build.log 2>&1
	# Serial: defconfig also builds the lua bindings of the dependencies, and the recursive make of
	# lua breaks under a parallel jobserver ("write jobserver: Bad file descriptor").
	# (No apostrophes anywhere in this single-quoted script.)
	make package/usteer/compile -j1 V=s >> /out/sdk-build.log 2>&1
	find bin/packages -name "usteer-[0-9]*.apk" -exec cp {} /out/ \;
'
apk=$(ls "$OUT"/usteer-[0-9]*.apk 2>/dev/null | head -n 1)
[ -n "$apk" ] || { tail -30 "$OUT/sdk-build.log" >&2 2>/dev/null; echo "usteer: no package built" >&2; exit 1; }
case ${apk##*/} in *"~${USTEER_COMMIT:0:8}-r100"*) ;; *) echo "usteer: built ${apk##*/}, not ${USTEER_COMMIT:0:8}-r100" >&2; exit 1 ;; esac
echo "usteer: built ${apk##*/}"
