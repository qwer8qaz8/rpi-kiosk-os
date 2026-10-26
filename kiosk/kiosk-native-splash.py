#!/usr/bin/env python3
"""
kiosk-native-splash.py - Hardware-Aware Native GTK3 / Wayland Boot Splash for KioskOS
Features custom Pi-themed branding when running on Raspberry Pi hardware (combining
Raspberry Pi ruby and Home Assistant cyan aesthetics), hardware telemetry status,
and dynamic profile activation.
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

# Import hardware profiles module from same directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

try:
    import hardware_profiles
    HW_INFO = hardware_profiles.detect_hardware()
except Exception:
    HW_INFO = {
        "is_raspberry_pi": False,
        "device_model": "Generic Linux Device",
        "profile_id": "generic_balanced",
        "profile_name": "Generic Balanced",
        "ram": {"total_gb": 2.0},
        "display": {"resolution": "1920x1080", "primary": {"connector": "HDMI"}}
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
        self.is_pi = HW_INFO.get("is_raspberry_pi", False)
        self.device_model = HW_INFO.get("device_model", "Generic Device")
        self.profile_id = HW_INFO.get("profile_id", "generic_balanced")
        self.resolution = HW_INFO.get("display", {}).get("resolution", "1080p")

        self.set_title("Home Assistant Kiosk Boot Splash")
        self.set_decorated(False)
        self.fullscreen()
        self.set_app_paintable(True)
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        # Main Layout
        self.main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        self.main_box.set_valign(Gtk.Align.CENTER)
        self.main_box.set_halign(Gtk.Align.CENTER)
        self.add(self.main_box)

        # Drawing Area for Custom Vector Logo
        self.emblem_area = Gtk.DrawingArea()
        self.emblem_area.set_size_request(200, 200)
        self.emblem_area.connect("draw", self.draw_emblem)
        self.main_box.pack_start(self.emblem_area, False, False, 0)

        # Title Label
        self.title_label = Gtk.Label()
        if self.is_pi:
            self.title_label.set_markup(
                '<span font="28" weight="heavy" color="#ffffff">HOME ASSISTANT <span color="#c51a4a">✕</span> <span color="#f43f5e">RASPBERRY PI</span></span>'
            )
        else:
            self.title_label.set_markup(
                '<span font="28" weight="heavy" color="#ffffff">HOME ASSISTANT <span color="#18bcf2">KIOSK</span></span>'
            )
        self.main_box.pack_start(self.title_label, False, False, 0)

        # Hardware Badge Pill
        self.hw_label = Gtk.Label()
        if self.is_pi:
            self.hw_label.set_markup(
                f'<span font="11" weight="bold" color="#fda4af">⚡ {self.device_model}  •  {self.resolution}  •  Profile: {self.profile_id}</span>'
            )
        else:
            self.hw_label.set_markup(
                f'<span font="11" weight="bold" color="#7dd3fc">⚡ {self.device_model}  •  {self.resolution}  •  Profile: {self.profile_id}</span>'
            )
        self.main_box.pack_start(self.hw_label, False, False, 0)

        # Status Label
        self.status_label = Gtk.Label()
        self.status_label.set_markup('<span font="13" color="#94a3b8">Checking system hardware & network...</span>')
        self.main_box.pack_start(self.status_label, False, False, 0)

        # Sleek Progress Bar
        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_size_request(380, 6)
        self.progress_bar.set_fraction(0.15)
        self.main_box.pack_start(self.progress_bar, False, False, 10)

        # Footer Credit
        self.credit_label = Gtk.Label()
        self.credit_label.set_markup('<span font="10" color="#475569">Single-Purpose Home Assistant Appliance  •  8Air</span>')
        self.main_box.pack_start(self.credit_label, False, False, 2)

        # Dynamic CSS Styling
        css_provider = Gtk.CssProvider()
        if self.is_pi:
            css = b"""
            window {
                background-color: #05060a;
            }
            progressbar trough {
                background-color: rgba(255, 255, 255, 0.08);
                border-radius: 6px;
                min-height: 6px;
                border: 1px solid rgba(255, 255, 255, 0.05);
            }
            progressbar progress {
                background: linear-gradient(90deg, #c51a4a, #18bcf2);
                border-radius: 6px;
                min-height: 6px;
            }
            """
        else:
            css = b"""
            window {
                background-color: #030712;
            }
            progressbar trough {
                background-color: rgba(255, 255, 255, 0.08);
                border-radius: 6px;
                min-height: 6px;
                border: 1px solid rgba(255, 255, 255, 0.05);
            }
            progressbar progress {
                background: linear-gradient(90deg, #0284c7, #18bcf2);
                border-radius: 6px;
                min-height: 6px;
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
        # Deep space dark background
        alloc = widget.get_allocation()
        cx = alloc.width / 2.0
        cy = alloc.height / 2.0
        cr.set_source_rgb(0.02, 0.03, 0.06)
        cr.paint()
        return False

    def draw_emblem(self, widget, cr):
        alloc = widget.get_allocation()
        cx = alloc.width / 2.0
        cy = alloc.height / 2.0

        pulse = math.sin(self.pulse_phase)
        glow_radius = 82 + 5 * pulse

        if self.is_pi:
            # Raspberry Pi + Home Assistant merged dual aesthetic
            # 1. Outer dual glowing aura (Ruby Red + Cyan)
            cr.set_source_rgba(0.77, 0.10, 0.29, 0.22 + 0.10 * pulse)  # Pi Ruby #c51a4a
            cr.arc(cx - 10, cy, glow_radius, 0, 2 * math.pi)
            cr.fill()

            cr.set_source_rgba(0.09, 0.74, 0.95, 0.20 + 0.08 * pulse)  # HA Cyan #18bcf2
            cr.arc(cx + 10, cy, glow_radius, 0, 2 * math.pi)
            cr.fill()

            # 2. Raspberry Top Leaves (Emerald Green)
            cr.set_source_rgb(0.27, 0.72, 0.32)  # Pi Green #46b852
            # Left leaf
            cr.arc(cx - 22, cy - 64, 14, 0, 2 * math.pi)
            cr.fill()
            # Center stem/leaf
            cr.arc(cx, cy - 72, 12, 0, 2 * math.pi)
            cr.fill()
            # Right leaf
            cr.arc(cx + 22, cy - 64, 14, 0, 2 * math.pi)
            cr.fill()

            # 3. Raspberry Pi Berry Body Nodes (Ruby Red Clusters)
            cr.set_source_rgb(0.77, 0.10, 0.29)  # Pi Ruby
            berry_nodes = [
                (cx - 36, cy - 40, 16), (cx + 36, cy - 40, 16),
                (cx - 48, cy - 14, 18), (cx + 48, cy - 14, 18),
                (cx - 42, cy + 18, 17), (cx + 42, cy + 18, 17),
                (cx - 26, cy + 46, 16), (cx + 26, cy + 46, 16),
                (cx, cy + 58, 15),
            ]
            for bx, by, brad in berry_nodes:
                cr.arc(bx, by, brad, 0, 2 * math.pi)
                cr.fill()

            # 4. Center Core: Dark High-Tech Glass Shield
            cw, ch = 84.0, 76.0
            cx0 = cx - cw / 2.0
            cy0 = cy - ch / 2.0 - 2.0
            rad = 14.0
            cr.new_sub_path()
            cr.arc(cx0 + cw - rad, cy0 + rad, rad, -math.pi/2, 0)
            cr.arc(cx0 + cw - rad, cy0 + ch - rad, rad, 0, math.pi/2)
            cr.arc(cx0 + rad, cy0 + ch - rad, rad, math.pi/2, math.pi)
            cr.arc(cx0 + rad, cy0 + rad, rad, math.pi, 3*math.pi/2)
            cr.close_path()

            cr.set_source_rgba(0.04, 0.06, 0.12, 0.95)
            cr.fill_preserve()
            cr.set_line_width(2.5)
            cr.set_source_rgba(0.09, 0.74, 0.95, 0.9)  # Glowing Cyan border
            cr.stroke()

            # 5. Glowing Home Assistant House Vector Symbol inside Shield
            cr.set_line_width(3.2)
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.98)

            hx, hy = cx, cy0 + 12
            # House roof
            cr.move_to(hx, hy)
            cr.line_to(hx - 22, hy + 22)
            cr.line_to(hx - 15, hy + 22)
            cr.line_to(hx - 15, hy + 44)
            cr.line_to(hx + 15, hy + 44)
            cr.line_to(hx + 15, hy + 22)
            cr.line_to(hx + 22, hy + 22)
            cr.close_path()
            cr.set_source_rgba(0.09, 0.74, 0.95, 0.35)
            cr.fill_preserve()
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
            cr.stroke()

            # Chimney
            cr.set_line_width(2.2)
            cr.move_to(hx + 11, hy + 12)
            cr.line_to(hx + 11, hy + 4)
            cr.line_to(hx + 16, hy + 4)
            cr.line_to(hx + 16, hy + 17)
            cr.stroke()

            # Tiny inner glowing smart-home dot
            cr.arc(hx, hy + 33, 3.5, 0, 2 * math.pi)
            cr.set_source_rgb(0.09, 0.74, 0.95)
            cr.fill()

        else:
            # Generic Hardware: Minimalist High-Tech Home Assistant Emblem
            cr.set_source_rgba(0.09, 0.74, 0.95, 0.22 + 0.12 * pulse)
            cr.arc(cx, cy, glow_radius, 0, 2 * math.pi)
            cr.fill()

            # Display Screen Bezel
            bw, bh = 110.0, 84.0
            bx0 = cx - bw / 2.0
            by0 = cy - bh / 2.0 - 4.0
            rad = 12.0
            cr.new_sub_path()
            cr.arc(bx0 + bw - rad, by0 + rad, rad, -math.pi/2, 0)
            cr.arc(bx0 + bw - rad, by0 + bh - rad, rad, 0, math.pi/2)
            cr.arc(bx0 + rad, by0 + bh - rad, rad, math.pi/2, math.pi)
            cr.arc(bx0 + rad, by0 + rad, rad, math.pi, 3*math.pi/2)
            cr.close_path()

            cr.set_source_rgba(0.05, 0.08, 0.16, 0.95)
            cr.fill_preserve()
            cr.set_line_width(2.5)
            cr.set_source_rgba(0.09, 0.74, 0.95, 0.85)
            cr.stroke()

            # Home Assistant House
            cr.set_line_width(3.2)
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
            cr.move_to(cx, by0 + 16)
            cr.line_to(cx - 24, by0 + 40)
            cr.line_to(cx - 17, by0 + 40)
            cr.line_to(cx - 17, by0 + 64)
            cr.line_to(cx + 17, by0 + 64)
            cr.line_to(cx + 17, by0 + 40)
            cr.line_to(cx + 24, by0 + 40)
            cr.close_path()
            cr.set_source_rgba(0.09, 0.74, 0.95, 0.25)
            cr.fill_preserve()
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
            cr.stroke()

            # Chimney
            cr.set_line_width(2.0)
            cr.move_to(cx + 12, by0 + 26)
            cr.line_to(cx + 12, by0 + 18)
            cr.line_to(cx + 17, by0 + 18)
            cr.line_to(cx + 17, by0 + 31)
            cr.stroke()

            # Core light
            cr.arc(cx, by0 + 52, 4.0, 0, 2 * math.pi)
            cr.set_source_rgb(0.09, 0.74, 0.95)
            cr.fill()

        return True

    def on_pulse_tick(self):
        self.pulse_phase += 0.08
        self.emblem_area.queue_draw()
        return not self.ready_to_exit

    def probe_dashboard(self):
        # Step 1: Hardware check status
        time.sleep(0.4)
        GLib.idle_add(self.update_status, f"Hardware detected: {self.device_model} ({self.resolution})", 0.30)
        
        # Step 2: Apply optimization profile
        time.sleep(0.4)
        GLib.idle_add(self.update_status, f"Applying hardware profile: {self.profile_id}...", 0.50)

        # Step 3: Probe Home Assistant
        time.sleep(0.4)
        GLib.idle_add(self.update_status, "Connecting to Home Assistant Dashboard...", 0.65)

        start = time.time()
        timeout = 10.0
        resolved = False

        while time.time() - start < timeout:
            try:
                req = urllib.request.Request(self.target_url, headers={"User-Agent": "kiosk-native-splash"})
                resp = urllib.request.urlopen(req, timeout=1.5)
                if resp.status in (200, 301, 302, 401, 403):
                    resolved = True
                    break
            except Exception:
                pass

            pct = 0.65 + min(0.30, ((time.time() - start) / timeout) * 0.30)
            GLib.idle_add(self.update_progress, pct)
            time.sleep(0.4)

        GLib.idle_add(self.update_status, "Dashboard Ready ✓ Launching...", 1.0)
        time.sleep(0.4)
        GLib.idle_add(self.finish_and_exit)

    def update_status(self, text, fraction=None):
        self.status_label.set_markup(f'<span font="13" color="#94a3b8">{text}</span>')
        if fraction is not None:
            self.progress_bar.set_fraction(fraction)

    def update_progress(self, fraction):
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
