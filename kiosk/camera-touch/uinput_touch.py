#!/usr/bin/env python3
"""
uinput_touch.py - Linux Kernel Virtual Touchscreen Driver via uinput
Creates a native hardware-recognized multi-touch digitizer for KioskOS.
"""

import sys
import os
import time

try:
    import evdev
    from evdev import UInput, ecodes as e, AbsInfo
    HAS_EVDEV = True
except ImportError:
    HAS_EVDEV = False

import subprocess

class VirtualTouchScreen:
    def __init__(self, screen_width=1920, screen_height=1080):
        self.width = screen_width
        self.height = screen_height
        self.ui = None
        self.tracking_id = 0
        self.is_touching = False
        self.use_fallback = False

        if HAS_EVDEV:
            try:
                cap = {
                    e.EV_KEY: [e.BTN_TOUCH, e.BTN_TOOL_FINGER],
                    e.EV_ABS: [
                        (e.ABS_X, AbsInfo(value=0, min=0, max=self.width, fuzz=0, flat=0, resolution=1)),
                        (e.ABS_Y, AbsInfo(value=0, min=0, max=self.height, fuzz=0, flat=0, resolution=1)),
                        (e.ABS_MT_SLOT, AbsInfo(value=0, min=0, max=9, fuzz=0, flat=0, resolution=0)),
                        (e.ABS_MT_TRACKING_ID, AbsInfo(value=-1, min=-1, max=65535, fuzz=0, flat=0, resolution=0)),
                        (e.ABS_MT_POSITION_X, AbsInfo(value=0, min=0, max=self.width, fuzz=0, flat=0, resolution=1)),
                        (e.ABS_MT_POSITION_Y, AbsInfo(value=0, min=0, max=self.height, fuzz=0, flat=0, resolution=1)),
                    ]
                }
                self.ui = UInput(cap, name="KioskOS Optical Touchscreen", version=0x1)
                print(f"[touch-uinput] Initialized virtual touchscreen digitizer ({self.width}x{self.height})")
            except Exception as ex:
                print(f"[touch-uinput] Warning: /dev/uinput open failed ({ex}). Falling back to virtual pointer injection.")
                self.use_fallback = True
        else:
            self.use_fallback = True

    def touch_down(self, x, y):
        x = max(0, min(self.width, int(x)))
        y = max(0, min(self.height, int(y)))
        self.tracking_id = (self.tracking_id + 1) % 65535

        if self.ui:
            self.ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
            self.ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, self.tracking_id)
            self.ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, x)
            self.ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, y)
            self.ui.write(e.EV_ABS, e.ABS_X, x)
            self.ui.write(e.EV_ABS, e.ABS_Y, y)
            self.ui.write(e.EV_KEY, e.BTN_TOUCH, 1)
            self.ui.write(e.EV_KEY, e.BTN_TOOL_FINGER, 1)
            self.ui.syn()
        elif self.use_fallback:
            # Fallback via ydotool or wtype if available
            subprocess.run(["ydotool", "mousemove", "--absolute", str(x), str(y)], capture_output=True)
            subprocess.run(["ydotool", "click", "0xC0"], capture_output=True)

        self.is_touching = True

    def touch_move(self, x, y):
        if not self.is_touching:
            self.touch_down(x, y)
            return

        x = max(0, min(self.width, int(x)))
        y = max(0, min(self.height, int(y)))

        if self.ui:
            self.ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
            self.ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, x)
            self.ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, y)
            self.ui.write(e.EV_ABS, e.ABS_X, x)
            self.ui.write(e.EV_ABS, e.ABS_Y, y)
            self.ui.syn()
        elif self.use_fallback:
            subprocess.run(["ydotool", "mousemove", "--absolute", str(x), str(y)], capture_output=True)

    def touch_up(self):
        if not self.is_touching:
            return

        if self.ui:
            self.ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
            self.ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
            self.ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
            self.ui.write(e.EV_KEY, e.BTN_TOOL_FINGER, 0)
            self.ui.syn()
        elif self.use_fallback:
            subprocess.run(["ydotool", "click", "0x80"], capture_output=True)

        self.is_touching = False

    def close(self):
        if self.ui:
            self.touch_up()
            self.ui.close()
