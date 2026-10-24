# Arrow Silver Linux for PineTab2

A lightweight Debian forky (ARM64) + XFCE 4.20 distro for the PINE64 PineTab2, with reliable landscape orientation and touchscreen from boot console to desktop.

This repo holds the project website (`index.html`, served via GitHub Pages). Download the PineTab2 image from the [v2026.10.23 GitHub Release](https://github.com/vmphil/arrow-silver-linux/releases/tag/v2026.10.23):

| File | Size | SHA-256 |
|---|---|---|
| [`arrow-silver-pinetab2-2026-10-23.img.xz`](https://github.com/vmphil/arrow-silver-linux/releases/download/v2026.10.23/arrow-silver-pinetab2-2026-10-23.img.xz) | 1,676,594,476 bytes | `fbdcc4bf4726fdb3742d9a516db2281e4bc365f7e2504f7a865357eb02539cfd` |

Checksum: [`arrow-silver-pinetab2-2026-10-23.img.xz.sha256`](https://github.com/vmphil/arrow-silver-linux/releases/download/v2026.10.23/arrow-silver-pinetab2-2026-10-23.img.xz.sha256)

```bash
xz -dc arrow-silver-pinetab2-2026-10-23.img.xz | sudo dd of=/dev/mmcblkX bs=64M status=progress conv=fsync
```

Default login: `ArrowSilver` / `live`. Credits: Debian, PINE64, inindev/uboot-rockchip, pine64-org/bes2600-firmware, the bes2600 driver project.
