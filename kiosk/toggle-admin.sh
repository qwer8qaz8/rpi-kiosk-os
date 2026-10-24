#!/usr/bin/env bash
# ==============================================================================
# toggle-admin.sh - Compositor keybind handler for Ctrl+Alt+=
# ==============================================================================

if [ -f "/tmp/kiosk-admin-workstation" ]; then
    /opt/kiosk/lock-kiosk.sh
else
    # In kiosk mode, trigger the client-side secret listener via synthetic or WebUI API
    curl -s -X POST http://127.0.0.1:8080/api/admin/trigger_listener >/dev/null 2>&1 || true
fi
