#!/usr/bin/env bash
# Inspect one built image and fail unless every piece is in place.
# Usage: verify.sh <out-dir> <profile> <openwrt-version> <serial> [official-sysupgrade.bin]
set -euo pipefail

OUT=$1; PROFILE=$2; V=$3; SERIAL=$4; OFFICIAL=${5:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=openwrt-$V-b$SERIAL
AP_ID='' FACTORY_IMAGE=0 INSTALL_HOUR=4 IMAGE_MAX_BYTES=0
# shellcheck disable=SC1090
. "$ROOT/devices/$PROFILE.conf"

img=$(ls "$OUT"/*-"$PROFILE"-squashfs-sysupgrade.bin)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
tar -xf "$img" -C "$W"
# only the directories we inspect (dev/ holds device nodes that need root to create)
unsquashfs -q -n -d "$W/r" "$W/sysupgrade-$PROFILE/root" bin sbin etc lib usr www root >/dev/null
R=$W/r
DB=$R/lib/apk/db/installed
fail=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
installed() { grep -qx "P:$1" "$DB"; }

# --- identity, preinit, firmware plumbing
check "board in sysupgrade CONTROL"         "grep -qx 'BOARD=$PROFILE' '$W/sysupgrade-$PROFILE/CONTROL'"
check "image is $V"                         "grep -q \"^DISTRIB_RELEASE='$V'\" '$R/etc/openwrt_release'"
check "ap-id is $AP_ID"                     "[ \"\$(cat '$R/etc/ap-id')\" = '$AP_ID' ]"
check "build identity is $TAG"              "grep -qx \"GHU_TAG='$TAG'\" '$R/etc/ghupdate/build'"
check "build identity has profile + devkey" "grep -qx \"GHU_PROFILE='$PROFILE'\" '$R/etc/ghupdate/build' && grep -qE \"^GHU_DEVKEY='[0-9a-f]{16}'\\\$\" '$R/etc/ghupdate/build'"
check "preinit address is 192.168.255.1"    "grep -qx 'pi_ip=\"192.168.255.1\"' '$R/lib/preinit/00_preinit.conf'"
check "preinit broadcast is 192.168.255.255" "grep -qx 'pi_broadcast=\"192.168.255.255\"' '$R/lib/preinit/00_preinit.conf'"
check "no 192.168.1.1 left in preinit"      "! grep -rqE '192\\.168\\.1\\.1([^0-9]|\$)' '$R/lib/preinit/'"
check "updater, boot hook, status CGI executable" "test -x '$R/usr/sbin/ghupdate' && test -x '$R/etc/init.d/ghupdate' && test -x '$R/www/cgi-bin/ghupdate-status'"
check "updater settings point at openwrt-home-aps" "grep -q \"option repo 'oliviacpu/openwrt-home-aps'\" '$R/etc/config/ghupdate'"
check "install hour is $INSTALL_HOUR"       "grep -q \"option hour '$INSTALL_HOUR'\" '$R/etc/config/ghupdate'"
check "repo-rename migration present"       "test -x '$R/etc/uci-defaults/93-ghupdate-repo'"
check "peer-down inhibit hook executable"   "test -x '$R/etc/ghupdate/inhibit.d/50-peer-down'"
check "release public key present"          "grep -q '^RW' '$R/etc/ghupdate/release.pub'"
check "LuCI module + views present"         "test -f '$R/www/luci-static/resources/ghupdate.js' && test -f '$R/www/luci-static/resources/view/status/include/05_ghupdate.js' && test -f '$R/www/luci-static/resources/view/system/ghupdate.js'"
check "ghupdate takes HA installs (ha-mqtt looks for the remote-install label)" "grep -q '^[[:space:]]*remote-install)' '$R/usr/sbin/ghupdate'"
check "no homeassistant rpcd ACL (HA uses MQTT only)" "test ! -e '$R/usr/share/rpcd/acl.d/homeassistant.json'"
check "homeassistant login retired at flash"   "test -x '$R/etc/uci-defaults/95-ha-ubus-retire'"
check "LuCI menu/ACL JSON valid"            "jq -e . '$R/usr/share/luci/menu.d/luci-app-ghupdate.json' '$R/usr/share/rpcd/acl.d/luci-app-ghupdate.json' >/dev/null"
for t in usign uclient-fetch jsonfilter sha256sum; do
	check "device has $t"                   "find '$R/bin' '$R/sbin' '$R/usr/bin' '$R/usr/sbin' -maxdepth 1 -name '$t' | grep -q ."
done

# --- first-boot defaults
check "DHCP-client LAN default (fresh installs only)" "test -f '$R/etc/uci-defaults/99-lan-dhcp' && grep -q '192.168.1.1' '$R/etc/uci-defaults/99-lan-dhcp'"
check "LAN default leaves a Home/Away Beryl alone" "grep -q '/etc/beryl-mode/current' '$R/etc/uci-defaults/99-lan-dhcp'"
check "dumb-AP NTP/DNS fix is executable"   "test -x '$R/etc/hotplug.d/iface/95-resolv-for-jails'"
check "usteer policy: aggressiveness 1, no min_snr/load kicks, roaming only on our build" "f='$R/etc/uci-defaults/98-usteer-policy'; grep -q 'aggressiveness=1' \"\$f\" && grep -q 'min_snr=0' \"\$f\" && grep -q 'load_kick_enabled=0' \"\$f\" && grep -q -- '\*-r100) POLICY=2' \"\$f\" && grep -q 'roam_scan_snr=0' \"\$f\""
# usteer must be a reviewed build: ours from source (-r100, passive default patched in) or the feed's
# 1d6524c6 (kept zero-kick by the policy). Anything else could kick at its default aggressiveness.
uv=$(awk '/^P:usteer$/ { f = 1 } f && /^V:/ { print substr($0, 3); exit }' "$DB")
case $uv in
	*~7532e125-r100) check "usteer is our source build ($uv)" true ;;
	2025.10.04~1d6524c6-*) check "usteer is the feed build ($uv): zero-kick policy, no roaming" true ;;
	*) check "usteer $uv is a reviewed build (7532e125-r100 or feed 1d6524c6)" false ;;
esac

# --- packages: everything requested is installed; things we keep out are out
for p in $(sed -e 's/#.*//' "$ROOT/packages/common.txt" "$ROOT/packages/$PROFILE.txt" 2>/dev/null | tr -s ' \t' '\n\n' | grep -v '^-' | grep . || true); do
	check "package $p installed"            "installed '$p'"
done
check "full wpad (802.11k/v), no wpad-basic" "installed wpad-mbedtls && ! installed wpad-basic-mbedtls"
check "Attended Sysupgrade / owut absent"   "! grep -qE '^P:(attendedsysupgrade-common|luci-app-attendedsysupgrade|owut)$' '$DB'"
check "luci-mod-rpc absent (its sys.exec ignores the rpcd ACL; HA uses ubus)" "! installed luci-mod-rpc"
check "Prometheus exporter absent"          "! grep -q '^P:prometheus-node-exporter' '$DB'"

# --- shell, Home Assistant
check "oh-my-posh is a static binary for this arch" "test -x '$R/usr/bin/oh-my-posh' && file -b '$R/usr/bin/oh-my-posh' | grep -q 'statically linked'"
check "oh-my-zsh core present"              "test -f '$R/usr/share/oh-my-zsh/oh-my-zsh.sh' && test -d '$R/usr/share/oh-my-zsh/lib'"
check "root zsh: .zshrc reads /etc/ap-id, login default" "grep -q '/etc/ap-id' '$R/root/.zshrc' && test -x '$R/etc/uci-defaults/96-zsh-root'"
check "ap-status login card, quiet login"   "test -x '$R/usr/bin/ap-status' && ! test -s '$R/etc/banner' && test -f '$R/etc/profile.d/apk-cheatsheet.hush' && test -s '$R/etc/banner.failsafe'"
check "ha-mqtt publisher + service present" "test -x '$R/usr/sbin/ha-mqtt' && test -x '$R/etc/init.d/ha-mqtt' && test -x '$R/etc/uci-defaults/94-ha-mqtt'"
check "ha_mqtt ships disabled, no credentials" "grep -qxE \"[[:space:]]*option enabled '0'\" '$R/etc/config/ha_mqtt' && grep -qxE \"[[:space:]]*option host ''\" '$R/etc/config/ha_mqtt' && grep -qxE \"[[:space:]]*option username ''\" '$R/etc/config/ha_mqtt' && grep -qxE \"[[:space:]]*option password ''\" '$R/etc/config/ha_mqtt'"
check "ha_mqtt node_id is $AP_ID"           "grep -qxE \"[[:space:]]*option node_id '$AP_ID'\" '$R/etc/config/ha_mqtt'"
check "SNMP retired: no snmpd, no SNMP helpers" "! grep -qE '^P:snmpd' '$DB' && ! test -e '$R/usr/sbin/ha-wifi' && ! test -e '$R/usr/sbin/ha-weaknames' && ! test -e '$R/usr/sbin/cpu-busy'"
check "SNMP leftovers cleaned on upgrade"   "test -x '$R/etc/uci-defaults/95-snmp-retire'"
check "kept /root/ swapped for the pushed files (image .zshrc wins)" "test -x '$R/etc/uci-defaults/92-root-keep'"
if [ "$FACTORY_IMAGE" = 1 ]; then
	check "factory image built"             "ls '$OUT'/*-'$PROFILE'-squashfs-factory.img >/dev/null 2>&1"
fi

# --- device-specific checks (devices/<profile>.verify)
# shellcheck disable=SC1090
[ -r "$ROOT/devices/$PROFILE.verify" ] && . "$ROOT/devices/$PROFILE.verify"

# --- no secrets in what we add (repo overlays): keys, passwords, PSKs, usign secret keys, hashes
secrets=$(grep -rInE "option (key|password|community|psk|auth_secret|secret) '[^']+'|PRIVATE KEY|^RWRTY|[$](1|5|6|p)[$][^:]+" \
	"$ROOT/overlay/common" "$ROOT/overlay/$PROFILE" 2>/dev/null | cut -d: -f1-2 | tr '\n' ' ' || true)
check "no secrets in overlay/common or overlay/$PROFILE${secrets:+ (found: $secrets)}" "[ -z \"\$secrets\" ]"

# --- every official package is included, except the ones left out on purpose
if [ -n "$OFFICIAL" ]; then
	mkdir "$W/o"; tar -xf "$OFFICIAL" -C "$W/o"
	unsquashfs -q -n -d "$W/o/r" "$W/o/sysupgrade-$PROFILE/root" lib/apk/db/installed >/dev/null
	excluded='^P:(attendedsysupgrade-common|luci-app-attendedsysupgrade|owut|rpcd-mod-rpcsys|ucode-mod-uclient|wpad-basic-mbedtls)$'
	missing=$(comm -23 <(grep '^P:' "$W/o/r/lib/apk/db/installed" | grep -vE "$excluded" | sort -u) \
	                   <(grep '^P:' "$DB" | sort -u) | tr '\n' ' ')
	check "every official package is included, except Attended Sysupgrade${missing:+ (missing: $missing)}" "[ -z '$missing' ]"
fi

if [ "$IMAGE_MAX_BYTES" -gt 0 ]; then
	check "image fits the firmware partition ($IMAGE_MAX_BYTES bytes)" "[ \$(stat -c %s '$img' 2>/dev/null || stat -f %z '$img') -lt $IMAGE_MAX_BYTES ]"
fi

[ "$fail" = 0 ] || { echo "verify[$PROFILE]: FAILED" >&2; exit 1; }
echo "verify[$PROFILE]: all checks passed for $TAG"
