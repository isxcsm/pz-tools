#!/usr/bin/env python3
"""Operation Acorn's adaptation moodle: 적응 중 (a dose of an upgrade serum is being adapted to; the research point comes when
it is over). One picture for every moodle size. Drawn as the game's status moodles are (Status_HeavyLoad,
Status_InjuredMinor): one plain object, a dark outline, soft shading, no face.

  Adapting: a syringe with an amber serum in its barrel, with a clock badge at its lower right.

Usage:
    python tools/moodle_adapt.py             write media/textures/OA_Moodle_Adapting_<size>.png
    python tools/moodle_adapt.py --preview   also write tools/moodle_adapt_preview.png (beside the game's own)

Needs the game installed (PZ_GAME, default the Steam folder) for the preview's backgrounds and neighbours only.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZES = (32, 48, 64, 80, 96, 128)
GAME = os.environ.get("PZ_GAME", r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid")
MOODLES = os.path.join(GAME, "media", "ui", "Moodles")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
PREVIEW_PATH = os.path.join(HERE, "moodle_adapt_preview.png")

K = 8                                   # supersampling
OUTLINE = (30, 33, 37)
GLASS_TOP, GLASS_BOTTOM = (240, 246, 249), (186, 202, 212)
AMBER_TOP, AMBER_BOTTOM = (246, 190, 92), (200, 120, 36)
METAL_TOP, METAL_BOTTOM = (196, 202, 208), (120, 128, 136)
PLUNGER = (78, 86, 96)
BADGE = (58, 64, 72)
BADGE_RIM = (232, 236, 240)


def vertical(size, box, top, bottom):
    """A vertical gradient filling `box` (x0, y0, x1, y1) of an image of `size`."""
    im = Image.new("RGBA", size, (0, 0, 0, 0))
    x0, y0, x1, y1 = [int(v) for v in box]
    d = ImageDraw.Draw(im)
    for y in range(max(0, y0), min(size[1], y1 + 1)):
        t = (y - y0) / max(1, y1 - y0)
        d.line([(x0, y), (x1, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return im


def outlined(im, px):
    """The picture with a dark outline `px` pixels wide around everything that is drawn."""
    alpha = im.getchannel("A")
    grown = alpha.filter(ImageFilter.MaxFilter(int(px) * 2 + 1))
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(Image.new("RGBA", im.size, OUTLINE + (255,)), (0, 0), grown)
    out.alpha_composite(im)
    return out


def clock(full, s, center):
    """The round badge at the lower right: a clock face with its hands at a quarter past."""
    im = Image.new("RGBA", full, (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx, cy, r = center[0] * s, center[1] * s, 25 * s
    d.ellipse((cx - r - 3 * s, cy - r - 3 * s, cx + r + 3 * s, cy + r + 3 * s), fill=OUTLINE + (255,))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=BADGE_RIM + (255,))
    r2 = r - 4 * s
    d.ellipse((cx - r2, cy - r2, cx + r2, cy + r2), fill=BADGE + (255,))
    w = 4 * s
    d.line([(cx, cy), (cx, cy - 15 * s)], fill=BADGE_RIM + (255,), width=int(w))          # the long hand, up
    d.line([(cx, cy), (cx + 10 * s, cy)], fill=BADGE_RIM + (255,), width=int(w))          # the short hand, right
    d.ellipse((cx - 3 * s, cy - 3 * s, cx + 3 * s, cy + 3 * s), fill=BADGE_RIM + (255,))
    return im


def syringe_strip(s):
    """A syringe lying along the x axis, needle to the right, on its own canvas; returns the image."""
    length, height = int(104 * s), int(40 * s)
    im = Image.new("RGBA", (length, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    mid = height / 2
    # the thumb rest and the rod, at the left
    d.rounded_rectangle((0, mid - 17 * s, 6 * s, mid + 17 * s), radius=2 * s, fill=PLUNGER + (255,))
    d.rectangle((6 * s, mid - 3 * s, 30 * s, mid + 3 * s), fill=PLUNGER + (255,))
    # the barrel: glass, with the serum in the part nearest the needle
    bl, bt, br, bb = 26 * s, mid - 13 * s, 76 * s, mid + 13 * s
    barrel = vertical((length, height), (0, bt, length, bb), GLASS_TOP, GLASS_BOTTOM)
    mask = Image.new("L", (length, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((bl, bt, br, bb), radius=3 * s, fill=255)
    im.paste(barrel, (0, 0), mask)
    liquid = vertical((length, height), (0, bt, length, bb), AMBER_TOP, AMBER_BOTTOM)
    lmask = Image.new("L", (length, height), 0)
    ImageDraw.Draw(lmask).rectangle((bl + 20 * s, bt + 4 * s, br - 3 * s, bb - 4 * s), fill=255)
    im.paste(liquid, (0, 0), lmask)
    # the flange at the barrel's open end, the tip and the needle
    d.rounded_rectangle((bl - 3 * s, mid - 18 * s, bl + 3 * s, mid + 18 * s), radius=2 * s, fill=GLASS_BOTTOM + (255,))
    d.polygon([(br, mid - 6 * s), (br + 10 * s, mid - 2.5 * s), (br + 10 * s, mid + 2.5 * s), (br, mid + 6 * s)],
              fill=METAL_BOTTOM + (255,))
    d.rectangle((br + 10 * s, mid - 1.5 * s, length - 1, mid + 1.5 * s), fill=METAL_TOP + (255,))
    # the graduation marks and a light line along the glass
    for i in range(5):
        x = bl + (10 + i * 8) * s
        d.line([(x, bt + 2 * s), (x, bt + 7 * s)], fill=OUTLINE + (170,), width=max(1, int(1.2 * s)))
    gloss = Image.new("L", (length, height), 0)
    ImageDraw.Draw(gloss).rounded_rectangle((bl + 3 * s, bt + 2.5 * s, br - 4 * s, bt + 5.5 * s), radius=1.5 * s, fill=140)
    im.paste(Image.new("RGBA", (length, height), (255, 255, 255, 255)), (0, 0), gloss)
    return im


def syringe(size):
    s = size / 128 * K
    full = (size * K, size * K)
    strip = syringe_strip(s).rotate(45, resample=Image.BICUBIC, expand=True)
    im = Image.new("RGBA", full, (0, 0, 0, 0))
    center = (58 * s, 58 * s)
    im.alpha_composite(strip, (int(center[0] - strip.width / 2), int(center[1] - strip.height / 2)))
    im = outlined(im, max(3.0, 2.2 * 128 / size) * s * 0.9)
    im.alpha_composite(clock(full, s, (98, 98)))
    return im.resize((size, size), Image.LANCZOS)


def build():
    return {("Adapting", size): syringe(size) for size in SIZES}


def main():
    images = build()
    for (name, size), im in images.items():
        im.save(os.path.join(OUT_DIR, "OA_Moodle_%s_%d.png" % (name, size)))
    if "--preview" in sys.argv:
        folder = os.path.join(MOODLES, "64")
        bg = Image.open(os.path.join(folder, "_Moodles_BGsolid.png")).convert("RGBA")

        def back(level):
            t = level / 4
            r, g, b, a = bg.split()
            tint = (0.42 + 0.45 * t, 0.42 - 0.22 * t, 0.42 - 0.22 * t) if level else (0.42, 0.42, 0.42)
            return Image.merge("RGBA", (r.point(lambda v: int(v * tint[0])), g.point(lambda v: int(v * tint[1])),
                                        b.point(lambda v: int(v * tint[2])), a))
        pics = [(images[("Adapting", 64)], back(0))]
        pics += [(Image.open(os.path.join(folder, n + ".png")).convert("RGBA"), back(2))
                 for n in ("Status_HeavyLoad", "Status_InjuredMinor", "Status_Bleeding")]
        sheet = Image.new("RGBA", (74 * len(pics) + 10, 84), (60, 60, 60, 255))
        for i, (pic, b) in enumerate(pics):
            sheet.alpha_composite(b, (10 + i * 74, 10))
            sheet.alpha_composite(pic, (10 + i * 74, 10))
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        big = Image.new("RGBA", (sheet.width, sheet.height + 280), (60, 60, 60, 255))
        big.alpha_composite(sheet, (0, 0))
        big.alpha_composite(images[("Adapting", 128)].resize((256, 256), Image.NEAREST), (10, sheet.height + 10))
        big.alpha_composite(images[("Adapting", 32)].resize((128, 128), Image.NEAREST), (290, sheet.height + 10))
        big.alpha_composite(images[("Adapting", 48)].resize((96, 96), Image.NEAREST), (440, sheet.height + 10))
        big.save(PREVIEW_PATH)
    print("wrote", len(images), "pictures to", OUT_DIR)


if __name__ == "__main__":
    main()
