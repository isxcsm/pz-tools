"""The machines sheet's objects: the shred bench, the bulk shredder, the cutter, the propane and oil refiners, the wood
saw, the research storage, the big rain storage and the installable lure. Each machine faces south at turns=0; those that
run have a stopped and a running look (lamps lit, what the machine is doing shown)."""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from tile_engine import (Scene, shadow, compose, unit, rotation, apply, add, sub, mul, stencil_text, acorn_mark,
                         IDENTITY, project, SS, W, H, UP, font)
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, LIT, UNLIT, BEZEL, lamp, lamp_y, lamp_x,
                          knob_y, stick, flat_decal, front_decal, side_decal, noise_texture, face_frame)
from tile_trade import hazard_strip, plank_lines

GRAPHITE = (74, 78, 82)
GRAPHITE_DARK = (52, 55, 58)
GRAPHITE_LIGHT = (104, 108, 112)
CREAM = (206, 202, 184)
CREAM_DARK = (166, 162, 146)
STEAM = (236, 238, 240)
FLAME = (255, 168, 40)


def double_poly(s, pts, outside, inside, outward, shine=0.0):
    """A thin wall drawn from both sides: the near side in one colour, the inside seen across a vessel in another."""
    s.poly(pts, outside, outward, shine)
    s.poly(pts, inside, mul(outward, -1), shine)


def ring_top(s, centre, r0, r1, z, colour, segments=40, shine=0.0):
    """A flat ring (a rim) facing up between two radii."""
    cx, cy = centre
    for i in range(segments):
        a0, a1 = 2 * math.pi * i / segments, 2 * math.pi * (i + 1) / segments
        pts = [(cx + r1 * math.cos(a0), cy + r1 * math.sin(a0), z), (cx + r1 * math.cos(a1), cy + r1 * math.sin(a1), z),
               (cx + r0 * math.cos(a1), cy + r0 * math.sin(a1), z), (cx + r0 * math.cos(a0), cy + r0 * math.sin(a0), z)]
        s.face(pts, colour, (0, 0, 1), shine)


def disc(s, centre, r, z, colour, segments=40, shine=0.0, emit=False):
    cx, cy = centre
    s.face([(cx + r * math.cos(2 * math.pi * i / segments), cy + r * math.sin(2 * math.pi * i / segments), z)
            for i in range(segments)], colour, (0, 0, 1), shine, emit)


def gauge_image(value, size=40, dark=False):
    """A round pressure gauge: a white dial with a scale, a red zone, the needle at value 0..1."""
    scale = 4
    s = size * scale
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, s - 1, s - 1], fill=(40, 42, 44, 255))
    d.ellipse([s * 0.07, s * 0.07, s * 0.93, s * 0.93], fill=(226, 224, 210, 255))
    for i in range(11):
        a = math.radians(225 - i * 27)
        r0, r1 = s * 0.30, s * 0.42
        c, sn = math.cos(a), -math.sin(a)
        col = (180, 40, 30, 255) if i >= 8 else (40, 40, 40, 255)
        d.line([(s / 2 + c * r0, s / 2 + sn * r0), (s / 2 + c * r1, s / 2 + sn * r1)], fill=col, width=scale)
    a = math.radians(225 - value * 270)
    d.line([(s / 2, s / 2), (s / 2 + math.cos(a) * s * 0.38, s / 2 - math.sin(a) * s * 0.38)], fill=(20, 20, 20, 255), width=int(scale * 1.6))
    d.ellipse([s * 0.45, s * 0.45, s * 0.55, s * 0.55], fill=(30, 30, 30, 255))
    return img.resize((size, size), Image.LANCZOS)


def valve_wheel(s, centre, r, colour=RED, axis='x'):
    """A hand wheel standing on an axis: a rim of tube, spokes."""
    x, y, z = centre
    if axis == 'x':
        a, b = (x - 0.006, y, z), (x + 0.006, y, z)
        s.tube(a, b, r, colour, cap=colour, segments=20)
        s.tube(a, b, r * 0.78, colour, segments=20, inward=True)
        for ang in (0, 60, 120):
            c, sn = math.cos(math.radians(ang)) * r, math.sin(math.radians(ang)) * r
            s.tube((x, y - c, z - sn), (x, y + c, z + sn), 0.004, colour, segments=5)
    else:
        a, b = (x, y - 0.006, z), (x, y + 0.006, z)
        s.tube(a, b, r, colour, cap=colour, segments=20)
        for ang in (0, 60, 120):
            c, sn = math.cos(math.radians(ang)) * r, math.sin(math.radians(ang)) * r
            s.tube((x - c, y, z - sn), (x + c, y, z + sn), 0.004, colour, segments=5)


# ----------------------------------------------------------------------------------------------------------------

def pegboard_image(w=128, h=56):
    img = Image.new('RGBA', (w, h), (76, 80, 70, 255))
    d = ImageDraw.Draw(img)
    for x in range(3, w, 6):
        for y in range(3, h, 6):
            d.ellipse([x - 1, y - 1, x, y], fill=(40, 42, 38, 255))
    steel, handle = (190, 194, 198, 255), (150, 100, 56, 255)
    # a hammer
    d.rectangle([10, 12, 13, 44], fill=handle)
    d.rectangle([4, 8, 20, 15], fill=steel)
    # a big wrench
    d.rectangle([30, 14, 34, 46], fill=steel)
    d.ellipse([27, 6, 38, 18], fill=steel)
    d.rectangle([31, 6, 34, 12], fill=(76, 80, 70, 255))
    # pliers
    d.polygon([(48, 10), (53, 10), (56, 28), (50, 28)], fill=(196, 50, 40, 255))
    d.polygon([(58, 10), (63, 10), (60, 28), (54, 28)], fill=(196, 50, 40, 255))
    d.polygon([(50, 28), (56, 28), (55, 40), (51, 40)], fill=steel)
    d.polygon([(54, 28), (60, 28), (59, 40), (56, 40)], fill=steel)
    # a saw
    d.polygon([(70, 12), (100, 12), (100, 32), (70, 32)], fill=steel)
    for x in range(70, 100, 3):
        d.polygon([(x, 32), (x + 1.5, 36), (x + 3, 32)], fill=steel)
    d.rectangle([100, 14, 108, 30], fill=handle)
    # screwdrivers
    for i, x in enumerate((114, 119, 124)):
        d.rectangle([x, 22, x + 2, 36], fill=steel)
        d.rectangle([x - 1, 8, x + 3, 22], fill=(224, 170, 40, 255) if i != 1 else (196, 50, 40, 255))
    return img


def shred_bench(turns):
    """The shred bench: a steel-framed workbench with a plank top, a vise at one end, a tray of parts, a hammer and
    a hacksaw, a pegboard of tools behind, and a scrap bin on the shelf under it."""
    s = Scene(turns)
    glows = []
    x0, x1, y0, y1 = 0.06, 0.94, 0.22, 0.78
    zt = 0.50
    for lx in (x0 + 0.02, x1 - 0.06):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx, ly, 0.0, lx + 0.04, ly + 0.04, zt, OD_DARK, shine=0.1)
    s.box(x0, y0, zt, x1, y1, zt + 0.05, OD_DARK, top=OD_DARK)
    s.box(x0 - 0.01, y0 - 0.01, zt + 0.05, x1 + 0.01, y1 + 0.01, zt + 0.075, WOOD, top=WOOD)
    flat_decal(s, x0 - 0.01, y0 - 0.01, x1 + 0.01, y1 + 0.01, zt + 0.075, plank_lines(176, 56, 3, WOOD, lines=4, spread=12), offset=0.001)
    front_decal(s, x0 - 0.01, x1 + 0.01, zt + 0.05, zt + 0.075, y1 + 0.01, plank_lines(176, 8, 4, WOOD_DARK, lines=1), offset=0.001)
    # a lower shelf with the scrap bin
    s.box(x0 + 0.03, y0 + 0.03, 0.14, x1 - 0.03, y1 - 0.03, 0.17, OD_DARK, top=OD)
    s.box(0.18, 0.30, 0.17, 0.46, 0.70, 0.36, GRAPHITE_DARK, top=GRAPHITE, shine=0.1)
    s.box(0.19, 0.31, 0.34, 0.45, 0.69, 0.36, (20, 20, 20))
    # scrap in the bin: wire, a hose end, bits of metal
    rn = random.Random(8)
    for i in range(6):
        bx, by = 0.21 + rn.random() * 0.2, 0.33 + rn.random() * 0.3
        s.box(bx, by, 0.34, bx + 0.05, by + 0.03, 0.38 + rn.random() * 0.03,
              rn.choice([(150, 70, 40), (120, 124, 128), (70, 100, 150), (190, 170, 120)]))
    # a box of parts on the shelf
    s.box(0.56, 0.32, 0.17, 0.80, 0.62, 0.30, OD, top=OD_LIGHT)
    front_decal(s, 0.58, 0.78, 0.2, 0.28, 0.621, stencil_text('PARTS', 40, 14, STENCIL))
    # the pegboard at the back
    s.box(x0, y0, zt + 0.075, x1, y0 + 0.02, zt + 0.52, OD_DARK, top=OD_DARK)
    front_decal(s, x0 + 0.02, x1 - 0.02, zt + 0.1, zt + 0.50, y0 + 0.02, pegboard_image(), offset=0.002)
    s.box(x0, y0 + 0.02, zt + 0.52, x1, y0 + 0.045, zt + 0.545, STEEL_DARK, shine=0.3)
    # a lamp on an arm
    s.tube((0.80, 0.30, zt + 0.075), (0.80, 0.30, zt + 0.40), 0.008, STEEL_DARK, segments=8)
    s.tube((0.80, 0.30, zt + 0.40), (0.64, 0.38, zt + 0.40), 0.008, STEEL_DARK, segments=8)
    s.tube((0.64, 0.38, zt + 0.41), (0.64, 0.38, zt + 0.30), 0.05, OD_DARK, r2=0.022, cap=(250, 240, 200), segments=16, shine=0.3)
    # the vise at the left end
    s.box(0.10, 0.46, zt + 0.075, 0.22, 0.62, zt + 0.15, GRAPHITE_DARK, top=GRAPHITE, shine=0.3)
    s.box(0.07, 0.48, zt + 0.12, 0.10, 0.60, zt + 0.17, GRAPHITE, shine=0.3)
    s.tube((0.04, 0.54, zt + 0.12), (0.10, 0.54, zt + 0.12), 0.012, STEEL, shine=0.6, segments=8)
    s.tube((0.035, 0.46, zt + 0.12), (0.035, 0.62, zt + 0.12), 0.008, STEEL, shine=0.6, segments=8)
    # a tray of small parts, a hammer, a hacksaw
    s.box(0.34, 0.42, zt + 0.075, 0.52, 0.64, zt + 0.10, GRAPHITE_DARK)
    s.box(0.345, 0.425, zt + 0.10, 0.515, 0.635, zt + 0.103, (24, 24, 24))
    for i in range(7):
        bx, by = 0.36 + rn.random() * 0.13, 0.44 + rn.random() * 0.17
        s.tube((bx, by, zt + 0.103), (bx, by, zt + 0.118), 0.012, rn.choice([BRASS, STEEL, (150, 70, 40)]), shine=0.5, segments=8)
    s.tube((0.60, 0.40, zt + 0.095), (0.74, 0.46, zt + 0.095), 0.01, WOOD_DARK, segments=8)
    s.box(0.72, 0.42, zt + 0.075, 0.80, 0.52, zt + 0.12, STEEL, shine=0.5)
    s.box(0.58, 0.58, zt + 0.075, 0.84, 0.60, zt + 0.12, STEEL, shine=0.5)
    s.box(0.82, 0.57, zt + 0.075, 0.90, 0.61, zt + 0.13, RED)
    # the front edge: the team's mark
    front_decal(s, x0 + 0.04, x0 + 0.17, zt + 0.0, zt + 0.05, y1 + 0.0, stencil_text('OAK', 44, 16, STENCIL), offset=0.002)
    ground = shadow((0.5, 0.5), 0.5, 0.34, 120)
    return compose(s, ground=ground, seed=100 + turns, glows=glows)


def bulk_shredder(turns, running):
    """The bulk shredder: an olive cabinet with a motor on its east end, a hopper with yellow-black rim on top over
    twin shafts, an output chute and a bin in front, a control box with lamps and an emergency stop, a beacon on a
    post. Running: the green lamp and beacon are lit and the bin holds shredded pieces."""
    s = Scene(turns)
    glows = []
    x0, x1, y0, y1 = 0.12, 0.80, 0.24, 0.76
    zb = 0.46
    s.box(x0 - 0.02, y0 - 0.02, 0.0, x1 + 0.02, y1 + 0.02, 0.06, GRAPHITE_DARK)
    s.box(x0, y0, 0.06, x1, y1, zb, OD, top=OD_LIGHT, shine=0.1)
    # panel seams and bolts on the cabinet
    s.box(x0 - 0.004, y0 - 0.004, 0.06, x1 + 0.004, y1 + 0.004, 0.09, OD_DARK)
    s.box(x0 - 0.004, y0 - 0.004, zb - 0.03, x1 + 0.004, y1 + 0.004, zb, OD_DARK)
    for i in range(4):
        s.box(x0 + 0.08 + i * 0.12, y1, 0.14, x0 + 0.095 + i * 0.12, y1 + 0.006, 0.40, OD_DARK)
    # the motor on the east end: a finned drum with a terminal box and a belt guard
    s.box(x1, 0.34, 0.12, x1 + 0.03, 0.66, 0.30, GRAPHITE_DARK, shine=0.2)
    s.tube((x1 + 0.03, 0.5, 0.26), (x1 + 0.17, 0.5, 0.26), 0.12, BLUE, cap=(34, 66, 94), shine=0.2, segments=32,
           bands=[(0, 0.07, (34, 66, 94))] + [(0.1 + 0.11 * i, 0.17 + 0.11 * i, (40, 84, 128)) for i in range(8)])
    s.tube((x1 + 0.17, 0.5, 0.26), (x1 + 0.19, 0.5, 0.26), 0.06, STEEL_DARK, shine=0.5, segments=16)
    s.box(x1 + 0.06, 0.45, 0.37, x1 + 0.13, 0.55, 0.42, (34, 66, 94), top=BLUE)
    s.box(x1 + 0.03, 0.31, 0.06, x1 + 0.2, 0.69, 0.10, GRAPHITE_DARK)
    # the hopper: a funnel from the cabinet's top to a wider mouth, its inside dark
    zh = 0.92
    a, b = (x0 + 0.02, y0 + 0.02), (x1 - 0.02, y1 - 0.02)
    m0 = (0.07, 0.11)   # the mouth's inset from the cabinet's edge
    top = [(a[0] - 0.02, a[1] - 0.04, zh), (b[0] + 0.02, a[1] - 0.04, zh), (b[0] + 0.02, b[1] + 0.04, zh), (a[0] - 0.02, b[1] + 0.04, zh)]
    low = [(a[0] + 0.05, a[1] + 0.08, zb), (b[0] - 0.05, a[1] + 0.08, zb), (b[0] - 0.05, b[1] - 0.08, zb), (a[0] + 0.05, b[1] - 0.08, zb)]
    for i in range(4):
        j = (i + 1) % 4
        mid = ((top[i][0] + top[j][0]) / 2, (top[i][1] + top[j][1]) / 2)
        out = unit((mid[0] - 0.46, mid[1] - 0.5, 0.0))
        pts = [low[i], low[j], top[j], top[i]]
        double_poly(s, pts, OD, (64, 68, 58), (out[0], out[1], 0.3), shine=0.1)
    # the throat, two shafts with cutter discs seen from above
    s.box(low[0][0], low[0][1], zb - 0.001, low[2][0], low[2][1], zb + 0.0005, (20, 20, 20))
    for i in range(2):
        y = 0.40 + i * 0.20
        s.tube((x0 + 0.1, y, zb + 0.03), (x1 - 0.1, y, zb + 0.03), 0.025, STEEL_DARK, shine=0.4, segments=12)
        for k in range(7):
            xx = x0 + 0.13 + k * 0.075
            s.tube((xx, y, zb + 0.03), (xx + 0.04, y, zb + 0.03), 0.06, STEEL, cap=STEEL_DARK, shine=0.6, segments=14)
    # the rim: yellow and black bands round the mouth
    rim_h = 0.07
    for i in range(4):
        j = (i + 1) % 4
        p0, p1 = top[i], top[j]
        out = unit(((p0[0] + p1[0]) / 2 - 0.46, (p0[1] + p1[1]) / 2 - 0.5, 0.0))
        pts = [(p0[0], p0[1], zh - rim_h), (p1[0], p1[1], zh - rim_h), (p1[0], p1[1], zh + 0.012), (p0[0], p0[1], zh + 0.012)]
        double_poly(s, pts, YELLOW, (44, 44, 40), out)
    front_decal(s, top[0][0], top[1][0], zh - rim_h, zh + 0.012, top[2][1] + 0.002, hazard_strip(120, 16, YELLOW, (30, 30, 28), 8))
    s.poly([(top[1][0], top[1][1], zh - rim_h), (top[2][0], top[2][1], zh - rim_h), (top[2][0], top[2][1], zh + 0.012),
            (top[1][0], top[1][1], zh + 0.012)], YELLOW, (1, 0, 0))
    # the output chute and the bin in front
    s.poly([(0.30, y1, 0.14), (0.62, y1, 0.14), (0.62, y1 + 0.14, 0.04), (0.30, y1 + 0.14, 0.04)], GRAPHITE_DARK, (0, 1, 1), shine=0.2)
    s.box(0.27, y1, 0.04, 0.30, y1 + 0.14, 0.14, GRAPHITE_DARK)
    s.box(0.62, y1, 0.04, 0.65, y1 + 0.14, 0.14, GRAPHITE_DARK)
    bin_y0, bin_y1 = y1 + 0.03, y1 + 0.22
    s.box(0.26, bin_y0, 0.0, 0.66, bin_y1, 0.14, GRAPHITE, top=GRAPHITE_DARK, shine=0.1)
    s.box(0.275, bin_y0 + 0.015, 0.10, 0.645, bin_y1 - 0.015, 0.141, (22, 22, 22))
    if running:
        rn = random.Random(3)
        s.box(0.28, bin_y0 + 0.02, 0.10, 0.64, bin_y1 - 0.02, 0.12, (60, 56, 50))
        for i in range(34):
            px, py = 0.285 + rn.random() * 0.35, bin_y0 + 0.025 + rn.random() * 0.14
            s.box(px, py, 0.11 + rn.random() * 0.02, px + 0.025 + rn.random() * 0.03, py + 0.02 + rn.random() * 0.02,
                  0.13 + rn.random() * 0.03, rn.choice([(170, 160, 130), (150, 70, 50), (70, 100, 150), (200, 190, 170), (120, 124, 128), (90, 130, 80)]))
    # the control box on the cabinet's front, left: lamps, the stop button, a label
    s.box(0.14, y1, 0.24, 0.26, y1 + 0.04, 0.42, GRAPHITE_DARK, top=GRAPHITE, shine=0.2)
    lamp_y(s, glows, 0.185, y1 + 0.04, 0.37, 0.016, 'green', running)
    lamp_y(s, glows, 0.22, y1 + 0.04, 0.37, 0.016, 'red', not running)
    s.tube((0.20, y1 + 0.04, 0.29), (0.20, y1 + 0.075, 0.29), 0.026, YELLOW, segments=16)
    s.tube((0.20, y1 + 0.075, 0.29), (0.20, y1 + 0.092, 0.29), 0.022, RED, cap=(220, 70, 56), segments=16, shine=0.3)
    # a beacon on a post at the north-west corner
    s.tube((x0 + 0.03, y0 + 0.03, zb), (x0 + 0.03, y0 + 0.03, zb + 0.62), 0.009, STEEL_DARK, segments=8)
    s.tube((x0 + 0.03, y0 + 0.03, zb + 0.62), (x0 + 0.03, y0 + 0.03, zb + 0.64), 0.03, BEZEL, segments=14)
    if running:
        s.tube((x0 + 0.03, y0 + 0.03, zb + 0.64), (x0 + 0.03, y0 + 0.03, zb + 0.70), 0.026, LIT['amber'], cap=(255, 240, 200), segments=14, emit=True)
        glows.append(((x0 + 0.03, y0 + 0.03, zb + 0.68), LIT['amber'], 0.2))
    else:
        s.tube((x0 + 0.03, y0 + 0.03, zb + 0.64), (x0 + 0.03, y0 + 0.03, zb + 0.70), 0.026, UNLIT['amber'], segments=14, shine=0.8)
    # lettering
    front_decal(s, 0.30, 0.74, 0.12, 0.22, y1 + 0.001, stencil_text('SHREDDER', 80, 20, STENCIL), offset=0.0)
    front_decal(s, 0.42, 0.56, 0.28, 0.42, y1 + 0.001, acorn_mark(28, STENCIL), offset=0.0)
    ground = shadow((0.55, 0.52), 0.5, 0.36, 125)
    return compose(s, ground=ground, seed=110 + turns + (4 if running else 0), glows=glows)


def cutting_mat_image(w=176, h=84):
    img = Image.new('RGBA', (w, h), (52, 104, 76, 255))
    d = ImageDraw.Draw(img)
    for x in range(0, w, 8):
        d.line([(x, 0), (x, h)], fill=(190, 214, 196, 255) if x % 40 == 0 else (82, 136, 104, 255), width=1)
    for y in range(0, h, 8):
        d.line([(0, y), (w, y)], fill=(190, 214, 196, 255) if y % 40 == 0 else (82, 136, 104, 255), width=1)
    d.rectangle([0, 0, w - 1, h - 1], outline=(30, 60, 44, 255))
    return img


def cutter(turns, running):
    """The cutter: a long cutting table with a green grid mat, a roll of canvas on arms at its west end, and a gantry
    with a blade carriage over the mat. Stopped: the carriage waits at the west end, the cloth is whole. Running: the carriage
    is mid-table, its lamp lit, and the cloth behind it is cut in two."""
    s = Scene(turns)
    glows = []
    x0, x1, y0, y1 = 0.18, 0.94, 0.26, 0.74
    zt = 0.46
    for lx in (x0 + 0.02, x1 - 0.06):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx, ly, 0.0, lx + 0.04, ly + 0.04, zt, GRAPHITE_DARK, shine=0.2)
    s.box(x0, y0, 0.12, x1, y1, 0.14, GRAPHITE_DARK)
    s.box(x0, y0, zt, x1, y1, zt + 0.045, OD_DARK, top=OD_DARK)
    s.box(x0 + 0.015, y0 + 0.015, zt + 0.045, x1 - 0.015, y1 - 0.015, zt + 0.055, (30, 60, 44))
    flat_decal(s, x0 + 0.015, y0 + 0.015, x1 - 0.015, y1 - 0.015, zt + 0.055, cutting_mat_image(), offset=0.001)
    # a rack of spare rolls under the table
    for i, c in enumerate(((176, 70, 56), (72, 110, 160), (200, 190, 150))):
        s.tube((x0 + 0.12 + i * 0.22, y0 + 0.03, 0.22), (x0 + 0.12 + i * 0.22, y1 - 0.03, 0.22), 0.07, c, cap=(220, 214, 190), segments=18)
    # the roll of canvas on two arms at the west end
    s.box(0.06, y0 - 0.02, 0.0, 0.14, y0 + 0.03, 0.80, GRAPHITE_DARK)
    s.box(0.06, y1 - 0.03, 0.0, 0.14, y1 + 0.02, 0.80, GRAPHITE_DARK)
    s.tube((0.10, y0, 0.66), (0.10, y1, 0.66), 0.015, STEEL, shine=0.6, segments=10)
    s.tube((0.10, y0 + 0.04, 0.66), (0.10, y1 - 0.04, 0.66), 0.13, CANVAS, cap=(210, 200, 170), segments=28,
           bands=[(0, 0.06, (110, 104, 80))] + [(0.06 + 0.06 * i, 0.09 + 0.06 * i, (170, 160, 122)) for i in range(15)])
    # the cloth leaving the roll over the table
    cloth_z = zt + 0.058
    cut = running
    gx = 0.56 if running else 0.30       # the gantry's place along the table
    s.poly([(0.17, y0 + 0.03, 0.62), (0.26, y0 + 0.03, cloth_z), (0.26, y1 - 0.03, cloth_z), (0.17, y1 - 0.03, 0.62)], CANVAS, (0, 0, 1), shine=0.0)
    s.face([(0.26, y0 + 0.03, cloth_z), (x1 - 0.06, y0 + 0.03, cloth_z), (x1 - 0.06, y1 - 0.03, cloth_z), (0.26, y1 - 0.03, cloth_z)], CANVAS, (0, 0, 1))
    if running:
        # the cut: a dark line behind the gantry, the two cloth halves a little apart; a cut-off strip beyond
        s.face([(0.26, 0.49, cloth_z + 0.001), (gx, 0.49, cloth_z + 0.001), (gx, 0.51, cloth_z + 0.001), (0.26, 0.51, cloth_z + 0.001)], (36, 70, 52), (0, 0, 1))
        s.box(gx + 0.12, y0 + 0.03, cloth_z, gx + 0.20, y1 - 0.03, cloth_z + 0.004, (190, 70, 56))
    # the gantry: two posts at the table's long edges, a cross beam, the carriage with the knife on a rail
    for yy in (y0 - 0.03, y1 + 0.0):
        s.box(gx - 0.03, yy, zt + 0.02, gx + 0.03, yy + 0.03, 0.78, OD, top=OD_LIGHT, shine=0.1)
    s.box(gx - 0.04, y0 - 0.03, 0.74, gx + 0.04, y1 + 0.03, 0.80, OD, top=OD_LIGHT, shine=0.1)
    s.tube((gx, y0 - 0.02, 0.72), (gx, y1 + 0.02, 0.72), 0.012, STEEL, shine=0.6, segments=8)
    cy = 0.50 if running else 0.35
    s.box(gx - 0.05, cy - 0.06, 0.60, gx + 0.05, cy + 0.06, 0.74, GRAPHITE_DARK, top=GRAPHITE, shine=0.2)
    s.box(gx - 0.012, cy - 0.015, cloth_z, gx + 0.012, cy + 0.015, 0.60, STEEL, shine=0.7)
    s.poly([(gx - 0.012, cy + 0.016, cloth_z), (gx + 0.012, cy + 0.016, cloth_z), (gx + 0.012, cy + 0.016, 0.58), (gx - 0.012, cy + 0.016, 0.58)], (220, 224, 226), (0, 1, 0), shine=0.8)
    lamp_y(s, glows, gx, cy + 0.06, 0.69, 0.014, 'green', running)
    lamp_y(s, glows, gx, cy + 0.06, 0.64, 0.012, 'amber', False)
    # a control pedestal at the east end of the table
    s.box(0.86, y1 + 0.0, 0.0, 0.94, y1 + 0.1, 0.52, OD, top=OD_LIGHT, shine=0.1)
    lamp_y(s, glows, 0.90, y1 + 0.1, 0.44, 0.014, 'green', running)
    lamp_y(s, glows, 0.90, y1 + 0.1, 0.38, 0.014, 'red', not running)
    s.box(0.87, y1 + 0.1, 0.22, 0.93, y1 + 0.104, 0.32, GRAPHITE_DARK)
    front_decal(s, x0 + 0.04, x0 + 0.30, 0.20, 0.30, y1 + 0.001, stencil_text('CUTTER', 60, 20, STENCIL), offset=0.0)
    ground = shadow((0.52, 0.5), 0.5, 0.34, 120)
    return compose(s, ground=ground, seed=120 + turns + (4 if running else 0), glows=glows)


def propane_refiner(turns, running):
    """The propane refiner: a tall cream process column on a skid, a bullet tank and two bottles with their pipes and
    red valve wheels, a pressure gauge and a control lamp. Running: a flare burns at the top of its stack, the gauge
    stands high and the lamp is green."""
    s = Scene(turns)
    glows = []
    x0, x1, y0, y1 = 0.08, 0.92, 0.18, 0.82
    s.box(x0, y0, 0.0, x1, y1, 0.07, GRAPHITE_DARK, top=GRAPHITE, shine=0.15)
    # hazard edge round the skid
    front_decal(s, x0, x1, 0.0, 0.07, y1 + 0.001, hazard_strip(176, 12, YELLOW, (30, 30, 28), 7), offset=0.0)
    # the column: a tall cylinder with a domed top, blue bands, rings
    cx, cy, r = 0.34, 0.40, 0.19
    s.tube((cx, cy, 0.07), (cx, cy, 1.02), r, CREAM, cap=CREAM, segments=40, shine=0.25,
           bands=[(0, 0.04, CREAM_DARK), (0.04, 0.30, CREAM), (0.30, 0.34, BLUE), (0.34, 0.62, CREAM), (0.62, 0.66, BLUE),
                  (0.66, 0.96, CREAM), (0.96, 1.0, CREAM_DARK)])
    s.sphere((cx, cy, 1.02), (r, r, 0.11), CREAM, rings=5, segments=40, z_from=0, z_to=90, shine=0.25)
    s.tube((cx, cy, 1.12), (cx, cy, 1.18), 0.03, STEEL_DARK, segments=12, shine=0.4)
    # a ladder on the column's east side
    for i in range(10):
        s.tube((cx + r + 0.01, cy - 0.04, 0.2 + i * 0.07), (cx + r + 0.01, cy + 0.04, 0.2 + i * 0.07), 0.005, STEEL_DARK, segments=5)
    s.tube((cx + r + 0.01, cy - 0.04, 0.2), (cx + r + 0.01, cy - 0.04, 0.9), 0.006, STEEL_DARK, segments=6)
    s.tube((cx + r + 0.01, cy + 0.04, 0.2), (cx + r + 0.01, cy + 0.04, 0.9), 0.006, STEEL_DARK, segments=6)
    # gauge on the column's south side
    gz = 0.72
    front_decal(s, cx - 0.06, cx + 0.06, gz - 0.06, gz + 0.06, cy + r + 0.005, gauge_image(0.78 if running else 0.12), offset=0.0)
    s.tube((cx, cy + r, gz), (cx, cy + r + 0.012, gz), 0.075, BEZEL, segments=20)
    front_decal(s, cx - 0.06, cx + 0.06, gz - 0.06, gz + 0.06, cy + r + 0.013, gauge_image(0.78 if running else 0.12), offset=0.0)
    # stencil
    front_decal(s, cx - 0.12, cx + 0.12, 0.35, 0.47, cy + r + 0.001, stencil_text('PROPANE', 60, 16, (40, 70, 130)), offset=0.0)
    # the bullet tank lying along x in front
    ty = 0.67
    s.tube((0.40, ty, 0.30), (0.86, ty, 0.30), 0.13, (214, 212, 200), cap=(190, 188, 176), segments=32, shine=0.35,
           bands=[(0, 0.5, (214, 212, 200)), (0.5, 0.56, BLUE), (0.56, 1, (214, 212, 200))])
    s.sphere((0.40, ty, 0.30), (0.08, 0.13, 0.13), (200, 198, 186), rings=6, segments=32, z_from=-90, z_to=90, shine=0.35)
    s.box(0.46, ty - 0.1, 0.07, 0.50, ty + 0.1, 0.19, GRAPHITE_DARK)
    s.box(0.76, ty - 0.1, 0.07, 0.80, ty + 0.1, 0.19, GRAPHITE_DARK)
    s.tube((0.62, ty, 0.43), (0.62, ty, 0.50), 0.035, STEEL_DARK, segments=14, shine=0.4)
    valve_wheel(s, (0.62, ty, 0.55), 0.045, RED, axis='x')
    # the pipes from the tank to the column
    s.tube((0.62, ty, 0.50), (0.62, 0.52, 0.50), 0.014, PIPE, segments=8, shine=0.4)
    s.tube((0.62, 0.52, 0.50), (cx + r * 0.7, 0.52, 0.50), 0.014, PIPE, segments=8, shine=0.4)
    s.tube((0.50, 0.40, 0.2), (cx + r, 0.40, 0.2), 0.014, PIPE, segments=8, shine=0.4)
    # two bottles beside the tank
    for bx, col in ((0.70, (176, 70, 52)), (0.82, (176, 70, 52))):
        s.tube((bx, 0.40, 0.07), (bx, 0.40, 0.46), 0.062, col, cap=col, segments=22, shine=0.3)
        s.sphere((bx, 0.40, 0.46), (0.062, 0.062, 0.04), col, rings=3, segments=22, z_from=0, z_to=90, shine=0.3)
        s.tube((bx, 0.40, 0.50), (bx, 0.40, 0.56), 0.016, STEEL, segments=8, shine=0.6)
        s.tube((bx, 0.40, 0.56), (bx - 0.01, 0.40, 0.58), 0.026, BRASS, segments=10, shine=0.6)
    s.tube((0.70, 0.40, 0.2), (0.82, 0.40, 0.2), 0.045, (220, 214, 190), segments=22, cap=(220, 214, 190))
    # the control box on the skid's front-left, with its lamp
    s.box(0.12, 0.74, 0.07, 0.30, 0.82, 0.32, OD, top=OD_LIGHT, shine=0.1)
    lamp_y(s, glows, 0.17, 0.82, 0.27, 0.016, 'green', running)
    lamp_y(s, glows, 0.23, 0.82, 0.27, 0.016, 'amber', False)
    s.box(0.15, 0.82, 0.12, 0.27, 0.824, 0.20, GRAPHITE_DARK)
    # the flare stack: a thin pipe rising from the column's top to a tip, a flame when running
    sx, sy = 0.50, 0.28
    s.tube((cx, cy, 1.12), (cx, cy, 1.14), 0.03, STEEL_DARK, segments=8)
    s.tube((sx, sy, 0.07), (sx, sy, 1.18), 0.022, GRAPHITE, segments=12, shine=0.3)
    s.tube((sx, sy, 1.18), (sx, sy, 1.24), 0.032, GRAPHITE_DARK, r2=0.02, segments=12)
    s.tube((cx + r * 0.9, cy, 0.9), (sx, sy, 0.9), 0.014, PIPE, segments=8)
    s.tube((sx, sy, 0.9), (sx, sy, 0.92), 0.02, STEEL, segments=8)

    def flame(big):
        # drawn above the tile's solid parts
        def over(img):
            d = ImageDraw.Draw(img)
            px, py = project(sx, sy, 1.24)
            for (scale, col) in ((1.0, (255, 120, 30, 190)), (0.7, (255, 190, 60, 230)), (0.4, (255, 250, 200, 255))):
                h = 22 * SS * scale * big
                w = 8 * SS * scale * big
                d.polygon([(px, py - h), (px + w, py - h * 0.25), (px + w * 0.5, py), (px - w * 0.5, py), (px - w, py - h * 0.25)], fill=col)
        return over
    over = flame(1.0) if running else None
    if running:
        glows.append(((sx, sy, 1.30), FLAME, 0.22))
    ground = shadow((0.5, 0.5), 0.52, 0.4, 125)
    return compose(s, ground=ground, over=over, seed=130 + turns + (4 if running else 0), glows=glows)


def oil_refiner(turns, running):
    """The oil refiner: a graphite horizontal vessel on a frame, a slim fractionating column with a stack of bands, a pipe
    run between them with a yellow valve wheel, a drum under the draw-off tap and a control box. Running: amber and green
    lamps lit, steam above the column, oil running into the drum."""
    s = Scene(turns)
    glows = []
    x0, x1, y0, y1 = 0.08, 0.92, 0.18, 0.82
    s.box(x0, y0, 0.0, x1, y1, 0.06, GRAPHITE_DARK, top=GRAPHITE, shine=0.15)
    front_decal(s, x0, x1, 0.0, 0.06, y1 + 0.001, hazard_strip(176, 12, YELLOW, (30, 30, 28), 7), offset=0.0)
    # the frame and the horizontal vessel
    for fx in (0.20, 0.50):
        s.box(fx, 0.22, 0.06, fx + 0.04, 0.34, 0.38, GRAPHITE_DARK, shine=0.1)
        s.box(fx, 0.46, 0.06, fx + 0.04, 0.58, 0.38, GRAPHITE_DARK, shine=0.1)
    s.tube((0.14, 0.40, 0.50), (0.62, 0.40, 0.50), 0.17, GRAPHITE_LIGHT, cap=GRAPHITE, segments=36, shine=0.5,
           bands=[(0, 0.04, GRAPHITE), (0.04, 0.46, GRAPHITE_LIGHT), (0.46, 0.50, GRAPHITE), (0.50, 0.96, GRAPHITE_LIGHT), (0.96, 1, GRAPHITE)])
    s.sphere((0.14, 0.40, 0.50), (0.06, 0.17, 0.17), GRAPHITE, rings=6, segments=36, z_from=-90, z_to=90, shine=0.4)
    s.sphere((0.62, 0.40, 0.50), (0.06, 0.17, 0.17), GRAPHITE, rings=6, segments=36, z_from=-90, z_to=90, shine=0.4)
    front_decal(s, 0.20, 0.52, 0.42, 0.54, 0.40 + 0.17, stencil_text('OIL', 36, 14, STENCIL), offset=0.0)
    # the manway on top and a breather
    s.tube((0.32, 0.40, 0.66), (0.32, 0.40, 0.72), 0.05, GRAPHITE, cap=GRAPHITE_DARK, segments=18, shine=0.3)
    s.tube((0.32, 0.40, 0.72), (0.32, 0.40, 0.74), 0.06, STEEL_DARK, cap=STEEL, segments=18, shine=0.5)
    # the column: slim, tall, with bands and rings, a vent
    cx, cy, r = 0.79, 0.38, 0.1
    s.tube((cx, cy, 0.06), (cx, cy, 1.15), r, GRAPHITE_LIGHT, cap=GRAPHITE, segments=28, shine=0.45,
           bands=[(0, 0.2, GRAPHITE_LIGHT), (0.2, 0.23, YELLOW), (0.23, 0.48, GRAPHITE_LIGHT), (0.48, 0.51, YELLOW),
                                      (0.51, 0.75, GRAPHITE_LIGHT), (0.75, 0.78, YELLOW), (0.78, 1, GRAPHITE_LIGHT)])
    s.sphere((cx, cy, 1.15), (r, r, 0.06), GRAPHITE, rings=4, segments=28, z_from=0, z_to=90, shine=0.4)
    for z in (0.3, 0.6, 0.9):
        s.tube((cx, cy, z), (cx, cy, z + 0.025), r + 0.02, GRAPHITE_DARK, segments=28, shine=0.2)
    s.tube((cx, cy, 1.2), (cx, cy, 1.3), 0.012, STEEL_DARK, segments=6)
    # the pipe run: vessel -> column, a valve wheel
    s.tube((0.62, 0.40, 0.50), (0.66, 0.40, 0.50), 0.035, STEEL_DARK, segments=14, shine=0.4)
    s.tube((0.66, 0.40, 0.50), (cx - r, 0.40, 0.50), 0.022, PIPE, segments=10, shine=0.4)
    s.tube((0.68, 0.40, 0.50), (0.68, 0.40, 0.58), 0.012, STEEL, segments=6)
    valve_wheel(s, (0.68, 0.40, 0.60), 0.04, YELLOW, axis='x')
    # draw-off pipes down the column's south side to taps
    for z, tx in ((0.28, 0.0), (0.6, 0.0)):
        s.tube((cx, cy + r, z), (cx, cy + r + 0.06, z), 0.016, PIPE, segments=8, shine=0.4)
    s.tube((cx, cy + r + 0.06, 0.28), (cx, cy + r + 0.06, 0.14), 0.016, PIPE, segments=8, shine=0.4)
    s.tube((cx, cy + r + 0.06, 0.14), (cx, cy + r + 0.06, 0.12), 0.026, BRASS, segments=10, shine=0.5)
    # the drum under the tap
    dx, dy = cx, cy + r + 0.06
    s.tube((dx, dy + 0.02, 0.06), (dx, dy + 0.02, 0.30), 0.085, (30, 32, 34), cap=(20, 22, 24), segments=22, shine=0.35,
           bands=[(0, 0.08, (24, 26, 28)), (0.08, 0.3, (34, 36, 38)), (0.3, 0.34, (24, 26, 28)), (0.34, 0.66, (34, 36, 38)),
                  (0.66, 0.7, (24, 26, 28)), (0.7, 0.92, (34, 36, 38)), (0.92, 1, (24, 26, 28))])
    disc(s, (dx, dy + 0.02), 0.07, 0.301, (14, 14, 14) if not running else (60, 40, 14), segments=22, shine=0.7)
    if running:
        s.tube((dx, dy, 0.12), (dx, dy, 0.30), 0.006, (40, 28, 10), segments=6, shine=0.7)
    # the control box on the skid front-left
    s.box(0.12, 0.70, 0.06, 0.34, 0.80, 0.34, OD, top=OD_LIGHT, shine=0.1)
    lamp_y(s, glows, 0.17, 0.80, 0.29, 0.016, 'green', running)
    lamp_y(s, glows, 0.23, 0.80, 0.29, 0.016, 'amber', running)
    lamp_y(s, glows, 0.29, 0.80, 0.29, 0.016, 'red', False)
    s.box(0.15, 0.80, 0.12, 0.31, 0.804, 0.22, GRAPHITE_DARK)

    def steam(img):
        d = ImageDraw.Draw(img, 'RGBA')
        px, py = project(cx, cy, 1.32)
        rn = random.Random(5)
        for i in reversed(range(9)):
            r_ = (5 + i * 1.4) * SS
            ox = (rn.random() - 0.5) * 6 * SS + i * 0.8 * SS
            oy = -i * 7 * SS
            a = max(30, 175 - i * 18)
            d.ellipse([px + ox - r_, py + oy - r_, px + ox + r_, py + oy + r_], fill=STEAM + (a,))
    if running:
        glows.append(((dx, dy, 0.22), (255, 150, 30), 0.1))
    ground = shadow((0.5, 0.5), 0.52, 0.4, 125)
    return compose(s, ground=ground, over=steam if running else None, seed=140 + turns + (4 if running else 0), glows=glows)
