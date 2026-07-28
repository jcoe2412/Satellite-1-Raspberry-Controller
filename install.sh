#!/bin/bash
# =============================================================================
# install.sh — Satellite1 HAT full setup for Raspberry Pi Zero 2W
# =============================================================================
# Configures a clean Raspberry Pi OS Bookworm (64-bit) image to work with the
# FutureProofHomes Satellite1 HAT: custom kernel, device tree overlays, DAC
# init service, I2S audio, ALSA config, Python SDK, and power-cut resilience.
#
# Steps performed:
#
#   0.  Sanity checks (root, Bookworm, firmware partition, .deb files present)
#   1.  Fix any broken apt state
#   2.  Install required system packages
#   3.  Install the FUSB302 custom kernel .deb
#   4.  Copy kernel + initrd into /boot/firmware/
#   5.  Install satellite1-rpi-setup .deb  (DTBs + overlays)
#   6.  Install satellite1-rpi-sdk .deb    (sat1 CLI + DAC init service)
#   7.  Fix satellite1-init.service        (speaker mode, PD wait, i2c ordering,
#                                           timeout cap, audio_out.py None-guard)
#   8.  Compile + install genericstereoaudiocodec I2S overlay
#   9.  Write ~/.asoundrc  (software volume, multi-app ALSA config)
#  10.  Write /boot/firmware/config.txt
#  11.  Configure kernel module autoload
#  12.  Configure journald volatile storage (clean boot after power cuts)
#  13.  Install jcoe2412/Satellite-1-Raspberry-Controller Python SDK
#  14.  Mark /boot/firmware read-only in fstab
#  15.  Print verification checklist
#
# ── ENABLE_PD parameter ──────────────────────────────────────────────────────
#
# Controls whether dtoverlay=fusb302b is added to config.txt to negotiate
# 9V USB-C Power Delivery for the TAS2780 amplifier.
#
# ENABLE_PD=0 (default): no PD negotiation — system runs stably at 5V.
#   Audio output is at 5V level. Recommended for initial setup and development.
#
# ENABLE_PD=1: dtoverlay=fusb302b added to config.txt (loaded at kernel boot).
#   The FUSB302 negotiates 9V with the charger, increasing amp headroom.
#   WARNING: only use with a charger that does NOT drop VBUS to 0V during the
#   5V→9V transition (GaN chargers, or the FPH-supplied charger). A hard VBUS
#   reset will reboot the Pi; the FUSB302 (VBUS-powered) survives and may hold
#   I2C SDA low, causing a kernel deadlock on the next boot. Unplug the USB-C
#   cable to recover.
#
# Usage:
#   sudo bash install.sh                    # 5V stable (default)
#   ENABLE_PD=1 sudo bash install.sh        # 9V PD via config.txt
#
# ── Power-cut resilience ─────────────────────────────────────────────────────
#
# This script includes three protections against data corruption on power cuts:
#
#   1. Journald volatile storage: journal lives in /run (tmpfs). A corrupted
#      journal previously prevented SSH from coming up after power cuts.
#
#   2. /boot/firmware read-only: FAT32 has no journaling — power cuts during
#      writes leave config.txt/kernel/initramfs corrupt. Mounting read-only
#      means the partition is never dirty at runtime.
#
#   3. AHT20 sensor deferred: the i2c-sensor overlay is not loaded at boot
#      (I2C deadlock risk). Loaded safely at runtime by aht20-boot.service.
#
# ── .deb files ───────────────────────────────────────────────────────────────
#
# Three .deb packages are required. If not present in the current directory,
# they are downloaded automatically from the GitHub release:
#
#   linux-image-6.12.58-v8-fusb302-v8_1fusb302_arm64.deb   (custom kernel)
#   satellite1-rpi-setup_1.0-1_arm64.deb                    (DTBs + overlays)
#   satellite1-rpi-sdk_0.1.4-1_arm64.deb                    (sat1 CLI + service)
#
# The script is fully idempotent — safe to re-run after a partial failure.
#
# After install, /boot/firmware is read-only. Future updates:
#   sudo mount -o remount,rw /boot/firmware
#   # ... make changes ...
#   sudo mount -o remount,ro /boot/firmware
# =============================================================================

set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner()  {
    local msg="$*"
    local line="────────────────────────────────────────────────────"
    echo -e "\n${BOLD}${CYAN}┌${line}┐${NC}"
    printf "${BOLD}${CYAN}│  %-48s│${NC}\n" "$msg"
    echo -e "${BOLD}${CYAN}└${line}┘${NC}"
}

# =============================================================================
# STEP 0 — Sanity checks
# =============================================================================
banner "STEP 0 — Sanity checks"

[[ $EUID -ne 0 ]] && error "Run as root:  sudo bash $0"

# ── Feature flags ─────────────────────────────────────────────────────────────
ENABLE_PD="${ENABLE_PD:-0}"

# ── .deb filenames ────────────────────────────────────────────────────────────
DEFAULT_KERNEL_DEB="linux-image-6.12.58-v8-fusb302-v8_1fusb302_arm64.deb"
DEFAULT_SETUP_DEB="satellite1-rpi-setup_1.0-1_arm64.deb"
DEFAULT_SDK_DEB="satellite1-rpi-sdk_0.1.4-1_arm64.deb"

# ── Download directory ────────────────────────────────────────────────────────
# All .deb files land here — avoids littering whatever directory the user ran
# the script from (especially important when piped via curl).
WORK_DIR="/tmp/satellite1-install"
mkdir -p "$WORK_DIR"

# Positional args allow passing pre-downloaded files; otherwise use WORK_DIR.
KERNEL_DEB="${1:-$WORK_DIR/$DEFAULT_KERNEL_DEB}"
SETUP_DEB="${2:-$WORK_DIR/$DEFAULT_SETUP_DEB}"
SDK_DEB="${3:-$WORK_DIR/$DEFAULT_SDK_DEB}"

# ── Auto-download missing .deb files from GitHub release ─────────────────────
RELEASE_URL="https://github.com/jcoe2412/Satellite-1-Raspberry-Controller/releases/latest/download"

download_if_missing() {
    local dest="$1"
    local filename
    filename="$(basename "$dest")"
    if [[ ! -f "$dest" ]]; then
        info "Downloading $filename to $WORK_DIR/ ..."
        wget -q --show-progress -O "$dest" "$RELEASE_URL/$filename" \
            || error "Failed to download $filename from $RELEASE_URL/$filename"
        success "Downloaded $filename"
    else
        info "Using cached $filename from $(dirname "$dest")/"
    fi
}

download_if_missing "$KERNEL_DEB"
download_if_missing "$SETUP_DEB"
download_if_missing "$SDK_DEB"

FIRMWARE_DIR="/boot/firmware"
CONFIG_TXT="$FIRMWARE_DIR/config.txt"
[[ ! -d "$FIRMWARE_DIR" ]] && \
    error "$FIRMWARE_DIR missing — this script requires Raspberry Pi OS Bookworm"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[[ -z "$REAL_HOME" ]] && \
    error "Cannot determine home directory for user '$REAL_USER'"

KVER=$(dpkg-deb -f "$KERNEL_DEB" Package | sed 's/linux-image-//')
[[ -z "$KVER" ]] && error "Could not determine kernel version from $KERNEL_DEB"

info "Kernel .deb  : $KERNEL_DEB"
info "Setup .deb   : $SETUP_DEB"
info "SDK .deb     : $SDK_DEB"
info "Kernel ver   : $KVER"
info "Real user    : $REAL_USER  (home: $REAL_HOME)"
info "Firmware dir : $FIRMWARE_DIR"
if [[ "${ENABLE_PD}" == "1" ]]; then
    warn "USB-C PD     : ENABLED  (dtoverlay=fusb302b in config.txt — kernel boot)"
    warn "               Only use with a charger that does NOT drop VBUS during PD!"
else
    info "USB-C PD     : DISABLED (ENABLE_PD=0 — system runs at 5V, stable)"
fi
success "Sanity checks passed."

# =============================================================================
# STEP 1 — Fix broken apt state
# =============================================================================
banner "STEP 1 — Fix broken apt state"

dpkg --configure -a || warn "dpkg --configure -a reported issues — continuing"
apt-get update -qq
apt --fix-broken install -y || warn "apt --fix-broken reported issues — continuing"
success "apt state clean."

# =============================================================================
# STEP 2 — Install system packages
# =============================================================================
banner "STEP 2 — System packages"

PACKAGES=(
    i2c-tools
    git
    python3-dev
    python3-venv
    device-tree-compiler
    alsa-utils
)

apt-get install -y "${PACKAGES[@]}"
success "System packages installed: ${PACKAGES[*]}"

# =============================================================================
# STEP 3 — Install the FUSB302 kernel .deb
# =============================================================================
banner "STEP 3 — FUSB302 custom kernel"

info "Running dpkg -i $KERNEL_DEB ..."
dpkg -i "$KERNEL_DEB" || warn "dpkg exited non-zero (boot warnings expected — continuing)"

BOOT_VMLINUZ="/boot/vmlinuz-${KVER}"
BOOT_INITRD="/boot/initrd.img-${KVER}"

[[ ! -f "$BOOT_VMLINUZ" ]] && \
    error "Kernel image not found after install: $BOOT_VMLINUZ"

if [[ ! -f "$BOOT_INITRD" ]]; then
    warn "initrd not found — generating with update-initramfs ..."
    update-initramfs -c -k "$KVER" || error "Failed to generate initrd for $KVER"
fi

success "Kernel $KVER installed."

# =============================================================================
# STEP 4 — Copy kernel + initrd into /boot/firmware/
# =============================================================================
banner "STEP 4 — Copy kernel + initrd to firmware partition"

KERNEL_IMG="kernel8-fusb302.img"
INITRD_IMG="initrd.img-${KVER}"

if ! touch "$FIRMWARE_DIR/.write_test" 2>/dev/null; then
    info "/boot/firmware is read-only — remounting rw ..."
    mount -o remount,rw "$FIRMWARE_DIR"
    REMOUNT_RO_AFTER=1
else
    rm -f "$FIRMWARE_DIR/.write_test"
    REMOUNT_RO_AFTER=0
fi

cp "$BOOT_VMLINUZ" "$FIRMWARE_DIR/$KERNEL_IMG"
cp "$BOOT_INITRD"  "$FIRMWARE_DIR/$INITRD_IMG"
success "Kernel and initrd copied to $FIRMWARE_DIR."

# =============================================================================
# STEP 5 — Install satellite1-rpi-setup .deb
# =============================================================================
banner "STEP 5 — satellite1-rpi-setup (DTBs + overlays)"

apt install -y "$(realpath "$SETUP_DEB")"

for overlay in fusb302b satellite1-i2s; do
    f="$FIRMWARE_DIR/overlays/${overlay}.dtbo"
    [[ -f "$f" ]] && success "Overlay present: ${overlay}.dtbo" \
                  || warn "Expected overlay not found: $f"
done

success "satellite1-rpi-setup installed."

# =============================================================================
# STEP 6 — Install satellite1-rpi-sdk .deb
# =============================================================================
banner "STEP 6 — satellite1-rpi-sdk (sat1 CLI + DAC init service)"

apt install -y "$(realpath "$SDK_DEB")"

SAT1_BIN="/opt/satellite1/venv/bin/sat1"
[[ -f "$SAT1_BIN" ]] && success "sat1 CLI installed at $SAT1_BIN" \
                      || warn "sat1 binary not found at $SAT1_BIN"

# =============================================================================
# STEP 7 — Fix satellite1-init.service
# =============================================================================
banner "STEP 7 — Fix satellite1-init.service"

# ── 7a. Install wait-for-pd.sh ────────────────────────────────────────────────
PD_WAIT_SCRIPT="/usr/local/bin/wait-for-pd.sh"
info "Installing PD wait script at $PD_WAIT_SCRIPT ..."

cat > "$PD_WAIT_SCRIPT" <<'PD_WAIT'
#!/bin/bash
# wait-for-pd.sh — polls sysfs until USB-C PD contract > 5V is established.
# If the FUSB302 sysfs path does not exist (ENABLE_PD=0), exits immediately.

SUPPLY=/sys/class/power_supply/tcpm-source-psy-1-0022
MAX_WAIT=20
SUPPLY_WAIT=10
TAG=wait-for-pd

supply_elapsed=0
while [[ ! -d "$SUPPLY" ]] && [[ $supply_elapsed -lt $SUPPLY_WAIT ]]; do
    sleep 1
    supply_elapsed=$(( supply_elapsed + 1 ))
done
if [[ ! -d "$SUPPLY" ]]; then
    logger -t "$TAG" "PD supply not found after ${SUPPLY_WAIT}s — FUSB302 not active, skipping"
    exit 0
fi

logger -t "$TAG" "Starting PD wait (MAX_WAIT=${MAX_WAIT}s)"
start=$(date +%s)
last_log=-5
while true; do
    voltage=$(cat "$SUPPLY/voltage_now" 2>/dev/null)
    elapsed=$(( $(date +%s) - start ))
    if [ -n "$voltage" ] && [ "$voltage" -gt 5000000 ]; then
        logger -t "$TAG" "PD contract established: ${voltage}uV after ${elapsed}s"
        exit 0
    fi
    if [ $elapsed -ge $MAX_WAIT ]; then
        logger -t "$TAG" "PD timeout after ${MAX_WAIT}s — continuing"
        touch /run/pd-contract-failed
        exit 0
    fi
    if [ $(( elapsed - last_log )) -ge 5 ]; then
        logger -t "$TAG" "Polling... elapsed=${elapsed}s voltage=${voltage:-none}"
        last_log=$elapsed
    fi
    sleep 0.5
done
PD_WAIT

chmod +x "$PD_WAIT_SCRIPT"
success "wait-for-pd.sh installed."

# ── 7b. Service override (speaker mode + optional PD wait) ────────────────────
OVERRIDE_DIR="/etc/systemd/system/satellite1-init.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/speaker.conf"
mkdir -p "$OVERRIDE_DIR"

if [[ "${ENABLE_PD}" == "1" ]]; then
    PD_WAIT_LINE="ExecStartPre=$PD_WAIT_SCRIPT"
else
    PD_WAIT_LINE=""
fi

cat > "$OVERRIDE_FILE" <<OVERRIDE
[Service]
${PD_WAIT_LINE}

ExecStart=
ExecStart=/opt/satellite1/venv/bin/sat1 dac \
    --speaker-enabled \
    --no-speaker-startup-muted \
    --speaker-startup-volume 0.8 \
    setup
OVERRIDE

success "satellite1-init.service speaker override written."

# ── 7c. udev rule to tag /dev/i2c-1 for systemd ──────────────────────────────
UDEV_RULE="/etc/udev/rules.d/99-i2c-systemd.rules"
RULE_CONTENT='KERNEL=="i2c-1", TAG+="systemd"'
if [[ ! -f "$UDEV_RULE" ]] || ! grep -qF "$RULE_CONTENT" "$UDEV_RULE"; then
    echo "$RULE_CONTENT" > "$UDEV_RULE"
    success "udev rule created: $UDEV_RULE"
else
    success "udev rule already present."
fi
udevadm control --reload-rules

# ── 7d. Remove dev-i2c-1.device dependency ───────────────────────────────────
NODEP_FILE="$OVERRIDE_DIR/no-i2c-wait.conf"
if [[ ! -f "$NODEP_FILE" ]]; then
    cat > "$NODEP_FILE" <<'NODEP'
[Unit]
Wants=
After=
After=sound.target
NODEP
    success "i2c-1 dependency drop-in created."
fi

# ── 7e. TimeoutStartSec cap ───────────────────────────────────────────────────
TIMEOUT_DROP_FILE="$OVERRIDE_DIR/timeout.conf"
cat > "$TIMEOUT_DROP_FILE" <<'TIMEOUT_DROP'
[Service]
TimeoutStartSec=90s
TIMEOUT_DROP
success "satellite1-init timeout cap written."

# ── 7f. Remove any leftover fusb302b-boot.service from previous installs ──────
if systemctl is-enabled fusb302b-boot.service &>/dev/null; then
    systemctl disable fusb302b-boot.service 2>/dev/null || true
    warn "Disabled leftover fusb302b-boot.service from previous install."
fi
rm -f "/etc/systemd/system/fusb302b-boot.service"
rm -f "$OVERRIDE_DIR/after-fusb302b-boot.conf"
rm -f "$OVERRIDE_DIR/00-load-fusb302.conf"

# ── 7g. aht20-boot.service ───────────────────────────────────────────────────
AHT20_BOOT_SERVICE="/etc/systemd/system/aht20-boot.service"
cat > "$AHT20_BOOT_SERVICE" <<'AHT20_BOOT'
[Unit]
Description=Load AHT20 temperature/humidity sensor overlay (deferred, I2C-safe)
After=sysinit.target

[Service]
Type=oneshot
ExecStartPre=-/bin/rm -rf /tmp/.dtoverlays
ExecStart=/usr/bin/dtoverlay i2c-sensor aht20 addr=0x38
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
AHT20_BOOT

systemctl enable aht20-boot.service
success "aht20-boot.service created and enabled."

# ── 7h. Patch FPH audio_out.py — None-guard for pd_contract ──────────────────
# satellite1-init.service crashes with AttributeError when FUSB302 is not
# loaded (pd_contract is None). This patches the missing None check.
AUDIO_OUT=$(find /opt/satellite1/venv -name "audio_out.py" 2>/dev/null | head -1)
if [[ -n "$AUDIO_OUT" ]]; then
    if grep -q 'if pd_contract\.voltage' "$AUDIO_OUT"; then
        sed -i 's/if pd_contract\.voltage/if pd_contract and pd_contract.voltage/g' "$AUDIO_OUT"
        success "Patched $AUDIO_OUT: pd_contract None-guard added."
    else
        info "audio_out.py: None-guard already present — skipping."
    fi
else
    warn "satellite1 audio_out.py not found — SDK not yet installed."
fi

systemctl daemon-reload
systemctl enable satellite1-init.service
success "satellite1-init.service enabled."

# =============================================================================
# STEP 8 — Compile + install genericstereoaudiocodec I2S overlay
# =============================================================================
banner "STEP 8 — genericstereoaudiocodec I2S overlay"

AUDIO_DTBO="$FIRMWARE_DIR/overlays/genericstereoaudiocodec.dtbo"
DTS_SRC="/tmp/genericstereoaudiocodec.dts"

cat > "$DTS_SRC" <<'DTS'
//Device tree overlay for generic stereo audio codec
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2708";

    fragment@0 {
        target = <&sound>;
        __overlay__ {
            compatible = "simple-audio-card";
            simple-audio-card,name = "GenericStereoAudioCodec";
            status = "okay";

            capture_link: simple-audio-card,dai-link@0 {
                format = "i2s";
                bitclock-master = <&r_codec_dai>;
                frame-master    = <&r_codec_dai>;
                r_cpu_dai: cpu {
                    sound-dai = <&i2s>;
                    dai-tdm-slot-num   = <2>;
                    dai-tdm-slot-width = <32>;
                };
                r_codec_dai: codec {
                    sound-dai = <&codec_in>;
                };
            };

            playback_link: simple-audio-card,dai-link@1 {
                format = "i2s";
                bitclock-master = <&p_codec_dai>;
                frame-master    = <&p_codec_dai>;
                p_cpu_dai: cpu {
                    sound-dai = <&i2s>;
                    dai-tdm-slot-num   = <2>;
                    dai-tdm-slot-width = <32>;
                };
                p_codec_dai: codec {
                    sound-dai = <&codec_out>;
                };
            };
        };
    };

    fragment@1 {
        target-path = "/";
        __overlay__ {
            codec_out: spdif-transmitter {
                #address-cells   = <0>;
                #size-cells      = <0>;
                #sound-dai-cells = <0>;
                compatible = "linux,spdif-dit";
                status = "okay";
            };
            codec_in: spdif-receiver {
                #address-cells   = <0>;
                #size-cells      = <0>;
                #sound-dai-cells = <0>;
                compatible = "linux,spdif-dir";
                status = "okay";
            };
        };
    };

    fragment@2 {
        target = <&i2s>;
        __overlay__ {
            #sound-dai-cells = <0>;
            status = "okay";
        };
    };
};
DTS

dtc -@ -H epapr -O dtb -o "$AUDIO_DTBO" -Wno-unit_address_vs_reg "$DTS_SRC"
success "genericstereoaudiocodec.dtbo compiled and installed."

# =============================================================================
# STEP 9 — Write ~/.asoundrc
# =============================================================================
banner "STEP 9 — ALSA config (/etc/asound.conf)"

# System-wide config so every user and service (including elda) gets the correct
# audio routing without needing a per-user ~/.asoundrc.
ASOUNDRC="/etc/asound.conf"
[[ -f "$ASOUNDRC" ]] && cp "$ASOUNDRC" "${ASOUNDRC}.bak" && info "Backed up $ASOUNDRC"

cat > "$ASOUNDRC" <<'ALSA'
# /etc/asound.conf — Satellite-1 HAT / genericstereoaudiocodec

pcm.GenericStereoAu_playback {
    type hw
    card GenericStereoAu
    device 0
}

pcm.GenericStereoAu_capture {
    type hw
    card GenericStereoAu
    device 1
}

ctl.GenericStereoAu {
    type hw
    card GenericStereoAu
}

pcm.dmixer {
    type dmix
    ipc_key  1024
    ipc_perm 0666
    slave.pcm "GenericStereoAu_playback"
    slave {
        period_time 0
        period_size 1024
        buffer_size 4096
        channels    2
        rate        48000
    }
    bindings { 0 0; 1 1; }
}

pcm.dsnooper {
    type dsnoop
    ipc_key  2048
    ipc_perm 0666
    slave.pcm "GenericStereoAu_capture"
    slave {
        period_time 0
        period_size 1024
        buffer_size 4096
        channels    2
        rate        48000
    }
}

pcm.softvol_playback {
    type softvol
    slave.pcm "dmixer"
    control { name "Master"; card GenericStereoAu; }
}

pcm.softvol_capture {
    type softvol
    slave.pcm "dsnooper"
    control { name "Capture"; card GenericStereoAu; }
}

pcm.duplex {
    type asym
    playback.pcm "softvol_playback"
    capture.pcm  "softvol_capture"
}

pcm.!default {
    type plug
    slave.pcm "duplex"
}
ALSA

success "ALSA config written to $ASOUNDRC"

# =============================================================================
# STEP 10 — Write /boot/firmware/config.txt
# =============================================================================
banner "STEP 10 — /boot/firmware/config.txt"

cp "$CONFIG_TXT" "${CONFIG_TXT}.satellite1.bak"
info "Previous config.txt backed up."

if [[ "${ENABLE_PD}" == "1" ]]; then
    FUSB302_LINE="dtoverlay=fusb302b"
    FUSB302_COMMENT="# USB-C Power Delivery (9V) — ENABLE_PD=1"
else
    FUSB302_LINE="#dtoverlay=fusb302b"
    FUSB302_COMMENT="# USB-C PD disabled (ENABLE_PD=0) — re-run with ENABLE_PD=1 to enable"
fi

cat > "$CONFIG_TXT" <<CONFIG
# /boot/firmware/config.txt — generated by install.sh
# Backup: ${CONFIG_TXT}.satellite1.bak

dtparam=i2c_arm=on
dtparam=i2c_arm_baudrate=100000
dtparam=i2s=on
dtparam=spi=on
#dtparam=audio=on

camera_auto_detect=1
display_auto_detect=1
auto_initramfs=1
disable_fw_kms_setup=1
arm_64bit=1
disable_overscan=1
arm_boost=1
enable_uart=1

dtoverlay=vc4-kms-v3d
max_framebuffers=2

[cm4]
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
kernel=${KERNEL_IMG}
initramfs ${INITRD_IMG} followkernel

dtoverlay=satellite1-i2s
dtoverlay=genericstereoaudiocodec

# ── USB-C Power Delivery ──────────────────────────────────────────────────────
${FUSB302_COMMENT}
# WARNING (ENABLE_PD=1): only use with a charger that does NOT drop VBUS to 0V
# during 5V→9V PD negotiation. A hard VBUS reset reboots the Pi; the FUSB302
# (VBUS-powered) survives and may hold SDA low, causing an I2C deadlock on the
# next boot. Unplug the USB-C cable to recover.
${FUSB302_LINE}

# ── AHT20 sensor: loaded at runtime by aht20-boot.service (I2C deadlock safe)
#dtoverlay=i2c-sensor,aht20,addr=0x38
CONFIG

success "config.txt written."

# =============================================================================
# STEP 11 — Module autoload
# =============================================================================
banner "STEP 11 — Module autoload"

MODULES_FILE="/etc/modules-load.d/satellite1.conf"
cat > "$MODULES_FILE" <<'MODULES'
# Satellite1 HAT
i2c-dev
MODULES

modprobe i2c-dev 2>/dev/null && info "Loaded i2c-dev" || warn "i2c-dev will load after reboot"
success "Module autoload configured."

# =============================================================================
# STEP 12 — Journald volatile storage
# =============================================================================
banner "STEP 12 — Journald volatile storage"

JOURNALD_DROP_DIR="/etc/systemd/journald.conf.d"
JOURNALD_CONF="$JOURNALD_DROP_DIR/volatile.conf"
mkdir -p "$JOURNALD_DROP_DIR"

cat > "$JOURNALD_CONF" <<'JOURNALD'
[Journal]
Storage=volatile
JOURNALD

success "Journald volatile storage configured."

# =============================================================================
# STEP 13 — Install jcoe2412/Satellite-1-Raspberry-Controller Python SDK
# =============================================================================
banner "STEP 13 — Python SDK (sat1-control)"

VENV_DIR="/opt/sat1_venv"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install \
    git+https://github.com/jcoe2412/Satellite-1-Raspberry-Controller

# Symlink sat1-control to /usr/local/bin so it is available to all users
# and services (including eldaspeaker.service which runs as the 'elda' user).
ln -sf "$VENV_DIR/bin/sat1-control" /usr/local/bin/sat1-control
success "sat1-control symlinked to /usr/local/bin/sat1-control"

success "sat1-control installed in $VENV_DIR"

# =============================================================================
# STEP 14 — /boot/firmware read-only in fstab
# =============================================================================
banner "STEP 14 — /boot/firmware read-only"

if grep -qE '/boot/firmware.*\bro\b' /etc/fstab; then
    success "/boot/firmware already read-only in fstab."
elif grep -q '/boot/firmware' /etc/fstab; then
    sed -i '/\/boot\/firmware/ s/\bdefaults\b/ro,defaults/' /etc/fstab
    success "/boot/firmware marked read-only in fstab (takes effect after reboot)."
else
    warn "/boot/firmware not in fstab — add 'ro' manually."
fi

warn "After reboot /boot/firmware is read-only. To make changes:"
warn "  sudo mount -o remount,rw /boot/firmware && ... && sudo mount -o remount,ro /boot/firmware"

if [[ "${REMOUNT_RO_AFTER:-0}" -eq 1 ]]; then
    mount -o remount,ro "$FIRMWARE_DIR" && info "/boot/firmware remounted read-only" \
        || warn "Could not remount — will be ro after reboot"
fi

# =============================================================================
# STEP 15 — Summary and verification checklist
# =============================================================================
banner "Installation complete!"

echo ""
echo -e "${BOLD}After reboot, verify with:${NC}"
echo ""
echo "  uname -r                             # → $KVER"
echo "  systemctl status satellite1-init     # → active (exited)"
echo "  systemctl status aht20-boot          # → active (exited)"
echo "  aplay -l && arecord -l               # → GenericStereoAudioCodec listed"
echo "  speaker-test -c 2 -t sine -f 440 -D hw:GenericStereoAu,0"
echo "  sat1-control speaker --get-volume"
echo "  sat1-control led --animation listen --timeout 5"
echo ""
echo "  # AHT20 temperature/humidity (hwmon):"
echo "  cat /sys/class/hwmon/hwmon*/name"
echo "  cat /sys/class/hwmon/hwmon*/temp1_input"
echo "  cat /sys/class/hwmon/hwmon*/humidity1_input"
echo ""
if [[ "${ENABLE_PD}" == "1" ]]; then
echo "  # USB-C PD (9V):"
echo "  lsmod | grep -E 'fusb302|tcpm|typec'"
echo "  cat /sys/class/power_supply/tcpm-source-psy-*/voltage_now   # → ~9000000"
echo ""
echo -e "${YELLOW}USB-C PD enabled. If Pi reboots in a loop or hangs: unplug the USB-C${NC}"
echo -e "${YELLOW}cable, wait 5s, replug, then re-run with ENABLE_PD=0.${NC}"
else
echo -e "${GREEN}Running at 5V (ENABLE_PD=0) — stable, no VBUS dropout risk.${NC}"
echo -e "${GREEN}To enable 9V PD: ENABLE_PD=1 sudo bash install.sh${NC}"
fi
echo ""
echo -e "${YELLOW}══════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Reboot now:  sudo reboot${NC}"
echo -e "${YELLOW}══════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  /boot/firmware is READ-ONLY after reboot.${NC}"
echo -e "${YELLOW}  To update config.txt or the kernel:${NC}"
echo -e "${YELLOW}    sudo mount -o remount,rw /boot/firmware${NC}"
echo -e "${YELLOW}    # ... make changes ...${NC}"
echo -e "${YELLOW}    sudo mount -o remount,ro /boot/firmware${NC}"
echo ""
