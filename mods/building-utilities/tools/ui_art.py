"""The breaker box window's small drawings, white on clear (the window tints them):
  media/textures/BU_FlowArrow.png  the arrow from a unit's inlet pipe chip to its outlet's, the way the water goes
Drawn eight times as large and brought down, for smooth edges.
  python -X utf8 tools/ui_art.py
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "BuildingUtilities", "42", "media", "textures")
UP = 8


def stroke(draw, points, width):
    """A polyline with round ends and joints."""
    draw.line(points, fill=255, width=width, joint="curve")
    r = width / 2
    for x, y in points:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=255)


def flow_arrow(w=24, h=16, line=2.0):
    """A shaft and an open head, centred, `line` pixels thick at the final size."""
    big = Image.new("L", (w * UP, h * UP), 0)
    draw = ImageDraw.Draw(big)
    pad = line * UP
    mid = h * UP / 2
    tip = w * UP - pad
    head = (h * UP / 2) - pad
    width = int(line * UP)
    stroke(draw, [(pad, mid), (tip, mid)], width)
    stroke(draw, [(tip - head, mid - head), (tip, mid), (tip - head, mid + head)], width)
    alpha = big.resize((w, h), Image.LANCZOS)
    image = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    image.putalpha(alpha)
    return image


if __name__ == "__main__":
    path = os.path.join(OUT, "BU_FlowArrow.png")
    flow_arrow().save(path)
    print(path)
