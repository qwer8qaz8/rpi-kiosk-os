#!/usr/bin/env python3
"""
kiosk-mcp.py - Official Model Context Protocol (MCP) Server for KioskOS
Allows AI assistants (Antigravity, Claude, Home Assistant MCP) to manage,
monitor, configure, and automate the KioskOS appliance via standard MCP tools.
Supports both stdio (default) and lightweight HTTP JSON-RPC modes.
"""

import sys
import os
import json
import subprocess
import time
from pathlib import Path

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
    target = "/etc/kiosk/config.json" if os.path.exists("/etc/kiosk") else "/opt/kiosk/config.json"
    try:
        with open(target, "w") as f:
            json.dump(cfg, f, indent=2)
        return True
    except Exception as e:
        try:
            p = subprocess.Popen(["sudo", "tee", target], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
            p.communicate(input=json.dumps(cfg, indent=2).encode())
            return p.returncode == 0
        except Exception:
            return False

TOOLS = [
    {
        "name": "kiosk_get_status",
        "description": "Get complete hardware telemetry, power state, dashboard URL, temperature, and performance mode of the KioskOS display.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "kiosk_set_url",
        "description": "Set the primary dashboard / web application URL displayed on the kiosk screen.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The full HTTP/HTTPS URL to display on the kiosk."
                }
            },
            "required": ["url"]
        }
    },
    {
        "name": "kiosk_set_power",
        "description": "Turn the kiosk physical screen / display power ON or OFF.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "power": {
                    "type": "boolean",
                    "description": "True to turn screen ON, False to turn screen OFF (standby)."
                }
            },
            "required": ["power"]
        }
    },
    {
        "name": "kiosk_set_brightness",
        "description": "Adjust the kiosk screen hardware brightness level (10% to 100%).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "brightness": {
                    "type": "integer",
                    "minimum": 10,
                    "maximum": 100,
                    "description": "Brightness percentage from 10 to 100."
                }
            },
            "required": ["brightness"]
        }
    },
    {
        "name": "kiosk_set_rotation",
        "description": "Rotate the display orientation via Wayland compositor.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "rotation": {
                    "type": "string",
                    "enum": ["normal", "90", "180", "270"],
                    "description": "Display orientation angle."
                }
            },
            "required": ["rotation"]
        }
    },
    {
        "name": "kiosk_speed_mode",
        "description": "Set performance mode: 'turbo' (pure locked kiosk, all listeners suppressed for max speed) or 'standard'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "enum": ["standard", "turbo"],
                    "description": "Performance profile."
                }
            },
            "required": ["mode"]
        }
    },
    {
        "name": "kiosk_touch_control",
        "description": "Manage Optical Camera Touchscreen Suite (enable/disable, mode, dynamic markers).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "enabled": {"type": "boolean", "description": "Enable or disable optical touch digitizer."},
                "mode": {"type": "string", "enum": ["single", "dual", "kinect"], "description": "Tracking sensor mode."},
                "dynamic_tracking": {"type": "boolean", "description": "Enable subtle corner mini-markers for moving cameras."}
            }
        }
    },
    {
        "name": "kiosk_trigger_chime",
        "description": "Play the hardware startup audio chime through connected speakers / audio jack.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "kiosk_reboot",
        "description": "Safely reboot the Raspberry Pi KioskOS system.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    }
]

def handle_tool_call(name, args):
    cfg = load_config()

    if name == "kiosk_get_status":
        temp = "Unknown"
        if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
            try:
                temp = f"{round(float(open('/sys/class/thermal/thermal_zone0/temp').read().strip()) / 1000.0, 1)}°C"
            except Exception:
                pass
        
        ip_res = subprocess.run(["hostname", "-I"], capture_output=True, text=True)
        ip_str = ip_res.stdout.strip().split()[0] if ip_res.stdout.strip() else "127.0.0.1"

        return {
            "dashboard_url": cfg.get("dashboard_url", "http://homeassistant.local:8123"),
            "screen_on": cfg.get("screen_on", True),
            "brightness": cfg.get("screen_brightness", cfg.get("brightness", 100)),
            "rotation": cfg.get("display_rotation", "normal"),
            "speed_mode": cfg.get("speed_mode", "standard"),
            "admin_enabled": cfg.get("admin_enabled", True),
            "camera_touch": cfg.get("camera_touch", {}),
            "system_ip": ip_str,
            "cpu_temperature": temp,
            "workstation_mode": os.path.exists("/tmp/kiosk-admin-workstation"),
            "webui_active": subprocess.run(["systemctl", "is-active", "kiosk-webui"], capture_output=True, text=True).stdout.strip() == "active"
        }

    elif name == "kiosk_set_url":
        url = args.get("url", "").strip()
        if not url:
            return {"error": "Missing url"}
        cfg["dashboard_url"] = url
        save_config(cfg)
        subprocess.run(["sudo", "systemctl", "restart", "kiosk-display"])
        return {"success": True, "dashboard_url": url}

    elif name == "kiosk_set_power":
        state = bool(args.get("power", True))
        cfg["screen_on"] = state
        save_config(cfg)
        subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "on" if state else "off"], capture_output=True)
        return {"success": True, "screen_on": state}

    elif name == "kiosk_set_brightness":
        val = int(args.get("brightness", 100))
        val = max(10, min(100, val))
        cfg["screen_brightness"] = val
        cfg["brightness"] = val
        save_config(cfg)
        subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "brightness", str(val)], capture_output=True)
        return {"success": True, "brightness": val}

    elif name == "kiosk_set_rotation":
        rot = args.get("rotation", "normal")
        cfg["display_rotation"] = rot
        save_config(cfg)
        subprocess.run(["sudo", "/usr/local/bin/kiosk-screen", "rotate", rot], capture_output=True)
        return {"success": True, "rotation": rot}

    elif name == "kiosk_speed_mode":
        mode = args.get("mode", "standard")
        cfg["speed_mode"] = mode
        cfg["admin_enabled"] = (mode != "turbo")
        save_config(cfg)
        subprocess.Popen(["sudo", "systemctl", "restart", "kiosk-display"])
        return {"success": True, "speed_mode": mode}

    elif name == "kiosk_touch_control":
        if "camera_touch" not in cfg:
            cfg["camera_touch"] = {}
        if "enabled" in args:
            cfg["camera_touch"]["enabled"] = bool(args["enabled"])
            action = "start" if args["enabled"] else "stop"
            subprocess.run(["sudo", "systemctl", action, "kiosk-camera-touch.service"], capture_output=True)
        if "mode" in args:
            cfg["camera_touch"]["mode"] = args["mode"]
            subprocess.run(["sudo", "systemctl", "restart", "kiosk-camera-touch.service"], capture_output=True)
        if "dynamic_tracking" in args:
            cfg["camera_touch"]["dynamic_tracking"] = bool(args["dynamic_tracking"])
            subprocess.run(["sudo", "systemctl", "restart", "kiosk-camera-touch.service"], capture_output=True)
        save_config(cfg)
        return {"success": True, "camera_touch": cfg["camera_touch"]}

    elif name == "kiosk_trigger_chime":
        if os.path.exists("/opt/kiosk/play-chime.sh"):
            subprocess.Popen(["/bin/bash", "/opt/kiosk/play-chime.sh"])
            return {"success": True, "message": "Startup chime played"}
        return {"error": "Chime script not found"}

    elif name == "kiosk_reboot":
        subprocess.Popen(["sudo", "systemctl", "reboot"])
        return {"success": True, "message": "System reboot initiated"}

    return {"error": f"Unknown tool: {name}"}

def run_stdio():
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            req = json.loads(line.strip())
            req_id = req.get("id")
            method = req.get("method")
            params = req.get("params", {})

            if method == "initialize":
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {
                            "tools": {}
                        },
                        "serverInfo": {
                            "name": "kioskos-mcp",
                            "version": "1.0.0"
                        }
                    }
                }
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "tools": TOOLS
                    }
                }
            elif method == "tools/call":
                name = params.get("name")
                args = params.get("arguments", {})
                tool_result = handle_tool_call(name, args)
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(tool_result, indent=2)
                            }
                        ]
                    }
                }
            else:
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {
                        "code": -32601,
                        "message": f"Method not found: {method}"
                    }
                }

            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()
        except (KeyboardInterrupt, SystemExit):
            break
        except Exception as e:
            err_res = {
                "jsonrpc": "2.0",
                "id": req_id if 'req_id' in locals() else None,
                "error": {
                    "code": -32603,
                    "message": str(e)
                }
            }
            sys.stdout.write(json.dumps(err_res) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    run_stdio()
