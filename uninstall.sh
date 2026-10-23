#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh - Clean Uninstaller for Raspberry Pi Kiosk
# ==============================================================================
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "              Raspberry Pi Kiosk Uninstaller                      "
echo "=================================================================="
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Root privileges required. Re-running with sudo...${NC}"
  if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "/bin/bash" ] && [ "$0" != "/usr/bin/bash" ] && [ "$0" != "-bash" ]; then
    exec sudo -E bash "$0" "$@"
  else
    exec sudo -E bash -c "$(curl -sSL https://raw.githubusercontent.com/qwer8qaz8/rpi-kiosk-os/main/uninstall.sh)"
  fi
fi

read -r -p "Are you sure you want to completely uninstall the Kiosk environment? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Uninstallation cancelled."
  exit 0
fi

echo -e "\n${GREEN}[1/5] Stopping and disabling systemd services...${NC}"
for svc in kiosk-display kiosk-mqtt kiosk-webui; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/${svc}.service"
done

systemctl daemon-reload

echo -e "${GREEN}[2/5] Removing kiosk application files...${NC}"
rm -rf /opt/kiosk

read -r -p "Do you want to delete stored configurations in /etc/kiosk? [y/N]: " DEL_CONFIG
if [[ "$DEL_CONFIG" =~ ^[Yy]$ ]]; then
  rm -rf /etc/kiosk
  echo "Removed /etc/kiosk"
fi

echo -e "${GREEN}[3/5] Removing sudoers rules and udev backlight rules...${NC}"
rm -f /etc/sudoers.d/kiosk
rm -f /etc/udev/rules.d/99-kiosk-backlight.rules
udevadm control --reload-rules 2>/dev/null || true

echo -e "${GREEN}[4/5] Restoring standard getty on TTY1...${NC}"
systemctl enable getty@tty1.service 2>/dev/null || true
systemctl start getty@tty1.service 2>/dev/null || true

echo -e "${GREEN}[5/5] Uninstallation Complete!${NC}"
echo -e "Cage and Chromium packages were preserved. If you wish to remove them, run:"
echo -e "  ${BOLD}sudo apt-get remove --purge cage chromium-browser wlr-randr${NC}"
echo -e "\nA system reboot is recommended: ${BOLD}sudo reboot${NC}\n"
