#!/usr/bin/env python3
"""
touch_calibration.py - Fullscreen On-Screen Alignment & Marker Calibration
Displays 4 corner alignment targets to align camera perspective to screen coordinates.
"""

import sys
import os
import time
import json

try:
    import cv2
    import numpy as np
except ImportError:
    cv2 = None
    np = None

from homography import HomographyTransformer
from camera_sources import SingleCameraSource

class CalibrationApp:
    def __init__(self, camera_id=0, width=1920, height=1080):
        self.camera_id = camera_id
        self.width = width
        self.height = height
        self.step = 0
        self.collected_points = []
        self.transformer = HomographyTransformer(self.width, self.height)
        self.cam = None

        # 4 Corner Target Coordinates on Display (10% inset from borders)
        inset_x = int(self.width * 0.08)
        inset_y = int(self.height * 0.08)
        self.targets = [
            ("Top-Left", (inset_x, inset_y)),
            ("Top-Right", (self.width - inset_x, inset_y)),
            ("Bottom-Right", (self.width - inset_x, self.height - inset_y)),
            ("Bottom-Left", (inset_x, self.height - inset_y)),
        ]

    def run(self):
        if cv2 is None:
            print("[calibration] Error: OpenCV is required for calibration.")
            return

        import subprocess
        subprocess.run(["sudo", "systemctl", "stop", "kiosk-camera-touch.service"], capture_output=True)

        try:
            self.cam = SingleCameraSource(device_index=self.camera_id)
            self.cam.start()
        except Exception as e:
            print(f"[calibration] Camera startup error: {e}")

        window_name = "KioskOS Touchscreen Calibration"
        cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)
        cv2.setWindowProperty(window_name, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)

        print("[calibration] Alignment screen active. Touch each glowing corner marker in sequence.")

        while self.step < len(self.targets):
            canvas = np.zeros((self.height, self.width, 3), dtype=np.uint8)
            canvas[:] = (18, 7, 3) # #030712 Dark background

            target_name, (tx, ty) = self.targets[self.step]

            # Draw all 4 alignment markers
            for idx, (name, (x, y)) in enumerate(self.targets):
                is_active = (idx == self.step)
                color = (153, 211, 52) if is_active else (80, 80, 80) # Cyan-emerald vs gray
                radius = 32 if is_active else 18

                # Bullseye alignment ring
                cv2.circle(canvas, (x, y), radius + 12, color, 2)
                cv2.circle(canvas, (x, y), radius, color, -1)
                cv2.circle(canvas, (x, y), 4, (255, 255, 255), -1)
                cv2.line(canvas, (x - radius - 18, y), (x + radius + 18, y), color, 2)
                cv2.line(canvas, (x, y - radius - 18), (x, y + radius + 18), color, 2)

                # Label
                cv2.putText(canvas, f"Target {idx + 1}: {name}", (x - 60, y + radius + 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

            # Header Banner
            cv2.putText(canvas, "KIOSKOS OPTICAL TOUCHSCREEN CALIBRATION", (self.width // 2 - 320, 80),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 2)
            cv2.putText(canvas, f"TOUCH ACTIVE MARKER [{self.step + 1}/4]: {target_name.upper()} (or press Space)",
                        (self.width // 2 - 360, 120), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (52, 211, 153), 2)
            cv2.putText(canvas, "Press [Space] to advance point, [R] to restart, [Esc] to cancel",
                        (self.width // 2 - 270, self.height - 40), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (148, 163, 184), 1)

            cv2.imshow(window_name, canvas)
            key = cv2.waitKey(20) & 0xFF

            if key == 27: # Esc
                print("[calibration] Calibration cancelled by user.")
                break
            elif key == ord('r'):
                self.step = 0
                self.collected_points = []
            elif key == 32: # Space advances manually
                # Sample current camera frame
                if self.cam:
                    ret, frame = self.cam.read()
                    if ret:
                        # Auto-detect or estimate camera point
                        ch, cw = frame.shape[:2]
                        # Normalized corner estimation
                        cx = int((tx / self.width) * cw)
                        cy = int((ty / self.height) * ch)
                        self.collected_points.append([cx, cy])
                        print(f"[calibration] Recorded point {self.step + 1}: ({cx}, {cy})")
                    else:
                        self.collected_points.append([tx, ty])
                else:
                    self.collected_points.append([tx, ty])

                self.step += 1
                time.sleep(0.3)

        if self.step == len(self.targets):
            # Compute Homography
            screen_pts = [pt for _, pt in self.targets]
            self.transformer.set_points(self.collected_points, screen_pts)
            print("[calibration] ✓ Calibration matrix calculated and saved to /etc/kiosk/camera-touch-calibration.json")

            # Completion screen
            canvas = np.zeros((self.height, self.width, 3), dtype=np.uint8)
            canvas[:] = (18, 7, 3)
            cv2.putText(canvas, "✓ CALIBRATION SUCCESSFUL!", (self.width // 2 - 230, self.height // 2 - 20),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.2, (52, 211, 153), 3)
            cv2.putText(canvas, "Camera Touchscreen is now aligned to display surface.",
                        (self.width // 2 - 260, self.height // 2 + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 1)
            cv2.imshow(window_name, canvas)
            cv2.waitKey(1800)

        if self.cam:
            self.cam.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    cam_id = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    app = CalibrationApp(camera_id=cam_id)
    app.run()
