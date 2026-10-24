# PineTab2 U-Boot (SD/eMMC)

Pinned binary from [inindev/uboot-rockchip](https://github.com/inindev/uboot-rockchip) **v2026.04**.

| File | Role |
|---|---|
| `u-boot-rockchip.bin` | Combined loader for SD/eMMC (write at sector 64) |
| `rk3566-pinetab2-v2026.04.zip` | Upstream zip (optional; script can re-fetch) |
| `PINNED` | URL, hashes, licence notes |
| `SHA256SUMS` | Hashes for the files we keep |
| `upstream-readme.txt` | Vendor flash instructions |
| `upstream-sha256sums.txt` | Vendor hashes (includes SPI binary we do not ship as default) |

**Do not flash SPI** with the Arrow Silver image builder. SPI updates can brick the tablet without the UART/bypass adapter. This image writes U-Boot only into the disk image at the Rockchip SD/eMMC offset.

Refresh / verify:

```bash
~/Documents/Arrow-Silver/live-pinetab/scripts/fetch-uboot-pinetab2.sh
```
