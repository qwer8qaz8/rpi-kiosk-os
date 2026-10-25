#!/usr/bin/env bash
# ==============================================================================
# launch-kiosk.sh - Home Assistant Kiosk Appliance Launcher & Supervisor
# Ultra-lightweight, hardware-accelerated, single-purpose Wayland kiosk.
# ==============================================================================

set +e
set -o pipefail

# Ensure single supervisor instance runs at a time
LOCKFILE="/tmp/launch-kiosk.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "[kiosk] Another launch-kiosk supervisor is already running, exiting cleanly."; exit 0; }

CONFIG_FILE="/etc/kiosk/config.json"
FALLBACK_CONFIG="/opt/kiosk/config.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve config file
if [ ! -f "$CONFIG_FILE" ] && [ -f "$FALLBACK_CONFIG" ]; then
  CONFIG_FILE="$FALLBACK_CONFIG"
fi

# Load settings from config.json
DASHBOARD_URL=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        url = json.load(f).get('dashboard_url', 'http://homeassistant.local:8123/lovelace/0?kiosk')
        if url.startswith('http:/') and not url.startswith('http://'):
            url = 'http://' + url[6:]
        elif url.startswith('https:/') and not url.startswith('https://'):
            url = 'https://' + url[7:]
        if 'kiosk' not in url.lower():
            sep = '&' if '?' in url else '?'
            url = url + sep + 'kiosk'
        print(url)
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

AUTOLOGIN_USER=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f).get('ha_username', ''))
except Exception:
    print('')
")

AUTOLOGIN_PASS=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        print(json.load(f).get('ha_password', ''))
except Exception:
    print('')
")

echo "[ha-kiosk] Starting Home Assistant Kiosk Appliance..."
echo "[ha-kiosk] Dashboard Target: $DASHBOARD_URL"

# Play Startup Audio Chime (async)
if [ -x "$SCRIPT_DIR/play-chime.sh" ] && [ ! -f "/tmp/kiosk-chime-played" ]; then
    touch "/tmp/kiosk-chime-played"
    "$SCRIPT_DIR/play-chime.sh" boot &
fi

# Dismiss early boot splash cleanly
if command -v plymouth >/dev/null 2>&1; then
    plymouth --quit 2>/dev/null || true
fi

# If using a .local hostname (e.g. homeassistant.local), ensure mDNS resolves
if [[ "$DASHBOARD_URL" =~ ([a-zA-Z0-9.-]+\.local) ]]; then
  mdns_host="${BASH_REMATCH[1]}"
  echo "[ha-kiosk] Resolving $mdns_host via mDNS..."
  for attempt in 1 2 3; do
    if getent hosts "$mdns_host" >/dev/null 2>&1 || (command -v avahi-resolve >/dev/null 2>&1 && avahi-resolve -n -4 "$mdns_host" >/dev/null 2>&1); then
      echo "[ha-kiosk] Successfully resolved $mdns_host via mDNS"
      break
    fi
    sleep 1
  done
fi

# Allow Wayland compositor to settle
sleep 0.5

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
  rm -rf "$CHROME_PROFILE_DIR/Default/Sessions" 2>/dev/null || true
  rm -rf "$CHROME_PROFILE_DIR/Default/Current Session" 2>/dev/null || true
  rm -rf "$CHROME_PROFILE_DIR/Default/Current Tabs" 2>/dev/null || true
  if [ -f "$CHROME_PROFILE_DIR/Default/Preferences" ]; then
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROME_PROFILE_DIR/Default/Preferences" 2>/dev/null || true
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROME_PROFILE_DIR/Default/Preferences" 2>/dev/null || true
  fi
fi

# Locate Chromium binary
CHROMIUM_BIN=""
for bin in /usr/lib/chromium/chromium /usr/lib/chromium-browser/chromium-browser /usr/bin/chromium-browser /usr/bin/chromium chromium-browser chromium; do
  if [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1; then
    CHROMIUM_BIN="$bin"
    break
  fi
done

if [ -z "$CHROMIUM_BIN" ]; then
  echo "[ha-kiosk] ERROR: Chromium binary not found!" >&2
  exit 1
fi

# Create ramdisk cache directory
mkdir -p /tmp/chromium-cache 2>/dev/null || true

# Generate Lean Single-Window & Auto-Login Extension
EXT_DIR="/tmp/kiosk-extension"
rm -rf "$EXT_DIR"
mkdir -p "$EXT_DIR"

cat << 'EOF_MANIFEST' > "$EXT_DIR/manifest.json"
{
  "manifest_version": 3,
  "name": "HA Kiosk Lock",
  "version": "2.0",
  "content_scripts": [
    {
      "matches": ["*://*/*"],
      "js": ["content.js"],
      "run_at": "document_start"
    }
  ]
}
EOF_MANIFEST

cat << 'EOF_JS' > "$EXT_DIR/content.js"
// ==============================================================================
// HA Kiosk Appliance Guard - Single-Window & Keyboard Lockdown
// ==============================================================================

// 1. Single Window Enforcement: Prevent popups or external windows
try {
  window.open = function(url) {
    if (url) window.location.href = url;
    return window;
  };
} catch(e) {}

document.addEventListener('click', function(e) {
  const a = e.target && e.target.closest ? e.target.closest('a') : null;
  if (a && a.target && a.target !== '_self') {
    a.target = '_self';
  }
}, true);

// 2. Strict Keyboard Shortcut Lockdown (Allow only F5 and Ctrl+R for refresh)
window.addEventListener('keydown', function(e) {
  const k = e.key.toLowerCase();
  
  // Allow normal refresh: F5 or Ctrl+R
  if (e.key === 'F5' || (e.ctrlKey && k === 'r')) {
    return;
  }

  // Block Chrome Task Manager
  if (e.shiftKey && (e.key === 'Escape' || e.keyCode === 27)) {
    e.preventDefault();
    e.stopPropagation();
    return false;
  }

  // Block DevTools (F12, Ctrl+Shift+I, Ctrl+Shift+J, Ctrl+Shift+C)
  if (e.key === 'F12' || (e.ctrlKey && e.shiftKey && (k === 'i' || k === 'j' || k === 'c'))) {
    e.preventDefault();
    e.stopPropagation();
    return false;
  }

  // Block Window & Tab management (Ctrl+T, Ctrl+N, Ctrl+W, Ctrl+O, Ctrl+S, Ctrl+P, Ctrl+H, Ctrl+J, Ctrl+U, Ctrl+D)
  if (e.ctrlKey && ['t', 'n', 'w', 'o', 's', 'p', 'h', 'j', 'u', 'd', 'b'].includes(k)) {
    e.preventDefault();
    e.stopPropagation();
    return false;
  }

  // Block Back/Forward history navigation via Alt+Arrow
  if (e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
    e.preventDefault();
    e.stopPropagation();
    return false;
  }
}, true);

// 3. Fallback Offline Page Redirection
if (window.location.href.startsWith('chrome-error://')) {
  window.location.replace('file:///opt/kiosk/offline.html?url=' + encodeURIComponent('__DASHBOARD_URL__'));
}

// Deep Shadow DOM Finder Helper
function findInShadow(root, selector) {
  if (!root) return null;
  try {
    const el = root.querySelector ? root.querySelector(selector) : null;
    if (el) return el;
    const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    for (const child of all) {
      if (child.shadowRoot) {
        const found = findInShadow(child.shadowRoot, selector);
        if (found) return found;
      }
    }
  } catch(e) {}
  return null;
}

// 4. Home Assistant Auto-Login (Shadow DOM Capable)
const HA_USER = '__AUTOLOGIN_USER__';
const HA_PASS = '__AUTOLOGIN_PASS__';

function attemptHaLogin() {
  if (!HA_USER || !HA_PASS) return;

  // 1) Check for User selection button (Trusted Networks auth flow)
  const userItems = document.querySelectorAll ? document.querySelectorAll('mwc-list-item, [role="button"]') : [];
  for (const item of userItems) {
    if (item.textContent && item.textContent.trim().toLowerCase() === HA_USER.toLowerCase()) {
      item.click();
      return;
    }
  }

  // 2) Check for Username and Password fields inside Shadow DOM
  const userField = findInShadow(document, 'input[name="username"]') || findInShadow(document, 'input[autocomplete="username"]');
  const passField = findInShadow(document, 'input[name="password"]') || findInShadow(document, 'input[type="password"]');

  if (userField && passField && !userField.value) {
    userField.value = HA_USER;
    userField.dispatchEvent(new Event('input', { bubbles: true }));
    userField.dispatchEvent(new Event('change', { bubbles: true }));

    passField.value = HA_PASS;
    passField.dispatchEvent(new Event('input', { bubbles: true }));
    passField.dispatchEvent(new Event('change', { bubbles: true }));

    const stayCheck = findInShadow(document, 'input[type="checkbox"]');
    if (stayCheck && !stayCheck.checked) stayCheck.click();

    setTimeout(() => {
      const submitBtn = findInShadow(document, 'button[type="submit"]') ||
                        findInShadow(document, 'mwc-button') ||
                        findInShadow(document, 'ha-progress-button');
      if (submitBtn) submitBtn.click();
    }, 250);
  }
}

// 5. Hide Sandwich & Sidebar Menu Permanently across all Shadow DOM levels
function hideSandwich() {
  const styles = `
    ha-menu-button,
    [slot="navigationIcon"],
    mwc-icon-button[slot="navigationIcon"],
    paper-icon-button[slot="navigationIcon"],
    ha-icon-button[slot="navigationIcon"],
    ha-sidebar,
    .mdc-drawer,
    ha-drawer > [slot="drawer"] {
      display: none !important;
      visibility: hidden !important;
      width: 0 !important;
      height: 0 !important;
      max-width: 0 !important;
      opacity: 0 !important;
      pointer-events: none !important;
    }
  `;

  function injectCSS(root) {
    if (!root) return;
    try {
      if (root.getElementById && !root.getElementById('ha-kiosk-hide-sandwich')) {
        const s = document.createElement('style');
        s.id = 'ha-kiosk-hide-sandwich';
        s.textContent = styles;
        root.appendChild(s);
      }
      const menuButtons = root.querySelectorAll ? root.querySelectorAll('ha-menu-button, [slot="navigationIcon"], ha-sidebar') : [];
      menuButtons.forEach(btn => {
        btn.style.setProperty('display', 'none', 'important');
        btn.style.setProperty('visibility', 'hidden', 'important');
      });
    } catch(e) {}
  }

  function recurseShadows(root) {
    if (!root) return;
    injectCSS(root);
    try {
      const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
      for (const el of all) {
        if (el.shadowRoot) recurseShadows(el.shadowRoot);
      }
    } catch(e) {}
  }

  recurseShadows(document);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => {
    setTimeout(attemptHaLogin, 500);
    hideSandwich();
  });
} else {
  setTimeout(attemptHaLogin, 500);
  hideSandwich();
}
window.addEventListener('load', () => {
  hideSandwich();
  setTimeout(attemptHaLogin, 1000);
});
setInterval(hideSandwich, 1500);
setInterval(attemptHaLogin, 3000);
EOF_JS

if [ -n "$AUTOLOGIN_USER" ]; then
    sed -i "s/__AUTOLOGIN_USER__/$AUTOLOGIN_USER/g" "$EXT_DIR/content.js"
else
    sed -i "s/__AUTOLOGIN_USER__//g" "$EXT_DIR/content.js"
fi

if [ -n "$AUTOLOGIN_PASS" ]; then
    sed -i "s/__AUTOLOGIN_PASS__/$AUTOLOGIN_PASS/g" "$EXT_DIR/content.js"
else
    sed -i "s/__AUTOLOGIN_PASS__//g" "$EXT_DIR/content.js"
fi

sed -i "s|__DASHBOARD_URL__|$DASHBOARD_URL|g" "$EXT_DIR/content.js"

# Launch Hardware-Accelerated Native GTK3 Splash Screen on Wayland (only on initial boot)
if [ -f "/opt/kiosk/kiosk-native-splash.py" ] && [ ! -f "/tmp/kiosk-boot-splash-done" ]; then
    touch "/tmp/kiosk-boot-splash-done"
    echo "[ha-kiosk] Displaying Native GTK3 Splash Screen..."
    python3 /opt/kiosk/kiosk-native-splash.py "$DASHBOARD_URL" || true
fi

# Clean up any duplicate chromium instances before supervisor begins
killall -9 chromium chromium-browser 2>/dev/null || true
sleep 0.5

# Persistent supervisor loop: keeps single-purpose fullscreen Chromium alive permanently
while true; do
    # Check if target HA is reachable, otherwise use branded offline screen with auto-retry
    TARGET_LAUNCH_URL="$DASHBOARD_URL"
    if ! curl -s -m 2 -o /dev/null -w "%{http_code}" "$DASHBOARD_URL" 2>/dev/null | grep -q '^[23]'; then
        TARGET_LAUNCH_URL="file:///opt/kiosk/offline.html?url=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$DASHBOARD_URL'''))" 2>/dev/null || echo "$DASHBOARD_URL")"
    fi

    echo "[ha-kiosk] Launching Fullscreen Single-Purpose Chromium ($TARGET_LAUNCH_URL)..."
    "$CHROMIUM_BIN" \
      --ozone-platform=wayland \
      --remote-debugging-port=9222 \
      --remote-allow-origins=* \
      --load-extension="$EXT_DIR" \
      --kiosk \
      --app="$TARGET_LAUNCH_URL" \
      --start-fullscreen \
      --noerrdialogs \
      --disable-infobars \
      --no-first-run \
      --password-store=basic \
      --disk-cache-dir=/tmp/chromium-cache \
      --enable-gpu-rasterization \
      --enable-zero-copy \
      --check-for-update-interval=31536000 \
      --disable-pinch \
      --overscroll-history-navigation=0 \
      --disable-features=Translate,OptimizationHints,MediaRouter \
      --disable-session-crashed-bubble \
      --disable-context-menu \
      --disable-component-update \
      --disable-domain-reliability \
      --no-default-browser-check \
      --autoplay-policy=no-user-gesture-required \
      --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' &
    
    CHROME_PID=$!

    # Background Watchdog to redirect any Chrome error page to branded offline.html
    (
      while kill -0 "$CHROME_PID" 2>/dev/null; do
        sleep 3
        if command -v curl >/dev/null 2>&1; then
          tab_info=$(curl -s http://127.0.0.1:9222/json 2>/dev/null || true)
          if echo "$tab_info" | grep -q "chrome-error://"; then
            echo "[ha-kiosk] Chrome error detected, navigating to offline screen..."
            encoded_url=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$DASHBOARD_URL'''))" 2>/dev/null || echo "$DASHBOARD_URL")
            curl -s "http://127.0.0.1:9222/json/new?file:///opt/kiosk/offline.html?url=$encoded_url" >/dev/null 2>&1 || true
          fi
        fi
      done
    ) &

    wait "$CHROME_PID" 2>/dev/null || true
    sleep 1
done
