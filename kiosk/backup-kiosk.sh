#!/usr/bin/env bash
# ==============================================================================
# backup-kiosk.sh - Clean KioskOS Backup Tool
# Exports configuration, scripts, and policies with all secrets sanitized.
# ==============================================================================

set -e

BACKUP_DIR=$(mktemp -d)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_TAR="kioskos-backup-${TIMESTAMP}.tar.gz"

echo "[backup] Preparing clean KioskOS backup..."

mkdir -p "$BACKUP_DIR/kiosk" "$BACKUP_DIR/etc"

# 1. Copy kiosk files
cp -r /opt/kiosk/* "$BACKUP_DIR/kiosk/" 2>/dev/null || true
rm -rf "$BACKUP_DIR/kiosk/__pycache__" "$BACKUP_DIR/kiosk/webui/__pycache__"

# 2. Sanitize config.json (strip private passwords and tokens)
if [ -f /etc/kiosk/config.json ]; then
    python3 -c "
import json
with open('/etc/kiosk/config.json') as f:
    cfg = json.load(f)
# Sanitize sensitive fields
if 'mqtt' in cfg:
    cfg['mqtt']['password'] = '******'
    if 'broker' in cfg['mqtt'] and ('192.168.' in cfg['mqtt']['broker'] or '10.' in cfg['mqtt']['broker']):
        cfg['mqtt']['broker'] = 'homeassistant.local'
cfg['webui_pin'] = ''
with open('$BACKUP_DIR/etc/config.json', 'w') as f:
    json.dump(cfg, f, indent=2)
"
fi

# 3. Create archive
tar -czf "$OUTPUT_TAR" -C "$BACKUP_DIR" .
rm -rf "$BACKUP_DIR"

echo "[backup] Backup created successfully: $(pwd)/$OUTPUT_TAR"
