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

# Check if Admin Workstation mode is active
if [ -f "/tmp/kiosk-admin-workstation" ]; then
    echo "[kiosk] Admin Workstation Mode active: removing lockdown policies..."
    rm -f /etc/chromium/policies/managed/kiosk_security_policy.json \
          /etc/chromium-browser/policies/managed/kiosk_security_policy.json \
          /etc/opt/chrome/policies/managed/kiosk_security_policy.json 2>/dev/null || true
else
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
fi

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
let currentAdminToken = null;
let adminInactivityTimer = null;

function resetAdminInactivity() {
    if (adminInactivityTimer) clearTimeout(adminInactivityTimer);
    if (adminRoot && adminRoot.style.display !== 'none') {
        adminInactivityTimer = setTimeout(() => {
            console.log('[Kiosk Security] Admin auto-logout due to 60s inactivity.');
            adminAuthenticated = false;
            currentAdminToken = null;
            if (adminRoot) adminRoot.style.display = 'none';
        }, 60000); // 60 seconds auto-logout
    }
}

let secretListenMode = false;
let secretBuffer = '';
let secretListenTimer = null;
let secretIndicatorEl = null;

function showCornerIndicator(status = 'listening', extra = '') {
    if (!secretIndicatorEl) {
        secretIndicatorEl = document.createElement('div');
        secretIndicatorEl.id = 'rpi-kiosk-secret-indicator';
        secretIndicatorEl.style.cssText = `
            position: fixed;
            top: 14px;
            right: 14px;
            z-index: 2147483647;
            padding: 8px 16px;
            border-radius: 20px;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 13px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
            box-shadow: 0 4px 25px rgba(0,0,0,0.7);
            transition: all 0.15s ease;
            pointer-events: none;
            user-select: none;
        `;
        document.body.appendChild(secretIndicatorEl);
    }

    if (status === 'listening') {
        secretIndicatorEl.style.background = 'rgba(15, 23, 42, 0.95)';
        secretIndicatorEl.style.border = '1px solid #38bdf8';
        secretIndicatorEl.style.color = '#38bdf8';
        const displayPrompt = extra ? extra : 'type Kiosk';
        secretIndicatorEl.innerHTML = `<span style="display:inline-block; width:10px; height:10px; border-radius:50%; background:#38bdf8; box-shadow:0 0 10px #38bdf8;"></span><span>● Listening [${displayPrompt}]</span>`;
    } else if (status === 'success') {
        secretIndicatorEl.style.background = 'rgba(6, 78, 59, 0.96)';
        secretIndicatorEl.style.border = '1px solid #34d399';
        secretIndicatorEl.style.color = '#34d399';
        secretIndicatorEl.innerHTML = '<span style="display:inline-block; width:10px; height:10px; border-radius:50%; background:#34d399; box-shadow:0 0 10px #34d399;"></span><span>✓ Unlocking...</span>';
    } else if (status === 'error') {
        secretIndicatorEl.style.background = 'rgba(127, 29, 29, 0.96)';
        secretIndicatorEl.style.border = '1px solid #f87171';
        secretIndicatorEl.style.color = '#f87171';
        secretIndicatorEl.innerHTML = '<span style="display:inline-block; width:10px; height:10px; border-radius:50%; background:#f87171; box-shadow:0 0 10px #f87171;"></span><span>✕ Cancelled</span>';
    }
    secretIndicatorEl.style.display = 'flex';
}

function hideCornerIndicator() {
    if (secretIndicatorEl) {
        secretIndicatorEl.style.display = 'none';
    }
    secretListenMode = false;
    secretBuffer = '';
    if (secretListenTimer) clearTimeout(secretListenTimer);
}

let passwordModalEl = null;

function openPasswordModal() {
    hideCornerIndicator();
    if (!passwordModalEl) {
        passwordModalEl = document.createElement('div');
        passwordModalEl.id = 'rpi-kiosk-password-modal';
        passwordModalEl.style.cssText = `
            position: fixed; inset: 0; z-index: 2147483647;
            background: rgba(10, 14, 26, 0.88);
            backdrop-filter: blur(25px) saturate(180%);
            -webkit-backdrop-filter: blur(25px) saturate(180%);
            display: flex; align-items: center; justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
        `;
        document.body.appendChild(passwordModalEl);
    }

    passwordModalEl.innerHTML = `
        <div style="background: rgba(24, 32, 47, 0.95); border: 1px solid rgba(255,255,255,0.16); border-radius: 18px; width: 380px; max-width: 92vw; padding: 32px 28px; box-shadow: 0 24px 60px rgba(0,0,0,0.8), 0 0 0 1px rgba(255,255,255,0.08); text-align: center; color: #fff;">
            <div style="font-size: 36px; margin-bottom: 12px;">🔒</div>
            <h2 style="font-size: 20px; font-weight: 700; margin: 0 0 6px 0; letter-spacing: -0.3px;">Administrator Authentication</h2>
            <p style="font-size: 13px; color: #94a3b8; margin: 0 0 20px 0; line-height: 1.4;">Enter your administrator password or PIN to unlock macOS Admin Workstation.</p>
            <input type="password" id="kiosk-auth-input" placeholder="Password or PIN" autofocus style="width: 100%; box-sizing: border-box; padding: 12px 14px; border-radius: 10px; border: 1px solid #334155; background: #0f172a; color: #fff; font-size: 15px; outline: none; margin-bottom: 14px;" />
            <div id="kiosk-auth-error" style="color: #f87171; font-size: 12px; margin-bottom: 12px; display: none;"></div>
            <div style="display: flex; gap: 10px;">
                <button id="kiosk-auth-cancel" style="flex: 1; padding: 10px; border-radius: 8px; border: 1px solid #334155; background: #1e293b; color: #cbd5e1; font-size: 13px; font-weight: 600; cursor: pointer;">Cancel (Esc)</button>
                <button id="kiosk-auth-submit" style="flex: 1; padding: 10px; border-radius: 8px; border: none; background: #2563eb; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer;">Unlock (Enter)</button>
            </div>
            <div style="margin-top: 14px; font-size: 11px; color: #64748b;">KioskOS Enterprise Security</div>
        </div>
    `;

    passwordModalEl.style.display = 'flex';
    const input = passwordModalEl.querySelector('#kiosk-auth-input');
    const submitBtn = passwordModalEl.querySelector('#kiosk-auth-submit');
    const cancelBtn = passwordModalEl.querySelector('#kiosk-auth-cancel');
    const errBox = passwordModalEl.querySelector('#kiosk-auth-error');

    const doSubmit = () => {
        const val = input.value.trim();
        if (!val) return;
        errBox.style.display = 'none';
        submitBtn.textContent = 'Verifying...';
        submitBtn.disabled = true;

        fetch('http://127.0.0.1:8080/api/admin/verify_pin', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ pin: val })
        })
        .then(r => r.json())
        .then(data => {
            if (data.authenticated || data.success) {
                submitBtn.textContent = '✓ Unlocking...';
                submitBtn.style.background = '#10b981';
                const token = data.admin_token || '';
                fetch('http://127.0.0.1:8080/api/admin/enable_workstation', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'Authorization': 'Bearer ' + token
                    }
                })
                .then(() => {
                    // Password modal closes; start-desktop.sh replaces fullscreen kiosk with real native macOS desktop
                    if (passwordModalEl) passwordModalEl.style.display = 'none';
                })
                .catch(() => {
                    if (passwordModalEl) passwordModalEl.style.display = 'none';
                });
            } else {
                submitBtn.textContent = 'Unlock (Enter)';
                submitBtn.disabled = false;
                errBox.textContent = data.error || 'Incorrect password. Please try again.';
                errBox.style.display = 'block';
                input.value = '';
                input.focus();
            }
        })
        .catch(() => {
            submitBtn.textContent = 'Unlock (Enter)';
            submitBtn.disabled = false;
            errBox.textContent = 'Connection error. Retrying...';
            errBox.style.display = 'block';
        });
    };

    submitBtn.onclick = doSubmit;
    cancelBtn.onclick = () => { passwordModalEl.style.display = 'none'; };
    input.onkeydown = (e) => {
        if (e.key === 'Enter') doSubmit();
        if (e.key === 'Escape') passwordModalEl.style.display = 'none';
    };
    setTimeout(() => input.focus(), 60);
}

let exitHoldTimer = null;
let exitHoldStart = 0;
let exitHoldInterval = null;
let exitHoldOverlayEl = null;
let exitCountdownTimer = null;
let exitCountdownModalEl = null;

function showExitHoldOverlay(progress) {
    if (!exitHoldOverlayEl) {
        exitHoldOverlayEl = document.createElement('div');
        exitHoldOverlayEl.id = 'kiosk-exit-hold-overlay';
        exitHoldOverlayEl.style.cssText = `
            position: fixed; top: 20px; left: 50%; transform: translateX(-50%);
            z-index: 2147483647; background: rgba(15, 23, 42, 0.95);
            border: 1px solid rgba(239, 68, 68, 0.4); border-radius: 16px;
            padding: 14px 24px; display: flex; flex-direction: column; align-items: center;
            box-shadow: 0 10px 30px rgba(0,0,0,0.8), 0 0 20px rgba(239, 68, 68, 0.3);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            color: #fff; min-width: 320px;
        `;
        document.body.appendChild(exitHoldOverlayEl);
    }
    exitHoldOverlayEl.style.display = 'flex';
    exitHoldOverlayEl.innerHTML = `
        <div style="font-size: 13px; font-weight: 700; color: #f87171; margin-bottom: 6px; letter-spacing: 0.5px;">
            🔒 Exit to Kiosk Mode
        </div>
        <div style="font-size: 12px; color: #cbd5e1; margin-bottom: 8px;">
            Keep holding to exit immediately...
        </div>
        <div style="width: 100%; height: 6px; background: rgba(255,255,255,0.1); border-radius: 6px; overflow: hidden;">
            <div style="width: ${progress}%; height: 100%; background: linear-gradient(90deg, #ef4444, #f87171); border-radius: 6px; transition: width 0.08s linear;"></div>
        </div>
    `;
}

function hideExitHoldOverlay() {
    if (exitHoldOverlayEl) exitHoldOverlayEl.style.display = 'none';
    if (exitHoldInterval) clearInterval(exitHoldInterval);
    if (exitHoldTimer) clearTimeout(exitHoldTimer);
    exitHoldInterval = null;
    exitHoldTimer = null;
    exitHoldStart = 0;
}

function showExitCountdownDialog() {
    hideExitHoldOverlay();
    if (!exitCountdownModalEl) {
        exitCountdownModalEl = document.createElement('div');
        exitCountdownModalEl.id = 'kiosk-exit-countdown-modal';
        exitCountdownModalEl.style.cssText = `
            position: fixed; inset: 0; z-index: 2147483647;
            background: rgba(3, 7, 18, 0.85); backdrop-filter: blur(20px);
            display: flex; align-items: center; justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        `;
        document.body.appendChild(exitCountdownModalEl);
    }

    let count = 5;
    exitCountdownModalEl.style.display = 'flex';
    const updateContent = () => {
        exitCountdownModalEl.innerHTML = `
            <div style="background: rgba(15, 23, 42, 0.96); border: 1px solid rgba(255,255,255,0.14); border-radius: 20px; width: 400px; max-width: 92vw; padding: 32px 28px; box-shadow: 0 25px 60px rgba(0,0,0,0.85); text-align: center; color: #fff;">
                <div style="font-size: 40px; margin-bottom: 12px;">🔒</div>
                <h2 style="font-size: 20px; font-weight: 700; margin: 0 0 8px 0;">Exit to Kiosk Mode?</h2>
                <p style="font-size: 13px; color: #94a3b8; margin: 0 0 20px 0; line-height: 1.5;">
                    Do you want to return to fullscreen Kiosk Mode?<br>
                    Auto-locking in <b style="color: #38bdf8; font-size: 16px;">${count}</b> seconds...
                </p>
                <div style="display: flex; gap: 12px;">
                    <button id="kiosk-cancel-exit-btn" style="flex: 1; padding: 12px; border-radius: 10px; border: 1px solid #334155; background: #1e293b; color: #cbd5e1; font-size: 13px; font-weight: 600; cursor: pointer;">Cancel (Esc)</button>
                    <button id="kiosk-confirm-exit-btn" style="flex: 1; padding: 12px; border-radius: 10px; border: none; background: #dc2626; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer;">Lock Now (Enter)</button>
                </div>
            </div>
        `;
        const confirmBtn = exitCountdownModalEl.querySelector('#kiosk-confirm-exit-btn');
        const cancelBtn = exitCountdownModalEl.querySelector('#kiosk-cancel-exit-btn');
        if (confirmBtn) confirmBtn.onclick = () => { doLockNow(); };
        if (cancelBtn) cancelBtn.onclick = () => { cancelCountdown(); };
    };

    const doLockNow = () => {
        if (exitCountdownTimer) clearInterval(exitCountdownTimer);
        exitCountdownModalEl.style.display = 'none';
        lockKioskNow();
    };

    const cancelCountdown = () => {
        if (exitCountdownTimer) clearInterval(exitCountdownTimer);
        exitCountdownModalEl.style.display = 'none';
    };

    updateContent();
    if (exitCountdownTimer) clearInterval(exitCountdownTimer);
    exitCountdownTimer = setInterval(() => {
        count--;
        if (count <= 0) {
            clearInterval(exitCountdownTimer);
            doLockNow();
        } else {
            updateContent();
        }
    }, 1000);

    const keyHandler = (e) => {
        if (exitCountdownModalEl.style.display !== 'none') {
            if (e.key === 'Enter') { e.preventDefault(); doLockNow(); window.removeEventListener('keydown', keyHandler); }
            if (e.key === 'Escape') { e.preventDefault(); cancelCountdown(); window.removeEventListener('keydown', keyHandler); }
        }
    };
    window.addEventListener('keydown', keyHandler);
}

window.openKioskExitDialog = showExitCountdownDialog;
window.triggerSecretListener = function() {
    secretListenMode = true;
    secretBuffer = '';
    showCornerIndicator('listening');
    if (secretListenTimer) clearTimeout(secretListenTimer);
    secretListenTimer = setTimeout(() => hideCornerIndicator(), 10000);
};

// 1. Advanced Keyboard Shortcuts & Secret Sequence Handler
window.addEventListener('keydown', function(e) {
    // If user presses Escape while listening in corner: cancel listening mode
    if (secretListenMode && e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        hideCornerIndicator();
        return false;
    }

    const isExitShortcut = (e.ctrlKey && e.altKey && (e.key === '=' || e.key === '+' || e.code === 'Equal' || e.code === 'NumpadEqual' || e.code === 'NumpadAdd')) ||
                           (e.ctrlKey && !e.altKey && !e.shiftKey && (e.key === '=' || e.code === 'Equal'));

    // Check if in Admin Desktop Mode
    const inAdminMode = window.location.pathname.includes('/desktop') ||
                        window.location.port === '8080' ||
                        window.__kiosk_workstation_active ||
                        document.cookie.includes('kiosk_admin=1');

    if (inAdminMode && isExitShortcut) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();

        if (!exitHoldStart && !e.repeat) {
            exitHoldStart = Date.now();
            showExitHoldOverlay(5);
            let start = Date.now();
            if (exitHoldInterval) clearInterval(exitHoldInterval);
            exitHoldInterval = setInterval(() => {
                let elapsed = Date.now() - start;
                let pct = Math.min(100, Math.floor((elapsed / 2000) * 100));
                showExitHoldOverlay(pct);
                if (elapsed >= 2000) {
                    hideExitHoldOverlay();
                    lockKioskNow();
                }
            }, 50);
        }
        return false;
    }

    // A) Admin Unlock Shortcut in Kiosk Mode: ONLY Ctrl + Alt + = (or +)
    const isShortcut = e.ctrlKey && e.altKey && !e.shiftKey && (
        e.key === '=' || e.key === '+' ||
        e.code === 'Equal' || e.code === 'NumpadEqual' || e.code === 'NumpadAdd' ||
        e.keyCode === 187 || e.keyCode === 61 || e.keyCode === 107
    );

    if (isShortcut && !inAdminMode) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();

        // Toggle Secret Listen Mode:
        if (secretListenMode) {
            hideCornerIndicator();
        } else {
            secretListenMode = true;
            secretBuffer = '';
            showCornerIndicator('listening');
            if (secretListenTimer) clearTimeout(secretListenTimer);
            secretListenTimer = setTimeout(() => {
                hideCornerIndicator();
            }, 10000);
        }
        return false;
    }

    // When Secret Listen Mode is active: INTERCEPT AND CONSUME ALL KEYS
    if (secretListenMode) {
        // ALWAYS prevent default so web page (Home Assistant) never sees any keystroke!
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();

        if (e.key && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
            secretBuffer += e.key;
            showCornerIndicator('listening', secretBuffer.replace(/./g, '•'));

            // 1. When user types 'Kiosk' with uppercase K -> open password prompt
            if (secretBuffer.endsWith('Kiosk')) {
                showCornerIndicator('success');
                setTimeout(() => {
                    hideCornerIndicator();
                    openPasswordModal();
                }, 250);
                return false;
            }

            // 2. Secret reboot command: 'reboot'
            if (secretBuffer.toLowerCase().endsWith('reboot')) {
                hideCornerIndicator();
                if (confirm('Reboot kiosk display system now?')) {
                    fetch('http://127.0.0.1:8080/api/reboot', { method: 'POST' });
                }
                return false;
            }

            // 3. Secret reload command: 'reload'
            if (secretBuffer.toLowerCase().endsWith('reload')) {
                hideCornerIndicator();
                fetch('http://127.0.0.1:8080/api/reload', { method: 'POST' });
                return false;
            }
        }
        return false;
    }

    // B) EMERGENCY PANIC LOCK: Ctrl+Alt+Shift+L or Ctrl+Alt+Shift+Q
    if (e.ctrlKey && e.altKey && e.shiftKey && (e.key === 'L' || e.key === 'l' || e.key === 'Q' || e.key === 'q')) {
        e.preventDefault();
        e.stopPropagation();
        lockKioskNow();
        return false;
    }

    // C) QUICK REBOOT SHORTCUT: Ctrl+Alt+Shift+R
    if (e.ctrlKey && e.altKey && e.shiftKey && (e.key === 'R' || e.key === 'r')) {
        e.preventDefault();
        e.stopPropagation();
        if (confirm('Reboot Raspberry Pi system immediately?')) {
            fetch('http://127.0.0.1:8080/api/reboot', { method: 'POST' });
        }
        return false;
    }

    // D) QUICK SCREEN TOGGLE: Ctrl+Alt+Shift+B
    if (e.ctrlKey && e.altKey && e.shiftKey && (e.key === 'B' || e.key === 'b')) {
        e.preventDefault();
        e.stopPropagation();
        fetch('http://127.0.0.1:8080/api/screen/power', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ state: 'toggle' })
        });
        return false;
    }

    // If Admin Modal is open, handle in-admin rapid hotkeys
    if (adminRoot && adminRoot.style.display !== 'none' && adminAuthenticated) {
        resetAdminInactivity();
        const activeTag = (document.activeElement && document.activeElement.tagName) ? document.activeElement.tagName.toLowerCase() : '';
        const isTyping = activeTag === 'input' || activeTag === 'textarea';
        if (!isTyping) {
            if (e.key === 'Escape') {
                e.preventDefault();
                adminRoot.style.display = 'none';
                return false;
            } else if (e.key === '1') {
                triggerUnlock(5); return false;
            } else if (e.key === '2') {
                triggerUnlock(10); return false;
            } else if (e.key === '3') {
                triggerUnlock(15); return false;
            } else if (e.key === '4') {
                triggerUnlock(30); return false;
            } else if (e.key === 'l' || e.key === 'L') {
                lockKioskNow(); return false;
            } else if (e.key === 'r' || e.key === 'R') {
                if (confirm('Reboot Raspberry Pi now?')) fetch('http://127.0.0.1:8080/api/reboot', { method: 'POST' });
                return false;
            } else if (e.key === 'd' || e.key === 'D') {
                fetch('http://127.0.0.1:8080/api/reload', { method: 'POST' });
                return false;
            } else if (e.key === 't' || e.key === 'T') {
                fetch('http://127.0.0.1:8080/api/screen/power', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ state: 'toggle' }) });
                return false;
            }
        }
    }

    // If in Workstation Mode or temporarily unlocked, permit standard browsing & new tabs
    if (window.__kiosk_unlocked) {
        return true;
    }

    // Strict Lockdown Mode: Block browser shortcuts, window opening, devtools, zoom
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

window.addEventListener('keypress', function(e) {
    if (secretListenMode) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        return false;
    }
}, true);

window.addEventListener('keyup', function(e) {
    if (exitHoldStart) {
        const heldDuration = Date.now() - exitHoldStart;
        hideExitHoldOverlay();
        // If released before 2 seconds: user tapped/released early -> show countdown dialog!
        if (heldDuration < 2000) {
            showExitCountdownDialog();
        }
    }

    if (secretListenMode) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
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

// 2. Clean CSS Injection to hide sidebar & prevent accidental navigation
try {
    localStorage.setItem('dockedSidebar', '"always_hidden"');
} catch (e) {}

function ensureKioskStyles() {
    if (document.getElementById('rpi-kiosk-lockdown-style')) return;
    const style = document.createElement('style');
    style.id = 'rpi-kiosk-lockdown-style';
    style.textContent = `
        ha-sidebar, #drawer, ha-drawer, .mdc-drawer { display: none !important; width: 0 !important; max-width: 0 !important; visibility: hidden !important; }
        ha-menu-button { display: none !important; visibility: hidden !important; }
        .menu, [data-panel="profile"], .profile { display: none !important; }
        * { -webkit-user-select: none !important; user-select: none !important; -webkit-user-drag: none !important; }
        input, textarea { -webkit-user-select: text !important; user-select: text !important; }
    `;
    (document.head || document.documentElement).appendChild(style);
}
ensureKioskStyles();
document.addEventListener('DOMContentLoaded', ensureKioskStyles);

// 3. Shadow-DOM query helpers
function querySelectorDeep(selector, root = document) {
    let found = root.querySelector ? root.querySelector(selector) : null;
    if (found) return found;
    const children = root.querySelectorAll ? root.querySelectorAll('*') : [];
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
        if (fieldOrInput.id === 'new-url-input' || fieldOrInput.id === 'new-pin-input' || fieldOrInput.id === 'cfg-new-allow' || fieldOrInput.closest('#rpi-kiosk-admin-root') || fieldOrInput.closest('#rpi-kiosk-password-modal')) {
            return;
        }
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
    if (window.__kiosk_unlocked || window.location.pathname.includes('/lovelace') || window.location.port === '8080') {
        loggedIn = true;
        return;
    }
    if (!window.location.pathname.includes('/auth') && !document.querySelector('ha-credential-login, ha-auth-flow')) {
        return;
    }

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
        const userInput = findHAField('username') || querySelectorDeep('ha-credential-login input[type="text"], ha-auth-flow input[name="username"], form.login input[name="username"]');
        const passInput = findHAField('password') || querySelectorDeep('ha-credential-login input[type="password"], ha-auth-flow input[name="password"], form.login input[name="password"]');
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

// Poll periodically for login form; automatically stops once logged in or after 30s
const loginInterval = setInterval(() => {
    tryAutoLogin();
    if (loggedIn) clearInterval(loginInterval);
}, 600);
setTimeout(() => {
    if (loginInterval) clearInterval(loginInterval);
}, 30000);

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

function showWorkstationFloatingBar() {
    if (document.getElementById('rpi-kiosk-workstation-bar')) return;
    const bar = document.createElement('div');
    bar.id = 'rpi-kiosk-workstation-bar';
    bar.style.cssText = `
        position: fixed;
        top: 10px;
        right: 18px;
        z-index: 2147483646;
        background: rgba(15, 23, 42, 0.95);
        backdrop-filter: blur(12px);
        border: 1px solid rgba(56, 189, 248, 0.6);
        box-shadow: 0 8px 30px rgba(0,0,0,0.6);
        border-radius: 30px;
        padding: 6px 16px;
        display: flex;
        align-items: center;
        gap: 12px;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        font-size: 13px;
        color: #ffffff;
        font-weight: 500;
        user-select: none;
    `;
    bar.innerHTML = `
        <span style="display:inline-block; width:9px; height:9px; border-radius:50%; background:#34d399; box-shadow:0 0 8px #34d399;"></span>
        <span style="font-weight:600; color:#e2e8f0;">Admin Workstation <span style="font-size:11px; color:#38bdf8; font-weight:normal;">(Tabs Active)</span></span>
        <button id="kiosk-ws-settings" style="background:#1e293b; border:1px solid #334155; color:#f1f5f9; padding:4px 10px; border-radius:14px; cursor:pointer; font-size:12px; font-weight:500;">⚙️ Settings</button>
        <button id="kiosk-ws-lock" style="background:#dc2626; border:none; color:#ffffff; padding:4px 12px; border-radius:14px; cursor:pointer; font-size:12px; font-weight:600;">🔒 Lock Kiosk</button>
    `;
    document.body.appendChild(bar);

    bar.querySelector('#kiosk-ws-settings').onclick = () => {
        toggleAdminModal();
    };
    bar.querySelector('#kiosk-ws-lock').onclick = () => {
        lockKioskNow();
    };
}

function removeWorkstationFloatingBar() {
    const bar = document.getElementById('rpi-kiosk-workstation-bar');
    if (bar) bar.remove();
}

function checkAdminStatus() {
    fetch('http://127.0.0.1:8080/api/admin/status')
        .then(res => res.json())
        .then(data => {
            if (data.workstation_mode) {
                window.__kiosk_unlocked = true;
                removeUnlockFloatingPill();
                showWorkstationFloatingBar();
            } else if (data.unlocked && data.remaining_seconds > 0) {
                window.__kiosk_unlocked = true;
                removeWorkstationFloatingBar();
                unlockExpiresAt = Date.now() + (data.remaining_seconds * 1000);
                showUnlockFloatingPill(data.remaining_seconds);
                startClientCountdown();
            } else {
                window.__kiosk_unlocked = false;
                removeUnlockFloatingPill();
                removeWorkstationFloatingBar();
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
    removeWorkstationFloatingBar();
    if (adminRoot) adminRoot.style.display = 'none';

    fetch('http://127.0.0.1:8080/api/admin/disable_workstation', { method: 'POST' })
        .then(() => {
            fetch('http://127.0.0.1:8080/api/admin/lock', { method: 'POST' });
        })
        .catch(e => console.error(e));
}

function triggerUnlock(min) {
    const headers = { 'Content-Type': 'application/json' };
    if (currentAdminToken) headers['Authorization'] = 'Bearer ' + currentAdminToken;
    fetch('http://127.0.0.1:8080/api/admin/unlock', {
        method: 'POST',
        headers: headers,
        body: JSON.stringify({ duration_minutes: min, admin_token: currentAdminToken })
    })
    .then(r => r.json())
    .then(d => {
        if (d.success) {
            window.__kiosk_unlocked = true;
            unlockExpiresAt = Date.now() + (d.duration_seconds * 1000);
            showUnlockFloatingPill(d.duration_seconds);
            startClientCountdown();
            if (adminRoot) adminRoot.style.display = 'none';
        } else {
            alert(d.error || 'Failed to unlock');
        }
    })
    .catch(e => alert('Failed to unlock: ' + e));
}

function renderAdminUI() {
    if (!adminShadow) return;
    resetAdminInactivity();

    if (!adminAuthenticated) {
        adminShadow.innerHTML = `
            <style>
                .overlay {
                    position: fixed; inset: 0; background: rgba(10, 14, 26, 0.92);
                    backdrop-filter: blur(20px); display: flex; align-items: center; justify-content: center;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                }
                .card {
                    background: #182032; border: 1px solid rgba(255,255,255,0.14);
                    border-radius: 18px; padding: 34px; width: 400px; color: #fff;
                    box-shadow: 0 20px 50px rgba(0,0,0,0.7); text-align: center;
                }
                h2 { margin: 0 0 8px 0; font-size: 22px; font-weight: 600; display:flex; align-items:center; justify-content:center; gap:8px; }
                p { margin: 0 0 20px 0; font-size: 14px; color: #9aa4b2; }
                input {
                    width: 100%; box-sizing: border-box; padding: 13px 16px;
                    border-radius: 10px; border: 1px solid #334155; background: #0f172a;
                    color: #fff; font-size: 16px; outline: none; margin-bottom: 18px;
                }
                input:focus { border-color: #3b82f6; box-shadow: 0 0 0 2px rgba(59,130,246,0.3); }
                .btn-row { display: flex; gap: 12px; }
                button {
                    flex: 1; padding: 12px; border-radius: 10px; font-size: 15px; font-weight: 600;
                    cursor: pointer; border: none; transition: 0.15s;
                }
                .btn-primary { background: #3b82f6; color: #fff; }
                .btn-primary:hover { background: #2563eb; }
                .btn-secondary { background: #334155; color: #cbd5e1; }
                .btn-secondary:hover { background: #475569; }
                .error { color: #f87171; font-size: 13px; margin-top: 14px; line-height: 1.4; display: none; }
                .shortcut-hint { margin-top: 18px; font-size: 12px; color: #64748b; border-top: 1px solid #1e293b; padding-top: 12px; }
            </style>
            <div class="overlay">
                <div class="card">
                    <h2>🔒 Kiosk Security Verification</h2>
                    <p>Enter your administrator password or PIN to unlock settings.</p>
                    <input type="password" id="admin-pass" placeholder="Admin Password / PIN" autofocus />
                    <div class="btn-row">
                        <button class="btn-secondary" id="btn-cancel">Cancel</button>
                        <button class="btn-primary" id="btn-unlock">Authenticate</button>
                    </div>
                    <div class="error" id="auth-error"></div>
                    <div class="shortcut-hint">
                        💡 Tip: Press <kbd style="background:#0f172a; padding:2px 5px; border-radius:4px;">Esc</kbd> to exit or tap top-right 5x on touchscreens.
                    </div>
                </div>
            </div>
        `;

        const passInput = adminShadow.getElementById('admin-pass');
        const unlockBtn = adminShadow.getElementById('btn-unlock');
        const cancelBtn = adminShadow.getElementById('btn-cancel');
        const errorEl = adminShadow.getElementById('auth-error');

        const doAuth = () => {
            const pass = passInput.value.trim();
            if (!pass) return;
            fetch('http://127.0.0.1:8080/api/admin/verify_pin', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ pin: pass })
            })
            .then(res => res.json().then(data => ({ status: res.status, data: data })))
            .then(({ status, data }) => {
                if (data.authenticated && data.admin_token) {
                    currentAdminToken = data.admin_token;
                    adminAuthenticated = true;
                    renderAdminUI();
                } else {
                    errorEl.textContent = data.error || 'Authentication failed. Please verify your credentials.';
                    errorEl.style.display = 'block';
                    passInput.value = '';
                }
            })
            .catch(() => {
                errorEl.textContent = 'Connection error. Please retry.';
                errorEl.style.display = 'block';
            });
        };

        unlockBtn.onclick = doAuth;
        passInput.onkeydown = (e) => {
            if (e.key === 'Enter') doAuth();
            if (e.key === 'Escape') { adminRoot.style.display = 'none'; }
        };
        cancelBtn.onclick = () => { adminRoot.style.display = 'none'; };
        setTimeout(() => passInput.focus(), 80);
        return;
    }

    // Authenticated Admin Dashboard
    adminShadow.innerHTML = `
        <style>
            .overlay {
                position: fixed; inset: 0; background: rgba(8, 12, 22, 0.92);
                backdrop-filter: blur(20px); display: flex; align-items: center; justify-content: center;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            }
            .dashboard {
                background: #131b2e; border: 1px solid rgba(255,255,255,0.14);
                border-radius: 20px; width: 720px; max-width: 94vw; max-height: 92vh;
                display: flex; flex-direction: column; color: #fff; overflow: hidden;
                box-shadow: 0 24px 60px rgba(0,0,0,0.7);
            }
            .header {
                padding: 18px 24px; border-bottom: 1px solid #1e293b; display: flex;
                align-items: center; justify-content: space-between; background: #0f172a;
            }
            .header h3 { margin: 0; font-size: 18px; font-weight: 600; display: flex; align-items: center; gap: 8px; }
            .header .hdr-btns { display: flex; gap: 8px; align-items: center; }
            .badge {
                font-size: 11px; padding: 3px 8px; border-radius: 12px; background: rgba(16, 185, 129, 0.2);
                border: 1px solid rgba(16, 185, 129, 0.4); color: #34d399; font-weight: 600;
            }
            .close-btn {
                background: transparent; border: none; color: #94a3b8; font-size: 22px;
                cursor: pointer; padding: 4px 8px; border-radius: 6px;
            }
            .close-btn:hover { background: #1e293b; color: #fff; }
            .content { padding: 22px 24px; overflow-y: auto; flex: 1; display: flex; flex-direction: column; gap: 18px; }
            .section {
                background: #182238; border: 1px solid #23314d; border-radius: 14px; padding: 18px;
            }
            .section-title {
                font-size: 15px; font-weight: 600; margin-bottom: 10px; color: #93c5fd;
                display: flex; align-items: center; justify-content: space-between;
            }
            .btn-group { display: flex; gap: 10px; flex-wrap: wrap; }
            .btn {
                padding: 9px 15px; border-radius: 8px; font-size: 13px; font-weight: 600;
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
            .url-list { max-height: 110px; overflow-y: auto; margin-top: 10px; display: flex; flex-direction: column; gap: 6px; }
            .url-item {
                display: flex; align-items: center; justify-content: space-between;
                background: #0f172a; padding: 6px 12px; border-radius: 6px; font-size: 13px; font-family: monospace;
            }
            .url-item button { background: none; border: none; color: #ef4444; cursor: pointer; font-size: 16px; }
            .input-row { display: flex; gap: 8px; margin-top: 8px; }
            .input-row input {
                flex: 1; padding: 9px 12px; border-radius: 8px; border: 1px solid #334155;
                background: #0f172a; color: #fff; font-size: 13px; outline: none;
            }
            .slider-row { display: flex; align-items: center; gap: 14px; }
            .slider-row input { flex: 1; }
            .shortcut-grid {
                display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 8px; font-size: 12px; color: #cbd5e1;
            }
            .shortcut-item {
                background: #0f172a; padding: 6px 10px; border-radius: 6px; display: flex; align-items: center; justify-content: space-between;
            }
            kbd { background: #1e293b; padding: 2px 6px; border-radius: 4px; font-family: monospace; font-weight: 600; color: #93c5fd; }
        </style>
        <div class="overlay">
            <div class="dashboard">
                <div class="header">
                    <h3>⚙️ Kiosk Control Center <span class="badge">Authenticated</span></h3>
                    <div class="hdr-btns">
                        <button class="close-btn" id="btn-close-dash" title="Close (Esc)">✕</button>
                    </div>
                </div>
                <div class="content">
                    <!-- Temporary Unlock Mode -->
                    <div class="section">
                        <div class="section-title">
                            <span>🔓 Temporary Unlock Mode</span>
                            <span style="font-size:12px; font-weight:normal; color:#94a3b8;">Hotkeys: 1, 2, 3, 4</span>
                        </div>
                        <p style="margin:0 0 12px 0; font-size:13px; color:#94a3b8;">
                            Temporarily disables URL restrictions and enables full keyboard navigation. Automatically re-locks when timer expires.
                        </p>
                        <div class="btn-group">
                            <button class="btn btn-action" data-unlock="5">5 Minutes [1]</button>
                            <button class="btn btn-action" data-unlock="10">10 Minutes [2]</button>
                            <button class="btn btn-action" data-unlock="15">15 Minutes [3]</button>
                            <button class="btn btn-action" data-unlock="30">30 Minutes [4]</button>
                            <button class="btn btn-danger" id="btn-lock-now">🔒 Emergency Lock [L]</button>
                        </div>
                    </div>

                    <!-- Allowed Websites Manager -->
                    <div class="section">
                        <div class="section-title">🌐 Allowed Websites (Enterprise Policy)</div>
                        <p style="margin:0 0 6px 0; font-size:13px; color:#94a3b8;">
                            Authorized domains and IPs strictly permitted during kiosk lock:
                        </p>
                        <div class="input-row">
                            <input type="text" id="new-url-input" placeholder="e.g. google.com or 192.168.1.50:8000" />
                            <button class="btn btn-action" id="btn-add-url">+ Add URL</button>
                        </div>
                        <div class="url-list" id="allowed-url-list">Loading authorized URLs...</div>
                    </div>

                    <!-- Display & Screen Controls -->
                    <div class="section">
                        <div class="section-title">
                            <span>🖥️ Display & Power</span>
                            <span style="font-size:12px; font-weight:normal; color:#94a3b8;">Hotkeys: T (Power)</span>
                        </div>
                        <div class="slider-row">
                            <span style="font-size:13px; width:80px;">Brightness:</span>
                            <input type="range" id="brightness-slider" min="10" max="100" value="100" />
                            <span id="brightness-val" style="font-size:13px; width:45px;">100%</span>
                        </div>
                        <div class="btn-group" style="margin-top: 14px;">
                            <button class="btn btn-subtle" id="btn-screen-toggle">Toggle Screen Power [T]</button>
                            <button class="btn btn-subtle" id="btn-reload-disp">🔁 Reload Display [D]</button>
                        </div>
                    </div>

                    <!-- Security & PIN Management -->
                    <div class="section">
                        <div class="section-title">🛡️ Security & PIN Settings</div>
                        <p style="margin:0 0 8px 0; font-size:13px; color:#94a3b8;">
                            Change administrator passcode (minimum 4 characters):
                        </p>
                        <div class="input-row">
                            <input type="password" id="new-pin-input" placeholder="Enter new PIN / Password" />
                            <button class="btn btn-warn" id="btn-save-pin">Update PIN</button>
                        </div>
                        <div id="pin-feedback" style="font-size:12px; margin-top:6px; display:none;"></div>
                    </div>

                    <!-- Keyboard Shortcuts Cheat Sheet -->
                    <div class="section">
                        <div class="section-title">⚡ Advanced Shortcuts Reference</div>
                        <div class="shortcut-grid">
                            <div class="shortcut-item"><span>Admin Menu:</span> <kbd>Ctrl+Alt+A</kbd></div>
                            <div class="shortcut-item"><span>Exit Fullscreen:</span> <kbd>Ctrl+Alt+=</kbd> type admin</div>
                            <div class="shortcut-item"><span>Panic Relock:</span> <kbd>Ctrl+Alt+Shift+L</kbd></div>
                            <div class="shortcut-item"><span>Quick Reboot:</span> <kbd>Ctrl+Alt+Shift+R</kbd></div>
                            <div class="shortcut-item"><span>Screen Toggle:</span> <kbd>Ctrl+Alt+Shift+B</kbd></div>
                            <div class="shortcut-item"><span>Touchscreen:</span> <span>5 taps top-right</span></div>
                            <div class="shortcut-item"><span>Close Menu:</span> <kbd>Esc</kbd></div>
                        </div>
                    </div>

                    <!-- System Reboot -->
                    <div class="section">
                        <div class="section-title">⚡ System Operations</div>
                        <div class="btn-group">
                            <button class="btn btn-danger" id="btn-reboot-pi">🔄 Reboot Raspberry Pi [R]</button>
                            <button class="btn btn-subtle" id="btn-reset-dash">🏠 Home Dashboard</button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    `;

    // Hook up interaction listener to reset inactivity timer
    adminShadow.querySelector('.dashboard').addEventListener('mousemove', resetAdminInactivity);
    adminShadow.querySelector('.dashboard').addEventListener('click', resetAdminInactivity);

    adminShadow.getElementById('btn-close-dash').onclick = () => { adminRoot.style.display = 'none'; };

    // Duration buttons
    adminShadow.querySelectorAll('[data-unlock]').forEach(btn => {
        btn.onclick = () => {
            const min = parseInt(btn.getAttribute('data-unlock'));
            triggerUnlock(min);
        };
    });

    // Lock Now button
    adminShadow.getElementById('btn-lock-now').onclick = () => {
        lockKioskNow();
    };

    // Load allowlist
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
                        const headers = { 'Content-Type': 'application/json' };
                        if (currentAdminToken) headers['Authorization'] = 'Bearer ' + currentAdminToken;
                        fetch('http://127.0.0.1:8080/api/admin/allowlist', {
                            method: 'POST',
                            headers: headers,
                            body: JSON.stringify({ action: 'remove', url: u, admin_token: currentAdminToken })
                        }).then(() => loadAllowlist());
                    };
                    urlListEl.appendChild(row);
                });
            })
            .catch(() => { urlListEl.innerHTML = '<span style="color:#ef4444;">Error loading allowlist</span>'; });
    }
    loadAllowlist();

    // Add URL
    const addUrlInput = adminShadow.getElementById('new-url-input');
    adminShadow.getElementById('btn-add-url').onclick = () => {
        const val = addUrlInput.value.trim();
        if (!val) return;
        const headers = { 'Content-Type': 'application/json' };
        if (currentAdminToken) headers['Authorization'] = 'Bearer ' + currentAdminToken;
        fetch('http://127.0.0.1:8080/api/admin/allowlist', {
            method: 'POST',
            headers: headers,
            body: JSON.stringify({ action: 'add', url: val, admin_token: currentAdminToken })
        }).then(() => {
            addUrlInput.value = '';
            loadAllowlist();
        });
    };

    // Change PIN
    const newPinInput = adminShadow.getElementById('new-pin-input');
    const pinFeedback = adminShadow.getElementById('pin-feedback');
    adminShadow.getElementById('btn-save-pin').onclick = () => {
        const np = newPinInput.value.trim();
        if (np.length < 4) {
            pinFeedback.textContent = '❌ PIN must be at least 4 characters long.';
            pinFeedback.style.color = '#f87171';
            pinFeedback.style.display = 'block';
            return;
        }
        const headers = { 'Content-Type': 'application/json' };
        if (currentAdminToken) headers['Authorization'] = 'Bearer ' + currentAdminToken;
        fetch('http://127.0.0.1:8080/api/admin/change_pin', {
            method: 'POST',
            headers: headers,
            body: JSON.stringify({ new_pin: np, admin_token: currentAdminToken })
        })
        .then(r => r.json())
        .then(d => {
            if (d.success) {
                pinFeedback.textContent = '✓ Admin PIN successfully updated!';
                pinFeedback.style.color = '#34d399';
                pinFeedback.style.display = 'block';
                newPinInput.value = '';
            } else {
                pinFeedback.textContent = '❌ ' + (d.error || 'Failed to update PIN');
                pinFeedback.style.color = '#f87171';
                pinFeedback.style.display = 'block';
            }
        });
    };

    // Brightness slider
    const bSlider = adminShadow.getElementById('brightness-slider');
    const bVal = adminShadow.getElementById('brightness-val');
    bSlider.oninput = () => { bVal.textContent = bSlider.value + '%'; };
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

// Screen & Input Mode Handler (Mouse auto-hide, Touch, Camera Optical Touch Calibration)
let mouseIdleTimer = null;
function initInputMode() {
    fetch('http://127.0.0.1:8080/api/screen/input_mode')
        .then(r => r.json())
        .then(cfg => {
            const mode = cfg.display_input_mode || 'mouse';
            if (mode === 'touchscreen') {
                document.documentElement.style.cursor = 'none';
            } else if (mode === 'mouse') {
                const timeoutSec = (cfg.mouse_cursor_autohide_sec || 5) * 1000;
                window.addEventListener('mousemove', () => {
                    document.documentElement.style.cursor = 'default';
                    if (mouseIdleTimer) clearTimeout(mouseIdleTimer);
                    mouseIdleTimer = setTimeout(() => {
                        document.documentElement.style.cursor = 'none';
                    }, timeoutSec);
                });
            } else if (mode === 'camera_touch' || cfg.camera_touch_markers) {
                renderOpticalCalibrationMarkers();
            }
        }).catch(() => {});
}

function renderOpticalCalibrationMarkers() {
    if (document.getElementById('kiosk-optical-markers')) return;
    const overlay = document.createElement('div');
    overlay.id = 'kiosk-optical-markers';
    overlay.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483640;';
    
    const mk = (pos, label) => `
        <div style="position:absolute;${pos};width:52px;height:52px;display:flex;align-items:center;justify-content:center;">
            <div style="width:40px;height:40px;border-radius:50%;border:3px solid #00ff66;box-shadow:0 0 12px #00ff66;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,0.85);">
                <div style="width:10px;height:10px;border-radius:50%;background:#00ff66;"></div>
            </div>
            <span style="position:absolute;font-family:monospace;font-size:10px;font-weight:900;color:#00ff66;background:#000;padding:1px 4px;border-radius:3px;border:1px solid #00ff66;">${label}</span>
        </div>
    `;

    overlay.innerHTML = `
        ${mk('top:10px;left:10px', 'TL')}
        ${mk('top:10px;right:10px', 'TR')}
        ${mk('bottom:10px;left:10px', 'BL')}
        ${mk('bottom:10px;right:10px', 'BR')}
        <div style="position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);width:32px;height:32px;border:2px dashed rgba(0,255,102,0.7);border-radius:50%;display:flex;align-items:center;justify-content:center;">
            <div style="width:6px;height:6px;background:#00ff66;border-radius:50%;"></div>
        </div>
    `;
    document.body.appendChild(overlay);
}

checkAdminStatus();
initInputMode();
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

EXTRA_CHROME_FLAGS+=("--load-extension=$EXT_DIR" "--remote-debugging-port=9222" "--remote-allow-origins=*")

if [ -f "/tmp/kiosk-admin-workstation" ]; then
    echo "Starting Chromium in Admin Workstation Mode (Normal New Tab)..."
    exec "$CHROMIUM_BIN" \
      "${EXTRA_CHROME_FLAGS[@]}" \
      --start-maximized \
      --noerrdialogs \
      --disable-infobars \
      --no-first-run \
      --password-store=basic \
      --disk-cache-dir=/tmp/chromium-cache \
      --enable-gpu-rasterization \
      --enable-zero-copy \
      "chrome://newtab"
else
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

    # Ensure WebUI server is answering before launching splash
    for attempt in {1..30}; do
        if curl -s -m 1 http://127.0.0.1:8080/splash >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done

    # Launch Chromium with custom boot splash screen in Standalone Application mode
    exec "$CHROMIUM_BIN" \
      "${EXTRA_CHROME_FLAGS[@]}" \
      --app="http://127.0.0.1:8080/splash" \
      --start-fullscreen \
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
fi
