# Changelog

## v2026.11.04 — PineTab2 image (2026-11-04)

- zram swap via zram-tools: zstd, 50% of RAM, priority 100 (`overlay/etc/default/zramswap`)
- power-profiles-daemon installed and enabled
- ModemManager and NetworkManager-wait-online masked (faster boot; USB cell modems won't work out of the box)
- Firefox ESR: WebRender forced on and hardware video decoding enabled (`overlay/etc/firefox-esr/arrow-silver-pinetab2.js`)
- Confirmed: bes2600 Wi-Fi powersave off (`wifi.powersave = 2`) and no SD swap partition
- XFCE compositing stays on

## v2026.10.23 — PineTab2 image (2026-10-23)

- First public PineTab2 release.
