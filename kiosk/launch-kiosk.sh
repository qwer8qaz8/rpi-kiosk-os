#!/usr/bin/env bash
# ==============================================================================
# launch-kiosk.sh - Invoked by Cage Wayland compositor on boot
# ==============================================================================

set -eo pipefail

CONFIG_FILE="/etc/kiosk/config.json"
FALLBACK_CONFIG="/opt/kiosk/config.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve config file
if [ ! -f "$CONFIG_FILE" ] && [ -f "$FALLBACK_CONFIG" ]; then
  CONFIG_FILE="$FALLBACK_CONFIG"
fi

# Load settings from config.json using python3
DASHBOARD_URL=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f).get('dashboard_url', 'http://homeassistant.local:8123/lovelace/0?kiosk'))
except Exception:
    print('http://homeassistant.local:8123/lovelace/0?kiosk')
")

ROTATION=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f).get('display_rotation', 'normal'))
except Exception:
    print('normal')
")

SCREEN_ON=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f).get('screen_on', True))
except Exception:
    print(True)
")

echo "[kiosk] Starting kiosk environment..."
echo "[kiosk] Dashboard URL: $DASHBOARD_URL"

# Allow Wayland compositor to settle
sleep 1

# Apply screen rotation if configured
if [ -n "$ROTATION" ] && [ "$ROTATION" != "normal" ]; then
  if [ -x "$SCRIPT_DIR/screen-control.sh" ]; then
    "$SCRIPT_DIR/screen-control.sh" rotate "$ROTATION" || true
  fi
fi

# Check initial screen state
if [ "$SCREEN_ON" = "False" ] || [ "$SCREEN_ON" = "false" ]; then
  if [ -x "$SCRIPT_DIR/screen-control.sh" ]; then
    "$SCRIPT_DIR/screen-control.sh" off || true
  fi
fi

# Clean up Chromium crash states and locks
CHROME_PROFILE_DIR="$HOME/.config/chromium"
if [ -d "$CHROME_PROFILE_DIR" ]; then
  rm -f "$CHROME_PROFILE_DIR"/Singleton* 2>/dev/null || true
  if [ -f "$CHROME_PROFILE_DIR/Default/Preferences" ]; then
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROME_PROFILE_DIR/Default/Preferences" 2>/dev/null || true
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROME_PROFILE_DIR/Default/Preferences" 2>/dev/null || true
  fi
fi

# Locate Chromium binary
CHROMIUM_BIN=""
for bin in chromium-browser chromium /usr/bin/chromium-browser /usr/bin/chromium; do
  if command -v "$bin" >/dev/null 2>&1; then
    CHROMIUM_BIN="$bin"
    break
  fi
done

if [ -z "$CHROMIUM_BIN" ]; then
  echo "[kiosk] ERROR: chromium-browser or chromium not found!" >&2
  exit 1
fi

echo "[kiosk] Using browser binary: $CHROMIUM_BIN"

# Create ramdisk cache directory to avoid wearing out SD card
mkdir -p /tmp/chromium-cache 2>/dev/null || true

# Launch Chromium locked in Kiosk mode
exec "$CHROMIUM_BIN" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --check-for-update-interval=31536000 \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --enable-features=OverlayScrollbar \
  --disable-features=Translate \
  --disable-session-crashed-bubble \
  --autoplay-policy=no-user-gesture-required \
  --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache \
  --enable-gpu-rasterization \
  --enable-zero-copy \
  "$DASHBOARD_URL"
