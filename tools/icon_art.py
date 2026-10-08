"""Draws the item icons: OperationAcorn/42/media/textures/Item_OA_<ItemName>.png (32x32), named by tools/icons.txt.

tools/icons.txt is the one place that says which item name gets which picture: one line per icon, tab-separated
    ItemName <TAB> picture key <TAB> note
Rename an item by changing the first column and running this script again (the old PNG is deleted when its name goes
away). The picture keys are the functions in PICTURES below. An item script says  Icon = OA_<ItemName>  and the game
finds media/textures/Item_OA_<ItemName>.png.

    python tools/icon_art.py            writes the icons
    python tools/icon_art.py --preview  also writes tools/icon_preview.png (every icon at 32px and at 4x)

The pictures are small solids drawn with the tile engine (tile_engine.py), in the same light and palette as the tiles:
the machines are their tiles shrunk, the parts are tiered by colour (old: rust brown, normal: steel grey, modern:
anodised blue), the serums by their tree (scout: blue-teal, load: amber, survival: green, shared: violet).
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw, ImageFilter  # noqa: E402

import tile_engine as E  # noqa: E402
from tile_engine import Scene, rotation, apply, add, stencil_text, acorn_mark, font  # noqa: E402
import tile_objects as O  # noqa: E402
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,  # noqa: E402
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, flat_decal, front_decal, side_decal,
                          stick, noise_texture)
import tile_art as A  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TEXTURES = os.path.join(HERE, '..', 'OperationAcorn', '42', 'media', 'textures')
SIZE = 32

TIERS = {
    'Old': dict(body=(142, 96, 62), dark=(98, 64, 40), light=(176, 128, 86), tag=(176, 120, 60)),
    'Normal': dict(body=(138, 146, 152), dark=(92, 98, 104), light=(184, 190, 194), tag=(184, 190, 194)),
    'Modern': dict(body=(58, 128, 196), dark=(36, 84, 138), light=(110, 176, 230), tag=(70, 150, 230)),
}
TREE = {
    'Scout': dict(liquid=(54, 180, 196), dark=(30, 110, 126), cap=(36, 100, 120)),
    'Load': dict(liquid=(236, 160, 48), dark=(166, 100, 24), cap=(150, 90, 30)),
    'Survival': dict(liquid=(108, 190, 70), dark=(60, 120, 40), cap=(60, 110, 40)),
    'Shared': dict(liquid=(176, 120, 226), dark=(110, 66, 160), cap=(96, 60, 140)),
}


# ----------------------------------------------------------------------------------------------------------------
# From a scene (or an image) to a 32x32 icon: cropped to what is drawn, fitted, with a thin dark outline.

def fit(image, size=SIZE, margin=1):
    box = image.getbbox()
    if not box:
        return Image.new('RGBA', (size, size), (0, 0, 0, 0))
    crop = image.crop(box)
    inner = size - 2 * margin - 2   # room left for the outline
    scale = inner / max(crop.width, crop.height)
    big = crop.resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.alpha_composite(big, ((size - big.width) // 2, (size - big.height) // 2))
    return outline(out)


def outline(icon):
    a = icon.getchannel('A')
    grown = a.filter(ImageFilter.MaxFilter(3))
    ring = Image.new('RGBA', icon.size, (22, 24, 22, 0))
    ring.putalpha(Image.eval(grown, lambda v: 215 if v > 20 else 0))
    ring.alpha_composite(icon)
    return ring


def from_scene(scene, glows=None):
    big = scene.render()
    small = big.convert('RGBa').resize((E.W * 2, E.H * 2), Image.LANCZOS).convert('RGBA')
    return fit(small)


def brighten(image, k=1.18):
    a = np.asarray(image).astype(np.float64)
    a[..., :3] = np.clip(a[..., :3] * k, 0, 255)
    return Image.fromarray(a.astype(np.uint8), 'RGBA')


def from_machine(key, state=0, facing='S'):
    """A machine's icon: the whole machine as it stands in the world (its tiles assembled), south facing."""
    return fit(brighten(A.assembled(key, state, facing)))


# ----------------------------------------------------------------------------------------------------------------
# Small solids.

def prism(s, pts2, z0, z1, colour, top=None, shine=0.2):
    """A flat prism over a 2-D outline (counter-clockwise), sides and top."""
    n = len(pts2)
    s.face([(x, y, z1) for x, y in pts2], top or colour, (0, 0, 1), shine)
    for i in range(n):
        (xa, ya), (xb, yb) = pts2[i], pts2[(i + 1) % n]
        out = E.unit((yb - ya, -(xb - xa), 0.0)) if (xb, yb) != (xa, ya) else (0, 0, 1)
        s.face([(xa, ya, z0), (xb, yb, z0), (xb, yb, z1), (xa, ya, z1)], colour, out, shine)


def star(cx, cy, r_out, r_in, teeth, phase=0.0):
    pts = []
    for i in range(teeth * 2):
        a = phase + math.pi * i / teeth
        rr = r_out if i % 2 == 0 else r_in
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


def hole(s, cx, cy, z, r, segments=6, colour=(26, 28, 28)):
    s.face([(cx + r * math.cos(2 * math.pi * i / segments), cy + r * math.sin(2 * math.pi * i / segments), z)
            for i in range(segments)], colour, (0, 0, 1))


def pictogram(kind, w=80, h=48, ink=(30, 34, 34), bg=(236, 232, 212)):
    """Small flat pictures for labels and plates."""
    sc = 4
    img = Image.new('RGBA', (w * sc, h * sc), bg + (255,))
    d = ImageDraw.Draw(img)
    c = ink + (255,)
    cx, cy = w * sc / 2, h * sc / 2

    def bag(x, y, s_):
        d.rounded_rectangle([x - 14 * s_, y - 12 * s_, x + 14 * s_, y + 16 * s_], radius=7 * s_, fill=c)
        d.rounded_rectangle([x - 9 * s_, y - 17 * s_, x + 9 * s_, y - 9 * s_], radius=4 * s_, outline=c, width=int(3 * s_))
        d.rectangle([x - 8 * s_, y + 2 * s_, x + 8 * s_, y + 8 * s_], fill=bg + (255,))
    if kind == 'bagplus':
        bag(cx - 8 * sc, cy, 1.2)
        d.rectangle([cx + 12 * sc, cy - 3 * sc, cx + 30 * sc, cy + 3 * sc], fill=c)
        d.rectangle([cx + 18 * sc, cy - 9 * sc, cx + 24 * sc, cy + 9 * sc], fill=c)
    elif kind == 'bagfeather':
        bag(cx - 8 * sc, cy, 1.2)
        d.polygon([(cx + 22 * sc, cy - 16 * sc), (cx + 22 * sc, cy + 6 * sc), (cx + 12 * sc, cy + 6 * sc)], fill=c)
        d.polygon([(cx + 22 * sc, cy + 6 * sc), (cx + 32 * sc, cy + 6 * sc), (cx + 22 * sc, cy + 18 * sc)], fill=c)
        d.rectangle([cx + 19 * sc, cy - 16 * sc, cx + 25 * sc, cy + 4 * sc], fill=c)
    elif kind == 'trunk':
        d.polygon([(cx - 30 * sc, cy + 8 * sc), (cx - 28 * sc, cy - 4 * sc), (cx - 14 * sc, cy - 12 * sc), (cx + 14 * sc, cy - 12 * sc),
                   (cx + 30 * sc, cy - 2 * sc), (cx + 32 * sc, cy + 8 * sc)], fill=c)
        d.ellipse([cx - 24 * sc, cy + 2 * sc, cx - 12 * sc, cy + 14 * sc], fill=bg + (255,), outline=c, width=int(3 * sc))
        d.ellipse([cx + 14 * sc, cy + 2 * sc, cx + 26 * sc, cy + 14 * sc], fill=bg + (255,), outline=c, width=int(3 * sc))
        d.polygon([(cx - 10 * sc, cy - 14 * sc), (cx + 10 * sc, cy - 22 * sc), (cx + 14 * sc, cy - 12 * sc)], fill=c)
    elif kind == 'engine':
        d.rectangle([cx - 24 * sc, cy - 8 * sc, cx + 20 * sc, cy + 14 * sc], fill=c)
        for i in range(4):
            d.rectangle([cx - 20 * sc + i * 11 * sc, cy - 17 * sc, cx - 12 * sc + i * 11 * sc, cy - 8 * sc], fill=c)
        d.rectangle([cx + 20 * sc, cy - 2 * sc, cx + 30 * sc, cy + 8 * sc], fill=c)
        d.rectangle([cx - 30 * sc, cy, cx - 24 * sc, cy + 6 * sc], fill=c)
        d.polygon([(cx - 4 * sc, cy - 2 * sc), (cx + 6 * sc, cy - 2 * sc), (cx, cy + 12 * sc)], fill=(255, 190, 40, 255))
    elif kind == 'exclaim':
        d.rectangle([cx - 4 * sc, cy - 17 * sc, cx + 4 * sc, cy + 5 * sc], fill=c)
        d.ellipse([cx - 5 * sc, cy + 9 * sc, cx + 5 * sc, cy + 19 * sc], fill=c)
    elif kind == 'cross':
        d.rectangle([cx - 5 * sc, cy - 17 * sc, cx + 5 * sc, cy + 17 * sc], fill=(190, 40, 34, 255))
        d.rectangle([cx - 17 * sc, cy - 5 * sc, cx + 17 * sc, cy + 5 * sc], fill=(190, 40, 34, 255))
    elif kind == 'clock':
        d.ellipse([cx - 17 * sc, cy - 17 * sc, cx + 17 * sc, cy + 17 * sc], outline=c, width=int(4 * sc))
        d.line([(cx, cy), (cx, cy - 11 * sc)], fill=c, width=int(3 * sc))
        d.line([(cx, cy), (cx + 8 * sc, cy + 4 * sc)], fill=c, width=int(3 * sc))
    return img.resize((w, h), Image.LANCZOS)


def paper_image(w=64, h=80, lines=7, stamp=None, checks=False, seed=1):
    img = Image.new('RGBA', (w, h), (232, 228, 208, 255))
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    d.rectangle([4, 4, w - 5, 12], fill=(60, 70, 52, 255))
    d.rectangle([7, 6, 26, 10], fill=(220, 214, 190, 255))
    for i in range(lines):
        y = 18 + i * ((h - 26) // lines)
        x0 = 6 + (10 if checks else 0)
        d.line([(x0, y), (x0 + rnd.randint(30, w - x0 - 8) - 6, y)], fill=(70, 70, 66, 255), width=2)
        if checks:
            d.rectangle([6, y - 3, 12, y + 3], outline=(60, 60, 56, 255))
            if i % 3 != 2:
                d.line([(7, y), (9, y + 3), (13, y - 5)], fill=(40, 120, 50, 255), width=2)
    if stamp:
        d.ellipse([w - 34, h - 34, w - 6, h - 6], outline=(190, 50, 40, 255), width=3)
        d.line([(w - 30, h - 12), (w - 10, h - 28)], fill=(190, 50, 40, 255), width=3)
    return img


# ----------------------------------------------------------------------------------------------------------------
# The pictures.

def trade_tile(index):
    return lambda: fit(brighten(A.TRADE[index][0]()))


def machine(key, state=0):
    return lambda: from_machine(key, state)


def document_manual():
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -34), (0.5, 0.5, 0.1))
    # a spiral-bound booklet lying a little open: olive cover with the team mark
    s.box(0.14, 0.18, 0.0, 0.86, 0.82, 0.07, OD_DARK, top=OD, shine=0.05)
    s.box(0.16, 0.20, 0.07, 0.84, 0.80, 0.085, (226, 222, 200))
    s.box(0.14, 0.18, 0.085, 0.86, 0.82, 0.13, OD, top=OD_LIGHT, shine=0.05)
    cover = Image.new('RGBA', (100, 80), (0, 0, 0, 0))
    flat_decal(s, 0.30, 0.24, 0.80, 0.76, 0.131, noise_texture(10, 10, 3, OD, spread=4), offset=0.0)
    flat_decal(s, 0.40, 0.30, 0.64, 0.54, 0.132, acorn_mark(48, STENCIL), offset=0.0)
    flat_decal(s, 0.34, 0.60, 0.78, 0.72, 0.132, stencil_text('MANUAL', 90, 22, STENCIL), offset=0.0)
    for i in range(7):
        y = 0.22 + i * 0.09
        s.tube((0.17, y, 0.11), (0.25, y, 0.11), 0.018, STEEL, segments=8, shine=0.6)
    return from_scene(s)


def document_manifest():
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -34), (0.5, 0.5, 0.1))
    # a clipboard: a wood board, a manifest sheet with checks, a steel clip
    s.box(0.16, 0.12, 0.0, 0.84, 0.88, 0.05, WOOD_DARK, top=WOOD, shine=0.05)
    flat_decal(s, 0.16, 0.12, 0.84, 0.88, 0.051, noise_texture(40, 40, 5, WOOD, spread=10), offset=0.0)
    s.box(0.22, 0.22, 0.05, 0.78, 0.84, 0.062, (232, 228, 208))
    flat_decal(s, 0.22, 0.22, 0.78, 0.84, 0.0625, paper_image(64, 74, 6, checks=True, stamp=True, seed=4), offset=0.0)
    s.box(0.34, 0.08, 0.05, 0.66, 0.2, 0.09, STEEL, top=(196, 200, 204), shine=0.7)
    s.box(0.44, 0.04, 0.09, 0.56, 0.1, 0.1, STEEL_DARK, shine=0.5)
    return from_scene(s)


def document_generic():
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -34), (0.5, 0.5, 0.1))
    # a manila folder with sheets sticking out and a red stamp
    s.box(0.14, 0.2, 0.0, 0.86, 0.8, 0.03, (190, 160, 100), top=(206, 176, 116))
    s.box(0.18, 0.24, 0.03, 0.8, 0.76, 0.05, (232, 228, 208))
    flat_decal(s, 0.18, 0.24, 0.8, 0.76, 0.0505, paper_image(64, 60, 5, stamp=True, seed=2), offset=0.0)
    s.box(0.14, 0.2, 0.05, 0.86, 0.62, 0.075, (206, 176, 116), top=(222, 192, 130))
    s.box(0.62, 0.14, 0.05, 0.84, 0.21, 0.075, (206, 176, 116), top=(222, 192, 130))
    flat_decal(s, 0.64, 0.145, 0.82, 0.205, 0.0755, stencil_text('OAK', 40, 14, (120, 40, 30)), offset=0.0)
    s.tube((0.28, 0.68, 0.055), (0.28, 0.76, 0.055), 0.012, STEEL, segments=6, shine=0.6)
    return from_scene(s)


def mission_item():
    s = Scene(0)
    # a sealed field pouch: olive canvas, a flap with a strap and a yellow tag
    s.box(0.2, 0.26, 0.0, 0.8, 0.74, 0.42, OD, top=OD_LIGHT, shine=0.05)
    s.box(0.18, 0.24, 0.30, 0.82, 0.76, 0.46, OD_DARK, top=OD, shine=0.05)
    s.box(0.44, 0.74, 0.04, 0.56, 0.78, 0.42, (60, 56, 40))
    s.box(0.42, 0.76, 0.28, 0.58, 0.8, 0.34, STEEL, shine=0.6)
    s.box(0.62, 0.76, 0.12, 0.78, 0.8, 0.32, YELLOW)
    front_decal(s, 0.64, 0.76, 0.14, 0.30, 0.801, pictogram('exclaim', 24, 40, bg=YELLOW), offset=0.0)
    s.box(0.2, 0.76, 0.0, 0.8, 0.77, 0.04, OD_DARK)
    return from_scene(s)


def bundle():
    s = Scene(0)
    # three clear sample bags with different contents, tied together with twine, a paper tag
    cols = ((150, 90, 56), (84, 120, 164), (172, 168, 140))
    for i, (x, y, c) in enumerate(((0.18, 0.28, cols[0]), (0.34, 0.2, cols[1]), (0.5, 0.3, cols[2]))):
        s.box(x, y, 0.0, x + 0.3, y + 0.42, 0.1, (214, 224, 228), top=(232, 240, 242), shine=0.7)
        s.box(x + 0.04, y + 0.06, 0.1, x + 0.26, y + 0.32, 0.13, c)
        s.box(x + 0.03, y + 0.36, 0.1, x + 0.27, y + 0.4, 0.125, (186, 40, 36))
    s.tube((0.16, 0.5, 0.16), (0.84, 0.5, 0.16), 0.012, TAN, segments=6)
    s.tube((0.16, 0.56, 0.16), (0.84, 0.56, 0.16), 0.012, TAN, segments=6)
    s.box(0.7, 0.62, 0.12, 0.88, 0.8, 0.14, (226, 222, 196))
    return from_scene(s)


def meteor_fragment():
    s = Scene(0)
    s.rock((0.5, 0.5, 0.2), 0.34, 11, (66, 58, 54), squash=(1.1, 0.95, 0.9), detail=1, jitter=0.3, colour2=(130, 82, 50),
           shine=0.2)
    s.rock((0.58, 0.46, 0.34), 0.1, 12, (170, 164, 158), squash=(1, 0.8, 0.5), detail=0, jitter=0.15, shine=0.8)
    return from_scene(s)


def vial(tree, cross=False):
    t = TREE[tree]
    s = Scene(0)
    cx, cy = 0.5, 0.5
    s.tube((cx, cy, 0.0), (cx, cy, 0.5), 0.17, t['liquid'], cap=t['liquid'], segments=28, shine=0.7,
           bands=[(0, 0.08, t['dark']), (0.08, 0.86, t['liquid']), (0.86, 1.0, t['dark'])])
    # the glass: a pale highlight stripe down the side
    s.tube((cx - 0.165, cy + 0.03, 0.08), (cx - 0.165, cy + 0.03, 0.42), 0.018, (240, 240, 234), segments=6, emit=True)
    # neck, the crimp ring and the stopper
    s.tube((cx, cy, 0.5), (cx, cy, 0.58), 0.1, t['dark'], segments=24, shine=0.5)
    s.tube((cx, cy, 0.58), (cx, cy, 0.66), 0.115, (206, 208, 212), cap=(226, 228, 232), segments=24, shine=0.8)
    s.tube((cx, cy, 0.66), (cx, cy, 0.72), 0.07, t['cap'], cap=(28, 28, 30), segments=18, shine=0.2)
    # the label
    front_decal(s, cx - 0.14, cx + 0.14, 0.1, 0.38, cy + 0.168, pictogram('cross' if cross else 'clock', 40, 44, bg=(236, 232, 212)) if cross else label_image(t), offset=0.0)
    return from_scene(s)


def label_image(t):
    img = Image.new('RGBA', (40, 44), (236, 232, 212, 255))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 39, 10], fill=t['dark'] + (255,))
    for i in range(3):
        d.line([(5, 17 + i * 8), (34 - i * 5, 17 + i * 8)], fill=(70, 70, 66, 255), width=2)
    d.ellipse([27, 28, 36, 37], fill=t['liquid'] + (255,))
    return img


def cure_serum():
    return vial('Scout', cross=True)


def cure_vial():
    t = dict(liquid=(236, 246, 240), dark=(150, 190, 176), cap=(190, 40, 34))
    s = Scene(0)
    cx, cy = 0.5, 0.5
    s.tube((cx, cy, 0.0), (cx, cy, 0.5), 0.17, t['liquid'], cap=t['liquid'], segments=28, shine=0.8,
           bands=[(0, 0.08, t['dark']), (0.08, 0.86, t['liquid']), (0.86, 1.0, t['dark'])])
    s.tube((cx - 0.165, cy + 0.03, 0.08), (cx - 0.165, cy + 0.03, 0.42), 0.018, (255, 255, 255), segments=6, emit=True)
    s.tube((cx, cy, 0.5), (cx, cy, 0.58), 0.1, t['dark'], segments=24, shine=0.5)
    s.tube((cx, cy, 0.58), (cx, cy, 0.66), 0.115, (206, 208, 212), cap=(226, 228, 232), segments=24, shine=0.8)
    s.tube((cx, cy, 0.66), (cx, cy, 0.72), 0.07, t['cap'], cap=(28, 28, 30), segments=18, shine=0.2)
    front_decal(s, cx - 0.14, cx + 0.14, 0.1, 0.38, cy + 0.168, cross_label(), offset=0.0)
    return from_scene(s)


def cross_label():
    img = Image.new('RGBA', (40, 44), (240, 238, 226, 255))
    d = ImageDraw.Draw(img)
    d.rectangle([15, 8, 25, 36], fill=(190, 40, 34, 255))
    d.rectangle([6, 17, 34, 27], fill=(190, 40, 34, 255))
    return img


def delay_drug():
    s = Scene(0)
    cx, cy = 0.5, 0.5
    # an amber pill bottle with a white cap and a clock label
    s.tube((cx, cy, 0.0), (cx, cy, 0.48), 0.2, (196, 118, 40), cap=(196, 118, 40), segments=30, shine=0.5,
           bands=[(0, 0.04, (150, 86, 26)), (0.04, 0.96, (196, 118, 40)), (0.96, 1, (150, 86, 26))])
    s.tube((cx, cy, 0.48), (cx, cy, 0.62), 0.21, (236, 234, 226), cap=(250, 248, 242), segments=30, shine=0.2,
           bands=[(0, 1, (236, 234, 226))])
    for i in range(10):
        a = 2 * math.pi * i / 10
        s.tube((cx + 0.205 * math.cos(a), cy + 0.205 * math.sin(a), 0.49), (cx + 0.205 * math.cos(a), cy + 0.205 * math.sin(a), 0.61), 0.01,
               (206, 204, 196), segments=4)
    front_decal(s, cx - 0.17, cx + 0.17, 0.08, 0.42, cy + 0.198, delay_label(), offset=0.0)
    return from_scene(s)


def delay_label():
    img = Image.new('RGBA', (48, 48), (240, 238, 226, 255))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 47, 8], fill=(60, 70, 52, 255))
    d.ellipse([12, 14, 36, 38], outline=(40, 40, 40, 255), width=3)
    d.line([(24, 26), (24, 18)], fill=(40, 40, 40, 255), width=2)
    d.line([(24, 26), (30, 29)], fill=(40, 40, 40, 255), width=2)
    return img


def tiered(tier):
    return TIERS[tier]


def motor(tier):
    t = TIERS[tier]
    s = Scene(0)
    cy, cz, r = 0.5, 0.32, 0.2
    s.box(0.2, 0.34, 0.0, 0.6, 0.66, 0.08, t['dark'])
    fins = []
    x = 0.0
    while x < 0.97:
        fins.append((x, min(1.0, x + 0.09), t['body']))
        fins.append((min(1.0, x + 0.09), min(1.0, x + 0.14), t['dark']))
        x += 0.14
    s.tube((0.16, cy, cz), (0.64, cy, cz), r, t['body'], cap=t['dark'], segments=28, bands=fins, shine=0.3)
    s.tube((0.64, cy, cz), (0.9, cy, cz), 0.045, STEEL, shine=0.8, segments=12)
    s.tube((0.64, cy, cz), (0.68, cy, cz), 0.12, t['dark'], segments=20)
    s.box(0.32, 0.42, cz + r - 0.02, 0.5, 0.58, cz + r + 0.1, BLACK, top=(64, 66, 68), shine=0.2)
    s.tube((0.41, 0.5, cz + r + 0.1), (0.41, 0.5, cz + r + 0.12), 0.03, t['tag'], segments=12)
    return from_scene(s)


def shredder_blade(tier):
    t = TIERS[tier]
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -24), (0.5, 0.5, 0.05))
    pts = star(0.5, 0.5, 0.42, 0.3, 9, 0.2)
    prism(s, pts, 0.0, 0.1, t['dark'], top=t['body'], shine=0.5)
    pts2 = star(0.5, 0.5, 0.3, 0.26, 18, 0.0)
    s.face([(x, y, 0.101) for x, y in pts2], t['light'], (0, 0, 1), 0.4)
    hole(s, 0.5, 0.5, 0.102, 0.1, 6)
    for i in range(3):
        a = 2 * math.pi * i / 3 + 0.5
        hole(s, 0.5 + 0.2 * math.cos(a), 0.5 + 0.2 * math.sin(a), 0.102, 0.03, 8)
    return from_scene(s)


def cutting_blade(tier):
    t = TIERS[tier]
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -30), (0.5, 0.5, 0.05))
    pts = [(0.1, 0.4), (0.7, 0.4), (0.9, 0.5), (0.7, 0.6), (0.1, 0.6)]
    prism(s, pts, 0.0, 0.05, t['dark'], top=t['light'], shine=0.8)
    s.face([(0.1, 0.4, 0.052), (0.7, 0.4, 0.052), (0.9, 0.5, 0.052), (0.7, 0.5, 0.052), (0.1, 0.5, 0.052)], t['body'], (0, 0, 1), 0.6)
    s.box(0.1, 0.38, 0.0, 0.3, 0.62, 0.1, t['tag'], top=t['light'], shine=0.1)
    for x in (0.16, 0.24):
        hole(s, x, 0.5, 0.101, 0.025, 8)
    return from_scene(s)


def saw_blade_item(tier):
    t = TIERS[tier]
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -24), (0.5, 0.5, 0.05))
    pts = star(0.5, 0.5, 0.44, 0.38, 28, 0.0)
    prism(s, pts, 0.0, 0.04, t['dark'], top=t['light'], shine=0.9)
    pts2 = [(0.5 + 0.28 * math.cos(2 * math.pi * i / 40), 0.5 + 0.28 * math.sin(2 * math.pi * i / 40)) for i in range(40)]
    s.face([(x, y, 0.041) for x, y in pts2], t['body'], (0, 0, 1), 0.6)
    hole(s, 0.5, 0.5, 0.042, 0.07, 14)
    for i in range(4):
        a = 2 * math.pi * i / 4 + 0.4
        hole(s, 0.5 + 0.3 * math.cos(a), 0.5 + 0.3 * math.sin(a), 0.042, 0.04, 8, t['dark'])
    return from_scene(s)


def catalyst(tier):
    t = TIERS[tier]
    s = Scene(0)
    cx, cy = 0.5, 0.5
    s.tube((cx, cy, 0.0), (cx, cy, 0.62), 0.22, t['body'], cap=t['light'], segments=30, shine=0.5,
           bands=[(0, 0.06, t['dark']), (0.06, 0.34, t['body']), (0.34, 0.5, t['tag']), (0.5, 0.94, t['body']), (0.94, 1, t['dark'])])
    # the perforated top and a nozzle
    for i in range(7):
        for j in range(7):
            x, y = cx - 0.15 + i * 0.05, cy - 0.15 + j * 0.05
            if (x - cx) ** 2 + (y - cy) ** 2 < 0.17 ** 2:
                hole(s, x, y, 0.622, 0.012, 6)
    s.tube((cx, cy, 0.62), (cx, cy, 0.7), 0.06, STEEL_DARK, segments=14, shine=0.5)
    s.tube((cx, cy, 0.7), (cx, cy, 0.76), 0.085, STEEL, segments=14, shine=0.8)
    return from_scene(s)


def foam_image(tier, w=96, h=64):
    return foam_coarse(tier, w, h)


def foam_coarse_old(tier, w, h):
    t = TIERS[tier]
    img = Image.new('RGBA', (w, h), t['dark'] + (255,))
    d = ImageDraw.Draw(img)
    for i in range(0, w, 8):
        for j in range(0, h, 8):
            d.polygon([(i, j + 8), (i + 4, j), (i + 8, j + 8)], fill=t['body'] + (255,))
            d.polygon([(i + 4, j + 8), (i + 8, j), (i + 12, j + 8)], fill=t['light'] + (255,))
    return img


def foam_coarse(tier, w, h):
    t = TIERS[tier]
    img = Image.new('RGBA', (w, h), t['dark'] + (255,))
    d = ImageDraw.Draw(img)
    n = 12
    for i in range(0, w, n):
        for j in range(0, h, n):
            d.polygon([(i, j), (i + n, j), (i + n / 2, j + n / 2)], fill=t['body'] + (255,))
            d.polygon([(i, j), (i + n / 2, j + n / 2), (i, j + n)], fill=t['dark'] + (255,))
            d.polygon([(i + n, j), (i + n, j + n), (i + n / 2, j + n / 2)], fill=t['light'] + (255,))
            d.polygon([(i, j + n), (i + n, j + n), (i + n / 2, j + n / 2)], fill=tuple(int(c * 0.6) for c in t['dark']) + (255,))
    return img


def cover(tier):
    t = TIERS[tier]
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), -30), (0.5, 0.5, 0.1))
    s.box(0.12, 0.22, 0.0, 0.88, 0.78, 0.2, t['dark'], top=t['body'], shine=0.0)
    flat_decal(s, 0.12, 0.22, 0.88, 0.78, 0.2, foam_image(tier), offset=0.0)
    front_decal(s, 0.12, 0.88, 0.0, 0.2, 0.781, noise_texture(10, 10, 2, t['dark'], spread=6), offset=0.0)
    s.box(0.12, 0.74, 0.0, 0.88, 0.78, 0.06, t['tag'])
    return from_scene(s)


def kit(kind, plate):
    s = Scene(0)
    s.box(0.14, 0.26, 0.0, 0.86, 0.74, 0.34, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.13, 0.25, 0.22, 0.87, 0.75, 0.3, OD_DARK, top=OD, shine=0.1)
    s.tube((0.34, 0.5, 0.34), (0.66, 0.5, 0.34), 0.02, BLACK, segments=8)
    s.tube((0.34, 0.5, 0.3), (0.34, 0.5, 0.36), 0.02, BLACK, segments=8)
    s.tube((0.66, 0.5, 0.3), (0.66, 0.5, 0.36), 0.02, BLACK, segments=8)
    s.box(0.2, 0.745, 0.18, 0.28, 0.77, 0.3, STEEL_DARK, shine=0.5)
    s.box(0.72, 0.745, 0.18, 0.8, 0.77, 0.3, STEEL_DARK, shine=0.5)
    img = pictogram(kind, 80, 48, bg=plate)
    front_decal(s, 0.3, 0.7, 0.04, 0.2, 0.751, img, offset=0.0)
    flat_decal(s, 0.3, 0.32, 0.7, 0.56, 0.301, img, offset=0.0)
    return from_scene(s)


def backpack():
    s = Scene(0)
    cx = 0.5
    s.box(0.24, 0.3, 0.0, 0.76, 0.7, 0.58, OD, top=OD_LIGHT, shine=0.05)
    s.box(0.22, 0.28, 0.4, 0.78, 0.72, 0.64, OD_DARK, top=OD, shine=0.05)
    # two front pockets
    s.box(0.27, 0.7, 0.04, 0.46, 0.78, 0.26, OD_LIGHT)
    s.box(0.54, 0.7, 0.04, 0.73, 0.78, 0.26, OD_LIGHT)
    s.box(0.26, 0.7, 0.24, 0.47, 0.79, 0.28, OD_DARK)
    s.box(0.53, 0.7, 0.24, 0.74, 0.79, 0.28, OD_DARK)
    # the flap's straps with buckles
    for x in (0.34, 0.62):
        s.box(x, 0.7, 0.3, x + 0.05, 0.74, 0.62, (74, 70, 50))
        s.box(x - 0.01, 0.74, 0.34, x + 0.06, 0.76, 0.4, STEEL, shine=0.7)
    front_decal(s, 0.4, 0.6, 0.46, 0.62, 0.725, acorn_mark(28, STENCIL), offset=0.0)
    # webbing strips on the sides with two hooks each, and a canteen hanging on the east one
    for sx in (0.22, 0.78):
        s.box(sx - 0.01 if sx < 0.5 else sx, 0.34, 0.1, sx + 0.0 if sx < 0.5 else sx + 0.012, 0.66, 0.5, (74, 70, 50))
    s.box(0.78, 0.4, 0.14, 0.8, 0.48, 0.2, STEEL, shine=0.7)
    s.tube((0.84, 0.5, 0.02), (0.84, 0.5, 0.3), 0.07, OD_DARK, cap=OD, segments=16)
    s.tube((0.84, 0.5, 0.3), (0.84, 0.5, 0.34), 0.03, BLACK, segments=10)
    return from_scene(s)


def jerrycan(mk):
    body = {1: OD, 2: (120, 128, 90), 3: (190, 196, 200)}[mk]
    top = {1: OD_LIGHT, 2: (146, 156, 112), 3: (214, 220, 224)}[mk]
    s = Scene(0)
    s.box(0.2, 0.32, 0.0, 0.8, 0.68, 0.56, body, top=top, shine=0.5 if mk == 3 else 0.1)
    # the three channels and the handle
    s.box(0.2, 0.32, 0.56, 0.42, 0.68, 0.64, body, top=top)
    s.box(0.58, 0.32, 0.56, 0.8, 0.68, 0.64, body, top=top)
    s.box(0.4, 0.4, 0.56, 0.6, 0.6, 0.6, (30, 30, 30))
    s.tube((0.68, 0.5, 0.56), (0.68, 0.5, 0.74), 0.045, STEEL_DARK, segments=14, shine=0.5)
    s.tube((0.68, 0.5, 0.74), (0.68, 0.5, 0.78), 0.06, (208, 70, 50) if mk < 3 else (230, 190, 70), segments=14, shine=0.4)
    s.tube((0.3, 0.5, 0.64), (0.58, 0.5, 0.64), 0.03, STEEL_DARK, segments=10)
    # stripes: one, two or three bands in the tier's colours
    cols = {1: [(230, 190, 50)], 2: [(236, 232, 214), (236, 232, 214)], 3: [(196, 50, 40), (196, 50, 40), (230, 190, 70)]}[mk]
    for i, c in enumerate(cols):
        z = 0.08 + i * 0.07
        s.box(0.2, 0.68, z, 0.8, 0.682, z + 0.04, c)
        s.box(0.8, 0.32, z, 0.802, 0.68, z + 0.04, c)
    front_decal(s, 0.34, 0.7, 0.30, 0.46, 0.683, stencil_text('MK%d' % mk, 50, 24, (30, 30, 28) if mk == 3 else STENCIL), offset=0.0)
    return from_scene(s)


def torch(mk):
    body = {1: OD, 2: (140, 146, 150), 3: (196, 60, 44)}[mk]
    dark = {1: OD_DARK, 2: (96, 100, 104), 3: (140, 40, 30)}[mk]
    s = Scene(0)
    s.tilt = (rotation((0, 1, 0), -30), (0.5, 0.5, 0.25))
    s.tube((0.18, 0.5, 0.2), (0.5, 0.5, 0.2), 0.055, BLACK, cap=(60, 60, 62), segments=14, shine=0.2)
    s.box(0.46, 0.42, 0.14, 0.7, 0.58, 0.34, body, top=dark, shine=0.5)
    s.tube((0.7, 0.5, 0.26), (0.9, 0.5, 0.26), 0.04, STEEL, cap=STEEL, segments=14, shine=0.8)
    s.tube((0.9, 0.5, 0.26), (0.97, 0.5, 0.26), 0.02, BRASS, segments=12, shine=0.8, r2=0.012)
    s.tube((0.6, 0.5, 0.34), (0.6, 0.5, 0.44), 0.012, STEEL_DARK, segments=6)
    s.tube((0.6, 0.5, 0.44), (0.6, 0.5, 0.48), 0.045, (210, 70, 50), segments=14, shine=0.3)
    # two hoses running back and down
    s.tube((0.18, 0.46, 0.2), (0.1, 0.4, 0.08), 0.02, (198, 60, 40), segments=8)
    s.tube((0.18, 0.54, 0.2), (0.1, 0.6, 0.08), 0.02, (50, 90, 160), segments=8)
    front_decal(s, 0.5, 0.68, 0.17, 0.3, 0.581, stencil_text('MK%d' % mk, 40, 20, (234, 230, 210)), offset=0.0)
    return from_scene(s)


def lure_icon():
    s = Scene(0)
    cx, cy = 0.5, 0.5
    s.box(0.22, 0.4, 0.0, 0.78, 0.7, 0.2, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.22, 0.4, 0.14, 0.78, 0.7, 0.2, OD_DARK, top=OD, shine=0.1)
    front_decal(s, 0.3, 0.7, 0.03, 0.12, 0.701, stencil_text('LURE', 40, 12, STENCIL), offset=0.0)
    s.tube((0.3, 0.55, 0.2), (0.3, 0.55, 0.55), 0.02, GREY, segments=8)
    s.tube((0.3, 0.55, 0.55), (0.55, 0.55, 0.62), 0.12, (104, 108, 114), r2=0.28, cap=(150, 154, 160), segments=28, shine=0.5)
    s.tube((0.3, 0.55, 0.55), (0.3, 0.55, 0.9), 0.008, STEEL, segments=6)
    s.tube((0.68, 0.5, 0.2), (0.68, 0.5, 0.36), 0.015, STEEL, segments=6)
    s.tube((0.68, 0.5, 0.36), (0.68, 0.5, 0.42), 0.04, (255, 160, 40), cap=(255, 230, 170), segments=12, emit=True)
    return from_scene(s)


PICTURES = {
    'terminal': lambda: fit(brighten(O.terminal(0, True))),
    'delivery_box': trade_tile(9),
    'supply_crate': trade_tile(10),
    'manual': document_manual,
    'manifest': document_manifest,
    'document': document_generic,
    'mission': mission_item,
    'bundle': bundle,
    'meteor': meteor_fragment,
    'serum_scout': lambda: vial('Scout'),
    'serum_load': lambda: vial('Load'),
    'serum_survival': lambda: vial('Survival'),
    'serum_shared': lambda: vial('Shared'),
    'cure': cure_vial,
    'delay': delay_drug,
    'shred_bench': machine('shredBench'),
    'bulk_shredder': machine('bulkShredder'),
    'cutter': machine('cutter'),
    'propane_refiner': machine('propaneRefiner'),
    'oil_refiner': machine('oilRefiner'),
    'wood_saw': machine('woodSaw'),
    'research_storage': machine('researchStorage'),
    'rain_storage': machine('rainStorage', 3),
    'lure': lure_icon,
    'backpack': backpack,
    'kit_bag_capacity': lambda: kit('bagplus', (170, 200, 236)),
    'kit_bag_weight': lambda: kit('bagfeather', (240, 200, 120)),
    'kit_trunk': lambda: kit('trunk', (168, 220, 196)),
    'kit_engine': lambda: kit('engine', (236, 170, 150)),
    'fuel_can_1': lambda: jerrycan(1), 'fuel_can_2': lambda: jerrycan(2), 'fuel_can_3': lambda: jerrycan(3),
    'torch_1': lambda: torch(1), 'torch_2': lambda: torch(2), 'torch_3': lambda: torch(3),
}
for _tier in TIERS:
    for _key, _fn in (('motor', motor), ('shredder_blade', shredder_blade), ('cutting_blade', cutting_blade),
                      ('saw_blade', saw_blade_item), ('catalyst', catalyst), ('cover', cover)):
        PICTURES['%s_%s' % (_key, _tier.lower())] = (lambda f=_fn, t=_tier: f(t))

import icon_story  # noqa: E402
PICTURES.update(icon_story.pictures(sys.modules[__name__]))


def read_list():
    path = os.path.join(HERE, 'icons.txt')
    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.strip() or line.startswith('#'):
                continue
            parts = line.split('\t')
            rows.append((parts[0], parts[1]))
    return rows


def main():
    rows = read_list()
    os.makedirs(TEXTURES, exist_ok=True)
    wanted = set()
    made = []
    for name, key in rows:
        icon = PICTURES[key]()
        file = 'Item_OA_%s.png' % name
        icon.save(os.path.join(TEXTURES, file))
        wanted.add(file)
        made.append((name, icon))
    # icons of names that were renamed away
    for file in os.listdir(TEXTURES):
        if file.startswith('Item_OA_') and file not in wanted:
            os.remove(os.path.join(TEXTURES, file))
    if '--preview' in sys.argv:
        cols = 10
        cell = 32 * 4 + 8
        rows_n = (len(made) + cols - 1) // cols
        sheet = Image.new('RGBA', (cols * cell, rows_n * (cell + 14)), (88, 94, 84, 255))
        d = ImageDraw.Draw(sheet)
        for i, (name, icon) in enumerate(made):
            x, y = (i % cols) * cell, (i // cols) * (cell + 14)
            sheet.alpha_composite(icon.resize((128, 128), Image.NEAREST), (x + 4, y + 2))
            sheet.alpha_composite(icon, (x + 4, y + 2))
            d.text((x + 3, y + 132), name[:20], fill=(240, 240, 230, 255))
        sheet.save(os.path.join(HERE, 'icon_preview.png'))
    print('wrote', len(made), 'icons')


if __name__ == '__main__':
    main()
