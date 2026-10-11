#!/usr/bin/env python3
"""Operation Acorn presence-sense marks (기척 감지), drawn around the character by Senses.lua.

Usage:
    python tools/sense_art.py             write media/textures/OA_Sense_*.png
    python tools/sense_art.py --preview   also write tools/sense_art_preview.png

The marks are white: the game tints them as it draws them and turns them to face the way the sound came from. They
copy Visual Sounds' pictures (its media/textures), which Senses.lua draws at its sizes; each is drawn at 8x and
downsampled with LANCZOS.
  OA_Sense_Arc_Near / _Mid / _Far
                            a zombie's arc (its Red .. Green): a thin sharp line bulging up (outward once turned),
                            fading to both ends, with a soft trail on its inner side only (toward the character)
  OA_Sense_Noise            a noise's thin arc (its lm)
  OA_Sense_Dots             a machine's dotted arc (its meca: a radio, TV or generator)
  OA_Sense_Line / _Wheel    a vehicle (its vehi): a flat line, and the wheel drawn on its middle at one size
  OA_Sense_Alarm_L / _M / _S
                            an alarm (its alert): sharp triangles standing apart along an arc, each pointing out from
                            its centre, the middle one solid and the others fading to the ends (no line under them).
                            Near: wide, many, fading gently; far: narrow, few, the middle one standing out
  OA_Sense_Thump            a zombie beating on something (its thumpBehavior): two pairs of brackets, ( ( ) )
  OA_Sense_Same             a sound on the character's square (its SameSquare): a soft disc with a thin ring
  OA_Sense_Up / _Down       a chevron, for a sound a floor above or below (its arrows)
  OA_Sense_Exclaim          an alarm near (경보 읽기), over the character's head: a red "!", a bar narrowing down and a
                            dot, with a dark rim and a soft red glow. Coloured, not white: it is drawn as it is
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 8
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
PREVIEW_PATH = os.path.join(HERE, "sense_art_preview.png")


def finish(big, w, h, middle=None):
    """The picture at its size. `middle`: where its line runs, above the picture's middle, of its height (Senses.lua
    puts the line at the cue's distance and the marks laid on it on the line: the arcs' trails hang below it)."""
    out = big.resize((w, h), Image.LANCZOS)
    if middle is not None:
        out.info["middle"] = middle
    return out


def glowing(shape, blur, core, glow):
    """A white image whose alpha is the shape plus a blurred copy of it (the glow)."""
    halo = shape.filter(ImageFilter.GaussianBlur(blur))
    alpha = ImageChops.add(shape.point(lambda v: int(v * core)), halo.point(lambda v: int(v * glow)))
    out = Image.new("RGBA", shape.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


# The zombies' arcs (near, mid, far), in pixels: the width, how far the ends sag below the crest, the line's thickness
# and how far its trail reaches in. Visual Sounds' Red, Orange and Green.
ARCS = {
    "OA_Sense_Arc_Near": dict(w=84, sag=8, line=2.6, trail=9),
    "OA_Sense_Arc_Mid": dict(w=104, sag=10, line=2.6, trail=9),
    "OA_Sense_Arc_Far": dict(w=124, sag=12, line=2.6, trail=9),
}
def arc(w, sag, line, trail):
    """A thin line on an arc across the width, its middle at the top, fading out to both ends, and under it (the arc's
    inner side) a trail fading from a third of the line's strength to nothing over `trail` pixels. The line, its trail
    and a thin glow stay inside every edge: one cut by the picture's edge draws a straight line along it."""
    blur = 0.5
    m = 3 * blur + 1
    h = int(math.ceil(2 * m + line + sag + trail))
    h += h % 2
    W, H = w * S, h * S
    top = (m + line / 2) * S
    half = (w / 2 - m - line / 2) * S
    sg = sag * S
    r = (half * half + sg * sg) / (2 * sg)
    cx, cy = W / 2, top + r
    span = math.asin(min(1.0, half / r))
    core = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(core)
    steps = 500
    # the trail first, from its far end in: each step a fainter copy of the line a little further in
    k = trail * S
    while k > 0:
        rr = r - k
        level = 0.33 * (1 - k / (trail * S)) ** 1.4
        for i in range(0, steps + 1, 2):
            a = -span + 2 * span * i / steps
            fade = 1 - (abs(a) / span) ** 2.2
            x, y = cx + rr * math.sin(a), cy - rr * math.cos(a)
            rad = S * 0.6
            v = int(255 * level * fade)
            if v > 0:
                d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=v)
        k -= S * 0.5
    line_im = Image.new("L", (W, H), 0)
    dl = ImageDraw.Draw(line_im)
    for i in range(steps + 1):
        a = -span + 2 * span * i / steps
        fade = 1 - (abs(a) / span) ** 2.2
        x, y = cx + r * math.sin(a), cy - r * math.cos(a)
        rad = line * S / 2 * (0.6 + 0.4 * fade)
        dl.ellipse((x - rad, y - rad, x + rad, y + rad), fill=int(255 * fade))
    core = ImageChops.lighter(core, line_im)
    return finish(glowing(core, blur * S, 1.0, 0.25), w, h, (H / 2 - top) / H)


def thump(size=32):
    """Two pairs of brackets round the middle, ( ( ) ), the outer ones bolder: a blow, as Visual Sounds' thumpBehavior."""
    W = size * S
    im = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(im)
    for r, width, level in ((0.40, 0.085, 255), (0.25, 0.065, 190)):
        R = W * r
        box = (W / 2 - R, W / 2 - R, W / 2 + R, W / 2 + R)
        for start in (130, -50):
            d.arc(box, start, start + 100, fill=level, width=int(W * width))
    return finish(glowing(im, S * 0.5, 1.0, 0.3), size, size)


def same(size=46):
    """A soft disc with a thin ring in it: a sound on the character's own square, as Visual Sounds' SameSquare."""
    W = size * S
    disc = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(disc)
    R = W * 0.3
    d.ellipse((W / 2 - R, W / 2 - R, W / 2 + R, W / 2 + R), fill=170)
    disc = disc.filter(ImageFilter.GaussianBlur(W * 0.08))
    ring = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(ring)
    R = W * 0.24
    d.ellipse((W / 2 - R, W / 2 - R, W / 2 + R, W / 2 + R), outline=255, width=int(S * 1.2))
    out = Image.new("RGBA", (W, W), (255, 255, 255, 0))
    out.putalpha(ImageChops.lighter(disc, ring))
    return finish(out, size, size)


def wheel(size=18):
    """A ring: a vehicle's wheel, as Visual Sounds' vehi draws it on its line."""
    W = size * S
    im = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(im)
    R = W * 0.4
    d.ellipse((W / 2 - R, W / 2 - R, W / 2 + R, W / 2 + R), outline=255, width=int(S * 1.6))
    return finish(glowing(im, S * 0.5, 1.0, 0.3), size, size)


def chevron(size, up, k=2):
    W = size * S
    im = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(im)
    top, bottom = W * 0.3, W * 0.7
    pts = [(W * 0.2, bottom), (W * 0.5, top), (W * 0.8, bottom)] if up else [(W * 0.2, top), (W * 0.5, bottom), (W * 0.8, top)]
    d.line(pts, fill=255, width=int(S * k * 2.4), joint="curve")
    return finish(glowing(im, S * k, 1.0, 0.5), size, size)


def noise_arc(style, w, h, sag):
    """A thin line for a noise heard, its kind in its pattern as Visual Sounds draws them: "plain" (an arc: anything),
    "dots" (a dotted arc: a machine) or "flat" (a straight line under a vehicle's wheel). `sag` is how far its ends are
    below its middle (pixels; 0 for the flat line)."""
    W, H = w * S, h * S
    m = 2.5 * S
    core = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(core)
    top = (H - sag * S) / 2
    half = W / 2 - m
    sg = max(0.01, sag * S)
    r = (half * half + sg * sg) / (2 * sg)
    cx, cy = W / 2, top + r
    span = math.asin(min(1.0, half / r))

    def at(t):
        a = span * t
        return cx + r * math.sin(a), cy - r * math.cos(a)

    if style == "dots":
        n = 17
        for i in range(n):
            t = -1 + 2 * i / (n - 1)
            x, y = at(t)
            fade = 1 - abs(t) ** 1.6
            rad = S * 1.9
            d.rectangle((x - rad, y - rad, x + rad, y + rad), fill=int(255 * fade))
        blur = S * 0.6
    else:
        steps = 400
        for i in range(steps + 1):
            t = -1 + 2 * i / steps
            x, y = at(t)
            fade = 1 - abs(t) ** 2.2
            rad = S * 0.9 * (0.6 + 0.4 * fade)
            d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=int(255 * fade))
        blur = S * 0.5
    return finish(glowing(core, blur, 1.0, 0.35), w, h, (H / 2 - top) / H)


# The alarm pictures (near, mid, far), in pixels of the picture: its width, the arc's radius, how many triangles, how
# far apart along the arc (a third more than a base: they stand apart), a triangle's base and height, and how fast they
# fade to the ends (a higher power keeps them brighter longer). Visual Sounds' alert2, alert5 and alert7, a little
# bolder.
ALARMS = {
    "OA_Sense_Alarm_L": dict(w=128, radius=150, n=9, pitch=16, base=12, tall=12, fade=0.8),
    "OA_Sense_Alarm_M": dict(w=112, radius=140, n=7, pitch=16, base=12, tall=12, fade=1.0),
    "OA_Sense_Alarm_S": dict(w=88, radius=130, n=5, pitch=16, base=12, tall=12, fade=1.6),
}


def alarm(w, radius, n, pitch, base, tall, fade):
    """Triangles standing apart on an arc, each pointing away from the arc's centre, the middle one solid and the
    others fading to the ends: (1 - |t|) ** fade of the way out, never below a tenth. The arc is fitted across the
    width with room round it for a thin glow; the picture is as tall as the arc needs."""
    tris = []
    spread = pitch * (n - 1) / 2 / radius
    for i in range(n):
        t = -1 + 2 * i / (n - 1)
        a = spread * t
        nx, ny = math.sin(a), -math.cos(a)
        tx, ty = math.cos(a), math.sin(a)
        x, y = radius * nx, radius * ny
        pts = [(x - tx * base / 2, y - ty * base / 2), (x + tx * base / 2, y + ty * base / 2),
               (x + nx * tall, y + ny * tall)]
        tris.append((pts, max(0.1, (1 - abs(t)) ** fade)))
    blur = 0.6
    m = 3 * blur + 1
    xs = [q[0] for pts, _ in tris for q in pts]
    ys = [q[1] for pts, _ in tris for q in pts]
    scale = (w - 2 * m) / (max(xs) - min(xs))
    h = int(math.ceil((max(ys) - min(ys)) * scale + 2 * m))
    h += h % 2
    W, H = w * S, h * S
    dx = W / 2 - S * scale * (max(xs) + min(xs)) / 2
    dy = H / 2 - S * scale * (max(ys) + min(ys)) / 2
    core = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(core)
    for pts, shade in tris:
        d.polygon([(dx + S * scale * x, dy + S * scale * y) for x, y in pts], fill=int(255 * shade))
    # the line is the middle triangle's middle
    middle = dy + S * scale * (-radius - tall / 2)
    return finish(glowing(core, blur * S, 1.0, 0.3), w, h, (H / 2 - middle) / H)


def exclaim(w=20, h=44):
    """A red "!" with a dark rim and a soft glow: the bar narrows down to round ends, the dot under it."""
    W, H = w * S, h * S
    shape = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(shape)
    cx = W / 2
    top, bottom, wide, narrow = H * 0.14, H * 0.66, W * 0.18, W * 0.10
    d.polygon([(cx - wide, top), (cx + wide, top), (cx + narrow, bottom), (cx - narrow, bottom)], fill=255)
    d.ellipse((cx - wide, top - wide, cx + wide, top + wide), fill=255)
    d.ellipse((cx - narrow, bottom - narrow, cx + narrow, bottom + narrow), fill=255)
    r = W * 0.13
    dot = H * 0.83
    d.ellipse((cx - r, dot - r, cx + r, dot + r), fill=255)
    rim = shape.filter(ImageFilter.MaxFilter(int(S * 2.2) | 1))
    glow = rim.filter(ImageFilter.GaussianBlur(S * 1.6))
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", (W, H), (255, 40, 25)).split(), glow.point(lambda v: int(v * 0.45)))))
    out.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", (W, H), (40, 6, 4)).split(), rim)))
    out.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", (W, H), (240, 34, 24)).split(), shape)))
    return finish(out, w, h)


def build():
    return {
        **{name: arc(**spec) for name, spec in ARCS.items()},
        "OA_Sense_Dots": noise_arc("dots", 112, 22, 11),
        "OA_Sense_Noise": noise_arc("plain", 112, 16, 9),
        "OA_Sense_Line": noise_arc("flat", 80, 8, 0),
        "OA_Sense_Wheel": wheel(),
        **{name: alarm(**spec) for name, spec in ALARMS.items()},
        "OA_Sense_Thump": thump(),
        "OA_Sense_Same": same(),
        "OA_Sense_Up": chevron(28, True),
        "OA_Sense_Down": chevron(28, False),
        "OA_Sense_Exclaim": exclaim(),
    }


def main():
    images = build()
    for name, im in images.items():
        im.save(os.path.join(OUT_DIR, name + ".png"))
    if "--preview" in sys.argv:
        tints = {"OA_Sense_Arc_Near": (255, 64, 51), "OA_Sense_Arc_Mid": (255, 217, 51),
                 "OA_Sense_Arc_Far": (77, 242, 102), "OA_Sense_Alarm_L": (242, 20, 15), "OA_Sense_Alarm_M": (242, 20, 15),
                 "OA_Sense_Alarm_S": (242, 20, 15), "OA_Sense_Dots": (0, 186, 254),
                 "OA_Sense_Thump": (255, 106, 0), "OA_Sense_Same": (255, 0, 0)}
        sheet = Image.new("RGBA", (sum(im.width + 10 for im in images.values()) + 8, 70), (34, 38, 34, 255))
        x = 8
        for name, im in images.items():
            tint = tints.get(name, (235, 235, 225))
            col = Image.new("RGBA", im.size, tint + (255,))
            col.putalpha(im.getchannel("A"))
            if name == "OA_Sense_Exclaim":
                col = im
            sheet.alpha_composite(col, (x, 12))
            x += im.width + 10
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        sheet.save(PREVIEW_PATH)
    print("wrote", len(images), "marks to", OUT_DIR)
    print("line above the middle, of the height (Senses.lua LINE):")
    for name, im in images.items():
        if "middle" in im.info:
            print("    %s = %.3f," % (name, im.info["middle"]))


if __name__ == "__main__":
    main()
