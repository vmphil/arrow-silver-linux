#!/usr/bin/env bash
# seed-chroot-secrets-from-squash.sh — copy missing auth files from the
# arm64 live squashfs into live-arm64/chroot (heals an incomplete SSD/NTFS
# copy that skipped root-only files like etc/shadow).
#
#   sudo ~/Documents/Arrow-Silver/live-pinetab/scripts/seed-chroot-secrets-from-squash.sh
#
# Safe to re-run: only fills files that are missing. Does not overwrite.
# The PineTab2 image builder also seeds into the *image mount* at build time,
# so you only need this if you want the on-disk chroot itself to be complete.

set -euo pipefail

AS=/home/philip/Documents/Arrow-Silver
LIVE_ARM=$AS/live-arm64
CHROOT=$LIVE_ARM/chroot
SQUASH=$LIVE_ARM/binary/live/filesystem.squashfs

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "    $*"; }
warn() { echo "    WARNING: $*" >&2; }

if [[ $(id -u) -ne 0 ]]; then
	die "Run with sudo: sudo $0"
fi

[[ -d $CHROOT ]] || die "missing chroot $CHROOT"
[[ -f $SQUASH ]] || die "missing squashfs $SQUASH"
command -v unsquashfs >/dev/null || die "unsquashfs not found (install squashfs-tools)"

need=()
for f in etc/shadow etc/gshadow etc/sudoers etc/shadow- etc/gshadow-; do
	if [[ ! -e $CHROOT/$f ]]; then
		need+=("$f")
	fi
done

if [[ ${#need[@]} -eq 0 ]]; then
	echo "chroot already has shadow/gshadow/sudoers — nothing to do."
	exit 0
fi

echo "==> Seeding into $CHROOT from $SQUASH"
echo "    missing: ${need[*]}"

WORK=$(mktemp -d /tmp/seed-chroot-secrets.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

unsquashfs -f -d "$WORK/squash-seed" "$SQUASH" "${need[@]}"

for f in "${need[@]}"; do
	src=$WORK/squash-seed/$f
	[[ -e $src ]] || { warn "not in squashfs: $f"; continue; }
	mkdir -p "$CHROOT/$(dirname "$f")"
	cp -a "$src" "$CHROOT/$f"
	case "$f" in
		etc/shadow|etc/gshadow|etc/shadow-|etc/gshadow-)
			if getent group shadow >/dev/null 2>&1; then
				chown root:shadow "$CHROOT/$f"
			else
				chown root:root "$CHROOT/$f"
			fi
			chmod 640 "$CHROOT/$f"
			;;
		etc/sudoers)
			chown root:root "$CHROOT/$f"
			chmod 440 "$CHROOT/$f"
			;;
	esac
	info "installed /$f"
done

[[ -e $CHROOT/etc/shadow ]] || die "still missing etc/shadow after seed"
echo "Done. Chroot auth files restored."
