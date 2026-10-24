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

sound_name="${1:-boot}"
case "$sound_name" in
    bing) SOUND_FILE="sound-bing.wav" ;;
    unlock) SOUND_FILE="sound-unlock.wav" ;;
    lock) SOUND_FILE="sound-lock.wav" ;;
    touch) SOUND_FILE="sound-touch.wav" ;;
    alert) SOUND_FILE="sound-alert.wav" ;;
    boot|*) SOUND_FILE="chime-boot.wav" ;;
esac

if [ "$CHIME_ENABLED" = "True" ] || [ "$CHIME_ENABLED" = "true" ] || [ "$CHIME_ENABLED" = "1" ]; then
    AUDIO_PATH="/opt/kiosk/sounds/$SOUND_FILE"
    [ ! -f "$AUDIO_PATH" ] && AUDIO_PATH="/opt/kiosk/sounds/startup.wav"
    if [ -f "$AUDIO_PATH" ]; then
        if command -v pw-play >/dev/null 2>&1; then
            pw-play "$AUDIO_PATH" >/dev/null 2>&1 &
        elif command -v aplay >/dev/null 2>&1; then
            aplay -q "$AUDIO_PATH" >/dev/null 2>&1 &
        fi
    fi
fi
