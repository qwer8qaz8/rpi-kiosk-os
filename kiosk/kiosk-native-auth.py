#!/usr/bin/env python3
"""
kiosk-native-auth.py - Native GTK3 Authentication Dialog for KioskOS
Hardware-accelerated native Wayland modal. Grabs keyboard input cleanly.
"""

import sys
import os
import json
import subprocess
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

class NativeAuthDialog(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.config = load_config()

        self.set_title("KioskOS Authentication")
        self.set_modal(True)
        self.set_decorated(False)
        self.set_default_size(420, 260)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_keep_above(True)
        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", Gtk.main_quit)

        # Dark theme styling
        css_provider = Gtk.CssProvider()
        css = b"""
        window {
            background-color: #0f172a;
            border: 2px solid #334155;
            border-radius: 16px;
        }
        .card-box {
            padding: 28px;
        }
        entry {
            background-color: #1e293b;
            color: #ffffff;
            border: 1px solid #475569;
            border-radius: 10px;
            padding: 10px 14px;
            font-size: 15px;
        }
        entry:focus {
            border-color: #38bdf8;
        }
        button {
            border-radius: 8px;
            padding: 10px 18px;
            font-size: 14px;
            font-weight: 600;
        }
        button.cancel-btn {
            background-color: #334155;
            color: #cbd5e1;
            border: none;
        }
        button.cancel-btn:hover {
            background-color: #475569;
        }
        button.unlock-btn {
            background-color: #2563eb;
            color: #ffffff;
            border: none;
        }
        button.unlock-btn:hover {
            background-color: #1d4ed8;
        }
        """
        css_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card.get_style_context().add_class("card-box")
        self.add(card)

        # Header Icon & Title
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        icon_lbl = Gtk.Label()
        icon_lbl.set_markup('<span font="24">🔒</span>')
        header.pack_start(icon_lbl, False, False, 0)

        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title_lbl = Gtk.Label()
        title_lbl.set_markup('<span font="16" weight="bold" color="#ffffff">Administrator Unlock</span>')
        title_lbl.set_halign(Gtk.Align.START)
        title_box.pack_start(title_lbl, False, False, 0)

        sub_lbl = Gtk.Label()
        sub_lbl.set_markup('<span font="12" color="#94a3b8">Enter admin password or PIN to unlock desktop mode</span>')
        sub_lbl.set_halign(Gtk.Align.START)
        title_box.pack_start(sub_lbl, False, False, 0)

        header.pack_start(title_box, True, True, 0)
        card.pack_start(header, False, False, 0)

        # Password Entry
        self.entry = Gtk.Entry()
        self.entry.set_visibility(False)
        self.entry.set_placeholder_text("Password or PIN")
        self.entry.connect("activate", self.on_unlock_clicked)
        card.pack_start(self.entry, False, False, 4)

        # Error label
        self.error_lbl = Gtk.Label()
        self.error_lbl.set_markup('<span font="12" color="#f87171"></span>')
        self.error_lbl.set_halign(Gtk.Align.START)
        card.pack_start(self.error_lbl, False, False, 0)

        # Buttons
        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        cancel_btn = Gtk.Button(label="Cancel (Esc)")
        cancel_btn.get_style_context().add_class("cancel-btn")
        cancel_btn.connect("clicked", lambda w: self.close_and_exit())
        btn_box.pack_start(cancel_btn, True, True, 0)

        unlock_btn = Gtk.Button(label="Unlock (Enter)")
        unlock_btn.get_style_context().add_class("unlock-btn")
        unlock_btn.connect("clicked", self.on_unlock_clicked)
        btn_box.pack_start(unlock_btn, True, True, 0)

        card.pack_start(btn_box, False, False, 6)

    def on_key_press(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.close_and_exit()
            return True
        return False

    def on_unlock_clicked(self, widget):
        pw = self.entry.get_text().strip()
        configured_pin = str(self.config.get("webui_pin", "")).strip()

        # Valid master passwords / pins
        valid_keys = ["rusert 1921", "rusert1921", "kiosk", "admin", "1234"]
        if configured_pin:
            valid_keys.append(configured_pin.lower())

        if pw.lower() in valid_keys:
            self.error_lbl.set_markup('<span font="12" color="#34d399">✓ Unlocking Desktop Mode...</span>')
            GLib.timeout_add(200, self.launch_desktop)
        else:
            self.error_lbl.set_markup('<span font="12" color="#f87171">Incorrect password or PIN.</span>')
            self.entry.set_text("")
            self.entry.grab_focus()

    def launch_desktop(self):
        self.destroy()
        if os.path.exists("/opt/kiosk/start-desktop.sh"):
            subprocess.Popen(["/bin/bash", "/opt/kiosk/start-desktop.sh"])
        Gtk.main_quit()

    def close_and_exit(self):
        self.destroy()
        Gtk.main_quit()

def main():
    try:
        win = NativeAuthDialog()
        win.show_all()
        win.entry.grab_focus()
        Gtk.main()
    except Exception as e:
        print(f"Error starting auth dialog: {e}")

if __name__ == "__main__":
    main()
