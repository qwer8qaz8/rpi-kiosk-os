#!/usr/bin/env python3
"""
marker_tracker.py - Real-Time Dynamic Landmark Tracker for Moving Cameras
Continuously tracks 4 corner mini-markers on display to dynamically adjust homography.
"""

import numpy as np

try:
    import cv2
except ImportError:
    cv2 = None

class DynamicMarkerTracker:
    def __init__(self, screen_width=1920, screen_height=1080):
        self.screen_width = screen_width
        self.screen_height = screen_height
        self.last_corners = None
        self.alpha = 0.25 # Smoothing for homography updates

    def detect_markers(self, frame):
        """
        Locates the 4 corner persistent mini-markers in the camera frame.
        Markers are high-contrast glowing emerald/cyan points in 4 quadrants.
        Returns: (success, [(u0, v0), (u1, v1), (u2, v2), (u3, v3)])
        """
        if frame is None or cv2 is None:
            return False, self.last_corners

        h, w = frame.shape[:2]
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)

        # Emerald / Cyan marker color range
        lower_marker = np.array([35, 120, 140], dtype=np.uint8)
        upper_marker = np.array([95, 255, 255], dtype=np.uint8)
        mask = cv2.inRange(hsv, lower_marker, upper_marker)

        # Quadrant dividing lines
        mid_x, mid_y = w // 2, h // 2
        quadrants = [
            (0, 0, mid_x, mid_y),         # Top-Left (Q0)
            (mid_x, 0, w, mid_y),         # Top-Right (Q1)
            (mid_x, mid_y, w, h),         # Bottom-Right (Q2)
            (0, mid_y, mid_x, h),         # Bottom-Left (Q3)
        ]

        found_corners = []

        for qx1, qy1, qx2, qy2 in quadrants:
            quad_mask = np.zeros_like(mask)
            quad_mask[qy1:qy2, qx1:qx2] = mask[qy1:qy2, qx1:qx2]
            contours, _ = cv2.findContours(quad_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if contours:
                # Find most compact circular contour
                best_pt = None
                best_score = 0
                for c in contours:
                    area = cv2.contourArea(c)
                    if 15 < area < 1500:
                        M = cv2.moments(c)
                        if M["m00"] > 0:
                            cx = int(M["m10"] / M["m00"])
                            cy = int(M["m01"] / M["m00"])
                            best_pt = (cx, cy)
                            break
                if best_pt:
                    found_corners.append(best_pt)

        if len(found_corners) == 4:
            # Smooth with previous corners
            if self.last_corners is not None:
                smoothed = []
                for idx in range(4):
                    sx = self.alpha * found_corners[idx][0] + (1.0 - self.alpha) * self.last_corners[idx][0]
                    sy = self.alpha * found_corners[idx][1] + (1.0 - self.alpha) * self.last_corners[idx][1]
                    smoothed.append((sx, sy))
                self.last_corners = smoothed
            else:
                self.last_corners = found_corners
            return True, self.last_corners

        # If temporarily occluded, maintain last known corners
        if self.last_corners is not None:
            return True, self.last_corners

        return False, None
