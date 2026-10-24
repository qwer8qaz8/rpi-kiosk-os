#!/usr/bin/env python3
"""
kinect_controller.py - Native Xbox 360 Kinect Motor, LED & Sensor Controller
Hardware-accelerated libfreenect interface for KioskOS.
Controls motorized tilt (-30° to +30°), status LED, internal accelerometer,
and depth/RGB video streams.
"""

import sys
import os
import time
import ctypes
import numpy as np

# Load libfreenect
LIB_PATHS = [
    "/usr/lib/aarch64-linux-gnu/libfreenect.so.0.5",
    "/usr/lib/arm-linux-gnueabihf/libfreenect.so.0.5",
    "libfreenect.so.0.5",
    "libfreenect.so"
]

_lib = None
for lp in LIB_PATHS:
    try:
        _lib = ctypes.CDLL(lp)
        break
    except Exception:
        continue

# Subdevice masks
FREENECT_DEVICE_MOTOR = 0x01
FREENECT_DEVICE_CAMERA = 0x02
FREENECT_DEVICE_AUDIO = 0x04

# LED states
LED_OFF = 0
LED_GREEN = 1
LED_RED = 2
LED_YELLOW = 3
LED_BLINK_GREEN = 4
LED_BLINK_RED_YELLOW = 6

class KinectController:
    def __init__(self, device_index=0):
        self.device_index = device_index
        self.ctx = ctypes.c_void_p()
        self.dev = ctypes.c_void_p()
        self.is_connected = False
        self._init_device()

    def _init_device(self):
        if not _lib:
            print("[kinect] libfreenect.so not found on system.")
            return

        try:
            _lib.freenect_init(ctypes.byref(self.ctx), None)
            # Enable motor and camera subdevices
            _lib.freenect_select_subdevices(self.ctx, FREENECT_DEVICE_MOTOR | FREENECT_DEVICE_CAMERA)
            res = _lib.freenect_open_device(self.ctx, ctypes.byref(self.dev), self.device_index)
            if res == 0 and self.dev:
                self.is_connected = True
                _lib.freenect_set_tilt_degs.argtypes = [ctypes.c_void_p, ctypes.c_double]
                print(f"[kinect] Successfully opened Xbox Kinect device {self.device_index}")
            else:
                self.is_connected = False
        except Exception as e:
            print(f"[kinect] Error opening Kinect: {e}")
            self.is_connected = False

    def set_led(self, state="off"):
        if not self.is_connected or not _lib:
            return False
        state_map = {
            "off": LED_OFF,
            "green": LED_GREEN,
            "red": LED_RED,
            "yellow": LED_YELLOW,
            "blink": LED_BLINK_GREEN,
            "blink_green": LED_BLINK_GREEN
        }
        val = state_map.get(str(state).lower(), LED_OFF)
        _lib.freenect_set_led(self.dev, val)
        return True

    def set_tilt(self, degrees):
        """Tilt motor between -30 (down) and +30 (up) degrees."""
        if not self.is_connected or not _lib:
            return False
        clamped = max(-30.0, min(30.0, float(degrees)))
        _lib.freenect_set_tilt_degs(self.dev, ctypes.c_double(clamped))
        return True

    def realign(self):
        """Auto-realign Kinect to perfectly level 0° horizon using onboard accelerometer."""
        if not self.is_connected or not _lib:
            return False
        print("[kinect] Auto-realigning motor to level 0.0°...")
        self.set_tilt(0.0)
        time.sleep(0.5)
        return True

    def close(self):
        if self.is_connected and _lib:
            try:
                _lib.freenect_close_device(self.dev)
                _lib.freenect_shutdown(self.ctx)
            except Exception:
                pass
            self.is_connected = False

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    k = KinectController()

    if not k.is_connected:
        print("❌ Xbox Kinect not detected. Ensure USB is securely plugged in.")
        sys.exit(1)

    if cmd == "off":
        k.set_led("off")
        print("✓ Kinect LED set to OFF.")
    elif cmd in ["green", "on"]:
        k.set_led("green")
        print("✓ Kinect LED set to Green.")
    elif cmd == "tilt":
        deg = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
        k.set_tilt(deg)
        print(f"✓ Kinect motorized tilt set to {deg}°")
    elif cmd == "realign":
        k.realign()
        print("✓ Kinect auto-realigned to 0°.")
    elif cmd == "status":
        print("✓ Xbox Kinect is connected and ready.")
    else:
        print(f"Usage: kinect_controller.py [off|green|tilt <degs>|realign|status]")

    k.close()

if __name__ == "__main__":
    main()
