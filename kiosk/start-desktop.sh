#!/usr/bin/env bash
# ==============================================================================
# start-desktop.sh - Launches real macOS desktop environment under labwc
# ==============================================================================

set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

echo "[kiosk-desktop] Transitioning to macOS Admin Desktop..."
touch /tmp/kiosk-admin-workstation

# Relax lockdown policy so full browser and networking are unrestricted
if [ -f /opt/kiosk/kiosk-config.sh ]; then
    sudo /opt/kiosk/kiosk-config.sh --unlock 2>/dev/null || true
fi

# Stop any running single-app kiosk instances
pkill -f 'chromium.*--kiosk' 2>/dev/null || true
pkill -f 'chromium.*--start-fullscreen' 2>/dev/null || true
sleep 0.5

# Start macOS Desktop Background
pkill -f swaybg 2>/dev/null || true
if command -v swaybg >/dev/null 2>&1; then
    swaybg -c "#0b0f19" &
fi

# Start macOS Top Bar & Bottom Dock
pkill -f waybar 2>/dev/null || true
if [ -f /etc/kiosk/waybar/config.jsonc ]; then
    waybar -c /etc/kiosk/waybar/config.jsonc -s /etc/kiosk/waybar/style.css &
elif [ -f /opt/kiosk/waybar/config.jsonc ]; then
    waybar -c /opt/kiosk/waybar/config.jsonc -s /opt/kiosk/waybar/style.css &
fi

# Launch side-by-side native windows:
# 1. Standalone Kiosk Settings / Control Center window (Left)
nohup /usr/bin/chromium \
  --ozone-platform=wayland \
  --app="http://127.0.0.1:8080/" \
  --window-size=920,680 \
  --window-position=50,60 \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache >/dev/null 2>&1 &

# 2. Native Google Chrome browser window with tabs & omnibar on top of the desktop (Right)
nohup /usr/bin/chromium \
  --ozone-platform=wayland \
  --window-size=920,680 \
  --window-position=980,60 \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache \
  "chrome://newtab" >/dev/null 2>&1 &

echo "[kiosk-desktop] macOS Admin Desktop active."
