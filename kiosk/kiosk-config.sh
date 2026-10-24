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

ORIGINAL_ARGS=("$@")
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

CONFIG_FILE="/etc/kiosk/config.json"
REPO_URL="https://github.com/qwer8qaz8/rpi-kiosk-os.git"
RAW_URL="https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main"

# Root check helper - preserves original CLI arguments when re-executing with sudo
require_root() {
  if [ "$EUID" -ne 0 ]; then
    exec sudo -E bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
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

apply_preset() {
  require_root
  local preset="$1"
  local custom_target="$2"
  local url=""
  local name=""

  case "$preset" in
    ha|homeassistant)
      url="${custom_target:-http://homeassistant.local:8123/lovelace/0?kiosk}"
      name="Home Assistant"
      ;;
    magicmirror|mirror)
      url="${custom_target:-http://localhost:8080}"
      name="MagicMirror²"
      ;;
    grafana|metrics)
      url="${custom_target:-http://localhost:3000}"
      name="Grafana Dashboard"
      ;;
    klipper|mainsail|fluidd|3dprinter|octoprint)
      url="${custom_target:-http://localhost:7125}"
      name="3D Printer (Klipper / Mainsail / Fluidd)"
      ;;
    dakboard|calendar)
      url="${custom_target:-https://dakboard.com/app}"
      name="DAKboard / Family Calendar"
      ;;
    *)
      url="${custom_target:-http://homeassistant.local:8123/lovelace/0?kiosk}"
      name="Custom Application"
      ;;
  esac

  save_config_val "preset" "$preset"
  save_config_val "dashboard_url" "$url"
  apply_security_policy
  systemctl restart kiosk-display 2>/dev/null || true
  echo -e "${GREEN}Configured kiosk for: ${BOLD}$name${NC} ($url)"
}

apply_security_policy() {
  require_root
  python3 -c "
import json, os, urllib.parse

config_file = '$CONFIG_FILE'
policy_dirs = [
    '/etc/chromium/policies/managed',
    '/etc/chromium-browser/policies/managed',
    '/etc/opt/chrome/policies/managed'
]

allowed_list = [
    'localhost:8080',
    '127.0.0.1:8080',
    'homeassistant.local:8123',
    'http://localhost:8080',
    'http://127.0.0.1:8080',
    'http://homeassistant.local:8123'
]

dash_url = 'http://homeassistant.local:8123/lovelace/0?kiosk'

try:
    if os.path.exists(config_file):
        with open(config_file) as f:
            cfg = json.load(f)
            dash_url = cfg.get('dashboard_url', dash_url)
            for u in cfg.get('allowed_urls', []):
                u = u.strip()
                if u:
                    if '://' in u:
                        pu = urllib.parse.urlparse(u)
                        if pu.netloc:
                            allowed_list.append(pu.netloc)
                            allowed_list.append(f'{pu.scheme}://{pu.netloc}')
                    else:
                        allowed_list.append(u)
except Exception:
    pass

try:
    if dash_url.startswith('http:/') and not dash_url.startswith('http://'):
        dash_url = 'http://' + dash_url[6:]
    elif dash_url.startswith('https:/') and not dash_url.startswith('https://'):
        dash_url = 'https://' + dash_url[7:]
    p = urllib.parse.urlparse(dash_url)
    if p.netloc:
        allowed_list.append(p.netloc)
        allowed_list.append(f'{p.scheme}://{p.netloc}')
except Exception:
    pass

policy = {
    'URLBlocklist': ['*'],
    'URLAllowlist': list(set(allowed_list)),
    'DeveloperToolsAvailability': 2,
    'DefaultPopupsSetting': 2,
    'AllowFileSelectionDialogs': False,
    'DownloadRestrictions': 3,
    'IncognitoModeAvailability': 1,
    'PrintingEnabled': False,
    'BrowserAddPersonEnabled': False,
    'BrowserGuestModeEnabled': False,
    'PasswordManagerEnabled': False,
    'AutofillAddressEnabled': False,
    'AutofillCreditCardEnabled': False,
    'TranslateEnabled': False,
    'EditBookmarksEnabled': False,
    'BookmarkBarEnabled': False,
    'ShowHomeButton': False,
    'HomepageIsNewTabPage': False,
    'NewTabPageLocation': dash_url
}

for d in policy_dirs:
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'kiosk_security_policy.json'), 'w') as f:
            json.dump(policy, f, indent=2)
    except Exception as e:
        print(f'Error writing {d}: {e}')
"
  save_config_val "lockdown" "true"
  echo -e "${GREEN}Enterprise security policy applied across all browser policy paths! Only authorized URLs are permitted.${NC}"
}

remove_security_policy() {
  require_root
  rm -f /etc/chromium/policies/managed/kiosk_security_policy.json \
        /etc/chromium-browser/policies/managed/kiosk_security_policy.json \
        /etc/opt/chrome/policies/managed/kiosk_security_policy.json 2>/dev/null || true
  save_config_val "lockdown" "false"
  echo -e "${YELLOW}Lockdown disabled: standard browsing allowed.${NC}"
}

update_from_github() {
  require_root
  mkdir -p /var/log/kiosk 2>/dev/null || true
  chown root:adm /var/log/kiosk 2>/dev/null || true
  chmod 775 /var/log/kiosk 2>/dev/null || true
  local log_file="/var/log/kiosk/update.log"
  echo "=== Update started at $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$log_file"

  # Direct on-screen display to show pretty update splash screen
  curl -s -X POST http://127.0.0.1:8080/api/display/navigate -H "Content-Type: application/json" -d '{"url":"http://127.0.0.1:8080/updating"}' >/dev/null 2>&1 || true

  echo -e "\n${CYAN}==================================================================${NC}"
  echo -e "${BOLD}Updating Raspberry Pi Kiosk OS from GitHub...${NC}"
  echo -e "${YELLOW}Displaying updating splash screen on kiosk display.${NC}"
  echo -e "Detailed persistent logs written to: ${BOLD}$log_file${NC}"
  echo -e "${CYAN}==================================================================${NC}"

  TMP_DIR=$(mktemp -d)
  if git clone --depth 1 "$REPO_URL" "$TMP_DIR" >> "$log_file" 2>&1; then
    echo -e "${GREEN}✓ Downloaded latest release.${NC}"
    echo "[$(date '+%H:%M:%S')] Downloaded latest release from GitHub" >> "$log_file"

    # Install any newly added dependencies silently with logging
    apt-get update -y >> "$log_file" 2>&1 || true
    apt-get install -y --no-install-recommends gammastep ddcutil grim ffmpeg avahi-daemon libnss-mdns avahi-utils >> "$log_file" 2>&1 || true
    systemctl enable --now avahi-daemon >> "$log_file" 2>&1 || true

    # Back up persistent on-device config before copying updated files
    if [ -f /etc/kiosk/config.json ]; then
      cp -f /etc/kiosk/config.json /tmp/kiosk-config-backup.json 2>/dev/null || true
    fi

    # Sync files excluding config.json
    rsync -av --exclude 'config.json' "$TMP_DIR/kiosk/" /opt/kiosk/ 2>/dev/null || {
      cp --remove-destination -r "$TMP_DIR/kiosk/"* /opt/kiosk/
    }

    # Restore persistent on-device config
    if [ -f /tmp/kiosk-config-backup.json ]; then
      cp -f /tmp/kiosk-config-backup.json /etc/kiosk/config.json 2>/dev/null || true
      rm -f /tmp/kiosk-config-backup.json 2>/dev/null || true
    fi

    # Ensure system strictly returns to locked fullscreen kiosk mode (never admin mode)
    rm -f /tmp/kiosk-admin-workstation /tmp/kiosk-unlocked
    cp --remove-destination "$TMP_DIR/kiosk-config.sh" /opt/kiosk/ 2>/dev/null || true
    cp --remove-destination "$TMP_DIR/systemd/"* /etc/systemd/system/
    chmod +x /opt/kiosk/*.sh /opt/kiosk/*.py /opt/kiosk/webui/*.py 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/local/bin/kiosk-config 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/local/bin/kiosk 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/bin/kiosk-config 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/bin/kiosk 2>/dev/null || true

    # Create logrotate rule for /var/log/kiosk
    cat << 'EOF_LOGROTATE' > /etc/logrotate.d/kiosk
/var/log/kiosk/*.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
    create 0640 root adm
}
EOF_LOGROTATE
    
    # Refresh security policies
    apply_security_policy >> "$log_file" 2>&1
    
    systemctl daemon-reload >> "$log_file" 2>&1
    systemctl enable kiosk-autoupdate.timer >> "$log_file" 2>&1 || true
    systemctl start kiosk-autoupdate.timer >> "$log_file" 2>&1 || true
    systemctl restart kiosk-webui >> "$log_file" 2>&1 || true
    systemctl restart kiosk-mqtt >> "$log_file" 2>&1 || true
    
    rm -rf "$TMP_DIR"
    echo "=== Update successfully completed at $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$log_file"
    echo -e "${GREEN}${BOLD}✓ Kiosk successfully updated! Rebooting system to apply updates cleanly...${NC}\n"
    sleep 2
    systemctl reboot 2>/dev/null || reboot 2>/dev/null || true
    exit 0
  else
    echo -e "${RED}Failed to reach GitHub. Check your internet connection.${NC}"
    echo "[$(date '+%H:%M:%S')] ERROR: Failed to clone $REPO_URL" >> "$log_file"
    rm -rf "$TMP_DIR"
    systemctl restart kiosk-display 2>/dev/null || true
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
    gateway=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -n 1 || echo "192.168.1.1")
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

# Handle natural subcommands and CLI options (e.g. `kiosk update`, `kiosk url http://...`, `kiosk autologin ...`)
if [ "$#" -gt 0 ]; then
  SUBCMD=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$SUBCMD" in
    update|--update)
      update_from_github
      exit 0
      ;;
    on|off|toggle)
      /opt/kiosk/screen-control.sh "$SUBCMD"
      exit 0
      ;;
    brightness|--brightness)
      /opt/kiosk/screen-control.sh brightness "$2"
      exit 0
      ;;
    rotate|--rotate)
      /opt/kiosk/screen-control.sh rotate "$2"
      exit 0
      ;;
    status|--status)
      echo -e "${CYAN}${BOLD}=== Kiosk Status ===${NC}"
      echo -e "Screen Power: $(/opt/kiosk/screen-control.sh status)"
      echo -e "Brightness:   $(/opt/kiosk/screen-control.sh get_brightness)%"
      echo -e "URL:          $(load_config_val "dashboard_url" "None")"
      echo -e "Web UI (8080): $(systemctl is-active kiosk-webui 2>/dev/null || echo "inactive")"
      echo -e "MQTT Client:  $(systemctl is-active kiosk-mqtt 2>/dev/null || echo "inactive")"
      exit 0
      ;;
    reload|--reload)
      require_root
      systemctl restart kiosk-display
      echo -e "${GREEN}✓ Kiosk display reloaded! (Configured successfully!)${NC}"
      exit 0
      ;;
    unlock|--unlock)
      require_root
      remove_security_policy
      [ ! -f /tmp/kiosk-admin-workstation ] && systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Temporary unlock mode enabled! (Configured successfully!)${NC}"
      exit 0
      ;;
    lock|--lock|lockdown|--lockdown)
      require_root
      apply_security_policy
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Lockdown applied! (Configured successfully!)${NC}"
      exit 0
      ;;
    url|--url|-u)
      require_root
      clean_url="$2"
      if [ -z "$clean_url" ]; then
        read -r -p "Enter new dashboard URL: " clean_url
      fi
      if [[ "$clean_url" =~ ^https?:/[^/] ]]; then
        clean_url="${clean_url/:\//:\/\/}"
      fi
      save_config_val "dashboard_url" "$clean_url"
      apply_security_policy
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Dashboard URL updated to: $clean_url (Configured successfully!)${NC}"
      exit 0
      ;;
    autologin|--autologin)
      require_root
      ha_user="$2"
      ha_pass="$3"
      if [ -z "$ha_user" ] || [ -z "$ha_pass" ]; then
        echo -e "\n${CYAN}=== Configure Auto-Type Login Credentials ===${NC}"
        echo "The kiosk will automatically type these credentials whenever the Home Assistant login screen appears."
        read -r -p "Home Assistant Username: " ha_user
        read -r -s -p "Home Assistant Password: " ha_pass
        echo ""
      fi
      save_config_val "ha_username" "$ha_user"
      save_config_val "ha_password" "$ha_pass"
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Auto-login credentials saved! (Configured successfully!)${NC}"
      exit 0
      ;;
    reboot|--reboot)
      require_root
      echo -e "${YELLOW}Rebooting Raspberry Pi now...${NC}"
      reboot
      exit 0
      ;;
    preset|--preset)
      require_root
      apply_preset "$2" "${3:-}"
      exit 0
      ;;
    webui|--webui)
      require_root
      case "${2:-status}" in
        disable|off|stop)
          systemctl stop kiosk-webui 2>/dev/null || true
          systemctl disable kiosk-webui 2>/dev/null || true
          save_config_val "webui_enabled" "false"
          echo -e "${YELLOW}Web UI service (port 8080) disabled and stopped.${NC}"
          ;;
        enable|on|start)
          systemctl enable kiosk-webui 2>/dev/null || true
          systemctl start kiosk-webui 2>/dev/null || true
          save_config_val "webui_enabled" "true"
          echo -e "${GREEN}Web UI service (port 8080) enabled and started.${NC}"
          ;;
        status)
          systemctl status kiosk-webui --no-pager
          ;;
        *)
          echo "Usage: kiosk webui [enable|disable|status]"
          ;;
      esac
      exit 0
      ;;
  esac
fi

# Parse Command-Line Flags
ACTION_PERFORMED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      require_root
      preset_name="$2"
      preset_url="${3:-}"
      apply_preset "$preset_name" "$preset_url"
      ACTION_PERFORMED=1
      if [ -n "$preset_url" ]; then shift 3; else shift 2; fi
      ;;
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
      echo "  --preset <NAME> [URL]  Apply preset: ha, magicmirror, grafana, 3dprinter, dakboard, custom"
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

# If arguments were provided but none matched, exit with error instead of opening the menu
if [ "$#" -gt 0 ] || [ "${#ORIGINAL_ARGS[@]}" -gt 0 ]; then
  echo -e "${RED}Unknown command or option.${NC}"
  echo "Usage: kiosk [url <URL> | autologin | unlock | lock | on | off | brightness <1-100> | update | status]"
  exit 1
fi

# Interactive Menu Mode (if run without flags)
clear
echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "              Raspberry Pi Kiosk Configuration Menu               "
echo "=================================================================="
echo -e "${NC}"

p_status=$(/opt/kiosk/screen-control.sh status 2>/dev/null || echo "ON")
b_status=$(/opt/kiosk/screen-control.sh get_brightness 2>/dev/null || echo "100")
web_active=$(systemctl is-active kiosk-webui 2>/dev/null || echo "inactive")

echo "1) Choose Kiosk Preset (Home Assistant, MagicMirror², Grafana, 3D Printer, DAKboard, Custom)"
echo "2) Change Dashboard URL directly"
echo "3) Set Auto-Type Login Credentials (Automatically types Username & Password on screen)"
echo "4) Configure Home Assistant trusted_networks YAML snippet"
echo "5) Apply / Refresh Enterprise Security Lockdown"
echo "6) Toggle Screen Power (Currently: $p_status)"
echo "7) Adjust Screen Brightness (Currently: ${b_status}%)"
echo "8) Rotate Display Orientation"
echo "9) Toggle Web Dashboard Port 8080 (Currently: $web_active)"
echo "10) Reload Kiosk Display"
echo "11) Set Static IP Address on Pi"
echo "12) Check for Updates from GitHub"
echo "13) Exit"
echo ""
read -r -p "Select an option [1-13]: " CHOICE

case "$CHOICE" in
  1)
    echo ""
    echo "Select a Kiosk Preset:"
    echo "  1) Home Assistant (Default - Lovelace Dashboard)"
    echo "  2) MagicMirror² (Smart Mirror / Info Display)"
    echo "  3) Grafana Dashboard (Homelab / Solar / System Metrics)"
    echo "  4) 3D Printer Controller (Klipper Mainsail / Fluidd / OctoPrint)"
    echo "  5) DAKboard / Family Calendar"
    echo "  6) Custom Web Application"
    read -r -p "Choose [1-6, default 1]: " P_CHOICE
    case "$P_CHOICE" in
      2)
        read -r -p "Enter MagicMirror URL [http://localhost:8080]: " MM_URL
        apply_preset "magicmirror" "$MM_URL"
        ;;
      3)
        read -r -p "Enter Grafana URL [http://localhost:3000]: " G_URL
        apply_preset "grafana" "$G_URL"
        ;;
      4)
        read -r -p "Enter 3D Printer URL [http://localhost:7125]: " TP_URL
        apply_preset "3dprinter" "$TP_URL"
        ;;
      5)
        read -r -p "Enter DAKboard Screen URL [https://dakboard.com/app]: " DB_URL
        apply_preset "dakboard" "$DB_URL"
        ;;
      6)
        read -r -p "Enter Custom URL: " CUST_URL
        apply_preset "custom" "$CUST_URL"
        ;;
      *)
        read -r -p "Enter Home Assistant URL [http://homeassistant.local:8123/lovelace/0?kiosk]: " HA_CUSTOM_URL
        apply_preset "homeassistant" "$HA_CUSTOM_URL"
        ;;
    esac
    ;;
  2)
    current_url=$(load_config_val "dashboard_url" "http://homeassistant.local:8123/lovelace/0?kiosk")
    read -r -p "Enter new Dashboard URL [$current_url]: " NEW_URL
    NEW_URL="${NEW_URL:-$current_url}"
    save_config_val "dashboard_url" "$NEW_URL"
    apply_security_policy
    sudo systemctl restart kiosk-display
    echo -e "${GREEN}✓ URL updated and kiosk reloaded!${NC}"
    ;;
  3)
    echo -e "\n${CYAN}=== Auto-Type Login Credentials ===${NC}"
    echo "The kiosk will automatically type these credentials whenever the Home Assistant login screen appears."
    read -r -p "Enter Home Assistant Username: " ha_user
    read -r -s -p "Enter Home Assistant Password: " ha_pass
    echo ""
    save_config_val "ha_username" "$ha_user"
    save_config_val "ha_password" "$ha_pass"
    sudo systemctl restart kiosk-display 2>/dev/null || true
    echo -e "${GREEN}✓ Auto-login credentials saved! Kiosk display will now auto-type and log in.${NC}"
    ;;
  4)
    current_uid=$(load_config_val "kiosk_user_id" "")
    read -r -p "Enter your Home Assistant Kiosk User ID [$current_uid]: " NEW_UID
    NEW_UID="${NEW_UID:-$current_uid}"
    save_config_val "kiosk_user_id" "$NEW_UID"
    generate_ha_snippet
    ;;
  5)
    apply_security_policy
    sudo systemctl restart kiosk-display
    ;;
  6)
    /opt/kiosk/screen-control.sh toggle
    ;;
  7)
    read -r -p "Enter brightness percentage (1 to 100): " B_VAL
    /opt/kiosk/screen-control.sh brightness "$B_VAL"
    ;;
  8)
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
    /opt/kiosk/screen-control.sh rotate "$ROT"
    ;;
  9)
    if [ "$web_active" = "active" ]; then
      require_root
      systemctl stop kiosk-webui
      systemctl disable kiosk-webui
      echo -e "${YELLOW}Web UI service (port 8080) disabled and stopped.${NC}"
    else
      require_root
      systemctl enable kiosk-webui
      systemctl start kiosk-webui
      echo -e "${GREEN}Web UI service (port 8080) enabled and started!${NC}"
    fi
    ;;
  10)
    require_root
    systemctl restart kiosk-display
    echo -e "${GREEN}✓ Kiosk display reloaded!${NC}"
    ;;
  11)
    cur_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    read -r -p "Enter desired static IP address [$cur_ip]: " S_IP
    S_IP="${S_IP:-$cur_ip}"
    set_static_ip "$S_IP"
    ;;
  12)
    update_from_github
    ;;
  *)
    echo "Exiting."
    ;;
esac
