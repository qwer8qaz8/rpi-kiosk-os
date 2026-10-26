#!/usr/bin/env python3
"""
generate-splash.py - High-Fidelity Raspberry Pi Edition Bootsplash Generator
Creates a 1920x1080 PNG bootsplash for Plymouth and KioskOS with supersampled
antialiased vector graphics combining the Raspberry Pi and Home Assistant branding.
"""

import math
import os
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def create_pi_bootsplash(output_path="splash.png"):
    # 2x supersampling for antialiasing
    w, h = 3840, 2160
    img = Image.new("RGBA", (w, h), (4, 7, 16, 255)) # #040710

    # Draw radial glows on a separate layer
    glow_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow_layer)

    cx = w // 2
    cy = int(h * 0.40) # Center emblem at 40% height

    # Left Ruby Glow (Raspberry Pi Ruby #c51a4a)
    for r in range(700, 50, -40):
        alpha = int(22 * (1.0 - r / 700.0))
        glow_draw.ellipse([cx - 240 - r, cy - r, cx - 240 + r, cy + r], fill=(197, 26, 74, alpha))

    # Right Cyan Glow (Home Assistant Cyan #0284c7)
    for r in range(700, 50, -40):
        alpha = int(22 * (1.0 - r / 700.0))
        glow_draw.ellipse([cx + 240 - r, cy - r, cx + 240 + r, cy + r], fill=(2, 132, 199, alpha))

    # Center Cyan Halo
    for r in range(450, 40, -30):
        alpha = int(35 * (1.0 - r / 450.0))
        glow_draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(14, 165, 233, alpha))

    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=60))
    img.paste(glow_layer, (0, 0), glow_layer)

    draw = ImageDraw.Draw(img)

    # 1. Raspberry Pi Top Leaves (Emerald Green #22c55e / #16a34a)
    leaf_color = (34, 197, 94, 255)
    leaf_y = cy - 250
    # Left Leaf
    draw.ellipse([cx - 150 - 65, leaf_y - 65, cx - 150 + 65, leaf_y + 65], fill=leaf_color)
    # Right Leaf
    draw.ellipse([cx + 150 - 65, leaf_y - 65, cx + 150 + 65, leaf_y + 65], fill=leaf_color)
    # Center Stem/Leaf
    draw.ellipse([cx - 55, leaf_y - 100, cx + 55, leaf_y + 30], fill=(22, 163, 74, 255))

    # 2. Raspberry Pi Berry Nodes (Ruby Red #c51a4a & #e11d48)
    ruby_main = (225, 29, 72, 255)   # #e11d48
    ruby_dark = (197, 26, 74, 255)   # #c51a4a

    berry_nodes = [
        # Upper row
        (cx - 170, cy - 140, 80), (cx + 170, cy - 140, 80),
        # Mid-upper row
        (cx - 240, cy - 20, 85),  (cx + 240, cy - 20, 85),
        # Mid-lower row
        (cx - 205, cy + 110, 80), (cx + 205, cy + 110, 80),
        # Lower row
        (cx - 130, cy + 220, 75), (cx + 130, cy + 220, 75),
        # Bottom center
        (cx, cy + 280, 70)
    ]

    for bx, by, br in berry_nodes:
        # Outer glow
        draw.ellipse([bx - br - 8, by - br - 8, bx + br + 8, by + br + 8], fill=(197, 26, 74, 120))
        # Solid node
        draw.ellipse([bx - br, by - br, bx + br, by + br], fill=ruby_main)
        # Highlight
        draw.ellipse([bx - br + 15, by - br + 15, bx - br + 45, by - br + 45], fill=(253, 164, 175, 180))

    # 3. Center Glass Shield (Home Assistant Enclosure)
    sw, sh = 400, 360
    sx0 = cx - sw // 2
    sy0 = cy - sh // 2 - 10
    rad = 50

    # Draw rounded shield
    draw.rounded_rectangle([sx0, sy0, sx0 + sw, sy0 + sh], radius=rad, fill=(7, 12, 26, 245), outline=(14, 165, 233, 255), width=10)
    # Inner subtle border
    draw.rounded_rectangle([sx0 + 8, sy0 + 8, sx0 + sw - 8, sy0 + sh - 8], radius=rad - 6, outline=(244, 63, 94, 160), width=4)

    # 4. Home Assistant House Symbol
    hx = cx
    hy = sy0 + 60

    # Roof & Chimney
    roof_points = [
        (hx, hy),
        (hx - 110, hy + 105),
        (hx - 75, hy + 105),
        (hx - 75, hy + 210),
        (hx + 75, hy + 210),
        (hx + 75, hy + 105),
        (hx + 110, hy + 105)
    ]
    # Subtle cyan glow behind house
    draw.polygon(roof_points, fill=(14, 165, 233, 70))
    # Crisp white outline
    draw.line(roof_points + [roof_points[0]], fill=(255, 255, 255, 255), width=14, joint="curve")

    # Chimney
    draw.line([(hx + 55, hy + 55), (hx + 55, hy + 20), (hx + 80, hy + 20), (hx + 80, hy + 80)], fill=(255, 255, 255, 255), width=10)

    # Smart home core dot inside house
    draw.ellipse([hx - 20, hy + 150, hx + 20, hy + 190], fill=(14, 165, 233, 255))
    draw.ellipse([hx - 8, hy + 162, hx + 8, hy + 178], fill=(255, 255, 255, 255))

    # 5. Typography
    # Try finding system fonts
    font_paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/opentype/cantarell/Cantarell-VF.otf",
        "/System/Library/Fonts/SFPro-Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf"
    ]
    font_bold_path = None
    for fp in font_paths:
        if os.path.exists(fp):
            font_bold_path = fp
            break

    try:
        if font_bold_path:
            f_title1 = ImageFont.truetype(font_bold_path, 110)
            f_title2 = ImageFont.truetype(font_bold_path, 90)
            f_badge  = ImageFont.truetype(font_bold_path, 40)
            f_sub    = ImageFont.truetype(font_bold_path, 34)
        else:
            f_title1 = f_title2 = f_badge = f_sub = ImageFont.load_default()
    except Exception:
        f_title1 = f_title2 = f_badge = f_sub = ImageFont.load_default()

    # Title Line 1: HOME ASSISTANT
    t1_text = "HOME ASSISTANT"
    t1_bbox = draw.textbbox((0, 0), t1_text, font=f_title1)
    t1_w = t1_bbox[2] - t1_bbox[0]
    t1_y = cy + 420
    draw.text((cx - t1_w // 2, t1_y), t1_text, font=f_title1, fill=(255, 255, 255, 255))

    # Title Line 2: RASPBERRY PI EDITION
    t2_text = "RASPBERRY PI EDITION"
    t2_bbox = draw.textbbox((0, 0), t2_text, font=f_title2)
    t2_w = t2_bbox[2] - t2_bbox[0]
    t2_y = t1_y + 130
    draw.text((cx - t2_w // 2, t2_y), t2_text, font=f_title2, fill=(244, 63, 94, 255)) # Vibrant Ruby

    # Badge Pill: SINGLE-PURPOSE HOME HUB • HARDWARE OPTIMIZED
    badge_text = "SINGLE-PURPOSE HOME HUB  •  HARDWARE OPTIMIZED"
    b_bbox = draw.textbbox((0, 0), badge_text, font=f_badge)
    bw = b_bbox[2] - b_bbox[0] + 80
    bh = 74
    bx = cx - bw // 2
    by = t2_y + 140

    draw.rounded_rectangle([bx, by, bx + bw, by + bh], radius=37, fill=(15, 23, 42, 230), outline=(51, 65, 85, 255), width=3)
    tb_bbox = draw.textbbox((0, 0), badge_text, font=f_badge)
    tb_w = tb_bbox[2] - tb_bbox[0]
    draw.text((cx - tb_w // 2, by + 14), badge_text, font=f_badge, fill=(148, 163, 184, 255))

    # Sleek bottom gradient accent line
    bar_w = 900
    bar_h = 10
    bar_x = cx - bar_w // 2
    bar_y = by + 160
    draw.rounded_rectangle([bar_x, bar_y, bar_x + bar_w, bar_y + bar_h], radius=5, fill=(14, 165, 233, 180))

    # Downsample from 3840x2160 to 1920x1080 with Lanczos for antialiased quality
    final_img = img.resize((1920, 1080), Image.Resampling.LANCZOS)
    final_img.save(output_path, "PNG", optimize=True)
    print(f"✓ Generated high-fidelity Raspberry Pi Edition splash at: {output_path}")

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "splash.png"
    create_pi_bootsplash(out)
