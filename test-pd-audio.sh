#!/bin/bash
# test-pd-audio.sh — report the actual USB-C PD state and play a fixed-level
# test tone, so you can A/B compare loudness between 5V and 9V operation.
#
# Usage:
#   bash test-pd-audio.sh [seconds]
#
# Run once at 5V and once at 9V (after toggling with toggle-pd.sh and
# rebooting) to confirm PD actually took effect and hear the difference.

set -uo pipefail

SUPPLY=/sys/class/power_supply/tcpm-source-psy-1-0022
SECS="${1:-4}"

if [[ -r "$SUPPLY/voltage_now" ]]; then
    V_UV=$(cat "$SUPPLY/voltage_now")
    V=$(awk "BEGIN{printf \"%.1f\", $V_UV/1000000}")
    if [ "$V_UV" -ge 9000000 ]; then
        MODE="9V PD (amp power_mode=2)"
    else
        MODE="5V (amp power_mode=0)"
    fi
    echo "PD contract: ${V}V  ->  ${MODE}"
else
    echo "PD supply node not found ($SUPPLY) - dtoverlay=fusb302b not loaded, running at fixed 5V"
fi

sat1-control speaker --set-volume 1.0
echo "Playing ${SECS}s test tone at max digital volume (440Hz)..."
timeout "${SECS}" speaker-test -c 2 -t sine -f 440 -D hw:GenericStereoAu,0
