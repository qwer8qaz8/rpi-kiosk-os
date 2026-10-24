#!/usr/bin/env python3
"""
homography.py - Perspective Transformation & Screen Space Mapping
Transforms camera pixel space (u, v) into display coordinates (x, y).
"""

import os
import json
import numpy as np

try:
    import cv2
except ImportError:
    cv2 = None

CONFIG_FILE = "/etc/kiosk/camera-touch-calibration.json"
FALLBACK_FILE = "/opt/kiosk/camera-touch-calibration.json"

class HomographyTransformer:
    def __init__(self, screen_width=1920, screen_height=1080):
        self.screen_width = screen_width
        self.screen_height = screen_height
        self.matrix = None
        self.calibrated = False
        self.load_calibration()

    def set_points(self, src_points, dst_points=None):
        """
        src_points: List of 4 (u, v) points in camera image:
          [Top-Left, Top-Right, Bottom-Right, Bottom-Left]
        """
        if dst_points is None:
            dst_points = [
                [0, 0],
                [self.screen_width, 0],
                [self.screen_width, self.screen_height],
                [0, self.screen_height]
            ]

        src = np.array(src_points, dtype=np.float32)
        dst = np.array(dst_points, dtype=np.float32)

        if cv2 is not None:
            self.matrix = cv2.getPerspectiveTransform(src, dst)
        else:
            # Fallback direct homography calculation
            self.matrix = self._compute_homography(src, dst)

        self.calibrated = True
        self.save_calibration(src_points)

    def transform(self, u, v):
        """
        Transforms camera coordinate (u, v) into screen (x, y).
        Returns (x, y, is_within_screen)
        """
        if self.matrix is None:
            # Normalized direct scaling fallback if uncalibrated
            return int(u), int(v), True

        pt = np.array([u, v, 1.0], dtype=np.float32)
        res = np.dot(self.matrix, pt)
        if abs(res[2]) < 1e-6:
            return 0, 0, False

        x = res[0] / res[2]
        y = res[1] / res[2]

        within = (0 <= x <= self.screen_width) and (0 <= y <= self.screen_height)
        return int(x), int(y), within

    def save_calibration(self, src_points):
        data = {
            "screen_width": self.screen_width,
            "screen_height": self.screen_height,
            "src_points": src_points,
            "matrix": self.matrix.tolist() if self.matrix is not None else None
        }
        for path in [CONFIG_FILE, FALLBACK_FILE]:
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    json.dump(data, f, indent=2)
                break
            except Exception:
                pass

    def load_calibration(self):
        for path in [CONFIG_FILE, FALLBACK_FILE]:
            if os.path.exists(path):
                try:
                    with open(path, "r") as f:
                        data = json.load(f)
                        self.screen_width = data.get("screen_width", self.screen_width)
                        self.screen_height = data.get("screen_height", self.screen_height)
                        if "matrix" in data and data["matrix"]:
                            self.matrix = np.array(data["matrix"], dtype=np.float32)
                            self.calibrated = True
                            return True
                except Exception:
                    pass
        return False

    def _compute_homography(self, src, dst):
        # 8-point linear solver fallback
        A = []
        for i in range(4):
            x, y = src[i][0], src[i][1]
            u, v = dst[i][0], dst[i][1]
            A.append([-x, -y, -1, 0, 0, 0, x*u, y*u, u])
            A.append([0, 0, 0, -x, -y, -1, x*v, y*v, v])
        A = np.asarray(A)
        _, _, Vh = np.linalg.svd(A)
        L = Vh[-1, :] / Vh[-1, -1]
        return L.reshape(3, 3)
