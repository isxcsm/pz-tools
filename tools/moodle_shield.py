#!/usr/bin/env python3
"""Operation Acorn's bite shield moodle (물림 내성 회복 중): shown while the shield of 상처 감염 저항 rank 2 rests after
saving a bite, one picture for each of its four levels. Drawn as the game's status moodles are (Status_HeavyLoad,
Status_InjuredMinor): one plain object with a dark outline and soft shading, no face.

The object: a heater shield with a bite taken out of its upper right corner (a scalloped notch, the teeth's marks),
its field filling from the bottom with a pale green charge as the rest runs out: level 4 (most of the rest ahead,
the moodle's background reddest) nearly empty, level 1 (soon ready) nearly full.

Usage:
    python tools/moodle_shield.py             write media/textures/OA_Moodle_BiteShield_<level>_<size>.png
    python tools/moodle_shield.py --preview   also write tools/moodle_shield_preview.png (beside the game's own)

Needs the game installed (PZ_GAME, default the Steam folder) for the preview's backgrounds and neighbours only.
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZES = (32, 48, 64, 80, 96, 128)
LEVELS = (1, 2, 3, 4)
GAME = os.environ.get("PZ_GAME", r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid")
MOODLES = os.path.join(GAME, "media", "ui", "Moodles")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
PREVIEW_PATH = os.path.join(HERE, "moodle_shield_preview.png")

K = 8                                   # supersampling
OUTLINE = (30, 33, 37)
RIM_LIGHT, RIM_DARK = (214, 221, 227), (122, 133, 142)
FIELD_EMPTY_TOP, FIELD_EMPTY_BOTTOM = (70, 76, 82), (48, 53, 58)
CHARGE_TOP, CHARGE_BOTTOM = (150, 236, 184), (54, 160, 104)
SURFACE = (214, 255, 228)
# How full the field is at each level (of its height).
FILL = {1: 0.82, 2: 0.58, 3: 0.34, 4: 0.10}


def shield_points(s):
    """The shield's outline in picture pixels (s: 128-picture pixels to these): a straight top with rounded corners,
    straight sides to a little past the middle, then curving in to the point."""
    pts = []
    left, right, top, side_end, tip = 27, 101, 20, 62, 113
    r = 7
    for a in range(180, 271, 10):               # top left corner
        pts.append((left + r + r * math.cos(math.radians(a)), top + r + r * math.sin(math.radians(a))))
    for a in range(270, 361, 10):               # top right corner
        pts.append((right - r + r * math.cos(math.radians(a)), top + r + r * math.sin(math.radians(a))))
    # right side down, then the curve to the tip (a quadratic from the side's end through a control point)
    pts.append((right, side_end))
    for i in range(1, 17):
        t = i / 16
        cx, cy = right, 96
        x = (1 - t) ** 2 * right + 2 * (1 - t) * t * cx + t * t * 64
        y = (1 - t) ** 2 * side_end + 2 * (1 - t) * t * cy + t * t * tip
        pts.append((x, y))
    for i in range(15, -1, -1):
        t = i / 16
        cx, cy = left, 96
        x = (1 - t) ** 2 * left + 2 * (1 - t) * t * cx + t * t * 64
        y = (1 - t) ** 2 * side_end + 2 * (1 - t) * t * cy + t * t * tip
        pts.append((x, y))
    return [(x * s, y * s) for x, y in pts]


def bite_mask(size, s, boost=1.0):
    """The bite: a disk at the upper right corner and the teeth's scallops along its edge (bigger with `boost`, so
    that the small pictures still show it)."""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    cx, cy, r = 103, 18, 24 * boost
    d.ellipse(((cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s), fill=255)
    for a in range(100, 261, 32):                # teeth along the inner edge
        tx, ty = cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))
        t = 6.4 * boost
        d.ellipse(((tx - t) * s, (ty - t) * s, (tx + t) * s, (ty + t) * s), fill=255)
    return m


# How much the bite grows in each picture: at 32 and 48 pixels it shrinks to a nick.
BOOST = {32: 0.92, 48: 1.0}


def vertical(size, box, top, bottom):
    """A vertical gradient filling `box` (x0, y0, x1, y1) of an image of `size`."""
    im = Image.new("RGBA", size, (0, 0, 0, 0))
    x0, y0, x1, y1 = [int(v) for v in box]
    d = ImageDraw.Draw(im)
    for y in range(max(0, y0), min(size[1], y1 + 1)):
        t = (y - y0) / max(1, y1 - y0)
        d.line([(x0, y), (x1, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return im


def shrink(mask, px):
    """The mask eroded by about px pixels: a box blur keeps full only what has the whole box inside (fast at any px)."""
    if px < 1:
        return mask
    return mask.filter(ImageFilter.BoxBlur(px)).point(lambda v: 255 if v >= 250 else 0)


def draw(level, size):
    s = size / 128 * K
    full = (size * K, size * K)
    shape = Image.new("L", full, 0)
    ImageDraw.Draw(shape).polygon(shield_points(s), fill=255)
    shape = ImageChops.subtract(shape, bite_mask(full, s, BOOST.get(size, 1.0)))
    # the outline is thicker in the small pictures, so that it still reads
    outline_px = max(3.5, 2.2 * 128 / size) * s
    body = shrink(shape, outline_px)
    field = shrink(body, 5.5 * s)
    im = Image.new("RGBA", full, (0, 0, 0, 0))
    im.paste(Image.new("RGBA", full, OUTLINE + (255,)), (0, 0), shape)
    # the rim: steel, lit from the upper left
    rim = vertical(full, (0, 20 * s, full[0], 113 * s), RIM_LIGHT, RIM_DARK)
    im.paste(rim, (0, 0), body)
    # a dark line between the rim and the field
    groove = shrink(body, 4.0 * s)
    im.paste(Image.new("RGBA", full, OUTLINE + (255,)), (0, 0), groove)
    # the field: dark where empty, the charge below its surface
    im.paste(vertical(full, (0, 26 * s, full[0], 108 * s), FIELD_EMPTY_TOP, FIELD_EMPTY_BOTTOM), (0, 0), field)
    fy = field.getbbox()
    if fy:
        f_top, f_bottom = fy[1], fy[3]
        surface = f_bottom - (f_bottom - f_top) * FILL[level]
        charge = Image.new("L", full, 0)
        ImageDraw.Draw(charge).rectangle((0, surface, full[0], full[1]), fill=255)
        charge = ImageChops.multiply(charge, field)
        im.paste(vertical(full, (0, surface, full[0], f_bottom), CHARGE_TOP, CHARGE_BOTTOM), (0, 0), charge)
        # the charge's surface: a bright line
        line = Image.new("L", full, 0)
        ImageDraw.Draw(line).rectangle((0, surface, full[0], surface + 2.2 * s), fill=255)
        im.paste(Image.new("RGBA", full, SURFACE + (255,)), (0, 0), ImageChops.multiply(line, field))
    # gloss: a soft light band down the left of the field
    gloss = Image.new("L", full, 0)
    ImageDraw.Draw(gloss).polygon([(36 * s, 28 * s), (48 * s, 28 * s), (40 * s, 92 * s), (34 * s, 80 * s)], fill=70)
    gloss = ImageChops.multiply(gloss.filter(ImageFilter.GaussianBlur(3 * s)), field)
    im.paste(Image.new("RGBA", full, (255, 255, 255, 255)), (0, 0), gloss)
    return im.resize((size, size), Image.LANCZOS)


def build():
    return {(level, size): draw(level, size) for level in LEVELS for size in SIZES}


def main():
    images = build()
    for (level, size), im in images.items():
        im.save(os.path.join(OUT_DIR, "OA_Moodle_BiteShield_%d_%d.png" % (level, size)))
    if "--preview" in sys.argv:
        folder = os.path.join(MOODLES, "64")
        bg = Image.open(os.path.join(folder, "_Moodles_BGsolid.png")).convert("RGBA")

        def back(level):
            # grey to the game's default bad colour (red) by level over 4, as the moodle column tints it
            t = level / 4
            r, g, b, a = bg.split()
            tint = (0.42 + 0.45 * t, 0.42 - 0.22 * t, 0.42 - 0.22 * t)
            return Image.merge("RGBA", (r.point(lambda v: int(v * tint[0])), g.point(lambda v: int(v * tint[1])),
                                        b.point(lambda v: int(v * tint[2])), a))
        pics = [(images[(lv, 64)], back(lv)) for lv in LEVELS]
        pics += [(Image.open(os.path.join(folder, n + ".png")).convert("RGBA"), back(2))
                 for n in ("Status_HeavyLoad", "Status_InjuredMinor", "Status_Bleeding")]
        sheet = Image.new("RGBA", (74 * len(pics) + 10, 84), (60, 60, 60, 255))
        for i, (pic, b) in enumerate(pics):
            sheet.alpha_composite(b, (10 + i * 74, 10))
            sheet.alpha_composite(pic, (10 + i * 74, 10))
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        big = Image.new("RGBA", (sheet.width, sheet.height + 280), (60, 60, 60, 255))
        big.alpha_composite(sheet, (0, 0))
        big.alpha_composite(images[(2, 128)].resize((256, 256), Image.NEAREST), (10, sheet.height + 10))
        x = 290
        for lv in LEVELS:
            big.alpha_composite(images[(lv, 32)].resize((128, 128), Image.NEAREST), (x, sheet.height + 10))
            big.alpha_composite(images[(lv, 48)].resize((96, 96), Image.NEAREST), (x + 16, sheet.height + 150))
            x += 140
        big.save(PREVIEW_PATH)
    print("wrote", len(images), "pictures to", OUT_DIR)


if __name__ == "__main__":
    main()
