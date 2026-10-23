#!/usr/bin/env bash
# ==============================================================================
# kiosk-config - Interactive & CLI Configuration Utility for Raspberry Pi Kiosk
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="/etc/kiosk/config.json"
REPO_URL="https://github.com/qwer8qaz8/rpi-kiosk-os.git"
RAW_URL="https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main"

# Root check helper
require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Root privileges required. Re-running with sudo...${NC}"
    exec sudo -E bash "$0" "$@"
  fi
}

load_config_val() {
  local key="$1"
  local def="$2"
  if [ -f "$CONFIG_FILE" ]; then
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$key', '$def'))" 2>/dev/null || echo "$def"
  else
    echo "$def"
  fi
}

save_config_val() {
  local key="$1"
  local val="$2"
  require_root
  python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
except Exception:
    data = {}
data['$key'] = '$val'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
}

apply_security_policy() {
  require_root
  local ha_url
  ha_url=$(load_config_val "dashboard_url" "http://homeassistant.local:8123/lovelace/0?kiosk")
  
  local allowed_host
  allowed_host=$(python3 -c "
import urllib.parse
try:
    p = urllib.parse.urlparse('$ha_url')
    print(f'{p.scheme}://{p.netloc}/*')
except Exception:
    print('http://*:8123/*')
")

  mkdir -p /etc/chromium/policies/managed /etc/opt/chrome/policies/managed
  cat << EOF > /etc/chromium/policies/managed/kiosk_security_policy.json
{
  "URLBlocklist": ["*"],
  "URLAllowlist": [
    "$allowed_host",
    "http://192.168.*:8123/*",
    "http://100.*:8123/*",
    "http://umbrel.local:8123/*",
    "http://homeassistant.local:8123/*",
    "http://localhost:8080/*",
    "http://127.0.0.1:8080/*"
  ],
  "DeveloperToolsAvailability": 2,
  "DefaultPopupsSetting": 2,
  "PrintingEnabled": false,
  "BrowserAddPersonEnabled": false,
  "BrowserGuestModeEnabled": false,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "TranslateEnabled": false,
  "EditBookmarksEnabled": false,
  "BookmarkBarEnabled": false,
  "ShowHomeButton": false,
  "ExtensionInstallBlocklist": ["*"]
}
EOF
  cp /etc/chromium/policies/managed/kiosk_security_policy.json /etc/opt/chrome/policies/managed/kiosk_security_policy.json 2>/dev/null || true
  save_config_val "lockdown" "true"
  echo -e "${GREEN}Enterprise security policy applied! Only Home Assistant URLs are permitted.${NC}"
}

remove_security_policy() {
  require_root
  rm -f /etc/chromium/policies/managed/kiosk_security_policy.json /etc/opt/chrome/policies/managed/kiosk_security_policy.json 2>/dev/null || true
  save_config_val "lockdown" "false"
  echo -e "${YELLOW}Lockdown disabled: standard browsing allowed.${NC}"
}

update_from_github() {
  require_root
  echo -e "\n${CYAN}Checking for updates from GitHub (qwer8qaz8/rpi-kiosk-os)...${NC}"
  TMP_DIR=$(mktemp -d)
  if git clone --depth 1 "$REPO_URL" "$TMP_DIR" 2>/dev/null; then
    echo -e "${GREEN}Downloaded latest release.${NC}"
    cp -r "$TMP_DIR/kiosk/"* /opt/kiosk/
    cp "$TMP_DIR/kiosk-config.sh" /opt/kiosk/ 2>/dev/null || true
    cp "$TMP_DIR/systemd/"* /etc/systemd/system/
    chmod +x /opt/kiosk/*.sh /opt/kiosk/*.py /opt/kiosk/webui/*.py 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/local/bin/kiosk-config 2>/dev/null || true
    
    # Refresh security policies
    apply_security_policy
    
    systemctl daemon-reload
    systemctl enable kiosk-autoupdate.timer 2>/dev/null || true
    systemctl start kiosk-autoupdate.timer 2>/dev/null || true
    systemctl restart kiosk-webui 2>/dev/null || true
    systemctl restart kiosk-mqtt 2>/dev/null || true
    systemctl restart kiosk-display 2>/dev/null || true
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}${BOLD}Kiosk successfully updated to the latest version!${NC}\n"
  else
    echo -e "${RED}Failed to reach GitHub. Check your internet connection.${NC}"
    rm -rf "$TMP_DIR"
    return 1
  fi
}

generate_ha_snippet() {
  local pi_ip
  pi_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "192.168.1.XXX")
  local user_id
  user_id=$(load_config_val "kiosk_user_id" "<YOUR_HA_USER_ID>")
  
  echo -e "\n${CYAN}==================================================================${NC}"
  echo -e "${BOLD}Home Assistant configuration.yaml Snippet:${NC}"
  echo -e "${YELLOW}"
  cat << EOF
homeassistant:
  auth_providers:
    - type: homeassistant
    - type: trusted_networks
      trusted_networks:
        - ${pi_ip}/32
      trusted_users:
        ${pi_ip}: ${user_id}
      allow_bypass_login: true
EOF
  echo -e "${CYAN}==================================================================${NC}\n"
}

set_static_ip() {
  require_root
  local target_ip="$1"
  local gateway="${2:-}"
  local dns="${3:-1.1.1.1 8.8.8.8}"

  if [ -z "$gateway" ]; then
    gateway=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -n 1 || echo "192.168.86.1")
  fi

  echo -e "\n${CYAN}Configuring Static IP: ${BOLD}$target_ip${NC} (Gateway: $gateway)..."

  # NetworkManager (Debian Bookworm default)
  if command -v nmcli >/dev/null 2>&1; then
    local conn_name
    conn_name=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ -n "$conn_name" ]; then
      nmcli connection modify "$conn_name" \
        ipv4.addresses "$target_ip/24" \
        ipv4.gateway "$gateway" \
        ipv4.dns "$dns" \
        ipv4.method manual 2>/dev/null || true
      nmcli connection up "$conn_name" 2>/dev/null || true
      echo -e "${GREEN}Static IP configured via NetworkManager on [$conn_name].${NC}"
      generate_ha_snippet
      return 0
    fi
  fi

  # Fallback for dhcpcd.conf (Debian Bullseye / legacy)
  if [ -f /etc/dhcpcd.conf ]; then
    local iface
    iface=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n 1 || echo "eth0")
    cat << EOF >> /etc/dhcpcd.conf

# Static IP for Kiosk
interface $iface
static ip_address=$target_ip/24
static routers=$gateway
static domain_name_servers=$dns
EOF
    systemctl restart dhcpcd 2>/dev/null || true
    echo -e "${GREEN}Static IP configured in /etc/dhcpcd.conf.${NC}"
    generate_ha_snippet
    return 0
  fi

  echo -e "${YELLOW}Could not automatically configure static IP via nmcli or dhcpcd. Setting a DHCP reservation in your router is recommended.${NC}"
}

# Parse Command-Line Flags
ACTION_PERFORMED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      require_root
      save_config_val "dashboard_url" "$2"
      apply_security_policy
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}Dashboard URL updated to: $2${NC}"
      ACTION_PERFORMED=1
      shift 2
      ;;
    --kiosk-user-id)
      require_root
      save_config_val "kiosk_user_id" "$2"
      generate_ha_snippet
      ACTION_PERFORMED=1
      shift 2
      ;;
    --lockdown)
      require_root
      mode="${2:-on}"
      if [ "$mode" = "off" ] || [ "$mode" = "false" ] || [ "$mode" = "0" ]; then
        remove_security_policy
        if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      else
        apply_security_policy
        if [ "$mode" = "on" ] || [ "$mode" = "true" ] || [ "$mode" = "1" ]; then
          shift 2
        else
          shift
        fi
      fi
      systemctl restart kiosk-display 2>/dev/null || true
      ACTION_PERFORMED=1
      ;;
    --rotate)
      require_root
      /opt/kiosk/screen-control.sh rotate "$2"
      ACTION_PERFORMED=1
      shift 2
      ;;
    --brightness)
      require_root
      /opt/kiosk/screen-control.sh brightness "$2"
      ACTION_PERFORMED=1
      shift 2
      ;;
    --update)
      update_from_github
      ACTION_PERFORMED=1
      shift
      ;;
    --static-ip)
      require_root
      set_static_ip "$2" "$3"
      ACTION_PERFORMED=1
      shift 2
      ;;
    --snippet)
      generate_ha_snippet
      ACTION_PERFORMED=1
      shift
      ;;
    --reload)
      require_root
      systemctl restart kiosk-display
      echo -e "${GREEN}Kiosk reloaded!${NC}"
      ACTION_PERFORMED=1
      shift
      ;;
    --help|-h)
      echo "Raspberry Pi Kiosk Configuration Tool"
      echo "Usage: kiosk-config [flags]"
      echo ""
      echo "Flags:"
      echo "  --url <URL>            Change dashboard URL"
      echo "  --kiosk-user-id <ID>   Set Kiosk User ID and print HA snippet"
      echo "  --rotate <0|90|180|270> Rotate screen"
      echo "  --brightness <0-100>   Set backlight brightness percentage"
      echo "  --lockdown             Apply strict enterprise URL & shortcut lockdown"
      echo "  --static-ip <IP>       Set static IP address on this Raspberry Pi"
      echo "  --update               Check GitHub and update kiosk software"
      echo "  --snippet              Print Home Assistant trusted_networks YAML snippet"
      echo "  --reload               Restart kiosk browser display"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$ACTION_PERFORMED" -eq 1 ]; then
  exit 0
fi

# Interactive Menu Mode (if run without flags)
clear
echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "              Raspberry Pi Kiosk Configuration Menu               "
echo "=================================================================="
echo -e "${NC}"

echo "1) Change Dashboard URL"
echo "2) Configure Home Assistant Auto-Login (trusted_networks snippet)"
echo "3) Apply / Refresh Enterprise Security Lockdown"
echo "4) Adjust Screen Brightness (0-100%)"
echo "5) Rotate Display Orientation"
echo "6) Reload Kiosk Display"
echo "7) Check for Updates from GitHub"
echo "8) Set Static IP Address on Pi"
echo "9) Exit"
echo ""
read -r -p "Select an option [1-9]: " CHOICE

case "$CHOICE" in
  1)
    current_url=$(load_config_val "dashboard_url" "http://homeassistant.local:8123/lovelace/0?kiosk")
    read -r -p "Enter new Dashboard URL [$current_url]: " NEW_URL
    NEW_URL="${NEW_URL:-$current_url}"
    save_config_val "dashboard_url" "$NEW_URL"
    apply_security_policy
    sudo systemctl restart kiosk-display
    echo -e "${GREEN}URL updated and kiosk reloaded!${NC}"
    ;;
  2)
    current_uid=$(load_config_val "kiosk_user_id" "")
    read -r -p "Enter your Home Assistant Kiosk User ID [$current_uid]: " NEW_UID
    NEW_UID="${NEW_UID:-$current_uid}"
    save_config_val "kiosk_user_id" "$NEW_UID"
    generate_ha_snippet
    ;;
  3)
    apply_security_policy
    sudo systemctl restart kiosk-display
    ;;
  4)
    read -r -p "Enter brightness percentage (0 to 100): " B_VAL
    sudo /opt/kiosk/screen-control.sh brightness "$B_VAL"
    ;;
  5)
    echo "1) Normal (0°)"
    echo "2) Portrait (90°)"
    echo "3) Inverted (180°)"
    echo "4) Inverted Portrait (270°)"
    read -r -p "Select [1-4]: " R_CHOICE
    case "$R_CHOICE" in
      2) ROT="90" ;;
      3) ROT="180" ;;
      4) ROT="270" ;;
      *) ROT="normal" ;;
    esac
    sudo /opt/kiosk/screen-control.sh rotate "$ROT"
    ;;
  6)
    sudo systemctl restart kiosk-display
    echo -e "${GREEN}Kiosk display reloaded!${NC}"
    ;;
  7)
    update_from_github
    ;;
  8)
    cur_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    read -r -p "Enter desired static IP address [$cur_ip]: " S_IP
    S_IP="${S_IP:-$cur_ip}"
    set_static_ip "$S_IP"
    ;;
  *)
    echo "Exiting."
    ;;
esac
