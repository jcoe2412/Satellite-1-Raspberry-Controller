#!/bin/bash
# check-amp-power-mode.sh — confirm the TAS2780 amp is ACTUALLY configured
# for 9V vs 5V, by reading its power-mode registers directly over I2C.
#
# Why: satellite1-init.service picks the amp's power mode once at boot,
# based on whatever /sys/.../voltage_now reads at that moment (gated by
# wait-for-pd.sh). `sat1 dac status` does not read back or report this
# setting, and `voltage_now` alone only confirms VBUS, not that the amp
# registers were actually written for it. This reads the ground truth
# off the chip.
#
# Usage:
#   sudo bash check-amp-power-mode.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash check-amp-power-mode.sh"; exit 1; }

BUS=1
ADDR=0x3f

CHNL0=$(i2cget -y "$BUS" "$ADDR" 0x03)
DCBLK0=$(i2cget -y "$BUS" "$ADDR" 0x04)

CDS=$(( (CHNL0 >> 6) & 0x3 ))
VBAT=$(( (DCBLK0 >> 7) & 0x1 ))
AMP_LEVEL=$(( (CHNL0 >> 1) & 0x1f ))

echo "CHNL_0=$CHNL0 DC_BLK0=$DCBLK0  CDS=$CDS VBAT1S=$VBAT  amp_level=$AMP_LEVEL"

if   [ "$CDS" -eq 3 ] && [ "$VBAT" -eq 1 ]; then echo "Amp IS configured for 9V (power_mode=2)"
elif [ "$CDS" -eq 2 ] && [ "$VBAT" -eq 0 ]; then echo "Amp is configured for 5V (power_mode=0)"
else echo "UNEXPECTED register state — neither known mode (CDS=$CDS VBAT1S=$VBAT)"
fi
