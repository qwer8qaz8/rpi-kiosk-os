#!/usr/bin/env bash
# ==============================================================================
# launch-kiosk.sh - Invoked by Cage Wayland compositor on boot
# ==============================================================================

set -eo pipefail

CONFIG_FILE="/etc/kiosk/config.json"
FALLBACK_CONFIG="/opt/kiosk/config.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve config file
if [ ! -f "$CONFIG_FILE" ] && [ -f "$FALLBACK_CONFIG" ]; then
  CONFIG_FILE="$FALLBACK_CONFIG"
fi

# Load settings from config.json using python3
DASHBOARD_URL=$(python3 -c "
import json
try:
    with open('$CONFIG_FILE') as f:
        url = json.load(f).get('dashboard_url', 'http://homeassistant.local:8123/lovelace/0?kiosk')
        if url.startswith('http:/') and not url.startswith('http://'):
            url = 'http://' + url[6:]
        elif url.startswith('https:/') and not url.startswith('https://'):
            url = 'https://' + url[7:]
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

echo "[kiosk] Starting kiosk environment..."
echo "[kiosk] Dashboard URL: $DASHBOARD_URL"

# If using a .local hostname (e.g. umbrel.local), ensure mDNS resolves
if [[ "$DASHBOARD_URL" =~ ([a-zA-Z0-9.-]+\.local) ]]; then
  mdns_host="${BASH_REMATCH[1]}"
  echo "[kiosk] Resolving $mdns_host via mDNS..."
  for attempt in 1 2 3; do
    if getent hosts "$mdns_host" >/dev/null 2>&1 || (command -v avahi-resolve >/dev/null 2>&1 && avahi-resolve -n -4 "$mdns_host" >/dev/null 2>&1); then
      echo "[kiosk] Successfully resolved $mdns_host via mDNS"
      break
    fi
    sleep 1
  done
fi

# Allow Wayland compositor to settle
sleep 1

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
  if [ -f "$CHROME_PROFILE_DIR/Default/Preferences" ]; then
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROME_PROFILE_DIR/Default/Preferences" 2>/dev/null || true
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROME_PROFILE_DIR/Default/Preferences" 2>/dev/null || true
  fi
fi

# Locate Chromium binary
CHROMIUM_BIN=""
for bin in chromium-browser chromium /usr/bin/chromium-browser /usr/bin/chromium; do
  if command -v "$bin" >/dev/null 2>&1; then
    CHROMIUM_BIN="$bin"
    break
  fi
done

if [ -z "$CHROMIUM_BIN" ]; then
  echo "[kiosk] ERROR: chromium-browser or chromium not found!" >&2
  exit 1
fi

echo "[kiosk] Using browser binary: $CHROMIUM_BIN"

# Create ramdisk cache directory to avoid wearing out SD card
mkdir -p /tmp/chromium-cache 2>/dev/null || true

# Extract allowed host from DASHBOARD_URL for enterprise URL lockdown
ALLOWED_HOST=$(python3 -c "
import urllib.parse
try:
    p = urllib.parse.urlparse('$DASHBOARD_URL')
    print(f'{p.scheme}://{p.netloc}/*')
except Exception:
    print('http://*:8123/*')
")

# Build enterprise security policy JSON across all standard Chromium paths
python3 -c "
import json, os, urllib.parse

config_file = '$CONFIG_FILE'
dash_url = '$DASHBOARD_URL'
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

try:
    if os.path.exists(config_file):
        with open(config_file) as f:
            cfg = json.load(f)
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
    except Exception:
        pass
" 2>/dev/null || true

# Load Auto-Login credentials from config if configured
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

EXTRA_CHROME_FLAGS=()
EXT_DIR="/tmp/kiosk-autologin-extension"
mkdir -p "$EXT_DIR"
cat << 'EOF_EXT_MANIFEST' > "$EXT_DIR/manifest.json"
{
  "manifest_version": 3,
  "name": "Kiosk Security and Auto-Login",
  "version": "1.0",
  "content_scripts": [
    {
      "matches": ["*://*/*"],
      "js": ["content.js"],
      "run_at": "document_start"
    }
  ]
}
EOF_EXT_MANIFEST

cat << EOF_EXT_JS > "$EXT_DIR/content.js"
// 1. Block keyboard shortcuts (Ctrl+T, Ctrl+N, Ctrl+W, F1-F12, zoom, etc.) and right-click
window.addEventListener('keydown', function(e) {
    if (e.ctrlKey || e.metaKey || e.altKey) {
        const key = e.key.toLowerCase();
        if (['t', 'n', 'w', 'o', 's', 'p', 'u', 'r', 'h', 'j', 'd', 'k', 'l', 'e', 'f', 'g', 'b', 'q'].includes(key) || e.key === 'Tab' || e.key === '-' || e.key === '=' || e.key === '+') {
            e.preventDefault();
            e.stopPropagation();
            return false;
        }
    }
    if (/^f[1-9][0-2]?$/i.test(e.key)) {
        e.preventDefault();
        e.stopPropagation();
        return false;
    }
}, true);

window.addEventListener('contextmenu', function(e) {
    e.preventDefault();
    e.stopPropagation();
    return false;
}, true);

// 2. Hide Home Assistant sidebar, drawer, hamburger menu button, and profile logout
function hideSidebarElements(root = document) {
    try {
        const targets = root.querySelectorAll('ha-sidebar, ha-menu-button, #drawer, ha-drawer, .mdc-drawer, [data-panel="profile"], .profile');
        for (const t of targets) {
            t.style.setProperty('display', 'none', 'important');
            t.style.setProperty('visibility', 'hidden', 'important');
            t.style.setProperty('width', '0px', 'important');
        }
        const all = root.querySelectorAll('*');
        for (const el of all) {
            if (el.shadowRoot) {
                hideSidebarElements(el.shadowRoot);
            }
        }
    } catch (e) {}
}

function injectKioskStyles() {
    if (!document.getElementById('rpi-kiosk-lockdown-style')) {
        const style = document.createElement('style');
        style.id = 'rpi-kiosk-lockdown-style';
        style.textContent = \`
            /* Remove sidebar, drawer, and hamburger menu button in Home Assistant */
            ha-sidebar, #drawer, ha-drawer, .mdc-drawer { display: none !important; width: 0 !important; visibility: hidden !important; }
            ha-menu-button { display: none !important; visibility: hidden !important; }
            .menu, [data-panel="profile"], .profile { display: none !important; }
            /* Disable text selection and dragging on physical touch screen */
            * { -webkit-user-select: none !important; user-select: none !important; -webkit-user-drag: none !important; }
            input, textarea { -webkit-user-select: text !important; user-select: text !important; }
        \`;
        if (document.head || document.documentElement) {
            (document.head || document.documentElement).appendChild(style);
        }
    }
    hideSidebarElements(document);
}
injectKioskStyles();
document.addEventListener('DOMContentLoaded', injectKioskStyles);

// 3. Shadow-DOM query helpers
function querySelectorDeep(selector, root = document) {
    let found = root.querySelector(selector);
    if (found) return found;
    const children = root.querySelectorAll('*');
    for (const child of children) {
        if (child.shadowRoot) {
            found = querySelectorDeep(selector, child.shadowRoot);
            if (found) return found;
        }
    }
    return null;
}

function queryAllDeep(selector, root = document) {
    let results = [];
    try {
        if (root.querySelectorAll) {
            results = Array.from(root.querySelectorAll(selector));
        }
        const children = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (const child of children) {
            if (child.shadowRoot) {
                results = results.concat(queryAllDeep(selector, child.shadowRoot));
            }
        }
    } catch (e) {}
    return results;
}

function setNativeValue(element, value) {
    const valueSetter = Object.getOwnPropertyDescriptor(element, 'value')?.set;
    const prototype = Object.getPrototypeOf(element);
    const prototypeValueSetter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    if (valueSetter && valueSetter !== prototypeValueSetter) {
        prototypeValueSetter.call(element, value);
    } else if (valueSetter) {
        valueSetter.call(element, value);
    } else {
        element.value = value;
    }
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
}

let loggedIn = false;
function tryAutoLogin() {
    if (loggedIn) return;
    injectKioskStyles();

    // Check for Trusted Networks user button (e.g. 'kiosk') and auto-click it
    const listItems = queryAllDeep('mwc-list-item, ha-card, [role="button"], button, paper-item, a, .user-list-item');
    for (const item of listItems) {
        const txt = (item.textContent || '').trim().toLowerCase();
        if (txt === 'kiosk' || txt.includes('kiosk') || txt.includes('trusted network')) {
            console.log('[Kiosk] Clicking trusted login option...');
            item.click();
            loggedIn = true;
            return;
        }
    }

    // Auto-type username & password if configured
    const autologinUser = '$AUTOLOGIN_USER';
    const autologinPass = '$AUTOLOGIN_PASS';
    if (autologinUser && autologinPass) {
        const userInput = querySelectorDeep('ha-credential-login input[name="username"]') || querySelectorDeep('input[name="username"]');
        const passInput = querySelectorDeep('ha-credential-login input[name="password"]') || querySelectorDeep('input[name="password"]');
        const submitBtn = querySelectorDeep('ha-credential-login mwc-button') || querySelectorDeep('button[type="submit"]') || querySelectorDeep('mwc-button');

        if (userInput && passInput && submitBtn) {
            if (userInput.value !== autologinUser) {
                console.log('[Kiosk] Auto-typing login credentials...');
                setNativeValue(userInput, autologinUser);
                setNativeValue(passInput, autologinPass);
                setTimeout(() => {
                    submitBtn.click();
                    loggedIn = true;
                    console.log('[Kiosk] Logged in successfully!');
                }, 300);
            }
        }
    }
}

const observer = new MutationObserver(() => tryAutoLogin());
observer.observe(document.documentElement, { childList: true, subtree: true });
setTimeout(tryAutoLogin, 500);
setTimeout(tryAutoLogin, 1500);
setTimeout(tryAutoLogin, 3000);
EOF_EXT_JS

EXTRA_CHROME_FLAGS+=("--load-extension=$EXT_DIR")

# Launch Chromium locked in Standalone Application Kiosk mode (--app disables tab strips and Ctrl+T shortcuts)
exec "$CHROMIUM_BIN" \
  "${EXTRA_CHROME_FLAGS[@]}" \
  --app="$DASHBOARD_URL" \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --check-for-update-interval=31536000 \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --enable-features=OverlayScrollbar \
  --disable-features=Translate,OptimizationHints,MediaRouter \
  --disable-session-crashed-bubble \
  --disable-context-menu \
  --disable-component-update \
  --disable-background-networking \
  --disable-domain-reliability \
  --disable-sync \
  --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required \
  --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' \
  --password-store=basic \
  --disk-cache-dir=/tmp/chromium-cache \
  --enable-gpu-rasterization \
  --enable-zero-copy
