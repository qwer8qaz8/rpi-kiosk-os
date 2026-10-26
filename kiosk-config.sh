#!/usr/bin/env bash
# ==============================================================================
# kiosk-config - Single-Purpose Home Assistant Kiosk Appliance Configuration Utility
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

ORIGINAL_ARGS=("$@")
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

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
data.pop('webui_pin', None)
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
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
    'homeassistant.local:8123',
    'http://homeassistant.local:8123',
    'https://homeassistant.local:8123',
    'umbrel.local:8123',
    'http://umbrel.local:8123',
    'https://umbrel.local:8123'
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

# Enterprise Single-Purpose Lockdown Policy for Chromium
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
  echo -e "${GREEN}Enterprise security policy applied across all browser policy paths! Only Home Assistant is permitted.${NC}"
}

remove_security_policy() {
  require_root
  rm -f /etc/chromium/policies/managed/kiosk_security_policy.json \
        /etc/chromium-browser/policies/managed/kiosk_security_policy.json \
        /etc/opt/chrome/policies/managed/kiosk_security_policy.json 2>/dev/null || true
  save_config_val "lockdown" "false"
  echo -e "${YELLOW}Lockdown disabled: standard browsing allowed.${NC}"
}

check_github_update() {
  local remote_head
  remote_head=$(git ls-remote "$REPO_URL" HEAD 2>/dev/null | awk '{print $1}')
  local current_commit=""
  if [ -f "/opt/kiosk/.git_commit" ]; then
    current_commit=$(cat /opt/kiosk/.git_commit 2>/dev/null || true)
  fi

  echo -e "${CYAN}=== KioskOS GitHub Update Status ===${NC}"
  echo -e "  • Current Local Commit: ${BOLD}${current_commit:-Unknown}${NC}"
  echo -e "  • Remote GitHub Commit: ${BOLD}${remote_head:-Unable to reach GitHub}${NC}"

  if [ -n "$remote_head" ] && [ -n "$current_commit" ] && [ "$remote_head" = "$current_commit" ]; then
    echo -e "${GREEN}✓ KioskOS is up to date! No update needed.${NC}"
    return 0
  elif [ -n "$remote_head" ]; then
    echo -e "${YELLOW}⚡ An update is available! Run 'kioskos update' to install it.${NC}"
    return 1
  else
    echo -e "${RED}Could not reach GitHub repository.${NC}"
    return 2
  fi
}

update_from_github() {
  require_root
  mkdir -p /var/log/kiosk 2>/dev/null || true
  chown root:adm /var/log/kiosk 2>/dev/null || true
  chmod 775 /var/log/kiosk 2>/dev/null || true
  local log_file="/var/log/kiosk/update.log"
  echo "=== Update check at $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$log_file"

  # 1. Check if remote HEAD commit matches current commit
  local remote_head
  remote_head=$(git ls-remote "$REPO_URL" HEAD 2>/dev/null | awk '{print $1}')
  local current_commit=""
  if [ -f "/opt/kiosk/.git_commit" ]; then
    current_commit=$(cat /opt/kiosk/.git_commit 2>/dev/null || true)
  fi

  if [ -n "$remote_head" ] && [ -n "$current_commit" ] && [ "$remote_head" = "$current_commit" ]; then
    echo "[$(date '+%H:%M:%S')] Already up to date at commit $current_commit" >> "$log_file"
    echo -e "${GREEN}✓ KioskOS is already at latest release ($current_commit). No update needed.${NC}"
    return 0
  fi

  echo -e "\n${CYAN}==================================================================${NC}"
  echo -e "${BOLD}Updating Home Assistant KioskOS from GitHub...${NC}"
  echo -e "Persistent logs written to: ${BOLD}$log_file${NC}"
  echo -e "${CYAN}==================================================================${NC}"

  TMP_DIR=$(mktemp -d)
  if git clone --depth 1 "$REPO_URL" "$TMP_DIR" >> "$log_file" 2>&1; then
    local new_commit
    new_commit=$(cd "$TMP_DIR" && git rev-parse HEAD 2>/dev/null || echo "$remote_head")
    echo "[$(date '+%H:%M:%S')] Downloaded latest release from GitHub (commit: $new_commit)" >> "$log_file"

    # Install any newly added dependencies silently
    apt-get update -y >> "$log_file" 2>&1 || true
    apt-get install -y --no-install-recommends gammastep ddcutil grim ffmpeg python3-gi gir1.2-gtk-3.0 avahi-daemon libnss-mdns avahi-utils >> "$log_file" 2>&1 || true

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

    # Clean up any obsolete WebUI remnants
    systemctl stop kiosk-webui 2>/dev/null || true
    systemctl disable kiosk-webui 2>/dev/null || true
    rm -f /etc/systemd/system/kiosk-webui.service 2>/dev/null || true
    rm -rf /opt/kiosk/webui 2>/dev/null || true

    # Record updated commit
    echo "$new_commit" > /opt/kiosk/.git_commit 2>/dev/null || true

    cp --remove-destination "$TMP_DIR/kiosk-config.sh" /opt/kiosk/ 2>/dev/null || true
    cp --remove-destination "$TMP_DIR/systemd/"* /etc/systemd/system/ 2>/dev/null || true
    chmod +x /opt/kiosk/*.sh /opt/kiosk/*.py 2>/dev/null || true
    ln -sf /opt/kiosk/kioskos /usr/local/bin/kioskos 2>/dev/null || true
    ln -sf /opt/kiosk/kioskos /usr/bin/kioskos 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/local/bin/kiosk-config 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/local/bin/kiosk 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/bin/kiosk-config 2>/dev/null || true
    ln -sf /opt/kiosk/kiosk-config.sh /usr/bin/kiosk 2>/dev/null || true

    # Deploy Bootsplash theme and update initramfs if splash changed
    if [ -f /opt/kiosk/splash.png ] && [ -d /usr/share/plymouth/themes/kioskos ]; then
      cp -f /opt/kiosk/splash.png /usr/share/plymouth/themes/kioskos/ 2>/dev/null || true
      if [ -x /usr/sbin/plymouth-set-default-theme ]; then
        /usr/sbin/plymouth-set-default-theme -R kioskos >> "$log_file" 2>&1 || true
      fi
    fi

    # Re-apply hardware performance profile
    if [ -x /opt/kiosk/hardware-profiles.py ]; then
      /opt/kiosk/hardware-profiles.py apply >> "$log_file" 2>&1 || true
    fi

    # Refresh security policies
    apply_security_policy >> "$log_file" 2>&1 || true
    
    systemctl daemon-reload >> "$log_file" 2>&1 || true
    systemctl restart kiosk-mqtt >> "$log_file" 2>&1 || true
    
    rm -rf "$TMP_DIR"
    echo "=== Update successfully completed at $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$log_file"
    echo -e "${GREEN}${BOLD}✓ Kiosk successfully updated! Reloading display (no reboot required)...${NC}\n"
    systemctl restart kiosk-display 2>/dev/null || true
    return 0
  else
    echo -e "${RED}Failed to reach GitHub. Check your internet connection.${NC}"
    echo "[$(date '+%H:%M:%S')] ERROR: Failed to clone $REPO_URL" >> "$log_file"
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

  # Fallback for dhcpcd.conf (legacy)
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

  echo -e "${YELLOW}Could not automatically configure static IP via nmcli or dhcpcd.${NC}"
}

# Handle Subcommands and CLI Options
if [ "$#" -gt 0 ]; then
  SUBCMD=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$SUBCMD" in
    update|--update)
      update_from_github
      exit 0
      ;;
    check-update|--check-update)
      check_github_update
      exit 0
      ;;
    hw|--hw|device|--device)
      python3 /opt/kiosk/hardware-profiles.py report 2>/dev/null || python3 "$SCRIPT_DIR/kiosk/hardware-profiles.py" report
      exit 0
      ;;
    profile|--profile)
      sub="${2:-list}"
      if [ "$sub" = "apply" ]; then
        require_root
        python3 /opt/kiosk/hardware-profiles.py apply "$3"
        systemctl restart kiosk-display
      else
        python3 /opt/kiosk/hardware-profiles.py list
      fi
      exit 0
      ;;
    backup|--backup)
      shift
      /opt/kiosk/backup-kiosk.sh "$@" 2>/dev/null || "$SCRIPT_DIR/kiosk/backup-kiosk.sh" "$@"
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
      echo -e "${CYAN}${BOLD}=== Kiosk Appliance Status ===${NC}"
      echo -e "Screen Power: $(/opt/kiosk/screen-control.sh status 2>/dev/null || echo 'ON')"
      echo -e "Brightness:   $(/opt/kiosk/screen-control.sh get_brightness 2>/dev/null || echo '100')%"
      echo -e "URL:          $(load_config_val "dashboard_url" "None")"
      echo -e "MQTT Client:  $(systemctl is-active kiosk-mqtt 2>/dev/null || echo "inactive")"
      if [ -f /etc/kiosk/hardware-info.json ]; then
        python3 -c "
import json
try:
    hw = json.load(open('/etc/kiosk/hardware-info.json'))
    print(f'Hardware:     {hw.get(\"device_model\")} ({hw.get(\"ram\", {}).get(\"total_gb\")} GB RAM)')
    print(f'Active Profile: {hw.get(\"profile_id\")}')
    print(f'Display:      {hw.get(\"display\", {}).get(\"resolution\")}')
except Exception: pass
" 2>/dev/null
      fi
      exit 0
      ;;
    reload|--reload)
      require_root
      systemctl restart kiosk-display
      echo -e "${GREEN}✓ Kiosk display reloaded!${NC}"
      exit 0
      ;;
    unlock|--unlock)
      require_root
      remove_security_policy
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Temporary unlock mode enabled!${NC}"
      exit 0
      ;;
    lock|--lock|lockdown|--lockdown)
      require_root
      apply_security_policy
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Lockdown applied!${NC}"
      exit 0
      ;;
    url|--url|-u)
      require_root
      clean_url="$2"
      if [ -z "$clean_url" ]; then
        read -r -p "Enter new Home Assistant URL: " clean_url
      fi
      if [[ "$clean_url" =~ ^https?:/[^/] ]]; then
        clean_url="${clean_url/:\//:\/\/}"
      fi
      save_config_val "dashboard_url" "$clean_url"
      apply_security_policy
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Dashboard URL updated to: $clean_url${NC}"
      exit 0
      ;;
    autologin|--autologin)
      require_root
      ha_user="$2"
      ha_pass="$3"
      if [ -z "$ha_user" ]; then
        echo -e "\n${CYAN}=== Configure Auto-Type Login Credentials ===${NC}"
        read -r -p "Home Assistant Username: " ha_user
        read -r -s -p "Home Assistant Password: " ha_pass
        echo ""
      fi
      save_config_val "ha_username" "$ha_user"
      save_config_val "ha_password" "$ha_pass"
      systemctl restart kiosk-display 2>/dev/null || true
      echo -e "${GREEN}✓ Auto-login credentials saved! Kiosk will now auto-type and log in.${NC}"
      exit 0
      ;;
    reboot|--reboot)
      require_root
      echo -e "${YELLOW}Manual reboot requested. Rebooting Raspberry Pi now...${NC}"
      reboot
      exit 0
      ;;
    help|--help|-h)
      echo "Raspberry Pi Home Assistant Kiosk Configuration Tool"
      echo "Usage: kiosk-config [command/flag]"
      echo ""
      echo "Commands:"
      echo "  url <URL>              Change Home Assistant dashboard URL"
      echo "  autologin [user] [pass] Set auto-login credentials for Home Assistant"
      echo "  hw                     Inspect hardware specs, screen resolution & profile"
      echo "  profile [list|apply]   Inspect or apply hardware optimization profiles"
      echo "  backup [create|list|restore] Backup or restore appliance configurations"
      echo "  update                 Check GitHub and cleanly update kiosk software"
      echo "  check-update           Check if an update is available without installing"
      echo "  rotate <0|90|180|270>  Rotate screen orientation"
      echo "  brightness <0-100>     Set backlight brightness level"
      echo "  on | off | toggle      Screen power control"
      echo "  lockdown               Apply strict Home Assistant lockdown"
      echo "  reload                 Restart kiosk browser display engine"
      echo "  status                 View appliance status"
      exit 0
      ;;
  esac
fi

# Interactive Menu Mode (if run without flags)
clear
echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "          Home Assistant Kiosk Appliance Configuration            "
echo "=================================================================="
echo -e "${NC}"

p_status=$(/opt/kiosk/screen-control.sh status 2>/dev/null || echo "ON")
b_status=$(/opt/kiosk/screen-control.sh get_brightness 2>/dev/null || echo "100")

echo "1) Change Home Assistant Dashboard URL"
echo "2) Set Auto-Login Credentials (Username & Password)"
echo "3) Hardware Diagnostics & Display Resolution Check"
echo "4) Apply / Switch Hardware Optimization Profile"
echo "5) Toggle Screen Power (Currently: $p_status)"
echo "6) Adjust Screen Brightness (Currently: ${b_status}%)"
echo "7) Rotate Display Orientation"
echo "8) Appliance Backup & Disaster Recovery"
echo "9) Check & Install GitHub Updates (No reboot required)"
echo "10) Set Static IP Address on Pi"
echo "11) Reload Kiosk Display"
echo "12) Exit"
echo ""
read -r -p "Select an option [1-12]: " CHOICE

case "$CHOICE" in
  1)
    current_url=$(load_config_val "dashboard_url" "http://homeassistant.local:8123/lovelace/0?kiosk")
    read -r -p "Enter new Dashboard URL [$current_url]: " NEW_URL
    NEW_URL="${NEW_URL:-$current_url}"
    save_config_val "dashboard_url" "$NEW_URL"
    apply_security_policy
    sudo systemctl restart kiosk-display
    echo -e "${GREEN}✓ URL updated and kiosk reloaded!${NC}"
    ;;
  2)
    echo -e "\n${CYAN}=== Auto-Login Credentials ===${NC}"
    read -r -p "Enter Home Assistant Username: " ha_user
    read -r -s -p "Enter Home Assistant Password: " ha_pass
    echo ""
    save_config_val "ha_username" "$ha_user"
    save_config_val "ha_password" "$ha_pass"
    sudo systemctl restart kiosk-display 2>/dev/null || true
    echo -e "${GREEN}✓ Auto-login credentials saved! Kiosk display will now auto-type and log in.${NC}"
    ;;
  3)
    python3 /opt/kiosk/hardware-profiles.py report 2>/dev/null || python3 "$SCRIPT_DIR/kiosk/hardware-profiles.py" report
    ;;
  4)
    python3 /opt/kiosk/hardware-profiles.py list 2>/dev/null || python3 "$SCRIPT_DIR/kiosk/hardware-profiles.py" list
    read -r -p "Enter profile ID to apply: " P_ID
    if [ -n "$P_ID" ]; then
      require_root
      python3 /opt/kiosk/hardware-profiles.py apply "$P_ID"
      systemctl restart kiosk-display
      echo -e "${GREEN}✓ Profile applied and display reloaded.${NC}"
    fi
    ;;
  5)
    /opt/kiosk/screen-control.sh toggle
    ;;
  6)
    read -r -p "Enter brightness percentage (1 to 100): " B_VAL
    /opt/kiosk/screen-control.sh brightness "$B_VAL"
    ;;
  7)
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
  8)
    echo "1) Create Sanitized Backup"
    echo "2) Create Full Backup (Includes Credentials)"
    echo "3) List Backups"
    echo "4) Restore from Backup"
    read -r -p "Select [1-4]: " B_OPT
    case "$B_OPT" in
      1) /opt/kiosk/backup-kiosk.sh create --sanitized ;;
      2) /opt/kiosk/backup-kiosk.sh create --full ;;
      3) /opt/kiosk/backup-kiosk.sh list ;;
      4)
        read -r -p "Enter path to backup archive: " RESTORE_PATH
        sudo /opt/kiosk/backup-kiosk.sh restore "$RESTORE_PATH"
        ;;
    esac
    ;;
  9)
    update_from_github
    ;;
  10)
    cur_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    read -r -p "Enter desired static IP address [$cur_ip]: " S_IP
    S_IP="${S_IP:-$cur_ip}"
    set_static_ip "$S_IP"
    ;;
  11)
    require_root
    systemctl restart kiosk-display
    echo -e "${GREEN}✓ Kiosk display reloaded!${NC}"
    ;;
  *)
    echo "Exiting."
    ;;
esac
