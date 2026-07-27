# Satellite-1-Raspberry-Controller

Python library and full-system installer for the
[FutureProofHomes Satellite1 HAT](https://futureproofhomes.net/) on a
**Raspberry Pi Zero 2W** running **Raspberry Pi OS Bookworm 64-bit**.

This is a fork of [corus87/Satellite-1-Raspberry-Controller](https://github.com/corus87/Satellite-1-Raspberry-Controller)
with targeted fixes and a complete system installer.

---

## What's different from corus87

| Area | Change |
|---|---|
| `SpeakerController` | No longer resets the TAS2780 on construction. `satellite1-init.service` owns hardware init (power mode, TDM, amp level). Calling `setup()`/`activate()` in the constructor was wiping the chip's configuration after every boot. |
| `_TAS2780` power mode | Default changed from hardcoded `0` (5V) to `'auto'`. Auto mode reads the USB-C PD contract voltage from sysfs and selects mode `2` (9V+) when available, falling back to mode `0` (5V). |
| System installer | New `install.sh` configures the full hardware stack from a clean Bookworm image. |

---

## One-liner system install

Covers everything: custom FUSB302 kernel, device tree overlays, DAC init service,
I2S audio, ALSA multi-app config, AHT20 sensor, boot hardening, and this Python library.

```bash
curl -sSL https://raw.githubusercontent.com/jcoe2412/Satellite-1-Raspberry-Controller/main/install.sh \
  | sudo bash
```

Or download and inspect first (recommended):

```bash
wget https://raw.githubusercontent.com/jcoe2412/Satellite-1-Raspberry-Controller/main/install.sh
# review install.sh ...
sudo bash install.sh
```

Reboot after the script completes.

---

## USB-C Power Delivery (9V)

By default the installer runs the system at stable **5V**. To negotiate 9V via USB-C
PD (louder audio through the TAS2780 amp), use `toggle-pd.sh` after the main install:

```bash
# Enable 9V PD
curl -sSL https://raw.githubusercontent.com/jcoe2412/Satellite-1-Raspberry-Controller/main/toggle-pd.sh | sudo bash -s enable
sudo reboot

# Disable (back to 5V)
curl -sSL https://raw.githubusercontent.com/jcoe2412/Satellite-1-Raspberry-Controller/main/toggle-pd.sh | sudo bash -s disable
sudo reboot

# Check current state (no root required)
bash <(curl -sSL https://raw.githubusercontent.com/jcoe2412/Satellite-1-Raspberry-Controller/main/toggle-pd.sh) status
```

Or if you already have the file locally:

```bash
sudo bash toggle-pd.sh enable    # 9V
sudo bash toggle-pd.sh disable   # 5V
bash toggle-pd.sh status         # show current state, no reboot needed
```

`toggle-pd.sh` makes two targeted edits: (un)comments `dtoverlay=fusb302b` in
`/boot/firmware/config.txt`, and adds/removes `ExecStartPre=wait-for-pd.sh` in
the `satellite1-init.service` override. It is idempotent and handles the
read-only `/boot/firmware` mount automatically.

> **Warning:** Only enable PD with a charger that does **not** drop VBUS to 0V
> during the 5V→9V transition (GaN chargers, or the FPH-supplied charger).
> A hard VBUS dropout reboots the Pi; the FUSB302 (VBUS-powered) survives and may
> hold I2C SDA low, causing a kernel deadlock on the next boot. Unplug the USB-C
> cable for 5 seconds and replug to recover. If this happens, run
> `sudo bash toggle-pd.sh disable` and reboot to restore stable 5V operation.

Recommendation: start with the default 5V install, confirm everything works, then
enable PD once you have a compatible charger.

---

## What the installer does

| Step | Description |
|---|---|
| 0 | Sanity checks. Auto-downloads the three `.deb` packages from GitHub Releases if not present locally. |
| 1 | Fixes any broken apt state |
| 2 | Installs system packages (`i2c-tools`, `git`, `python3-dev`, `device-tree-compiler`, `alsa-utils`) |
| 3 | Installs the custom FUSB302 kernel `.deb` |
| 4 | Copies kernel + initrd into `/boot/firmware/` |
| 5 | Installs `satellite1-rpi-setup` `.deb` (DTBs + overlays) |
| 6 | Installs `satellite1-rpi-sdk` `.deb` (sat1 CLI + DAC init service) |
| 7 | Fixes `satellite1-init.service`: speaker mode, optional PD wait, I2C ordering, timeout cap, `audio_out.py` None-guard for missing FUSB302 |
| 8 | Compiles + installs the `genericstereoaudiocodec` I2S overlay |
| 9 | Writes `~/.asoundrc` (software volume, multi-app ALSA config with dmix/dsnoop) |
| 10 | Writes `/boot/firmware/config.txt` (conditionally adds `dtoverlay=fusb302b`) |
| 11 | Configures kernel module autoload (`i2c-dev`) |
| 12 | Sets journald to volatile storage (prevents journal corruption after power cuts) |
| 13 | Installs this Python library into `~/sat1_venv/` and symlinks `sat1-control` to `/usr/local/bin/` |
| 14 | Marks `/boot/firmware` read-only in fstab (prevents FAT32 corruption on power cuts) |
| 15 | Prints a verification checklist |

The script is **idempotent** — safe to re-run after a partial failure.

---

## Required .deb packages

Three packages are downloaded automatically from [GitHub Releases](https://github.com/jcoe2412/Satellite-1-Raspberry-Controller/releases/latest)
if not present in the current directory:

| File | Size | Description |
|---|---|---|
| `linux-image-6.12.58-v8-fusb302-v8_1fusb302_arm64.deb` | 31 MB | Custom kernel with FUSB302B + TCPM support |
| `satellite1-rpi-setup_1.0-1_arm64.deb` | 2.6 MB | Device tree blobs + overlays |
| `satellite1-rpi-sdk_0.1.4-1_arm64.deb` | 4.2 KB | sat1 CLI, DAC init service |

---

## Prerequisites

- Raspberry Pi Zero 2W
- Raspberry Pi OS **Bookworm 64-bit** (clean image recommended)
- FutureProofHomes Satellite1 HAT
- USB-C power supply (see ENABLE_PD note above)
- Internet access on the Pi (for downloading packages, unless you pre-copy the `.deb` files)

---

## Python library — usage

Install the library only (without the full system installer):

```bash
python3 -m venv sat1_venv
sat1_venv/bin/pip install git+https://github.com/jcoe2412/Satellite-1-Raspberry-Controller
```

### LED controller

```python
from sat1_control import LedController
from time import sleep

led = LedController()
led.set_animation("listen")
sleep(5)
led.set_animation("idle")
```

### Speaker controller

```python
from sat1_control import SpeakerController

spk = SpeakerController()
spk.set_volume(0.7)
spk.increase_volume()
spk.mute_on()
spk.mute_off()
print(spk.volume)
spk.disable()
```

> Note: `SpeakerController` does **not** reset or reinitialize the TAS2780.
> Hardware init is owned by `satellite1-init.service` at boot. Volume and mute
> are the only runtime controls managed here.

### Buttons (Flic)

```python
from sat1_control import Buttons

def on_single(btn):
    print(f"Single click: {btn}")

def on_double(btn):
    print(f"Double click: {btn}")

def on_hold(btn):
    print(f"Hold: {btn}")

buttons = Buttons(on_single=on_single, on_double=on_double, on_hold=on_hold)
buttons.start()
```

---

## Post-install verification

After rebooting:

```bash
# Kernel version
uname -r
# → 6.12.58-v8-fusb302-v8

# Services
systemctl status satellite1-init
systemctl status aht20-boot

# Audio devices
aplay -l && arecord -l
# → GenericStereoAudioCodec listed

# Speaker test
speaker-test -c 2 -t sine -f 440 -D hw:GenericStereoAu,0

# Python library
sat1-control speaker --get-volume

# LED test
sat1-control led --animation listen --timeout 5

# AHT20 temperature/humidity sensor
cat /sys/class/hwmon/hwmon*/name
cat /sys/class/hwmon/hwmon*/temp1_input    # divide by 1000 for °C
cat /sys/class/hwmon/hwmon*/humidity1_input
```

---

## Modifying /boot/firmware after install

After install, `/boot/firmware` is mounted read-only (FAT32 corruption protection).
`toggle-pd.sh` handles the remount automatically. For any other manual changes:

```bash
sudo mount -o remount,rw /boot/firmware
# ... make changes ...
sudo mount -o remount,ro /boot/firmware
```

---

## Credits

Original library by [corus87](https://github.com/corus87/Satellite-1-Raspberry-Controller).
Hardware by [FutureProofHomes](https://futureproofhomes.net/).
