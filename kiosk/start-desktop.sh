#!/usr/bin/env bash
# ==============================================================================
# start-desktop.sh - Launches real desktop environment with independent windows
# ==============================================================================

set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

echo "[kiosk-desktop] Transitioning to Real Linux Desktop Environment..."
touch /tmp/kiosk-admin-workstation

# Relax lockdown policy so full browser and networking are unrestricted
if [ -f /opt/kiosk/kiosk-config.sh ]; then
    sudo /opt/kiosk/kiosk-config.sh --unlock 2>/dev/null || true
fi

# 1. Completely terminate all fullscreen kiosk chromium processes so they don't merge tabs
pkill -9 -f 'chromium' 2>/dev/null || true
sleep 0.6

# 2. Set desktop dark background
pkill -f swaybg 2>/dev/null || true
if command -v swaybg >/dev/null 2>&1; then
    swaybg -c "#030712" &
fi

# 3. Launch bottom taskbar / panel
pkill -f waybar 2>/dev/null || true
if [ -f /etc/kiosk/waybar/config.jsonc ]; then
    waybar -c /etc/kiosk/waybar/config.jsonc -s /etc/kiosk/waybar/style.css &
elif [ -f /opt/kiosk/waybar/config.jsonc ]; then
    waybar -c /opt/kiosk/waybar/config.jsonc -s /opt/kiosk/waybar/style.css &
fi

sleep 0.4

# 4. Launch Independent Native Window 1: Standalone Control Center (Left)
nohup /usr/bin/chromium \
  --ozone-platform=wayland \
  --user-data-dir=/tmp/chromium-kiosk-settings \
  --app="http://127.0.0.1:8080/" \
  --window-size=920,680 \
  --window-position=50,60 \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache >/dev/null 2>&1 &

# 5. Launch Independent Native Window 2: Real Google Chrome Browser on Desktop (Right)
nohup /usr/bin/chromium \
  --ozone-platform=wayland \
  --user-data-dir=/tmp/chromium-kiosk-browser \
  --window-size=920,680 \
  --window-position=980,60 \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache \
  "chrome://newtab" >/dev/null 2>&1 &

echo "[kiosk-desktop] Real desktop environment active with separate floating windows."
