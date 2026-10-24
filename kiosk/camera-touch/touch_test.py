#!/usr/bin/env python3
"""
touch_test.py - Immediate Live Diagnostic & Camera Touch Testing Tool
Tests single camera tracking, homography mapping, and virtual touchscreen injection.
"""

import sys
import os
import time

try:
    import cv2
    import numpy as np
except ImportError:
    cv2 = None
    np = None

from camera_sources import SingleCameraSource
from touch_detector import TouchDetector
from homography import HomographyTransformer
from uinput_touch import VirtualTouchScreen

def main():
    camera_id = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    print("=" * 65)
    print(f"  KIOSKOS CAMERA TOUCHSCREEN LIVE DIAGNOSTIC (Camera {camera_id})")
    print("=" * 65)

    if cv2 is None:
        print("[error] OpenCV (python3-opencv) is required to run camera testing.")
        sys.exit(1)

    # Release any background service holding the video device
    import subprocess
    was_running = subprocess.run(["systemctl", "is-active", "kiosk-camera-touch.service"], capture_output=True, text=True).stdout.strip() == "active"
    if was_running:
        print("• Pausing background touch daemon to access camera stream...")
        subprocess.run(["sudo", "systemctl", "stop", "kiosk-camera-touch.service"], capture_output=True)

    print(f"• Opening camera device {camera_id}...")
    try:
        source = SingleCameraSource(device_index=camera_id, width=640, height=480, fps=30)
        source.start()
    except Exception as e:
        print(f"[error] Failed to open camera {camera_id}: {e}")
        print("Tip: Check if camera is connected via 'ls -la /dev/video*'")
        sys.exit(1)

    detector = TouchDetector(mode="single")
    transformer = HomographyTransformer()
    touchscreen = VirtualTouchScreen()

    is_gui = bool(os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY"))
    window_name = "KioskOS Camera Touch Tracker"
    if is_gui:
        cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(window_name, 640, 480)

    print("• Tracking loop started. Press [q] or [Ctrl+C] to stop.")
    print("-" * 65)

    fps_count = 0
    start_time = time.time()
    last_touch_state = False

    try:
        while True:
            ret, frame = source.read()
            if not ret or frame is None:
                time.sleep(0.03)
                continue

            fps_count += 1
            elapsed = time.time() - start_time
            fps = fps_count / elapsed if elapsed > 0 else 30.0

            found, (u, v), is_touch, annotated = detector.process_single_frame(frame)

            if found:
                # Map to screen coordinates
                screen_x, screen_y, within = transformer.transform(u, v)

                status_str = "TOUCH DOWN" if is_touch else "HOVER"
                sys.stdout.write(f"\r[FPS: {fps:4.1f}] Cam: ({int(u):3d}, {int(v):3d}) -> Screen: ({screen_x:4d}, {screen_y:4d}) | State: {status_str:<10}")
                sys.stdout.flush()

                # Emit to virtual touchscreen digitizer
                if is_touch:
                    if not last_touch_state:
                        touchscreen.touch_down(screen_x, screen_y)
                    else:
                        touchscreen.touch_move(screen_x, screen_y)
                    last_touch_state = True
                else:
                    if last_touch_state:
                        touchscreen.touch_up()
                    last_touch_state = False
            else:
                if last_touch_state:
                    touchscreen.touch_up()
                    last_touch_state = False
                sys.stdout.write(f"\r[FPS: {fps:4.1f}] Searching for hand / fingertip...{' ' * 30}")
                sys.stdout.flush()

            if is_gui:
                cv2.putText(annotated, f"FPS: {fps:.1f}", (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
                cv2.imshow(window_name, annotated)
                if cv2.waitKey(1) & 0xFF == ord('q'):
                    break

    except KeyboardInterrupt:
        print("\n[test] Test stopped by user.")
    finally:
        print("\n• Cleaning up resources...")
        touchscreen.close()
        source.release()
        if is_gui:
            cv2.destroyAllWindows()
        print("✓ Done.")

if __name__ == "__main__":
    main()
