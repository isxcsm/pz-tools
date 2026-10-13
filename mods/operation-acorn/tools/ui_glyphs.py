#!/usr/bin/env python3
"""Small white glyphs for the mod's own windows (the research tab): a pip, a ring, a check, a cross, a reset arrow.

    python tools/ui_glyphs.py      writes media/textures/OA_UI/OA_UI_<Glyph>_<px>.png

The fonts have none of these (no ● ○ ✓ ✗ ↻ in the game's Korean fonts), and a texture shrunk much more than 2x
shimmers (the game loads media/textures without mipmaps), so each glyph is written at every pixel size a window may
draw it at, and a window draws the one of the size it wants at its own size (1:1, crisp). The window tints them.
Each is drawn at 8x and box-filtered down.
"""
import math
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures", "OA_UI"))
SS = 8

# glyph -> (smallest, largest) pixel size; every size between is written. The research tab's Lua (Upgrades/Window.lua,
# GLYPH_SIZES) holds the same ranges.
SIZES = {
    "Pip": (4, 48),
    "Ring": (4, 24),
    "Check": (8, 40),
    "Cross": (8, 40),
    "Reset": (10, 48),
}


def pip(d, s):
    d.ellipse([0, 0, s - 1, s - 1], fill=255)


def ring(d, s):
    t = max(SS, round(s / 6))
    d.ellipse([0, 0, s - 1, s - 1], outline=255, width=t)


def check(d, s):
    t = max(SS * 1.6, s * 0.16)
    d.line([(s * 0.10, s * 0.55), (s * 0.40, s * 0.84), (s * 0.92, s * 0.18)], fill=255, width=int(t), joint="curve")


def cross(d, s):
    t = int(max(SS * 1.6, s * 0.16))
    d.line([(s * 0.18, s * 0.18), (s * 0.82, s * 0.82)], fill=255, width=t)
    d.line([(s * 0.82, s * 0.18), (s * 0.18, s * 0.82)], fill=255, width=t)


def reset(d, s):
    t = int(max(SS * 1.6, s * 0.13))
    d.arc([s * 0.14, s * 0.14, s * 0.86, s * 0.86], start=-60, end=230, fill=255, width=t)
    a = math.radians(-60)
    ax, ay = s * 0.5 + s * 0.36 * math.cos(a), s * 0.5 + s * 0.36 * math.sin(a)
    d.polygon([(ax - s * 0.21, ay - s * 0.05), (ax + s * 0.15, ay - s * 0.17), (ax + s * 0.05, ay + s * 0.21)], fill=255)


DRAW = {"Pip": pip, "Ring": ring, "Check": check, "Cross": cross, "Reset": reset}


def glyph(name, px):
    big = px * SS
    mask = Image.new("L", (big, big), 0)
    DRAW[name](ImageDraw.Draw(mask), big)
    mask = mask.resize((px, px), Image.BOX)
    out = Image.new("RGBA", (px, px), (255, 255, 255, 0))
    out.putalpha(mask)
    return out


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    wanted = set()
    for name, (lo, hi) in SIZES.items():
        for px in range(lo, hi + 1):
            file = "OA_UI_%s_%d.png" % (name, px)
            glyph(name, px).save(os.path.join(OUT_DIR, file))
            wanted.add(file)
    for file in os.listdir(OUT_DIR):
        if file.startswith("OA_UI_") and file not in wanted:
            os.remove(os.path.join(OUT_DIR, file))
    print("wrote %d glyphs to %s" % (len(wanted), OUT_DIR))


if __name__ == "__main__":
    main()
