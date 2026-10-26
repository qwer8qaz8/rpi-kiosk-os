# KioskOS - AI Agent & Automated Provisioning Guide

This document is designed for AI Coding Agents and Automated Provisioning Systems to deploy, configure, diagnose, and maintain **KioskOS** as a dedicated single-purpose Home Assistant Kiosk appliance.

---

## ⚡ 1. One-Line Deployment (Clean Raspberry Pi OS to KioskOS)

Run this single command on any fresh Raspberry Pi OS (Lite or Desktop, Debian 12 Bookworm / Debian 13 Trixie):

```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash
```

### Unattended / Non-Interactive Agent Deployment
```bash
curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh | bash -s -- \
  --url "http://homeassistant.local:8123/lovelace/0?kiosk" \
  --orientation "normal" \
  --non-interactive
```

---

## 🛠️ 2. Comprehensive CLI Reference (`kioskos`)

The `kioskos` CLI is available globally and is the authoritative management interface for agents and administrators:

### Status & Hardware Inspection
```bash
# Check appliance status, telemetry, active profile, resolution, and IP
kioskos status

# Run physical hardware diagnostics (SoC, RAM variant, screen resolution, thermals)
kioskos hw

# View available hardware profiles and applied optimization flags
kioskos profile list
kioskos profile apply rpi4_high
```

### Home Assistant & Dashboard Control
```bash
# Set Home Assistant target dashboard URL (reloads compositor immediately)
kioskos url "http://homeassistant.local:8123/lovelace/0?kiosk"

# Configure auto-login credentials (automatically types and bypasses login screens)
kioskos autologin "kiosk_user" "kiosk_password"

# Set/get any configuration key
kioskos set brightness 85
kioskos set rotation 90
kioskos get dashboard_url
```

### Display & Screen Power
```bash
# Toggle or set screen backlight power
kioskos screen on
kioskos screen off
kioskos screen sleep

# Adjust backlight brightness (10-100%)
kioskos brightness 75

# Set display orientation (normal, 90, 180, 270)
kioskos rotate normal
```

### Backup & Disaster Recovery
```bash
# Create sanitized backup (passwords & tokens stripped for agent inspection / git export)
kioskos backup create --sanitized

# Create full backup (includes passwords for 1:1 hardware migration)
kioskos backup create --full --out /var/backups/kiosk/full-backup.tar.gz

# List all available backups
kioskos backup list

# Restore appliance from an archive
kioskos backup restore /var/backups/kiosk/kioskos-backup-sanitized-20261026_160000.tar.gz
```

### Updates & Maintenance (Zero Spontaneous Reboots)
```bash
# Check if a new release is available on GitHub
kioskos update check

# Pull and apply latest GitHub update (reloads display compositor, never forces a system reboot)
kioskos update apply

# Restart kiosk display engine cleanly
kioskos restart

# Safe manual reboot (only when explicitly requested)
kioskos reboot
```

---

## 🖥️ 3. Physical Kiosk Keyboard Handling & Lockdown

To ensure zero tampering in public or living spaces, **all browser shortcuts and system hotkeys are strictly blocked** at both the Wayland compositor (`labwc`) and Chromium content script levels:

| Shortcut Category | Blocked Combinations | Behavior |
|---|---|---|
| **Tabs & Windows** | <kbd>Ctrl</kbd>+<kbd>T</kbd>, <kbd>Ctrl</kbd>+<kbd>N</kbd>, <kbd>Ctrl</kbd>+<kbd>W</kbd>, <kbd>Ctrl</kbd>+<kbd>Q</kbd>, <kbd>Alt</kbd>+<kbd>F4</kbd> | Intercepted & Voided |
| **Developer Tools** | <kbd>F12</kbd>, <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>I</kbd>, <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>J</kbd>, <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>C</kbd> | Disabled by Policy & Compositor |
| **Chrome Internal** | <kbd>Shift</kbd>+<kbd>Esc</kbd> (Task Manager), <kbd>Ctrl</kbd>+<kbd>H</kbd>, <kbd>Ctrl</kbd>+<kbd>J</kbd>, <kbd>Ctrl</kbd>+<kbd>P</kbd>, <kbd>Ctrl</kbd>+<kbd>S</kbd>, <kbd>Ctrl</kbd>+<kbd>O</kbd> | Intercepted & Blocked |
| **Navigation & Zoom** | <kbd>Alt</kbd>+<kbd>&larr;</kbd>, <kbd>Alt</kbd>+<kbd>&rarr;</kbd>, <kbd>F11</kbd>, Touch pinch-to-zoom | Disabled |
| **Virtual Terminals** | <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F1..F12</kbd> | Masked via kernel keymap & logind |
| **Administrator Refresh** | <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>R</kbd> | Restarts `kiosk-display` compositor |

---

## 🚀 4. Performance Optimization Profiles

KioskOS dynamically checks the underlying hardware and applies tailored Chromium command-line flags and memory bounds:

| Profile | Target Hardware | Optimizations |
|---|---|---|
| `rpi5_high` | Raspberry Pi 5 (4GB / 8GB) | VideoCore VII Vulkan/GPU rasterization, 4 raster threads, 1024MB JS heap, 128MB RAM cache |
| `rpi5_balanced` | Raspberry Pi 5 (2GB) | VideoCore VII rasterization, 3 renderer limit, 512MB JS heap |
| `rpi4_high` | Raspberry Pi 4 Model B (4GB / 8GB) | VideoCore VI GPU rasterization, 3 raster threads, 768MB JS heap, 64MB RAM cache |
| `rpi4_2gb` | Raspberry Pi 4 Model B (2GB) | Dual renderer limit, 384MB JS heap, 32MB RAM cache, tuned swappiness |
| `rpi4_1gb` | Raspberry Pi 4 Model B (1GB) | Single renderer limit, 256MB JS heap, smooth scrolling disabled |
| `rpi3` | Raspberry Pi 3 Model B / B+ (1GB) | VideoCore IV flags, low-resolution tiling, 256MB JS heap |
| `rpizero2` | Raspberry Pi Zero 2 W (512MB) | Single renderer, 192MB JS heap, memory compression (ZRAM) |
| `generic_high` | x86_64 / ARM (>4GB RAM) | 4 raster threads, 1024MB JS heap, full GPU acceleration |
| `generic_balanced`| Generic Linux (2GB - 4GB RAM) | 3 raster threads, 512MB JS heap, GPU rasterization |
| `generic_lean` | Generic Linux (1GB - 2GB RAM) | 2 raster threads, 384MB JS heap, compact memory limits |
| `generic_ultralean`| Generic Linux (<1GB RAM) | Single renderer, 192MB JS heap, minimal footprint |

---

## 🎨 5. Hardware-Aware Boot Splash Screen

When booting on a Raspberry Pi, KioskOS displays a custom **Raspberry Pi × Home Assistant** themed vector splash screen:
- Blended dual aesthetic: Raspberry Pi ruby-red berry clusters and emerald leaves surrounding the glowing cyan Home Assistant house glyph.
- Displays detected hardware model (e.g. `Raspberry Pi 4 Model B`) and active screen resolution.
- Live progress indicator showing hardware optimization and connection status.
- Zero browser dependencies: built in hardware-accelerated GTK3/Cairo running directly on Wayland.

---

## 🤖 6. Quick Instructions for AI Agents

When interacting with a KioskOS device:
1. **Never search for a Web UI on port 8080** - KioskOS is 100% single-purpose and CLI configured.
2. **Inspect device state**: Run `kioskos status` and `kioskos hw`.
3. **Change settings**: Always use `kioskos set <key> <val>` or `kioskos url <url>`.
4. **Trigger updates**: Use `kioskos update`. It compares remote commit hashes and refreshes the display without rebooting.
5. **Back up state**: Run `kioskos backup create --sanitized` before making modifications.
