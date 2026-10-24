#!/usr/bin/env bash
# ==============================================================================
# Screen Control Utility for Cage / Wayland Kiosk
# Handles screen power (ON/OFF), brightness, rotation, and status detection across:
# 1. Wayland outputs (via wlr-randr and Wayland compositor socket)
# 2. Universal Wayland software gamma brightness (via gammastep)
# 3. Linux sysfs backlight (/sys/class/backlight/*) for DSI touchscreens
# 4. HDMI monitor DDC/CI hardware control (via ddcutil)
# 5. Linux framebuffer blanking (/sys/class/graphics/fb*/blank)
# ==============================================================================

set -o pipefail

CONFIG_FILE="/etc/kiosk/config.json"
ACTION="${1:-status}"
ARG2="$2"

setup_wayland_env() {
  if [ -z "$XDG_RUNTIME_DIR" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
    for uid_dir in /run/user/*; do
      if [ -d "$uid_dir" ]; then
        export XDG_RUNTIME_DIR="$uid_dir"
        break
      fi
    done
  fi
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"

  if [ -z "$WAYLAND_DISPLAY" ]; then
    for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
      if [ -S "$sock" ]; then
        export WAYLAND_DISPLAY="$(basename "$sock")"
        break
      fi
    done
  fi
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
}

run_wayland_cmd() {
  setup_wayland_env
  local target_user
  target_user=$(stat -c '%U' "$XDG_RUNTIME_DIR" 2>/dev/null || echo "pi")
  if [ "$EUID" -eq 0 ] && [ "$target_user" != "root" ]; then
    sudo -u "$target_user" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" "$@" 2>/dev/null || true
  else
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" "$@" 2>/dev/null || true
  fi
}

get_all_outputs() {
  local outs=""
  if command -v wlr-randr >/dev/null 2>&1; then
    outs=$(run_wayland_cmd wlr-randr | grep -E '^[A-Za-z0-9-]+' | awk '{print $1}')
  fi
  if [ -z "$outs" ]; then
    for conn in /sys/class/drm/card*-*; do
      if [ -d "$conn" ]; then
        cname=$(basename "$conn" | sed 's/card[0-9]*-//')
        outs="$outs $cname"
      fi
    done
  fi
  if [ -z "$outs" ]; then
    outs="HDMI-A-1 HDMI-A-2 DSI-1"
  fi
  echo "$outs"
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
  if [ -z "$percent" ]; then percent=100; fi
  if [ "$percent" -lt 1 ]; then percent=1; fi
  if [ "$percent" -gt 100 ]; then percent=100; fi

  # 1. Hardware DSI backlight (if present)
  for bl in /sys/class/backlight/*; do
    if [ -d "$bl" ] && [ -f "$bl/max_brightness" ]; then
      max_b=$(cat "$bl/max_brightness" 2>/dev/null || echo 255)
      calc_b=$(( (max_b * percent) / 100 ))
      if [ -w "$bl/brightness" ]; then
        echo "$calc_b" > "$bl/brightness" 2>/dev/null || true
      else
        sudo tee "$bl/brightness" >/dev/null <<< "$calc_b" 2>/dev/null || true
      fi
    fi
  done

  # 2. Universal Wayland Gamma Brightness (works on HDMI, DSI, TV via Cage/wlroots)
  if ! command -v gammastep >/dev/null 2>&1; then
    # Automatically install gammastep if missing
    if [ "$EUID" -eq 0 ]; then
      apt-get update -y >/dev/null 2>&1 && apt-get install -y --no-install-recommends gammastep >/dev/null 2>&1 || true
    else
      sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y --no-install-recommends gammastep >/dev/null 2>&1 || true
    fi
  fi

  if command -v gammastep >/dev/null 2>&1; then
    pkill -9 -f "gammastep" 2>/dev/null || true
    if [ "$percent" -ge 100 ]; then
      run_wayland_cmd gammastep -m wayland -x >/dev/null 2>&1 || true
    else
      ratio=$(python3 -c "print(max(0.05, round($percent / 100.0, 2)))")
      run_wayland_cmd gammastep -m wayland -O 6500 -b "$ratio" >/dev/null 2>&1 &
    fi
  fi

  # 2b. brightnessctl for standard Linux systems
  if command -v brightnessctl >/dev/null 2>&1; then
    brightnessctl set "${percent}%" >/dev/null 2>&1 || true
  fi

  # 3. Hardware DDC/CI for HDMI monitors (if available)
  if command -v ddcutil >/dev/null 2>&1; then
    ddcutil setvcp 10 "$percent" >/dev/null 2>&1 &
  fi

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
  if [ -f "$CONFIG_FILE" ]; then
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('brightness', 100))" 2>/dev/null && return
  fi
  echo 100
}

set_screen_power() {
  local state="$1" # "on" or "off"

  if [ "$state" = "on" ]; then
    # 1. Raspberry Pi HDMI display power ON via VideoCore
    if command -v vcgencmd >/dev/null 2>&1; then
      vcgencmd display_power 1 2>/dev/null || true
    fi

    # 2. Backlight on (DSI touchscreens)
    set_backlight_power 0

    # 3. Framebuffer unblank
    for fb in /sys/class/graphics/fb*; do
      if [ -f "$fb/blank" ]; then
        sudo tee "$fb/blank" >/dev/null <<< 0 2>/dev/null || echo 0 > "$fb/blank" 2>/dev/null || true
      fi
    done

    # 4. ddcutil monitor wake (HDMI)
    if command -v ddcutil >/dev/null 2>&1; then
      ddcutil setvcp d6 1 >/dev/null 2>&1 &
    fi

    # 5. Generic Linux console unblank
    if command -v setterm >/dev/null 2>&1; then
      setterm --blank poke 2>/dev/null || true
    fi

    # 6. Restore brightness
    b_val=$(get_brightness)
    set_brightness "$b_val"

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
    # 1. Raspberry Pi HDMI display power OFF via VideoCore
    # Note: We do NOT use wlr-randr --off because disabling all outputs causes Cage compositor to exit!
    if command -v vcgencmd >/dev/null 2>&1; then
      vcgencmd display_power 0 2>/dev/null || true
    fi

    # 2. Backlight off (DSI touchscreens)
    set_backlight_power 1

    # 3. Framebuffer blank
    for fb in /sys/class/graphics/fb*; do
      if [ -f "$fb/blank" ]; then
        sudo tee "$fb/blank" >/dev/null <<< 1 2>/dev/null || echo 1 > "$fb/blank" 2>/dev/null || true
      fi
    done

    # 4. ddcutil monitor sleep (HDMI)
    if command -v ddcutil >/dev/null 2>&1; then
      ddcutil setvcp d6 5 >/dev/null 2>&1 &
    fi

    # 5. Generic Linux console blank
    if command -v setterm >/dev/null 2>&1; then
      setterm --blank force 2>/dev/null || true
    fi

    # Auto-lock: If monitor turns off while in Admin Desktop Mode, auto-lock back to Kiosk immediately
    if [ -f /tmp/kiosk-admin-workstation ]; then
      echo "[screen-control] Monitor turned off: Auto-locking Admin Mode back to Kiosk..."
      /opt/kiosk/lock-kiosk.sh >/dev/null 2>&1 &
    fi

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
  local rotation="$1"
  local output
  output=$(get_all_outputs | awk '{print $1}')

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
    run_wayland_cmd wlr-randr --output "$output" --transform "$transform"
    echo "Output $output rotated to $transform"
  fi

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

  # Check vcgencmd first on Raspberry Pi
  if command -v vcgencmd >/dev/null 2>&1; then
    local vcg
    vcg=$(vcgencmd display_power 2>/dev/null || true)
    if [[ "$vcg" =~ display_power=0 ]]; then
      echo "OFF"
      return
    fi
  fi

  # Check backlight power on DSI touchscreens
  for bl in /sys/class/backlight/*; do
    if [ -f "$bl/bl_power" ]; then
      val=$(cat "$bl/bl_power" 2>/dev/null)
      if [ "$val" = "1" ]; then
        echo "OFF"
        return
      fi
    fi
  done

  # Fallback to config file
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
    echo "Usage: $0 {on|off|toggle|brightness <0-100>|get_brightness|rotate <normal|90|180|270>|status}"
    exit 1
    ;;
esac
