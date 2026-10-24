#!/usr/bin/env python3
"""
kiosk-native-admin.py - Native GTK3 Control Center Application for KioskOS
Real native Linux desktop application running alongside Chrome in Admin Mode.
"""

import sys
import os
import json
import subprocess
import threading
import time

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

def save_config(cfg):
    for p in CONFIG_PATHS:
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                json.dump(cfg, f, indent=2)
        except Exception:
            pass

class NativeAdminWindow(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.config = load_config()

        self.set_title("KioskOS Control Center")
        self.set_default_size(780, 560)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", Gtk.main_quit)

        # Apply dark theme styling
        css_provider = Gtk.CssProvider()
        css = b"""
        window {
            background-color: #0f172a;
            color: #f8fafc;
        }
        .header-box {
            background-color: #1e293b;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            padding: 16px 24px;
        }
        .section-card {
            background-color: #1e293b;
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.08);
            padding: 18px;
            margin-bottom: 16px;
        }
        .section-title {
            font-size: 15px;
            font-weight: bold;
            color: #38bdf8;
            margin-bottom: 8px;
        }
        entry {
            background-color: #0f172a;
            color: #ffffff;
            border: 1px solid #334155;
            border-radius: 8px;
            padding: 8px 12px;
        }
        entry:focus {
            border-color: #38bdf8;
        }
        button {
            background-color: #334155;
            color: #ffffff;
            border: none;
            border-radius: 8px;
            padding: 8px 16px;
            font-weight: 600;
        }
        button:hover {
            background-color: #475569;
        }
        button.primary-btn {
            background-color: #0284c7;
        }
        button.primary-btn:hover {
            background-color: #0369a1;
        }
        button.success-btn {
            background-color: #059669;
        }
        button.success-btn:hover {
            background-color: #047857;
        }
        button.danger-btn {
            background-color: #dc2626;
        }
        button.danger-btn:hover {
            background-color: #b91c1c;
        }
        .telemetry-bar {
            background-color: #020617;
            border-top: 1px solid rgba(255, 255, 255, 0.08);
            padding: 10px 24px;
            font-size: 12px;
            color: #94a3b8;
        }
        """
        css_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(main_box)

        # Header
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        header.get_style_context().add_class("header-box")

        title_lbl = Gtk.Label()
        title_lbl.set_markup(
            '<span font="18" weight="bold" color="#ffffff">⚡ KioskOS</span> '
            '<span font="13" color="#38bdf8" weight="bold">Admin Control Center</span>'
        )
        title_lbl.set_halign(Gtk.Align.START)
        header.pack_start(title_lbl, True, True, 0)

        # Return to Kiosk Mode Button in Header
        lock_btn = Gtk.Button(label="🔒 Return to Kiosk Mode")
        lock_btn.get_style_context().add_class("success-btn")
        lock_btn.connect("clicked", self.on_return_to_kiosk)
        header.pack_end(lock_btn, False, False, 0)

        main_box.pack_start(header, False, False, 0)

        # Scrollable Content Area
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        content_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content_box.set_margin_start(24)
        content_box.set_margin_end(24)
        content_box.set_margin_top(20)
        content_box.set_margin_bottom(20)
        scroller.add(content_box)
        main_box.pack_start(scroller, True, True, 0)

        # CARD 1: Dashboard Configuration
        card1 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        card1.get_style_context().add_class("section-card")

        c1_title = Gtk.Label()
        c1_title.set_markup('<span font="13" weight="bold" color="#e2e8f0">Home Assistant / Kiosk Dashboard URL</span>')
        c1_title.set_halign(Gtk.Align.START)
        card1.pack_start(c1_title, False, False, 0)

        url_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.url_entry = Gtk.Entry()
        self.url_entry.set_text(self.config.get("dashboard_url", "http://homeassistant.local:8123/lovelace/0?kiosk"))
        self.url_entry.set_hexpand(True)
        url_box.pack_start(self.url_entry, True, True, 0)

        save_url_btn = Gtk.Button(label="Save & Reload")
        save_url_btn.get_style_context().add_class("primary-btn")
        save_url_btn.connect("clicked", self.on_save_url)
        url_box.pack_start(save_url_btn, False, False, 0)
        card1.pack_start(url_box, False, False, 0)

        content_box.pack_start(card1, False, False, 0)

        # CARD 2: Display & Hardware Controls
        card2 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card2.get_style_context().add_class("section-card")

        c2_title = Gtk.Label()
        c2_title.set_markup('<span font="13" weight="bold" color="#e2e8f0">Display &amp; Hardware Control</span>')
        c2_title.set_halign(Gtk.Align.START)
        card2.pack_start(c2_title, False, False, 0)

        # Brightness Slider
        bright_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        b_lbl = Gtk.Label(label="Brightness:")
        b_lbl.set_size_request(90, -1)
        b_lbl.set_halign(Gtk.Align.START)
        bright_box.pack_start(b_lbl, False, False, 0)

        self.bright_scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 10, 100, 5)
        self.bright_scale.set_value(float(self.config.get("screen_brightness", 100)))
        self.bright_scale.set_hexpand(True)
        self.bright_scale.connect("value-changed", self.on_brightness_change)
        bright_box.pack_start(self.bright_scale, True, True, 0)
        card2.pack_start(bright_box, False, False, 0)

        # Screen Power & Rotation Row
        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)

        pwr_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        pwr_lbl = Gtk.Label(label="Screen Power:")
        self.pwr_switch = Gtk.Switch()
        self.pwr_switch.set_active(self.config.get("screen_on", True))
        self.pwr_switch.connect("state-set", self.on_power_toggle)
        pwr_box.pack_start(pwr_lbl, False, False, 0)
        pwr_box.pack_start(self.pwr_switch, False, False, 0)
        row2.pack_start(pwr_box, False, False, 0)

        rot_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        rot_lbl = Gtk.Label(label="Rotation:")
        self.rot_combo = Gtk.ComboBoxText()
        for rot in ["normal", "90", "180", "270"]:
            self.rot_combo.append_text(rot)
        self.rot_combo.set_active(["normal", "90", "180", "270"].index(self.config.get("display_rotation", "normal")))
        self.rot_combo.connect("changed", self.on_rotation_change)
        rot_box.pack_start(rot_lbl, False, False, 0)
        rot_box.pack_start(self.rot_combo, False, False, 0)
        row2.pack_start(rot_box, False, False, 0)

        chime_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        chime_lbl = Gtk.Label(label="Startup Chime:")
        self.chime_switch = Gtk.Switch()
        self.chime_switch.set_active(self.config.get("startup_chime", True))
        self.chime_switch.connect("state-set", self.on_chime_toggle)
        chime_box.pack_start(chime_lbl, False, False, 0)
        chime_box.pack_start(self.chime_switch, False, False, 0)
        row2.pack_start(chime_box, False, False, 0)

        card2.pack_start(row2, False, False, 0)
        content_box.pack_start(card2, False, False, 0)

        # CARD 3: Optical Camera Touchscreen Engine
        card_touch = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card_touch.get_style_context().add_class("section-card")

        ct_title = Gtk.Label()
        ct_title.set_markup('<span font="13" weight="bold" color="#e2e8f0">Optical Camera Touchscreen</span>')
        ct_title.set_halign(Gtk.Align.START)
        card_touch.pack_start(ct_title, False, False, 0)

        t_row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)

        t_switch_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        t_switch_lbl = Gtk.Label(label="Camera Touchscreen:")
        self.touch_switch = Gtk.Switch()
        touch_cfg = self.config.get("camera_touch", {})
        self.touch_switch.set_active(touch_cfg.get("enabled", False))
        self.touch_switch.connect("state-set", self.on_touch_toggle)
        t_switch_box.pack_start(t_switch_lbl, False, False, 0)
        t_switch_box.pack_start(self.touch_switch, False, False, 0)
        t_row1.pack_start(t_switch_box, False, False, 0)

        t_mode_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        t_mode_lbl = Gtk.Label(label="Tracking Mode:")
        self.touch_mode_combo = Gtk.ComboBoxText()
        self.touch_mode_combo.append("single", "1 Camera (Single)")
        self.touch_mode_combo.append("dual", "2 Cameras (Stereo Depth)")
        self.touch_mode_combo.append("kinect", "Xbox Kinect (Infrared Depth)")
        self.touch_mode_combo.set_active_id(touch_cfg.get("mode", "single"))
        self.touch_mode_combo.connect("changed", self.on_touch_mode_change)
        t_mode_box.pack_start(t_mode_lbl, False, False, 0)
        t_mode_box.pack_start(self.touch_mode_combo, False, False, 0)
        row1_dyn = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        dyn_lbl = Gtk.Label(label="Dynamic Camera (Mini-Markers):")
        self.touch_dyn_switch = Gtk.Switch()
        self.touch_dyn_switch.set_active(touch_cfg.get("dynamic_tracking", False))
        self.touch_dyn_switch.connect("state-set", self.on_touch_dyn_toggle)
        row1_dyn.pack_start(dyn_lbl, False, False, 0)
        row1_dyn.pack_start(self.touch_dyn_switch, False, False, 0)

        t_row1.pack_start(t_mode_box, False, False, 0)
        t_row1.pack_start(row1_dyn, False, False, 0)

        card_touch.pack_start(t_row1, False, False, 0)

        # Action buttons
        t_btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        calib_btn = Gtk.Button(label="🎯 Calibrate Markers & Align Screen")
        calib_btn.connect("clicked", self.on_calibrate_touch)
        t_btn_box.pack_start(calib_btn, True, True, 0)

        test_btn = Gtk.Button(label="📹 Live Test Camera Tracking")
        test_btn.connect("clicked", self.on_test_camera)
        t_btn_box.pack_start(test_btn, True, True, 0)

        card_touch.pack_start(t_btn_box, False, False, 0)
        content_box.pack_start(card_touch, False, False, 0)

        # CARD 4: Maintenance & System Actions
        card3 = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card3.get_style_context().add_class("section-card")

        c3_title = Gtk.Label()
        c3_title.set_markup('<span font="13" weight="bold" color="#e2e8f0">System Actions &amp; Maintenance</span>')
        c3_title.set_halign(Gtk.Align.START)
        card3.pack_start(c3_title, False, False, 0)

        actions_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        update_btn = Gtk.Button(label="🚀 Install System Update")
        update_btn.connect("clicked", self.on_run_update)
        actions_box.pack_start(update_btn, True, True, 0)

        restart_disp_btn = Gtk.Button(label="🔄 Restart Kiosk Display")
        restart_disp_btn.connect("clicked", self.on_restart_display)
        actions_box.pack_start(restart_disp_btn, True, True, 0)

        reboot_btn = Gtk.Button(label="⏻ Reboot Raspberry Pi")
        reboot_btn.get_style_context().add_class("danger-btn")
        reboot_btn.connect("clicked", self.on_reboot)
        actions_box.pack_start(reboot_btn, True, True, 0)

        card3.pack_start(actions_box, False, False, 0)
        content_box.pack_start(card3, False, False, 0)

        # Telemetry Footer
        self.telemetry_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=20)
        self.telemetry_box.get_style_context().add_class("telemetry-bar")

        self.telem_ip = Gtk.Label(label="IP: Checking...")
        self.telem_temp = Gtk.Label(label="Temp: Checking...")
        self.telem_mem = Gtk.Label(label="Mem: Checking...")

        self.telemetry_box.pack_start(self.telem_ip, False, False, 0)
        self.telemetry_box.pack_start(self.telem_temp, False, False, 0)
        self.telemetry_box.pack_start(self.telem_mem, False, False, 0)
        main_box.pack_end(self.telemetry_box, False, False, 0)

        # Telemetry refresh timer
        GLib.timeout_add(3000, self.refresh_telemetry)
        self.refresh_telemetry()

    def on_return_to_kiosk(self, widget):
        self.destroy()
        if os.path.exists("/opt/kiosk/lock-kiosk.sh"):
            subprocess.Popen(["/bin/bash", "/opt/kiosk/lock-kiosk.sh"])
        else:
            subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"])
        Gtk.main_quit()

    def on_save_url(self, widget):
        new_url = self.url_entry.get_text().strip()
        if new_url:
            self.config["dashboard_url"] = new_url
            save_config(self.config)
            dialog = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.INFO,
                buttons=Gtk.ButtonsType.OK,
                text="Dashboard URL Saved"
            )
            dialog.format_secondary_text(f"URL updated to:\n{new_url}\nWill apply upon next kiosk reload.")
            dialog.run()
            dialog.destroy()

    def on_brightness_change(self, scale):
        val = int(scale.get_value())
        self.config["screen_brightness"] = val
        save_config(self.config)
        subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "brightness", str(val)], capture_output=True)

    def on_power_toggle(self, switch, state):
        self.config["screen_on"] = state
        save_config(self.config)
        subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "on" if state else "off"], capture_output=True)
        return False

    def on_rotation_change(self, combo):
        rot = combo.get_active_text()
        if rot:
            self.config["display_rotation"] = rot
            save_config(self.config)
            subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "rotate", rot], capture_output=True)

    def on_chime_toggle(self, switch, state):
        self.config["startup_chime"] = state
        save_config(self.config)
        if state:
            chime_script = "/opt/kiosk/play-chime.sh"
            if os.path.exists(chime_script):
                subprocess.Popen([chime_script])
        return False

    def on_touch_toggle(self, switch, state):
        if "camera_touch" not in self.config:
            self.config["camera_touch"] = {}
        self.config["camera_touch"]["enabled"] = state
        save_config(self.config)
        action = "start" if state else "stop"
        subprocess.run(["sudo", "systemctl", action, "kiosk-camera-touch.service"], capture_output=True)
        return False

    def on_touch_mode_change(self, combo):
        active_id = combo.get_active_id()
        if active_id:
            if "camera_touch" not in self.config:
                self.config["camera_touch"] = {}
            self.config["camera_touch"]["mode"] = active_id
            save_config(self.config)
            subprocess.run(["sudo", "systemctl", "restart", "kiosk-camera-touch.service"], capture_output=True)

    def on_touch_dyn_toggle(self, switch, state):
        if "camera_touch" not in self.config:
            self.config["camera_touch"] = {}
        self.config["camera_touch"]["dynamic_tracking"] = state
        save_config(self.config)
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-camera-touch.service"], capture_output=True)
        return False

    def on_calibrate_touch(self, widget):
        calib_script = "/opt/kiosk/camera-touch/touch_calibration.py"
        if os.path.exists(calib_script):
            subprocess.Popen(["python3", calib_script])

    def on_test_camera(self, widget):
        test_script = "/opt/kiosk/camera-touch/touch_test.py"
        if os.path.exists(test_script):
            subprocess.Popen(["python3", test_script])

    def on_run_update(self, widget):
        if os.path.exists("/opt/kiosk/kiosk-native-update.py"):
            subprocess.Popen(["python3", "/opt/kiosk/kiosk-native-update.py"])
        else:
            subprocess.Popen(["sudo", "/opt/kiosk/kiosk-config.sh", "--update"])

    def on_restart_display(self, widget):
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"])

    def on_reboot(self, widget):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Confirm System Reboot"
        )
        dialog.format_secondary_text("Are you sure you want to reboot the Raspberry Pi?")
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            subprocess.run(["sudo", "systemctl", "reboot"])

    def refresh_telemetry(self):
        try:
            # IP Address
            res = subprocess.run(["hostname", "-I"], capture_output=True, text=True)
            ips = res.stdout.strip().split()
            ip_str = ips[0] if ips else "127.0.0.1"
            self.telem_ip.set_text(f"IP: {ip_str}")

            # Temp
            if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
                with open("/sys/class/thermal/thermal_zone0/temp") as f:
                    temp_c = round(float(f.read().strip()) / 1000.0, 1)
                    self.telem_temp.set_text(f"Temp: {temp_c}°C")

            # Mem
            with open("/proc/meminfo") as f:
                lines = f.readlines()
                total = int(lines[0].split()[1])
                avail = int(lines[2].split()[1])
                pct = int(((total - avail) / total) * 100)
                self.telem_mem.set_text(f"Memory: {pct}%")
        except Exception:
            pass
        return True

def main():
    win = NativeAdminWindow()
    win.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
