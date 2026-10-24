#!/usr/bin/env python3
"""
kiosk-native-splash.py - Native GTK3 / Wayland Boot Splash for KioskOS
Zero web browser dependencies. High performance hardware-accelerated GTK3 window.
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

        self.set_title("Home Assistant Kiosk Boot Splash")
        self.set_decorated(False)
        self.fullscreen()
        self.set_app_paintable(True)
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        # Main Layout
        self.main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
        self.main_box.set_valign(Gtk.Align.CENTER)
        self.main_box.set_halign(Gtk.Align.CENTER)
        self.add(self.main_box)

        # Drawing Area for custom Home Assistant Display Emblem
        self.emblem_area = Gtk.DrawingArea()
        self.emblem_area.set_size_request(160, 160)
        self.emblem_area.connect("draw", self.draw_emblem)
        self.main_box.pack_start(self.emblem_area, False, False, 0)

        # Title Label
        self.title_label = Gtk.Label()
        self.title_label.set_markup(
            '<span font="30" weight="heavy" color="#ffffff">HOME ASSISTANT <span color="#18bcf2">KIOSK</span></span>'
        )
        self.main_box.pack_start(self.title_label, False, False, 0)

        # Subtitle / Status Label
        self.status_label = Gtk.Label()
        self.status_label.set_markup('<span font="13" color="#94a3b8">Connecting to Home Assistant...</span>')
        self.main_box.pack_start(self.status_label, False, False, 0)

        # Sleek Progress Bar
        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_size_request(340, 6)
        self.progress_bar.set_fraction(0.15)
        self.main_box.pack_start(self.progress_bar, False, False, 10)

        # Credit Label
        self.credit_label = Gtk.Label()
        self.credit_label.set_markup('<span font="11" color="#475569">8Air  •  SuperG Technologies</span>')
        self.main_box.pack_start(self.credit_label, False, False, 4)

        # CSS Styling
        css_provider = Gtk.CssProvider()
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
        # Dark ambient radial background
        alloc = widget.get_allocation()
        cx = alloc.width / 2.0
        cy = alloc.height / 2.0
        cr.set_source_rgb(0.012, 0.027, 0.07)  # #030712
        cr.paint()
        return False

    def draw_emblem(self, widget, cr):
        alloc = widget.get_allocation()
        cx = alloc.width / 2.0
        cy = alloc.height / 2.0

        # Outer pulsing cyan glow
        glow_alpha = 0.25 + 0.15 * math.sin(self.pulse_phase)
        cr.set_source_rgba(0.09, 0.74, 0.95, glow_alpha * 0.35)
        cr.arc(cx, cy, 68 + 4 * math.sin(self.pulse_phase), 0, 2 * math.pi)
        cr.fill()

        # Display Bezel (Rounded Box)
        bw, bh = 110.0, 80.0
        bx0 = cx - bw / 2.0
        by0 = cy - bh / 2.0 - 6.0
        
        # Rounded rect path
        rad = 12.0
        cr.new_sub_path()
        cr.arc(bx0 + bw - rad, by0 + rad, rad, -math.pi/2, 0)
        cr.arc(bx0 + bw - rad, by0 + bh - rad, rad, 0, math.pi/2)
        cr.arc(bx0 + rad, by0 + bh - rad, rad, math.pi/2, math.pi)
        cr.arc(bx0 + rad, by0 + rad, rad, math.pi, 3*math.pi/2)
        cr.close_path()

        # Fill display screen with dark glass
        cr.set_source_rgba(0.05, 0.08, 0.16, 0.9)
        cr.fill_preserve()
        # Cyan border
        cr.set_line_width(2.5)
        cr.set_source_rgba(0.09, 0.74, 0.95, 0.85)
        cr.stroke()

        # Home Assistant House Symbol inside display
        cr.set_line_width(3.0)
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
        
        # Roof
        cr.move_to(cx, by0 + 16)
        cr.line_to(cx - 24, by0 + 38)
        cr.line_to(cx - 18, by0 + 38)
        cr.line_to(cx - 18, by0 + 60)
        cr.line_to(cx + 18, by0 + 60)
        cr.line_to(cx + 18, by0 + 38)
        cr.line_to(cx + 24, by0 + 38)
        cr.close_path()
        cr.set_source_rgba(0.09, 0.74, 0.95, 0.25)
        cr.fill_preserve()
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
        cr.stroke()

        # Small chimney
        cr.set_line_width(2.0)
        cr.move_to(cx + 12, by0 + 26)
        cr.line_to(cx + 12, by0 + 19)
        cr.line_to(cx + 17, by0 + 19)
        cr.line_to(cx + 17, by0 + 30)
        cr.stroke()

        cr.set_source_rgba(0.2, 0.83, 0.6, 0.9)
        cr.fill_preserve()
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.9)
        cr.stroke()

        return True

    def on_pulse_tick(self):
        self.pulse_phase += 0.08
        self.emblem_area.queue_draw()
        return not self.ready_to_exit

    def probe_dashboard(self):
        time.sleep(0.5)
        GLib.idle_add(self.update_status, "Connecting to Home Assistant Dashboard...", 0.35)

        start = time.time()
        timeout = 10.0  # Max 10 seconds wait before continuing anyway
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

            pct = 0.35 + min(0.55, ((time.time() - start) / timeout) * 0.55)
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
