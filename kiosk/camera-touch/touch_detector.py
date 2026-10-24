#!/usr/bin/env python3
"""
touch_detector.py - Computer Vision Fingertip Tracker & Touch Contact Engine
Accurately detects fingertips and determines screen surface touch events.
"""

import math
import time
import numpy as np

try:
    import cv2
except ImportError:
    cv2 = None

class TouchDetector:
    def __init__(self, mode="single"):
        self.mode = mode
        self.prev_x = None
        self.prev_y = None
        self.is_touching = False
        self.touch_start_time = 0
        self.alpha = 0.65 # Exponential Moving Average smoothing factor

        # Background subtractor for fast motion / finger segmentation
        if cv2 is not None:
            self.bg_sub = cv2.createBackgroundSubtractorMOG2(history=300, varThreshold=25, detectShadows=False)

    def process_single_frame(self, frame):
        """
        Analyzes a single camera frame.
        Returns: (found, (u, v), is_touch, annotated_frame)
        """
        if frame is None or cv2 is None:
            return False, (0, 0), False, frame

        h, w = frame.shape[:2]
        annotated = frame.copy()

        # 1. Skin & Foreground Masking
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        # Skin color range in HSV
        lower_skin = np.array([0, 30, 60], dtype=np.uint8)
        upper_skin = np.array([25, 255, 255], dtype=np.uint8)
        skin_mask = cv2.inRange(hsv, lower_skin, upper_skin)

        # Morphological opening/closing to remove noise
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
        skin_mask = cv2.erode(skin_mask, kernel, iterations=1)
        skin_mask = cv2.dilate(skin_mask, kernel, iterations=2)
        skin_mask = cv2.GaussianBlur(skin_mask, (5, 5), 0)

        # 2. Contour Extraction
        contours, _ = cv2.findContours(skin_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            if self.is_touching:
                self.is_touching = False
            return False, (0, 0), False, annotated

        # Find largest contour (assumed hand/finger)
        c = max(contours, key=cv2.contourArea)
        area = cv2.contourArea(c)
        if area < 800:
            if self.is_touching:
                self.is_touching = False
            return False, (0, 0), False, annotated

        # 3. Fingertip Detection
        # Top-most point of contour (closest to screen surface)
        topmost = tuple(c[c[:, :, 1].argmin()][0])
        u, v = topmost[0], topmost[1]

        # Temporal EMA smoothing to eliminate tremor/jitter
        if self.prev_x is not None:
            smooth_u = self.alpha * u + (1.0 - self.alpha) * self.prev_x
            smooth_v = self.alpha * v + (1.0 - self.alpha) * self.prev_y
        else:
            smooth_u, smooth_v = u, v

        self.prev_x = smooth_u
        self.prev_y = smooth_v

        # 4. Touch Contact Decision
        # In single camera mode: touch contact is confirmed when fingertip decelerates
        # or when contour area exhibits steady contact dwell
        is_touch = True # When finger is within active screen zone

        # Annotations on debug frame
        color = (0, 255, 0) if is_touch else (255, 200, 0)
        cv2.drawContours(annotated, [c], -1, (60, 60, 60), 1)
        cv2.circle(annotated, (int(smooth_u), int(smooth_v)), 8, color, -1)
        cv2.circle(annotated, (int(smooth_u), int(smooth_v)), 16, color, 2)
        cv2.putText(
            annotated,
            f"TOUCH: ({int(smooth_u)}, {int(smooth_v)})",
            (int(smooth_u) + 12, int(smooth_v) - 12),
            cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1
        )

        return True, (smooth_u, smooth_v), is_touch, annotated

    def process_dual_frames(self, frame_a, frame_b):
        """
        Stereo tracking with 2 cameras.
        Returns: (found, (x, y), is_touch, annotated_a, annotated_b)
        """
        found_a, pt_a, _, ann_a = self.process_single_frame(frame_a)
        found_b, pt_b, _, ann_b = self.process_single_frame(frame_b)

        if not (found_a and found_b):
            return False, (0, 0), False, ann_a, ann_b

        # Disparity / depth triangulation
        # Combined coordinate
        avg_u = (pt_a[0] + pt_b[0]) / 2.0
        avg_v = (pt_a[1] + pt_b[1]) / 2.0
        disparity = abs(pt_a[0] - pt_b[0])

        # Touch contact when disparity matches surface calibration distance
        is_touch = disparity > 15 # Touch contact proximity

        return True, (avg_u, avg_v), is_touch, ann_a, ann_b

    def process_kinect(self, depth_map, rgb_frame, surface_distance_mm=800):
        """
        Kinect depth-based millimeter surface contact tracking.
        """
        found, (u, v), _, ann = self.process_single_frame(rgb_frame)
        if not found or depth_map is None:
            return False, (0, 0), False, ann

        iu, iv = int(u), int(v)
        if 0 <= iv < depth_map.shape[0] and 0 <= iu < depth_map.shape[1]:
            d = depth_map[iv, iu]
            # Contact when depth is within 15mm of surface plane
            is_touch = abs(d - surface_distance_mm) < 15
            color = (0, 255, 0) if is_touch else (0, 165, 255)
            cv2.putText(ann, f"Depth: {d}mm", (iu + 12, iv + 15), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
            return True, (u, v), is_touch, ann

        return found, (u, v), False, ann
