#!/usr/bin/env python3
"""
kiosk-chime-server.py - Ultra-Lightweight Audio Chime & Notification Server
Runs a lean HTTP endpoint (<8MB RAM) allowing Home Assistant, automations,
and local scripts to trigger audio chimes (bing, alert, boot, etc.) instantly.

Home Assistant REST Command:
  rest_command:
    kiosk_bing:
      url: "http://<KIOSK_IP>:8124/chime?sound=bing"
      method: POST
"""

import sys
import os
import subprocess
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

PORT = 8124
CHIME_SCRIPT = "/opt/kiosk/play-chime.sh"
SCREEN_SCRIPT = "/opt/kiosk/screen-control.sh"

class ChimeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._handle_request()

    def do_POST(self):
        self._handle_request()

    def _handle_request(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = urllib.parse.parse_qs(parsed.query)

        if path in ["", "/health", "/status"]:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "online",
                "appliance": "Home Assistant Kiosk",
                "audio_endpoint": "/chime?sound=bing"
            }).encode("utf-8"))
            return

        # Screen Sleep endpoint (turns screen off & monitors mouse to wake)
        if path == "/screen/sleep":
            if os.path.exists(SCREEN_SCRIPT):
                subprocess.Popen(["/bin/bash", SCREEN_SCRIPT, "sleep"])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "action": "sleep"}).encode("utf-8"))
            return

        # Screen Wake endpoint
        if path == "/screen/wake":
            if os.path.exists(SCREEN_SCRIPT):
                subprocess.Popen(["/bin/bash", SCREEN_SCRIPT, "on"])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "action": "wake"}).encode("utf-8"))
            return

        # Brightness adjustment endpoint
        if path == "/brightness":
            val = params.get("value", ["80"])[0]
            try:
                val = str(int(val))
            except ValueError:
                val = "80"
            if os.path.exists(SCREEN_SCRIPT):
                subprocess.Popen(["/bin/bash", SCREEN_SCRIPT, "brightness", val])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "brightness": val}).encode("utf-8"))
            return

        if path == "/chime" or path == "/notify" or path == "/bing":
            sound = params.get("sound", ["bing"])[0].lower()
            if not sound or path == "/bing":
                sound = "bing"

            # Execute chime asynchronously
            if os.path.exists(CHIME_SCRIPT):
                subprocess.Popen(["/bin/bash", CHIME_SCRIPT, sound])

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({
                "success": True,
                "sound": sound,
                "message": f"Played {sound} chime"
            }).encode("utf-8"))
            return

        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": "Not Found"}).encode("utf-8"))

    def log_message(self, format, *args):
        # Keep logs silent to minimize I/O
        pass

def run():
    server = HTTPServer(("0.0.0.0", PORT), ChimeHandler)
    print(f"[kiosk-chime] Notification server listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    run()
