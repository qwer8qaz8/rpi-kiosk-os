# 🖥️ rpi-kiosk-os

> **Ultra-lightweight, FullPageOS-inspired single-purpose Home Assistant Kiosk Appliance for Raspberry Pi OS Lite (64-bit)**.  
> Installs in minutes with zero desktop overhead using **labwc** (Wayland) and **Hardware-Optimized Chromium**.

[![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%20OS%20Lite%20(64--bit)-C51A4A?logo=raspberry-pi&logoColor=white)](#)
[![Display](https://img.shields.io/badge/Compositor-labwc%20(Wayland)-4C1)](#)
[![Home Assistant](https://img.shields.io/badge/Integration-Home%20Assistant%20MQTT-41BDF5?logo=home-assistant&logoColor=white)](#)
[![CLI](https://img.shields.io/badge/CLI-kioskos-blue)](#)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## ⚡ Quick Start

### 1. Interactive One-Line Setup
Boot up a fresh **Raspberry Pi OS Lite (64-bit)**, connect via SSH, and paste:

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | sudo bash
```

---

### 2. Automated / Unattended Setup (With CLI Flags)
You can pass pre-filled flags directly through curl to bypass interactive prompts completely:

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | sudo bash -s -- \
  --url "http://homeassistant.local:8123/lovelace-kiosk/0?kiosk" \
  --orientation "normal" \
  --kiosk-user-id "YOUR_HA_USER_ID" \
  --mqtt-broker "192.168.1.100" \
  --non-interactive
```

---

### 3. Environment Variable One-Liner
```bash
HA_URL="http://192.168.1.100:8123/lovelace/0?kiosk" \
HA_USER_ID="YOUR_HA_USER_ID" \
NON_INTERACTIVE=1 \
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash
```

---

### 4. Pre-Configured File Setup (`kiosk-setup.json`)
You can map out your setup using a local JSON file (see [`kiosk-setup.json.example`](kiosk-setup.json.example)):

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash -s -- \
  --config /boot/firmware/kiosk-setup.json \
  --non-interactive
```

---

## 📋 Installer Flags & Options

| Flag | Long Option | Description | Default |
| :--- | :--- | :--- | :--- |
| `-u` | `--url <URL>` | Home Assistant Dashboard / Lovelace URL | `http://homeassistant.local:8123/lovelace/0?kiosk` |
| `-o` | `--orientation <ROT>` | Rotation: `normal` (0°), `90`, `180`, `270` | `normal` |
| `-t` | `--display-type <T>` | Display type: `wayland_hdmi` or `dsi_touchscreen` | `wayland_hdmi` |
| `-k` | `--kiosk-user-id <ID>`| Home Assistant Kiosk User ID for auto-login | `""` |
| `-b` | `--mqtt-broker <HOST>`| MQTT broker IP or hostname | `""` (disabled) |
| `-p` | `--mqtt-port <PORT>`  | MQTT broker port | `1883` |
| `-m` | `--mqtt-user <USER>`  | MQTT username | `""` |
| `-w` | `--mqtt-pass <PASS>`  | MQTT password | `""` |
| `-c` | `--config <FILE>`     | Path to pre-filled setup JSON file | `""` |
| `-y` | `--non-interactive`   | Run completely unattended | Interactive prompt |
| `-h` | `--help`              | Show available installer options | |

---

## 🚀 Key Features

* **⚡ Ultra-Minimal Footprint:** No desktop environments, window managers, or panels. Boots directly into **labwc** (Wayland) running hardware-accelerated Chromium in locked fullscreen app mode.
* **🍓 Hardware-Aware Profiles & Pi-Themed Bootsplash:** Automatically analyzes physical hardware (Pi 5, 4, 3, Zero 2 W, or Generic) and applies optimal Chromium rasterization threads, JS heap bounds, and cache settings. Boots with an animated custom Raspberry Pi × Home Assistant themed vector splash screen.
* **🛡️ Secure Automatic Login:** Restricts auto-login strictly to the Pi's reserved IP address using Home Assistant's `trusted_networks` authentication provider, or injects auto-login credentials deeply into shadow DOM login forms.
* **🔒 Comprehensive Shortcut Lockdown:** All Chrome shortcuts, devtools (<kbd>F12</kbd>, <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>I</kbd>), tabs (<kbd>Ctrl</kbd>+<kbd>T</kbd>/<kbd>W</kbd>), and task managers (<kbd>Shift</kbd>+<kbd>Esc</kbd>) are intercepted and voided.
* **💾 Disaster Recovery & Backups:** Create sanitized and full `.tar.gz` backups with a single command: `kioskos backup create`.
* **🔄 Seamless GitHub Updates (No Spontaneous Reboots):** Automated daily checks sync latest code and cleanly reload the display compositor without random system reboots.
* **🏠 Native Home Assistant Integration via MQTT:** Automatically registers your Pi in Home Assistant via MQTT Discovery (screen power, brightness, telemetry, chimes).
* **💾 SD Card Protection:** Chromium caching is directed to a RAM disk (`/tmp/chromium-cache`), preventing wear on your MicroSD card.
* **🔄 Touchscreen & HDMI Support:** Works out-of-the-box with the Official Raspberry Pi Touchscreen (DSI), Waveshare DSI screens, and standard HDMI monitors.

---

## 📂 Repository Structure

```
rpi-kiosk-os/
├── install.sh                  # One-line interactive & automated setup script
├── uninstall.sh                # Clean uninstaller
├── README.md                   # Full step-by-step instructions
├── AGENT_INSTRUCTIONS.md       # AI Agent & automated provisioning guide
├── AGENTS.md                   # Multi-agent developer reference
├── kiosk-config.sh             # Configuration utility
├── kiosk/
│   ├── kioskos                 # Master appliance CLI
│   ├── hardware-profiles.py    # Hardware profiling & performance optimizer
│   ├── kiosk-native-splash.py  # Hardware-aware GTK3 Wayland splash
│   ├── backup-kiosk.sh         # Appliance backup & recovery tool
│   ├── launch-kiosk.sh         # FullPageOS-style kiosk launcher & supervisor
│   ├── screen-control.sh       # Hardware power & orientation helper
│   ├── kiosk-mqtt.py           # MQTT discovery & telemetry daemon
│   └── labwc/                  # Labwc compositor & shortcut lockdown configs
└── systemd/
    ├── kiosk-display.service   # Systemd unit running labwc on TTY1
    ├── kiosk-mqtt.service      # MQTT daemon service
    ├── kiosk-autoupdate.timer  # Daily update timer (safe non-rebooting)
    └── kiosk-autoupdate.service# Update runner
```

---

## 🛠️ Step-by-Step Setup Guide

### Step 1: Flash Raspberry Pi OS Lite (64-bit)

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
2. Target device: **Raspberry Pi 4** (or Pi 3 / 5).
3. Operating System: **Raspberry Pi OS (other)** &rarr; **Raspberry Pi OS Lite (64-bit)**.
4. Click **Edit Settings**:
   * Set hostname (e.g. `rpi-kiosk`).
   * Set username and password (e.g. `pi`).
   * Configure your Wi-Fi or Ethernet.
   * **Enable SSH**.
5. Write the image to your MicroSD card and insert it into the Pi.

---

### Step 2: Reserve the Pi's IP in Your Router (DHCP Reservation)

1. Log into your home router's admin panel (e.g. `192.168.1.1`).
2. Locate your Raspberry Pi in the DHCP client list.
3. Reserve a static IP address for its MAC address (e.g. `192.168.1.50`).

---

### Step 3: Run the Installer

SSH into your Pi:

```bash
ssh pi@192.168.1.50
```

Run the installer:

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | sudo bash
```

---

### Step 4: Configure Home Assistant Auto-Login (`trusted_networks`)

To allow the kiosk to boot straight into your dashboard without prompting for credentials:

1. In Home Assistant, go to **Settings** &rarr; **People** &rarr; **Users**.
2. Click **Add User** and create a dedicated non-admin user named `Kiosk`.
3. Open the user profile and copy their **User ID** (e.g. `a1b2c3d4e5f67890123456789abcdef0`).
4. In Home Assistant's `configuration.yaml`, add the following snippet:

```yaml
homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.50/32    # Replace with your Pi's reserved static IP
      trusted_users:
        192.168.1.50: a1b2c3d4e5f67890123456789abcdef0  # Replace with Kiosk User ID
      allow_bypass_login: true
```

*(Tip: You can also generate and copy this YAML snippet directly inside the Web UI at `http://<PI_IP>:8080`!)*

5. Restart Home Assistant. When the Pi connects from `192.168.1.50`, it bypasses the login screen directly into the Kiosk user session!

---

### Step 5: Hide Top Header & Sidebar with `kiosk-mode` (HACS)

To lock the kiosk view and hide navigation bars exclusively for the Kiosk user:

1. In Home Assistant, install the **kiosk-mode** frontend plugin via HACS:  
   [https://github.com/NemesisRE/kiosk-mode](https://github.com/NemesisRE/kiosk-mode)
2. Open your Lovelace dashboard, click the 3 dots in the top right &rarr; **Edit Dashboard** &rarr; **Raw configuration editor**.
3. Add the `kiosk_mode` block at the top:

```yaml
kiosk_mode:
  user_settings:
    - users:
        - "Kiosk" # Dedicated Kiosk username
      hide_header: true
      hide_sidebar: true
      hide_overflow: true
```

---

## 📱 Local Web Management Dashboard (Port 8080)

Access the management panel at any time from your phone, tablet, or PC:

```
http://<PI_IP>:8080
```

### Features available via Web UI:
* 💡 **Toggle Screen Power:** Instantly turn display backlight ON or OFF.
* 🔆 **Brightness Slider:** Adjust backlight brightness (1–100%) in real time.
* 🔄 **Reload Kiosk:** Restarts the browser and refreshes the Lovelace view.
* 🔌 **Reboot Pi:** Clean system reboot without needing SSH.
* 🖥️ **Change Dashboard URL:** Update start URL and Lovelace path on the fly.
* 📐 **Screen Rotation:** Rotate between Landscape (0°), Portrait (90°), Inverted (180°), or Inverted Portrait (270°).
* 🏠 **MQTT Settings:** Update broker IP, port, and credentials.
* 📋 **YAML Snippet Generator:** Live auto-generated `trusted_networks` block with one-click copy.

---

## 🏠 Home Assistant Native MQTT Integration & Custom Card

When enabled, `kiosk-mqtt.service` automatically registers the kiosk in Home Assistant via MQTT Discovery:

| Entity ID | Type | Description |
| :--- | :--- | :--- |
| `switch.rpi_kiosk_screen` | Switch | Turns screen backlight ON / OFF |
| `number.rpi_kiosk_brightness` | Number | Adjusts screen brightness (1–100%) |
| `button.rpi_kiosk_reload` | Button | Reloads the kiosk Chromium view |
| `button.rpi_kiosk_reboot` | Button | Reboots the Raspberry Pi |
| `sensor.rpi_kiosk_url` | Sensor | Reports the active dashboard URL |
| `sensor.rpi_kiosk_temperature` | Sensor | CPU temperature in °C |
| `sensor.rpi_kiosk_ip` | Sensor | Current local IP address |

### Custom Lovelace Card (`rpi-kiosk-card`)
Add [`homeassistant/kiosk-card.js`](homeassistant/kiosk-card.js) to your Home Assistant dashboard resources to get a dedicated kiosk control card:

```yaml
type: custom:rpi-kiosk-card
title: Wall Kiosk Display
switch_entity: switch.rpi_kiosk_screen
brightness_entity: number.rpi_kiosk_brightness
temperature_entity: sensor.rpi_kiosk_cpu_temperature
reload_button: button.rpi_kiosk_reload
reboot_button: button.rpi_kiosk_reboot
```

---

## ⌨️ Dedicated CLI Control: `kiosk`

After installation, manage everything on the Pi anytime by simply typing:

```bash
kiosk
```

You can also run quick direct commands:

```bash
# Update kiosk software & policies from GitHub
kiosk update

# Screen power & brightness
kiosk on
kiosk off
kiosk toggle
kiosk brightness 50

# Display orientation
kiosk rotate normal   # or 90, 180, 270

# Presets (Home Assistant, MagicMirror², Grafana, 3D Printer, DAKboard)
kiosk preset ha
kiosk preset magicmirror http://localhost:8080
kiosk preset grafana http://localhost:3000
kiosk preset 3dprinter http://localhost:7125

# Web UI Management (Port 8080)
kiosk webui disable   # Turn off web management completely
kiosk webui enable    # Turn on web management
kiosk webui status

# Kiosk Control
kiosk reload          # Reload the screen browser
kiosk reboot          # Reboot Raspberry Pi
kiosk status          # View hardware, screen & service status
```

---

## ⚙️ Service Control & Troubleshooting

```bash
# Check kiosk browser status
sudo systemctl status kiosk-display

# Check web UI server status
sudo systemctl status kiosk-webui

# Check MQTT daemon status
sudo systemctl status kiosk-mqtt

# View live display logs
journalctl -u kiosk-display -f
```

---

## 🗑️ Uninstallation

```bash
cd rpi-kiosk-os
sudo ./uninstall.sh
```

---

## 📄 License

MIT License. Free to use and customize for your home automation setup!
