#!/usr/bin/env python3
"""
hardware_profiles.py - Hardware Detection & Performance Optimization Engine for KioskOS
Identifies Raspberry Pi models, RAM variants, display resolutions, and generates
optimized hardware profiles (Chromium flags, memory limits, raster threads, compositor tuning).
"""

import os
import sys
import json
import glob
import re
import platform
import subprocess

CONFIG_FILE = "/etc/kiosk/config.json"
FLAGS_FILE = "/etc/kiosk/chromium-flags.conf"
HW_INFO_FILE = "/etc/kiosk/hardware-info.json"

# Raspberry Pi Revision Code Decoder Table (partial for fast lookup, model strings are primary)
RPI_REVISION_HINTS = {
    "d04170": ("Raspberry Pi 5", 8192),
    "c04170": ("Raspberry Pi 5", 4096),
    "b04170": ("Raspberry Pi 5", 2048),
    "d03115": ("Raspberry Pi 4 Model B", 8192),
    "d03114": ("Raspberry Pi 4 Model B", 8192),
    "c03114": ("Raspberry Pi 4 Model B", 4096),
    "c03112": ("Raspberry Pi 4 Model B", 4096),
    "c03111": ("Raspberry Pi 4 Model B", 4096),
    "b03114": ("Raspberry Pi 4 Model B", 2048),
    "b03112": ("Raspberry Pi 4 Model B", 2048),
    "b03111": ("Raspberry Pi 4 Model B", 2048),
    "a03111": ("Raspberry Pi 4 Model B", 1024),
    "a020d3": ("Raspberry Pi 3 Model B+", 1024),
    "a02082": ("Raspberry Pi 3 Model B", 1024),
    "a22082": ("Raspberry Pi 3 Model B", 1024),
    "902120": ("Raspberry Pi Zero 2 W", 512),
    "9000c1": ("Raspberry Pi Zero W", 512),
}

def get_cpu_info():
    info = {
        "model_name": "Unknown CPU",
        "cores": os.cpu_count() or 1,
        "revision": "",
        "hardware": "",
        "architecture": platform.machine()
    }
    if sys.platform == "darwin":
        try:
            m = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
            info["model_name"] = m
        except Exception:
            pass
        return info

    if os.path.exists("/proc/cpuinfo"):
        try:
            with open("/proc/cpuinfo", "r") as f:
                for line in f:
                    parts = line.strip().split(":")
                    if len(parts) == 2:
                        k, v = parts[0].strip(), parts[1].strip()
                        if k in ("model name", "Processor"):
                            info["model_name"] = v
                        elif k == "Revision":
                            info["revision"] = v.lower()
                        elif k == "Hardware":
                            info["hardware"] = v
        except Exception:
            pass
    return info

def get_device_tree_model():
    if sys.platform == "darwin":
        try:
            m = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
            return f"Apple Mac ({m})"
        except Exception:
            return "Apple Mac"

    for path in ["/proc/device-tree/model", "/sys/firmware/devicetree/base/model"]:
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read().strip().replace("\x00", "")
                    if content:
                        return content
            except Exception:
                pass
    return None

def get_ram_info():
    total_kb = 0
    available_kb = 0
    if sys.platform == "darwin":
        try:
            mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())
            total_kb = int(mem_bytes / 1024)
            available_kb = int(total_kb * 0.6)
        except Exception:
            pass
    elif os.path.exists("/proc/meminfo"):
        try:
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        total_kb = int(line.split()[1])
                    elif line.startswith("MemAvailable:"):
                        available_kb = int(line.split()[1])
        except Exception:
            pass
    
    total_mb = int(total_kb / 1024)
    avail_mb = int(available_kb / 1024)
    total_gb = round(total_mb / 1024.0, 1)
    return {
        "total_kb": total_kb,
        "total_mb": total_mb,
        "total_gb": total_gb,
        "available_mb": avail_mb
    }

def get_cpu_temp():
    # Try thermal zone
    for tz in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            with open(tz, "r") as f:
                val = float(f.read().strip())
                if val > 1000:
                    val /= 1000.0
                return round(val, 1)
        except Exception:
            pass
    # Try vcgencmd
    try:
        res = subprocess.run(["vcgencmd", "measure_temp"], capture_output=True, text=True, timeout=1)
        m = re.search(r"temp=([0-9.]+)", res.stdout)
        if m:
            return float(m.group(1))
    except Exception:
        pass
    return None

def get_display_info():
    displays = []
    # Probe DRM connector status and modes
    for status_file in glob.glob("/sys/class/drm/card*-*/status"):
        try:
            with open(status_file, "r") as f:
                status = f.read().strip()
            connector_dir = os.path.dirname(status_file)
            connector_name = os.path.basename(connector_dir)
            # Remove card prefix e.g. card0-HDMI-A-1 -> HDMI-A-1
            m = re.search(r"card\d+-(.+)", connector_name)
            name = m.group(1) if m else connector_name

            modes = []
            modes_file = os.path.join(connector_dir, "modes")
            if os.path.exists(modes_file):
                with open(modes_file, "r") as mf:
                    modes = [l.strip() for l in mf if l.strip()]

            if status == "connected":
                native_mode = modes[0] if modes else "Unknown"
                width, height = 0, 0
                if "x" in native_mode:
                    try:
                        w_str, h_str = native_mode.split("x")[:2]
                        width, height = int(w_str), int(h_str)
                    except Exception:
                        pass
                displays.append({
                    "connector": name,
                    "connected": True,
                    "current_mode": native_mode,
                    "width": width,
                    "height": height,
                    "available_modes": modes[:5]
                })
        except Exception:
            pass

    # If no displays detected via DRM, try wlr-randr or framebuffer
    if not displays:
        try:
            res = subprocess.run(["wlr-randr"], capture_output=True, text=True, timeout=2)
            cur_head = None
            for line in res.stdout.splitlines():
                if not line.startswith(" ") and line.strip():
                    cur_head = line.split()[0]
                elif "current" in line and cur_head:
                    m = re.search(r"(\d+)x(\d+) px, ([0-9.]+) Hz", line)
                    if m:
                        displays.append({
                            "connector": cur_head,
                            "connected": True,
                            "current_mode": f"{m.group(1)}x{m.group(2)}",
                            "width": int(m.group(1)),
                            "height": int(m.group(2)),
                            "refresh_rate": float(m.group(3))
                        })
        except Exception:
            pass

    if not displays:
        displays.append({
            "connector": "Default / Auto",
            "connected": True,
            "current_mode": "1920x1080",
            "width": 1920,
            "height": 1080
        })

    primary = displays[0]
    return {
        "primary": primary,
        "width": primary["width"],
        "height": primary["height"],
        "resolution": primary["current_mode"],
        "all": displays
    }

def detect_hardware():
    dt_model = get_device_tree_model()
    cpu_info = get_cpu_info()
    ram_info = get_ram_info()
    temp = get_cpu_temp()
    display = get_display_info()

    is_pi = False
    device_model = "Generic Linux Device"
    pi_generation = None
    pi_ram_variant = None

    # Determine if it's a Raspberry Pi
    if dt_model and "Raspberry Pi" in dt_model:
        is_pi = True
        device_model = dt_model
    elif cpu_info.get("hardware") in ("BCM2835", "BCM2836", "BCM2837", "BCM2711", "BCM2712"):
        is_pi = True
        device_model = f"Raspberry Pi ({cpu_info.get('hardware')})"

    if not is_pi and cpu_info.get("revision") in RPI_REVISION_HINTS:
        is_pi = True
        hint_name, hint_ram = RPI_REVISION_HINTS[cpu_info.get("revision")]
        device_model = hint_name

    # Identify Pi generation and RAM variant
    if is_pi:
        m = re.search(r"Raspberry Pi\s+(\d+|Zero\s*2\s*W|Zero\s*W|Zero|Compute Module\s*\d+)", device_model, re.IGNORECASE)
        if m:
            pi_generation = m.group(1).upper()

        # Classify RAM tier
        total_mb = ram_info["total_mb"]
        if total_mb >= 7000:
            pi_ram_variant = "8GB"
        elif total_mb >= 3400:
            pi_ram_variant = "4GB"
        elif total_mb >= 1600:
            pi_ram_variant = "2GB"
        elif total_mb >= 800:
            pi_ram_variant = "1GB"
        else:
            pi_ram_variant = "512MB"

    # Select Hardware Profile
    profile_id = "generic_balanced"
    profile_name = "Generic Balanced"

    if is_pi:
        if pi_generation == "5":
            if pi_ram_variant in ("8GB", "4GB"):
                profile_id = "rpi5_high"
                profile_name = f"Raspberry Pi 5 ({pi_ram_variant}) - High Performance"
            else:
                profile_id = "rpi5_balanced"
                profile_name = f"Raspberry Pi 5 ({pi_ram_variant}) - Balanced"
        elif "4" in str(pi_generation):
            if pi_ram_variant in ("8GB", "4GB"):
                profile_id = "rpi4_high"
                profile_name = f"Raspberry Pi 4 ({pi_ram_variant}) - High Performance"
            elif pi_ram_variant == "2GB":
                profile_id = "rpi4_2gb"
                profile_name = "Raspberry Pi 4 (2GB) - Optimized"
            else:
                profile_id = "rpi4_1gb"
                profile_name = "Raspberry Pi 4 (1GB) - Compact"
        elif "3" in str(pi_generation):
            profile_id = "rpi3"
            profile_name = f"Raspberry Pi 3 ({pi_ram_variant}) - Lean"
        elif "ZERO 2" in str(pi_generation):
            profile_id = "rpizero2"
            profile_name = "Raspberry Pi Zero 2 W (512MB) - Ultra-Lean"
        else:
            profile_id = "rpilegacy"
            profile_name = f"Raspberry Pi Legacy ({pi_ram_variant})"
    else:
        # Generic auto-tuning based on RAM
        total_mb = ram_info["total_mb"]
        if total_mb >= 4000:
            profile_id = "generic_high"
            profile_name = f"Generic High Performance ({ram_info['total_gb']}GB RAM)"
        elif total_mb >= 2000:
            profile_id = "generic_balanced"
            profile_name = f"Generic Balanced ({ram_info['total_gb']}GB RAM)"
        elif total_mb >= 900:
            profile_id = "generic_lean"
            profile_name = f"Generic Lean ({ram_info['total_gb']}GB RAM)"
        else:
            profile_id = "generic_ultralean"
            profile_name = f"Generic Ultra-Lean (<1GB RAM)"

    return {
        "is_raspberry_pi": is_pi,
        "device_model": device_model,
        "pi_generation": pi_generation,
        "pi_ram_variant": pi_ram_variant,
        "cpu": cpu_info,
        "ram": ram_info,
        "temperature_c": temp,
        "display": display,
        "profile_id": profile_id,
        "profile_name": profile_name
    }

def get_profile_specs(profile_id, ram_mb=2048):
    """
    Returns exact performance flags and optimization rules for a given profile ID.
    """
    specs = {
        "rpi5_high": {
            "js_heap_mb": 1024,
            "raster_threads": 4,
            "renderer_limit": 4,
            "cache_location": "ramdisk",
            "cache_size_mb": 128,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": True,
            "swappiness": 10,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--canvas-oop-rasterization",
                "--enable-raw-draw",
                "--num-raster-threads=4",
                "--enable-features=VaapiVideoDecoder,CanvasOopRasterization",
                "--js-flags=--max-old-space-size=1024",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=134217728"
            ],
            "description": "Full VideoCore VII hardware acceleration, 4 raster threads, 1GB JS heap, high-speed RAM caching."
        },
        "rpi5_balanced": {
            "js_heap_mb": 512,
            "raster_threads": 4,
            "renderer_limit": 3,
            "cache_location": "ramdisk",
            "cache_size_mb": 64,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": True,
            "swappiness": 20,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--canvas-oop-rasterization",
                "--num-raster-threads=4",
                "--renderer-process-limit=3",
                "--js-flags=--max-old-space-size=512",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=67108864"
            ],
            "description": "VideoCore VII acceleration, balanced 512MB JS heap, 64MB RAM cache."
        },
        "rpi4_high": {
            "js_heap_mb": 768,
            "raster_threads": 3,
            "renderer_limit": 3,
            "cache_location": "ramdisk",
            "cache_size_mb": 64,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": False,
            "swappiness": 20,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--canvas-oop-rasterization",
                "--ignore-gpu-blocklist",
                "--num-raster-threads=3",
                "--renderer-process-limit=3",
                "--js-flags=--max-old-space-size=768",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=67108864"
            ],
            "description": "VideoCore VI acceleration, 3 raster threads, 768MB JS heap, smooth animations."
        },
        "rpi4_2gb": {
            "js_heap_mb": 384,
            "raster_threads": 2,
            "renderer_limit": 2,
            "cache_location": "ramdisk",
            "cache_size_mb": 32,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": False,
            "swappiness": 40,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--num-raster-threads=2",
                "--renderer-process-limit=2",
                "--js-flags=--max-old-space-size=384",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=33554432"
            ],
            "description": "Tuned 2-process limit, 384MB JS heap, 32MB RAM cache, low memory overhead."
        },
        "rpi4_1gb": {
            "js_heap_mb": 256,
            "raster_threads": 2,
            "renderer_limit": 1,
            "cache_location": "disk",
            "cache_size_mb": 16,
            "smooth_scrolling": False,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": False,
            "swappiness": 60,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--renderer-process-limit=1",
                "--num-raster-threads=2",
                "--disable-smooth-scrolling",
                "--js-flags=--max-old-space-size=256",
                "--disk-cache-size=16777216"
            ],
            "description": "Strict single-renderer process, 256MB JS heap, disabled smooth scrolling to eliminate frame drops."
        },
        "rpi3": {
            "js_heap_mb": 256,
            "raster_threads": 2,
            "renderer_limit": 1,
            "cache_location": "disk",
            "cache_size_mb": 16,
            "smooth_scrolling": False,
            "gpu_rasterization": True,
            "zero_copy": False,
            "vulkan": False,
            "swappiness": 80,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--renderer-process-limit=1",
                "--num-raster-threads=2",
                "--disable-smooth-scrolling",
                "--enable-low-res-tiling",
                "--js-flags=--max-old-space-size=256",
                "--disk-cache-size=16777216"
            ],
            "description": "VideoCore IV conservative flags, low-resolution tiling, 256MB JS heap."
        },
        "rpizero2": {
            "js_heap_mb": 192,
            "raster_threads": 1,
            "renderer_limit": 1,
            "cache_location": "disk",
            "cache_size_mb": 8,
            "smooth_scrolling": False,
            "gpu_rasterization": False,
            "zero_copy": False,
            "vulkan": False,
            "swappiness": 100,
            "chromium_flags": [
                "--renderer-process-limit=1",
                "--num-raster-threads=1",
                "--disable-smooth-scrolling",
                "--disable-gpu-compositing",
                "--js-flags=--max-old-space-size=192",
                "--disk-cache-size=8388608"
            ],
            "description": "Ultra-lean 512MB RAM constraint, software compositing fallback, 192MB JS limit."
        },
        "rpilegacy": {
            "js_heap_mb": 128,
            "raster_threads": 1,
            "renderer_limit": 1,
            "cache_location": "disk",
            "cache_size_mb": 4,
            "smooth_scrolling": False,
            "gpu_rasterization": False,
            "zero_copy": False,
            "vulkan": False,
            "swappiness": 100,
            "chromium_flags": [
                "--renderer-process-limit=1",
                "--num-raster-threads=1",
                "--disable-smooth-scrolling",
                "--disable-gpu-compositing",
                "--js-flags=--max-old-space-size=128",
                "--disk-cache-size=4194304"
            ],
            "description": "Extreme legacy ARM constraint."
        },
        "generic_high": {
            "js_heap_mb": 1024,
            "raster_threads": 4,
            "renderer_limit": 4,
            "cache_location": "ramdisk",
            "cache_size_mb": 128,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": False,
            "swappiness": 10,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--canvas-oop-rasterization",
                "--num-raster-threads=4",
                "--js-flags=--max-old-space-size=1024",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=134217728"
            ],
            "description": "High RAM multi-core x86/ARM target with 1GB JS heap, 4 raster threads."
        },
        "generic_balanced": {
            "js_heap_mb": 512,
            "raster_threads": 3,
            "renderer_limit": 2,
            "cache_location": "ramdisk",
            "cache_size_mb": 64,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": False,
            "swappiness": 30,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--num-raster-threads=3",
                "--renderer-process-limit=2",
                "--js-flags=--max-old-space-size=512",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=67108864"
            ],
            "description": "Balanced 2GB-4GB RAM target with GPU rasterization and 512MB JS heap."
        },
        "generic_lean": {
            "js_heap_mb": 384,
            "raster_threads": 2,
            "renderer_limit": 2,
            "cache_location": "ramdisk",
            "cache_size_mb": 32,
            "smooth_scrolling": True,
            "gpu_rasterization": True,
            "zero_copy": True,
            "vulkan": False,
            "swappiness": 50,
            "chromium_flags": [
                "--enable-gpu-rasterization",
                "--enable-zero-copy",
                "--num-raster-threads=2",
                "--renderer-process-limit=2",
                "--js-flags=--max-old-space-size=384",
                "--disk-cache-dir=/tmp/chromium-cache",
                "--disk-cache-size=33554432"
            ],
            "description": "Lean 1GB-2GB RAM target with compact memory boundaries."
        },
        "generic_ultralean": {
            "js_heap_mb": 192,
            "raster_threads": 1,
            "renderer_limit": 1,
            "cache_location": "disk",
            "cache_size_mb": 8,
            "smooth_scrolling": False,
            "gpu_rasterization": False,
            "zero_copy": False,
            "vulkan": False,
            "swappiness": 100,
            "chromium_flags": [
                "--renderer-process-limit=1",
                "--num-raster-threads=1",
                "--disable-smooth-scrolling",
                "--js-flags=--max-old-space-size=192",
                "--disk-cache-size=8388608"
            ],
            "description": "Low-resource <1GB RAM target, single renderer, disabled smooth scrolling."
        }
    }
    return specs.get(profile_id, specs["generic_balanced"])

def apply_hardware_profile(force_profile=None):
    hw = detect_hardware()
    profile_id = force_profile or hw["profile_id"]
    specs = get_profile_specs(profile_id, hw["ram"]["total_mb"])

    # Prepare directories
    for d in ["/etc/kiosk", "/opt/kiosk"]:
        os.makedirs(d, exist_ok=True)

    # 1. Save hardware info json
    hw["active_profile"] = profile_id
    hw["active_specs"] = specs
    for p in [HW_INFO_FILE, "/opt/kiosk/hardware-info.json"]:
        try:
            with open(p, "w") as f:
                json.dump(hw, f, indent=2)
        except Exception:
            pass

    # 2. Write chromium flags file
    flag_lines = [
        f"# KioskOS Hardware-Optimized Chromium Flags",
        f"# Profile: {profile_id} ({hw['profile_name']})",
        f"# Target Hardware: {hw['device_model']} ({hw['ram']['total_gb']} GB RAM)",
        f"# Display: {hw['display']['resolution']} on {hw['display']['primary']['connector']}",
        ""
    ] + specs["chromium_flags"]

    for p in [FLAGS_FILE, "/opt/kiosk/chromium-flags.conf"]:
        try:
            with open(p, "w") as f:
                f.write("\n".join(flag_lines) + "\n")
        except Exception:
            pass

    # 3. Apply sysctl swappiness if root
    if os.geteuid() == 0 and "swappiness" in specs:
        try:
            subprocess.run(["sysctl", f"vm.swappiness={specs['swappiness']}"], capture_output=True)
        except Exception:
            pass

    return hw, specs

def print_hardware_report():
    hw = detect_hardware()
    specs = get_profile_specs(hw["profile_id"], hw["ram"]["total_mb"])

    BOLD = "\033[1m"
    GREEN = "\033[32m"
    CYAN = "\033[36m"
    YELLOW = "\033[33m"
    MAGENTA = "\033[35m"
    NC = "\033[0m"

    print(f"\n{CYAN}{'='*70}{NC}")
    print(f"{BOLD}           KioskOS Hardware Detection & Optimization Engine{NC}")
    print(f"{CYAN}{'='*70}{NC}")
    
    brand = f"{MAGENTA}Raspberry Pi Hardware{NC}" if hw["is_raspberry_pi"] else f"{GREEN}Generic Hardware{NC}"
    print(f"  • Hardware Class:     {brand}")
    print(f"  • Device Model:       {BOLD}{hw['device_model']}{NC}")
    print(f"  • CPU Architecture:   {hw['cpu']['architecture']} ({hw['cpu']['cores']} Cores)")
    if hw["temperature_c"]:
        print(f"  • Temperature:        {hw['temperature_c']} °C")
    
    ram = hw["ram"]
    print(f"  • System Memory:      {BOLD}{ram['total_gb']} GB{NC} ({ram['total_mb']} MB total, {ram['available_mb']} MB free)")
    
    disp = hw["display"]
    print(f"  • Active Display:     {GREEN}{disp['primary']['connector']}{NC} @ {BOLD}{disp['resolution']}{NC}")
    
    print(f"\n{BOLD}[Optimal Performance Profile]{NC}")
    print(f"  • Profile ID:         {CYAN}{hw['profile_id']}{NC}")
    print(f"  • Name:               {BOLD}{hw['profile_name']}{NC}")
    print(f"  • Summary:            {specs['description']}")
    print(f"  • JS Heap Boundary:   {specs['js_heap_mb']} MB")
    print(f"  • Raster Threads:     {specs['raster_threads']}")
    print(f"  • Renderer Limit:     {specs['renderer_limit']}")
    print(f"  • GPU Rasterization:  {'Enabled' if specs['gpu_rasterization'] else 'Disabled'}")
    print(f"  • Zero-Copy Shm:      {'Enabled' if specs['zero_copy'] else 'Disabled'}")
    print(f"  • Cache Mode:         {specs['cache_location']} ({specs['cache_size_mb']} MB)")
    print(f"{CYAN}{'='*70}{NC}\n")

if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "report"
    if action in ("report", "print", "status", "hw"):
        print_hardware_report()
    elif action == "detect":
        hw = detect_hardware()
        print(json.dumps(hw, indent=2))
    elif action == "apply":
        profile = sys.argv[2] if len(sys.argv) > 2 else None
        hw, specs = apply_hardware_profile(profile)
        print(f"Applied profile: {hw['profile_id']} ({hw['profile_name']})")
    elif action == "flags":
        hw = detect_hardware()
        specs = get_profile_specs(hw["profile_id"], hw["ram"]["total_mb"])
        print(" ".join(specs["chromium_flags"]))
    elif action == "list":
        print("Available KioskOS Hardware Profiles:")
        for pid in [
            "rpi5_high", "rpi5_balanced", "rpi4_high", "rpi4_2gb", "rpi4_1gb",
            "rpi3", "rpizero2", "rpilegacy", "generic_high", "generic_balanced",
            "generic_lean", "generic_ultralean"
        ]:
            s = get_profile_specs(pid)
            print(f"  • {pid:<18} - {s['description']}")
    else:
        print_hardware_report()
