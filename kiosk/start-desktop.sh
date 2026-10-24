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
sudo rm -f /etc/chromium/policies/managed/kiosk_security_policy.json \
           /etc/chromium-browser/policies/managed/kiosk_security_policy.json \
           /etc/opt/chrome/policies/managed/kiosk_security_policy.json 2>/dev/null || true

# 1. Completely terminate fullscreen kiosk chromium so it yields display to desktop
killall -9 chromium chromium-browser 2>/dev/null || pkill -9 -f chromium 2>/dev/null || true
sleep 0.8

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

# 4. Launch Native Linux Window 1: Native KioskOS Control Center (Left)
if [ -f /opt/kiosk/kiosk-native-admin.py ]; then
    python3 /opt/kiosk/kiosk-native-admin.py &
fi

# 5. Launch Native Window 2: Real Google Chrome Browser on Desktop (Right)
nohup /usr/bin/chromium \
  --ozone-platform=wayland \
  --user-data-dir=/tmp/chromium-kiosk-browser \
  --window-size=1000,720 \
  --window-position=850,60 \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache \
  "chrome://newtab" >/dev/null 2>&1 &

echo "[kiosk-desktop] Real desktop environment active with separate floating windows."
