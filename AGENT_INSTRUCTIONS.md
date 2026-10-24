# KioskOS - Agent & Automated Installation Guide

This document is designed for AI Coding Agents and Automated Provisioning Systems to deploy, configure, and maintain **KioskOS** on any Raspberry Pi out-of-the-box.

---

## ⚡ 1. One-Line Terminal Conversion (Clean Pi to KioskOS)

Run this single command on any fresh Raspberry Pi OS (Lite or Desktop, Debian 12 Bookworm / Debian 13 Trixie):

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash
```

### Unattended / Non-Interactive Install with Custom Dashboard
```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash -s -- \
  --url "http://homeassistant.local:8123/lovelace/0?kiosk" \
  --orientation "normal" \
  --non-interactive
```

---

## 🛠️ 2. The `kioskos` CLI Command

Once installed, the `kioskos` command is available system-wide:

| Command | Action |
|---|---|
| `kioskos status` | Displays live telemetry, active dashboard URL, screen state, and service health |
| `kioskos url <NEW_URL>` | Sets the dashboard URL and reloads the display compositor automatically |
| `kioskos update` | Launches the hardware-accelerated Native GTK3 update interface and reboots |
| `kioskos admin` | Launches macOS-style Admin Desktop Mode (Google Chrome + Native Control Center) |
| `kioskos lock` | Instantly returns to Single-App Fullscreen Kiosk Mode |
| `kioskos restart` | Restarts `kiosk-display` compositor cleanly |
| `kioskos reboot` | Reboots the Raspberry Pi system safely |
| `kioskos backup` | Exports a sanitized `.tar.gz` backup with all private credentials stripped |

---

## 🖥️ 3. Physical Kiosk Keyboard Shortcuts

| Shortcut | Description |
|---|---|
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>=</kbd> | Stealth Admin Listener Mode (invisible, no hint text). Silently type `Kiosk` &rarr; Enter Admin Password |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>R</kbd> | Instant Kiosk Compositor Restart / Reload |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>L</kbd> | Emergency Lock / Return to Kiosk Mode |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>Delete</kbd> | Instant Raspberry Pi Reboot |

---

## 🌐 4. Remote Web Management API

Available on port `8080` (e.g. `http://<pi-ip>:8080/`):
- `GET /api/status`: System status and telemetry
- `POST /api/settings`: Update dashboard URL, rotation, MQTT configuration
- `POST /api/update`: Triggers native KioskOS updater on screen and reboots
- `POST /api/screen`: Screen power control (`on`, `off`, `toggle`)
- `POST /api/brightness`: Set backlight brightness (`10` - `100`)
- `POST /api/reload`: Reload compositor
- `POST /api/reboot`: Reboot Raspberry Pi

---

## 🔒 5. Architecture & Native System Elements

- **Native GTK3 Splash:** `/opt/kiosk/kiosk-native-splash.py` (hardware-accelerated Wayland splash, zero browser tabs)
- **Native GTK3 Updater:** `/opt/kiosk/kiosk-native-update.py` (animated update screen with git sync & auto-reboot)
- **Native GTK3 Admin App:** `/opt/kiosk/kiosk-native-admin.py` (native Linux control panel running next to Chrome)
- **Wayland Compositor:** `labwc` on `tty1` managed by `kiosk-display.service`
- **Single Window Enforcement:** Popup blocking, `target="_blank"` interception, and window.open redirects to ensure user remains locked inside the designated dashboard.
