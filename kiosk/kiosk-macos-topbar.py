#!/usr/bin/env python3
"""
kiosk-macos-topbar.py - Authentic macOS-Style Top Menu Bar for KioskOS Admin Desktop
Native GTK3 hardware-accelerated top panel on Wayland.
Features:
  -  / KioskOS System Menu
  - Standard App Menus: KioskOS, Display, Touch, Kinect, Window, Help
  - Status Tray: Kinect state, Camera, Temp, RAM %, IP Address, Clock
  - Quick-Lock Action button (Instant return to single locked kiosk)
"""

import sys
import os
import time
import subprocess
import json
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib

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

class MacOSTopBar(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("kiosk-macos-topbar")
        self.set_role("panel")
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_resizable(False)

        # Screen dimensions
        screen = Gdk.Screen.get_default()
        width = screen.get_width() if screen else 1920
        self.set_size_request(width, 32)
        self.set_default_size(width, 32)
        self.move(0, 0)

        # macOS Translucent Glass Styling
        css_provider = Gtk.CssProvider()
        css = b"""
        window {
            background-color: rgba(15, 23, 42, 0.92);
            border-bottom: 1px solid rgba(255, 255, 255, 0.12);
            color: #f1f5f9;
            font-family: -apple-system, BlinkMacSystemFont, "Cantarell", "DejaVu Sans", sans-serif;
            font-size: 13px;
        }
        menubar {
            background-color: transparent;
            padding: 0;
            border: none;
        }
        menubar > menuitem {
            padding: 4px 10px;
            color: #e2e8f0;
            font-weight: 500;
        }
        menubar > menuitem:hover {
            background-color: rgba(255, 255, 255, 0.12);
            color: #ffffff;
            border-radius: 4px;
        }
        menuitem.apple-logo {
            font-size: 16px;
            font-weight: bold;
            padding: 2px 10px 4px 12px;
            color: #ffffff;
        }
        menuitem.app-name {
            font-weight: 700;
            color: #ffffff;
        }
        menu {
            background-color: #1e293b;
            border: 1px solid #475569;
            border-radius: 8px;
            padding: 6px;
        }
        menu menuitem {
            padding: 6px 14px;
            color: #f1f5f9;
            font-size: 13px;
            border-radius: 4px;
        }
        menu menuitem:hover {
            background-color: #2563eb;
            color: #ffffff;
        }
        .status-badge {
            background-color: rgba(255, 255, 255, 0.08);
            border-radius: 6px;
            padding: 2px 8px;
            font-size: 12px;
            font-weight: 500;
            color: #cbd5e1;
        }
        .lock-btn {
            background-color: #059669;
            color: #ffffff;
            border: none;
            border-radius: 6px;
            padding: 3px 10px;
            font-size: 12px;
            font-weight: 700;
        }
        .lock-btn:hover {
            background-color: #047857;
        }
        """
        css_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Bar container
        bar_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        bar_box.set_margin_start(6)
        bar_box.set_margin_end(12)
        bar_box.set_margin_top(2)
        bar_box.set_margin_bottom(2)
        self.add(bar_box)

        # 1. Left: Menu Bar
        menu_bar = Gtk.MenuBar()
        bar_box.pack_start(menu_bar, False, False, 0)

        #  System Menu
        apple_item = Gtk.MenuItem()
        apple_lbl = Gtk.Label(label="")
        apple_lbl.get_style_context().add_class("apple-logo")
        apple_item.add(apple_lbl)
        apple_menu = Gtk.Menu()
        apple_item.set_submenu(apple_menu)
        menu_bar.append(apple_item)

        about_item = Gtk.MenuItem(label="About KioskOS Appliance")
        about_item.connect("activate", self.on_about)
        apple_menu.append(about_item)

        apple_menu.append(Gtk.SeparatorMenuItem())

        settings_item = Gtk.MenuItem(label="KioskOS Control Center...")
        settings_item.connect("activate", self.on_open_control_center)
        apple_menu.append(settings_item)

        apple_menu.append(Gtk.SeparatorMenuItem())

        lock_item = Gtk.MenuItem(label="Lock & Return to Kiosk Mode (Cmd+L)")
        lock_item.connect("activate", self.on_lock_kiosk)
        apple_menu.append(lock_item)

        restart_item = Gtk.MenuItem(label="Restart Kiosk Display")
        restart_item.connect("activate", lambda w: subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"]))
        apple_menu.append(restart_item)

        apple_menu.append(Gtk.SeparatorMenuItem())

        reboot_item = Gtk.MenuItem(label="Restart Raspberry Pi...")
        reboot_item.connect("activate", lambda w: subprocess.run(["sudo", "systemctl", "reboot"]))
        apple_menu.append(reboot_item)

        # App Name Menu: KioskOS
        app_item = Gtk.MenuItem(label="KioskOS")
        app_item.get_style_context().add_class("app-name")
        app_menu = Gtk.Menu()
        app_item.set_submenu(app_menu)
        menu_bar.append(app_item)

        launch_browser_item = Gtk.MenuItem(label="Open Web Browser")
        launch_browser_item.connect("activate", self.on_launch_browser)
        app_menu.append(launch_browser_item)

        launch_term_item = Gtk.MenuItem(label="Open Terminal")
        launch_term_item.connect("activate", lambda w: subprocess.Popen(["foot"] if os.path.exists("/usr/bin/foot") else ["x-terminal-emulator"]))
        app_menu.append(launch_term_item)

        # Display Menu
        disp_item = Gtk.MenuItem(label="Display")
        disp_menu = Gtk.Menu()
        disp_item.set_submenu(disp_menu)
        menu_bar.append(disp_item)

        pwr_on = Gtk.MenuItem(label="Screen Power ON")
        pwr_on.connect("activate", lambda w: subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "on"]))
        disp_menu.append(pwr_on)

        pwr_off = Gtk.MenuItem(label="Screen Power OFF (Standby)")
        pwr_off.connect("activate", lambda w: subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "off"]))
        disp_menu.append(pwr_off)

        disp_menu.append(Gtk.SeparatorMenuItem())

        b100 = Gtk.MenuItem(label="Brightness: 100%")
        b100.connect("activate", lambda w: subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "brightness", "100"]))
        disp_menu.append(b100)

        b50 = Gtk.MenuItem(label="Brightness: 50%")
        b50.connect("activate", lambda w: subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "brightness", "50"]))
        disp_menu.append(b50)

        # Touch Menu
        touch_item = Gtk.MenuItem(label="Touch")
        touch_menu = Gtk.Menu()
        touch_item.set_submenu(touch_menu)
        menu_bar.append(touch_item)

        calib_item = Gtk.MenuItem(label="🎯 Calibrate Screen Markers")
        calib_item.connect("activate", lambda w: subprocess.Popen(["python3", "/opt/kiosk/camera-touch/touch_calibration.py"]))
        touch_menu.append(calib_item)

        test_item = Gtk.MenuItem(label="📹 Live Camera Diagnostic Test")
        test_item.connect("activate", lambda w: subprocess.Popen(["python3", "/opt/kiosk/camera-touch/touch_test.py"]))
        touch_menu.append(test_item)

        # Kinect Menu
        kinect_item = Gtk.MenuItem(label="Kinect")
        kinect_menu = Gtk.Menu()
        kinect_item.set_submenu(kinect_menu)
        menu_bar.append(kinect_item)

        k_level = Gtk.MenuItem(label="📐 Level Kinect Motor (0° Center)")
        k_level.connect("activate", lambda w: subprocess.run(["python3", "/opt/kiosk/camera-touch/kinect_controller.py", "tilt", "0"]))
        kinect_menu.append(k_level)

        k_up = Gtk.MenuItem(label="🔼 Tilt Up (+15°)")
        k_up.connect("activate", lambda w: subprocess.run(["python3", "/opt/kiosk/camera-touch/kinect_controller.py", "tilt", "15"]))
        kinect_menu.append(k_up)

        k_down = Gtk.MenuItem(label="🔽 Tilt Down (-15°)")
        k_down.connect("activate", lambda w: subprocess.run(["python3", "/opt/kiosk/camera-touch/kinect_controller.py", "tilt", "-15"]))
        kinect_menu.append(k_down)

        kinect_menu.append(Gtk.SeparatorMenuItem())

        k_led_off = Gtk.MenuItem(label="💡 Turn Kinect LED OFF")
        k_led_off.connect("activate", lambda w: subprocess.run(["python3", "/opt/kiosk/camera-touch/kinect_controller.py", "off"]))
        kinect_menu.append(k_led_off)

        k_led_on = Gtk.MenuItem(label="🟢 Turn Kinect LED Green")
        k_led_on.connect("activate", lambda w: subprocess.run(["python3", "/opt/kiosk/camera-touch/kinect_controller.py", "green"]))
        kinect_menu.append(k_led_on)

        # 2. Right: System Status Tray & Clock
        tray_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        bar_box.pack_end(tray_box, False, False, 0)

        # Quick Return to Kiosk Button
        lock_btn = Gtk.Button(label="🔒 Lock Kiosk")
        lock_btn.get_style_context().add_class("lock-btn")
        lock_btn.connect("clicked", lambda w: self.on_lock_kiosk())
        tray_box.pack_end(lock_btn, False, False, 0)

        # Clock
        self.clock_lbl = Gtk.Label()
        self.clock_lbl.get_style_context().add_class("status-badge")
        tray_box.pack_end(self.clock_lbl, False, False, 0)

        # IP Address
        self.ip_lbl = Gtk.Label(label="IP: ...")
        self.ip_lbl.get_style_context().add_class("status-badge")
        tray_box.pack_end(self.ip_lbl, False, False, 0)

        # Temperature
        self.temp_lbl = Gtk.Label(label="🌡️ ...")
        self.temp_lbl.get_style_context().add_class("status-badge")
        tray_box.pack_end(self.temp_lbl, False, False, 0)

        # Kinect Indicator
        self.kinect_lbl = Gtk.Label(label="🎮 Kinect")
        self.kinect_lbl.get_style_context().add_class("status-badge")
        tray_box.pack_end(self.kinect_lbl, False, False, 0)

        # Periodic telemetry & clock update
        GLib.timeout_add(1000, self.update_status)
        self.update_status()

    def update_status(self):
        # Clock: e.g. "Sat Oct 24  6:18 PM"
        now_str = time.strftime("%a %b %d  %-I:%M %p")
        self.clock_lbl.set_text(now_str)

        # IP
        try:
            res = subprocess.run(["hostname", "-I"], capture_output=True, text=True)
            ips = res.stdout.strip().split()
            ip_str = ips[0] if ips else "127.0.0.1"
            self.ip_lbl.set_text(f"📶 {ip_str}")
        except Exception:
            pass

        # Temp
        if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
            try:
                temp_c = round(float(open("/sys/class/thermal/thermal_zone0/temp").read().strip()) / 1000.0, 1)
                self.temp_lbl.set_text(f"🌡️ {temp_c}°C")
            except Exception:
                pass

        # Kinect check
        try:
            lsusb = subprocess.run(["lsusb"], capture_output=True, text=True).stdout
            if "Xbox NUI" in lsusb:
                self.kinect_lbl.set_text("🎮 Kinect Connected")
            else:
                self.kinect_lbl.set_text("🎮 Kinect Disconnected")
        except Exception:
            pass

        return True

    def on_about(self, widget):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text="KioskOS Appliance Edition"
        )
        dialog.format_secondary_text(
            "Version 2.0 (Appliance)\n"
            "Hardware-accelerated Linux Kiosk Environment\n"
            "Wayland Compositor + Optical Multi-Touch Digitizer\n"
            "© 2026 KioskOS Project"
        )
        dialog.run()
        dialog.destroy()

    def on_open_control_center(self, widget):
        if os.path.exists("/opt/kiosk/kiosk-native-admin.py"):
            subprocess.Popen(["python3", "/opt/kiosk/kiosk-native-admin.py"])

    def on_launch_browser(self, widget):
        subprocess.Popen([
            "/usr/bin/chromium",
            "--ozone-platform=wayland",
            "--user-data-dir=/tmp/chromium-kiosk-browser",
            "chrome://newtab"
        ])

    def on_lock_kiosk(self, widget=None):
        self.destroy()
        if os.path.exists("/opt/kiosk/lock-kiosk.sh"):
            subprocess.Popen(["/bin/bash", "/opt/kiosk/lock-kiosk.sh"])
        Gtk.main_quit()

def main():
    app = MacOSTopBar()
    app.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
