#!/usr/bin/env bash
# ==============================================================================
# rpi-kiosk-os: One-Line Automated Installer for Raspberry Pi OS Lite Kiosk
# ==============================================================================
set -eo pipefail

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Default Parameters (can be overridden via flags, env vars, or setup file)
DEFAULT_HA_URL="http://homeassistant.local:8123/lovelace/0?kiosk"
HA_URL="${HA_URL:-}"
DISPLAY_TYPE="${DISPLAY_TYPE:-}"
ROTATION="${ROTATION:-}"
MQTT_BROKER="${MQTT_BROKER:-}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
HA_USER_ID="${HA_USER_ID:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
CONFIG_FILE_INPUT=""
REPO_URL="${REPO_URL:-https://github.com/qwer8qaz8/rpi-kiosk-os.git}"

# Parse Command-Line Arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)
      HA_URL="$2"
      shift 2
      ;;
    -o|--orientation|--rotate)
      ROTATION="$2"
      shift 2
      ;;
    -t|--display-type)
      DISPLAY_TYPE="$2"
      shift 2
      ;;
    -b|--mqtt-broker)
      MQTT_BROKER="$2"
      shift 2
      ;;
    -p|--mqtt-port)
      MQTT_PORT="$2"
      shift 2
      ;;
    -m|--mqtt-user)
      MQTT_USER="$2"
      shift 2
      ;;
    -w|--mqtt-pass)
      MQTT_PASS="$2"
      shift 2
      ;;
    -k|--kiosk-user-id)
      HA_USER_ID="$2"
      shift 2
      ;;
    -c|--config)
      CONFIG_FILE_INPUT="$2"
      shift 2
      ;;
    -r|--repo)
      REPO_URL="$2"
      shift 2
      ;;
    -y|--non-interactive|--unattended)
      NON_INTERACTIVE=1
      shift
      ;;
    -h|--help)
      echo "Raspberry Pi Kiosk Installer"
      echo "Usage: ./install.sh [options]"
      echo ""
      echo "Options:"
      echo "  -u, --url <URL>              Home Assistant Dashboard URL"
      echo "  -o, --orientation <ROTATION> Screen orientation: normal, 90, 180, 270"
      echo "  -t, --display-type <TYPE>    Display type: hdmi or dsi"
      echo "  -b, --mqtt-broker <HOST>     MQTT Broker IP / hostname"
      echo "  -p, --mqtt-port <PORT>       MQTT Broker port (default 1883)"
      echo "  -m, --mqtt-user <USER>       MQTT Username"
      echo "  -w, --mqtt-pass <PASS>       MQTT Password"
      echo "  -k, --kiosk-user-id <ID>     Home Assistant non-admin user ID"
      echo "  -c, --config <FILE>          Path to pre-filled JSON config file"
      echo "  -y, --non-interactive        Run without prompts using flags or defaults"
      echo "  -h, --help                   Display this help message"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# If a config file was passed, load values from it
if [ -n "$CONFIG_FILE_INPUT" ] && [ -f "$CONFIG_FILE_INPUT" ]; then
  echo -e "${BLUE}Loading configuration from: ${BOLD}$CONFIG_FILE_INPUT${NC}"
  HA_URL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('dashboard_url', ''))" 2>/dev/null || echo "$HA_URL")
  ROTATION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('display_rotation', ''))" 2>/dev/null || echo "$ROTATION")
  DISPLAY_TYPE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('display_type', ''))" 2>/dev/null || echo "$DISPLAY_TYPE")
  MQTT_BROKER=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('mqtt', {}).get('broker', ''))" 2>/dev/null || echo "$MQTT_BROKER")
  MQTT_USER=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('mqtt', {}).get('username', ''))" 2>/dev/null || echo "$MQTT_USER")
  MQTT_PASS=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('mqtt', {}).get('password', ''))" 2>/dev/null || echo "$MQTT_PASS")
  HA_USER_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE_INPUT')).get('kiosk_user_id', ''))" 2>/dev/null || echo "$HA_USER_ID")
fi

clear 2>/dev/null || true
echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "          Raspberry Pi OS Lite Ultra-Lightweight Kiosk            "
echo "        Cage (Wayland) + Chromium + Flask WebUI + HA MQTT         "
echo "=================================================================="
echo -e "${NC}"

# Check for root / sudo privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Root privileges required. Elevating with sudo...${NC}"
  if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "/bin/bash" ] && [ "$0" != "/usr/bin/bash" ] && [ "$0" != "-bash" ]; then
    exec sudo -E bash "$0" "$@"
  else
    TMP_INSTALLER="/tmp/rpi-kiosk-installer.sh"
    curl -sSL "https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/install.sh" -o "$TMP_INSTALLER"
    chmod +x "$TMP_INSTALLER"
    exec sudo -E bash "$TMP_INSTALLER" "$@"
  fi
fi

# Operating system check
if [ ! -f /etc/debian_version ]; then
  echo -e "${RED}[ERROR] This installer is designed for Debian / Raspberry Pi OS.${NC}" >&2
  exit 1
fi

# Detect non-root target user
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  TARGET_USER=$(id -un 1000 2>/dev/null || echo "pi")
fi
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo "1000")
TARGET_HOME=$(eval echo "~$TARGET_USER")

echo -e "${BLUE}Target user:${NC} ${BOLD}$TARGET_USER${NC} (UID: $TARGET_UID)"

# Detect Pi IP Address
DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$DETECTED_IP" ]; then
  DETECTED_IP="192.168.1.XXX"
fi

# Connect terminal input if running in interactive mode via curl pipe
if [ "$NON_INTERACTIVE" != "1" ] && [ ! -t 0 ] && [ -e /dev/tty ]; then
  exec < /dev/tty
fi

# Interactive Setup (if not running in unattended mode)
if [ "$NON_INTERACTIVE" != "1" ]; then
  echo -e "\n${BOLD}--- Setup Configuration ---${NC}\n"

  # 1. Home Assistant URL
  if [ -z "$HA_URL" ]; then
    read -r -p "Home Assistant Dashboard URL [$DEFAULT_HA_URL]: " INPUT_HA_URL
    HA_URL="${INPUT_HA_URL:-$DEFAULT_HA_URL}"
  fi

  # 2. Display Type
  if [ -z "$DISPLAY_TYPE" ]; then
    echo -e "\nSelect Display Connection:"
    echo "  1) HDMI Monitor / TV (wayland_hdmi)"
    echo "  2) Official / DSI Ribbon Touchscreen (dsi_touchscreen)"
    read -r -p "Choose [1 or 2, default 1]: " INPUT_DISPLAY_TYPE
    case "$INPUT_DISPLAY_TYPE" in
      2) DISPLAY_TYPE="dsi_touchscreen" ;;
      *) DISPLAY_TYPE="wayland_hdmi" ;;
    esac
  fi

  # 3. Orientation
  if [ -z "$ROTATION" ]; then
    echo -e "\nSelect Screen Orientation:"
    echo "  1) Standard Landscape (0°)"
    echo "  2) Portrait (90° Clockwise)"
    echo "  3) Inverted Landscape (180°)"
    echo "  4) Inverted Portrait (270° Clockwise)"
    read -r -p "Choose [1-4, default 1]: " INPUT_ROTATION
    case "$INPUT_ROTATION" in
      2) ROTATION="90" ;;
      3) ROTATION="180" ;;
      4) ROTATION="270" ;;
      *) ROTATION="normal" ;;
    esac
  fi

  # 4. MQTT Broker
  if [ -z "$MQTT_BROKER" ]; then
    echo -e "\nConfigure Home Assistant / Umbrel MQTT Integration (Optional):"
    read -r -p "Enter MQTT Broker Host/IP (leave blank to skip): " INPUT_MQTT_BROKER
    if [ -n "$INPUT_MQTT_BROKER" ]; then
      MQTT_BROKER="$INPUT_MQTT_BROKER"
      read -r -p "Enter MQTT Port [1883]: " INPUT_MQTT_PORT
      MQTT_PORT="${INPUT_MQTT_PORT:-1883}"
      read -r -p "Enter MQTT Username (optional): " MQTT_USER
      read -r -s -p "Enter MQTT Password (optional): " MQTT_PASS
      echo ""
    fi
  fi

  # 5. Kiosk Non-Admin User ID
  if [ -z "$HA_USER_ID" ]; then
    echo -e "\n${CYAN}Home Assistant Auto-Login Configuration:${NC}"
    echo "To allow the kiosk to bypass the login prompt without storing passwords,"
    echo "Home Assistant's trusted_networks provider can automatically log in a dedicated user."
    read -r -p "Enter your Home Assistant Kiosk User ID (Settings -> People -> Users, or leave blank): " HA_USER_ID
  fi
fi

# Fallback defaults if values still unset
HA_URL="${HA_URL:-$DEFAULT_HA_URL}"
DISPLAY_TYPE="${DISPLAY_TYPE:-wayland_hdmi}"
ROTATION="${ROTATION:-normal}"
if [ -n "$MQTT_BROKER" ]; then
  MQTT_ENABLED="true"
else
  MQTT_ENABLED="false"
fi

echo -e "\n${GREEN}[1/6] Installing dependencies (Cage, Chromium, Flask, MQTT)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

CHROMIUM_PKG="chromium-browser"
if ! apt-cache show chromium-browser >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium"
fi

apt-get install -y --no-install-recommends \
  cage \
  "$CHROMIUM_PKG" \
  wlr-randr \
  python3-paho-mqtt \
  python3-flask \
  git \
  curl \
  jq \
  systemd

# Add target user to hardware groups
echo -e "${GREEN}[2/6] Configuring user permissions for Wayland and hardware access...${NC}"
for grp in video input render tty; do
  if getent group "$grp" >/dev/null; then
    usermod -a -G "$grp" "$TARGET_USER" 2>/dev/null || true
  fi
done

# Backlight udev rule
mkdir -p /etc/udev/rules.d
cat << 'EOF' > /etc/udev/rules.d/99-kiosk-backlight.rules
SUBSYSTEM=="backlight", ACTION=="add", RUN+="/bin/chgrp -R video /sys/class/backlight/%k", RUN+="/bin/chmod -R g+w /sys/class/backlight/%k"
EOF
udevadm control --reload-rules 2>/dev/null || true

# Sudoers permissions
echo -e "${GREEN}[3/6] Configuring permissions for kiosk services...${NC}"
cat << EOF > /etc/sudoers.d/kiosk
# Permissions for Kiosk services and Web UI
$TARGET_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart kiosk-display, /bin/systemctl stop kiosk-display, /bin/systemctl start kiosk-display
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart kiosk-display, /usr/bin/systemctl stop kiosk-display, /usr/bin/systemctl start kiosk-display
$TARGET_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart kiosk-mqtt, /usr/bin/systemctl restart kiosk-mqtt
$TARGET_USER ALL=(ALL) NOPASSWD: /bin/systemctl reboot, /usr/bin/systemctl reboot
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/class/backlight/*/bl_power, /usr/bin/tee /sys/class/backlight/*/brightness
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/vcgencmd display_power *
EOF
chmod 0440 /etc/sudoers.d/kiosk

# Install Kiosk files to /opt/kiosk
echo -e "${GREEN}[4/6] Installing kiosk scripts and Web UI to /opt/kiosk...${NC}"
mkdir -p /opt/kiosk /opt/kiosk/webui/templates /etc/kiosk

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/kiosk/launch-kiosk.sh" ]; then
  cp -r "$SCRIPT_DIR/kiosk/"* /opt/kiosk/
  cp "$SCRIPT_DIR/systemd/"* /etc/systemd/system/
else
  TMP_REPO=$(mktemp -d)
  git clone --depth 1 "$REPO_URL" "$TMP_REPO"
  cp -r "$TMP_REPO/kiosk/"* /opt/kiosk/
  cp "$TMP_REPO/systemd/"* /etc/systemd/system/
  rm -rf "$TMP_REPO"
fi

chmod +x /opt/kiosk/launch-kiosk.sh
chmod +x /opt/kiosk/screen-control.sh
chmod +x /opt/kiosk/kiosk-mqtt.py
chmod +x /opt/kiosk/webui/app.py

# Write /etc/kiosk/config.json
cat << EOF > /etc/kiosk/config.json
{
  "dashboard_url": "$HA_URL",
  "screen_on": true,
  "display_type": "$DISPLAY_TYPE",
  "display_rotation": "$ROTATION",
  "mqtt": {
    "enabled": $MQTT_ENABLED,
    "broker": "$MQTT_BROKER",
    "port": $MQTT_PORT,
    "username": "$MQTT_USER",
    "password": "$MQTT_PASS",
    "topic_prefix": "homeassistant",
    "device_id": "rpi_kiosk",
    "device_name": "RPi Kiosk"
  }
}
EOF

chown -R "$TARGET_USER:$TARGET_USER" /opt/kiosk
chown -R "$TARGET_USER:$TARGET_USER" /etc/kiosk
chmod 664 /etc/kiosk/config.json

# Customize Systemd units for the detected user and UID
echo -e "${GREEN}[5/6] Registering Systemd Services...${NC}"
for svc in kiosk-display.service kiosk-mqtt.service kiosk-webui.service; do
  sed -i "s/User=pi/User=$TARGET_USER/g" "/etc/systemd/system/$svc"
  sed -i "s/Group=pi/Group=$TARGET_USER/g" "/etc/systemd/system/$svc"
  sed -i "s|XDG_RUNTIME_DIR=/run/user/1000|XDG_RUNTIME_DIR=/run/user/$TARGET_UID|g" "/etc/systemd/system/$svc"
done

systemctl set-default graphical.target
systemctl daemon-reload
systemctl enable kiosk-display.service
systemctl enable kiosk-mqtt.service
systemctl enable kiosk-webui.service

systemctl restart kiosk-webui.service
systemctl restart kiosk-mqtt.service
systemctl restart kiosk-display.service || true

# Generate Home Assistant trusted_networks snippet
SNIPPET_FILE="/etc/kiosk/ha-trusted-networks.yaml"
cat << EOF > "$SNIPPET_FILE"
# ==============================================================================
# Paste the following into your Home Assistant configuration.yaml:
# This automatically logs in the Kiosk display without prompting for password,
# strictly restricted to the Raspberry Pi's IP address.
# ==============================================================================
homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - ${DETECTED_IP}/32
      trusted_users:
        ${DETECTED_IP}: ${HA_USER_ID:-"<YOUR_HA_USER_ID>"}
      allow_bypass_login: true
EOF

echo -e "\n${GREEN}[6/6] Installation Complete!${NC}\n"
echo -e "${CYAN}==================================================================${NC}"
echo -e "${BOLD}1. Home Assistant Auto-Login Configuration:${NC}"
echo -e "   Paste this snippet into your Home Assistant ${BOLD}configuration.yaml${NC}:"
echo -e "${YELLOW}"
cat "$SNIPPET_FILE"
echo -e "${NC}"
echo -e "   (A copy is saved at: ${BOLD}$SNIPPET_FILE${NC})"

echo -e "\n${BOLD}2. Web Management Dashboard:${NC}"
echo -e "   Open from any browser or phone: ${GREEN}http://${DETECTED_IP}:8080${NC}"
echo -e "   You can change the URL, rotate the display, or toggle screen power."

echo -e "\n${BOLD}3. Status & Services:${NC}"
echo -e "   • Display Kiosk:  ${GREEN}active${NC} (via Cage Wayland compositor on TTY1)"
echo -e "   • Web Management: ${GREEN}http://${DETECTED_IP}:8080${NC}"
if [ "$MQTT_ENABLED" = "true" ]; then
  echo -e "   • MQTT Daemon:    ${GREEN}active${NC} (Reporting to $MQTT_BROKER)"
else
  echo -e "   • MQTT Daemon:    ${YELLOW}disabled${NC} (Enable via Web UI anytime)"
fi

echo -e "\n${CYAN}==================================================================${NC}"
echo -e "${BOLD}Tip:${NC} If you don't see the display immediately, reboot once:"
echo -e "     ${BOLD}sudo reboot${NC}"
echo -e "${CYAN}==================================================================${NC}\n"
