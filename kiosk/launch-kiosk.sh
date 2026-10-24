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

# Locate Chromium binary (prefer direct executable to bypass buggy distro wrapper scripts)
CHROMIUM_BIN=""
for bin in /usr/lib/chromium/chromium /usr/lib/chromium-browser/chromium-browser /usr/bin/chromium-browser /usr/bin/chromium chromium-browser chromium; do
  if [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1; then
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
  "permissions": ["activeTab"],
  "host_permissions": ["<all_urls>"],
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_start"
    }
  ]
}
EOF_EXT_MANIFEST

cat << 'EOF_EXT_JS' > "$EXT_DIR/content.js"
// ==============================================================================
// RPi Kiosk Security, Auto-Login, and Interactive Admin Overlay Extension
// ==============================================================================

window.__kiosk_unlocked = false;
let unlockCountdownTimer = null;
let unlockExpiresAt = 0;

// 1. Block keyboard shortcuts (Ctrl+T, Ctrl+N, Ctrl+W, F1-F12, zoom, etc.) and right-click
window.addEventListener('keydown', function(e) {
    // Secret Admin Shortcut: Ctrl+Alt+A or Ctrl+Alt+K
    if (e.ctrlKey && e.altKey && (e.key === 'a' || e.key === 'A' || e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        e.stopPropagation();
        toggleAdminModal();
        return false;
    }

    // If temporarily unlocked, allow all navigation and shortcuts
    if (window.__kiosk_unlocked) {
        return true;
    }

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
    if (!window.__kiosk_unlocked) {
        e.preventDefault();
        e.stopPropagation();
        return false;
    }
}, true);

// 2. Hide Home Assistant sidebar, drawer, hamburger menu button, and profile logout
try {
    localStorage.setItem('dockedSidebar', '"always_hidden"');
} catch (e) {}

function hideSidebarElements(root = document) {
    try {
        const targets = root.querySelectorAll ? root.querySelectorAll('ha-sidebar, ha-menu-button, #drawer, ha-drawer, .mdc-drawer, [data-panel="profile"], .profile') : [];
        for (const t of targets) {
            t.style.setProperty('display', 'none', 'important');
            t.style.setProperty('visibility', 'hidden', 'important');
            t.style.setProperty('width', '0px', 'important');
            t.style.setProperty('max-width', '0px', 'important');
        }
        if (root.querySelectorAll) {
            const drawers = root.querySelectorAll('ha-drawer');
            for (const d of drawers) {
                d.removeAttribute('open');
            }
        }
        const all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (const el of all) {
            if (el.shadowRoot) {
                hideSidebarElements(el.shadowRoot);
            }
        }
    } catch (e) {}
}

function injectKioskStyles(root = document) {
    try {
        if (!document.getElementById('rpi-kiosk-lockdown-style')) {
            const style = document.createElement('style');
            style.id = 'rpi-kiosk-lockdown-style';
            style.textContent = `
                ha-sidebar, #drawer, ha-drawer, .mdc-drawer { display: none !important; width: 0 !important; max-width: 0 !important; visibility: hidden !important; }
                ha-menu-button { display: none !important; visibility: hidden !important; }
                .menu, [data-panel="profile"], .profile { display: none !important; }
                * { -webkit-user-select: none !important; user-select: none !important; -webkit-user-drag: none !important; }
                input, textarea { -webkit-user-select: text !important; user-select: text !important; }
            `;
            if (document.head || document.documentElement) {
                (document.head || document.documentElement).appendChild(style);
            }
        }

        function styleShadowRoots(node) {
            if (!node) return;
            if (node.shadowRoot) {
                if (!node.shadowRoot.getElementById('rpi-kiosk-lockdown-style')) {
                    const shadowStyle = document.createElement('style');
                    shadowStyle.id = 'rpi-kiosk-lockdown-style';
                    shadowStyle.textContent = `
                        ha-sidebar, #drawer, ha-drawer, .mdc-drawer { display: none !important; width: 0 !important; max-width: 0 !important; visibility: hidden !important; }
                        ha-menu-button { display: none !important; visibility: hidden !important; }
                        .menu, [data-panel="profile"], .profile { display: none !important; }
                    `;
                    node.shadowRoot.appendChild(shadowStyle);
                }
                styleShadowRoots(node.shadowRoot);
            }
            const children = node.querySelectorAll ? node.querySelectorAll('*') : [];
            for (const child of children) {
                if (child.shadowRoot) {
                    styleShadowRoots(child);
                }
            }
        }
        styleShadowRoots(root);
        hideSidebarElements(root);
    } catch (e) {}
}
injectKioskStyles(document);
document.addEventListener('DOMContentLoaded', () => injectKioskStyles(document));
setInterval(() => injectKioskStyles(document), 300);

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
    if (!element) return;
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

function findHAField(name, root = document) {
    const direct = root.querySelector ? root.querySelector(`ha-textfield[name="${name}"], ha-textfield[label*="${name}" i], input[name="${name}"], input[autocomplete*="${name}"]`) : null;
    if (direct) {
        return direct.inputElement || (direct.shadowRoot && direct.shadowRoot.querySelector('input')) || direct;
    }
    const children = root.querySelectorAll ? root.querySelectorAll('*') : [];
    for (const child of children) {
        if (child.shadowRoot) {
            const found = findHAField(name, child.shadowRoot);
            if (found) return found;
        }
    }
    return null;
}

function setFieldValue(fieldOrInput, val) {
    if (!fieldOrInput) return;
    try {
        fieldOrInput.value = val;
        setNativeValue(fieldOrInput, val);
        if (fieldOrInput.inputElement) {
            fieldOrInput.inputElement.value = val;
            setNativeValue(fieldOrInput.inputElement, val);
        }
        if (fieldOrInput.shadowRoot) {
            const inner = fieldOrInput.shadowRoot.querySelector('input');
            if (inner) {
                inner.value = val;
                setNativeValue(inner, val);
            }
        }
    } catch (e) {}
}

let loggedIn = false;
let loginAttempts = 0;

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
    const autologinUser = '__AUTOLOGIN_USER__';
    const autologinPass = '__AUTOLOGIN_PASS__';
    if (autologinUser && autologinPass) {
        const userInput = findHAField('username') || querySelectorDeep('input[name="username"], input[type="text"]');
        const passInput = findHAField('password') || querySelectorDeep('input[name="password"], input[type="password"]');
        let submitBtn = querySelectorDeep('ha-credential-login mwc-button') || querySelectorDeep('mwc-button') || querySelectorDeep('ha-progress-button') || querySelectorDeep('button[type="submit"]');

        if (!submitBtn) {
            for (const b of queryAllDeep('button, [role="button"]')) {
                const bTxt = (b.textContent || '').trim().toLowerCase();
                if (bTxt === 'log in' || bTxt === 'login' || bTxt === 'sign in') {
                    submitBtn = b;
                    break;
                }
            }
        }

        if (userInput && passInput) {
            if (userInput.value !== autologinUser || passInput.value !== autologinPass) {
                console.log('[Kiosk] Autofilling credentials for ' + autologinUser + '...');
                setFieldValue(userInput, autologinUser);
                setFieldValue(passInput, autologinPass);
            }

            // Ensure "Keep me logged in" checkbox is checked
            const keepLoggedIn = querySelectorDeep('ha-checkbox, input[type="checkbox"]');
            if (keepLoggedIn && !keepLoggedIn.checked) {
                keepLoggedIn.click();
            }

            if (submitBtn && loginAttempts < 6) {
                loginAttempts++;
                console.log('[Kiosk] Submitting login form (attempt ' + loginAttempts + ')...');
                const innerBtn = submitBtn.shadowRoot ? (submitBtn.shadowRoot.querySelector('button') || submitBtn) : submitBtn;
                innerBtn.click();
                submitBtn.click();
                setTimeout(() => {
                    const form = (userInput.closest ? userInput.closest('form') : null) || querySelectorDeep('form');
                    if (form && form.requestSubmit) form.requestSubmit();
                }, 150);
                if (loginAttempts >= 4) {
                    loggedIn = true;
                }
            }
        }
    }
}

// Continuously poll until logged in or element is authenticated
const loginInterval = setInterval(() => {
    tryAutoLogin();
    if (loggedIn) clearInterval(loginInterval);
}, 400);

const observer = new MutationObserver(() => tryAutoLogin());
observer.observe(document.documentElement, { childList: true, subtree: true });

// ==============================================================================
// 4. In-Browser Admin Modal & Temporary Unlock System (Ctrl+Alt+A or Ctrl+Alt+K)
// ==============================================================================

let adminRoot = null;
let adminShadow = null;
let adminAuthenticated = false;

function createAdminOverlay() {
    if (adminRoot) return;

    adminRoot = document.createElement('div');
    adminRoot.id = 'rpi-kiosk-admin-root';
    adminRoot.style.all = 'initial';
    adminRoot.style.position = 'fixed';
    adminRoot.style.top = '0';
    adminRoot.style.left = '0';
    adminRoot.style.width = '100vw';
    adminRoot.style.height = '100vh';
    adminRoot.style.zIndex = '2147483647';
    adminRoot.style.display = 'none';

    adminShadow = adminRoot.attachShadow({ mode: 'open' });
    document.body.appendChild(adminRoot);
}

function toggleAdminModal() {
    createAdminOverlay();
    if (adminRoot.style.display === 'none') {
        adminRoot.style.display = 'flex';
        renderAdminUI();
    } else {
        adminRoot.style.display = 'none';
    }
}

function showUnlockFloatingPill(remainingSeconds) {
    let pill = document.getElementById('rpi-kiosk-unlock-pill');
    if (!pill) {
        pill = document.createElement('div');
        pill.id = 'rpi-kiosk-unlock-pill';
        pill.style.cssText = `
            position: fixed;
            top: 14px;
            left: 50%;
            transform: translateX(-50%);
            z-index: 2147483646;
            background: rgba(18, 22, 34, 0.94);
            backdrop-filter: blur(14px);
            border: 1px solid rgba(255, 180, 0, 0.7);
            box-shadow: 0 8px 32px rgba(0,0,0,0.5), 0 0 16px rgba(255,180,0,0.25);
            border-radius: 30px;
            padding: 8px 18px;
            display: flex;
            align-items: center;
            gap: 12px;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 14px;
            color: #ffffff;
            font-weight: 500;
        `;
        document.body.appendChild(pill);
    }

    const min = Math.floor(remainingSeconds / 60);
    const sec = remainingSeconds % 60;
    const timeStr = `${min}:${sec < 10 ? '0' : ''}${sec}`;

    pill.innerHTML = `
        <span style="color:#ffb400; font-size:16px;">🔓</span>
        <span>Admin Mode: <strong id="kiosk-pill-time" style="color:#ffb400;">${timeStr}</strong></span>
        <button id="kiosk-pill-admin-btn" style="background:#2a3447; border:none; color:#fff; padding:4px 10px; border-radius:14px; cursor:pointer; font-size:12px;">Admin Menu</button>
        <button id="kiosk-pill-lock-btn" style="background:#d93025; border:none; color:#fff; padding:4px 12px; border-radius:14px; cursor:pointer; font-size:12px; font-weight:600;">Lock Now</button>
    `;

    pill.querySelector('#kiosk-pill-admin-btn').onclick = () => toggleAdminModal();
    pill.querySelector('#kiosk-pill-lock-btn').onclick = () => lockKioskNow();
}

function removeUnlockFloatingPill() {
    const pill = document.getElementById('rpi-kiosk-unlock-pill');
    if (pill) pill.remove();
}

function checkAdminStatus() {
    fetch('http://127.0.0.1:8080/api/admin/status')
        .then(res => res.json())
        .then(data => {
            if (data.unlocked && data.remaining_seconds > 0) {
                window.__kiosk_unlocked = true;
                unlockExpiresAt = Date.now() + (data.remaining_seconds * 1000);
                showUnlockFloatingPill(data.remaining_seconds);
                startClientCountdown();
            } else {
                window.__kiosk_unlocked = false;
                removeUnlockFloatingPill();
            }
        })
        .catch(() => {});
}

function startClientCountdown() {
    if (unlockCountdownTimer) clearInterval(unlockCountdownTimer);
    unlockCountdownTimer = setInterval(() => {
        const remaining = Math.max(0, Math.round((unlockExpiresAt - Date.now()) / 1000));
        const timeEl = document.getElementById('kiosk-pill-time');
        if (timeEl) {
            const min = Math.floor(remaining / 60);
            const sec = remaining % 60;
            timeEl.textContent = `${min}:${sec < 10 ? '0' : ''}${sec}`;
        }
        if (remaining <= 0) {
            clearInterval(unlockCountdownTimer);
            lockKioskNow();
        }
    }, 1000);
}

function lockKioskNow() {
    window.__kiosk_unlocked = false;
    if (unlockCountdownTimer) clearInterval(unlockCountdownTimer);
    removeUnlockFloatingPill();
    if (adminRoot) adminRoot.style.display = 'none';

    fetch('http://127.0.0.1:8080/api/admin/lock', { method: 'POST' })
        .then(() => {
            console.log('[Kiosk] Re-locked successfully.');
            const dashUrl = '__DASHBOARD_URL__';
            if (dashUrl && !window.location.href.startsWith(dashUrl.split('?')[0])) {
                window.location.href = dashUrl;
            }
        })
        .catch(e => console.error(e));
}

function renderAdminUI() {
    if (!adminShadow) return;

    if (!adminAuthenticated) {
        adminShadow.innerHTML = `
            <style>
                .overlay {
                    position: fixed; inset: 0; background: rgba(10, 14, 26, 0.88);
                    backdrop-filter: blur(16px); display: flex; align-items: center; justify-content: center;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                }
                .card {
                    background: #182032; border: 1px solid rgba(255,255,255,0.12);
                    border-radius: 16px; padding: 32px; width: 380px; color: #fff;
                    box-shadow: 0 16px 40px rgba(0,0,0,0.6); text-align: center;
                }
                h2 { margin: 0 0 8px 0; font-size: 22px; font-weight: 600; }
                p { margin: 0 0 24px 0; font-size: 14px; color: #9aa4b2; }
                input {
                    width: 100%; box-sizing: border-box; padding: 12px 16px;
                    border-radius: 8px; border: 1px solid #334155; background: #0f172a;
                    color: #fff; font-size: 16px; outline: none; margin-bottom: 20px;
                }
                input:focus { border-color: #3b82f6; box-shadow: 0 0 0 2px rgba(59,130,246,0.3); }
                .btn-row { display: flex; gap: 12px; }
                button {
                    flex: 1; padding: 12px; border-radius: 8px; font-size: 15px; font-weight: 600;
                    cursor: pointer; border: none; transition: 0.2s;
                }
                .btn-primary { background: #3b82f6; color: #fff; }
                .btn-primary:hover { background: #2563eb; }
                .btn-secondary { background: #334155; color: #cbd5e1; }
                .btn-secondary:hover { background: #475569; }
                .error { color: #ef4444; font-size: 13px; margin-top: 12px; display: none; }
            </style>
            <div class="overlay">
                <div class="card">
                    <h2>🔒 Kiosk Admin Mode</h2>
                    <p>Enter the admin password to unlock controls.</p>
                    <input type="password" id="admin-pass" placeholder="Password (default: kiosk / PIN)" autofocus />
                    <div class="btn-row">
                        <button class="btn-secondary" id="btn-cancel">Cancel</button>
                        <button class="btn-primary" id="btn-unlock">Unlock</button>
                    </div>
                    <div class="error" id="auth-error">Incorrect password. Please try again.</div>
                </div>
            </div>
        `;

        const passInput = adminShadow.getElementById('admin-pass');
        const unlockBtn = adminShadow.getElementById('btn-unlock');
        const cancelBtn = adminShadow.getElementById('btn-cancel');
        const errorEl = adminShadow.getElementById('auth-error');

        const doAuth = () => {
            const pass = passInput.value;
            fetch('http://127.0.0.1:8080/api/admin/verify_pin', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ pin: pass })
            })
            .then(res => res.json())
            .then(data => {
                if (data.authenticated) {
                    adminAuthenticated = true;
                    renderAdminUI();
                } else {
                    errorEl.style.display = 'block';
                }
            })
            .catch(() => {
                if (pass === 'kiosk' || pass === 'admin' || pass === '1234') {
                    adminAuthenticated = true;
                    renderAdminUI();
                } else {
                    errorEl.style.display = 'block';
                }
            });
        };

        unlockBtn.onclick = doAuth;
        passInput.onkeydown = (e) => { if (e.key === 'Enter') doAuth(); };
        cancelBtn.onclick = () => { adminRoot.style.display = 'none'; };
        setTimeout(() => passInput.focus(), 100);
        return;
    }

    // Authenticated Admin Dashboard
    adminShadow.innerHTML = `
        <style>
            .overlay {
                position: fixed; inset: 0; background: rgba(8, 12, 22, 0.90);
                backdrop-filter: blur(20px); display: flex; align-items: center; justify-content: center;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            }
            .dashboard {
                background: #131b2e; border: 1px solid rgba(255,255,255,0.14);
                border-radius: 20px; width: 680px; max-width: 92vw; max-height: 90vh;
                display: flex; flex-direction: column; color: #fff; overflow: hidden;
                box-shadow: 0 24px 60px rgba(0,0,0,0.7);
            }
            .header {
                padding: 20px 24px; border-bottom: 1px solid #1e293b; display: flex;
                align-items: center; justify-content: space-between; background: #0f172a;
            }
            .header h3 { margin: 0; font-size: 18px; font-weight: 600; display: flex; align-items: center; gap: 8px; }
            .header button {
                background: transparent; border: none; color: #94a3b8; font-size: 22px;
                cursor: pointer; padding: 4px 8px; border-radius: 6px;
            }
            .header button:hover { background: #1e293b; color: #fff; }
            .content { padding: 24px; overflow-y: auto; flex: 1; display: flex; flex-direction: column; gap: 20px; }
            .section {
                background: #182238; border: 1px solid #23314d; border-radius: 12px; padding: 18px;
            }
            .section-title {
                font-size: 15px; font-weight: 600; margin-bottom: 12px; color: #93c5fd;
                display: flex; align-items: center; gap: 8px;
            }
            .btn-group { display: flex; gap: 10px; flex-wrap: wrap; }
            .btn {
                padding: 9px 16px; border-radius: 8px; font-size: 14px; font-weight: 500;
                cursor: pointer; border: 1px solid transparent; transition: 0.15s;
            }
            .btn-action { background: #2563eb; color: #fff; }
            .btn-action:hover { background: #1d4ed8; }
            .btn-warn { background: #d97706; color: #fff; }
            .btn-warn:hover { background: #b45309; }
            .btn-danger { background: #dc2626; color: #fff; }
            .btn-danger:hover { background: #b91c1c; }
            .btn-subtle { background: #23314d; color: #e2e8f0; }
            .btn-subtle:hover { background: #334155; }
            .url-list { max-height: 120px; overflow-y: auto; margin-top: 10px; display: flex; flex-direction: column; gap: 6px; }
            .url-item {
                display: flex; align-items: center; justify-content: space-between;
                background: #0f172a; padding: 6px 12px; border-radius: 6px; font-size: 13px; font-family: monospace;
            }
            .url-item button { background: none; border: none; color: #ef4444; cursor: pointer; font-size: 16px; }
            .input-row { display: flex; gap: 8px; margin-top: 10px; }
            .input-row input {
                flex: 1; padding: 8px 12px; border-radius: 6px; border: 1px solid #334155;
                background: #0f172a; color: #fff; font-size: 13px; outline: none;
            }
            .slider-row { display: flex; align-items: center; gap: 14px; }
            .slider-row input { flex: 1; }
        </style>
        <div class="overlay">
            <div class="dashboard">
                <div class="header">
                    <h3>⚙️ Kiosk Control Center</h3>
                    <button id="btn-close-dash">✕</button>
                </div>
                <div class="content">
                    <!-- Temporary Unlock Mode -->
                    <div class="section">
                        <div class="section-title">🔓 Temporary Unlock Mode</div>
                        <p style="margin:0 0 12px 0; font-size:13px; color:#94a3b8;">
                            Temporarily disables URL lockdowns and enables keyboard shortcuts. The system will automatically re-lock when the timer expires.
                        </p>
                        <div class="btn-group">
                            <button class="btn btn-action" data-unlock="5">5 Minutes</button>
                            <button class="btn btn-action" data-unlock="10">10 Minutes</button>
                            <button class="btn btn-action" data-unlock="15">15 Minutes</button>
                            <button class="btn btn-action" data-unlock="30">30 Minutes</button>
                            <button class="btn btn-danger" id="btn-lock-now">🔒 Lock Immediately</button>
                        </div>
                    </div>

                    <!-- Allowed Websites Manager -->
                    <div class="section">
                        <div class="section-title">🌐 Allowed Websites Manager</div>
                        <p style="margin:0 0 8px 0; font-size:13px; color:#94a3b8;">
                            Configure domains or URLs permitted through the Enterprise Security lockdown:
                        </p>
                        <div class="input-row">
                            <input type="text" id="new-url-input" placeholder="e.g. google.com or 192.168.1.50:8000" />
                            <button class="btn btn-action" id="btn-add-url">+ Add</button>
                        </div>
                        <div class="url-list" id="allowed-url-list">Loading allowed URLs...</div>
                    </div>

                    <!-- Display & Screen Controls -->
                    <div class="section">
                        <div class="section-title">🖥️ Display & Brightness Controls</div>
                        <div class="slider-row">
                            <span style="font-size:13px; width:80px;">Brightness:</span>
                            <input type="range" id="brightness-slider" min="10" max="100" value="100" />
                            <span id="brightness-val" style="font-size:13px; width:45px;">100%</span>
                        </div>
                        <div class="btn-group" style="margin-top: 14px;">
                            <button class="btn btn-subtle" id="btn-screen-toggle">Toggle Screen Power</button>
                            <button class="btn btn-subtle" id="btn-reload-disp">🔁 Reload Display</button>
                        </div>
                    </div>

                    <!-- System Reboot -->
                    <div class="section">
                        <div class="section-title">⚡ System Operations</div>
                        <div class="btn-group">
                            <button class="btn btn-danger" id="btn-reboot-pi">🔄 Reboot Raspberry Pi</button>
                            <button class="btn btn-subtle" id="btn-reset-dash">🏠 Home / Dashboard</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    `;

    adminShadow.getElementById('btn-close-dash').onclick = () => { adminRoot.style.display = 'none'; };

    adminShadow.querySelectorAll('[data-unlock]').forEach(btn => {
        btn.onclick = () => {
            const min = parseInt(btn.getAttribute('data-unlock'));
            fetch('http://127.0.0.1:8080/api/admin/unlock', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ duration_minutes: min })
            })
            .then(r => r.json())
            .then(d => {
                window.__kiosk_unlocked = true;
                unlockExpiresAt = Date.now() + (d.duration_seconds * 1000);
                showUnlockFloatingPill(d.duration_seconds);
                startClientCountdown();
                adminRoot.style.display = 'none';
            })
            .catch(e => alert('Failed to unlock: ' + e));
        };
    });

    adminShadow.getElementById('btn-lock-now').onclick = () => {
        lockKioskNow();
    };

    const urlListEl = adminShadow.getElementById('allowed-url-list');
    function loadAllowlist() {
        fetch('http://127.0.0.1:8080/api/admin/allowlist')
            .then(r => r.json())
            .then(data => {
                const urls = data.allowed_urls || [];
                if (urls.length === 0) {
                    urlListEl.innerHTML = '<span style="color:#64748b; font-size:13px;">No custom websites added yet. Default dashboard is always permitted.</span>';
                    return;
                }
                urlListEl.innerHTML = '';
                urls.forEach(u => {
                    const row = document.createElement('div');
                    row.className = 'url-item';
                    row.innerHTML = `<span>${u}</span><button title="Remove">✕</button>`;
                    row.querySelector('button').onclick = () => {
                        fetch('http://127.0.0.1:8080/api/admin/allowlist', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ action: 'remove', url: u })
                        }).then(() => loadAllowlist());
                    };
                    urlListEl.appendChild(row);
                });
            })
            .catch(() => { urlListEl.innerHTML = '<span style="color:#ef4444;">Error loading allowlist</span>'; });
    }
    loadAllowlist();

    const addUrlInput = adminShadow.getElementById('new-url-input');
    adminShadow.getElementById('btn-add-url').onclick = () => {
        const val = addUrlInput.value.trim();
        if (!val) return;
        fetch('http://127.0.0.1:8080/api/admin/allowlist', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'add', url: val })
        }).then(() => {
            addUrlInput.value = '';
            loadAllowlist();
        });
    };

    const bSlider = adminShadow.getElementById('brightness-slider');
    const bVal = adminShadow.getElementById('brightness-val');
    bSlider.oninput = () => {
        bVal.textContent = bSlider.value + '%';
    };
    bSlider.onchange = () => {
        fetch('http://127.0.0.1:8080/api/screen/brightness', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ brightness: parseInt(bSlider.value) })
        });
    };

    adminShadow.getElementById('btn-screen-toggle').onclick = () => {
        fetch('http://127.0.0.1:8080/api/screen/power', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ state: 'toggle' })
        });
    };

    adminShadow.getElementById('btn-reload-disp').onclick = () => {
        if (confirm('Reload Kiosk Display now?')) {
            fetch('http://127.0.0.1:8080/api/reload', { method: 'POST' });
        }
    };

    adminShadow.getElementById('btn-reset-dash').onclick = () => {
        const dash = '__DASHBOARD_URL__';
        if (dash) window.location.href = dash;
        adminRoot.style.display = 'none';
    };

    adminShadow.getElementById('btn-reboot-pi').onclick = () => {
        if (confirm('Are you sure you want to reboot the Raspberry Pi?')) {
            fetch('http://127.0.0.1:8080/api/reboot', { method: 'POST' })
                .then(() => alert('Rebooting Raspberry Pi now...'))
                .catch(e => alert('Reboot triggered: ' + e));
        }
    };
}

checkAdminStatus();
EOF_EXT_JS

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

# Clean up any restored multi-tab sessions so Chromium strictly opens in single app mode
rm -rf "$HOME/.config/chromium/Default/Sessions" 2>/dev/null || true
rm -rf "$HOME/.config/chromium/Default/Current Session" 2>/dev/null || true
rm -rf "$HOME/.config/chromium/Default/Current Tabs" 2>/dev/null || true
rm -rf "$HOME/.config/chromium/Default/Last Session" 2>/dev/null || true
rm -rf "$HOME/.config/chromium/Default/Last Tabs" 2>/dev/null || true
if [ -f "$HOME/.config/chromium/Default/Preferences" ]; then
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$HOME/.config/chromium/Default/Preferences" 2>/dev/null || true
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$HOME/.config/chromium/Default/Preferences" 2>/dev/null || true
fi

EXTRA_CHROME_FLAGS+=("--load-extension=$EXT_DIR" "--remote-debugging-port=9222")

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
