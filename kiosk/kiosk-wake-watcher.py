#!/usr/bin/env python3
"""
kiosk-wake-watcher.py - Exclusive Keyboard Wake Listener for Kiosk Display
Monitors connected physical keyboard devices for keypress events.
When any key is pressed down, it restores HDMI DPMS output via Wayland (wlopm --on)
and cleanly terminates. Mouse movements, vibrations, and phantom touches are strictly ignored.
"""

import os
import sys
import glob
import time
import struct
import select
import subprocess
import re
import logging

LOG_FILE = "/tmp/kiosk-wake.log"
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def run_wayland(cmd_list):
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = "/run/user/1000"
    env["WAYLAND_DISPLAY"] = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    try:
        subprocess.run(cmd_list, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        logging.error(f"Error running {cmd_list}: {e}")

def get_outputs():
    outputs = []
    try:
        env = os.environ.copy()
        env["XDG_RUNTIME_DIR"] = "/run/user/1000"
        env["WAYLAND_DISPLAY"] = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        res = subprocess.run(["wlr-randr"], env=env, capture_output=True, text=True)
        for line in res.stdout.splitlines():
            m = re.match(r"^([A-Za-z0-9-]+)\s+", line)
            if m:
                outputs.append(m.group(1))
    except Exception:
        pass
    if not outputs:
        outputs = ["HDMI-A-1"]
    return outputs

def wake_screen():
    logging.info("Keyboard key pressed! Waking display...")
    for out in get_outputs():
        run_wayland(["wlopm", "--on", out])

    # Update config file state
    cfg_path = "/opt/kiosk/kiosk-config.json"
    if os.path.exists(cfg_path):
        try:
            import json
            with open(cfg_path, "r") as f:
                cfg = json.load(f)
            cfg["screen_on"] = True
            with open(cfg_path, "w") as f:
                json.dump(cfg, f, indent=2)
        except Exception:
            pass

    # Notify screen-control or MQTT
    try:
        subprocess.run(["/opt/kiosk/screen-control.sh", "on"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

def find_keyboards():
    devs = []
    # 1. By-id symlinks
    for p in glob.glob("/dev/input/by-id/*-kbd*") + glob.glob("/dev/input/by-id/*-event-kbd*"):
        try:
            real = os.path.realpath(p)
            if real not in devs and os.access(real, os.R_OK):
                devs.append(real)
        except Exception:
            pass

    # 2. Check /proc/bus/input/devices for kbd handlers
    if os.path.exists("/proc/bus/input/devices"):
        try:
            with open("/proc/bus/input/devices", "r") as f:
                blocks = f.read().split("\n\n")
            for b in blocks:
                if "Handlers=" in b and "kbd" in b:
                    # Exclude HDMI CEC remote receiver
                    if "vc4-hdmi" in b:
                        continue
                    for ev in re.findall(r"event\d+", b):
                        p = f"/dev/input/{ev}"
                        if os.path.exists(p) and p not in devs and os.access(p, os.R_OK):
                            devs.append(p)
        except Exception:
            pass
    return devs

def main():
    # Grace period: let any physical button/key release finish before listening
    time.sleep(0.5)

    kb_devs = find_keyboards()
    logging.info(f"Active keyboards detected: {kb_devs}")

    fds = {}
    for dev_path in kb_devs:
        try:
            fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK)
            fds[fd] = dev_path
            # Flush existing events
            try:
                while os.read(fd, 24):
                    pass
            except BlockingIOError:
                pass
        except Exception as e:
            logging.warning(f"Could not open {dev_path}: {e}")

    # Fallback only if no keyboard is connected to prevent permanent lockouts
    if not fds:
        logging.warning("No physical keyboard found; falling back to mice device.")
        if os.path.exists("/dev/input/mice"):
            try:
                fd = os.open("/dev/input/mice", os.O_RDONLY | os.O_NONBLOCK)
                fds[fd] = "/dev/input/mice"
            except Exception:
                pass

    if not fds:
        logging.error("No input devices available for wake. Exiting.")
        sys.exit(1)

    logging.info("Listening exclusively for keyboard keypress to wake...")

    EVENT_FORMAT = "qqHHi"
    EVENT_SIZE = struct.calcsize(EVENT_FORMAT) # 24 bytes

    while True:
        r, _, _ = select.select(list(fds.keys()), [], [], 5.0)
        for fd in r:
            try:
                data = os.read(fd, EVENT_SIZE * 16)
                if not data:
                    continue

                if fds[fd] == "/dev/input/mice":
                    wake_screen()
                    return

                for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    chunk = data[i:i + EVENT_SIZE]
                    sec, usec, ev_type, code, val = struct.unpack(EVENT_FORMAT, chunk)
                    # EV_KEY = 1, val == 1 is Key Press (down)
                    if ev_type == 1 and val == 1:
                        logging.info(f"Key press detected (code={code}) on {fds[fd]}. Waking screen!")
                        wake_screen()
                        return
            except (BlockingIOError, OSError):
                continue

if __name__ == "__main__":
    main()
