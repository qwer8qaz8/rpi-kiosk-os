# 🖥️ rpi-kiosk-os

> **Ultra-lightweight, headless-booted Home Assistant touchscreen kiosk for Raspberry Pi OS Lite (64-bit)**.  
> Installs in minutes with zero desktop overhead using **Cage** (Wayland) and **Chromium**.

[![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%20OS%20Lite%20(64--bit)-C51A4A?logo=raspberry-pi&logoColor=white)](#)
[![Display](https://img.shields.io/badge/Compositor-Cage%20(Wayland)-4C1)](#)
[![Home Assistant](https://img.shields.io/badge/Integration-Home%20Assistant%20MQTT-41BDF5?logo=home-assistant&logoColor=white)](#)
[![Web UI](https://img.shields.io/badge/WebUI-Port%208080-blue)](#)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## ⚡ Quick Start

### 1. Interactive One-Line Setup
Boot up a fresh **Raspberry Pi OS Lite (64-bit)**, connect via SSH, and paste:

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash
```

---

### 2. Automated / Unattended Setup (With CLI Flags)
You can pass pre-filled flags directly through curl to bypass interactive prompts completely:

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash -s -- \
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

* **⚡ Ultra-Minimal Footprint:** No desktop environments, window managers, or panels (`raspberrypi-ui-mods` is not installed). Boots directly into **Cage**, an ultra-lightweight Wayland kiosk compositor that displays a single full-screen window.
* **🛡️ Secure Automatic Login:** Restricts auto-login strictly to the Pi's reserved IP address using Home Assistant's `trusted_networks` authentication provider—no hardcoded passwords needed.
* **📱 Web Management Dashboard (Port 8080):** Mobile-friendly web interface accessible at `http://<PI_IP>:8080` to change the dashboard URL, toggle screen power, rotate the display (0°, 90°, 180°, 270°), and reboot without needing SSH.
* **🏠 Native Home Assistant Integration via MQTT:** Automatically registers your Pi in Home Assistant via MQTT Discovery:
  * `switch.kiosk_screen` – Turn screen backlight/power ON or OFF.
  * `button.kiosk_reload` – Instantly reload Chromium / Lovelace view.
  * `button.kiosk_reboot` – Reboot the Pi from Home Assistant.
  * `sensor.kiosk_url` – Reports the active dashboard URL.
  * `sensor.kiosk_temperature` & `sensor.kiosk_ip` – Hardware telemetry.
* **💾 SD Card Protection:** Chromium caching is directed to a RAM disk (`/tmp/chromium-cache`), preventing wear on your MicroSD card.
* **🔄 Touchscreen & HDMI Support:** Works out-of-the-box with the Official Raspberry Pi Touchscreen (DSI), Waveshare DSI screens, and standard HDMI monitors.

---

## 📂 Repository Structure

```
rpi-kiosk-os/
├── install.sh                  # Interactive & automated setup script
├── uninstall.sh                # Clean uninstaller
├── README.md                   # Full step-by-step instructions
├── kiosk-setup.json.example    # Unattended setup configuration template
├── kiosk/
│   ├── config.json             # Runtime configuration
│   ├── launch-kiosk.sh         # Script invoked by Cage systemd service
│   ├── screen-control.sh       # Hardware power & orientation helper
│   ├── kiosk-mqtt.py           # MQTT discovery & command daemon
│   └── webui/
│       ├── app.py              # Flask settings server (Port 8080)
│       └── templates/
│           └── index.html      # Mobile-friendly web UI
└── systemd/
    ├── kiosk-display.service   # Systemd unit running Cage on TTY1
    ├── kiosk-mqtt.service      # MQTT daemon service
    └── kiosk-webui.service     # Web management UI service
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

Run the installer (choose either interactive or flag-based):

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash
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

Regular users will continue to see the full UI on other devices, while the kiosk touchscreen displays a clean, edge-to-edge dashboard!

---

## 📱 Local Web Management Dashboard (Port 8080)

Access the management panel at any time from your phone, tablet, or PC:

```
http://<PI_IP>:8080
```

### Features available via Web UI:
* 💡 **Toggle Screen Power:** Instantly turn display backlight ON or OFF.
* 🔄 **Reload Kiosk:** Restarts the browser and refreshes the Lovelace view.
* 🔌 **Reboot Pi:** Clean system reboot without needing SSH.
* 🖥️ **Change Dashboard URL:** Update start URL and Lovelace path on the fly.
* 📐 **Screen Rotation:** Rotate between Landscape (0°), Portrait (90°), Inverted (180°), or Inverted Portrait (270°).
* 🏠 **MQTT Settings:** Update broker IP, port, and credentials.

---

## 🏠 Home Assistant Native MQTT Integration

When enabled, `kiosk-mqtt.service` automatically registers the kiosk in Home Assistant via MQTT Discovery:

| Entity ID | Type | Description |
| :--- | :--- | :--- |
| `switch.rpi_kiosk_screen` | Switch | Turns screen backlight ON / OFF |
| `button.rpi_kiosk_reload` | Button | Reloads the kiosk Chromium view |
| `button.rpi_kiosk_reboot` | Button | Reboots the Raspberry Pi |
| `sensor.rpi_kiosk_url` | Sensor | Reports the active dashboard URL |
| `sensor.rpi_kiosk_temperature` | Sensor | CPU temperature in °C |
| `sensor.rpi_kiosk_ip` | Sensor | Current local IP address |

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
