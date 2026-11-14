#!/usr/bin/env bash
# Inspect a built sysupgrade image and fail unless every piece is in place.
# Usage: verify.sh <out-dir> <openwrt-version> <serial> [official-sysupgrade.bin]
set -euo pipefail

OUT=$1; V=$2; SERIAL=$3; OFFICIAL=${4:-}
PROFILE=netgear_wax214v2
TAG=openwrt-$V-b$SERIAL

img=$(ls "$OUT"/*-"$PROFILE"-squashfs-sysupgrade.bin)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
tar -xf "$img" -C "$W"
# only the directories we inspect (dev/ holds device nodes that need root to create)
unsquashfs -q -n -d "$W/r" "$W/sysupgrade-$PROFILE/root" bin sbin etc lib usr www >/dev/null
R=$W/r
fail=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }

check "board in sysupgrade CONTROL"         "grep -qx 'BOARD=$PROFILE' '$W/sysupgrade-$PROFILE/CONTROL'"
check "image is $V"                         "grep -q \"^DISTRIB_RELEASE='$V'\" '$R/etc/openwrt_release'"
check "preinit address is 192.168.255.1"    "grep -qx 'pi_ip=\"192.168.255.1\"' '$R/lib/preinit/00_preinit.conf'"
check "preinit broadcast is 192.168.255.255" "grep -qx 'pi_broadcast=\"192.168.255.255\"' '$R/lib/preinit/00_preinit.conf'"
check "no 192.168.1.1 left in preinit"      "! grep -rqE '192\\.168\\.1\\.1([^0-9]|\$)' '$R/lib/preinit/'"
check "LAN DHCP first-boot script"          "test -f '$R/etc/uci-defaults/99-lan-dhcp'"
check "updater first-boot script"           "test -f '$R/etc/uci-defaults/98-ghupdate'"
check "updater is executable"               "test -x '$R/usr/sbin/ghupdate'"
check "updater boot hook is executable"     "test -x '$R/etc/init.d/ghupdate'"
check "status CGI is executable"            "test -x '$R/www/cgi-bin/ghupdate-status'"
check "build identity is $TAG"              "grep -qx \"GHU_TAG='$TAG'\" '$R/etc/ghupdate/build'"
check "release public key present"          "grep -q '^RW' '$R/etc/ghupdate/release.pub'"
check "updater settings present"            "grep -q \"option repo\" '$R/etc/config/ghupdate'"
check "LuCI module + views present"         "test -f '$R/www/luci-static/resources/ghupdate.js' && test -f '$R/www/luci-static/resources/view/status/include/05_ghupdate.js' && test -f '$R/www/luci-static/resources/view/system/ghupdate.js'"
check "LuCI menu/ACL JSON valid"            "jq -e . '$R/usr/share/luci/menu.d/luci-app-ghupdate.json' '$R/usr/share/rpcd/acl.d/luci-app-ghupdate.json' >/dev/null"
for t in usign uclient-fetch jsonfilter sha256sum; do
	check "device has $t"                   "ls -d '$R/bin/$t' '$R/sbin/$t' '$R/usr/bin/$t' '$R/usr/sbin/$t' 2>/dev/null | grep -q ."
done
check "LuCI and wpad installed"             "grep -qx 'P:luci-base' '$R/lib/apk/db/installed' && grep -q '^P:wpad' '$R/lib/apk/db/installed'"

if [ -n "$OFFICIAL" ]; then
	mkdir "$W/o"; tar -xf "$OFFICIAL" -C "$W/o"
	unsquashfs -q -n -d "$W/o/r" "$W/o/sysupgrade-$PROFILE/root" lib/apk/db/installed >/dev/null
	missing=$(comm -23 <(grep '^P:' "$W/o/r/lib/apk/db/installed" | sort -u) <(grep '^P:' "$R/lib/apk/db/installed" | sort -u) | tr '\n' ' ')
	check "every official package is included${missing:+ (missing: $missing)}" "[ -z '$missing' ]"
fi

[ "$fail" = 0 ] || { echo "verify: FAILED" >&2; exit 1; }
echo "verify: all checks passed for $TAG"
