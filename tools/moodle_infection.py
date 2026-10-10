#!/usr/bin/env python3
"""Operation Acorn's infection moodles: 억제 중 (a delay drug holds the infection) and 검사 전 (a zombie wound not yet
tested for). One picture each for every moodle size; the level only changes the tooltip's text, not the picture.
Drawn as the game's status moodles are (Status_HeavyLoad, Status_InjuredMinor): one plain object, a dark outline, soft
shading, no face.

  Suppressed: a capsule pill, pale and amber halves, with a pause badge (two bars) at its lower right.
  Untested:   a test tube with a pale liquid, with a question mark badge at its lower right.

Usage:
    python tools/moodle_infection.py             write media/textures/OA_Moodle_<Name>_<size>.png
    python tools/moodle_infection.py --preview   also write tools/moodle_infection_preview.png (beside the game's own)

Needs the game installed (PZ_GAME, default the Steam folder) for the preview's backgrounds and neighbours only.
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SIZES = (32, 48, 64, 80, 96, 128)
GAME = os.environ.get("PZ_GAME", r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid")
MOODLES = os.path.join(GAME, "media", "ui", "Moodles")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
PREVIEW_PATH = os.path.join(HERE, "moodle_infection_preview.png")

K = 8                                   # supersampling
OUTLINE = (30, 33, 37)
PALE_TOP, PALE_BOTTOM = (240, 244, 247), (176, 186, 194)
AMBER_TOP, AMBER_BOTTOM = (246, 190, 92), (200, 120, 36)
BADGE = (58, 64, 72)
BADGE_RIM = (232, 236, 240)
GLASS = (214, 230, 238)
LIQUID_TOP, LIQUID_BOTTOM = (170, 232, 200), (70, 168, 120)
FONTS = (r"C:\Windows\Fonts\arialbd.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")


def vertical(size, box, top, bottom):
    """A vertical gradient filling `box` (x0, y0, x1, y1) of an image of `size`."""
    im = Image.new("RGBA", size, (0, 0, 0, 0))
    x0, y0, x1, y1 = [int(v) for v in box]
    d = ImageDraw.Draw(im)
    for y in range(max(0, y0), min(size[1], y1 + 1)):
        t = (y - y0) / max(1, y1 - y0)
        d.line([(x0, y), (x1, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return im


def capsule(length, thickness):
    """A capsule's mask (a stadium) `length` by `thickness` pixels."""
    m = Image.new("L", (int(length), int(thickness)), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, length - 1, thickness - 1), radius=thickness / 2, fill=255)
    return m


def on_canvas(mask, full, center, angle):
    """The mask turned by `angle` degrees (counter-clockwise) and put with its middle at `center` on a blank mask."""
    turned = mask.rotate(angle, resample=Image.BICUBIC, expand=True)
    out = Image.new("L", full, 0)
    out.paste(turned, (int(center[0] - turned.width / 2), int(center[1] - turned.height / 2)))
    return out


def outlined(im, px):
    """The picture with a dark outline `px` pixels wide around everything that is drawn."""
    alpha = im.getchannel("A")
    grown = alpha.filter(ImageFilter.MaxFilter(int(px) * 2 + 1))
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(Image.new("RGBA", im.size, OUTLINE + (255,)), (0, 0), grown)
    out.alpha_composite(im)
    return out


def badge(full, s, center, kind):
    """The round badge at the lower right: two bars (pause) or a question mark."""
    im = Image.new("RGBA", full, (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx, cy, r = center[0] * s, center[1] * s, 25 * s
    d.ellipse((cx - r - 3 * s, cy - r - 3 * s, cx + r + 3 * s, cy + r + 3 * s), fill=OUTLINE + (255,))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=BADGE_RIM + (255,))
    r2 = r - 4 * s
    d.ellipse((cx - r2, cy - r2, cx + r2, cy + r2), fill=BADGE + (255,))
    if kind == "pause":
        w, h = 7 * s, 22 * s
        for dx in (-9 * s, 2 * s):
            d.rounded_rectangle((cx + dx, cy - h / 2, cx + dx + w, cy + h / 2), radius=2 * s, fill=BADGE_RIM + (255,))
    else:
        font = None
        for path in FONTS:
            if os.path.exists(path):
                font = ImageFont.truetype(path, int(34 * s))
                break
        if font is None:
            font = ImageFont.load_default()
        d.text((cx, cy + 1 * s), "?", font=font, fill=BADGE_RIM + (255,), anchor="mm")
    return im


def pill(size):
    s = size / 128 * K
    full = (size * K, size * K)
    im = Image.new("RGBA", full, (0, 0, 0, 0))
    length, thick = 92 * s, 40 * s
    center = (56 * s, 60 * s)
    shape = on_canvas(capsule(length, thick), full, center, 45)
    # the two halves: the line between them is across the capsule, at its middle
    half = Image.new("L", full, 0)
    hx, hy = center
    ux, uy = math.cos(math.radians(45)), -math.sin(math.radians(45))      # along the capsule, to its upper right
    px, py = -uy, ux                                                      # across it
    far = 200 * s
    ImageDraw.Draw(half).polygon([(hx + px * far, hy + py * far), (hx - px * far, hy - py * far),
                                  (hx - px * far + ux * far, hy - py * far + uy * far),
                                  (hx + px * far + ux * far, hy + py * far + uy * far)], fill=255)
    amber = ImageChops.multiply(shape, half)
    pale = ImageChops.subtract(shape, amber)
    top, bottom = 22 * s, 100 * s
    im.paste(vertical(full, (0, top, full[0], bottom), PALE_TOP, PALE_BOTTOM), (0, 0), pale)
    im.paste(vertical(full, (0, top, full[0], bottom), AMBER_TOP, AMBER_BOTTOM), (0, 0), amber)
    # the light along the upper left edge
    gloss = on_canvas(capsule(length * 0.78, thick * 0.16), full, (center[0] - 6 * s, center[1] - 7 * s), 45)
    im.paste(Image.new("RGBA", full, (255, 255, 255, 255)), (0, 0), gloss.point(lambda v: int(v * 0.55)))
    im = outlined(im, max(3.0, 2.2 * 128 / size) * s * 0.9)
    im.alpha_composite(badge(full, s, (98, 98), "pause"))
    return im.resize((size, size), Image.LANCZOS)


def tube(size):
    s = size / 128 * K
    full = (size * K, size * K)
    im = Image.new("RGBA", full, (0, 0, 0, 0))
    length, thick = 100 * s, 34 * s
    center = (56 * s, 58 * s)
    angle = 52
    # the tube: a stadium, the mouth end square, standing on its round end
    body = Image.new("L", (int(length), int(thick)), 0)
    ImageDraw.Draw(body).rounded_rectangle((0, 0, length - 1, thick - 1), radius=thick / 2, fill=255)
    ImageDraw.Draw(body).rectangle((length - thick / 2, 0, length - 1, thick - 1), fill=255)
    shape = on_canvas(body, full, center, angle)
    glass = vertical(full, (0, 18 * s, full[0], 100 * s), (236, 244, 248), GLASS)
    im.paste(glass, (0, 0), shape)
    # the liquid: the half of the tube nearest its round end
    liquid = Image.new("L", (int(length), int(thick)), 0)
    ImageDraw.Draw(liquid).rounded_rectangle((5 * s, 5 * s, length * 0.58, thick - 5 * s), radius=(thick - 10 * s) / 2,
                                             fill=255)
    liquid = on_canvas(liquid, full, center, angle)
    im.paste(vertical(full, (0, 40 * s, full[0], 100 * s), LIQUID_TOP, LIQUID_BOTTOM), (0, 0), liquid)
    # the rim ring at the mouth, and a light line along the glass
    ring = Image.new("L", (int(8 * s), int(thick + 8 * s)), 255)
    ring = on_canvas(ring, full, (center[0] + (length / 2 - 2 * s) * math.cos(math.radians(angle)),
                                  center[1] - (length / 2 - 2 * s) * math.sin(math.radians(angle))), angle)
    im.paste(Image.new("RGBA", full, (200, 208, 214, 255)), (0, 0), ring)
    gloss = on_canvas(capsule(length * 0.62, thick * 0.14), full, (center[0] - 4 * s, center[1] - 5 * s), angle)
    im.paste(Image.new("RGBA", full, (255, 255, 255, 255)), (0, 0), gloss.point(lambda v: int(v * 0.7)))
    im = outlined(im, max(3.0, 2.2 * 128 / size) * s * 0.9)
    im.alpha_composite(badge(full, s, (98, 98), "question"))
    return im.resize((size, size), Image.LANCZOS)


def build():
    return {("Suppressed", size): pill(size) for size in SIZES} | {("Untested", size): tube(size) for size in SIZES}


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
        pics = [(images[("Suppressed", 64)], back(0)), (images[("Untested", 64)], back(2))]
        pics += [(Image.open(os.path.join(folder, n + ".png")).convert("RGBA"), back(2))
                 for n in ("Status_HeavyLoad", "Status_InjuredMinor", "Status_Bleeding")]
        sheet = Image.new("RGBA", (74 * len(pics) + 10, 84), (60, 60, 60, 255))
        for i, (pic, b) in enumerate(pics):
            sheet.alpha_composite(b, (10 + i * 74, 10))
            sheet.alpha_composite(pic, (10 + i * 74, 10))
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        big = Image.new("RGBA", (sheet.width, sheet.height + 280), (60, 60, 60, 255))
        big.alpha_composite(sheet, (0, 0))
        big.alpha_composite(images[("Suppressed", 128)].resize((256, 256), Image.NEAREST), (10, sheet.height + 10))
        big.alpha_composite(images[("Untested", 128)].resize((256, 256), Image.NEAREST), (280, sheet.height + 10))
        x = 560
        for name in ("Suppressed", "Untested"):
            big.alpha_composite(images[(name, 32)].resize((128, 128), Image.NEAREST), (x, sheet.height + 10))
            big.alpha_composite(images[(name, 48)].resize((96, 96), Image.NEAREST), (x + 16, sheet.height + 150))
            x += 140
        big.save(PREVIEW_PATH)
    print("wrote", len(images), "pictures to", OUT_DIR)


if __name__ == "__main__":
    main()
