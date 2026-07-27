#!/bin/bash
# toggle-pd.sh — enable or disable USB-C Power Delivery on the Satellite1 HAT
#
# Usage:
#   sudo bash toggle-pd.sh enable   # negotiate 9V via FUSB302B
#   sudo bash toggle-pd.sh disable  # back to stable 5V
#   sudo bash toggle-pd.sh status   # show current state (no root required)
#
# One-liner (enable):
#   curl -sSL https://raw.githubusercontent.com/jcoe2412/Satellite-1-Raspberry-Controller/main/toggle-pd.sh | sudo bash -s enable
#
# What this changes:
#   1. config.txt  — (un)comments dtoverlay=fusb302b
#   2. speaker.conf — adds/removes ExecStartPre=wait-for-pd.sh
#   3. systemctl daemon-reload
#
# A reboot is required for the change to take effect.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

ACTION="${1:-}"
[[ "$ACTION" == "enable" || "$ACTION" == "disable" || "$ACTION" == "status" ]] || {
    echo "Usage: sudo bash toggle-pd.sh enable|disable|status"
    exit 1
}

FIRMWARE_DIR="/boot/firmware"
CONFIG_TXT="$FIRMWARE_DIR/config.txt"
PD_WAIT_SCRIPT="/usr/local/bin/wait-for-pd.sh"
OVERRIDE_FILE="/etc/systemd/system/satellite1-init.service.d/speaker.conf"

# ── status ────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
    if grep -q "^dtoverlay=fusb302b" "$CONFIG_TXT" 2>/dev/null; then
        echo -e "${GREEN}PD: ENABLED${NC}  (dtoverlay=fusb302b active in config.txt)"
    elif grep -q "^#dtoverlay=fusb302b" "$CONFIG_TXT" 2>/dev/null; then
        echo -e "${YELLOW}PD: DISABLED${NC} (#dtoverlay=fusb302b commented out in config.txt)"
    else
        echo -e "${RED}PD: UNKNOWN${NC}  (fusb302b line not found in config.txt)"
    fi
    if grep -q "ExecStartPre=$PD_WAIT_SCRIPT" "$OVERRIDE_FILE" 2>/dev/null; then
        echo    "wait-for-pd: active in speaker.conf"
    else
        echo    "wait-for-pd: not in speaker.conf"
    fi
    exit 0
fi

[[ $EUID -ne 0 ]] && error "Run as root:  sudo bash toggle-pd.sh $ACTION"

# ── remount config.txt rw ─────────────────────────────────────────────────────
REMOUNT_RO_AFTER=0
if ! touch "$FIRMWARE_DIR/.write_test" 2>/dev/null; then
    info "/boot/firmware is read-only — remounting rw ..."
    mount -o remount,rw "$FIRMWARE_DIR"
    REMOUNT_RO_AFTER=1
else
    rm -f "$FIRMWARE_DIR/.write_test"
fi

# ── 1. config.txt ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == "enable" ]]; then
    # idempotent: strips any leading # before the line
    sed -i 's/^#*dtoverlay=fusb302b/dtoverlay=fusb302b/' "$CONFIG_TXT"
    if grep -q "^dtoverlay=fusb302b" "$CONFIG_TXT"; then
        success "config.txt: dtoverlay=fusb302b enabled"
    else
        error "config.txt: fusb302b line not found — was install.sh run first?"
    fi
else
    sed -i 's/^#*dtoverlay=fusb302b/#dtoverlay=fusb302b/' "$CONFIG_TXT"
    success "config.txt: dtoverlay=fusb302b disabled"
fi

# ── remount ro ────────────────────────────────────────────────────────────────
if [[ "${REMOUNT_RO_AFTER}" -eq 1 ]]; then
    mount -o remount,ro "$FIRMWARE_DIR"
    info "/boot/firmware remounted read-only"
fi

# ── 2. speaker.conf: add/remove ExecStartPre ──────────────────────────────────
if [[ ! -f "$OVERRIDE_FILE" ]]; then
    error "$OVERRIDE_FILE not found — was install.sh run first?"
fi

if [[ "$ACTION" == "enable" ]]; then
    if grep -q "ExecStartPre=$PD_WAIT_SCRIPT" "$OVERRIDE_FILE"; then
        info "speaker.conf: ExecStartPre already present — skipping"
    else
        # Insert after [Service] line
        sed -i "/^\[Service\]/a ExecStartPre=$PD_WAIT_SCRIPT" "$OVERRIDE_FILE"
        success "speaker.conf: ExecStartPre=$PD_WAIT_SCRIPT added"
    fi
else
    if grep -q "ExecStartPre=$PD_WAIT_SCRIPT" "$OVERRIDE_FILE"; then
        sed -i "/^ExecStartPre=$(echo "$PD_WAIT_SCRIPT" | sed 's/\//\\\//g')/d" "$OVERRIDE_FILE"
        success "speaker.conf: ExecStartPre removed"
    else
        info "speaker.conf: ExecStartPre not present — skipping"
    fi
fi

# ── 3. reload systemd ─────────────────────────────────────────────────────────
systemctl daemon-reload
success "systemd daemon reloaded"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$ACTION" == "enable" ]]; then
    echo -e "${GREEN}USB-C PD enabled.${NC}"
    warn "Only use with a charger that does NOT drop VBUS to 0V during PD negotiation."
    warn "If the Pi reboots in a loop after reboot: unplug USB-C, wait 5s, replug."
    warn "To recover from I2C deadlock: run  sudo bash toggle-pd.sh disable  then reboot."
else
    echo -e "${GREEN}USB-C PD disabled. System will run at stable 5V.${NC}"
fi
echo ""
echo -e "${YELLOW}Reboot to apply:  sudo reboot${NC}"
echo ""
