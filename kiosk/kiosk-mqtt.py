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
    if SCREEN_CONTROL_SCRIPT.exists() and os.access(SCREEN_CONTROL_SCRIPT, os.X_OK):
        cmd = [str(SCREEN_CONTROL_SCRIPT), action]
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
        client.subscribe(f"{self.base_topic}/brightness/set", qos=1)
        client.subscribe(f"{self.base_topic}/url/set", qos=1)
        client.subscribe(f"{self.base_topic}/reload/set", qos=1)
        client.subscribe(f"{self.base_topic}/reboot/set", qos=1)
        
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
        logger.info("Published Home Assistant MQTT discovery payloads.")

    def publish_states(self):
        if not self.is_connected:
            return

        screen_st = get_screen_state()
        self.client.publish(f"{self.base_topic}/screen/state", screen_st, qos=1, retain=True)

        bright_val = get_screen_brightness()
        self.client.publish(f"{self.base_topic}/brightness/state", str(bright_val), qos=1, retain=True)

        cfg = load_config()
        url = cfg.get("dashboard_url", "http://homeassistant.local:8123/lovelace/0?kiosk")
        self.client.publish(f"{self.base_topic}/url/state", url, qos=1, retain=True)

        telemetry = {
            "ip_address": get_ip_address(),
            "temperature": get_cpu_temperature(),
            "memory_usage": get_memory_usage()
        }
        self.client.publish(f"{self.base_topic}/system/state", json.dumps(telemetry), qos=1, retain=True)

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

                while not self.stop_event.is_set():
                    new_cfg = load_config()
                    if new_cfg.get("mqtt") != self.config.get("mqtt"):
                        logger.info("MQTT configuration updated. Reconnecting...")
                        break

                    self.publish_states()
                    time.sleep(30)

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
