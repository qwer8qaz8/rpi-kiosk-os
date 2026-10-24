#!/usr/bin/env bash
# ==============================================================================
# apply-update.sh - KioskOS Native System Update Runner
# Displays native GTK3 update screen, synchronizes latest code, and reboots cleanly.
# ==============================================================================

set -e

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

echo "[kioskos] Launching Native KioskOS Update Interface..."

if [ -f "/opt/kiosk/kiosk-native-update.py" ]; then
    python3 /opt/kiosk/kiosk-native-update.py
else
    echo "[kioskos] kiosk-native-update.py not found, running CLI update..."
    /opt/kiosk/kiosk-config.sh --update
    sudo systemctl reboot
fi
