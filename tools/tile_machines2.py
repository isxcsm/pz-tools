"""More machines: the wood saw, the research storage, the big rain storage and the installable lure (see
tile_machines.py)."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import Scene, shadow, compose, rotation, stencil_text, acorn_mark, project, SS
from tile_objects import (OD, OD_DARK, OD_LIGHT, BLACK, RUBBER, STEEL, STEEL_DARK, STENCIL, RED, BRASS, BLUE, LIT, UNLIT,
                          BEZEL, lamp_y, front_decal, side_decal, flat_decal)
from tile_machines import (GRAPHITE, GRAPHITE_DARK, ring_top, disc)


def saw_blade(s, cx, y, cz, r, colour=(190, 194, 198)):
    """A circular saw blade standing in a plane of constant y (its flat face looks south): teeth round the rim."""
    teeth = 30
    pts = []
    for i in range(teeth * 2):
        a = 2 * math.pi * i / (teeth * 2)
        rr = r if i % 2 == 0 else r * 0.9
        pts.append((cx + rr * math.cos(a), y, cz + rr * math.sin(a)))
    s.poly(pts, colour, (0, 1, 0), shine=0.7)
    for rr, col in ((r * 0.62, (150, 154, 158)), (r * 0.18, (60, 62, 64))):
        s.face([(cx + rr * math.cos(2 * math.pi * i / 24), y + 0.002, cz + rr * math.sin(2 * math.pi * i / 24))
                for i in range(24)], col, (0, 1, 0), 0.5)


def wood_saw(turns, running):
    """The wood saw: a table saw on a steel stand with a motor, the blade up through the table, a log on the infeed
    side and cut boards stacked at the outfeed end, a switch box with its lamp. Running: the blade is a bright blur
    with sparks and chips flying, the lamp is green."""
    s = Scene(turns)
    glows = []
    x0, x1, y0, y1 = 0.06, 0.94, 0.24, 0.76
    zt = 0.46
    for lx in (x0 + 0.02, x1 - 0.06):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx, ly, 0.0, lx + 0.045, ly + 0.045, zt, OD_DARK, shine=0.1)
    s.box(x0, y0, zt - 0.04, x1, y1, zt, OD_DARK)
    s.box(x0 - 0.01, y0 - 0.01, zt, x1 + 0.01, y1 + 0.01, zt + 0.04, GRAPHITE, top=(132, 136, 140), shine=0.35)
    s.tube((0.40, 0.50, 0.22), (0.62, 0.50, 0.22), 0.10, BLUE, cap=(34, 66, 94), segments=24, shine=0.2)
    s.box(0.34, 0.40, 0.12, 0.66, 0.60, 0.15, GRAPHITE_DARK)
    s.box(0.38, 0.30, zt + 0.04, 0.62, 0.70, zt + 0.045, (60, 62, 64))
    s.box(x0, y0 + 0.02, zt + 0.04, x1, y0 + 0.08, zt + 0.12, OD, top=OD_LIGHT, shine=0.2)
    bz = zt + 0.08
    s.box(0.44, 0.52, zt + 0.045, 0.56, 0.60, zt + 0.30, OD_DARK, top=OD, shine=0.15)
    saw_blade(s, 0.50, 0.505, bz + 0.07, 0.17, (210, 214, 218) if running else (172, 176, 180))
    if running:
        rn = random.Random(2)
        for i in range(16):
            ang = rn.random() * math.pi
            d = 0.9 + rn.random() * 1.0
            px = max(0.1, min(0.9, 0.50 + 0.17 * math.cos(ang) * d))
            pz = bz + 0.07 + 0.17 * math.sin(ang) * d
            y = 0.40 + rn.random() * 0.1
            s.box(px, y, pz, px + 0.016, y + 0.02, pz + 0.014, (230, 190, 120), emit=True)
        glows.append(((0.50, 0.50, bz + 0.07), (255, 230, 170), 0.2, (0, 1, 0)))
    for i in range(14):
        rn = random.Random(40 + i)
        px, py = 0.34 + rn.random() * 0.34, 0.56 + rn.random() * 0.26
        if running or i < 7:
            s.box(px, py, 0.0, px + 0.05, py + 0.04, 0.018, (214, 176, 118))
    for lx in (0.14, 0.30):
        s.box(lx, 0.34, zt + 0.045, lx + 0.025, 0.66, zt + 0.12, GRAPHITE_DARK)
    s.tube((0.08, 0.50, zt + 0.18), (0.36, 0.50, zt + 0.18), 0.075, (96, 70, 46), cap=(196, 156, 100), segments=22)
    for i in range(4):
        s.box(0.70, 0.34, zt + 0.045 + i * 0.026, 0.92, 0.66, zt + 0.07 + i * 0.026,
              (206, 168, 112) if i % 2 else (190, 152, 98), top=(224, 186, 130))
    s.box(0.12, y1, 0.14, 0.24, y1 + 0.05, 0.34, OD, top=OD_LIGHT, shine=0.1)
    lamp_y(s, glows, 0.15, y1 + 0.05, 0.30, 0.015, 'green', running)
    lamp_y(s, glows, 0.21, y1 + 0.05, 0.30, 0.015, 'red', not running)
    s.tube((0.18, y1 + 0.05, 0.20), (0.18, y1 + 0.07, 0.20), 0.025, RED if not running else (80, 80, 80), segments=14,
           shine=0.3)
    s.box(x0 + 0.02, y1 - 0.04, zt - 0.14, x1 - 0.02, y1 - 0.01, zt - 0.04, OD_DARK)
    front_decal(s, 0.40, 0.84, zt - 0.13, zt - 0.05, y1 - 0.009, stencil_text('SAW', 44, 14, STENCIL), offset=0.0)
    ground = shadow((0.5, 0.5), 0.52, 0.36, 125)
    return compose(s, ground=ground, seed=150 + turns + (4 if running else 0), glows=glows)


def research_storage(turns):
    """The research storage: a tall olive locker with two doors, vents, a hasp and padlock, the team's mark and
    stencilled lettering, on feet. Its doors face south."""
    s = Scene(turns)
    x0, x1, y0, y1 = 0.12, 0.88, 0.24, 0.76
    zt = 1.24
    for fx in (x0 + 0.02, x1 - 0.08):
        for fy in (y0 + 0.02, y1 - 0.08):
            s.box(fx, fy, 0.0, fx + 0.06, fy + 0.06, 0.06, GRAPHITE_DARK)
    s.box(x0, y0, 0.06, x1, y1, zt, OD, top=OD_LIGHT, shine=0.1)
    s.box(x0 - 0.01, y0 - 0.01, 0.06, x1 + 0.01, y1 + 0.01, 0.12, OD_DARK)
    s.box(x0 - 0.012, y0 - 0.012, zt - 0.05, x1 + 0.012, y1 + 0.012, zt, OD_DARK, top=OD_DARK)
    f = y1 + 0.006
    mid = (x0 + x1) / 2
    s.box(x0 + 0.03, y1, 0.16, mid - 0.004, f, zt - 0.08, OD_LIGHT, shine=0.1)
    s.box(mid + 0.004, y1, 0.16, x1 - 0.03, f, zt - 0.08, OD_LIGHT, shine=0.1)
    s.box(mid - 0.004, y1, 0.14, mid + 0.004, f, zt - 0.06, BLACK)
    for dx0, dx1 in ((x0 + 0.06, mid - 0.04), (mid + 0.04, x1 - 0.06)):
        for z in (0.3, 0.55):
            s.box(dx0, f, z, dx1, f + 0.01, z + 0.012, OD_DARK)
        for i in range(5):
            s.box(dx0 + 0.01, f, zt - 0.2 + i * 0.026, dx1 - 0.01, f + 0.008, zt - 0.2 + i * 0.026 + 0.012, (24, 26, 24))
    s.box(mid - 0.07, f, 0.62, mid - 0.055, f + 0.03, 0.82, STEEL_DARK, shine=0.5)
    s.box(mid + 0.055, f, 0.62, mid + 0.07, f + 0.03, 0.82, STEEL_DARK, shine=0.5)
    s.box(mid - 0.07, f + 0.03, 0.66, mid + 0.07, f + 0.045, 0.70, STEEL, shine=0.6)
    s.box(mid - 0.03, f + 0.045, 0.56, mid + 0.03, f + 0.075, 0.66, BRASS, shine=0.7)
    s.tube((mid, f + 0.06, 0.66), (mid, f + 0.06, 0.72), 0.02, STEEL, segments=10, shine=0.7)
    front_decal(s, x0 + 0.08, mid - 0.06, 0.88, 1.02, f + 0.01, stencil_text('OAK', 40, 22, STENCIL), offset=0.0)
    front_decal(s, mid + 0.05, mid + 0.22, 0.86, 1.04, f + 0.01, acorn_mark(34, STENCIL), offset=0.0)
    front_decal(s, x0 + 0.06, x1 - 0.06, 0.20, 0.27, f + 0.01, stencil_text('RESEARCH', 100, 12, STENCIL), offset=0.0)
    for i in range(5):
        s.box(x1, y0 + 0.06, 0.2 + i * 0.2, x1 + 0.01, y1 - 0.06, 0.22 + i * 0.2, OD_DARK)
    side_decal(s, y0 + 0.12, y1 - 0.12, 0.56, 0.72, x1 + 0.012, stencil_text('OAK-R', 52, 20, STENCIL), offset=0.0)
    ground = shadow((0.5, 0.5), 0.46, 0.34, 125)
    return compose(s, ground=ground, seed=160 + turns, glows=[])


def rain_storage():
    """The big rain storage: an open-topped round plastic tank, blue and ribbed, a thick rim, rain water standing
    inside, a brass tap low on its south side and an overflow stub."""
    s = Scene(0)
    cx, cy, r, h = 0.5, 0.5, 0.40, 0.80
    PLASTIC = (58, 104, 150)
    PLASTIC_DARK = (40, 76, 114)
    PLASTIC_LIGHT = (140, 176, 206)
    s.tube((cx, cy, 0.02), (cx, cy, h), r - 0.025, (78, 92, 104), segments=44, inward=True)
    bands = []
    n = 6
    for i in range(n):
        bands.append((i / n, i / n + 0.78 / n, PLASTIC))
        bands.append((i / n + 0.78 / n, (i + 1) / n, PLASTIC_DARK))
    s.tube((cx, cy, 0.0), (cx, cy, h), r, PLASTIC, segments=44, bands=bands, shine=0.3, caps=False)
    s.tube((cx, cy, h - 0.05), (cx, cy, h + 0.015), r + 0.02, PLASTIC_LIGHT, segments=44, shine=0.35, caps=False)
    ring_top(s, (cx, cy), r - 0.04, r + 0.02, h + 0.015, PLASTIC_LIGHT, segments=44, shine=0.35)
    wz = h - 0.26
    disc(s, (cx, cy), r - 0.03, wz, (52, 150, 176), segments=44, shine=0.9)
    glint = Image.new('RGBA', (128, 128), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glint)
    gd.ellipse([20, 28, 70, 52], fill=(190, 226, 250, 150))
    gd.ellipse([74, 70, 104, 82], fill=(190, 226, 250, 110))
    flat_decal(s, cx - r + 0.05, cy - r + 0.05, cx + r - 0.05, cy + r - 0.05, wz, glint, offset=0.002)
    for lx, ly, rot in ((0.42, 0.55, 20), (0.58, 0.42, 70)):
        s.xbox((lx, ly, wz + 0.004), (0.06, 0.03, 0.006), rotation((0, 0, 1), rot), (120, 130, 60), top=(138, 150, 70))
    tx, ty = cx + r * 0.52, cy + r * 0.85
    s.tube((tx, ty - 0.01, 0.16), (tx + 0.03, ty + 0.07, 0.16), 0.03, BRASS, segments=12, shine=0.6)
    s.tube((tx + 0.03, ty + 0.07, 0.16), (tx + 0.03, ty + 0.07, 0.10), 0.026, BRASS, segments=12, shine=0.6)
    s.tube((tx + 0.0, ty + 0.03, 0.19), (tx + 0.0, ty + 0.03, 0.235), 0.012, STEEL, segments=8, shine=0.6)
    s.box(tx - 0.035, ty + 0.03, 0.232, tx + 0.035, ty + 0.045, 0.248, RED)
    ox, oy = cx + r * 0.97, cy
    s.tube((ox - 0.02, oy, h - 0.12), (ox + 0.08, oy, h - 0.12), 0.035, PLASTIC_DARK, segments=14, shine=0.3)
    s.tube((ox + 0.08, oy, h - 0.12), (ox + 0.08, oy, h - 0.22), 0.035, PLASTIC_DARK, segments=14, shine=0.3)
    ground = shadow((0.5, 0.5), 0.46, 0.38, 125)
    return compose(s, ground=ground, seed=170, glows=[])


def lure(on):
    """The installable lure: a field loudspeaker on a short tripod, two horns up on its mast, a battery box with a
    lamp at its foot and an antenna. On: the lamp and the beacon are lit and sound rings spread out from the horns."""
    s = Scene(0)
    glows = []
    cx, cy = 0.5, 0.5
    for ang in (90, 210, 330):
        a = math.radians(ang)
        s.tube((cx + 0.2 * math.cos(a), cy + 0.2 * math.sin(a), 0.0), (cx, cy, 0.5), 0.012, STEEL_DARK, segments=8,
               shine=0.4)
        s.box(cx + 0.2 * math.cos(a) - 0.025, cy + 0.2 * math.sin(a) - 0.025, 0.0, cx + 0.2 * math.cos(a) + 0.025,
              cy + 0.2 * math.sin(a) + 0.025, 0.012, RUBBER)
    s.tube((cx, cy, 0.45), (cx, cy, 0.58), 0.03, GRAPHITE_DARK, segments=14, shine=0.3)
    s.tube((cx, cy, 0.58), (cx, cy, 0.95), 0.014, GRAPHITE, segments=10, shine=0.4)
    s.box(cx - 0.05, cy - 0.05, 0.86, cx + 0.05, cy + 0.05, 0.92, OD, top=OD_LIGHT, shine=0.1)
    for (ax, ay) in ((0.12, 0.10), (-0.12, -0.10)):
        s.tube((cx, cy, 0.89), (cx + ax * 0.6, cy + ay * 0.6, 0.89), 0.02, GRAPHITE, segments=8)
        s.tube((cx + ax * 0.6, cy + ay * 0.6, 0.89), (cx + ax * 1.3, cy + ay * 1.3, 0.97), 0.03, GRAPHITE, r2=0.10,
               cap=(20, 22, 24), segments=24, shine=0.35)
    s.tube((cx, cy, 0.92), (cx, cy, 1.1), 0.008, STEEL, r2=0.004, segments=6, shine=0.5)
    s.tube((cx, cy, 0.92), (cx, cy, 0.95), 0.03, BEZEL, segments=14)
    if on:
        s.tube((cx, cy, 0.95), (cx, cy, 1.0), 0.026, LIT['amber'], cap=(255, 240, 200), segments=14, emit=True)
        glows.append(((cx, cy, 0.98), LIT['amber'], 0.2))
    else:
        s.tube((cx, cy, 0.95), (cx, cy, 1.0), 0.026, UNLIT['amber'], segments=14, shine=0.8)
    s.box(0.58, 0.58, 0.0, 0.82, 0.74, 0.17, OD, top=OD_LIGHT, shine=0.1)
    front_decal(s, 0.60, 0.80, 0.04, 0.12, 0.741, stencil_text('LURE', 40, 12, STENCIL), offset=0.0)
    lamp_y(s, glows, 0.72, 0.74, 0.13, 0.013, 'green', on)
    s.tube((0.62, 0.62, 0.17), (0.62, 0.62, 0.24), 0.012, BLACK, segments=6)
    s.tube((0.62, 0.62, 0.24), (cx + 0.02, cy + 0.02, 0.5), 0.006, BLACK, segments=5)
    s.tube((0.76, 0.62, 0.17), (0.76, 0.62, 0.34), 0.008, STEEL, segments=6)

    def rings(img):
        d = ImageDraw.Draw(img, 'RGBA')
        for (hx, hy, hz) in ((cx + 0.15, cy + 0.12, 0.97), (cx - 0.15, cy - 0.12, 0.97)):
            px, py = project(hx, hy, hz)
            for i, rr in enumerate((16, 26, 36)):
                d.arc([px - rr * SS, py - rr * SS * 0.7, px + rr * SS, py + rr * SS * 0.7], -50, 50,
                      fill=(255, 220, 140, 220 - i * 55), width=int(2.4 * SS))
                d.arc([px - rr * SS, py - rr * SS * 0.7, px + rr * SS, py + rr * SS * 0.7], 130, 230,
                      fill=(255, 220, 140, 150 - i * 40), width=int(2.0 * SS))
    ground = shadow((0.5, 0.5), 0.3, 0.26, 105)
    return compose(s, ground=ground, over=rings if on else None, seed=180 + (1 if on else 0), glows=glows)
