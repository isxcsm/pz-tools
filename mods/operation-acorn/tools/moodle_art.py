#!/usr/bin/env python3
"""Operation Acorn moodle pictures, made from the game's own mood moodle art so that they sit in the moodle column
as the game's own: the game's face is taken as it is (its shading, gloss, lids and outline), its expression changed
and its colours mapped onto the mod's, then scaled to every moodle size the game's option offers.

Usage:
    python tools/moodle_art.py             write media/textures/OA_Moodle_Sixth_<size>.png
    python tools/moodle_art.py --preview   also write tools/moodle_art_preview.png (beside some of the game's own)

Needs the game installed (PZ_GAME, default the Steam folder): it reads media/ui/Moodles/128/Mood_Bored.png.

The sixth sense (육감): the game's bored face, its pupils moved into the corners of its eyes (a sidelong look: it
has noticed something there; it is not scared), the comics' "sensed it" mark outside its head in the upper right corner (as the game's scared face has its drop
outside it; the face keeps the game's size),
in a deep rose (a warning colour, kept apart from the game's angry face, which is bright red).
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
PREVIEW_PATH = os.path.join(HERE, "moodle_art_preview.png")

# The bored face's grey tones onto deep rose ones, by brightness: black stays near black and white stays white.
RAMP = [(0, (18, 10, 10)), (60, (80, 26, 30)), (110, (148, 56, 58)), (150, (194, 94, 90)),
        (190, (226, 146, 136)), (230, (245, 208, 200)), (255, (255, 255, 255))]
MARK = (252, 226, 218)
MARK_EDGE = (80, 26, 30)
PUPIL = (8, 8, 10)
# Each eye of the 128 bored face: its white's columns (x0..x1) and rows (y0..y1), and where its pupil is (px0..px1).
EYES = ((31, 53, 56, 63, 38, 46), (71, 96, 56, 63, 80, 87))
SHIFT = 6       # how far the pupils move, to the left


def brightness(p):
    return (p[0] + p[1] + p[2]) / 3


def look_aside(face):
    """Moves each pupil SHIFT pixels left. The empty eye is rebuilt first: on each row the span the pupil covered
    (with its soft edge) takes the colours between the eye's white just left and right of it. The pupil is then lifted
    off the original as darkness over that empty eye and laid back SHIFT pixels to the left, edge and all."""
    src = face.copy()
    s = src.load()
    for x0, x1, y0, y1, p0, p1 in EYES:
        a, b = p0 - 3, p1 + 3            # white on both sides of the pupil and its soft edge
        empty = {}
        for y in range(y0, y1 + 1):
            ca, cb = s[a, y], s[b, y]
            for x in range(a, b + 1):
                t = (x - a) / (b - a)
                empty[(x, y)] = tuple(int(ca[i] + (cb[i] - ca[i]) * t) for i in range(4))
        dark = {}
        for (x, y), e in empty.items():
            depth = brightness(e) - brightness(s[x, y])
            if depth > 0 and brightness(e) > 0:
                dark[(x, y)] = min(1.0, depth / brightness(e))
        px = face.load()
        for (x, y), e in empty.items():
            px[x, y] = e
        for (x, y), k in dark.items():
            tx = x - SHIFT
            if tx < x0:
                continue
            under = px[tx, y]
            px[tx, y] = tuple(int(under[i] * (1 - k) + PUPIL[i] * k) for i in range(3)) + (under[3],)
    return face


def recolour(face):
    lut = []
    for v in range(256):
        for (a, ca), (b, cb) in zip(RAMP, RAMP[1:]):
            if v <= b:
                t = (v - a) / (b - a)
                lut.append(tuple(int(ca[i] + (cb[i] - ca[i]) * t) for i in range(3)))
                break
    px = face.load()
    for y in range(face.height):
        for x in range(face.width):
            r, g, b, a = px[x, y]
            px[x, y] = lut[int(0.299 * r + 0.587 * g + 0.114 * b)] + (a,)
    return face


def tingle(face, boost=1.0):
    """The comics' "sensed it" mark outside the head at its upper right: a small cluster of three wedges joined at a
    root just off the rim, fanning outward, thick at the root and pointed; drawn at 8x the picture's own size and laid
    on smoothly, with a dark edge a pixel wide at that size. Its measures are in the 128 picture's pixels; boost grows
    the wedges (not the root's place) so that they still read as wedges in the small pictures."""
    k = 8
    f = face.width / 128 * k            # 128-picture pixels to layer pixels
    layer = Image.new("L", (face.width * k, face.height * k), 0)
    d = ImageDraw.Draw(layer)
    cx, cy = 64, 66                     # the face's middle; it keeps its size, the mark goes in the corner beside it
    out = -45
    root = 49                           # just off the rim
    ox, oy = cx + root * math.cos(math.radians(out)), cy + root * math.sin(math.radians(out))
    r0, r1, w = 1.5 * boost, 12 * boost, 3.9 * boost ** 0.5   # longer more than wider, so they stay apart
    for ang in (out - 47, out, out + 47):
        a = math.radians(ang)
        ux, uy, nx, ny = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
        d.polygon([((ox + ux * r0 + nx * w) * f, (oy + uy * r0 + ny * w) * f), ((ox + ux * r1) * f, (oy + uy * r1) * f),
                   ((ox + ux * r0 - nx * w) * f, (oy + uy * r0 - ny * w) * f)], fill=255)
        d.ellipse(((ox + ux * r0 - w) * f, (oy + uy * r0 - w) * f, (ox + ux * r0 + w) * f, (oy + uy * r0 + w) * f),
                  fill=255)
    mask = layer.resize(face.size, Image.LANCZOS)
    # a dark outline round them, as the game's drawn marks have (the scared face's drop)
    edge = layer.filter(ImageFilter.MaxFilter(2 * k + 1)).resize(face.size, Image.LANCZOS)
    face.paste(Image.new("RGBA", face.size, MARK_EDGE + (255,)), (0, 0), edge)
    face.paste(Image.new("RGBA", face.size, MARK + (255,)), (0, 0), mask)
    return face


# How much the mark grows in each picture: at 32 and 48 pixels the 128 picture's wedges shrink to a dot.
BOOST = {32: 1.6, 48: 1.3}


def build():
    face = recolour(look_aside(Image.open(os.path.join(MOODLES, "128", "Mood_Bored.png")).convert("RGBA")))
    return {size: tingle(face.copy() if size == 128 else face.resize((size, size), Image.LANCZOS), BOOST.get(size, 1.0))
            for size in SIZES}


def main():
    images = build()
    for size, im in images.items():
        im.save(os.path.join(OUT_DIR, "OA_Moodle_Sixth_%d.png" % size))
    if "--preview" in sys.argv:
        folder = os.path.join(MOODLES, "64")
        bg = Image.open(os.path.join(folder, "_Moodles_BGsolid.png")).convert("RGBA")
        r, g, b, a = bg.split()
        back = Image.merge("RGBA", (r.point(lambda v: int(v * 0.42)), g.point(lambda v: int(v * 0.42)),
                                    b.point(lambda v: int(v * 0.42)), a))
        pics = [images[64]] + [Image.open(os.path.join(folder, n + ".png")).convert("RGBA")
                               for n in ("Mood_Concentrating", "Mood_Bored", "Mood_Scared", "Mood_Sad")]
        sheet = Image.new("RGBA", (74 * len(pics) + 10, 84), (60, 60, 60, 255))
        for i, pic in enumerate(pics):
            sheet.alpha_composite(back, (10 + i * 74, 10))
            sheet.alpha_composite(pic, (10 + i * 74, 10))
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        big = Image.new("RGBA", (sheet.width, sheet.height + 270), (60, 60, 60, 255))
        big.alpha_composite(sheet, (0, 0))
        big.alpha_composite(images[128].resize((256, 256), Image.NEAREST), (10, sheet.height + 8))
        big.alpha_composite(images[32].resize((128, 128), Image.NEAREST), (280, sheet.height + 8))
        big.alpha_composite(images[48].resize((144, 144), Image.NEAREST), (420, sheet.height + 8))
        big.save(PREVIEW_PATH)
    print("wrote", len(images), "sizes to", OUT_DIR)


if __name__ == "__main__":
    main()
