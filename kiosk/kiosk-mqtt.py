#!/usr/bin/env python3
"""
kiosk-mqtt.py
Home Assistant MQTT Auto-Discovery and Device Control Daemon for Raspberry Pi Kiosk.
Provides:
  - switch.kiosk_screen (Screen Power On/Off)
  - number.kiosk_brightness (Screen Brightness 1-100%)
  - button.kiosk_reload (Reload Chromium / Kiosk)
  - button.kiosk_reboot (Reboot Raspberry Pi)
  - sensor.kiosk_url (Current Dashboard URL)
  - text.kiosk_url (Change Dashboard URL remotely from Home Assistant)
  - sensor.kiosk_temperature (CPU Temperature)
  - sensor.kiosk_ip (Local IP Address)
  - sensor.kiosk_memory_usage (RAM % Used)
"""

import os
import sys
import time
import json
import socket
import logging
import subprocess
import threading
from pathlib import Path

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("kiosk-mqtt")

CONFIG_PATH = Path("/etc/kiosk/config.json")
FALLBACK_CONFIG_PATH = Path("/opt/kiosk/config.json")
SCREEN_CONTROL_SCRIPT = Path("/opt/kiosk/screen-control.sh")

# Motion detection & Night mode state
LAST_FRAME_SAMPLE = None
MOTION_UNTIL = 0
NIGHT_SCREEN_OFF = False

try:
    import paho.mqtt.client as mqtt
except ImportError:
    logger.error("paho-mqtt is not installed. Please run: apt-get install python3-paho-mqtt")
    sys.exit(1)


def load_config():
    path = CONFIG_PATH if CONFIG_PATH.exists() else FALLBACK_CONFIG_PATH
    if not path.exists():
        return {}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception as e:
        logger.warning(f"Error reading config {path}: {e}")
        return {}


def save_config(cfg):
    path = CONFIG_PATH if CONFIG_PATH.parent.exists() else FALLBACK_CONFIG_PATH
    try:
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception as e:
        logger.error(f"Error saving config to {path}: {e}")


def get_mac_address():
    try:
        for iface in ["eth0", "wlan0", "en0"]:
            mac_file = f"/sys/class/net/{iface}/address"
            if os.path.exists(mac_file):
                with open(mac_file) as f:
                    return f.read().strip().replace(":", "").lower()
    except Exception:
        pass
    return "000000000000"


def get_ip_address():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.0)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_cpu_temperature():
    try:
        thermal_file = "/sys/class/thermal/thermal_zone0/temp"
        if os.path.exists(thermal_file):
            with open(thermal_file) as f:
                temp_raw = f.read().strip()
                return round(float(temp_raw) / 1000.0, 1)
        res = subprocess.run(["vcgencmd", "measure_temp"], capture_output=True, text=True, timeout=2)
        if res.returncode == 0:
            return float(res.stdout.split("=")[1].split("'")[0])
    except Exception:
        pass
    return None


def get_memory_usage():
    try:
        with open("/proc/meminfo") as f:
            mem = {}
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    mem[parts[0].strip()] = int(parts[1].strip().split()[0])
            total = mem.get("MemTotal", 1)
            avail = mem.get("MemAvailable", 0)
            used = total - avail
            return round((used / total) * 100.0, 1)
    except Exception:
        return None


def run_screen_cmd(action, arg=""):
    if SCREEN_CONTROL_SCRIPT.exists():
        cmd = ["sudo", str(SCREEN_CONTROL_SCRIPT), action]
        if arg:
            cmd.append(str(arg))
        subprocess.run(cmd, capture_output=True, text=True)
    else:
        logger.warning(f"screen-control.sh not found at {SCREEN_CONTROL_SCRIPT}")


def get_screen_state():
    if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
        res = subprocess.run([str(SCREEN_CONTROL_SCRIPT), "status"], capture_output=True, text=True)
        if res.returncode == 0:
            return res.stdout.strip().upper()
    return "ON"


def get_screen_brightness():
    if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
        res = subprocess.run([str(SCREEN_CONTROL_SCRIPT), "get_brightness"], capture_output=True, text=True)
        if res.returncode == 0:
            try:
                return int(res.stdout.strip())
            except ValueError:
                pass
    return 100


class KioskMQTTDaemon:
    def __init__(self):
        self.client = None
        self.config = load_config()
        self.device_id = self.config.get("mqtt", {}).get("device_id") or f"rpi_kiosk_{get_mac_address()[-6:]}"
        self.device_name = self.config.get("mqtt", {}).get("device_name", "RPi Kiosk")
        self.prefix = self.config.get("mqtt", {}).get("topic_prefix", "homeassistant")
        self.base_topic = f"rpi_kiosk/{self.device_id}"
        self.status_topic = f"{self.base_topic}/status"
        self.is_connected = False
        self.stop_event = threading.Event()

    def create_client(self):
        mqtt_cfg = self.config.get("mqtt", {})
        client_id = f"{self.device_id}_daemon"

        try:
            from paho.mqtt.enums import CallbackAPIVersion
            client = mqtt.Client(CallbackAPIVersion.VERSION2, client_id=client_id, protocol=mqtt.MQTTv311)
        except (ImportError, AttributeError):
            client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)

        user = mqtt_cfg.get("username")
        pw = mqtt_cfg.get("password")
        if user:
            client.username_pw_set(user, pw or None)

        client.will_set(self.status_topic, payload="offline", qos=1, retain=True)

        client.on_connect = self.on_connect
        client.on_disconnect = self.on_disconnect
        client.on_message = self.on_message
        return client

    def on_connect(self, client, userdata, flags, rc, *extra):
        logger.info(f"Connected to MQTT broker (rc: {rc})")
        self.is_connected = True
        client.publish(self.status_topic, "online", qos=1, retain=True)
        self.publish_discovery()
        
        # Subscriptions
        client.subscribe(f"{self.base_topic}/screen/set", qos=1)
        client.subscribe(f"{self.base_topic}/lockdown/set", qos=1)
        client.subscribe(f"{self.base_topic}/brightness/set", qos=1)
        client.subscribe(f"{self.base_topic}/url/set", qos=1)
        client.subscribe(f"{self.base_topic}/reload/set", qos=1)
        client.subscribe(f"{self.base_topic}/reboot/set", qos=1)
        client.subscribe(f"{self.base_topic}/nightmode/set", qos=1)
        client.subscribe(f"{self.base_topic}/hide_menu/set", qos=1)
        client.subscribe(f"{self.base_topic}/admin_mode/set", qos=1)
        
        self.publish_states()

    def on_disconnect(self, client, userdata, rc, *extra):
        logger.warning(f"Disconnected from MQTT broker (rc: {rc})")
        self.is_connected = False

    def on_message(self, client, userdata, msg):
        topic = msg.topic
        payload = msg.payload.decode("utf-8", errors="ignore").strip()
        logger.info(f"MQTT message received on [{topic}]: {payload}")

        if topic == f"{self.base_topic}/screen/set":
            if payload.upper() in ["ON", "TRUE", "1"]:
                run_screen_cmd("on")
                client.publish(f"{self.base_topic}/screen/state", "ON", qos=1, retain=True)
            elif payload.upper() in ["OFF", "FALSE", "0"]:
                run_screen_cmd("off")
                client.publish(f"{self.base_topic}/screen/state", "OFF", qos=1, retain=True)

        elif topic == f"{self.base_topic}/lockdown/set":
            if payload.upper() in ["ON", "TRUE", "1"]:
                logger.info("Enabling Strict Lockdown via MQTT...")
                subprocess.run(["sudo", "/usr/local/bin/kiosk-config", "--lockdown", "on"], capture_output=True)
                client.publish(f"{self.base_topic}/lockdown/state", "ON", qos=1, retain=True)
            elif payload.upper() in ["OFF", "FALSE", "0"]:
                logger.info("Disabling Strict Lockdown via MQTT...")
                subprocess.run(["sudo", "/usr/local/bin/kiosk-config", "--lockdown", "off"], capture_output=True)
                client.publish(f"{self.base_topic}/lockdown/state", "OFF", qos=1, retain=True)

        elif topic == f"{self.base_topic}/brightness/set":
            try:
                b_val = int(float(payload))
                run_screen_cmd("brightness", b_val)
                client.publish(f"{self.base_topic}/brightness/state", str(b_val), qos=1, retain=True)
            except ValueError:
                logger.warning(f"Invalid brightness payload: {payload}")

        elif topic == f"{self.base_topic}/url/set":
            if payload:
                logger.info(f"Updating dashboard URL via MQTT to: {payload}")
                cfg = load_config()
                cfg["dashboard_url"] = payload
                save_config(cfg)
                client.publish(f"{self.base_topic}/url/state", payload, qos=1, retain=True)
                subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)

        elif topic == f"{self.base_topic}/reload/set":
            logger.info("Triggering Kiosk display reload...")
            subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"], capture_output=True)

        elif topic == f"{self.base_topic}/reboot/set":
            logger.info("Triggering system reboot from MQTT...")
            subprocess.run(["sudo", "systemctl", "reboot"], capture_output=True)

        elif topic == f"{self.base_topic}/nightmode/set":
            cfg = load_config()
            cfg["night_mode_enabled"] = payload.upper() in ["ON", "TRUE", "1"]
            save_config(cfg)
            client.publish(f"{self.base_topic}/nightmode/state", "ON" if cfg["night_mode_enabled"] else "OFF", qos=1, retain=True)

        elif topic == f"{self.base_topic}/hide_menu/set":
            cfg = load_config()
            cfg["hide_sidebar_menu"] = payload.upper() in ["ON", "TRUE", "1"]
            save_config(cfg)
            client.publish(f"{self.base_topic}/hide_menu/state", "ON" if cfg["hide_sidebar_menu"] else "OFF", qos=1, retain=True)

        elif topic == f"{self.base_topic}/admin_mode/set":
            if payload.upper() in ["ON", "TRUE", "1"]:
                subprocess.Popen(["/bin/bash", "/opt/kiosk/start-desktop.sh"])
                client.publish(f"{self.base_topic}/admin_mode/state", "ON", qos=1, retain=True)
            else:
                subprocess.Popen(["/bin/bash", "/opt/kiosk/lock-kiosk.sh"])
                client.publish(f"{self.base_topic}/admin_mode/state", "OFF", qos=1, retain=True)

    def publish_discovery(self):
        device_info = {
            "identifiers": [f"kiosk_{self.device_id}"],
            "name": self.device_name,
            "model": "Raspberry Pi Kiosk",
            "manufacturer": "Raspberry Pi OS",
            "sw_version": "1.1.0"
        }

        # 1. Screen Switch
        switch_disc = {
            "name": f"{self.device_name} Screen Power",
            "unique_id": f"{self.device_id}_screen",
            "state_topic": f"{self.base_topic}/screen/state",
            "command_topic": f"{self.base_topic}/screen/set",
            "availability_topic": self.status_topic,
            "payload_on": "ON",
            "payload_off": "OFF",
            "icon": "mdi:monitor",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/switch/{self.device_id}/screen/config",
            json.dumps(switch_disc), qos=1, retain=True
        )

        # 1b. Strict Lockdown Switch
        lockdown_disc = {
            "name": f"{self.device_name} Strict Lockdown",
            "unique_id": f"{self.device_id}_lockdown",
            "state_topic": f"{self.base_topic}/lockdown/state",
            "command_topic": f"{self.base_topic}/lockdown/set",
            "availability_topic": self.status_topic,
            "payload_on": "ON",
            "payload_off": "OFF",
            "icon": "mdi:shield-lock",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/switch/{self.device_id}/lockdown/config",
            json.dumps(lockdown_disc), qos=1, retain=True
        )

        # 1c. Hide Home Assistant Sandwich Menu & Sidebar Switch
        menu_disc = {
            "name": f"{self.device_name} Hide Sandwich Menu",
            "unique_id": f"{self.device_id}_hide_menu",
            "state_topic": f"{self.base_topic}/hide_menu/state",
            "command_topic": f"{self.base_topic}/hide_menu/set",
            "availability_topic": self.status_topic,
            "payload_on": "ON",
            "payload_off": "OFF",
            "icon": "mdi:menu-open",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/switch/{self.device_id}/hide_menu/config",
            json.dumps(menu_disc), qos=1, retain=True
        )

        # 1d. Admin Desktop Mode Switch
        admin_disc = {
            "name": f"{self.device_name} Admin Desktop Mode",
            "unique_id": f"{self.device_id}_admin_mode",
            "state_topic": f"{self.base_topic}/admin_mode/state",
            "command_topic": f"{self.base_topic}/admin_mode/set",
            "availability_topic": self.status_topic,
            "payload_on": "ON",
            "payload_off": "OFF",
            "icon": "mdi:desktop-mac-dashboard",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/switch/{self.device_id}/admin_mode/config",
            json.dumps(admin_disc), qos=1, retain=True
        )

        # 2. Brightness Number
        bright_disc = {
            "name": f"{self.device_name} Brightness",
            "unique_id": f"{self.device_id}_brightness",
            "state_topic": f"{self.base_topic}/brightness/state",
            "command_topic": f"{self.base_topic}/brightness/set",
            "min": 1,
            "max": 100,
            "step": 5,
            "unit_of_measurement": "%",
            "availability_topic": self.status_topic,
            "icon": "mdi:brightness-6",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/number/{self.device_id}/brightness/config",
            json.dumps(bright_disc), qos=1, retain=True
        )

        # 3. Reload Button
        reload_disc = {
            "name": f"{self.device_name} Reload",
            "unique_id": f"{self.device_id}_reload",
            "command_topic": f"{self.base_topic}/reload/set",
            "payload_press": "PRESS",
            "availability_topic": self.status_topic,
            "icon": "mdi:refresh",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/button/{self.device_id}/reload/config",
            json.dumps(reload_disc), qos=1, retain=True
        )

        # 4. Reboot Button
        reboot_disc = {
            "name": f"{self.device_name} Reboot",
            "unique_id": f"{self.device_id}_reboot",
            "command_topic": f"{self.base_topic}/reboot/set",
            "payload_press": "PRESS",
            "availability_topic": self.status_topic,
            "icon": "mdi:restart",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/button/{self.device_id}/reboot/config",
            json.dumps(reboot_disc), qos=1, retain=True
        )

        # 5. URL Sensor
        url_disc = {
            "name": f"{self.device_name} Active URL",
            "unique_id": f"{self.device_id}_url",
            "state_topic": f"{self.base_topic}/url/state",
            "availability_topic": self.status_topic,
            "icon": "mdi:web",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/sensor/{self.device_id}/url/config",
            json.dumps(url_disc), qos=1, retain=True
        )

        # 6. Temperature Sensor
        temp_disc = {
            "name": f"{self.device_name} CPU Temperature",
            "unique_id": f"{self.device_id}_temp",
            "state_topic": f"{self.base_topic}/system/state",
            "value_template": "{{ value_json.temperature }}",
            "unit_of_measurement": "°C",
            "device_class": "temperature",
            "state_class": "measurement",
            "availability_topic": self.status_topic,
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/sensor/{self.device_id}/temperature/config",
            json.dumps(temp_disc), qos=1, retain=True
        )

        # 7. IP Address Sensor
        ip_disc = {
            "name": f"{self.device_name} IP Address",
            "unique_id": f"{self.device_id}_ip",
            "state_topic": f"{self.base_topic}/system/state",
            "value_template": "{{ value_json.ip_address }}",
            "icon": "mdi:ip-network",
            "availability_topic": self.status_topic,
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/sensor/{self.device_id}/ip/config",
            json.dumps(ip_disc), qos=1, retain=True
        )

        # 8. Live Camera / Screen Snapshot
        cam_disc = {
            "name": f"{self.device_name} Camera",
            "unique_id": f"{self.device_id}_camera",
            "topic": f"{self.base_topic}/camera/image",
            "availability_topic": self.status_topic,
            "icon": "mdi:camera",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/camera/{self.device_id}/camera/config",
            json.dumps(cam_disc), qos=1, retain=True
        )

        # 9. Motion Binary Sensor
        motion_disc = {
            "name": f"{self.device_name} Motion",
            "unique_id": f"{self.device_id}_motion",
            "state_topic": f"{self.base_topic}/motion/state",
            "device_class": "motion",
            "availability_topic": self.status_topic,
            "payload_on": "ON",
            "payload_off": "OFF",
            "icon": "mdi:motion-sensor",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/binary_sensor/{self.device_id}/motion/config",
            json.dumps(motion_disc), qos=1, retain=True
        )

        # 10. Night Mode Switch
        night_disc = {
            "name": f"{self.device_name} Night Mode",
            "unique_id": f"{self.device_id}_nightmode",
            "state_topic": f"{self.base_topic}/nightmode/state",
            "command_topic": f"{self.base_topic}/nightmode/set",
            "availability_topic": self.status_topic,
            "payload_on": "ON",
            "payload_off": "OFF",
            "icon": "mdi:weather-night",
            "device": device_info
        }
        self.client.publish(
            f"{self.prefix}/switch/{self.device_id}/nightmode/config",
            json.dumps(night_disc), qos=1, retain=True
        )
        logger.info("Published Home Assistant MQTT discovery payloads.")

    def publish_states(self):
        if not self.is_connected:
            return

        screen_st = get_screen_state()
        self.client.publish(f"{self.base_topic}/screen/state", screen_st, qos=1, retain=True)

        is_locked = Path("/etc/chromium/policies/managed/kiosk_security_policy.json").exists()
        self.client.publish(f"{self.base_topic}/lockdown/state", "ON" if is_locked else "OFF", qos=1, retain=True)

        bright_val = get_screen_brightness()
        self.client.publish(f"{self.base_topic}/brightness/state", str(bright_val), qos=1, retain=True)

        cfg = load_config()
        url = cfg.get("dashboard_url", "http://homeassistant.local:8123/lovelace/0?kiosk")
        self.client.publish(f"{self.base_topic}/url/state", url, qos=1, retain=True)

        hide_menu_val = cfg.get("hide_sidebar_menu", True)
        self.client.publish(f"{self.base_topic}/hide_menu/state", "ON" if hide_menu_val else "OFF", qos=1, retain=True)

        is_admin_active = Path("/tmp/kiosk-admin-workstation").exists()
        self.client.publish(f"{self.base_topic}/admin_mode/state", "ON" if is_admin_active else "OFF", qos=1, retain=True)

        telemetry = {
            "ip_address": get_ip_address(),
            "temperature": get_cpu_temperature(),
            "memory_usage": get_memory_usage()
        }
        self.client.publish(f"{self.base_topic}/system/state", json.dumps(telemetry), qos=1, retain=True)

        if cfg.get("camera_publish_enabled", False) and Path("/dev/video0").exists():
            try:
                import urllib.request
                snap_data = urllib.request.urlopen("http://127.0.0.1:8080/api/camera/snapshot", timeout=2).read()
                if snap_data:
                    self.client.publish(f"{self.base_topic}/camera/image", snap_data, qos=0, retain=True)
            except Exception:
                pass

    def check_motion_and_nightmode(self):
        global LAST_FRAME_SAMPLE, MOTION_UNTIL, NIGHT_SCREEN_OFF
        cfg = load_config()

        # 1. Camera Motion Detection (opt-in only to conserve CPU)
        if cfg.get("camera_motion_enabled", False) and Path("/dev/video0").exists():
            try:
                import urllib.request
                req = urllib.request.Request("http://127.0.0.1:8080/api/camera/snapshot", headers={"User-Agent": "kiosk-mqtt"})
                raw_img = urllib.request.urlopen(req, timeout=1.5).read()
                if raw_img and len(raw_img) > 1000:
                    step = max(1, len(raw_img) // 200)
                    sample = raw_img[100:len(raw_img)-100:step]
                    if LAST_FRAME_SAMPLE and len(LAST_FRAME_SAMPLE) == len(sample):
                        diffs = sum(1 for a, b in zip(LAST_FRAME_SAMPLE, sample) if abs(a - b) > 25)
                        if diffs > (len(sample) * 0.12):
                            now = time.time()
                            if now > MOTION_UNTIL:
                                self.client.publish(f"{self.base_topic}/motion/state", "ON", qos=1, retain=True)
                            MOTION_UNTIL = now + 15
                            if NIGHT_SCREEN_OFF:
                                run_screen_cmd("on")
                                NIGHT_SCREEN_OFF = False
                                self.client.publish(f"{self.base_topic}/screen/state", "ON", qos=1, retain=True)
                    LAST_FRAME_SAMPLE = sample
            except Exception:
                pass

        if MOTION_UNTIL > 0 and time.time() > MOTION_UNTIL:
            self.client.publish(f"{self.base_topic}/motion/state", "OFF", qos=1, retain=True)
            MOTION_UNTIL = 0

        # 2. Automated Night Mode Scheduler
        night_en = cfg.get("night_mode_enabled", False)
        if night_en:
            now_hm = time.strftime("%H:%M")
            start = cfg.get("night_mode_start", "23:00")
            end = cfg.get("night_mode_end", "07:00")
            is_night = False
            if start <= end:
                is_night = (start <= now_hm < end)
            else:
                is_night = (now_hm >= start or now_hm < end)

            if is_night and time.time() > MOTION_UNTIL:
                current_st = get_screen_state()
                if current_st == "ON":
                    run_screen_cmd("off")
                    NIGHT_SCREEN_OFF = True
                    self.client.publish(f"{self.base_topic}/screen/state", "OFF", qos=1, retain=True)
            elif not is_night and NIGHT_SCREEN_OFF:
                run_screen_cmd("on")
                NIGHT_SCREEN_OFF = False
                self.client.publish(f"{self.base_topic}/screen/state", "ON", qos=1, retain=True)

    def run(self):
        while not self.stop_event.is_set():
            self.config = load_config()
            mqtt_cfg = self.config.get("mqtt", {})
            enabled = mqtt_cfg.get("enabled", False)
            broker = mqtt_cfg.get("broker", "").strip()

            if not enabled or not broker:
                logger.debug("MQTT is disabled or broker is empty. Waiting...")
                time.sleep(10)
                continue

            try:
                port = int(mqtt_cfg.get("port", 1883))
                logger.info(f"Connecting to MQTT broker at {broker}:{port}...")
                self.client = self.create_client()
                self.client.connect(broker, port, keepalive=60)
                self.client.loop_start()

                tick_count = 0
                while not self.stop_event.is_set():
                    new_cfg = load_config()
                    if new_cfg.get("mqtt") != self.config.get("mqtt"):
                        logger.info("MQTT configuration updated. Reconnecting...")
                        break

                    self.check_motion_and_nightmode()
                    tick_count += 1
                    if tick_count >= 15:  # every 30s
                        self.publish_states()
                        tick_count = 0
                    time.sleep(2)

                if self.client:
                    self.client.publish(self.status_topic, "offline", qos=1, retain=True)
                    self.client.loop_stop()
                    self.client.disconnect()

            except Exception as e:
                logger.error(f"MQTT error: {e}. Retrying in 15 seconds...")
                time.sleep(15)


def main():
    daemon = KioskMQTTDaemon()
    daemon.run()


if __name__ == "__main__":
    main()
