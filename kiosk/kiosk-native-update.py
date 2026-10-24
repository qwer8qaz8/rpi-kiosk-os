#!/usr/bin/env python3
"""
kiosk-native-update.py - Native GTK3 System Update Interface for KioskOS
Pure hardware-accelerated GTK3 fullscreen window. Zero browser dependencies.
"""

import sys
import os
import time
import math
import subprocess
import threading

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib

class NativeUpdateWindow(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.pulse_phase = 0.0
        self.is_done = False

        self.set_title("KioskOS System Update")
        self.set_decorated(False)
        self.fullscreen()
        self.set_app_paintable(True)
        self.connect("draw", self.on_draw)
        self.connect("destroy", Gtk.main_quit)

        self.main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        self.main_box.set_valign(Gtk.Align.CENTER)
        self.main_box.set_halign(Gtk.Align.CENTER)
        self.add(self.main_box)

        # Drawing Area for Hex Update Emblem
        self.emblem_area = Gtk.DrawingArea()
        self.emblem_area.set_size_request(160, 160)
        self.emblem_area.connect("draw", self.draw_emblem)
        self.main_box.pack_start(self.emblem_area, False, False, 0)

        # Title
        self.title_label = Gtk.Label()
        self.title_label.set_markup(
            '<span font="26" weight="bold" letter_spacing="3000" color="#ffffff">KIOSK</span>'
            '<span font="26" weight="bold" letter_spacing="3000" color="#34d399">OS</span> '
            '<span font="16" weight="medium" color="#94a3b8">UPDATE</span>'
        )
        self.main_box.pack_start(self.title_label, False, False, 0)

        # Status text
        self.status_label = Gtk.Label()
        self.status_label.set_markup('<span font="15" weight="bold" color="#e2e8f0">Installing System Update...</span>')
        self.main_box.pack_start(self.status_label, False, False, 0)

        self.sub_label = Gtk.Label()
        self.sub_label.set_markup('<span font="13" color="#94a3b8">Connecting to repository. Kiosk will restart automatically.</span>')
        self.main_box.pack_start(self.sub_label, False, False, 0)

        # Progress bar
        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_size_request(380, 8)
        self.progress_bar.set_fraction(0.1)
        self.main_box.pack_start(self.progress_bar, False, False, 10)

        # CSS Styling
        css_provider = Gtk.CssProvider()
        css = b"""
        window {
            background-color: #030712;
        }
        progressbar trough {
            background-color: rgba(255, 255, 255, 0.08);
            border-radius: 8px;
            min-height: 8px;
            border: 1px solid rgba(255, 255, 255, 0.06);
        }
        progressbar progress {
            background: linear-gradient(90deg, #059669, #34d399);
            border-radius: 8px;
            min-height: 8px;
        }
        """
        css_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        GLib.timeout_add(33, self.on_pulse_tick)
        threading.Thread(target=self.run_update_process, daemon=True).start()

    def on_draw(self, widget, cr):
        cr.set_source_rgb(0.012, 0.027, 0.07)  # #030712
        cr.paint()
        return False

    def draw_emblem(self, widget, cr):
        alloc = widget.get_allocation()
        cx = alloc.width / 2.0
        cy = alloc.height / 2.0
        r = 60.0

        glow_alpha = 0.2 + 0.15 * math.sin(self.pulse_phase)
        cr.set_source_rgba(0.2, 0.83, 0.6, glow_alpha * 0.4)
        cr.arc(cx, cy, r + 16, 0, 2 * math.pi)
        cr.fill()

        # Hexagon
        cr.set_line_width(3.0)
        points = []
        for i in range(6):
            angle = math.radians(60 * i - 30)
            points.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))

        cr.move_to(points[0][0], points[0][1])
        for px, py in points[1:]:
            cr.line_to(px, py)
        cr.close_path()

        cr.set_source_rgba(0.06, 0.3, 0.22, 0.4)
        cr.fill_preserve()
        cr.set_source_rgba(0.2, 0.83, 0.6, 0.95)
        cr.stroke()

        # Download / Arrow icon in center
        cr.set_line_width(3.5)
        cr.set_line_cap(1)  # ROUND
        cr.set_line_join(1) # ROUND
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)

        # Down arrow shaft
        cr.move_to(cx, cy - 22)
        cr.line_to(cx, cy + 12)
        cr.stroke()

        # Arrow head
        cr.move_to(cx - 14, cy)
        cr.line_to(cx, cy + 14)
        cr.line_to(cx + 14, cy)
        cr.stroke()

        # Bottom base line
        cr.move_to(cx - 18, cy + 24)
        cr.line_to(cx + 18, cy + 24)
        cr.stroke()

        return True

    def on_pulse_tick(self):
        self.pulse_phase += 0.08
        self.emblem_area.queue_draw()
        return not self.is_done

    def set_step(self, status, subtitle, fraction):
        GLib.idle_add(self._apply_step, status, subtitle, fraction)

    def _apply_step(self, status, subtitle, fraction):
        self.status_label.set_markup(f'<span font="15" weight="bold" color="#e2e8f0">{status}</span>')
        self.sub_label.set_markup(f'<span font="13" color="#94a3b8">{subtitle}</span>')
        self.progress_bar.set_fraction(fraction)

    def run_update_process(self):
        time.sleep(1.0)
        self.set_step("Connecting to GitHub...", "Fetching latest version tags and branches...", 0.2)

        repo_dir = "/home/pi/rpi-kiosk-os"
        if not os.path.exists(repo_dir):
            repo_dir = "/opt/kiosk"

        # 1. Fetch git repo
        try:
            if os.path.exists(os.path.join(repo_dir, ".git")):
                subprocess.run(["git", "-C", repo_dir, "fetch", "--all", "--prune"], capture_output=True, timeout=30)
                self.set_step("Downloading Updates...", "Synchronizing repository changes...", 0.45)
                time.sleep(1.0)
                subprocess.run(["git", "-C", repo_dir, "reset", "--hard", "origin/main"], capture_output=True, timeout=15)
        except Exception as e:
            pass

        self.set_step("Installing System Files...", "Copying updated scripts and configurations...", 0.70)
        time.sleep(1.0)

        # 2. Sync to /opt/kiosk and /etc/kiosk
        try:
            if os.path.exists(f"{repo_dir}/kiosk"):
                subprocess.run(["sudo", "cp", "-r", f"{repo_dir}/kiosk/.", "/opt/kiosk/"], capture_output=True)
                subprocess.run(["sudo", "chmod", "+x", "/opt/kiosk/*.sh"], capture_output=True)
                subprocess.run(["sudo", "chmod", "+x", "/opt/kiosk/*.py"], capture_output=True)
        except Exception:
            pass

        self.set_step("Reloading System Services...", "Applying systemd updates...", 0.90)
        time.sleep(1.0)
        try:
            subprocess.run(["sudo", "systemctl", "daemon-reload"], capture_output=True)
        except Exception:
            pass

        self.set_step("Update Complete ✓", "Restarting Raspberry Pi in 3 seconds...", 1.0)
        time.sleep(3.0)
        self.is_done = True

        # Reboot
        subprocess.run(["sudo", "systemctl", "reboot"])

def main():
    win = NativeUpdateWindow()
    win.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
