#!/usr/bin/env python3
"""Operation Acorn presence-sense marks (기척 감지), drawn around the character by Senses.lua.

Usage:
    python tools/sense_art.py             write media/textures/OA_Sense_*.png
    python tools/sense_art.py --preview   also write tools/sense_art_preview.png

The marks are white: the game tints them as it draws them (DrawTextureAngle with a colour) and turns them to face
the way the zombies are. Each is drawn at 8x and downsampled with LANCZOS.
  OA_Sense_Arc_L / _M / _S  a soft glowing arc, bulging up (outward once turned): near / mid / far
  OA_Sense_Noise / _Car / _Dots / _Alarm
                            thin arcs for a noise heard (rank 2), its kind in the pattern as Visual Sounds draws
                            them: plain (anything), a wheel (a vehicle), dots (a radio, TV or generator), spikes
                            (an alarm). White for all but alarms (deep red): the zombies' arcs keep the colours
  OA_Sense_Bang             three short strokes fanning out, laid on the outer side of the arc of zombies beating on
                            something (rank 2), in the arc's colour
  OA_Sense_Up / _Down       a chevron, for zombies a floor above or below (rank 2)

Senses.lua draws them stretched to a size in tiles (they follow the zoom), so they are made at twice the size they
were first drawn at, near what a default zoom shows.
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 8
# The arcs' glow (a blur of this many strokes) and the room left round the stroke for it (half a stroke and three
# blurs: nothing of the glow reaches the picture's edge).
ARC_GLOW = 0.6
ARC_MARGIN = 0.5 + 3 * ARC_GLOW
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
PREVIEW_PATH = os.path.join(HERE, "sense_art_preview.png")


def finish(big, w, h):
    return big.resize((w, h), Image.LANCZOS)


def glowing(shape, blur, core, glow):
    """A white image whose alpha is the shape plus a blurred copy of it (the glow)."""
    halo = shape.filter(ImageFilter.GaussianBlur(blur))
    alpha = ImageChops.add(shape.point(lambda v: int(v * core)), halo.point(lambda v: int(v * glow)))
    out = Image.new("RGBA", shape.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def arc(w, h, thick, dotted=False):
    """An arc across the width, its middle at the top, fading out to both ends, with a soft glow. The stroke and its
    glow stay MARGIN strokes inside every edge: one cut by the picture's edge draws a straight line along it."""
    W, H = w * S, h * S
    core = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(core)
    m = thick * S * ARC_MARGIN
    # a circle through the top middle and the two lower ends, all a margin inside the picture
    sag = H - 2 * m
    half = W / 2 - m
    r = (half * half + sag * sag) / (2 * sag)
    cx, cy = W / 2, m + r
    span = math.asin(min(1.0, half / r))
    steps = 400
    for i in range(steps + 1):
        a = -span + 2 * span * i / steps
        t = abs(a) / span
        if dotted and (i // 22) % 2 == 1:
            continue
        fade = (1 - t ** 2.2)
        x, y = cx + r * math.sin(a), cy - r * math.cos(a)
        rad = thick * S / 2 * (0.55 + 0.45 * fade)
        d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=int(255 * fade))
    return finish(glowing(core, thick * S * ARC_GLOW, 0.95, 0.55), w, h)


def bang(w, h, k=2):
    """Three short strokes fanning out from a point below them, the middle one the longest: a blow. The strokes are
    fitted (one scale, moved) inside the picture with room round them for their glow: nothing reaches the edge."""
    W, H = w * S, h * S
    P = S * k
    width, blur = P * 2.2, P * 0.6
    m = width / 2 + 3 * blur
    strokes = []
    for deg, inner, outer in ((-38, 0.62, 1.05), (0, 0.55, 1.18), (38, 0.62, 1.05)):
        a = math.radians(deg)
        nx, ny = math.sin(a), -math.cos(a)
        strokes.append(((nx * inner, ny * inner), (nx * outer, ny * outer)))
    xs = [p[0] for s_ in strokes for p in s_]
    ys = [p[1] for s_ in strokes for p in s_]
    scale = min((W - 2 * m) / (max(xs) - min(xs)), (H - 2 * m) / (max(ys) - min(ys)))
    dx = W / 2 - scale * (max(xs) + min(xs)) / 2
    dy = H / 2 - scale * (max(ys) + min(ys)) / 2
    im = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(im)
    for (ax, ay), (bx, by) in strokes:
        x0, y0, x1, y1 = dx + scale * ax, dy + scale * ay, dx + scale * bx, dy + scale * by
        d.line((x0, y0, x1, y1), fill=255, width=int(width))
        for x, y in ((x0, y0), (x1, y1)):
            d.ellipse((x - width / 2, y - width / 2, x + width / 2, y + width / 2), fill=255)
    return finish(glowing(im, blur, 1.0, 0.55), w, h)


def chevron(size, up, k=2):
    W = size * S
    im = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(im)
    top, bottom = W * 0.3, W * 0.7
    pts = [(W * 0.2, bottom), (W * 0.5, top), (W * 0.8, bottom)] if up else [(W * 0.2, top), (W * 0.5, bottom), (W * 0.8, top)]
    d.line(pts, fill=255, width=int(S * k * 2.4), joint="curve")
    return finish(glowing(im, S * k, 1.0, 0.5), size, size)


def noise_arc(style, w=96, h=36, k=2):
    """A thin arc for a noise heard, its kind in its pattern as Visual Sounds draws them: "plain" (anything), "car" (a
    wheel on its middle), "dots" (a machine: radio, TV, generator), "teeth" (an alarm: little spikes outward)."""
    W, H = w * S, h * S
    P = S * k
    core = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(core)
    top = H * 0.42 if style in ("car", "teeth") else H * 0.2
    sag = H - top - P * 2
    half = W / 2 - P * 2
    r = (half * half + sag * sag) / (2 * sag)
    cx, cy = W / 2, top + r
    span = math.asin(min(1.0, half / r))

    def at(t):
        a = span * t
        return cx + r * math.sin(a), cy - r * math.cos(a), a

    if style == "dots":
        n = 15
        for i in range(n):
            t = -1 + 2 * i / (n - 1)
            x, y, _ = at(t)
            fade = 1 - abs(t) ** 2.2
            rad = P * 1.25
            d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=int(255 * fade))
    elif style == "teeth":
        n = 9
        for i in range(n):
            t = -1 + 2 * i / (n - 1)
            x, y, a = at(t * 0.92)
            fade = 1 - abs(t) ** 2.0
            # a small triangle standing on the arc, pointing away from the centre
            nx, ny = math.sin(a), -math.cos(a)
            tx, ty = math.cos(a), math.sin(a)
            base, tall = P * 2.2, P * 4.2 * (0.6 + 0.4 * fade)
            pts = [(x - tx * base, y - ty * base), (x + tx * base, y + ty * base), (x + nx * tall, y + ny * tall)]
            d.polygon(pts, fill=int(255 * fade))
    else:
        steps = 400
        for i in range(steps + 1):
            t = -1 + 2 * i / steps
            x, y, _ = at(t)
            fade = 1 - abs(t) ** 2.2
            rad = P * 0.75 * (0.6 + 0.4 * fade)
            d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=int(255 * fade))
        if style == "car":
            x, y, _ = at(0)
            rad = P * 3.6
            d.ellipse((x - rad, y - rad, x + rad, y + rad), outline=255, width=int(P * 1.2))
    return finish(glowing(core, P * 0.8, 1.0, 0.4), w, h)


def build():
    return {
        "OA_Sense_Arc_L": arc(112, 32, 3.6),
        "OA_Sense_Arc_M": arc(84, 26, 3.0),
        "OA_Sense_Arc_S": arc(60, 20, 2.4),
        "OA_Sense_Dots": noise_arc("dots"),
        "OA_Sense_Car": noise_arc("car"),
        "OA_Sense_Alarm": noise_arc("teeth"),
        "OA_Sense_Noise": noise_arc("plain"),
        "OA_Sense_Bang": bang(48, 28),
        "OA_Sense_Up": chevron(28, True),
        "OA_Sense_Down": chevron(28, False),
    }


def main():
    images = build()
    for name, im in images.items():
        im.save(os.path.join(OUT_DIR, name + ".png"))
    if "--preview" in sys.argv:
        tints = [(255, 90, 60), (255, 180, 70), (200, 225, 255), (235, 235, 225)]
        sheet = Image.new("RGBA", (980, 70), (34, 38, 34, 255))
        x = 8
        for (name, im), tint in zip(images.items(), tints * 3):
            col = Image.new("RGBA", im.size, tint + (255,))
            col.putalpha(im.getchannel("A"))
            sheet.alpha_composite(col, (x, 12))
            x += im.width + 10
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        sheet.save(PREVIEW_PATH)
    print("wrote", len(images), "marks to", OUT_DIR)


if __name__ == "__main__":
    main()
