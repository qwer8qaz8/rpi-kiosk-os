#!/usr/bin/env bash
# ==============================================================================
# lock-kiosk.sh - Exits Desktop Mode and returns to Fullscreen Single-App Kiosk
# ==============================================================================

set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

echo "[kiosk-lock] Exiting Admin Desktop Mode and locking kiosk..."

rm -f /tmp/kiosk-admin-workstation
/opt/kiosk/play-chime.sh lock 2>/dev/null || true
if [ -f /opt/kiosk/kiosk-config.sh ]; then
    sudo /opt/kiosk/kiosk-config.sh --lock 2>/dev/null || true
fi

# Terminate all desktop workstation applications
pkill -9 -f waybar 2>/dev/null || true
pkill -9 -f kiosk-macos-topbar.py 2>/dev/null || true
pkill -9 -f swaybg 2>/dev/null || true
pkill -9 -f foot 2>/dev/null || true
pkill -9 -f kiosk-native-admin.py 2>/dev/null || true
killall -9 chromium chromium-browser 2>/dev/null || pkill -9 -f chromium 2>/dev/null || true
sleep 0.8

echo "[kiosk-lock] Fullscreen Kiosk Mode resumed."
