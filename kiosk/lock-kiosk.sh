#!/usr/bin/env bash
# ==============================================================================
# lock-kiosk.sh - Exits Desktop Mode and returns to Fullscreen Single-App Kiosk
# ==============================================================================

set -e
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

echo "[kiosk-lock] Exiting Admin Desktop Mode and locking kiosk..."

rm -f /tmp/kiosk-admin-workstation
if [ -f /opt/kiosk/kiosk-config.sh ]; then
    sudo /opt/kiosk/kiosk-config.sh --lock 2>/dev/null || true
fi

# Terminate all desktop workstation applications
pkill -f waybar 2>/dev/null || true
pkill -f swaybg 2>/dev/null || true
pkill -f foot 2>/dev/null || true
pkill -f 'chromium' 2>/dev/null || true
sleep 0.5

# Re-launch single-app fullscreen kiosk
nohup /opt/kiosk/launch-kiosk.sh >/dev/null 2>&1 &
echo "[kiosk-lock] Fullscreen Kiosk Mode resumed."
