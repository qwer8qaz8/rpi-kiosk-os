#!/usr/bin/env python3
"""
kiosk-camera-touch.py - Main Background Engine for Optical Camera Touchscreen
Runs continuously, tracking 1 or 2 cameras or Xbox Kinect, and feeding Linux uinput.
"""

import sys
import os
import time
import json
import signal

try:
    import cv2
    import numpy as np
except ImportError:
    cv2 = None
    np = None

from camera_sources import SingleCameraSource, DualCameraSource, KinectSource
from touch_detector import TouchDetector
from homography import HomographyTransformer
from uinput_touch import VirtualTouchScreen
from marker_tracker import DynamicMarkerTracker
import subprocess

CONFIG_PATHS = ["/etc/kiosk/config.json", "/opt/kiosk/config.json"]

def load_config():
    for p in CONFIG_PATHS:
        if os.path.exists(p):
            try:
                with open(p, "r") as f:
                    return json.load(f)
            except Exception:
                pass
    return {}

class CameraTouchDaemon:
    def __init__(self):
        self.running = True
        self.config = load_config()
        self.touch_cfg = self.config.get("camera_touch", {})
        self.mode = self.touch_cfg.get("mode", "single") # "single", "dual", "kinect"
        self.cameras = self.touch_cfg.get("cameras", [0])
        self.dynamic_tracking = self.touch_cfg.get("dynamic_tracking", False)
        self.marker_overlay_proc = None
        self.frame_idx = 0

        self.source = None
        self.detector = None
        self.transformer = None
        self.touchscreen = None
        self.marker_tracker = None
        self.last_touch = False

        signal.signal(signal.SIGINT, self.handle_signal)
        signal.signal(signal.SIGTERM, self.handle_signal)
        signal.signal(signal.SIGHUP, self.reload_config)

    def handle_signal(self, signum, frame):
        print(f"[touch-daemon] Received signal {signum}. Stopping...")
        self.running = False

    def reload_config(self, signum, frame):
        print("[touch-daemon] Reloading configuration and calibration...")
        self.config = load_config()
        self.touch_cfg = self.config.get("camera_touch", {})
        if self.transformer:
            self.transformer.load_calibration()

    def setup(self):
        if cv2 is None:
            raise RuntimeError("OpenCV (python3-opencv) is not installed.")

        self.transformer = HomographyTransformer()
        self.detector = TouchDetector(mode=self.mode)
        self.marker_tracker = DynamicMarkerTracker(
            screen_width=self.transformer.screen_width,
            screen_height=self.transformer.screen_height
        )
        self.touchscreen = VirtualTouchScreen(
            screen_width=self.transformer.screen_width,
            screen_height=self.transformer.screen_height
        )

        if self.dynamic_tracking:
            self.start_marker_overlay()

        if self.mode == "dual" and len(self.cameras) >= 2:
            self.source = DualCameraSource(cam_a=self.cameras[0], cam_b=self.cameras[1])
        elif self.mode == "kinect":
            self.source = KinectSource()
        else:
            cam_idx = self.cameras[0] if self.cameras else 0
            self.source = SingleCameraSource(device_index=cam_idx)

        self.source.start()
        print(f"[touch-daemon] Optical Touchscreen daemon active in '{self.mode}' mode.")

    def start_marker_overlay(self):
        overlay_script = "/opt/kiosk/camera-touch/kiosk-marker-overlay.py"
        if os.path.exists(overlay_script) and self.marker_overlay_proc is None:
            try:
                self.marker_overlay_proc = subprocess.Popen(["python3", overlay_script])
                print("[touch-daemon] Started persistent dynamic marker overlay.")
            except Exception as e:
                print(f"[touch-daemon] Could not start marker overlay: {e}")

    def stop_marker_overlay(self):
        if self.marker_overlay_proc:
            try:
                self.marker_overlay_proc.terminate()
            except Exception:
                pass
            self.marker_overlay_proc = None

    def run(self):
        self.setup()
        try:
            while self.running:
                self.frame_idx += 1
                if self.mode == "single":
                    ret, frame = self.source.read()
                    if not ret or frame is None:
                        time.sleep(0.02)
                        continue

                    # Dynamic Real-Time Homography Adjustment (every 6 frames)
                    if self.dynamic_tracking and (self.frame_idx % 6 == 0):
                        found_markers, corners = self.marker_tracker.detect_markers(frame)
                        if found_markers and corners:
                            self.transformer.set_points(corners)

                    found, (u, v), is_touch, _ = self.detector.process_single_frame(frame)
                    if found:
                        sx, sy, within = self.transformer.transform(u, v)
                        if is_touch and within:
                            if not self.last_touch:
                                self.touchscreen.touch_down(sx, sy)
                            else:
                                self.touchscreen.touch_move(sx, sy)
                            self.last_touch = True
                        else:
                            if self.last_touch:
                                self.touchscreen.touch_up()
                            self.last_touch = False
                    else:
                        if self.last_touch:
                            self.touchscreen.touch_up()
                        self.last_touch = False

                elif self.mode == "dual":
                    ret, frame_a, frame_b = self.source.read()
                    if not ret:
                        time.sleep(0.02)
                        continue

                    found, (u, v), is_touch, _, _ = self.detector.process_dual_frames(frame_a, frame_b)
                    if found:
                        sx, sy, within = self.transformer.transform(u, v)
                        if is_touch and within:
                            if not self.last_touch:
                                self.touchscreen.touch_down(sx, sy)
                            else:
                                self.touchscreen.touch_move(sx, sy)
                            self.last_touch = True
                        else:
                            if self.last_touch:
                                self.touchscreen.touch_up()
                            self.last_touch = False
                    else:
                        if self.last_touch:
                            self.touchscreen.touch_up()
                        self.last_touch = False

                elif self.mode == "kinect":
                    ret, depth, rgb = self.source.read_depth_and_rgb()
                    if not ret:
                        time.sleep(0.02)
                        continue

                    found, (u, v), is_touch, _ = self.detector.process_kinect(depth, rgb)
                    if found:
                        sx, sy, within = self.transformer.transform(u, v)
                        if is_touch and within:
                            if not self.last_touch:
                                self.touchscreen.touch_down(sx, sy)
                            else:
                                self.touchscreen.touch_move(sx, sy)
                            self.last_touch = True
                        else:
                            if self.last_touch:
                                self.touchscreen.touch_up()
                            self.last_touch = False
                    else:
                        if self.last_touch:
                            self.touchscreen.touch_up()
                        self.last_touch = False

                # Maintain 30-60 Hz loop with low CPU usage
                time.sleep(0.01)

        finally:
            self.stop_marker_overlay()
            if self.touchscreen:
                self.touchscreen.close()
            if self.source:
                self.source.release()
            print("[touch-daemon] Stopped cleanly.")

if __name__ == "__main__":
    daemon = CameraTouchDaemon()
    daemon.run()
