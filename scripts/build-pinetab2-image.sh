#!/usr/bin/env bash
# build-pinetab2-image.sh — build an Arrow Silver raw disk image for the
# PINE64 PineTab2 (RK3566) with U-Boot at the Rockchip SD/eMMC offset.
#
#   sudo ~/Documents/Arrow-Silver/live-pinetab/scripts/build-pinetab2-image.sh
#   sudo …/build-pinetab2-image.sh --force          # overwrite existing .img
#   sudo COMPRESS=1 …/build-pinetab2-image.sh       # also write .img.xz
#   sudo DTB=rk3566-pinetab2-v0.1.dtb …             # early hardware revision
#
# What it does, in order:
#   1. Preflight (root, tools, live-arm64/chroot, pinned U-Boot, bes2600 .deb)
#   2. Create a sparse GPT image: p1 ext4 /boot (~512 MiB), p2 ext4 /
#   3. rsync live-arm64/chroot → root (read-only source; never writes into it)
#   4. Under qemu-aarch64: create ArrowSilver/live; install headers + growpart +
#      bes2600-dkms; then strip live/Calamares/GRUB-EFI (initramfs deferred)
#   5. Install patched BES2600 DTBs, extlinux.conf, fstab, first-boot expand
#      (+ desktop look from overlay/desktop: Docklike dock, compositing,
#       Spectral VM fix, optional wallpapers; applied at the end of step 6)
#   6. Rebuild initrd once; write u-boot-rockchip.bin at sector 64; SHA256SUMS
#
# Does NOT flash SPI. Does NOT modify live-arm64/ permanently.
# Output: live-pinetab/out/arrow-silver-pinetab2-YYYY-MM-DD.img

set -euo pipefail

AS=/home/philip/Documents/Arrow-Silver
LIVE_ARM=$AS/live-arm64
CHROOT_SRC=$LIVE_ARM/chroot
PT=$AS/live-pinetab
OUT_DIR=$PT/out
OVERLAY=$PT/overlay
DESKTOP_OVL=$OVERLAY/desktop   # 2026-10-17: dock/transparency/Spectral fix/wallpapers (from Daily ARM64)
UBOOT_DIR=$PT/u-boot/pinetab2
UBOOT_BIN=$UBOOT_DIR/u-boot-rockchip.bin
BES_DEB_DIR=$PT/drivers/bes2600/deb
BES_DT_DIR=$PT/drivers/bes2600/dt
BES_FW_HELPER=$PT/drivers/bes2600/arrow-silver-bes2600-firmware
FETCH_UBOOT=$PT/scripts/fetch-uboot-pinetab2.sh
SPECTRAL_DEB_DIR=$PT/packages   # 2026-10-18: spectral-browser_*_arm64.deb (built from ~/spectral-browser)

# Image geometry (MiB). First 16 MiB reserved for GPT + U-Boot (bin ~9.2 MiB at 32 KiB).
IMG_SIZE_MIB=${IMG_SIZE_MIB:-6144}   # 6 GiB sparse
BOOT_START_MIB=16
BOOT_SIZE_MIB=512
DTB_NAME=${DTB:-rk3566-pinetab2-v2.0.dtb}
COMPRESS=${COMPRESS:-0}
FORCE=0
DATE_STAMP=$(date +%Y-%m-%d)
IMG_BASENAME=arrow-silver-pinetab2-$DATE_STAMP
IMG=$OUT_DIR/$IMG_BASENAME.img

STRIP_PKGS=(
	live-boot live-boot-initramfs-tools live-config live-config-systemd live-tools
	calamares
	grub-efi-arm64 grub-efi-arm64-bin grub-efi-arm64-unsigned grub2-common
	yakuake   # 2026-10-23: drop-down terminal does not work on PineTab2 (inherited from ARM64 base)
)
ADD_PKGS=(
	linux-headers-arm64 dkms build-essential
	cloud-guest-utils e2fsprogs parted
	rsync util-linux   # 2026-10-18: arrow-silver-install-emmc (rsync, wipefs, lsblk)
	curl wget ca-certificates   # 2026-10-18: downloads (e.g. Grok Bot .deb)
	u-boot-menu
	xfce4-terminal   # 2026-10-23: replaces Yakuake as the terminal (ARM64 base has only xterm)
	xfce4-docklike-plugin mousepad   # 2026-10-17: bottom dock + text editor (match Daily ARM64)
	# 2026-10-19: YouTube in Spectral (WebKitGTK -> GStreamer codecs)
	gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
	gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-gl
	gstreamer1.0-alsa gstreamer1.0-pulseaudio
	pulseaudio-utils   # 2026-10-19: pactl for the XF86Audio volume-key shortcuts
	flatpak gnome-software gnome-software-plugin-flatpak   # 2026-10-22: app store + Flathub
	xdg-user-dirs xdg-user-dirs-gtk   # 2026-10-22: Documents/Music/Pictures/Downloads for new users
)

STAMP() { date +%H:%M:%S; }
step() { echo; echo "==> [$(STAMP)] $*"; }
info() { echo "    $*"; }
warn() { echo "    WARNING: $*" >&2; }
die()  { echo; echo "ERROR: $*" >&2; exit 1; }

for arg in "$@"; do
	case "$arg" in
		--force|-f) FORCE=1 ;;
		--compress) COMPRESS=1 ;;
		--help|-h)
			sed -n '2,20p' "$0"
			exit 0
			;;
		*) die "unknown argument: $arg (try --force / --compress)" ;;
	esac
done

if [[ $(id -u) -ne 0 ]]; then
	die "Run with sudo: sudo $0"
fi

T0=$(date +%s)
LOOP=
MNT=
QEMU_COPIED=0
POLICY_CREATED=0
RESOLV_MOVED=0
DONE=0
WORK=

mounts_under() {
	# findmnt -r escapes spaces as \x20 ("Written Apps") and the project path
	# goes through the ~/Documents symlink; match the real path in unescaped
	# list mode so mounts are actually found.
	local prefix
	prefix=$(realpath -m "$1")
	findmnt -ln -o TARGET | awk -v p="$prefix/" 'index($0, p) == 1' | sort -r
}

unmount_under() {
	local prefix=$1 m pass
	for pass in 1 2 3 4 5 6 7 8 9 10; do
		local list
		list=$(mounts_under "$prefix")
		[[ -z $list ]] && return 0
		while IFS= read -r m; do
			[[ -z $m ]] && continue
			if umount "$m" 2>/dev/null; then
				info "unmounted $m"
			elif umount -l "$m" 2>/dev/null; then
				info "lazy-unmounted $m"
			else
				warn "could not unmount $m (pass $pass)"
			fi
		done <<<"$list"
	done
	[[ -z $(mounts_under "$prefix") ]]
}

teardown_chroot() {
	if [[ -n ${MNT:-} && -d ${MNT:-} ]]; then
		if [[ $POLICY_CREATED -eq 1 ]]; then
			rm -f "$MNT/usr/sbin/policy-rc.d" || true
			POLICY_CREATED=0
		fi
		unmount_under "$MNT" || warn "mounts still present under $MNT"
		if [[ $RESOLV_MOVED -eq 1 ]]; then
			rm -f "$MNT/etc/resolv.conf" || true
			mv "$MNT/etc/resolv.conf.arrow-img-bak" "$MNT/etc/resolv.conf" 2>/dev/null || true
			RESOLV_MOVED=0
		fi
		if [[ $QEMU_COPIED -eq 1 ]]; then
			rm -f "$MNT/usr/bin/qemu-aarch64-static" || true
			QEMU_COPIED=0
		fi
	fi
	return 0
}

detach_loop() {
	if [[ -z ${LOOP:-} ]]; then
		return 0
	fi
	local tries=0
	while [[ $tries -lt 5 ]]; do
		if losetup -d "$LOOP" 2>/dev/null; then
			info "detached $LOOP"
			LOOP=
			return 0
		fi
		tries=$((tries + 1))
		sleep 0.4
	done
	warn "could not detach $LOOP (still busy?); leaving LOOP set for diagnostics"
	return 1
}

cleanup_mounts() {
	# Always detach nested mounts first, then boot, then root — unmount_under
	# only matches prefix/, so $MNT itself must be umounted explicitly.
	if [[ -z ${MNT:-} || ! -d ${MNT:-} ]]; then
		return 0
	fi
	teardown_chroot
	if mountpoint -q "$MNT/boot" 2>/dev/null; then
		umount "$MNT/boot" 2>/dev/null || umount -l "$MNT/boot" 2>/dev/null || warn "boot still mounted at $MNT/boot"
	fi
	unmount_under "$MNT" || true
	if mountpoint -q "$MNT" 2>/dev/null; then
		umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || warn "root still mounted at $MNT"
	fi
	rmdir "$MNT" 2>/dev/null || true
}

cleanup() {
	local rc=$?
	set +e
	cleanup_mounts
	MNT=
	detach_loop || true
	[[ -n ${WORK:-} ]] && rm -rf "$WORK"
	if [[ $DONE -ne 1 ]]; then
		echo
		echo "Stopped with exit code $rc. Loop/mounts cleaned up." >&2
		if [[ -e ${IMG:-}.partial ]]; then
			echo "Partial image left at ${IMG}.partial (remove or retry with --force)." >&2
		fi
		echo "If a prior run left a stuck loop, see BUILD-PINETAB.md (cleanup one-liner)." >&2
	fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

chroot_run() {
	# FLASH_KERNEL_SKIP: this is an extlinux/U-Boot disk image, not flash-kernel.
	# INITRD=Yes: keep initrd generation eligible once we re-enable update-initramfs.
	chroot "$MNT" /usr/bin/env -i \
		HOME=/root \
		PATH=/usr/sbin:/usr/bin:/sbin:/bin \
		LANG=C.UTF-8 LC_ALL=C.UTF-8 \
		DEBIAN_FRONTEND=noninteractive \
		DEBCONF_NONINTERACTIVE_SEEN=true \
		FLASH_KERNEL_SKIP=1 \
		INITRD=Yes \
		TMPDIR=/var/tmp \
		"$@"
}

# Log a chroot command to live-pinetab/out/ (also keep stdout/stderr on the console).
chroot_run_log() {
	local log=$1 rcfile rc
	shift
	mkdir -p "$(dirname "$log")"
	rcfile=$(mktemp)
	{
		echo "==== $(date -Iseconds) :: $*"
		set +e
		chroot_run "$@"
		rc=$?
		set -e
		echo "$rc" >"$rcfile"
		echo "==== exit $rc :: $*"
	} 2>&1 | tee -a "$log"
	rc=$(cat "$rcfile")
	rm -f "$rcfile"
	return "$rc"
}


# --- update-initramfs recovery -------------------------------------------
# In Debian forky (0.151) /usr/sbin/update-initramfs ships in the
# *initramfs-tools* package (initramfs-tools-core only has mkinitramfs etc.),
# so reinstalling -core never brings it back. live-tools diverts it to
# update-initramfs.orig.initramfs-tools and owns a symlink at the real path
# (-> ../bin/live-update-initramfs). Removing live-tools deletes whatever file
# sits at /usr/sbin/update-initramfs (it is in live-tools.list), after which the
# initramfs-tools trigger/postinst dies with "update-initramfs: not found" (127).

UIT_PATHS=(/usr/sbin/update-initramfs /sbin/update-initramfs)

# Real binary = regular file (not the live symlink), executable.
update_initramfs_is_real() {
	[[ -f $MNT/usr/sbin/update-initramfs && ! -L $MNT/usr/sbin/update-initramfs \
		&& -x $MNT/usr/sbin/update-initramfs ]]
}

# Remove every dpkg diversion matching *update-initramfs* (binary + man page,
# /usr/sbin and /sbin), putting the diverted original back at the real path.
clear_update_initramfs_diversions() {
	local tag=${1:+ ($1)} line path divto owner
	local re_local='^local diversion of (.+) to (.+)$'
	local re_pkg='^diversion of (.+) to (.+) by (.+)$'
	local -a who lines=()
	mapfile -t lines < <(chroot_run dpkg-divert --list '*update-initramfs*' 2>/dev/null || true)
	for line in "${lines[@]}"; do
		[[ -n $line ]] || continue
		if [[ $line =~ $re_local ]]; then
			path=${BASH_REMATCH[1]} divto=${BASH_REMATCH[2]} owner=""
			who=(--local)
		elif [[ $line =~ $re_pkg ]]; then
			path=${BASH_REMATCH[1]} divto=${BASH_REMATCH[2]} owner=${BASH_REMATCH[3]}
			who=(--package "$owner")
		else
			warn "unparsed dpkg-divert line: $line"
			continue
		fi
		info "removing diversion $path -> $divto${owner:+ (by $owner)}${tag}"
		# dpkg-divert --rename refuses to overwrite an existing file, and the
		# thing at $path is the live wrapper/symlink. Drop it when the real
		# (diverted) file is still around so --rename can move it back.
		if [[ -e $MNT$divto && ! -L $MNT$divto ]] && [[ -e $MNT$path || -L $MNT$path ]]; then
			rm -f "$MNT$path"
		fi
		if ! chroot_run dpkg-divert "${who[@]}" --divert "$divto" --rename --remove "$path" \
			>>"$APT_LOG" 2>&1; then
			warn "dpkg-divert --rename --remove $path failed; removing without --rename"
			chroot_run dpkg-divert "${who[@]}" --divert "$divto" --remove "$path" >>"$APT_LOG" 2>&1 \
				|| die "cannot remove diversion of $path (see $APT_LOG)"
			if [[ -f $MNT$divto ]]; then
				rm -f "$MNT$path"
				mv "$MNT$divto" "$MNT$path"
			fi
		fi
	done
	if chroot_run dpkg-divert --list '*update-initramfs*' 2>/dev/null | grep -q .; then
		die "update-initramfs diversions still present after cleanup:
$(chroot_run dpkg-divert --list '*update-initramfs*' 2>&1)"
	fi
}

# Leftover .orig/.distrib copies with no diversion: move back over a missing
# or symlinked real path (live wrapper / dangling symlink).
restore_update_initramfs_leftovers() {
	local tag=${1:+ ($1)} p suf f
	for p in "${UIT_PATHS[@]}" /usr/share/man/man8/update-initramfs.8.gz; do
		for suf in .orig.initramfs-tools .orig .distrib; do
			f=$MNT$p$suf
			[[ $p == *.8.gz ]] && f=$MNT${p%.8.gz}$suf.8.gz
			[[ -f $f && ! -L $f ]] || continue
			if [[ -L $MNT$p || ! -e $MNT$p ]]; then
				info "restoring $p from $(basename "$f")${tag}"
				rm -f "$MNT$p"
				mv "$f" "$MNT$p"
			fi
		done
	done
	# Dangling / live-wrapper symlink at the real path: remove so dpkg --unpack
	# (or the check below) sees the truth.
	if [[ -L $MNT/usr/sbin/update-initramfs ]]; then
		info "removing symlink $(readlink "$MNT/usr/sbin/update-initramfs") at /usr/sbin/update-initramfs${tag}"
		rm -f "$MNT/usr/sbin/update-initramfs"
	fi
}

# Once live-tools no longer diverts update-initramfs, its stale claim on the
# path in live-tools.list makes `apt-get purge live-tools` delete the *real*
# binary. Drop those entries so the purge leaves initramfs-tools intact.
disown_live_tools_update_initramfs() {
	local list=$MNT/var/lib/dpkg/info/live-tools.list p
	[[ -f $list ]] || return 0
	if chroot_run dpkg-divert --list '*update-initramfs*' 2>/dev/null | grep -q .; then
		return 0
	fi
	for p in "${UIT_PATHS[@]}" /usr/share/man/man8/update-initramfs.8.gz; do
		if grep -qxF "$p" "$list"; then
			info "dropping $p from live-tools.list (owned by initramfs-tools now)"
			grep -vxF "$p" "$list" >"$list.arrow-tmp" || true
			cat "$list.arrow-tmp" >"$list"
			rm -f "$list.arrow-tmp"
		fi
	done
}

# Download and dpkg --unpack (NO configure → no postinst → cannot hit the
# missing binary) the given packages, preferring their installed versions.
unpack_debs_no_configure() {
	local dir=/tmp/arrow-initramfs-debs pkg ver tag=$1
	local -a specs=() cands=() debs=()
	shift
	rm -rf "${MNT:?}$dir"
	mkdir -p "$MNT$dir"
	chmod 1777 "$MNT$dir"
	for pkg in "$@"; do
		ver=$(chroot_run dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
		specs+=("$pkg${ver:+=$ver}")
		cands+=("$pkg")
	done
	if ! chroot_run_log "$APT_LOG" bash -c 'cd "$1" && shift && apt-get download "$@"' \
		_ "$dir" "${specs[@]}"; then
		warn "installed version(s) not downloadable; fetching candidate(s): ${cands[*]}${tag}"
		rm -f "$MNT$dir"/*.deb
		chroot_run_log "$APT_LOG" bash -c 'cd "$1" && shift && apt-get download "$@"' \
			_ "$dir" "${cands[@]}" \
			|| die "apt-get download ${cands[*]} failed — see $APT_LOG"
	fi
	for pkg in "$@"; do
		shopt -s nullglob
		local -a got=("$MNT$dir/${pkg}_"*.deb)
		shopt -u nullglob
		[[ ${#got[@]} -ge 1 ]] || die "apt-get download produced no ${pkg}_*.deb in $dir"
		debs+=("$dir/$(basename "${got[0]}")")
	done
	chroot_run_log "$APT_LOG" dpkg --force-hold --unpack "${debs[@]}" \
		|| die "dpkg --unpack ${debs[*]} failed — see $APT_LOG"
	rm -rf "${MNT:?}$dir"
}

# Ensure /usr/sbin/update-initramfs is the real initramfs-tools binary and
# initramfs-tools is configured. Safe to call repeatedly; call while
# update_initramfs=no is in effect (trigger runs but defers the rebuild).
ensure_update_initramfs() {
	local reason=${1:-} tag="" st core_ver tools_ver
	[[ -n $reason ]] && tag=" ($reason)"
	[[ -n ${APT_LOG:-} ]] || die "ensure_update_initramfs: APT_LOG unset"
	mkdir -p "$MNT/var/tmp"
	chmod 1777 "$MNT/var/tmp"

	clear_update_initramfs_diversions "$reason"
	restore_update_initramfs_leftovers "$reason"

	if update_initramfs_is_real; then
		info "update-initramfs OK at /usr/sbin/update-initramfs${tag}"
	else
		warn "update-initramfs missing; dpkg --unpack initramfs-tools (no configure)${tag}"
		unpack_debs_no_configure "$tag" initramfs-tools
		update_initramfs_is_real \
			|| die "/usr/sbin/update-initramfs still missing after 'dpkg --unpack initramfs-tools'${tag} — see $APT_LOG"
		info "update-initramfs restored from initramfs-tools .deb${tag}"
	fi

	# Core (mkinitramfs) only if its files are gone, or if the unpack above
	# pulled a different initramfs-tools version (Depends: -core (= same)).
	tools_ver=$(chroot_run dpkg-query -W -f='${Version}' initramfs-tools 2>/dev/null || true)
	core_ver=$(chroot_run dpkg-query -W -f='${Version}' initramfs-tools-core 2>/dev/null || true)
	if [[ ! -x $MNT/usr/sbin/mkinitramfs || $core_ver != "$tools_ver" ]]; then
		warn "initramfs-tools-core missing files or version skew (core=$core_ver tools=$tools_ver); unpacking core${tag}"
		unpack_debs_no_configure "$tag" initramfs-tools-core
	fi

	st=$(chroot_run dpkg-query -W -f='${db:Status-Abbrev}\n' initramfs-tools initramfs-tools-core 2>/dev/null || true)
	if [[ $(chroot_run dpkg --audit 2>/dev/null || true) != "" ]] || grep -qv '^ii' <<<"$st"; then
		info "dpkg --configure -a (binary present now)${tag}"
		chroot_run_log "$APT_LOG" dpkg --configure -a \
			|| warn "dpkg --configure -a returned non-zero${tag}"
	fi
	st=$(chroot_run dpkg-query -W -f='${db:Status-Abbrev}' initramfs-tools 2>/dev/null || true)
	[[ $st == ii* ]] \
		|| die "initramfs-tools still not configured (dpkg status '$st')${tag} — see $APT_LOG"
}

# Run an apt/dpkg command; if it fails *only* because initramfs-tools could
# not be configured, restore update-initramfs + dpkg --configure -a and carry
# on. Any other failure (other packages in "Errors were encountered", no dpkg
# error list at all = resolver/download failure, dpkg --audit not clean) dies.
run_apt_tolerating_initramfs() {
	local what=$1 rc=0 start failed audit
	shift
	start=$(wc -l <"$APT_LOG")
	chroot_run_log "$APT_LOG" "$@" || rc=$?
	(( rc == 0 )) && return 0
	failed=$(tail -n +"$((start + 1))" "$APT_LOG" \
		| awk '/^Errors were encountered while processing:/{f=1; next}
			f && /^ /{sub(/^ +/, ""); sub(/:.*/, ""); print; next} {f=0}' \
		| sort -u | tr '\n' ' ')
	failed=${failed% }
	if [[ $failed != initramfs-tools ]]; then
		die "$what failed (exit $rc); failing packages: '${failed:-none listed — not a dpkg configure error}' — see $APT_LOG"
	fi
	warn "$what exited $rc only because initramfs-tools failed to configure; recovering"
	ensure_update_initramfs "$what recovery"
	chroot_run_log "$APT_LOG" dpkg --configure -a \
		|| die "dpkg --configure -a still failing after restoring update-initramfs ($what) — see $APT_LOG"
	audit=$(chroot_run dpkg --audit 2>&1 || true)
	[[ -z $audit ]] || die "dpkg --audit not clean after $what:
$audit"
	info "$what: recovered (initramfs-tools configured)"
}

# Seed missing auth files into the *image mount* from the arm64 squashfs.
# The SSD/NTFS copy of live-arm64/chroot often lacks etc/shadow (root-only
# files skipped during the move). The build runs as root, so seeding $MNT
# is enough; use scripts/seed-chroot-secrets-from-squash.sh to heal the
# on-disk chroot separately.
seed_auth_from_squash() {
	local SQUASH=$LIVE_ARM/binary/live/filesystem.squashfs
	local need=() f dest mode owner
	for f in etc/shadow etc/gshadow etc/sudoers etc/shadow- etc/gshadow-; do
		if [[ ! -e $MNT/$f ]]; then
			need+=("$f")
		fi
	done
	if [[ ${#need[@]} -eq 0 ]]; then
		info "auth files present on image root (shadow/gshadow/sudoers)"
		return 0
	fi
	warn "image root missing: ${need[*]}"

	if [[ -f $SQUASH ]]; then
		command -v unsquashfs >/dev/null || die "unsquashfs required to seed auth files from $SQUASH"
		mkdir -p "$WORK/squash-seed"
		# Extract only the missing paths; -f overwrites within the seed dir.
		if ! unsquashfs -f -d "$WORK/squash-seed" "$SQUASH" "${need[@]}"; then
			die "unsquashfs failed extracting auth files from $SQUASH"
		fi
		for f in "${need[@]}"; do
			dest=$WORK/squash-seed/$f
			[[ -e $dest ]] || continue
			mkdir -p "$MNT/$(dirname "$f")"
			cp -a "$dest" "$MNT/$f"
			case "$f" in
				etc/shadow|etc/gshadow|etc/shadow-|etc/gshadow-)
					if getent group shadow >/dev/null 2>&1; then
						chown root:shadow "$MNT/$f"
					else
						chown root:root "$MNT/$f"
					fi
					chmod 640 "$MNT/$f"
					;;
				etc/sudoers)
					chown root:root "$MNT/$f"
					chmod 440 "$MNT/$f"
					;;
			esac
			info "seeded /$f from squashfs"
		done
	else
		warn "no squashfs at $SQUASH — synthesizing minimal locked shadow/gshadow/sudoers"
		if [[ ! -e $MNT/etc/shadow && -f $MNT/etc/passwd ]]; then
			local days=$(( $(date +%s) / 86400 ))
			: >"$MNT/etc/shadow"
			while IFS=: read -r name _rest; do
				[[ -n $name ]] || continue
				printf '%s:*:%s:0:99999:7:::\n' "$name" "$days" >>"$MNT/etc/shadow"
			done <"$MNT/etc/passwd"
			if getent group shadow >/dev/null 2>&1; then
				chown root:shadow "$MNT/etc/shadow"
			else
				chown root:root "$MNT/etc/shadow"
			fi
			chmod 640 "$MNT/etc/shadow"
			info "synthesized /etc/shadow (all accounts locked; chpasswd will set ArrowSilver)"
		fi
		if [[ ! -e $MNT/etc/gshadow && -f $MNT/etc/group ]]; then
			: >"$MNT/etc/gshadow"
			while IFS=: read -r name _x gid members; do
				[[ -n $name ]] || continue
				printf '%s:*:%s:%s\n' "$name" "$gid" "${members:-}" >>"$MNT/etc/gshadow"
			done <"$MNT/etc/group"
			if getent group shadow >/dev/null 2>&1; then
				chown root:shadow "$MNT/etc/gshadow"
			else
				chown root:root "$MNT/etc/gshadow"
			fi
			chmod 640 "$MNT/etc/gshadow"
			info "synthesized /etc/gshadow"
		fi
		if [[ ! -e $MNT/etc/sudoers ]]; then
			cat >"$MNT/etc/sudoers" << 'SUDOTMPL'
Defaults	env_reset
Defaults	mail_badpass
root	ALL=(ALL:ALL) ALL
%sudo	ALL=(ALL:ALL) ALL
SUDOTMPL
			chown root:root "$MNT/etc/sudoers"
			chmod 440 "$MNT/etc/sudoers"
			info "synthesized minimal /etc/sudoers"
		fi
	fi

	[[ -e $MNT/etc/shadow ]] || die "still no /etc/shadow on image after seed"
	[[ -e $MNT/etc/sudoers ]] || die "still no /etc/sudoers on image after seed"
}

# ---------------------------------------------------------- 0. preflight ---

step "Preflight checks"

[[ -d $CHROOT_SRC ]] || die "Missing live-arm64 chroot: $CHROOT_SRC (build/refresh the ARM64 ISO first)"
[[ -x $CHROOT_SRC/usr/bin/dpkg ]] || die "chroot looks incomplete (no /usr/bin/dpkg)"
SQUASH_FILE=$LIVE_ARM/binary/live/filesystem.squashfs
if [[ ! -e $CHROOT_SRC/etc/shadow ]]; then
	if [[ -f $SQUASH_FILE ]]; then
		warn "chroot missing etc/shadow (common after NTFS/SSD copy of root-only files)."
		warn "Build will seed shadow/gshadow/sudoers into the *image* from filesystem.squashfs."
		warn "To heal the on-disk chroot: sudo $PT/scripts/seed-chroot-secrets-from-squash.sh"
	else
		die "chroot missing etc/shadow and no squashfs at $SQUASH_FILE"
	fi
fi
[[ -d $BES_DEB_DIR ]] || die "Missing $BES_DEB_DIR"
[[ -x $BES_FW_HELPER ]] || die "Missing firmware helper $BES_FW_HELPER"
[[ -d $BES_DT_DIR ]] || die "Missing $BES_DT_DIR"
[[ -f $BES_DT_DIR/$DTB_NAME ]] || die "Missing patched DTB $BES_DT_DIR/$DTB_NAME (try DTB=rk3566-pinetab2-v0.1.dtb)"
[[ -f $BES_DT_DIR/rk3566-pinetab2-v0.1.dtb ]] || die "Missing v0.1 DTB"
[[ -f $BES_DT_DIR/rk3566-pinetab2-v2.0.dtb ]] || die "Missing v2.0 DTB"
[[ -f $OVERLAY/extlinux/extlinux.conf.in ]] || die "Missing overlay extlinux template"
[[ -f $OVERLAY/etc/fstab.in ]] || die "Missing overlay fstab template"
[[ -f $OVERLAY/usr/local/sbin/arrow-silver-firstboot ]] || die "Missing firstboot script"
[[ -f $OVERLAY/etc/systemd/system/arrow-silver-firstboot.service ]] || die "Missing firstboot unit"
for f in usr/local/sbin/arrow-silver-install-emmc usr/local/bin/arrow-silver-install-emmc-launch \
	usr/share/applications/arrow-silver-install-emmc.desktop; do
	[[ -f $OVERLAY/$f ]] || die "Missing eMMC installer file $OVERLAY/$f"
done
for f in etc/xdg/xfce4/panel/default.xml etc/xdg/xfce4/panel/docklike-11.rc \
	etc/skel/.config/xfce4/panel/docklike-11.rc \
	etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml etc/X11/Xsession.d/90arrow-webkit-vm \
	usr/share/backgrounds/arrow-silver-elf-ranger.png usr/share/backgrounds/arrow-silver-neon-city.png \
	usr/share/backgrounds/arrow-silver-cyber-alley.png; do
	[[ -f $DESKTOP_OVL/$f ]] || die "Missing desktop overlay file $DESKTOP_OVL/$f"
done

for t in losetup parted mkfs.ext4 truncate rsync findmnt sha256sum chroot \
	qemu-aarch64-static curl unzip sync numfmt blkid partprobe unsquashfs mountpoint; do
	command -v "$t" >/dev/null || die "$t not found on the host"
done
if [[ $COMPRESS == 1 ]]; then
	command -v xz >/dev/null || die "xz not found (needed for COMPRESS=1)"
fi

shopt -s nullglob
BES_DEBS=("$BES_DEB_DIR"/bes2600-dkms_*.deb)
shopt -u nullglob
[[ ${#BES_DEBS[@]} -eq 1 ]] || die "expected exactly one bes2600-dkms_*.deb in $BES_DEB_DIR"
shopt -s nullglob
SPECTRAL_DEBS=("$SPECTRAL_DEB_DIR"/spectral-browser_*_arm64.deb)
shopt -u nullglob
[[ ${#SPECTRAL_DEBS[@]} -eq 1 ]] || die "expected exactly one spectral-browser_*_arm64.deb in $SPECTRAL_DEB_DIR (build: sudo ~/spectral-browser/packaging/build-arm64.sh)"
dpkg-deb -f "${SPECTRAL_DEBS[0]}" Architecture | grep -qx arm64 || die "${SPECTRAL_DEBS[0]} is not an arm64 package"
info "Spectral:      $(basename "${SPECTRAL_DEBS[0]}")"

shopt -s nullglob
VMLINUZ=("$CHROOT_SRC"/boot/vmlinuz-*)
shopt -u nullglob
[[ ${#VMLINUZ[@]} -ge 1 ]] || die "no vmlinuz-* in $CHROOT_SRC/boot"
KVER=${VMLINUZ[0]##*/vmlinuz-}
[[ -f $CHROOT_SRC/boot/initrd.img-$KVER ]] || die "no initrd.img-$KVER in chroot"
info "source kernel: $KVER"
info "DTB default:   $DTB_NAME"
info "image size:    ${IMG_SIZE_MIB} MiB (sparse)"

need_uboot=0
if [[ ! -f $UBOOT_BIN ]]; then
	need_uboot=1
elif ! echo "91b5fb6eb7107ee574c996d227ff9072dbc7d3be3df759e1f48d90ba3b437b9a  $UBOOT_BIN" | sha256sum -c --status; then
	need_uboot=1
fi
if [[ $need_uboot -eq 1 ]]; then
	step "Fetching / verifying pinned U-Boot"
	[[ -x $FETCH_UBOOT ]] || die "missing $FETCH_UBOOT"
	if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
		sudo -u "$SUDO_USER" "$FETCH_UBOOT" || "$FETCH_UBOOT"
	else
		"$FETCH_UBOOT"
	fi
fi
[[ -f $UBOOT_BIN ]] || die "still no $UBOOT_BIN"
echo "91b5fb6eb7107ee574c996d227ff9072dbc7d3be3df759e1f48d90ba3b437b9a  $UBOOT_BIN" | sha256sum -c
UBOOT_BYTES=$(stat -c %s "$UBOOT_BIN")
info "U-Boot: $UBOOT_BIN ($UBOOT_BYTES bytes) → write at sector 64"

mkdir -p "$OUT_DIR"
IMG_PARTIAL=$IMG.partial
if [[ -e $IMG || -e $IMG.xz || -e $IMG_PARTIAL ]]; then
	if [[ $FORCE -ne 1 ]]; then
		die "Refusing to overwrite $IMG (and/or .xz / .partial). Re-run with --force."
	fi
	info "--force: will replace existing $IMG_BASENAME.img*"
fi

# Detach any leftover loop from a previous crashed run that still points at today's partial.
release_stale_partial() {
	local partial=$1
	[[ -e $partial ]] || return 0
	local line loopdev
	while IFS= read -r line; do
		[[ -z $line ]] && continue
		loopdev=${line%%:*}
		info "found stale loop $loopdev on $partial — unmounting partitions"
		local mp
		for mp in $(findmnt -rn -o TARGET -S "${loopdev}p2" 2>/dev/null; findmnt -rn -o TARGET -S "${loopdev}p1" 2>/dev/null); do
			[[ -z $mp ]] && continue
			umount "$mp/boot" 2>/dev/null || true
			umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || warn "could not unmount $mp"
			rmdir "$mp" 2>/dev/null || true
		done
		# Also scan /tmp/pinetab2-mnt.* mountpoints
		for mp in /tmp/pinetab2-mnt.*; do
			[[ -d $mp ]] || continue
			if findmnt -rn -o SOURCE -T "$mp" 2>/dev/null | grep -q "$loopdev"; then
				umount "$mp/boot" 2>/dev/null || true
				umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
				rmdir "$mp" 2>/dev/null || true
			fi
		done
		losetup -d "$loopdev" 2>/dev/null || warn "could not detach $loopdev"
	done < <(losetup -j "$partial" 2>/dev/null || true)
}
if [[ $FORCE -eq 1 ]]; then
	release_stale_partial "$IMG_PARTIAL"
	release_stale_partial "$IMG"
fi

AVAIL_K=$(df -Pk "$OUT_DIR" | awk 'NR==2{print $4}')
NEED_K=$((8 * 1024 * 1024))
if [[ $AVAIL_K -lt $NEED_K ]]; then
	die "Need ~8 GiB free under $OUT_DIR (have $((AVAIL_K/1024/1024)) GiB)"
fi

BINFMT=/proc/sys/fs/binfmt_misc/qemu-aarch64
[[ -r $BINFMT ]] || die "qemu-aarch64 binfmt not registered ($BINFMT)"
grep -qx enabled "$BINFMT" || die "qemu-aarch64 binfmt is registered but disabled"
FLAGS=$(awk '/^flags:/{print $2}' "$BINFMT")
info "binfmt qemu-aarch64: enabled, flags=$FLAGS"

WORK=$(mktemp -d /tmp/build-pinetab2.XXXXXX)
MNT=$(mktemp -d /tmp/pinetab2-mnt.XXXXXX)
rm -f "$IMG_PARTIAL"

# ----------------------------------------------------- 1. create image ---

step "1/7 Creating sparse GPT image (${IMG_SIZE_MIB} MiB)"
truncate -s "${IMG_SIZE_MIB}M" "$IMG_PARTIAL"
parted -s "$IMG_PARTIAL" mklabel gpt
parted -s "$IMG_PARTIAL" unit MiB mkpart boot ext4 ${BOOT_START_MIB} $((BOOT_START_MIB + BOOT_SIZE_MIB))
parted -s "$IMG_PARTIAL" unit MiB mkpart root ext4 $((BOOT_START_MIB + BOOT_SIZE_MIB)) 100%
# 2026-10-17 boot fix: "boot" on GPT turns p1 into an EFI System Partition
# (type C12A7328…) even though it is ext4. U-Boot's distro boot wants the
# "legacy_boot" attribute instead; with it set, bootflow scans only p1.
parted -s "$IMG_PARTIAL" set 1 legacy_boot on
parted -s "$IMG_PARTIAL" print | sed 's/^/    /'

step "1/7 Attaching loop device"
LOOP=$(losetup --find --show --partscan "$IMG_PARTIAL")
info "loop: $LOOP"
# 2026-10-18 loop fix: --partscan already makes p1/p2. Calling partprobe while
# they appear makes udev delete and re-create them, so mkfs raced a missing
# node. Wait for udev to finish, and only partprobe if nothing shows up.
for i in $(seq 1 40); do
	udevadm settle --timeout=5 2>/dev/null || true
	[[ -b ${LOOP}p1 && -b ${LOOP}p2 ]] && break
	sleep 0.5
	(( i == 10 || i == 25 )) && { partprobe "$LOOP" 2>/dev/null || true; }
done
udevadm settle --timeout=5 2>/dev/null || true
sleep 1
[[ -b ${LOOP}p1 && -b ${LOOP}p2 ]] || die "partition nodes ${LOOP}p1/p2 did not appear"

step "1/7 Formatting ext4"
mkfs.ext4 -F -L AS-boot -q "${LOOP}p1"
mkfs.ext4 -F -L AS-root -q "${LOOP}p2"
BOOT_UUID=$(blkid -s UUID -o value "${LOOP}p1")
ROOT_UUID=$(blkid -s UUID -o value "${LOOP}p2")
[[ -n $BOOT_UUID && -n $ROOT_UUID ]] || die "failed to read partition UUIDs"
info "boot UUID=$BOOT_UUID"
info "root UUID=$ROOT_UUID"

# ----------------------------------------------------- 2. mount + rsync ---

step "2/7 Mounting and rsyncing live-arm64/chroot → image root"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

SRC_FSTYPE=$(findmnt -no FSTYPE -T "$CHROOT_SRC" 2>/dev/null || true)
RSYNC_FLAGS=(-aH --info=progress2)
case "$SRC_FSTYPE" in
	ntfs|ntfs3|fuseblk|fuse.ntfs*)
		info "chroot source on $SRC_FSTYPE — skipping ACL/xattr flags (-AX) for reliability"
		;;
	*)
		# Still prefer -aH only: ACLs/xattrs from a mixed host often trip rsync 23.
		info "chroot source fstype=${SRC_FSTYPE:-unknown} — using rsync -aH (no -AX)"
		;;
esac

set +e
rsync "${RSYNC_FLAGS[@]}" \
	--exclude=/dev --exclude=/proc --exclude=/sys --exclude=/run \
	--exclude=/tmp --exclude=/mnt --exclude=/media \
	--exclude=/boot/grub \
	--exclude='/var/cache/apt/archives/*.deb' \
	--exclude=/var/tmp \
	"$CHROOT_SRC/" "$MNT/"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
	info "rsync complete"
elif [[ $rc -eq 23 ]]; then
	warn "rsync finished with code 23 (some attrs/files skipped — common on NTFS). Continuing if rootfs looks usable."
else
	die "rsync failed with exit $rc"
fi
[[ -x $MNT/usr/bin/dpkg ]] || die "rsync left unusable root (no dpkg)"

mkdir -p "$MNT"/{dev,proc,sys,run,tmp,mnt,media,boot,var/tmp}
chmod 1777 "$MNT/tmp" "$MNT/var/tmp"
# mkinitramfs defaults to TMPDIR=/var/tmp; rsync excludes /var/tmp so recreate it
# or update-initramfs fails with: mktemp: ... /var/tmp/mkinitramfs_XXXXXX: No such file

# Ensure /boot (separate partition) still has the kernel/initrd from the live chroot.
# NTFS rsync-23 can theoretically skip large boot files; copy from source if missing.
ensure_boot_kernel_files() {
	local src=$CHROOT_SRC/boot
	local dst=$MNT/boot
	mkdir -p "$dst"
	if [[ ! -f $dst/vmlinuz-$KVER ]]; then
		[[ -f $src/vmlinuz-$KVER ]] || die "missing vmlinuz-$KVER on boot partition and in $src"
		warn "copying vmlinuz-$KVER onto image /boot (was missing after rsync)"
		cp -a "$src/vmlinuz-$KVER" "$dst/"
	fi
	if [[ ! -f $dst/initrd.img-$KVER ]]; then
		if [[ -f $src/initrd.img-$KVER ]]; then
			warn "copying initrd.img-$KVER onto image /boot (was missing after rsync)"
			cp -a "$src/initrd.img-$KVER" "$dst/"
		else
			warn "no initrd.img-$KVER yet — will be built later"
		fi
	fi
	for f in "config-$KVER" "System.map-$KVER"; do
		if [[ ! -f $dst/$f && -f $src/$f ]]; then
			cp -a "$src/$f" "$dst/" || true
		fi
	done
	info "boot payload: $(ls -1 "$dst"/vmlinuz-$KVER "$dst"/initrd.img-$KVER 2>/dev/null | tr '\n' ' ')"
}
ensure_boot_kernel_files

step "2/7 Seeding missing auth files (shadow/gshadow/sudoers) if needed"
seed_auth_from_squash

# ----------------------------------------------- 3. qemu chroot setup ---

step "3/7 Preparing qemu-aarch64 chroot in the image"
if [[ -e $MNT/etc/resolv.conf || -L $MNT/etc/resolv.conf ]]; then
	mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.arrow-img-bak"
	RESOLV_MOVED=1
fi
[[ -e /etc/resolv.conf ]] || die "host has no /etc/resolv.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

if [[ $FLAGS != *F* ]]; then
	HOSTQEMU=$(readlink -f /usr/bin/qemu-aarch64-static)
	[[ -x $HOSTQEMU ]] || die "no qemu-aarch64-static"
	cp -a "$HOSTQEMU" "$MNT/usr/bin/qemu-aarch64-static"
	QEMU_COPIED=1
	info "copied qemu-aarch64-static into image (binfmt has no F flag)"
fi

mount -t proc proc "$MNT/proc"
mount -t sysfs sysfs "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t tmpfs tmpfs "$MNT/run"
mount -t tmpfs tmpfs "$MNT/tmp"

if [[ ! -e $MNT/usr/sbin/policy-rc.d ]]; then
	printf '#!/bin/sh\nexit 101\n' >"$MNT/usr/sbin/policy-rc.d"
	chmod 755 "$MNT/usr/sbin/policy-rc.d"
	POLICY_CREATED=1
fi

# ------------------------------------------ 4. strip + install packages ---

APT_LOG=$OUT_DIR/apt-pinetab2-$DATE_STAMP.log
INITRD_LOG=$OUT_DIR/update-initramfs-pinetab2-$DATE_STAMP.log
: >"$APT_LOG"
: >"$INITRD_LOG"
info "apt log:    $APT_LOG"
info "initrd log: $INITRD_LOG"

# Defer initramfs rebuilds during purge/install. live-boot-initramfs-tools postrm
# and package triggers call update-initramfs; without /var/tmp that hard-fails
# initramfs-tools configure (dpkg exit 100). We rebuild once at step 6.
INITRAMFS_UCONF=$MNT/etc/initramfs-tools/update-initramfs.conf
if [[ -f $INITRAMFS_UCONF ]]; then
	cp -a "$INITRAMFS_UCONF" "$INITRAMFS_UCONF.arrow-bak"
fi
mkdir -p "$MNT/etc/initramfs-tools"
cat >"$INITRAMFS_UCONF" <<'UIEOF'
# Arrow Silver image build: defer until packages settle (restored before step 6).
update_initramfs=no
backup_initramfs=no
UIEOF

# Drop live-tools' diversion early so /usr/sbin/update-initramfs is the real
# initramfs-tools binary (not the live-update-initramfs symlink). No download
# here (apt-get update not run yet); full ensure_update_initramfs follows.
clear_update_initramfs_diversions "early, before apt-get update"
restore_update_initramfs_leftovers "early, before apt-get update"

step "4/7 Creating ArrowSilver / live user (before apt churn)"
# Keep a known live-style login so Phil can test without a first-boot wizard.
if ! chroot_run id ArrowSilver >/dev/null 2>&1; then
	chroot_run useradd -m -s /bin/bash -c 'Arrow Silver Live' \
		-G sudo,audio,video,plugdev,netdev,input ArrowSilver
fi
chroot_run usermod -aG sudo,audio,video,plugdev,netdev,input ArrowSilver 2>/dev/null || true
chroot_run usermod -aG bluetooth ArrowSilver 2>/dev/null || true
echo 'ArrowSilver:live' | chroot_run chpasswd
mkdir -p "$MNT/etc/sudoers.d"
cat >"$MNT/etc/sudoers.d/arrowsilver-live" << 'SUEOF'
ArrowSilver ALL=(ALL) NOPASSWD: ALL
SUEOF
chmod 440 "$MNT/etc/sudoers.d/arrowsilver-live"
if [[ -d $MNT/etc/lightdm ]]; then
	mkdir -p "$MNT/etc/lightdm/lightdm.conf.d"
	cat >"$MNT/etc/lightdm/lightdm.conf.d/50-arrowsilver-autologin.conf" << 'LDEOF'
[Seat:*]
autologin-user=ArrowSilver
autologin-user-timeout=0
user-session=xfce
LDEOF
fi
info "login: ArrowSilver / live  (change after first successful boot)"

step "4/7 Installing tablet packages + linux-headers (before live purge)"
# 2026-10-18 apt fix: the ARM64 live build pins the kernel to 7.2.8-1 at
# priority 990 (live-arm64/config/archives/kernel-7.2.8.pref.chroot ->
# /etc/apt/preferences.d/kernel-7.2.8.pref). 7.2.8 is gone from forky, so the
# pin keeps linux-image-arm64/linux-base-arm64 at 7.2.8 while
# linux-headers-arm64 needs 7.2.11 -> apt exit 100, and the new solver then
# reports build-essential/dkms/mousepad as "not going to be installed" too.
# Drop the pin in the *image only* (base chroot untouched), refetch full
# lists (no pdiffs on top of the chroot's 10-12 lists), and full-upgrade the
# 10-12 chroot to today's forky before installing (no partial upgrade).
for pref in "$MNT"/etc/apt/preferences.d/kernel-*.pref; do
	[[ -e $pref ]] || continue
	info "dropping kernel pin $(basename "$pref") from the image"
	rm -f "$pref"
done
find "$MNT/var/lib/apt/lists" -maxdepth 1 -type f ! -name lock -delete 2>/dev/null || true
rm -rf "$MNT/var/lib/apt/lists/partial/"* 2>/dev/null || true
chroot_run_log "$APT_LOG" apt-get -o Acquire::PDiffs=false update \
	|| die "apt-get update failed — see $APT_LOG"
ensure_update_initramfs "before full-upgrade"
step "4/7 full-upgrade image to current forky (kernel floats to the archive's)"
run_apt_tolerating_initramfs "apt-get full-upgrade" apt-get full-upgrade -y \
	--no-install-recommends \
	-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
chroot_run apt-get clean || true
info "root fs after full-upgrade: $(df -h --output=used,avail "$MNT" | tail -1)"
# After lists are fresh: dpkg --unpack initramfs-tools if the binary is gone.
ensure_update_initramfs "after apt-get update"
# 2026-10-17 boot fix: install the kernel and headers metapackages together.
# Debian testing drops old kernel ABIs fast (the chroot's 7.2.8 headers are
# gone from the archive), and linux-headers-arm64 alone then fights the
# installed linux-image-arm64/linux-base-arm64 (2026-10-17 apt failure), or
# silently upgrades the kernel while extlinux still boots the old one with no
# headers/DKMS. So: take whatever kernel the archive has now and boot that.
INSTALL_PKGS=(linux-image-arm64 linux-headers-arm64)
for p in "${ADD_PKGS[@]}"; do
	[[ $p == linux-headers-arm64 ]] && continue
	INSTALL_PKGS+=("$p")
done
info "kernel/headers: linux-image-arm64 + linux-headers-arm64 (current archive kernel)"
chroot_run_log "$APT_LOG" apt-get install -y --no-install-recommends \
	-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
	"${INSTALL_PKGS[@]}"
OLD_KVER=$KVER
KVER=$(ls -1 "$MNT"/boot/vmlinuz-* | sed 's#.*/vmlinuz-##' | sort -V | tail -1)
[[ -n $KVER && -d $MNT/usr/src/linux-headers-$KVER ]] \
	|| die "no headers for newest kernel '$KVER' after install — see $APT_LOG"
if [[ $KVER != "$OLD_KVER" ]]; then
	info "kernel in image: $OLD_KVER -> $KVER (old one purged below; its initrd still has live-boot hooks)"
	# Only purge what is actually installed (the chroot never had 7.2.8 headers;
	# apt-get purge of an unknown package is a hard error).
	OLD_PKGS=()
	for p in linux-image linux-modules linux-binary linux-base linux-headers; do
		st=$(chroot_run dpkg-query -W -f='${db:Status-Status}' "$p-$OLD_KVER" 2>/dev/null || true)
		[[ $st == installed || $st == config-files ]] && OLD_PKGS+=("$p-$OLD_KVER")
	done
	if [[ ${#OLD_PKGS[@]} -gt 0 ]]; then
		run_apt_tolerating_initramfs "purge old kernel" apt-get purge -y "${OLD_PKGS[@]}"
	fi
	rm -f "$MNT/boot/initrd.img-$OLD_KVER" "$MNT/boot/vmlinuz-$OLD_KVER" \
		"$MNT/boot/config-$OLD_KVER" "$MNT/boot/System.map-$OLD_KVER"
fi
info "boot kernel: $KVER"

mkdir -p "$MNT/tmp/as-debs"
cp -a "${BES_DEBS[0]}" "$MNT/tmp/as-debs/"
DEB_BASENAME=$(basename "${BES_DEBS[0]}")
if ! chroot_run_log "$APT_LOG" apt-get install -y --no-install-recommends \
	-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
	"/tmp/as-debs/$DEB_BASENAME"; then
	warn "apt install of bes2600-dkms failed; trying dpkg -i + apt -f"
	chroot_run_log "$APT_LOG" dpkg -i "/tmp/as-debs/$DEB_BASENAME" || true
	chroot_run_log "$APT_LOG" apt-get install -y -f --no-install-recommends \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
fi
rm -rf "$MNT/tmp/as-debs"
if ! ls "$MNT/lib/modules/$KVER/updates/dkms/"bes2600.ko* >/dev/null 2>&1; then
	warn "bes2600 DKMS module not built for $KVER (Wi-Fi only; boot unaffected) — see $APT_LOG"
fi
chroot_run apt-get clean || true

# Spectral Browser arm64 (2026-10-18). Local .deb through apt so its Depends
# (WebKitGTK 4.1, bubblewrap, xdg-dbus-proxy) resolve. Here, while apt works
# and before the desktop step prunes dock pins, so its dock pin is kept.
step "4/7 Installing Spectral Browser (arm64 .deb)"
mkdir -p "$MNT/tmp/as-debs"
cp -a "${SPECTRAL_DEBS[0]}" "$MNT/tmp/as-debs/"
SPECTRAL_BASENAME=$(basename "${SPECTRAL_DEBS[0]}")
chroot_run_log "$APT_LOG" apt-get install -y --no-install-recommends \
	-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
	"/tmp/as-debs/$SPECTRAL_BASENAME" \
	|| die "apt install of $SPECTRAL_BASENAME failed — see $APT_LOG"
rm -rf "$MNT/tmp/as-debs"
[[ -x $MNT/usr/bin/spectral-browser ]] || die "spectral-browser binary missing after install"
info "$(chroot_run /usr/bin/spectral-browser --version 2>/dev/null || echo 'spectral-browser installed (--version did not run)')"
chroot_run apt-get clean || true

install -m 755 -o root -g root "$BES_FW_HELPER" "$MNT/usr/sbin/arrow-silver-bes2600-firmware"
info "bes2600-dkms + firmware helper installed (firmware blobs added in step 6 from oct19/firmware)"

step "4/7 Stripping live / Calamares / GRUB-EFI packages"
# Purge triggers initramfs-tools (live-boot-initramfs-tools postrm); the real
# binary must exist first, and live-tools must not take it with it on removal.
ensure_update_initramfs "before live purge"
disown_live_tools_update_initramfs
chroot_run apt-mark hold initramfs-tools initramfs-tools-core 2>>"$APT_LOG" || true
list_installed_strip_pkgs() {
	local p st
	TO_PURGE=()
	for p in "${STRIP_PKGS[@]}"; do
		st=$(chroot_run dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true)
		if [[ $st == installed || $st == half-configured || $st == unpacked \
			|| $st == half-installed || $st == triggers-awaited || $st == triggers-pending ]]; then
			TO_PURGE+=("$p")
		fi
	done
}
list_installed_strip_pkgs
if [[ ${#TO_PURGE[@]} -gt 0 ]]; then
	info "purging: ${TO_PURGE[*]}"
	run_apt_tolerating_initramfs "apt-get purge" apt-get purge -y "${TO_PURGE[@]}"
	# apt stops after a failed dpkg run; finish anything it did not reach.
	list_installed_strip_pkgs
	if [[ ${#TO_PURGE[@]} -gt 0 ]]; then
		info "purging remaining: ${TO_PURGE[*]}"
		run_apt_tolerating_initramfs "apt-get purge (retry)" apt-get purge -y "${TO_PURGE[@]}"
	fi
	run_apt_tolerating_initramfs "apt-get autoremove" apt-get autoremove -y --purge
else
	info "nothing to purge"
fi
chroot_run apt-mark unhold initramfs-tools initramfs-tools-core 2>>"$APT_LOG" || true
# live-tools gone: binary must still be the real one before dpkg --configure -a.
ensure_update_initramfs "after live purge/autoremove"
chroot_run_log "$APT_LOG" dpkg --configure -a || warn "dpkg --configure -a returned non-zero"
rm -rf "$MNT/var/lib/live" "$MNT/etc/live" 2>/dev/null || true
rm -f "$MNT/usr/share/applications/calamares.desktop" 2>/dev/null || true
# ARM64 base's Calamares "Install Arrow Silver" launcher: PineTab2 uses the eMMC installer only.
rm -f "$MNT/usr/share/applications/arrow-silver-install.desktop" \
	"$MNT/usr/share/applications/install-debian.desktop" \
	"$MNT/usr/local/bin/arrow-silver-install" 2>/dev/null || true
find "$MNT/etc/skel" "$MNT/home" "$MNT/root" -maxdepth 3 \( -name 'arrow-silver-install.desktop' -o -name 'calamares.desktop' -o -name 'install-debian.desktop' \) -delete 2>/dev/null || true
# live hook may linger if purge skipped it; drop so final initrd is disk-image clean.
rm -f "$MNT/usr/share/initramfs-tools/hooks/live" \
	"$MNT/usr/share/initramfs-tools/scripts/live" \
	"$MNT/usr/share/initramfs-tools/scripts/local-top/live"* 2>/dev/null || true

# ------------------------------------------ 5. boot files, overlay ---

step "5/7 Installing patched DTBs + extlinux + fstab + first-boot"
DTB_BOOT=$MNT/boot/dtbs/rockchip
DTB_USR=$MNT/usr/lib/linux-image-$KVER/rockchip
mkdir -p "$DTB_BOOT" "$DTB_BOOT/stock"
[[ -d $DTB_USR ]] || die "missing $DTB_USR in image"
# 2026-10-17: keep Debian's unpatched DTBs as a fallback boot entry, in case
# the BES2600-patched ones (built against 7.2.8) misbehave on a newer kernel.
for v in v0.1 v2.0; do
	[[ -f $DTB_USR/rk3566-pinetab2-$v.dtb ]] \
		&& install -m 644 -o root -g root "$DTB_USR/rk3566-pinetab2-$v.dtb" "$DTB_BOOT/stock/"
done
[[ -f $DTB_BOOT/stock/$DTB_NAME ]] || die "Debian kernel $KVER has no $DTB_NAME"
install -m 644 -o root -g root "$BES_DT_DIR/rk3566-pinetab2-v0.1.dtb" "$DTB_BOOT/"
install -m 644 -o root -g root "$BES_DT_DIR/rk3566-pinetab2-v2.0.dtb" "$DTB_BOOT/"
install -m 644 -o root -g root "$BES_DT_DIR/rk3566-pinetab2-v0.1.dtb" "$DTB_USR/"
install -m 644 -o root -g root "$BES_DT_DIR/rk3566-pinetab2-v2.0.dtb" "$DTB_USR/"
info "installed patched DTBs (v0.1 + v2.0) into /boot/dtbs and /usr/lib/linux-image-$KVER"

mkdir -p "$MNT/boot/extlinux"
sed -e "s/@KVER@/$KVER/g" \
	-e "s/@ROOT_UUID@/$ROOT_UUID/g" \
	-e "s/@DTB@/$DTB_NAME/g" \
	"$OVERLAY/extlinux/extlinux.conf.in" >"$MNT/boot/extlinux/extlinux.conf"
chmod 644 "$MNT/boot/extlinux/extlinux.conf"
# u-boot-menu's kernel hook would regenerate extlinux.conf from Debian
# defaults (FDT under /usr, "ro quiet", no console) on the first kernel
# upgrade. Turn that off; our own hook just moves the kernel version along.
if [[ -f $MNT/etc/default/u-boot ]]; then
	sed -i 's/^#\?U_BOOT_UPDATE=.*/U_BOOT_UPDATE="false"/' "$MNT/etc/default/u-boot"
	grep -q '^U_BOOT_UPDATE="false"' "$MNT/etc/default/u-boot" \
		|| echo 'U_BOOT_UPDATE="false"' >>"$MNT/etc/default/u-boot"
fi
install -d -m 755 "$MNT/etc/initramfs/post-update.d"
cat >"$MNT/etc/initramfs/post-update.d/zz-arrow-extlinux" <<'HOOKEOF'
#!/bin/sh
# Arrow Silver PineTab2: point /boot/extlinux/extlinux.conf at the newest
# kernel that has an initrd (u-boot-menu is disabled in /etc/default/u-boot).
conf=/boot/extlinux/extlinux.conf
[ -f "$conf" ] || exit 0
new=$(for k in /boot/vmlinuz-*; do v=${k#/boot/vmlinuz-}; [ -f "/boot/initrd.img-$v" ] && echo "$v"; done | sort -V | tail -n 1)
[ -n "$new" ] || exit 0
sed -i -E "s#(vmlinuz|initrd\.img)-[^ ]+#\1-$new#g" "$conf"
HOOKEOF
chmod 755 "$MNT/etc/initramfs/post-update.d/zz-arrow-extlinux"
info "extlinux → FDT /dtbs/rockchip/$DTB_NAME"

sed -e "s/@ROOT_UUID@/$ROOT_UUID/g" \
	-e "s/@BOOT_UUID@/$BOOT_UUID/g" \
	"$OVERLAY/etc/fstab.in" >"$MNT/etc/fstab"
chmod 644 "$MNT/etc/fstab"

install -m 755 -o root -g root \
	"$OVERLAY/usr/local/sbin/arrow-silver-firstboot" \
	"$MNT/usr/local/sbin/arrow-silver-firstboot"
install -m 644 -o root -g root \
	"$OVERLAY/etc/systemd/system/arrow-silver-firstboot.service" \
	"$MNT/etc/systemd/system/arrow-silver-firstboot.service"
chroot_run systemctl enable arrow-silver-firstboot.service

# 2026-10-18 eMMC installer: script + menu launcher + the exact pinned U-Boot
# (and its sha256) that step 7 writes, so the installer can verify and reuse it.
install -m 755 -o root -g root "$OVERLAY/usr/local/sbin/arrow-silver-install-emmc" \
	"$MNT/usr/local/sbin/arrow-silver-install-emmc"
install -D -m 755 -o root -g root "$OVERLAY/usr/local/bin/arrow-silver-install-emmc-launch" \
	"$MNT/usr/local/bin/arrow-silver-install-emmc-launch"
install -D -m 644 -o root -g root "$OVERLAY/usr/share/applications/arrow-silver-install-emmc.desktop" \
	"$MNT/usr/share/applications/arrow-silver-install-emmc.desktop"
install -D -m 644 -o root -g root "$UBOOT_BIN" "$MNT/usr/lib/arrow-silver/u-boot-rockchip.bin"
( cd "$MNT/usr/lib/arrow-silver" && sha256sum u-boot-rockchip.bin >u-boot-rockchip.bin.sha256 )
cmp -s "$UBOOT_BIN" "$MNT/usr/lib/arrow-silver/u-boot-rockchip.bin" || die "bundled U-Boot differs from $UBOOT_BIN"
info "eMMC installer + bundled U-Boot ($(cut -c1-16 "$MNT/usr/lib/arrow-silver/u-boot-rockchip.bin.sha256")…) installed"
# 2026-10-22: Flathub remote for GNOME Software (flatpak reads remotes.d on first use)
[[ -f $OVERLAY/etc/flatpak/remotes.d/flathub.flatpakrepo ]] || die "Missing overlay etc/flatpak/remotes.d/flathub.flatpakrepo"
install -D -m 644 -o root -g root "$OVERLAY/etc/flatpak/remotes.d/flathub.flatpakrepo" \
	"$MNT/etc/flatpak/remotes.d/flathub.flatpakrepo"
info "Flathub remote preconfigured (/etc/flatpak/remotes.d/flathub.flatpakrepo)"
# 2026-10-22: BES2600 drops when it idles; keep Wi-Fi power saving off
[[ -f $OVERLAY/etc/NetworkManager/conf.d/wifi-powersave-off.conf ]] || die "Missing overlay etc/NetworkManager/conf.d/wifi-powersave-off.conf"
install -D -m 644 -o root -g root "$OVERLAY/etc/NetworkManager/conf.d/wifi-powersave-off.conf" \
	"$MNT/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
info "NetworkManager Wi-Fi power saving off (/etc/NetworkManager/conf.d/wifi-powersave-off.conf)"

echo 'arrow-silver' >"$MNT/etc/hostname"
if [[ -f $MNT/etc/hosts ]] && ! grep -q 'arrow-silver' "$MNT/etc/hosts"; then
	echo '127.0.1.1	arrow-silver' >>"$MNT/etc/hosts"
fi

# ----------------------------------------------- 6. rebuild initrd ---

step "6/7 Rebuilding initrd (drop live-boot hooks)"
# Still deferred (update_initramfs=no): fix binary / half-configured packages first.
ensure_update_initramfs "before final initrd rebuild"
chroot_run_log "$APT_LOG" dpkg --configure -a || warn "dpkg --configure -a returned non-zero"
# Re-enable update-initramfs now that packages have settled.
if [[ -f $INITRAMFS_UCONF.arrow-bak ]]; then
	mv -f "$INITRAMFS_UCONF.arrow-bak" "$INITRAMFS_UCONF"
else
	cat >"$INITRAMFS_UCONF" <<'UIEOF'
update_initramfs=yes
backup_initramfs=no
UIEOF
fi
mkdir -p "$MNT/var/tmp"
chmod 1777 "$MNT/var/tmp"
ensure_boot_kernel_files
# Absolute path: env(1) must not PATH-search a missing update-initramfs (exit 127).
# TMPDIR=/var/tmp matches mkinitramfs default; directory created above.
# -u refuses to run when no initrd exists yet (new kernel installed while
# update_initramfs=no), so create in that case.
UIT_MODE=-u
[[ -f $MNT/boot/initrd.img-$KVER ]] || UIT_MODE=-c
chroot_run_log "$INITRD_LOG" env TMPDIR=/var/tmp /usr/sbin/update-initramfs "$UIT_MODE" -k "$KVER" \
	|| die "update-initramfs failed — see $INITRD_LOG"
[[ -f $MNT/boot/initrd.img-$KVER ]] || die "initrd missing after rebuild"
if command -v lsinitramfs >/dev/null && lsinitramfs "$MNT/boot/initrd.img-$KVER" | grep -q 'scripts/live'; then
	die "initrd still contains live-boot scripts"
fi
grep -q "vmlinuz-$KVER" "$MNT/boot/extlinux/extlinux.conf" || die "extlinux.conf does not boot $KVER"
[[ -f $MNT/boot/vmlinuz-$KVER ]] || die "vmlinuz missing on boot partition"
info "initrd rebuilt for $KVER (log: $INITRD_LOG)"

INC=$LIVE_ARM/config/includes.chroot
if [[ -d $INC ]]; then
	rsync -rl --checksum --chown=root:root --itemize-changes \
		"$INC/" "$MNT/" >"$WORK/rsync-inc.log" || true
	info "re-applied includes.chroot ($(grep -cE '^[>c]' "$WORK/rsync-inc.log" 2>/dev/null || echo 0) changes)"
fi

# Desktop look (2026-10-17), same as Daily ARM64. Must come after the
# includes.chroot re-apply above: that tree still ships xfwm4.xml with
# compositing off (in /etc/xdg and /etc/skel).
step "6/7 Desktop look: Docklike dock, compositing, Spectral VM fix, wallpapers"
rsync -rl --checksum --chown=root:root --chmod=D755,F644 --exclude=/README.md \
	"$DESKTOP_OVL/" "$MNT/"
# 2026-10-23: Yakuake is purged in step 4, but the includes.chroot re-apply
# above puts back its autostart, XFCE helper and wrapper. Remove them and make
# xfce4-terminal the preferred terminal (Ctrl+Alt+T, dock, "Open Terminal").
rm -f "$MNT/etc/xdg/autostart/org.kde.yakuake.desktop" \
	"$MNT/usr/share/xfce4/helpers/yakuake.desktop" \
	"$MNT/usr/local/bin/arrow-silver-terminal" 2>/dev/null || true
find "$MNT/etc/skel" "$MNT/home" "$MNT/root" -maxdepth 4 \( -name 'org.kde.yakuake.desktop' -o -name 'yakuakerc' \) -delete 2>/dev/null || true
for hrc in "$MNT/etc/xdg/xfce4/helpers.rc" "$MNT/etc/skel/.config/xfce4/helpers.rc"; do
	if [[ -f $hrc ]]; then sed -i 's/^TerminalEmulator=.*/TerminalEmulator=xfce4-terminal/' "$hrc"; fi
done
if [[ -x $MNT/usr/bin/yakuake ]]; then die "yakuake still installed"; fi
[[ -x $MNT/usr/bin/xfce4-terminal ]] || die "xfce4-terminal missing (Yakuake replacement)"
# xfconf only reads xfce4-desktop.xml; older bases shipped it as xfce-desktop.xml.
while IFS= read -r -d '' badxml; do
	goodxml=${badxml%/xfce-desktop.xml}/xfce4-desktop.xml
	if [[ -e $goodxml ]]; then rm -f "$badxml"; else mv "$badxml" "$goodxml"; fi
done < <(find "$MNT/etc/xdg" "$MNT/etc/skel" "$MNT/home" "$MNT/root" -path '*/xfce-perchannel-xml/xfce-desktop.xml' -print0 2>/dev/null)
XFWM_REL=.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
install -d -m 755 -o root -g root "$MNT/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
install -m 644 -o root -g root "$DESKTOP_OVL/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" \
	"$MNT/etc/skel/$XFWM_REL"
# Drop dock pins whose app is not in this image (the PineTab2 image is built
# from the core live-arm64 chroot, which has no Thunderbird/LibreOffice/Rhythmbox).
for rc in "$MNT/etc/xdg/xfce4/panel/docklike-11.rc" "$MNT/etc/skel/.config/xfce4/panel/docklike-11.rc"; do
	pins=$(sed -n 's/^pinned=//p' "$rc")
	keep=
	IFS=';' read -ra arr <<<"$pins"
	for d in "${arr[@]}"; do
		[[ -n $d ]] || continue
		if [[ -f $MNT$d ]]; then keep+="$d;"; else info "dock: no $(basename "$d") in image, unpinned"; fi
	done
	sed -i "s|^pinned=.*|pinned=$keep|" "$rc"
done
info "dock pins: $(sed -n 's/^pinned=//p' "$MNT/etc/skel/.config/xfce4/panel/docklike-11.rc" | tr ';' ' ' | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
# ArrowSilver's home was made from skel back in step 3, before these files existed.
# 2026-10-19: volume keys (no pulseaudio panel plugin) -> pactl custom shortcuts.
KBD_REL=.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml
KBD_SRC=$DESKTOP_OVL/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml
[[ -f $KBD_SRC ]] || die "missing $KBD_SRC"
install -m 644 -o root -g root "$KBD_SRC" "$MNT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"
install -m 644 -o root -g root "$KBD_SRC" "$MNT/etc/skel/$KBD_REL"
grep -q 'XF86AudioRaiseVolume' "$MNT/etc/skel/$KBD_REL" || die "volume-key shortcuts not installed"
AS_HOME=$MNT/home/ArrowSilver
if [[ -d $AS_HOME ]]; then
	AS_UG=$(chroot_run id -u ArrowSilver):$(chroot_run id -g ArrowSilver)
	for rel in "$XFWM_REL" .config/xfce4/panel/docklike-11.rc "$KBD_REL"; do
		install -D -m 644 "$MNT/etc/skel/$rel" "$AS_HOME/$rel"
	done
	chown -R "$AS_UG" "$AS_HOME/.config"
fi
grep -q 'name="use_compositing" type="bool" value="true"' "$MNT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" \
	|| die "/etc/xdg xfwm4.xml does not turn compositing on"
for f in /usr/lib/aarch64-linux-gnu/xfce4/panel/plugins/libdocklike.so /usr/bin/mousepad \
	/usr/share/backgrounds/arrow-silver.png \
	/usr/bin/spectral-browser /usr/lib/spectral-browser/libspectral-ext.so \
	/usr/share/applications/spectral-browser.desktop; do
	[[ -e $MNT$f ]] || die "image is missing $f"
done
info "dock + compositing + Spectral VM fix + 3 optional wallpapers in place (default wallpaper unchanged)"

# Oct 19 add-ons (2026-10-18): BES2600 Wi-Fi firmware, landscape screen +
# touch rotation, xfce4-battery-plugin. After the includes/desktop re-apply
# so nothing overwrites it; chroot is still mounted for apt.
step "6/7 Oct 19 add-ons: Wi-Fi firmware, landscape rotation, battery plugin"
[[ -f $PT/oct19/pinetab2-oct19-addons.sh ]] || die "missing $PT/oct19/pinetab2-oct19-addons.sh"
( ROOT=$MNT ADDON_DIR=$PT/oct19 source "$PT/oct19/pinetab2-oct19-addons.sh" ) || die "Oct 19 add-ons failed"
for f in bes2600_factory.txt best2002_fw_boot_sdio.bin best2002_fw_sdio.bin; do
	[[ -f $MNT/lib/firmware/bes2600/$f ]] || die "image is missing /lib/firmware/bes2600/$f"
done
grep -q 'mem_sleep_default=s2idle' "$MNT/boot/extlinux/extlinux.conf" \
	|| die "extlinux.conf lacks mem_sleep_default=s2idle (deep suspend crashes panfrost on resume)"

# 2026-10-19: last package-touching step is done -> fix man cache ownership
# (root-owned files made mandb print 'Permission denied' on every apt install).
step "6/7 Final checks: man cache ownership, GStreamer codecs"
if chroot_run id man >/dev/null 2>&1; then
	chroot_run chown -R man:man /var/cache/man || warn "chown /var/cache/man failed"
	BAD_MAN=$(chroot_run find /var/cache/man ! -user man 2>/dev/null | wc -l)
	[[ $BAD_MAN -eq 0 ]] && info "/var/cache/man owned by man" || warn "$BAD_MAN files under /var/cache/man not owned by man"
else
	warn "no 'man' user in image; skipped /var/cache/man chown"
fi
if chroot_run gst-inspect-1.0 avdec_h264 >/dev/null 2>&1; then
	info "GStreamer: avdec_h264 found (YouTube codecs OK)"
else
	warn "GStreamer avdec_h264 NOT found in image: YouTube in Spectral will fail"
fi

# ----------------------------------------------- 7. finish + U-Boot ---

step "7/7 Unmounting and writing U-Boot at sector 64"
sync
cleanup_mounts
MNT=
detach_loop || die "failed to detach loop before writing U-Boot"
dd if="$UBOOT_BIN" of="$IMG_PARTIAL" bs=512 seek=64 conv=notrunc,fsync status=progress
sync
info "U-Boot written at byte offset $((64 * 512)) (32 KiB)"

rm -f "$IMG"
mv -f "$IMG_PARTIAL" "$IMG"
chmod 644 "$IMG"

step "7/7 Checksums"
(
	cd "$OUT_DIR"
	sha256sum "$IMG_BASENAME.img" >SHA256SUMS
	if [[ $COMPRESS == 1 ]]; then
		info "compressing with xz -T0 -9 (slow)…"
		xz -T0 -9 -k -f "$IMG_BASENAME.img"
		sha256sum "$IMG_BASENAME.img.xz" >>SHA256SUMS
	fi
)
IMG_BYTES=$(stat -c %s "$IMG")
IMG_SHA=$(awk '{print $1; exit}' "$OUT_DIR/SHA256SUMS")
ELAPSED=$(( $(date +%s) - T0 ))

cat >"$OUT_DIR/FLASH-$IMG_BASENAME.txt" << NOTEOF
Arrow Silver PineTab2 image — $DATE_STAMP

File: $IMG
SHA256: $IMG_SHA
Size: $IMG_BYTES bytes ($(numfmt --to=iec-i --suffix=B "$IMG_BYTES"))

Login: ArrowSilver / live

Flash to SD or eMMC (DESTROYS ALL DATA on the target):
  sudo dd if=$IMG of=/dev/mmcblkX bs=64M status=progress conv=fsync
  sync

U-Boot is already embedded at sector 64. Do NOT also flash SPI.

Boot DTB: $DTB_NAME
Early hardware (v0.1): rebuild with DTB=rk3566-pinetab2-v0.1.dtb
  or edit /boot/extlinux/extlinux.conf on the boot partition.

Wi-Fi (BES2600): driver (bes2600-dkms, power-save patch) AND firmware are
  included in /lib/firmware/bes2600/ (pine64-org/bes2600-firmware cd21914580fc).
  No manual restore needed. Wi-Fi power saving is off via
  /etc/NetworkManager/conf.d/wifi-powersave-off.conf.
  Check after boot: arrow-silver-bes2600-firmware check ; dkms status

First boot expands the root partition to fill the card.
NOTEOF
chmod 644 "$OUT_DIR/FLASH-$IMG_BASENAME.txt"

echo
echo "    Image:  $IMG"
echo "    Size:   $IMG_BYTES bytes ($(numfmt --to=iec-i --suffix=B "$IMG_BYTES"))"
echo "    SHA256: $IMG_SHA"
echo "    Notes:  $OUT_DIR/FLASH-$IMG_BASENAME.txt"
[[ $COMPRESS == 1 ]] && echo "    XZ:     $IMG.xz"
echo "    Took:   $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo
echo "    Login:  ArrowSilver / live"
echo "    Flash:  sudo dd if=$IMG of=/dev/mmcblkX bs=64M status=progress conv=fsync"
DONE=1
