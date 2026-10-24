#!/usr/bin/env python3
"""
camera_sources.py - Unified Camera Interface for Optical Touchscreen
Supports Single Camera, Dual Camera (Stereo), and Xbox Kinect (Depth).
"""

import sys
import time
import os

try:
    import cv2
    import numpy as np
except ImportError:
    cv2 = None
    np = None

class SingleCameraSource:
    def __init__(self, device_index=0, width=640, height=480, fps=30):
        self.device_index = device_index
        self.width = width
        self.height = height
        self.fps = fps
        self.cap = None

    def start(self):
        if cv2 is None:
            raise RuntimeError("OpenCV is required for camera capture.")

        import glob
        devices_to_try = [self.device_index]
        for dev in sorted(glob.glob("/dev/video*")):
            try:
                idx = int(dev.replace("/dev/video", ""))
                if idx not in devices_to_try:
                    devices_to_try.append(idx)
            except Exception:
                pass

        for dev_idx in devices_to_try:
            for backend in [cv2.CAP_V4L2, None]:
                try:
                    if backend is not None:
                        self.cap = cv2.VideoCapture(dev_idx, backend)
                    else:
                        self.cap = cv2.VideoCapture(dev_idx)
                    if self.cap.isOpened():
                        self.device_index = dev_idx
                        break
                except Exception:
                    continue
            if self.cap and self.cap.isOpened():
                break

        if not self.cap or not self.cap.isOpened():
            raise RuntimeError(f"Could not open camera device (tried: {devices_to_try})")

        # Crucial for USB webcams on Raspberry Pi: Request MJPG to conserve USB bus bandwidth and trigger LED
        try:
            self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
        except Exception:
            pass

        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
        self.cap.set(cv2.CAP_PROP_FPS, self.fps)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1) # Low latency

        print(f"[camera] Single camera source started on device {self.device_index} ({self.width}x{self.height} @ {self.fps}fps)")

    def read(self):
        if not self.cap:
            return False, None
        return self.cap.read()

    def release(self):
        if self.cap:
            self.cap.release()
            self.cap = None

class DualCameraSource:
    def __init__(self, cam_a=0, cam_b=1, width=640, height=480, fps=30):
        self.cam_a = SingleCameraSource(cam_a, width, height, fps)
        self.cam_b = SingleCameraSource(cam_b, width, height, fps)

    def start(self):
        self.cam_a.start()
        self.cam_b.start()
        print("[camera] Dual camera (stereo) sources started successfully.")

    def read(self):
        ret_a, frame_a = self.cam_a.read()
        ret_b, frame_b = self.cam_b.read()
        if not (ret_a and ret_b):
            return False, None, None
        return True, frame_a, frame_b

    def release(self):
        self.cam_a.release()
        self.cam_b.release()

class KinectSource:
    """
    Xbox Kinect v1/v2 depth camera source.
    Uses libfreenect if installed, or falls back to standard V4L2 depth stream.
    """
    def __init__(self):
        self.has_freenect = False
        self.freenect = None
        try:
            import freenect
            self.freenect = freenect
            self.has_freenect = True
        except ImportError:
            pass
        self.rgb_cap = None

    def start(self):
        if self.has_freenect:
            print("[kinect] Initialized Xbox Kinect via native libfreenect driver.")
        else:
            print("[kinect] libfreenect not detected. Attempting V4L2 UVC capture for Kinect...")
            self.rgb_cap = SingleCameraSource(device_index=0)
            self.rgb_cap.start()

    def read_depth_and_rgb(self):
        if self.has_freenect:
            # freenect.sync_get_depth returns 11-bit depth in mm
            depth, _ = self.freenect.sync_get_depth()
            rgb, _ = self.freenect.sync_get_video()
            # Convert RGB to BGR for OpenCV
            rgb_bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
            return True, depth, rgb_bgr
        elif self.rgb_cap:
            ret, frame = self.rgb_cap.read()
            return ret, None, frame
        return False, None, None

    def release(self):
        if self.rgb_cap:
            self.rgb_cap.release()
