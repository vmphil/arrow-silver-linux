# Sources and Licensing — Arrow Silver for PineTab2 (DRAFT)

Arrow Silver for PineTab2 is an unofficial image **based on Debian forky (testing) arm64**.
It is not an official Debian release and is not affiliated with Debian or PINE64.

Image this file covers: `arrow-silver-pinetab2-2026-10-23.img`
(raw SHA256 `c134da4e1e8ddbf39b8c7804bf57d514369b423c1f51e88760e867d56f8716fb`).

## 1. Debian packages (GPL and other free licences)

- Every package comes unmodified from the Debian forky arm64 archive. Each one's licence is in `/usr/share/doc/<package>/copyright` on the image.
- Source: `apt-get source <package>=<version>`, or https://snapshot.debian.org/ for older versions.
- Exact package list: `MANIFEST-pinetab2-2026-10-23.txt` (TODO: generate and publish, see section 8).

## 2. Linux kernel — GPL-2.0

- **Stock Debian kernel, not modified:** `linux-image-7.2.11+deb14-arm64`, version `7.2.11-1`, from the forky archive (pulled by `linux-image-arm64` during the image build).
- Source: Debian source package `linux`, version `7.2.11-1` (`apt-get source linux=7.2.11-1`; snapshot.debian.org).
- Arrow Silver applies no kernel patches and uses no custom kernel config.

## 3. Device tree (PineTab2 DTBs) — GPL-2.0 OR MIT (Linux DTS licence)

- Debian's own `rk3566-pinetab2-v0.1.dtb` and `rk3566-pinetab2-v2.0.dtb` are kept unchanged in `/boot/dtbs/rockchip/stock/` as a fallback boot entry.
- The default boot DTBs are **patched**: they add the BES2600 WLAN and Bluetooth UART nodes (taken from DanctNIX linux-pinetab2) to the Linux 7.2.8 DTS.
- In this repo: `drivers/bes2600/dt/0001-arm64-dts-rockchip-pinetab2-add-BES2600-WLAN-and-BT-.patch`.
- TODO: say which kernel source tree and commit the patch applies to, and the exact `dtc`/make command used to build the `.dtb` files.

## 4. BES2600 Wi-Fi driver (bes2600-dkms) — GPL-2.0-only

- Upstream: DanctNIX linux-pinetab2, https://codeberg.org/DanctNIX/linux-pinetab2.git
  - tag `v7.1.8-danctnix1`, commit `344dbbd1d2e2b540197575e1c00a2b15abb1ab8b`
  - path `drivers/staging/bes2600`
- Packaging style is adapted from Mobian's bes2600-dkms: https://salsa.debian.org/Mobian-team/devices/bes2600-dkms.git
- Local changes, all included in this repo:
  - `drivers/bes2600/patches/0001-drop-txrx_opt-for-out-of-tree-dkms.patch` lets the driver build out of tree.
  - **"nopm" power patch (arrowsilver2, 2026-10-22):**
    - In `bes_pwr.c`, `power_down_work` keeps the chip awake (it locks instead of unlocking), and `unlock_device` is marked `__maybe_unused`.
    - In the `Makefile`, `-DBES_UNIFIED_PM` is commented out.
    - DKMS version: `0~git20260810.344dbbd.nopm`.
  - TODO: export the nopm change as a `.patch` file next to patch 0001.
- Full patched source:
  - `drivers/bes2600/source/` (with `dkms.conf`)
  - `drivers/bes2600/deb-experimental/bes2600-nopm-src.tgz`
  - The shipped `.deb` also contains the complete source in `/usr/src/`.

## 5. U-Boot bootloader — GPL-2.0+ (and Trusted Firmware-A, BSD-3-Clause)

- Prebuilt, unmodified binary from inindev/uboot-rockchip release **v2026.04**:
  - https://github.com/inindev/uboot-rockchip/releases/download/v2026.04/rk3566-pinetab2.zip
  - zip SHA256 `adfed313c652f296544952a2361c4992688809acd09b09be23cddec659792a3c`
  - `u-boot-rockchip.bin` SHA256 `91b5fb6eb7107ee574c996d227ff9072dbc7d3be3df759e1f48d90ba3b437b9a`
- Built from upstream U-Boot `v2026.04` (https://github.com/u-boot/u-boot/tree/v2026.04) and ARM Trusted Firmware `lts-v2.14.1`, using inindev's build scripts: https://github.com/inindev/uboot-rockchip
- Arrow Silver applies no U-Boot patches.
- TODO: check that inindev's v2026.04 tag has the exact build config. Rockchip DDR/TPL blobs (rkbin) may also be inside the binary under their own licence; TODO confirm.

## 6. BES2600 firmware — Apache-2.0 (redistribution permitted)

- Files in `/lib/firmware/bes2600/`:
  - `best2002_fw_boot_sdio.bin`
  - `best2002_fw_sdio.bin`
  - `best2002_fw_sdio_nosignal.bin`
  - `best2002_fw_sdio_btrf.bin`
  - `bes2600_factory.txt`
- Source: PINE64, https://gitlab.com/pine64-org/bes2600-firmware, commit `cd21914580fc`.
- Licence: Apache-2.0. The upstream LICENSE was added in 2025, and the commit message says "PINE Store told us we're allowed to redistribute it". PINE64 support also stated that BES authorised distribution under Apache 2 (see https://github.com/dreemurrs-embedded/linux-pinetab2/issues/3).
- The image ships the licence text at `/usr/share/doc/firmware-bes2600/LICENSE`.
- These are binary blobs. No firmware source code is available or needed for redistribution under Apache-2.0.
- TODO: confirm `bes2600_factory.txt` comes from the same upstream repo.

## 7. Arrow Silver's own files

This covers the build scripts (`scripts/`, `oct19/pinetab2-oct19-addons.sh`), the live-build configs, the XFCE settings, the Productivity bar, the firmware helper `arrow-silver-bes2600-firmware`, and the wallpapers.
- Scripts and configs licence: TODO — Phil to choose (suggested GPL-3.0-or-later). Add a `LICENSE` file to the repo.

### Wallpapers — CC BY 4.0 (Creative Commons Attribution 4.0 International)

The three custom Arrow Silver wallpapers are released under **CC BY 4.0**. Anyone may use, modify and redistribute them for any purpose, including commercially, as long as they credit **Philip Orona / Arrow Silver** (https://creativecommons.org/licenses/by/4.0/):

- `/usr/share/backgrounds/arrow-silver-cyber-alley.png`
- `/usr/share/backgrounds/arrow-silver-elf-ranger.png`
- `/usr/share/backgrounds/arrow-silver-neon-city.png`

In the build tree they are in `live-pinetab/overlay/desktop/usr/share/backgrounds/`, with copies in `live/` and `live-arm64/config/includes.chroot/usr/share/backgrounds/`.

The repo must include a separate `LICENSE-artwork` file stating that these files are © Philip Orona / Arrow Silver and licensed under CC BY 4.0. It should give the attribution line "Wallpaper by Philip Orona / Arrow Silver, CC BY 4.0" and link to (or include) the full CC BY 4.0 legal text.

TODO: decide the licence for the other images: `arrow-silver.png` (the default wallpaper), `arrow-silver-login.png` and `arrow-silver-loading.png`.

## 8. What the repo must include

- [ ] `scripts/build-pinetab2-image.sh`, `scripts/fetch-uboot-pinetab2.sh`, `oct19/pinetab2-oct19-addons.sh`
- [ ] The live-build config (`live-arm64/config/`) used to make the base chroot
- [ ] `drivers/bes2600/`: patched source, `dkms.conf`, `patches/`, Debian packaging, `PINNED`, and the DT patch
- [ ] The nopm change as a `.patch` (TODO)
- [ ] `u-boot/pinetab2/PINNED` and `SHA256SUMS`
- [ ] The firmware `LICENSE` and a pointer to the upstream firmware commit
- [ ] The package manifest. The base list exists at `live-arm64/live-image-arm64.packages`. The PineTab2 build then runs `full-upgrade` and kernel changes on top, so the exact image list must come from the image itself (`dpkg-query -W --admindir=<mounted root>/var/lib/dpkg`) or from the image on the tablet. TODO.
- [ ] Third-party `.deb` files bundled in the image (e.g. `packages/spectral-browser_1.3.2_arm64.deb`): TODO list their licence and source.
- [ ] A `LICENSE` file for Arrow Silver's own work
- [ ] A `LICENSE-artwork` file (CC BY 4.0, attribution: Philip Orona / Arrow Silver) for the three wallpapers

*Not legal advice. This file describes how the image is built.*
