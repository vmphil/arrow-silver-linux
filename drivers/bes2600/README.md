# bes2600-dkms (Arrow Silver / PineTab2)

Out-of-tree **BES2600** SDIO Wi-Fi driver as a DKMS package for Arrow Silver’s
PineTab2 image. Builds against Debian forky **linux-headers-7.2.8+deb14-arm64**.

## Pin

See `PINNED`. Driver source is taken from DanctNIX `linux-pinetab2`
**v7.1.8-danctnix1** (`344dbbd1d2e2b540197575e1c00a2b15abb1ab8b`), path
`drivers/staging/bes2600`, license **GPL-2.0-only**.

Mobian’s `bes2600-dkms` on salsa vendors an older tree without documenting a
git hash; packaging layout (dh-dkms, AUTOINSTALL) follows that project, but the
code pin is DanctNIX’s known-good tablet tree.

## Patch

`patches/0001-drop-txrx_opt-for-out-of-tree-dkms.patch` — omit `txrx_opt.c` /
`txrx_opt.h` and strip call sites so the module builds standalone. Confirmed
cross-compile: `bes2600.ko`, vermagic `7.2.8+deb14-arm64 SMP preempt mod_unload aarch64`.

## Firmware (you supply)

This package **never** downloads or bundles firmware blobs.

```bash
sudo arrow-silver-bes2600-firmware list
sudo arrow-silver-bes2600-firmware install-from /path/to/firmware-dir
sudo arrow-silver-bes2600-firmware check
```

Required files under `/lib/firmware/bes2600/`:

- `best2002_fw_boot_sdio.bin`
- `best2002_fw_sdio.bin`
- `best2002_fw_sdio_nosignal.bin`
- `best2002_fw_sdio_btrf.bin`

Optional: `bes2600_factory.txt` (calibration).

## Install

```bash
sudo apt install ./bes2600-dkms_*.deb
# needs matching linux-headers on the device
sudo dkms status
sudo modprobe bes2600
```

## Device tree

Debian forky’s stock `rk3566-pinetab2-*.dtb` **does not** describe the BES2600.
The PineTab2 image must ship patched DTBs (or a DT overlay) from
`dt/0001-arm64-dts-rockchip-pinetab2-add-BES2600-WLAN-and-BT-.patch`
(WLAN + BT UART nodes from DanctNIX, rebased onto 7.2.8). Prebuilt reference
DTBs may sit alongside this package under `dt/`.

## Known issues

- Upstream unstable: crashes, slow shutdowns (Pine64 / DanctNIX).
- No working BES2600 Bluetooth driver in mainline or this package
  (`bes2600_btuart` exists in-tree but is unfinished / not AUTOINSTALL’d here).
- Not hardware-tested in this packaging pass.
