"""Two-tile machines, part 2, and the big rain storage: the wood saw and the research storage (2 x 1), its stacking
crate (1 x 1), the rain storage (2 x 2). See tile_big1.py."""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from tile_engine import (OWNERS, Scene, shadow, compose, unit, rotation, apply, add, mul, stencil_text, acorn_mark, project,
                         SS, UP)
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, LIT, UNLIT, BEZEL, lamp, lamp_y,
                          front_decal, side_decal, back_decal, west_decal, flat_decal, noise_texture)
from tile_trade import hazard_strip, plank_lines
from tile_machines import GRAPHITE, GRAPHITE_DARK, GRAPHITE_LIGHT, double_poly, ring_top, disc, valve_wheel


def blade(s, cx, y, cz, r, colour, teeth=24):
    """A big circular saw blade standing in the plane y = const, seen from both sides: hooked teeth round the rim with
    deep gullets, a dark band where the teeth are set, the blade's polished body, expansion slots, an arbor flange and
    its bolts in the middle."""
    pts = []
    for i in range(teeth):
        a0 = 2 * math.pi * i / teeth
        step = 2 * math.pi / teeth
        # the tooth's tip, its hooked face falling to the gullet, the gullet's floor, the back rising to the next tip
        for da, rr in ((0.0, r), (step * 0.12, r * 0.84), (step * 0.35, r * 0.82), (step * 0.75, r * 0.95)):
            pts.append((cx + rr * math.cos(a0 + da), y, cz + rr * math.sin(a0 + da)))
    double_poly(s, pts, colour, colour, (0, 1, 0), shine=0.8)
    body = tuple(int(c * 0.82) for c in colour)
    band = tuple(int(c * 0.6) for c in colour)
    seg = 40
    for sign in (1, -1):
        def ring(rr, col, z=0.003):
            s.poly([(cx + rr * math.cos(2 * math.pi * i / seg), y + z * sign, cz + rr * math.sin(2 * math.pi * i / seg))
                    for i in range(seg)], col, (0, sign, 0), 0.5)
        ring(r * 0.8, band)
        ring(r * 0.74, body, 0.004)
        # expansion slots, from the band in toward the middle
        for k in range(4):
            a = 2 * math.pi * k / 4 + 0.3
            s.poly([(cx + rr * math.cos(a + da), y + 0.005 * sign, cz + rr * math.sin(a + da))
                    for rr, da in ((r * 0.78, -0.02), (r * 0.78, 0.02), (r * 0.6, 0.015), (r * 0.6, -0.015))],
                   band, (0, sign, 0), 0.3)
        ring(r * 0.26, STEEL_DARK, 0.006)
        ring(r * 0.1, (40, 40, 42), 0.008)
        for k in range(4):
            a = 2 * math.pi * k / 4 + 0.785
            bx, bz = cx + r * 0.18 * math.cos(a), cz + r * 0.18 * math.sin(a)
            s.poly([(bx + 0.012 * math.cos(2 * math.pi * i / 8), y + 0.009 * sign, bz + 0.012 * math.sin(2 * math.pi * i / 8))
                    for i in range(8)], STEEL, (0, sign, 0), 0.7)


def end_grain(size=96, seed=3):
    """A log's sawn end: pale wood with growth rings round an off-centre pith, a few checks, the bark's dark edge."""
    rn = random.Random(seed)
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = size / 2
    d.ellipse([1, 1, size - 2, size - 2], fill=(70, 50, 32, 255))
    d.ellipse([5, 5, size - 6, size - 6], fill=(206, 168, 112, 255))
    px, py = c + 4, c - 3
    for k in range(4, int(c) - 6, 4):
        tone = (176, 136, 86, 255) if (k // 4) % 2 else (190, 150, 98, 255)
        d.ellipse([px - k, py - k, px + k, py + k], outline=tone, width=2)
    for _ in range(3):
        a = rn.random() * 2 * math.pi
        d.line([(px, py), (px + math.cos(a) * c * 0.8, py + math.sin(a) * c * 0.8)], fill=(120, 88, 56, 255), width=1)
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).ellipse([1, 1, size - 2, size - 2], fill=255)
    img.putalpha(mask)
    return img


def wood_saw(turns, look):
    """The wood saw (2 x 1): a sawmill. A log on a roller bed at the west end feeds into a big circular blade standing
    in a heavy frame; sawn boards come out on a bed at the east end and stack. A blue motor and the switch box with its
    lamps sit in the base under the blade, sawdust piles on the floor. Running: the blade is a bright blur with sparks,
    chips and sawdust flying and the log has moved up to the blade. The lamps say on (green); stopped, they are dark.
    look: 0 stopped (switched off or no power: every lamp dark), 2 ready (switched on and waiting: the green lamp, nothing
    moves), 1 running (working)."""
    running, on = look == 1, look >= 1
    s = Scene(turns, foot=(2, 1))
    glows = []
    rn = random.Random(6)
    y0, y1 = 0.22, 0.78
    # the roller bed (infeed)
    for lx in (0.06, 0.40, 0.74):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx, ly, 0.0, lx + 0.04, ly + 0.04, 0.40, OD_DARK, shine=0.1)
    s.box(0.04, y0, 0.38, 0.88, y0 + 0.07, 0.46, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.04, y1 - 0.07, 0.38, 0.88, y1, 0.46, OD, top=OD_LIGHT, shine=0.1)
    for i in range(7):
        x = 0.10 + i * 0.12
        s.tube((x, y0 + 0.02, 0.47), (x, y1 - 0.02, 0.47), 0.03, STEEL, segments=12, shine=0.5)
    # the log, bark on its sides, its sawn end bright; further along when it is being cut
    lx0 = 0.14 if not running else 0.2
    lx1 = 0.84 if not running else 0.96
    s.tube((lx0, 0.5, 0.67), (lx1, 0.5, 0.67), 0.17, (92, 66, 44), cap=(206, 168, 112), segments=26, shine=0.05,
           bands=[(0, 0.5, (92, 66, 44)), (0.5, 0.52, (74, 52, 34)), (0.52, 1, (100, 72, 48))])
    grain = end_grain()
    west_decal(s, 0.33, 0.67, 0.5, 0.84, lx0, grain, offset=0.004)
    side_decal(s, 0.33, 0.67, 0.5, 0.84, lx1, end_grain(seed=5), offset=0.004)
    # bark scars
    for _ in range(8):
        t = rn.random()
        a = rn.random() * 2 * math.pi
        x = lx0 + (lx1 - lx0) * t
        s.box(x, 0.5 + 0.17 * math.cos(a) - 0.01, 0.67 + 0.17 * math.sin(a) - 0.01, x + 0.08, 0.5 + 0.17 * math.cos(a) + 0.01,
              0.67 + 0.17 * math.sin(a) + 0.01, (62, 44, 30))
    # dogs holding the log: two steel clamps
    for x in (lx0 + 0.1, lx1 - 0.2):
        s.box(x, y0 + 0.07, 0.5, x + 0.05, y0 + 0.12, 0.7, STEEL_DARK, shine=0.4)
        s.box(x, y1 - 0.12, 0.5, x + 0.05, y1 - 0.07, 0.7, STEEL_DARK, shine=0.4)
    # the saw's base: a cabinet with the motor, the switch box on its front, a sawdust chute
    bx0, bx1 = 0.92, 1.30
    s.box(bx0, y0 - 0.02, 0.0, bx1, y1 + 0.02, 0.50, OD, top=OD_LIGHT, shine=0.1)
    s.box(bx0 - 0.01, y0 - 0.03, 0.46, bx1 + 0.01, y1 + 0.03, 0.54, GRAPHITE, top=GRAPHITE_LIGHT, shine=0.4)
    s.tube((0.98, y1 + 0.12, 0.26), (1.26, y1 + 0.12, 0.26), 0.1, BLUE, cap=(44, 62, 88), segments=26, shine=0.2,
           bands=[(0, 0.08, (44, 62, 88))] + [(0.12 + 0.14 * i, 0.2 + 0.14 * i, (54, 76, 102)) for i in range(6)])
    s.box(0.96, y1 + 0.02, 0.10, 1.28, y1 + 0.2, 0.14, GRAPHITE_DARK)
    s.box(0.99, y1 + 0.04, 0.34, 1.12, y1 + 0.1, 0.42, (44, 62, 88), top=BLUE)
    s.box(0.94, y0 + 0.05, 0.3, 1.0, y0 + 0.5, 0.44, GRAPHITE_DARK)
    # the frame: two uprights and a head beam, the arbor between them
    for yy in (y0 - 0.02, y1 - 0.06):
        s.box(0.96, yy, 0.54, 1.18, yy + 0.08, 1.46, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.94, y0 - 0.04, 1.40, 1.20, y1 + 0.04, 1.50, OD, top=OD_LIGHT, shine=0.1)
    s.tube((1.06, y0, 0.92), (1.06, y1, 0.92), 0.03, STEEL, shine=0.7, segments=14)
    # the blade: stopped = clean steel, running = pale and bright
    bz, br = 0.92, 0.38
    blade(s, 1.06, 0.50, bz, br, (232, 236, 240) if running else (196, 200, 206))
    s.box(1.02, 0.46, 0.50, 1.10, 0.54, bz - br * 0.9, OD_DARK)
    # a guard over the blade's rear half and a splitter behind it
    s.box(1.08, y0 + 0.03, bz + 0.12, 1.20, y1 - 0.03, bz + br + 0.06, OD_DARK, top=OD, shine=0.1)
    # the outfeed bed and the stacked boards
    for lx in (1.36, 1.68, 1.92):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx - 0.02, ly, 0.0, lx + 0.02, ly + 0.04, 0.36, OD_DARK, shine=0.1)
    s.box(1.32, y0, 0.34, 1.96, y0 + 0.06, 0.42, OD, top=OD_LIGHT, shine=0.1)
    s.box(1.32, y1 - 0.06, 0.34, 1.96, y1, 0.42, OD, top=OD_LIGHT, shine=0.1)
    for i in range(5):
        x = 1.38 + i * 0.12
        s.tube((x, y0 + 0.02, 0.43), (x, y1 - 0.02, 0.43), 0.025, STEEL, segments=12, shine=0.5)
    boards = 5 if running else 3
    for k in range(boards):
        c = (206, 168, 112) if k % 2 else (190, 152, 98)
        s.box(1.36, 0.30, 0.46 + k * 0.05, 1.92, 0.70, 0.50 + k * 0.05, c, top=(226, 190, 132))
        s.box(1.36, 0.30, 0.50 + k * 0.05, 1.92, 0.31, 0.505 + k * 0.05, (150, 110, 70))
    # sawdust under the cut and by the chute
    for i in range(16 if running else 8):
        px, py = 0.92 + rn.random() * 0.5, 0.82 + rn.random() * 0.14
        s.box(px, py, 0.0, px + 0.07, py + 0.05, 0.02 + rn.random() * 0.02, (214, 176, 118))
    # the switch box on the base's front, lamps and buttons
    s.box(0.98, y1 + 0.02, 0.18, 1.10, y1 + 0.07, 0.38, GRAPHITE_DARK, top=GRAPHITE, shine=0.2)
    lamp_y(s, glows, 1.015, y1 + 0.07, 0.33, 0.022, 'green', on)
    lamp_y(s, glows, 1.065, y1 + 0.07, 0.33, 0.022, 'red', False)
    s.tube((1.04, y1 + 0.07, 0.24), (1.04, y1 + 0.09, 0.24), 0.022, RED if not on else (70, 70, 70), segments=14, shine=0.3)
    front_decal(s, 0.04, 0.86, 0.14, 0.30, y1 + 0.001, stencil_text('OAK SAWMILL', 120, 18, STENCIL))
    s.box(0.04, y1 - 0.06, 0.30, 0.86, y1 - 0.01, 0.38, OD_DARK)
    if running:
        for i in range(34):
            ang = rn.random() * math.pi * 1.1 - 0.1
            d = 0.9 + rn.random() * 1.3
            px = 1.06 + br * math.cos(ang) * d
            pz = bz + br * math.sin(ang) * d
            y = 0.32 + rn.random() * 0.4
            s.box(px, y, pz, px + 0.016, y + 0.016, pz + 0.014, (240, 200, 130), emit=True)
        glows.append(((1.06, 0.5, bz), (255, 230, 170), 0.3, (0, 1, 0)))
        glows.append(((1.06, 0.5, bz), (255, 230, 170), 0.3, (0, -1, 0)))
    ground = shadow((1.0, 0.55), 1.05, 0.42, 125)
    return compose(s, ground=ground, seed=150 + turns + 4 * int(look), glows=glows)


def research_storage(turns):
    """The research storage (2 x 1): a wide olive cabinet of four louvred doors, a bar and two padlocks across its
    middle, the team's mark and stencilled lettering, on a steel plinth and feet."""
    s = Scene(turns, foot=(2, 1))
    x0, x1, y0, y1 = 0.06, 1.94, 0.24, 0.78
    zt = 1.32
    for fx in (x0 + 0.03, 0.96, x1 - 0.1):
        for fy in (y0 + 0.03, y1 - 0.09):
            s.box(fx, fy, 0.0, fx + 0.07, fy + 0.07, 0.06, GRAPHITE_DARK)
    s.box(x0, y0, 0.06, x1, y1, zt, OD, top=OD_LIGHT, shine=0.1)
    s.box(x0 - 0.01, y0 - 0.01, 0.06, x1 + 0.01, y1 + 0.01, 0.13, OD_DARK)
    # the lid: a thin rim in the body's olive under a light top (a dark rim or top read as a shadow painted on)
    s.box(x0 - 0.012, y0 - 0.012, zt - 0.03, x1 + 0.012, y1 + 0.012, zt, OD, top=OD_LIGHT, shine=0.1)
    f = y1 + 0.007
    # four doors with their seams, ribs and louvres; each pair shares a central post
    xs = [x0 + 0.04, 0.54, 1.00, 1.46, x1 - 0.04]
    # the central post is wider
    xs = [x0 + 0.04, 0.50, 0.98, 1.02, 1.50, x1 - 0.04]
    doors = [(xs[0], xs[1]), (xs[1], xs[2]), (xs[3], xs[4]), (xs[4], xs[5])]
    for (a, b) in doors:
        s.box(a + 0.004, y1, 0.17, b - 0.004, f, zt - 0.04, OD_LIGHT, shine=0.1)
        for z in (0.34, 0.6):
            s.box(a + 0.04, f, z, b - 0.04, f + 0.01, z + 0.012, OD_DARK)
        for i in range(6):
            s.box(a + 0.05, f, zt - 0.27 + i * 0.03, b - 0.05, f + 0.008, zt - 0.27 + i * 0.03 + 0.014, (24, 26, 24))
        # a handle near the post
        hx = b - 0.07 if a < 0.96 else a + 0.045
        s.box(hx, f, 0.66, hx + 0.02, f + 0.035, 0.84, STEEL_DARK, shine=0.5)
    s.box(xs[2], y1, 0.15, xs[3], f + 0.012, zt - 0.04, OD_DARK)
    # the locking bar across the middle with two padlocks
    s.box(0.72, f + 0.012, 0.70, 1.28, f + 0.035, 0.76, STEEL, shine=0.6)
    for px in (0.78, 1.16):
        s.box(px, f + 0.035, 0.58, px + 0.06, f + 0.07, 0.70, BRASS, shine=0.7)
        s.tube((px + 0.03, f + 0.055, 0.70), (px + 0.03, f + 0.055, 0.75), 0.018, STEEL, segments=10, shine=0.7)
    front_decal(s, 0.12, 0.48, 1.0, 1.14, f + 0.012, stencil_text('OAK', 60, 24, STENCIL))
    front_decal(s, 1.52, 1.88, 1.0, 1.14, f + 0.012, stencil_text('RESEARCH', 90, 20, STENCIL))
    front_decal(s, 0.90, 1.10, 0.92, 1.22, f + 0.014, acorn_mark(40, STENCIL))
    for i in range(6):
        s.box(x1, y0 + 0.06, 0.2 + i * 0.18, x1 + 0.01, y1 - 0.06, 0.22 + i * 0.18, OD_DARK)
    side_decal(s, y0 + 0.1, y1 - 0.1, 0.56, 0.72, x1 + 0.012, stencil_text('OAK-R', 52, 20, STENCIL))
    # the back: stiffeners between three panels, a louvred vent high at each end, a data plate and a cable gland
    b = y0 - 0.012
    for sx in (0.66, 1.32):
        s.box(sx - 0.02, b, 0.16, sx + 0.02, y0, zt - 0.05, OD_DARK, top=OD)
    s.box(x0 + 0.04, b, 0.16, x1 - 0.04, y0, 0.19, OD_DARK, top=OD)
    for vx0, vx1 in ((0.16, 0.5), (1.5, 1.84)):
        s.box(vx0 - 0.02, b - 0.002, zt - 0.36, vx1 + 0.02, y0, zt - 0.08, OD_DARK)
        for i in range(6):
            z = zt - 0.33 + i * 0.04
            s.box(vx0, b - 0.012, z, vx1, b - 0.002, z + 0.018, (28, 30, 28), top=OD_LIGHT)
    s.box(0.86, b - 0.004, 0.62, 1.12, y0, 0.78, (176, 166, 120), shine=0.4)
    back_decal(s, 0.88, 1.10, 0.64, 0.76, b - 0.004, stencil_text('OAK-R1  LOT 07', 80, 30, (40, 38, 30)))
    s.tube((1.62, b, 0.34), (1.62, b - 0.05, 0.34), 0.03, GRAPHITE, cap=GRAPHITE_DARK, segments=12, shine=0.3)
    s.tube((1.62, b - 0.05, 0.34), (1.62, b - 0.05, 0.08), 0.012, (30, 30, 30), segments=8)
    back_decal(s, 0.2, 0.56, 0.3, 0.44, b, stencil_text('OAK', 60, 24, STENCIL))
    # the west end: ribs as on the east, a recessed carrying handle
    for i in range(6):
        s.box(x0 - 0.01, y0 + 0.06, 0.2 + i * 0.18, x0, y1 - 0.06, 0.22 + i * 0.18, OD_DARK)
    s.box(x0 - 0.012, 0.4, 0.86, x0, 0.62, 0.94, (26, 28, 26))
    s.box(x0 - 0.03, 0.42, 0.9, x0 - 0.012, 0.6, 0.92, STEEL_DARK, shine=0.5)
    # lifting eyes at the lid's corners
    for ex, ey in ((x0 + 0.1, y0 + 0.08), (x1 - 0.1, y0 + 0.08), (x0 + 0.1, y1 - 0.08), (x1 - 0.1, y1 - 0.08)):
        s.box(ex - 0.03, ey - 0.03, zt, ex + 0.03, ey + 0.03, zt + 0.015, STEEL_DARK, top=STEEL)
        s.tube((ex - 0.025, ey, zt + 0.04), (ex + 0.025, ey, zt + 0.04), 0.022, STEEL, segments=12, shine=0.6, caps=False)
    ground = shadow((1.0, 0.52), 1.0, 0.38, 125)
    return compose(s, ground=ground, seed=160 + turns, glows=[])


# The research crate's height: the game stacks a table's tiles its Surface (32) apart, times the tile scale (64 pixels in
# these tiles), and a unit up is UP pixels: the crate's top is where the next one stands.
CRATE_TOP = 64 / UP


def research_crate():
    """The research crate (1 x 1), the research storage's small kind that stacks three high. Like the game's crates it
    has no front: an olive steel crate on four feet, the same on every side (a lid's seam, two ribs, a carrying handle,
    the team's lettering and mark). Its top is flat: the next crate stands on it."""
    s = Scene(0)
    lo, hi = 0.08, 0.92
    zt = CRATE_TOP
    zl = zt - 0.14
    for fx in (lo + 0.02, hi - 0.1):
        for fy in (lo + 0.02, hi - 0.1):
            s.box(fx, fy, 0.0, fx + 0.08, fy + 0.08, 0.05, GRAPHITE_DARK)
    s.box(lo, lo, 0.05, hi, hi, zl, OD, top=OD_LIGHT, shine=0.1)
    # the lid, a little wider than the body, its rim in the body's olive under a light top
    s.box(lo - 0.012, lo - 0.012, zl, hi + 0.012, hi + 0.012, zt, OD, top=OD_LIGHT, shine=0.1)
    f = hi + 0.007
    # the two faces the tile shows (south and east), alike: what stands out of a face spans a..b along it, z0..z1 up,
    # d deep; the lettering and the mark sit on it
    faces = (
        lambda a, b, z0, z1, d, colour, shine=0.0: s.box(a, hi, z0, b, hi + d, z1, colour, shine=shine),
        lambda a, b, z0, z1, d, colour, shine=0.0: s.box(hi, a, z0, hi + d, b, z1, colour, shine=shine),
    )
    for raised in faces:
        for z in (0.16, 0.40):
            raised(lo + 0.03, hi - 0.03, z, z + 0.024, 0.007, OD_DARK)
        raised(lo, hi, zl - 0.014, zl, 0.007, OD_DARK)
        raised(0.38, 0.62, zl - 0.1, zl - 0.07, 0.024, STEEL_DARK, 0.5)
    for decal in (front_decal, side_decal):
        decal(s, 0.3, 0.7, 0.45, 0.56, f, stencil_text('OAK-R', 52, 20, STENCIL))
        decal(s, 0.41, 0.59, 0.19, 0.37, f, acorn_mark(40, STENCIL))
    ground = shadow((0.5, 0.5), 0.48, 0.48, 120)
    return compose(s, ground=ground, seed=170, glows=[])


def rain_storage(level=3):
    """The big rain storage (2 x 2): a 4000 litre open-topped round plastic tank, blue-grey and ribbed, a thick lip,
    two steel hoops with their buckles round it, a rain funnel on a post at the back that pipes what it catches over the
    rim, a brass tap with its valve low on the front, an overflow pipe and a stencilled plate, on a timber pallet. level 0..3 is how much water it holds: empty (a dry
    floor with a little dirt and leaves), a quarter, a half, full (the water a hand below the rim)."""
    if level and 'rainStorage' not in OWNERS:
        rain_storage(0)    # the empty tank's split of the pixels into tiles is the one every level uses
    s = Scene(0, foot=(2, 2))
    cx, cy, r, h = 1.0, 1.0, 0.82, 0.8
    PLASTIC = (66, 84, 96)
    PLASTIC_DARK = (50, 64, 74)
    PLASTIC_LIGHT = (118, 130, 138)
    floor_z = 0.09
    full_z = 0.66
    wz = floor_z + (full_z - floor_z) * (0.0, 0.25, 0.5, 1.0)[level]
    # the pallet under the tank: bearers, then deck boards with gaps between them
    for by in (0.16, 0.96, 1.76):
        s.box(0.12, by - 0.05, 0.0, 1.88, by + 0.05, 0.035, WOOD_DARK, top=WOOD_DARK)
    for i in range(9):
        bx = 0.12 + i * 0.2
        s.box(bx, 0.12, 0.035, bx + 0.17, 1.88, 0.06, WOOD_DARK, top=WOOD if i % 2 else (150, 112, 70))
    # the far inside wall (dry above the water, dark and wet below it), then the outer wall with its ribs
    wet_top = wz if level else floor_z
    if level:
        s.tube((cx, cy, 0.08), (cx, cy, wet_top), r - 0.04, (44, 60, 66), segments=64, inward=True)
    s.tube((cx, cy, wet_top), (cx, cy, h), r - 0.04, (78, 92, 104), segments=64, inward=True)
    bands = []
    n = 8
    for i in range(n):
        bands.append((i / n, i / n + 0.8 / n, PLASTIC))
        bands.append((i / n + 0.8 / n, (i + 1) / n, PLASTIC_DARK))
    s.tube((cx, cy, 0.06), (cx, cy, h), r, PLASTIC, segments=64, bands=bands, shine=0.3, caps=False)
    s.tube((cx, cy, h - 0.07), (cx, cy, h + 0.02), r + 0.03, PLASTIC_LIGHT, segments=64, shine=0.35, caps=False)
    ring_top(s, (cx, cy), r - 0.07, r + 0.03, h + 0.02, PLASTIC_LIGHT, segments=64, shine=0.35)
    if level == 0:
        # dry: the floor of the tank, dark dirt and silt with leaves and twigs, a dried ring of scum on the wall
        disc(s, (cx, cy), r - 0.05, floor_z, (92, 80, 62), segments=64, shine=0.05)
        dirt = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
        dd = ImageDraw.Draw(dirt)
        rn = random.Random(31)
        for _ in range(70):
            x, y = rn.randint(20, 236), rn.randint(20, 236)
            if (x - 128) ** 2 + (y - 128) ** 2 > 104 ** 2:
                continue
            size = rn.randint(3, 11)
            tone = rn.choice(((60, 50, 38, 170), (118, 102, 78, 150), (74, 66, 48, 160)))
            dd.ellipse([x, y, x + size, y + size * 2 // 3 + 1], fill=tone)
        for k in (46, 80):
            dd.ellipse([128 - k, 128 - k, 128 + k, 128 + k], outline=(70, 60, 46, 60), width=3)
        flat_decal(s, cx - r + 0.08, cy - r + 0.08, cx + r - 0.08, cy + r - 0.08, floor_z, dirt)
        for lx, ly, rot, c1, c2 in ((0.8, 1.15, 20, (132, 104, 52), (150, 120, 60)), (1.25, 0.85, 70, (112, 96, 44), (132, 112, 52)),
                                    (1.1, 1.35, 130, (140, 90, 40), (160, 106, 48)), (1.4, 1.2, 100, (96, 110, 52), (116, 130, 62))):
            s.xbox((lx, ly, floor_z + 0.004), (0.1, 0.05, 0.006), rotation((0, 0, 1), rot), c1, top=c2)
        s.tube((0.9, 0.9, floor_z + 0.012), (1.2, 1.02, floor_z + 0.016), 0.012, (84, 66, 44), segments=6)
    else:
        disc(s, (cx, cy), r - 0.05, wz, (60, 92, 98), segments=64, shine=0.5)
        glint = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glint)
        gd.ellipse([40, 60, 150, 104], fill=(170, 196, 206, 70))
        for k in (70, 120):
            gd.ellipse([128 - k // 2, 128 - k // 2, 128 + k // 2, 128 + k // 2], outline=(150, 176, 184, 40), width=2)
        glint = glint.filter(ImageFilter.GaussianBlur(4))
        flat_decal(s, cx - r + 0.08, cy - r + 0.08, cx + r - 0.08, cy + r - 0.08, wz, glint)
        for lx, ly, rot in ((0.8, 1.1, 20), (1.2, 0.8, 70), (1.1, 1.3, 130)):
            s.xbox((lx, ly, wz + 0.004), (0.1, 0.05, 0.006), rotation((0, 0, 1), rot), (120, 130, 60), top=(138, 150, 70))
    # the level gauge: a sight tube down the south side with its water, the marks at the quarters
    fraction = (0.0, 0.25, 0.5, 1.0)[level]
    gx = cx + 0.12
    gy = cy + math.sqrt(r * r - 0.12 * 0.12)
    g0, g1 = 0.12, h - 0.1
    s.box(gx - 0.05, gy - 0.01, g0 - 0.03, gx + 0.05, gy + 0.05, g1 + 0.03, STEEL_DARK, top=STEEL)
    s.box(gx - 0.026, gy + 0.05, g0, gx + 0.026, gy + 0.062, g1, (188, 204, 212), top=(188, 204, 212), shine=0.5)
    if fraction > 0:
        s.box(gx - 0.026, gy + 0.062, g0, gx + 0.026, gy + 0.07, g0 + (g1 - g0) * fraction, (60, 96, 104), top=(72, 110, 118), shine=0.6)
    for q in (0.25, 0.5, 0.75, 1.0):
        zq = g0 + (g1 - g0) * q
        s.box(gx + 0.026, gy + 0.05, zq - 0.006, gx + 0.075, gy + 0.075, zq + 0.006, (232, 232, 220), top=(232, 232, 220))
    # two steel hoops round the wall, each with a buckle and its bolt on the south-east side
    for hz in (0.24, 0.56):
        s.tube((cx, cy, hz), (cx, cy, hz + 0.035), r + 0.014, STEEL_DARK, segments=64, shine=0.5, caps=False)
        a = math.radians(40)
        bx, by = cx + (r + 0.02) * math.cos(a), cy + (r + 0.02) * math.sin(a)
        s.xbox((bx, by, hz + 0.0175), (0.08, 0.03, 0.06), rotation((0, 0, 1), 40 + 90), STEEL, top=STEEL, shine=0.6)
        s.tube((bx - 0.03 * math.sin(a), by + 0.03 * math.cos(a), hz + 0.0175),
               (bx + 0.03 * math.sin(a), by - 0.03 * math.cos(a), hz + 0.0175), 0.012, BRASS, segments=8, shine=0.6)
    # the plate on the front: what it is and holds
    plate = stencil_text('OAK-W  4000 L', 96, 16, STENCIL)
    a = math.radians(112)
    px, py = cx + (r + 0.004) * math.cos(a), cy + (r + 0.004) * math.sin(a)
    tangent = (-math.sin(a), math.cos(a), 0)
    s.decal((px - tangent[0] * 0.2, py - tangent[1] * 0.2, 0.5), (tangent[0] * 0.4, tangent[1] * 0.4, 0), (0, 0, -0.08),
            plate, (math.cos(a), math.sin(a), 0), 0.006)
    # the tap low on the front, a gate valve with a wheel, the pipe down
    tx, ty = cx - 0.3, cy + r * 0.955
    s.tube((tx, ty, 0.2), (tx, ty + 0.1, 0.2), 0.04, BRASS, segments=14, shine=0.6)
    s.tube((tx, ty + 0.1, 0.2), (tx, ty + 0.1, 0.12), 0.034, BRASS, segments=14, shine=0.6)
    s.tube((tx, ty + 0.04, 0.2), (tx, ty + 0.04, 0.3), 0.014, STEEL, segments=8, shine=0.6)
    valve_wheel(s, (tx, ty + 0.04, 0.32), 0.05, RED, axis='y')
    # the rain funnel at the back corner: a post on a foot, a wide funnel with a leaf screen on top, its pipe bent
    # over the rim into the tank; an overflow pipe on the east side
    fx, fy = 1.74, 0.26
    s.box(fx - 0.09, fy - 0.09, 0.0, fx + 0.09, fy + 0.09, 0.05, GRAPHITE_DARK, top=GRAPHITE)
    s.box(fx - 0.025, fy - 0.025, 0.05, fx + 0.025, fy + 0.025, 1.2, GRAPHITE, top=GRAPHITE_LIGHT, shine=0.3)
    for k in (-1, 1):
        s.tube((fx, fy, 0.9), (fx + k * 0.1, fy, 1.2), 0.012, GRAPHITE_DARK, segments=6)
    s.tube((fx, fy, 1.16), (fx, fy, 1.42), 0.05, (52, 58, 64), r2=0.26, segments=28, shine=0.4, caps=False)
    s.tube((fx, fy, 1.18), (fx, fy, 1.42), 0.045, (34, 38, 42), r2=0.25, segments=28, inward=True, caps=False)
    s.tube((fx, fy, 1.40), (fx, fy, 1.44), 0.27, GRAPHITE_LIGHT, segments=28, shine=0.4, caps=False)
    screen = Image.new('RGBA', (128, 128), (0, 0, 0, 0))
    sd = ImageDraw.Draw(screen)
    sd.ellipse([2, 2, 125, 125], fill=(30, 34, 36, 120))
    for k in range(8, 128, 10):
        sd.line([(k, 0), (k, 127)], fill=(150, 156, 160, 200), width=1)
        sd.line([(0, k), (127, k)], fill=(150, 156, 160, 200), width=1)
    mask = Image.new('L', (128, 128), 0)
    ImageDraw.Draw(mask).ellipse([2, 2, 125, 125], fill=255)
    screen.putalpha(Image.fromarray(np.minimum(np.array(screen.getchannel('A')), np.array(mask))))
    flat_decal(s, fx - 0.25, fy - 0.25, fx + 0.25, fy + 0.25, 1.43, screen)
    s.tube((fx, fy, 1.18), (fx, fy, 1.06), 0.035, GRAPHITE, segments=14, shine=0.3)
    s.tube((fx, fy, 1.06), (cx + 0.5, cy - 0.5, h + 0.14), 0.035, GRAPHITE, segments=14, shine=0.3)
    s.tube((cx + 0.5, cy - 0.5, h + 0.14), (cx + 0.42, cy - 0.42, h - 0.02), 0.035, GRAPHITE, segments=14, shine=0.3)
    ox, oy = cx + r * 0.98, cy - 0.15
    s.tube((ox - 0.03, oy, h - 0.16), (ox + 0.13, oy, h - 0.16), 0.05, PLASTIC_DARK, segments=16, shine=0.3)
    s.tube((ox + 0.13, oy, h - 0.16), (ox + 0.13, oy, 0.18), 0.05, PLASTIC_DARK, segments=16, shine=0.3)
    ground = shadow((1.0, 1.0), 0.95, 0.95, 125)
    return compose(s, ground=ground, seed=170, owner_key='rainStorage')
