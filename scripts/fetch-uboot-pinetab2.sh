#!/usr/bin/env bash
# fetch-uboot-pinetab2.sh — download + verify the pinned PineTab2 U-Boot binary.
# Safe to run without root. Does not flash anything.
set -euo pipefail

AS=${AS:-/home/philip/Documents/Arrow-Silver}
DIR=$AS/live-pinetab/u-boot/pinetab2
ZIP_URL=https://github.com/inindev/uboot-rockchip/releases/download/v2026.04/rk3566-pinetab2.zip
ZIP_SHA=adfed313c652f296544952a2361c4992688809acd09b09be23cddec659792a3c
BIN_SHA=91b5fb6eb7107ee574c996d227ff9072dbc7d3be3df759e1f48d90ba3b437b9a
ZIP_NAME=rk3566-pinetab2-v2026.04.zip

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "    $*"; }

mkdir -p "$DIR"
cd "$DIR"

need_fetch=0
if [[ ! -f u-boot-rockchip.bin ]]; then
	need_fetch=1
elif ! echo "$BIN_SHA  u-boot-rockchip.bin" | sha256sum -c --status; then
	echo "u-boot-rockchip.bin hash mismatch; re-fetching"
	need_fetch=1
fi

if [[ $need_fetch -eq 1 ]]; then
	echo "==> Fetching $ZIP_URL"
	curl -fsSL -o "$ZIP_NAME.partial" "$ZIP_URL"
	echo "$ZIP_SHA  $ZIP_NAME.partial" | sha256sum -c
	mv -f "$ZIP_NAME.partial" "$ZIP_NAME"
	rm -rf .extract
	mkdir .extract
	unzip -q "$ZIP_NAME" -d .extract
	BIN=$(find .extract -name u-boot-rockchip.bin -type f | head -1)
	[[ -n $BIN ]] || die "zip has no u-boot-rockchip.bin"
	echo "$BIN_SHA  $BIN" | sha256sum -c
	cp -f "$BIN" u-boot-rockchip.bin
	# Keep vendor notes if present
	R=$(find .extract -name readme.txt -type f | head -1 || true)
	S=$(find .extract -name sha256sums.txt -type f | head -1 || true)
	[[ -n ${R:-} ]] && cp -f "$R" upstream-readme.txt
	[[ -n ${S:-} ]] && cp -f "$S" upstream-sha256sums.txt
	rm -rf .extract
	info "installed u-boot-rockchip.bin"
else
	info "u-boot-rockchip.bin already present and verified"
fi

echo "$BIN_SHA  u-boot-rockchip.bin" | sha256sum -c
ls -la u-boot-rockchip.bin
echo "OK. Flash offset: sector 64 (dd bs=512 seek=64). Do NOT flash SPI from this tree."
