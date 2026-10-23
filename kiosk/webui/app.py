#!/usr/bin/env python3
"""
app.py - Lightweight Kiosk Web Management Server (Port 8080)
Provides a mobile-friendly dashboard to manage:
  - Dashboard URL
  - Screen Power ON / OFF
  - Screen Orientation / Rotation
  - Home Assistant MQTT Broker Settings
  - Kiosk Reload & System Reboot
"""

import os
import sys
import json
import socket
import logging
import subprocess
from pathlib import Path
from flask import Flask, render_template, request, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("kiosk-webui")

app = Flask(__name__)

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
            "display_output": "auto",
            "display_rotation": "normal",
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


@app.route("/")
def index():
    cfg = load_config()
    status = {
        "ip": get_local_ip(),
        "cpu_temp": get_cpu_temp(),
        "uptime": get_uptime(),
        "screen_status": get_screen_status(),
        "hostname": socket.gethostname()
    }
    return render_template("index.html", config=cfg, status=status)


@app.route("/api/status", methods=["GET"])
def api_status():
    cfg = load_config()
    return jsonify({
        "success": True,
        "screen_status": get_screen_status(),
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

    if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
        subprocess.run([str(SCREEN_CONTROL_SCRIPT), action], capture_output=True)
    
    current_status = get_screen_status()
    return jsonify({"success": True, "screen_status": current_status})


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
    if new_url and new_url.strip() != cfg.get("dashboard_url"):
        cfg["dashboard_url"] = new_url.strip()
        url_changed = True

    # Screen Rotation
    new_rotation = req.get("display_rotation")
    rotation_changed = False
    if new_rotation and new_rotation != cfg.get("display_rotation"):
        cfg["display_rotation"] = new_rotation
        rotation_changed = True
        if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
            subprocess.run([str(SCREEN_CONTROL_SCRIPT), "rotate", new_rotation], capture_output=True)

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
        # Only overwrite password if user entered a new one
        mqtt_cfg["password"] = str(req.get("mqtt_password", ""))
    if "mqtt_device_name" in req:
        mqtt_cfg["device_name"] = str(req.get("mqtt_device_name", "RPi Kiosk")).strip()

    save_config(cfg)

    # If URL changed, reload kiosk display to load new page
    if url_changed:
        logger.info("Dashboard URL updated. Reloading kiosk display...")
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)

    # If MQTT config changed, restart MQTT daemon
    if prev_mqtt != mqtt_cfg:
        logger.info("MQTT settings changed. Restarting kiosk-mqtt service...")
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-mqtt"], capture_output=True)

    return jsonify({"success": True, "message": "Settings saved successfully"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
