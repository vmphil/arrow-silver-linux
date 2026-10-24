#!/usr/bin/env bash
# pinetab2-oct19-addons.sh - Oct 19 list for the Arrow Silver PineTab2 image:
#   1. Bundle BES2600 Wi-Fi firmware (Apache-2.0, pine64-org/bes2600-firmware
#      commit cd21914580fc) into /lib/firmware/bes2600/
#   2. Start in landscape: Xorg rotates DSI-1 "right" + touchscreen matrix
#      (+ xrandr autostart fallback, + fbcon=rotate:1 for the text console)
#   3. xfce4-battery-plugin package
#
# Two ways to use it:
#   a) On the booted tablet (test before rebuilding):
#        sudo ROOT=/ ./pinetab2-oct19-addons.sh      then reboot
#   b) In build-pinetab2-image.sh, right before step "6/7 Rebuilding initrd":
#        ROOT=$MNT ADDON_DIR=$PT/oct19 source "$PT/oct19/pinetab2-oct19-addons.sh"
#      (copy this folder to live-pinetab/oct19/ first)
set -euo pipefail
ROOT=${ROOT:?set ROOT=/ on the tablet, or ROOT=\$MNT inside the build script}
ADDON_DIR=${ADDON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
_say() { echo "    [oct19] $*"; }

# --- 1. BES2600 firmware -------------------------------------------------
FW_SRC=$ADDON_DIR/firmware
( cd "$FW_SRC/bes2600" && sha256sum -c --quiet ../SHA256SUMS ) \
	|| { echo "BES2600 firmware checksum mismatch in $FW_SRC" >&2; exit 1; }
install -d -m 755 "$ROOT/lib/firmware/bes2600"
install -m 644 "$FW_SRC"/bes2600/* "$ROOT/lib/firmware/bes2600/"
install -d -m 755 "$ROOT/usr/share/doc/firmware-bes2600"
install -m 644 "$FW_SRC/LICENSE" "$ROOT/usr/share/doc/firmware-bes2600/LICENSE"
_say "BES2600 firmware (5 files) -> /lib/firmware/bes2600/"

# --- 2. Landscape rotation (screen + touch) ------------------------------
install -d -m 755 "$ROOT/etc/X11/xorg.conf.d"
cat > "$ROOT/etc/X11/xorg.conf.d/40-arrow-silver-pinetab2-rotate.conf" << 'XEOF'
# PineTab2 panel is natively portrait; start in landscape (same as
# xrandr --output DSI-1 --rotate right). Touch matrix = 90 deg clockwise.
Section "Monitor"
	Identifier "DSI-1"
	Option "Rotate" "right"
EndSection

Section "InputClass"
	Identifier "Arrow Silver PineTab2 touchscreen rotate right"
	MatchIsTouchscreen "on"
	Option "TransformationMatrix" "0 1 0 -1 0 1 0 0 1"
EndSection
XEOF
# Fallback in case XFCE's display settings reset the rotation at login.
install -d -m 755 "$ROOT/etc/xdg/autostart"
cat > "$ROOT/etc/xdg/autostart/arrow-silver-pinetab2-rotate.desktop" << 'DEOF'
[Desktop Entry]
Type=Application
Name=PineTab2 landscape
Exec=sh -c 'xrandr --output DSI-1 --rotate right || true'
NoDisplay=true
OnlyShowIn=XFCE;
DEOF
EXT=$ROOT/boot/extlinux/extlinux.conf
if [[ -f $EXT ]] && ! grep -q 'fbcon=rotate' "$EXT"; then
	sed -i -E '/^[[:space:]]*(append|APPEND)[[:space:]]/ s/$/ fbcon=rotate:1/' "$EXT"
	_say "extlinux: added fbcon=rotate:1 (text console in landscape)"
fi
# 2026-10-19: deep suspend leaves the RK3566 GPU power domain off on resume
# (panfrost readl abort, frozen screen). s2idle resumes cleanly on PineTab2.
if [[ -f $EXT ]] && ! grep -q 'mem_sleep_default' "$EXT"; then
	sed -i -E '/^[[:space:]]*(append|APPEND)[[:space:]]/ s/$/ mem_sleep_default=s2idle/' "$EXT"
	_say "extlinux: added mem_sleep_default=s2idle (deep sleep crashes the GPU on resume)"
fi
_say "Xorg rotate right + touchscreen matrix + xrandr autostart fallback"

# --- 3. xfce4-battery-plugin ---------------------------------------------
if [[ $ROOT == / ]]; then
	apt-get install -y --no-install-recommends xfce4-battery-plugin
elif declare -F chroot_run >/dev/null; then
	chroot_run apt-get install -y --no-install-recommends xfce4-battery-plugin
else
	chroot "$ROOT" apt-get install -y --no-install-recommends xfce4-battery-plugin
fi
_say "xfce4-battery-plugin installed (add it to the panel once: right-click panel > Panel > Add New Items)"
