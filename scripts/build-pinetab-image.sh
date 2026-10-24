#!/usr/bin/env bash
# build-pinetab-image.sh — PineTab (Allwinner A64) image stub.
# The A64 tablet still needs the Feixin panel driver enabled (see BUILD-PINETAB.md).
# PineTab2 is the supported target today.
set -euo pipefail
echo "PineTab (A64) image build is not ready yet." >&2
echo "Debian's kernel leaves CONFIG_DRM_PANEL_FEIXIN_K101_IM2BA02 off, so the" >&2
echo "internal screen stays black. Use the PineTab2 builder instead:" >&2
echo "  sudo ~/Documents/Arrow-Silver/live-pinetab/scripts/build-pinetab2-image.sh" >&2
echo "Details: ~/Documents/Arrow-Silver/live-pinetab/BUILD-PINETAB.md" >&2
exit 1
