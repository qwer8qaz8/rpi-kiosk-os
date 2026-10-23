#!/usr/bin/env bash
# ==============================================================================
# Screen Control Utility for Cage / Wayland Kiosk
# Handles screen power (ON/OFF), brightness, rotation, and status detection across:
# 1. Wayland outputs (via wlr-randr)
# 2. Linux sysfs backlight (/sys/class/backlight/*)
# 3. Raspberry Pi firmware (vcgencmd display_power)
# ==============================================================================

set -o pipefail

CONFIG_FILE="/etc/kiosk/config.json"
ACTION="${1:-status}"
ARG2="$2"

get_active_wayland_output() {
  if command -v wlr-randr >/dev/null 2>&1; then
    wlr-randr 2>/dev/null | grep -E '^[A-Za-z0-9-]+' | awk '{print $1}' | head -n 1
  fi
}

set_backlight_power() {
  local power_val="$1" # 0 = ON, 1 = OFF for bl_power
  for bl in /sys/class/backlight/*; do
    if [ -d "$bl" ]; then
      if [ -w "$bl/bl_power" ]; then
        echo "$power_val" > "$bl/bl_power" 2>/dev/null || true
      else
        sudo tee "$bl/bl_power" >/dev/null <<< "$power_val" 2>/dev/null || true
      fi
    fi
  done
}

set_brightness() {
  local percent="$1"
  # Clamp 1-100
  if [ "$percent" -lt 1 ]; then percent=1; fi
  if [ "$percent" -gt 100 ]; then percent=100; fi

  for bl in /sys/class/backlight/*; do
    if [ -d "$bl" ] && [ -f "$bl/max_brightness" ]; then
      max_b=$(cat "$bl/max_brightness" 2>/dev/null || echo 255)
      calc_b=$(( (max_b * percent) / 100 ))
      if [ "$calc_b" -lt 1 ]; then calc_b=1; fi

      if [ -w "$bl/brightness" ]; then
        echo "$calc_b" > "$bl/brightness" 2>/dev/null || true
      else
        sudo tee "$bl/brightness" >/dev/null <<< "$calc_b" 2>/dev/null || true
      fi
    fi
  done

  # Save to config
  if [ -f "$CONFIG_FILE" ]; then
    python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    data['brightness'] = $percent
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except Exception:
    pass
" 2>/dev/null || true
  fi
  echo "$percent"
}

get_brightness() {
  for bl in /sys/class/backlight/*; do
    if [ -d "$bl" ] && [ -f "$bl/brightness" ] && [ -f "$bl/max_brightness" ]; then
      cur=$(cat "$bl/brightness" 2>/dev/null || echo 255)
      max_b=$(cat "$bl/max_brightness" 2>/dev/null || echo 255)
      if [ "$max_b" -gt 0 ]; then
        echo $(( (cur * 100) / max_b ))
        return
      fi
    fi
  done
  # Fallback to config
  if [ -f "$CONFIG_FILE" ]; then
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('brightness', 100))" 2>/dev/null && return
  fi
  echo 100
}

set_screen_power() {
  local state="$1" # "on" or "off"
  local output
  output=$(get_active_wayland_output)

  if [ "$state" = "on" ]; then
    # 1. Backlight
    set_backlight_power 0
    # 2. wlr-randr if running under Cage
    if [ -n "$output" ] && command -v wlr-randr >/dev/null 2>&1; then
      wlr-randr --output "$output" --on 2>/dev/null || true
    fi
    # 3. vcgencmd for HDMI if available
    if command -v vcgencmd >/dev/null 2>&1; then
      vcgencmd display_power 1 2>/dev/null || true
    fi
    # Update state in config
    if [ -f "$CONFIG_FILE" ]; then
      python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    data['screen_on'] = True
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except Exception:
    pass
" 2>/dev/null || true
    fi
    echo "Screen powered ON"

  elif [ "$state" = "off" ]; then
    # 1. Backlight
    set_backlight_power 1
    # 2. wlr-randr
    if [ -n "$output" ] && command -v wlr-randr >/dev/null 2>&1; then
      wlr-randr --output "$output" --off 2>/dev/null || true
    fi
    # 3. vcgencmd for HDMI
    if command -v vcgencmd >/dev/null 2>&1; then
      vcgencmd display_power 0 2>/dev/null || true
    fi
    # Update state in config
    if [ -f "$CONFIG_FILE" ]; then
      python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    data['screen_on'] = False
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except Exception:
    pass
" 2>/dev/null || true
    fi
    echo "Screen powered OFF"
  fi
}

rotate_screen() {
  local rotation="$1" # normal, 90, 180, 270 (or 90-cw, etc.)
  local output
  output=$(get_active_wayland_output)

  case "$rotation" in
    90|90-cw)
      transform="90"
      ;;
    180)
      transform="180"
      ;;
    270|90-ccw)
      transform="270"
      ;;
    *)
      transform="normal"
      ;;
  esac

  if [ -n "$output" ] && command -v wlr-randr >/dev/null 2>&1; then
    wlr-randr --output "$output" --transform "$transform" 2>/dev/null || true
    echo "Output $output rotated to $transform"
  else
    echo "No active Wayland output found to rotate"
  fi

  # Update config
  if [ -f "$CONFIG_FILE" ]; then
    python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    data['display_rotation'] = '$transform'
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except Exception:
    pass
" 2>/dev/null || true
  fi
}

get_status() {
  local screen_state="ON"
  for bl in /sys/class/backlight/*; do
    if [ -f "$bl/bl_power" ]; then
      val=$(cat "$bl/bl_power" 2>/dev/null)
      if [ "$val" = "1" ]; then
        screen_state="OFF"
      fi
    fi
  done
  if [ -f "$CONFIG_FILE" ]; then
    configured=$(python3 -c "import json; print('ON' if json.load(open('$CONFIG_FILE')).get('screen_on', True) else 'OFF')" 2>/dev/null)
    if [ -n "$configured" ]; then
      screen_state="$configured"
    fi
  fi
  echo "$screen_state"
}

case "$ACTION" in
  on)
    set_screen_power "on"
    ;;
  off)
    set_screen_power "off"
    ;;
  toggle)
    current=$(get_status)
    if [ "$current" = "ON" ]; then
      set_screen_power "off"
    else
      set_screen_power "on"
    fi
    ;;
  brightness)
    set_brightness "$ARG2"
    ;;
  get_brightness)
    get_brightness
    ;;
  rotate)
    rotate_screen "$ARG2"
    ;;
  status)
    get_status
    ;;
  *)
    echo "Usage: $0 {on|off|toggle|brightness <1-100>|get_brightness|rotate <normal|90|180|270>|status}"
    exit 1
    ;;
esac
