#!/usr/bin/env bash
# ==============================================================================
# toggle-admin.sh - Compositor keybind handler for Ctrl+Alt+= or Ctrl+=
# ==============================================================================

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if [ -f "/tmp/kiosk-admin-workstation" ]; then
    /opt/kiosk/prompt-exit.sh
else
    curl -s -X POST http://127.0.0.1:8080/api/admin/trigger_listener >/dev/null 2>&1 || true
    if command -v wtype >/dev/null 2>&1; then
        wtype -M ctrl -M alt = -m alt -m ctrl 2>/dev/null || true
    fi
fi
