#!/usr/bin/env python3
"""
kiosk-marker-overlay.py - Click-Through Persistent Mini-Markers for Dynamic Tracking
Displays 4 small, subtle corner markers for continuous camera homography realignment.
"""

import sys
import os
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib
import cairo

class MarkerOverlay(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("KioskOS Dynamic Tracking Markers")
        self.set_decorated(False)
        self.fullscreen()
        self.set_app_paintable(True)
        self.set_keep_above(True)

        # Transparent screen visuals
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)

        self.connect("draw", self.on_draw)
        self.connect("realize", self.on_realize)

    def on_realize(self, widget):
        # Make window completely click-through (ignore all input events)
        window = widget.get_window()
        if window:
            # Combine with empty region to pass all mouse/touch events through
            empty_region = cairo.Region()
            window.input_shape_combine_region(empty_region, 0, 0, 0)

    def on_draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0) # Clear to transparent
        cr.paint()

        alloc = widget.get_allocation()
        w, h = alloc.width, alloc.height

        # Inset for mini-markers (8% from screen edges)
        ix = int(w * 0.08)
        iy = int(h * 0.08)

        corners = [
            (ix, iy),          # Top-Left
            (w - ix, iy),      # Top-Right
            (w - ix, h - iy),  # Bottom-Right
            (ix, h - iy)       # Bottom-Left
        ]

        cr.set_operator(cairo.OPERATOR_OVER)

        for cx, cy in corners:
            # Subtle outer glow ring (opacity 0.25)
            cr.set_source_rgba(0.20, 0.83, 0.60, 0.25)
            cr.arc(cx, cy, 14, 0, 2 * 3.14159)
            cr.fill()

            # Solid vibrant emerald tracking core (10px diameter, optimal for camera tracking)
            cr.set_source_rgba(0.20, 0.83, 0.60, 0.90)
            cr.arc(cx, cy, 5, 0, 2 * 3.14159)
            cr.fill()

            # Center white pinpoint
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.95)
            cr.arc(cx, cy, 2, 0, 2 * 3.14159)
            cr.fill()

        return False

def main():
    app = MarkerOverlay()
    app.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
