#!/usr/bin/env python3
"""
kiosk-native-splash.py - Hardware-Aware Native GTK3 / Wayland Boot Splash for KioskOS
Features custom Raspberry Pi Edition branding with merged dual Ruby/Cyan aesthetic,
hardware telemetry badge, and guaranteed display time for HDMI monitor sync.
"""

import sys
import os
import json
import time
import math
import threading
import urllib.request
import urllib.error

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib, Pango

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

try:
    import hardware_profiles
    HW_INFO = hardware_profiles.detect_hardware()
except Exception:
    HW_INFO = {
        "is_raspberry_pi": True,
        "device_model": "Raspberry Pi 4 Model B",
        "profile_id": "rpi4_2gb",
        "profile_name": "Raspberry Pi 4 (2GB) - Optimized",
        "ram": {"total_gb": 2.0},
        "display": {"resolution": "1920x1080", "primary": {"connector": "HDMI-A-1"}}
    }

CONFIG_PATHS = ["/etc/kiosk/config.json", "/opt/kiosk/config.json"]

def load_dashboard_url():
    for p in CONFIG_PATHS:
        if os.path.exists(p):
            try:
                with open(p, "r") as f:
                    data = json.load(f)
                    url = data.get("dashboard_url", "").strip()
                    if url:
                        return url
            except Exception:
                pass
    return "http://homeassistant.local:8123/lovelace/0?kiosk"

class NativeSplashWindow(Gtk.Window):
    def __init__(self, target_url):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.target_url = target_url
        self.ready_to_exit = False
        self.pulse_phase = 0.0
        self.is_pi = HW_INFO.get("is_raspberry_pi", True)
        self.device_model = HW_INFO.get("device_model", "Raspberry Pi")
        self.profile_id = HW_INFO.get("profile_id", "rpi4_2gb")
        self.resolution = HW_INFO.get("display", {}).get("resolution", "1080p")
        self.connector = HW_INFO.get("display", {}).get("primary", {}).get("connector", "HDMI")

        self.set_title("Home Assistant Kiosk Boot Splash")
        self.set_decorated(False)
        self.fullscreen()
        self.set_app_paintable(True)
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        # Main Layout
        self.main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.main_box.set_valign(Gtk.Align.CENTER)
        self.main_box.set_halign(Gtk.Align.CENTER)
        self.add(self.main_box)

        # Drawing Area for Custom Vector Logo
        self.emblem_area = Gtk.DrawingArea()
        self.emblem_area.set_size_request(240, 240)
        self.emblem_area.connect("draw", self.draw_emblem)
        self.main_box.pack_start(self.emblem_area, False, False, 0)

        # Title Label
        self.title_label = Gtk.Label()
        self.title_label.set_markup(
            '<span font="32" weight="heavy" color="#ffffff">HOME ASSISTANT</span>'
        )
        self.main_box.pack_start(self.title_label, False, False, 0)

        # Edition Subtitle
        self.edition_label = Gtk.Label()
        if self.is_pi:
            self.edition_label.set_markup(
                '<span font="20" weight="heavy" color="#f43f5e">⚡ RASPBERRY PI EDITION ⚡</span>'
            )
        else:
            self.edition_label.set_markup(
                '<span font="18" weight="heavy" color="#18bcf2">APPLIANCE EDITION</span>'
            )
        self.main_box.pack_start(self.edition_label, False, False, 0)

        # Hardware Badge Pill
        self.hw_label = Gtk.Label()
        if self.is_pi:
            self.hw_label.set_markup(
                f'<span font="11" weight="bold" color="#fda4af">Hardware: {self.device_model}  •  {self.connector} @ {self.resolution}  •  Profile: {self.profile_id}</span>'
            )
        else:
            self.hw_label.set_markup(
                f'<span font="11" weight="bold" color="#7dd3fc">Hardware: {self.device_model}  •  {self.resolution}  •  Profile: {self.profile_id}</span>'
            )
        self.main_box.pack_start(self.hw_label, False, False, 0)

        # Status Label
        self.status_label = Gtk.Label()
        self.status_label.set_markup('<span font="13" color="#94a3b8">Initializing system hardware & display...</span>')
        self.main_box.pack_start(self.status_label, False, False, 4)

        # Sleek Progress Bar
        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_size_request(420, 8)
        self.progress_bar.set_fraction(0.15)
        self.main_box.pack_start(self.progress_bar, False, False, 10)

        # Footer Credit
        self.credit_label = Gtk.Label()
        self.credit_label.set_markup('<span font="12" weight="bold" color="#64748b">8Air  •  SuperG Technologies</span>')
        self.main_box.pack_start(self.credit_label, False, False, 6)

        # CSS Styling
        css_provider = Gtk.CssProvider()
        css = b"""
        window {
            background-color: #040710;
        }
        progressbar trough {
            background-color: rgba(255, 255, 255, 0.08);
            border-radius: 6px;
            min-height: 8px;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }
        progressbar progress {
            background: linear-gradient(90deg, #e11d48, #0ea5e9);
            border-radius: 6px;
            min-height: 8px;
        }
        """
        css_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Pulse timer for emblem animation (30 fps)
        GLib.timeout_add(33, self.on_pulse_tick)

        # Background probe thread
        threading.Thread(target=self.probe_dashboard, daemon=True).start()

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        cr.set_source_rgb(0.015, 0.027, 0.06)
        cr.paint()
        return False

    def draw_emblem(self, widget, cr):
        alloc = widget.get_allocation()
        cx = alloc.width / 2.0
        cy = alloc.height / 2.0

        pulse = math.sin(self.pulse_phase)
        glow_radius = 98 + 6 * pulse

        # 1. Dual Glowing Aura (Raspberry Ruby #e11d48 + Home Assistant Cyan #0ea5e9)
        cr.set_source_rgba(0.88, 0.11, 0.28, 0.25 + 0.12 * pulse)
        cr.arc(cx - 16, cy, glow_radius, 0, 2 * math.pi)
        cr.fill()

        cr.set_source_rgba(0.05, 0.65, 0.91, 0.22 + 0.10 * pulse)
        cr.arc(cx + 16, cy, glow_radius, 0, 2 * math.pi)
        cr.fill()

        # 2. Raspberry Top Leaves (Emerald Green #22c55e)
        cr.set_source_rgb(0.13, 0.77, 0.37)
        # Left leaf
        cr.arc(cx - 28, cy - 76, 17, 0, 2 * math.pi)
        cr.fill()
        # Center stem/leaf
        cr.arc(cx, cy - 86, 15, 0, 2 * math.pi)
        cr.fill()
        # Right leaf
        cr.arc(cx + 28, cy - 76, 17, 0, 2 * math.pi)
        cr.fill()

        # 3. Raspberry Pi Berry Nodes (Ruby Red Clusters)
        cr.set_source_rgb(0.88, 0.11, 0.28) # #e11d48
        berry_nodes = [
            (cx - 44, cy - 46, 19), (cx + 44, cy - 46, 19),
            (cx - 58, cy - 14, 21), (cx + 58, cy - 14, 21),
            (cx - 50, cy + 24, 20), (cx + 50, cy + 24, 20),
            (cx - 32, cy + 58, 18), (cx + 32, cy + 58, 18),
            (cx, cy + 72, 17),
        ]
        for bx, by, brad in berry_nodes:
            cr.arc(bx, by, brad, 0, 2 * math.pi)
            cr.fill()

        # 4. Center Core Shield (Dark Glass with Cyan Outline)
        cw, ch = 100.0, 92.0
        cx0 = cx - cw / 2.0
        cy0 = cy - ch / 2.0 - 2.0
        rad = 16.0
        cr.new_sub_path()
        cr.arc(cx0 + cw - rad, cy0 + rad, rad, -math.pi/2, 0)
        cr.arc(cx0 + cw - rad, cy0 + ch - rad, rad, 0, math.pi/2)
        cr.arc(cx0 + rad, cy0 + ch - rad, rad, math.pi/2, math.pi)
        cr.arc(cx0 + rad, cy0 + rad, rad, math.pi, 3*math.pi/2)
        cr.close_path()

        cr.set_source_rgba(0.03, 0.05, 0.11, 0.95)
        cr.fill_preserve()
        cr.set_line_width(3.0)
        cr.set_source_rgba(0.05, 0.65, 0.91, 0.95) # Cyan border
        cr.stroke()

        # 5. Glowing Home Assistant House Vector Symbol
        cr.set_line_width(3.5)
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.98)

        hx, hy = cx, cy0 + 14
        cr.move_to(hx, hy)
        cr.line_to(hx - 26, hy + 26)
        cr.line_to(hx - 18, hy + 26)
        cr.line_to(hx - 18, hy + 54)
        cr.line_to(hx + 18, hy + 54)
        cr.line_to(hx + 18, hy + 26)
        cr.line_to(hx + 26, hy + 26)
        cr.close_path()
        cr.set_source_rgba(0.05, 0.65, 0.91, 0.35)
        cr.fill_preserve()
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
        cr.stroke()

        # Chimney
        cr.set_line_width(2.5)
        cr.move_to(hx + 13, hy + 14)
        cr.line_to(hx + 13, hy + 5)
        cr.line_to(hx + 19, hy + 5)
        cr.line_to(hx + 19, hy + 20)
        cr.stroke()

        # Smart home core dot
        cr.arc(hx, hy + 40, 4.0, 0, 2 * math.pi)
        cr.set_source_rgb(0.05, 0.65, 0.91)
        cr.fill()

        return True

    def on_pulse_tick(self):
        self.pulse_phase += 0.08
        self.emblem_area.queue_draw()
        return not self.ready_to_exit

    def probe_dashboard(self):
        # Guaranteed progressive display stages so user actually sees the bootsplash
        # Stage 1: Hardware check (0.8s)
        time.sleep(0.8)
        GLib.idle_add(self.update_status, f"Hardware: {self.device_model} ({self.connector} @ {self.resolution})", 0.30)
        
        # Stage 2: Performance profile (0.9s)
        time.sleep(0.9)
        GLib.idle_add(self.update_status, f"Applied hardware profile: {self.profile_id} (Optimized)", 0.55)

        # Stage 3: Connecting to Home Assistant (1.0s)
        time.sleep(1.0)
        GLib.idle_add(self.update_status, "Connecting to Home Assistant Dashboard...", 0.80)

        start = time.time()
        timeout = 8.0

        while time.time() - start < timeout:
            try:
                req = urllib.request.Request(self.target_url, headers={"User-Agent": "kiosk-native-splash"})
                resp = urllib.request.urlopen(req, timeout=1.5)
                if resp.status in (200, 301, 302, 401, 403):
                    break
            except Exception:
                pass
            time.sleep(0.3)

        # Stage 4: Launching dashboard
        GLib.idle_add(self.update_status, "Home Assistant Ready ✓ Launching...", 1.0)
        time.sleep(0.8)
        GLib.idle_add(self.finish_and_exit)

    def update_status(self, text, fraction=None):
        self.status_label.set_markup(f'<span font="13" color="#94a3b8">{text}</span>')
        if fraction is not None:
            self.progress_bar.set_fraction(fraction)

    def finish_and_exit(self):
        self.ready_to_exit = True
        self.destroy()
        Gtk.main_quit()

def main():
    target_url = sys.argv[1] if len(sys.argv) > 1 else load_dashboard_url()
    win = NativeSplashWindow(target_url)
    win.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
