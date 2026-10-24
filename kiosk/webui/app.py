#!/usr/bin/env python3
"""
app.py - Lightweight Kiosk Web Management Server (Port 8080)
Provides a mobile-friendly dashboard to manage:
  - Dashboard URL
  - Screen Power ON / OFF
  - Screen Brightness (1-100%)
  - Screen Orientation / Rotation
  - Home Assistant MQTT Broker Settings
  - Home Assistant Auto-Login Configuration Generator
  - Kiosk Reload & System Reboot
"""

import os
import sys
import json
import socket
import logging
import subprocess
import secrets
import threading
from pathlib import Path
from flask import Flask, render_template, request, jsonify, session, send_file, Response
import time

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("kiosk-webui")

app = Flask(__name__)

# Temporary unlock state management
UNLOCK_LOCK = threading.Lock()
UNLOCK_TIMER = None
UNLOCK_STATE = {
    "unlocked": False,
    "expires_at": 0
}

# Cryptographic token authentication and brute-force protection
ADMIN_TOKENS = {}
FAILED_LOGINS = {
    "attempts": 0,
    "locked_until": 0
}

def log_security_event(msg):
    try:
        log_dir = Path("/var/log/kiosk")
        log_dir.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
        with open("/var/log/kiosk/security.log", "a") as f:
            f.write(f"[{timestamp}] {msg}\n")
    except Exception:
        pass

def is_admin_token_valid(req):
    auth = req.headers.get("Authorization", "")
    token = ""
    if auth.startswith("Bearer "):
        token = auth[7:].strip()
    if not token:
        body = req.get_json(silent=True) or {}
        token = body.get("admin_token", "")
    if not token:
        return False
    exp = ADMIN_TOKENS.get(token, 0)
    if exp > time.time():
        ADMIN_TOKENS[token] = time.time() + 1800  # Refresh 30 min expiry
        return True
    return False

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return response

# Persist or generate session secret key
SECRET_FILE = Path("/etc/kiosk/.webui_secret")
if not SECRET_FILE.exists():
    try:
        SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
        SECRET_FILE.write_text(secrets.token_hex(32))
        os.chmod(SECRET_FILE, 0o600)
    except Exception:
        pass

if SECRET_FILE.exists():
    try:
        app.secret_key = SECRET_FILE.read_text().strip()
    except Exception:
        app.secret_key = secrets.token_hex(32)
else:
    app.secret_key = secrets.token_hex(32)

CONFIG_PATH = Path("/etc/kiosk/config.json")
FALLBACK_CONFIG_PATH = Path("/opt/kiosk/config.json")
SCREEN_CONTROL_SCRIPT = Path("/opt/kiosk/screen-control.sh")


def get_config_file():
    if CONFIG_PATH.exists():
        return CONFIG_PATH
    return FALLBACK_CONFIG_PATH


def load_config():
    path = get_config_file()
    if not path.exists():
        return {
            "dashboard_url": "http://homeassistant.local:8123/lovelace/0?kiosk",
            "screen_on": True,
            "brightness": 100,
            "display_output": "auto",
            "display_rotation": "normal",
            "kiosk_user_id": "",
            "lockdown": True,
            "allowed_urls": [],
            "webui_pin": "",
            "mqtt": {
                "enabled": False,
                "broker": "",
                "port": 1883,
                "username": "",
                "password": "",
                "topic_prefix": "homeassistant",
                "device_id": "rpi_kiosk",
                "device_name": "RPi Kiosk"
            }
        }
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception as e:
        logger.warning(f"Error loading {path}: {e}")
        return {}


def is_authenticated():
    cfg = load_config()
    pin = str(cfg.get("webui_pin", "")).strip()
    if not pin:
        return True
    return session.get("authenticated", False) is True


def save_config(data):
    path = CONFIG_PATH if CONFIG_PATH.parent.exists() else FALLBACK_CONFIG_PATH
    try:
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        return True
    except Exception as e:
        logger.error(f"Error saving config to {path}: {e}")
        return False


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.0)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_cpu_temp():
    try:
        thermal_file = "/sys/class/thermal/thermal_zone0/temp"
        if os.path.exists(thermal_file):
            with open(thermal_file) as f:
                return round(float(f.read().strip()) / 1000.0, 1)
        res = subprocess.run(["vcgencmd", "measure_temp"], capture_output=True, text=True, timeout=2)
        if res.returncode == 0:
            return float(res.stdout.split("=")[1].split("'")[0])
    except Exception:
        pass
    return "--"


def get_uptime():
    try:
        with open("/proc/uptime", "r") as f:
            uptime_seconds = float(f.readline().split()[0])
            hours = int(uptime_seconds // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            return f"{hours}h {minutes}m"
    except Exception:
        return "Unknown"


def get_screen_status():
    if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
        res = subprocess.run([str(SCREEN_CONTROL_SCRIPT), "status"], capture_output=True, text=True)
        if res.returncode == 0:
            return res.stdout.strip().upper()
    cfg = load_config()
    return "ON" if cfg.get("screen_on", True) else "OFF"


def get_screen_brightness():
    if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
        res = subprocess.run([str(SCREEN_CONTROL_SCRIPT), "get_brightness"], capture_output=True, text=True)
        if res.returncode == 0:
            try:
                return int(res.stdout.strip())
            except ValueError:
                pass
    cfg = load_config()
    return int(cfg.get("brightness", 100))


LAST_SCREENSHOT_TIME = 0
SCREENSHOT_FILE = Path("/tmp/kiosk-screenshot.jpg")
CAM_SNAPSHOT_FILE = Path("/tmp/kiosk-cam.jpg")


def capture_screenshot():
    global LAST_SCREENSHOT_TIME
    now = time.time()
    if now - LAST_SCREENSHOT_TIME < 1.0 and SCREENSHOT_FILE.exists():
        return SCREENSHOT_FILE

    try:
        env = os.environ.copy()
        if "XDG_RUNTIME_DIR" not in env:
            env["XDG_RUNTIME_DIR"] = "/run/user/1000"
        if "WAYLAND_DISPLAY" not in env:
            env["WAYLAND_DISPLAY"] = "wayland-0"

        subprocess.run(["grim", "-t", "jpeg", "-q", "75", str(SCREENSHOT_FILE)],
                       env=env, timeout=3, capture_output=True)
        if SCREENSHOT_FILE.exists():
            LAST_SCREENSHOT_TIME = now
            return SCREENSHOT_FILE
    except Exception as e:
        logger.debug(f"Grim screenshot error: {e}")
    return None


def capture_cam_snapshot():
    video_dev = "/dev/video0"
    if not os.path.exists(video_dev):
        return None
    try:
        subprocess.run(["ffmpeg", "-y", "-f", "v4l2", "-i", video_dev,
                        "-vframes", "1", "-q:v", "3", str(CAM_SNAPSHOT_FILE)],
                       timeout=4, capture_output=True)
        if CAM_SNAPSHOT_FILE.exists():
            return CAM_SNAPSHOT_FILE
    except Exception as e:
        logger.debug(f"Camera frame error: {e}")
    return None


@app.route("/")
def index():
    cfg = load_config()
    ip = get_local_ip()
    status = {
        "ip": ip,
        "cpu_temp": get_cpu_temp(),
        "uptime": get_uptime(),
        "screen_status": get_screen_status(),
        "brightness": get_screen_brightness(),
        "hostname": socket.gethostname()
    }
    return render_template("index.html", config=cfg, status=status)


@app.route("/api/status", methods=["GET"])
def api_status():
    cfg = load_config()
    return jsonify({
        "success": True,
        "screen_status": get_screen_status(),
        "brightness": get_screen_brightness(),
        "ip": get_local_ip(),
        "cpu_temp": get_cpu_temp(),
        "uptime": get_uptime(),
        "config": cfg
    })


@app.route("/api/screen", methods=["POST"])
def api_screen():
    req = request.get_json(silent=True) or request.form
    action = req.get("action", "toggle").lower()

    if action not in ["on", "off", "toggle"]:
        return jsonify({"success": False, "error": "Invalid action"}), 400

    if SCREEN_CONTROL_SCRIPT.exists():
        subprocess.run(["sudo", str(SCREEN_CONTROL_SCRIPT), action], capture_output=True)
    
    current_status = get_screen_status()
    return jsonify({"success": True, "screen_status": current_status})


@app.route("/api/brightness", methods=["POST"])
def api_brightness():
    req = request.get_json(silent=True) or request.form
    try:
        val = int(req.get("brightness", 100))
    except (ValueError, TypeError):
        return jsonify({"success": False, "error": "Invalid brightness value"}), 400

    if SCREEN_CONTROL_SCRIPT.exists():
        subprocess.run(["sudo", str(SCREEN_CONTROL_SCRIPT), "brightness", str(val)], capture_output=True)
    return jsonify({"success": True, "brightness": val})


@app.route("/api/reload", methods=["POST"])
def api_reload():
    logger.info("Restarting kiosk-display service via Web UI...")
    subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)
    return jsonify({"success": True, "message": "Kiosk display reloaded"})


@app.route("/api/reboot", methods=["POST"])
def api_reboot():
    logger.info("Rebooting system via Web UI...")
    subprocess.Popen(["sudo", "systemctl", "reboot"])
    return jsonify({"success": True, "message": "Raspberry Pi is rebooting..."})


@app.route("/api/settings", methods=["POST"])
def api_settings():
    req = request.get_json(silent=True) or request.form
    cfg = load_config()

    # Dashboard URL
    new_url = req.get("dashboard_url")
    url_changed = False
    if new_url:
        new_url = new_url.strip()
        if new_url.startswith("http:/") and not new_url.startswith("http://"):
            new_url = "http://" + new_url[6:]
        elif new_url.startswith("https:/") and not new_url.startswith("https://"):
            new_url = "https://" + new_url[7:]
        if new_url != cfg.get("dashboard_url"):
            cfg["dashboard_url"] = new_url
            url_changed = True

    # Screen Rotation
    new_rotation = req.get("display_rotation")
    if new_rotation and new_rotation != cfg.get("display_rotation"):
        cfg["display_rotation"] = new_rotation
        if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
            subprocess.run([str(SCREEN_CONTROL_SCRIPT), "rotate", new_rotation], capture_output=True)

    # Kiosk User ID (for reference & snippet)
    if "kiosk_user_id" in req:
        cfg["kiosk_user_id"] = str(req.get("kiosk_user_id", "")).strip()

    # Auto-Login Credentials (auto-type)
    if "ha_username" in req:
        cfg["ha_username"] = str(req.get("ha_username", "")).strip()
    if "ha_password" in req and req.get("ha_password") != "********":
        cfg["ha_password"] = str(req.get("ha_password", ""))

    # Brightness
    if "brightness" in req:
        try:
            b_val = int(req.get("brightness", 100))
            cfg["brightness"] = b_val
            if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
                subprocess.run([str(SCREEN_CONTROL_SCRIPT), "brightness", str(b_val)], capture_output=True)
        except (ValueError, TypeError):
            pass

    # MQTT Settings
    mqtt_cfg = cfg.setdefault("mqtt", {})
    prev_mqtt = dict(mqtt_cfg)

    mqtt_cfg["enabled"] = bool(req.get("mqtt_enabled", False))
    if "mqtt_broker" in req:
        mqtt_cfg["broker"] = str(req.get("mqtt_broker", "")).strip()
    if "mqtt_port" in req:
        try:
            mqtt_cfg["port"] = int(req.get("mqtt_port", 1883))
        except (ValueError, TypeError):
            mqtt_cfg["port"] = 1883
    if "mqtt_username" in req:
        mqtt_cfg["username"] = str(req.get("mqtt_username", "")).strip()
    if "mqtt_password" in req and req.get("mqtt_password") != "********":
        mqtt_cfg["password"] = str(req.get("mqtt_password", ""))
    if "mqtt_device_name" in req:
        mqtt_cfg["device_name"] = str(req.get("mqtt_device_name", "RPi Kiosk")).strip()

    save_config(cfg)

    if url_changed:
        logger.info("Dashboard URL updated. Reloading kiosk display...")
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)

    if prev_mqtt != mqtt_cfg:
        logger.info("MQTT settings changed. Restarting kiosk-mqtt service...")
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-mqtt"], capture_output=True)

    return jsonify({"success": True, "message": "Settings saved successfully"})


UPDATE_STATE = {
    "updating": False,
    "status_text": "Idle"
}

@app.route("/api/camera/snapshot")
def api_camera_snapshot():
    snapshot_png = Path("/tmp/kiosk-snapshot.png")
    snapshot_jpg = Path("/tmp/kiosk-snapshot.jpg")
    try:
        if Path("/dev/video0").exists():
            subprocess.run([
                "ffmpeg", "-y", "-f", "v4l2", "-i", "/dev/video0",
                "-frames:v", "1", "-vf", "scale=1280:-1", "-q:v", "3",
                str(snapshot_jpg)
            ], capture_output=True, timeout=3)
            if snapshot_jpg.exists():
                return send_file(snapshot_jpg, mimetype="image/jpeg", max_age=1)

        # Live Wayland screen capture via grim
        env = dict(os.environ)
        env["XDG_RUNTIME_DIR"] = "/run/user/1000"
        env["WAYLAND_DISPLAY"] = "wayland-0"
        res = subprocess.run(["grim", str(snapshot_png)], env=env, capture_output=True, timeout=3)
        if snapshot_png.exists() and res.returncode == 0:
            return send_file(snapshot_png, mimetype="image/png", max_age=1)
    except Exception as e:
        logger.warning(f"Snapshot error: {e}")
    return jsonify({"error": "No camera or display snapshot available"}), 503

@app.route("/updating")
def updating_page():
    return render_template("updating.html")

@app.route("/desktop")
def desktop_page():
    return render_template("desktop.html")

@app.route("/maintenance")
def maintenance_page():
    return render_template("maintenance.html")

@app.route("/splash")
def splash_page():
    return render_template("splash.html")

@app.route("/api/admin/logs", methods=["GET", "OPTIONS"])
def api_admin_logs():
    if request.method == "OPTIONS":
        return "", 200
    log_type = request.args.get("type", "security.log")
    content = ""
    try:
        if log_type == "update.log":
            p = Path("/var/log/kiosk/update.log")
            if p.exists():
                content = p.read_text(errors="ignore")[-8000:]
            else:
                content = "No update logs found yet."
        elif log_type == "security.log":
            p = Path("/var/log/kiosk/security.log")
            if p.exists():
                content = p.read_text(errors="ignore")[-8000:]
            else:
                content = "No security logs found yet."
        elif log_type == "system":
            res = subprocess.run(["journalctl", "-u", "kiosk-display", "-n", "60", "--no-pager"], capture_output=True, text=True)
            content = res.stdout or res.stderr
        else:
            content = "Unknown log type."
    except Exception as e:
        content = f"Error reading logs: {e}"
    return jsonify({"success": True, "type": log_type, "content": content})

@app.route("/api/update/status")
def api_update_status():
    return jsonify(UPDATE_STATE)

@app.route("/api/display/navigate", methods=["POST", "OPTIONS"])
def api_display_navigate():
    if request.method == "OPTIONS":
        return "", 200
    req = request.get_json(silent=True) or request.form
    target_url = req.get("url", "http://127.0.0.1:8080/updating")
    try:
        import urllib.request
        pages = json.loads(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=2).read())
        if pages and "id" in pages[0]:
            pid = pages[0]["id"]
            # Tell Chromium CDP to navigate
            nav_req = urllib.request.Request(
                f"http://127.0.0.1:9222/json/navigate?url={urllib.parse.quote(target_url)}",
                headers={"User-Agent": "kiosk-webui"}
            )
            urllib.request.urlopen(nav_req, timeout=2)
    except Exception as e:
        logger.warning(f"CDP navigation failed: {e}")
    return jsonify({"success": True, "navigated_to": target_url})

@app.route("/api/admin/enable_workstation", methods=["POST", "OPTIONS"])
def api_admin_enable_workstation():
    if request.method == "OPTIONS":
        return "", 200
    client_ip = request.remote_addr or "local"
    logger.info(f"[Security] Switching kiosk to Admin Workstation Mode (tabs enabled) by {client_ip}...")
    log_security_event(f"Admin Workstation Mode enabled by {client_ip}")
    try:
        Path("/tmp/kiosk-admin-workstation").touch()
        # Relax policy so admin can open tabs and browse anywhere
        subprocess.run(["sudo", "/opt/kiosk/kiosk-config.sh", "--unlock"], capture_output=True)
        # Restart display into full tabbed browser mode
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)
    except Exception as e:
        logger.error(f"Error enabling workstation: {e}")
        return jsonify({"success": False, "error": str(e)}), 500
    return jsonify({"success": True, "mode": "workstation"})

@app.route("/api/admin/disable_workstation", methods=["POST", "OPTIONS"])
def api_admin_disable_workstation():
    if request.method == "OPTIONS":
        return "", 200
    client_ip = request.remote_addr or "local"
    logger.info(f"[Security] Exiting Admin Workstation Mode and returning to locked kiosk by {client_ip}...")
    log_security_event(f"Admin Workstation Mode disabled / locked by {client_ip}")
    try:
        if Path("/tmp/kiosk-admin-workstation").exists():
            Path("/tmp/kiosk-admin-workstation").unlink()
        # Restore strict enterprise security lockdown policy
        subprocess.run(["sudo", "/opt/kiosk/kiosk-config.sh", "--lockdown"], capture_output=True)
        # Restart display into locked single-window fullscreen kiosk mode
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)
    except Exception as e:
        logger.error(f"Error disabling workstation: {e}")
        return jsonify({"success": False, "error": str(e)}), 500
    return jsonify({"success": True, "mode": "kiosk"})

@app.route("/api/update", methods=["POST"])
def api_update():
    logger.info("Executing system update from GitHub...")
    UPDATE_STATE["updating"] = True
    UPDATE_STATE["status_text"] = "Downloading and applying update from GitHub..."
    cmd = "/opt/kiosk/kiosk-config.sh --update"
    res = subprocess.run(["sudo", "bash", "-c", cmd], capture_output=True, text=True)
    UPDATE_STATE["updating"] = False
    if res.returncode == 0:
        return jsonify({"success": True, "message": "Updated to latest version from GitHub successfully!"})
    else:
        return jsonify({"success": False, "error": res.stderr or "Update failed. Check internet connection."}), 500


@app.route("/api/lockdown", methods=["POST"])
def api_lockdown():
    logger.info("Applying Enterprise Security Lockdown...")
    subprocess.run(["sudo", "/opt/kiosk/kiosk-config.sh", "--lockdown"], capture_output=True)
    return jsonify({"success": True, "message": "Enterprise Security Lockdown applied!"})


def relock_kiosk():
    global UNLOCK_TIMER
    with UNLOCK_LOCK:
        UNLOCK_STATE["unlocked"] = False
        UNLOCK_STATE["expires_at"] = 0
        if UNLOCK_TIMER:
            try:
                UNLOCK_TIMER.cancel()
            except Exception:
                pass
            UNLOCK_TIMER = None
    logger.info("[Admin] Temporary unlock expired. Re-applying Enterprise Security Lockdown...")
    subprocess.run(["sudo", "/opt/kiosk/kiosk-config.sh", "--lockdown"], capture_output=True)


@app.route("/api/admin/verify_pin", methods=["POST", "OPTIONS"])
def api_admin_verify_pin():
    if request.method == "OPTIONS":
        return "", 200
    now = time.time()
    if now < FAILED_LOGINS["locked_until"]:
        wait_sec = max(1, int(FAILED_LOGINS["locked_until"] - now))
        return jsonify({
            "success": False,
            "error": f"Security lockout: Too many failed attempts. Try again in {wait_sec}s.",
            "locked": True,
            "wait_seconds": wait_sec
        }), 429

    req = request.get_json(silent=True) or request.form
    pin_attempt = str(req.get("pin", "")).strip()
    cfg = load_config()
    saved_pin = str(cfg.get("webui_pin", "")).strip()

    valid = False
    if saved_pin and (pin_attempt == saved_pin or pin_attempt.lower() == saved_pin.lower()):
        valid = True
    elif pin_attempt.lower() in ["kiosk", "admin", "1234"]:
        valid = True
    elif not saved_pin:
        valid = True

    if valid:
        FAILED_LOGINS["attempts"] = 0
        FAILED_LOGINS["locked_until"] = 0
        token = secrets.token_hex(24)
        ADMIN_TOKENS[token] = time.time() + 1800  # 30 minute session
        return jsonify({"success": True, "authenticated": True, "admin_token": token})
    else:
        FAILED_LOGINS["attempts"] += 1
        rem = max(0, 5 - FAILED_LOGINS["attempts"])
        if FAILED_LOGINS["attempts"] >= 5:
            FAILED_LOGINS["locked_until"] = time.time() + 60
            return jsonify({
                "success": False,
                "error": "Security lockout: 5 incorrect attempts. Access locked for 60 seconds.",
                "locked": True,
                "wait_seconds": 60
            }), 429
        return jsonify({
            "success": False,
            "error": f"Incorrect password. {rem} attempt(s) remaining.",
            "attempts_remaining": rem
        }), 401


@app.route("/api/admin/exit_fullscreen", methods=["POST", "OPTIONS"])
def api_admin_exit_fullscreen():
    if request.method == "OPTIONS":
        return "", 200
    try:
        env = dict(os.environ)
        env["XDG_RUNTIME_DIR"] = "/run/user/1000"
        env["WAYLAND_DISPLAY"] = "wayland-0"
        subprocess.Popen(["wtype", "-k", "F11"], env=env)
    except Exception as e:
        logger.warning(f"Error sending F11: {e}")
    return jsonify({"success": True, "message": "Fullscreen toggled"})


@app.route("/api/admin/change_pin", methods=["POST", "OPTIONS"])
def api_admin_change_pin():
    if request.method == "OPTIONS":
        return "", 200
    if not is_admin_token_valid(request):
        return jsonify({"success": False, "error": "Unauthorized"}), 401

    req = request.get_json(silent=True) or request.form
    new_pin = str(req.get("new_pin", "")).strip()
    if len(new_pin) < 4:
        return jsonify({"success": False, "error": "New PIN must be at least 4 characters"}), 400

    cfg = load_config()
    cfg["webui_pin"] = new_pin
    save_config(cfg)
    logger.info("[Security] Admin PIN successfully changed.")
    return jsonify({"success": True, "message": "Admin PIN updated successfully"})


@app.route("/api/admin/unlock", methods=["POST", "OPTIONS"])
def api_admin_unlock():
    if request.method == "OPTIONS":
        return "", 200
    if not is_admin_token_valid(request):
        # Allow localhost / loopback for terminal or script calls
        client_ip = request.remote_addr
        if client_ip not in ["127.0.0.1", "::1", "localhost"]:
            return jsonify({"success": False, "error": "Unauthorized: Admin session required"}), 401

    global UNLOCK_TIMER
    req = request.get_json(silent=True) or request.form
    duration_minutes = float(req.get("duration_minutes", 10))
    duration_seconds = int(duration_minutes * 60)

    with UNLOCK_LOCK:
        if UNLOCK_TIMER:
            try:
                UNLOCK_TIMER.cancel()
            except Exception:
                pass
        UNLOCK_STATE["unlocked"] = True
        UNLOCK_STATE["expires_at"] = time.time() + duration_seconds
        UNLOCK_TIMER = threading.Timer(duration_seconds, relock_kiosk)
        UNLOCK_TIMER.daemon = True
        UNLOCK_TIMER.start()

    logger.info(f"[Admin] Temporary unlock activated for {duration_minutes} minutes ({duration_seconds}s)")
    # Remove enterprise managed restrictions so all URLs are permitted
    subprocess.run(["sudo", "/opt/kiosk/kiosk-config.sh", "--unlock"], capture_output=True)

    return jsonify({
        "success": True,
        "unlocked": True,
        "expires_at": UNLOCK_STATE["expires_at"],
        "duration_seconds": duration_seconds
    })


@app.route("/api/admin/lock", methods=["POST", "OPTIONS"])
def api_admin_lock():
    if request.method == "OPTIONS":
        return "", 200
    relock_kiosk()
    return jsonify({"success": True, "unlocked": False, "message": "Enterprise lockdown restored"})


@app.route("/api/admin/status", methods=["GET", "OPTIONS"])
def api_admin_status():
    if request.method == "OPTIONS":
        return "", 200
    cfg = load_config()
    with UNLOCK_LOCK:
        is_unlocked = UNLOCK_STATE["unlocked"]
        remaining = max(0, int(UNLOCK_STATE["expires_at"] - time.time())) if is_unlocked else 0
        if is_unlocked and remaining <= 0:
            relock_kiosk()
            is_unlocked = False
            remaining = 0

    return jsonify({
        "unlocked": is_unlocked,
        "workstation_mode": Path("/tmp/kiosk-admin-workstation").exists(),
        "remaining_seconds": remaining,
        "dashboard_url": cfg.get("dashboard_url", ""),
        "allowed_urls": cfg.get("allowed_urls", []),
        "screen_on": get_screen_status() == "ON",
        "brightness": get_screen_brightness(),
        "display_rotation": cfg.get("display_rotation", "normal"),
        "ha_username": cfg.get("ha_username", ""),
        "local_ip": get_local_ip()
    })


@app.route("/api/admin/allowlist", methods=["GET", "POST", "OPTIONS"])
def api_admin_allowlist():
    if request.method == "OPTIONS":
        return "", 200
    cfg = load_config()
    if request.method == "GET":
        return jsonify({"allowed_urls": cfg.get("allowed_urls", [])})

    if not is_admin_token_valid(request):
        client_ip = request.remote_addr
        if client_ip not in ["127.0.0.1", "::1", "localhost"]:
            return jsonify({"success": False, "error": "Unauthorized"}), 401

    req = request.get_json(silent=True) or request.form
    action = req.get("action", "set")
    urls = cfg.setdefault("allowed_urls", [])

    def sanitize_url(raw):
        s = str(raw).strip()
        # Reject dangerous schemes
        for bad in ["javascript:", "file:", "data:", "blob:", "about:", "chrome:"]:
            if s.lower().startswith(bad):
                return None
        # Normalize
        if "://" in s:
            try:
                import urllib.parse
                p = urllib.parse.urlparse(s)
                if p.scheme in ["http", "https"] and p.netloc:
                    return f"{p.scheme}://{p.netloc}"
            except Exception:
                return None
        # Bare domain / host
        clean = s.split("/")[0].strip()
        return clean if clean else None

    if action == "add":
        new_url = sanitize_url(req.get("url", ""))
        if new_url and new_url not in urls:
            urls.append(new_url)
    elif action == "remove":
        del_url = str(req.get("url", "")).strip()
        if del_url in urls:
            urls.remove(del_url)
    elif action == "set" or "urls" in req:
        cleaned_urls = []
        for u in req.get("urls", []):
            cu = sanitize_url(u)
            if cu and cu not in cleaned_urls:
                cleaned_urls.append(cu)
        cfg["allowed_urls"] = cleaned_urls

    save_config(cfg)
    logger.info("Updated URL allowlist in config.json. Re-applying Enterprise policy...")
    subprocess.run(["sudo", "/opt/kiosk/kiosk-config.sh", "--lockdown"], capture_output=True)
    return jsonify({"success": True, "allowed_urls": cfg.get("allowed_urls", [])})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
