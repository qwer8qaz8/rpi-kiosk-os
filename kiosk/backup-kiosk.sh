#!/usr/bin/env bash
# ==============================================================================
# backup-kiosk.sh - KioskOS Appliance Backup & Recovery Tool
# Supports full and sanitized backups, listing, and automated recovery.
# ==============================================================================

set -eo pipefail

BACKUP_STORAGE_DIR="/var/backups/kiosk"
mkdir -p "$BACKUP_STORAGE_DIR" 2>/dev/null || BACKUP_STORAGE_DIR="/tmp/kiosk-backups"
mkdir -p "$BACKUP_STORAGE_DIR" 2>/dev/null || true

CONFIG_FILE="/etc/kiosk/config.json"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/opt/kiosk/config.json"

BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m"

cmd="${1:-create}"

case "$cmd" in
  create|backup)
    mode="sanitized"
    out_file=""

    shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --full)
          mode="full"
          shift
          ;;
        --sanitized)
          mode="sanitized"
          shift
          ;;
        --out|-o)
          out_file="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    if [ -z "$out_file" ]; then
      out_file="${BACKUP_STORAGE_DIR}/kioskos-backup-${mode}-${TIMESTAMP}.tar.gz"
    fi

    echo -e "${CYAN}[backup] Generating ${mode} KioskOS backup...${NC}"
    STAGING_DIR=$(mktemp -d)

    mkdir -p "$STAGING_DIR/opt_kiosk" "$STAGING_DIR/etc_kiosk" "$STAGING_DIR/systemd"

    # 1. Copy /opt/kiosk (excluding cache, sockets, lock files)
    if [ -d /opt/kiosk ]; then
      rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '*.lock' --exclude '.git' /opt/kiosk/ "$STAGING_DIR/opt_kiosk/" 2>/dev/null || {
        cp -r /opt/kiosk/* "$STAGING_DIR/opt_kiosk/" 2>/dev/null || true
      }
    fi

    # 2. Copy /etc/kiosk
    if [ -d /etc/kiosk ]; then
      cp -r /etc/kiosk/* "$STAGING_DIR/etc_kiosk/" 2>/dev/null || true
    elif [ -f /opt/kiosk/config.json ]; then
      cp /opt/kiosk/config.json "$STAGING_DIR/etc_kiosk/" 2>/dev/null || true
    fi

    # 3. Copy systemd kiosk units
    cp -f /etc/systemd/system/kiosk-* "$STAGING_DIR/systemd/" 2>/dev/null || true

    # 4. If sanitized mode, strip passwords and sensitive secrets
    if [ "$mode" = "sanitized" ] && [ -f "$STAGING_DIR/etc_kiosk/config.json" ]; then
      python3 -c "
import json
p = '$STAGING_DIR/etc_kiosk/config.json'
try:
    with open(p, 'r') as f:
        cfg = json.load(f)
    if 'ha_password' in cfg:
        cfg['ha_password'] = '******'
    if 'mqtt' in cfg and isinstance(cfg['mqtt'], dict):
        if 'password' in cfg['mqtt']:
            cfg['mqtt']['password'] = '******'
        if 'broker' in cfg['mqtt'] and ('192.168.' in str(cfg['mqtt']['broker']) or '10.' in str(cfg['mqtt']['broker'])):
            cfg['mqtt']['broker'] = 'homeassistant.local'
    cfg.pop('webui_pin', None)
    with open(p, 'w') as f:
        json.dump(cfg, f, indent=2)
except Exception as e:
    print('Warning sanitizing config:', e)
" 2>/dev/null || true
    fi

    # 5. Pack archive
    mkdir -p "$(dirname "$out_file")"
    tar -czf "$out_file" -C "$STAGING_DIR" .
    rm -rf "$STAGING_DIR"

    FILE_SIZE=$(du -h "$out_file" | awk '{print $1}')
    echo -e "${GREEN}✓ KioskOS backup created successfully!${NC}"
    echo -e "  • File: ${BOLD}${out_file}${NC} (${FILE_SIZE})"
    if [ "$mode" = "full" ]; then
      echo -e "  • Mode: ${mode} (Passwords preserved)"
    else
      echo -e "  • Mode: ${mode} (Passwords sanitized)"
    fi
    ;;

  list)
    echo -e "\n${BOLD}=== Available KioskOS Backups ===${NC}"
    found=0
    for dir in "$BACKUP_STORAGE_DIR" "/tmp" "."; do
      if [ -d "$dir" ]; then
        for f in "$dir"/kioskos-backup-*.tar.gz; do
          if [ -f "$f" ]; then
            found=1
            size=$(du -h "$f" | awk '{print $1}')
            mtime=$(date -r "$f" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1 || echo "Unknown")
            echo -e "  • ${CYAN}$(basename "$f")${NC} (${size}) - Modified: $mtime"
            echo -e "    Path: ${BOLD}$f${NC}"
          fi
        done
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo -e "${YELLOW}  No existing KioskOS backups found in ${BACKUP_STORAGE_DIR}.${NC}"
    fi
    echo ""
    ;;

  restore)
    tar_path="$2"
    if [ -z "$tar_path" ] || [ ! -f "$tar_path" ]; then
      echo -e "${RED}Error:${NC} Backup file not found. Usage: backup-kiosk.sh restore <path_to_backup.tar.gz>"
      exit 1
    fi

    echo -e "${CYAN}[restore] Validating backup archive: $tar_path...${NC}"
    if ! tar -tzf "$tar_path" >/dev/null 2>&1; then
      echo -e "${RED}Error:${NC} Archive corrupted or not a valid gzip tarball."
      exit 1
    fi

    EXTRACT_DIR=$(mktemp -d)
    tar -xzf "$tar_path" -C "$EXTRACT_DIR"

    echo -e "${CYAN}[restore] Restoring KioskOS files...${NC}"
    if [ -d "$EXTRACT_DIR/etc_kiosk" ]; then
      mkdir -p /etc/kiosk
      cp -r "$EXTRACT_DIR/etc_kiosk/"* /etc/kiosk/ 2>/dev/null || true
    fi

    if [ -d "$EXTRACT_DIR/opt_kiosk" ]; then
      mkdir -p /opt/kiosk
      cp -r "$EXTRACT_DIR/opt_kiosk/"* /opt/kiosk/ 2>/dev/null || true
      chmod +x /opt/kiosk/*.sh /opt/kiosk/*.py 2>/dev/null || true
    fi

    if [ -d "$EXTRACT_DIR/systemd" ]; then
      cp -f "$EXTRACT_DIR/systemd/"* /etc/systemd/system/ 2>/dev/null || true
      systemctl daemon-reload 2>/dev/null || true
    fi

    rm -rf "$EXTRACT_DIR"

    # Re-apply hardware profile for this device
    if [ -x /opt/kiosk/hardware-profiles.py ]; then
      /opt/kiosk/hardware-profiles.py apply 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ KioskOS backup restored successfully!${NC}"
    echo -e "Reloading display compositor..."
    systemctl restart kiosk-display 2>/dev/null || true
    ;;

  *)
    echo "Usage: backup-kiosk.sh [create [--sanitized|--full] [--out <file>] | list | restore <file>]"
    ;;
esac
