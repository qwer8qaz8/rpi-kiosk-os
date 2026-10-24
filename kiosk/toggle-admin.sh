#!/usr/bin/env bash
# ==============================================================================
# toggle-admin.sh - Compositor keybind handler for Ctrl+Alt+= or Ctrl+=
# ==============================================================================

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if [ -f "/tmp/kiosk-admin-workstation" ]; then
    /opt/kiosk/lock-kiosk.sh
else
    # Launch native GTK3 authentication dialog immediately
    if ! pgrep -f "kiosk-native-auth.py" >/dev/null 2>&1; then
        python3 /opt/kiosk/kiosk-native-auth.py &
    fi
    curl -s -X POST http://127.0.0.1:8080/api/admin/trigger_listener >/dev/null 2>&1 || true
fi
