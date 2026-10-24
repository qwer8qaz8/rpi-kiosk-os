#!/usr/bin/env bash
# ==============================================================================
# play-chime.sh - KioskOS Modern Ambient Boot Chime Player
# ==============================================================================

CONFIG_FILE="/etc/kiosk/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="/opt/kiosk/config.json"
fi

CHIME_ENABLED=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f).get('startup_chime', True))
except Exception:
    print(True)
" 2>/dev/null || echo "True")

if [ "$CHIME_ENABLED" = "True" ] || [ "$CHIME_ENABLED" = "true" ] || [ "$CHIME_ENABLED" = "1" ]; then
    CHIME_FILE="/opt/kiosk/sounds/startup.wav"
    if [ -f "$CHIME_FILE" ]; then
        # Try pw-play (PipeWire) then fallback to aplay (ALSA)
        if command -v pw-play >/dev/null 2>&1; then
            pw-play "$CHIME_FILE" >/dev/null 2>&1 &
        elif command -v aplay >/dev/null 2>&1; then
            aplay -q "$CHIME_FILE" >/dev/null 2>&1 &
        fi
    fi
fi
