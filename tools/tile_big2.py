"""Two-tile machines, part 2, and the big rain storage: the wood saw and the research storage (2 x 1), the rain storage
(2 x 2). See tile_big1.py."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import Scene, shadow, compose, unit, rotation, apply, add, mul, stencil_text, acorn_mark, project, SS
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, LIT, UNLIT, BEZEL, lamp, lamp_y,
                          front_decal, side_decal, flat_decal, noise_texture)
from tile_trade import hazard_strip, plank_lines
from tile_machines import GRAPHITE, GRAPHITE_DARK, GRAPHITE_LIGHT, double_poly, ring_top, disc, valve_wheel


def blade(s, cx, y, cz, r, colour, teeth=36):
    """A big circular saw blade standing in the plane y = const, seen from both sides: teeth round the rim, an arbor
    flange in the middle."""
    pts = []
    for i in range(teeth * 2):
        a = 2 * math.pi * i / (teeth * 2)
        rr = r if i % 2 == 0 else r * 0.93
        pts.append((cx + rr * math.cos(a), y, cz + rr * math.sin(a)))
    double_poly(s, pts, colour, colour, (0, 1, 0), shine=0.8)
    for sign in (1, -1):
        for rr, col in ((r * 0.55, tuple(int(c * 0.88) for c in colour)), (r * 0.2, STEEL_DARK)):
            seg = 32
            s.poly([(cx + rr * math.cos(2 * math.pi * i / seg), y + 0.003 * sign, cz + rr * math.sin(2 * math.pi * i / seg))
                    for i in range(seg)], col, (0, sign, 0), 0.5)


def wood_saw(turns, running):
    """The wood saw (2 x 1): a sawmill. A log on a roller bed at the west end feeds into a big circular blade standing
    in a heavy frame; sawn boards come out on a bed at the east end and stack. A blue motor and the switch box with its
    lamps sit in the base under the blade, sawdust piles on the floor. Running: the blade is a bright blur with sparks,
    chips and sawdust flying, the lamp is green and the log has moved up to the blade."""
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
    s.tube((0.98, y1 + 0.12, 0.26), (1.26, y1 + 0.12, 0.26), 0.1, BLUE, cap=(34, 66, 94), segments=26, shine=0.2,
           bands=[(0, 0.08, (34, 66, 94))] + [(0.12 + 0.14 * i, 0.2 + 0.14 * i, (40, 84, 128)) for i in range(6)])
    s.box(0.96, y1 + 0.02, 0.10, 1.28, y1 + 0.2, 0.14, GRAPHITE_DARK)
    s.box(0.99, y1 + 0.04, 0.34, 1.12, y1 + 0.1, 0.42, (34, 66, 94), top=BLUE)
    s.box(0.94, y0 + 0.05, 0.3, 1.0, y0 + 0.5, 0.44, GRAPHITE_DARK)
    # the frame: two uprights and a head beam, the arbor between them
    for yy in (y0 - 0.02, y1 - 0.06):
        s.box(0.96, yy, 0.54, 1.18, yy + 0.08, 1.46, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.94, y0 - 0.04, 1.40, 1.20, y1 + 0.04, 1.50, OD, top=OD_LIGHT, shine=0.1)
    s.tube((1.06, y0, 0.92), (1.06, y1, 0.92), 0.03, STEEL, shine=0.7, segments=14)
    # the blade: stopped = clean steel, running = pale and bright
    bz, br = 0.92, 0.38
    blade(s, 1.06, 0.50, bz, br, (226, 230, 234) if running else (176, 180, 184))
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
    lamp_y(s, glows, 1.02, y1 + 0.07, 0.34, 0.014, 'green', running)
    lamp_y(s, glows, 1.06, y1 + 0.07, 0.34, 0.014, 'red', not running)
    s.tube((1.04, y1 + 0.07, 0.24), (1.04, y1 + 0.09, 0.24), 0.022, RED if not running else (70, 70, 70), segments=14, shine=0.3)
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
    return compose(s, ground=ground, seed=150 + turns + (4 if running else 0), glows=glows)


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
    s.box(x0 - 0.012, y0 - 0.012, zt - 0.05, x1 + 0.012, y1 + 0.012, zt, OD_DARK, top=OD_DARK)
    f = y1 + 0.007
    # four doors with their seams, ribs and louvres; each pair shares a central post
    xs = [x0 + 0.04, 0.54, 1.00, 1.46, x1 - 0.04]
    # the central post is wider
    xs = [x0 + 0.04, 0.50, 0.98, 1.02, 1.50, x1 - 0.04]
    doors = [(xs[0], xs[1]), (xs[1], xs[2]), (xs[3], xs[4]), (xs[4], xs[5])]
    for (a, b) in doors:
        s.box(a + 0.004, y1, 0.17, b - 0.004, f, zt - 0.08, OD_LIGHT, shine=0.1)
        for z in (0.34, 0.6):
            s.box(a + 0.04, f, z, b - 0.04, f + 0.01, z + 0.012, OD_DARK)
        for i in range(6):
            s.box(a + 0.05, f, zt - 0.27 + i * 0.03, b - 0.05, f + 0.008, zt - 0.27 + i * 0.03 + 0.014, (24, 26, 24))
        # a handle near the post
        hx = b - 0.07 if a < 0.96 else a + 0.045
        s.box(hx, f, 0.66, hx + 0.02, f + 0.035, 0.84, STEEL_DARK, shine=0.5)
    s.box(xs[2], y1, 0.15, xs[3], f + 0.012, zt - 0.06, OD_DARK)
    # the locking bar across the middle with two padlocks
    s.box(0.72, f + 0.012, 0.70, 1.28, f + 0.035, 0.76, STEEL, shine=0.6)
    for px in (0.78, 1.16):
        s.box(px, f + 0.035, 0.58, px + 0.06, f + 0.07, 0.70, BRASS, shine=0.7)
        s.tube((px + 0.03, f + 0.055, 0.70), (px + 0.03, f + 0.055, 0.75), 0.018, STEEL, segments=10, shine=0.7)
    front_decal(s, 0.12, 0.48, 1.0, 1.14, f + 0.012, stencil_text('OAK', 60, 24, STENCIL))
    front_decal(s, 1.52, 1.88, 1.0, 1.14, f + 0.012, stencil_text('RESEARCH', 90, 20, STENCIL))
    front_decal(s, 0.90, 1.10, 0.92, 1.22, f + 0.014, acorn_mark(40, STENCIL))
    front_decal(s, 0.12, 0.88, 0.2, 0.3, f + 0.012, stencil_text('STORAGE  OAK-R1', 120, 12, STENCIL))
    for i in range(6):
        s.box(x1, y0 + 0.06, 0.2 + i * 0.18, x1 + 0.01, y1 - 0.06, 0.22 + i * 0.18, OD_DARK)
    side_decal(s, y0 + 0.1, y1 - 0.1, 0.56, 0.72, x1 + 0.012, stencil_text('OAK-R', 52, 20, STENCIL))
    ground = shadow((1.0, 0.52), 1.0, 0.38, 125)
    return compose(s, ground=ground, seed=160 + turns, glows=[])


def rain_storage():
    """The big rain storage (2 x 2): a 4000 litre open-topped round plastic tank, blue-grey and ribbed, a thick lip
    with a hand rail of steel loops, rain water standing a little below the rim, a ladder up the south-east side, a
    downspout pipe feeding it from above, a brass tap with its valve low on the front and an overflow pipe."""
    s = Scene(0, foot=(2, 2))
    cx, cy, r, h = 1.0, 1.0, 0.82, 1.0
    PLASTIC = (58, 104, 150)
    PLASTIC_DARK = (40, 76, 114)
    PLASTIC_LIGHT = (140, 176, 206)
    # the base ring, a pallet of timber under the tank
    s.box(0.12, 0.12, 0.0, 1.88, 1.88, 0.06, WOOD_DARK, top=WOOD)
    # the far inside wall, then the outer wall with its ribs (a darker band now and then)
    s.tube((cx, cy, 0.08), (cx, cy, h), r - 0.04, (78, 92, 104), segments=64, inward=True)
    bands = []
    n = 8
    for i in range(n):
        bands.append((i / n, i / n + 0.8 / n, PLASTIC))
        bands.append((i / n + 0.8 / n, (i + 1) / n, PLASTIC_DARK))
    s.tube((cx, cy, 0.06), (cx, cy, h), r, PLASTIC, segments=64, bands=bands, shine=0.3, caps=False)
    s.tube((cx, cy, h - 0.07), (cx, cy, h + 0.02), r + 0.03, PLASTIC_LIGHT, segments=64, shine=0.35, caps=False)
    ring_top(s, (cx, cy), r - 0.07, r + 0.03, h + 0.02, PLASTIC_LIGHT, segments=64, shine=0.35)
    wz = h - 0.26
    disc(s, (cx, cy), r - 0.05, wz, (52, 150, 176), segments=64, shine=0.9)
    glint = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glint)
    gd.ellipse([34, 56, 130, 100], fill=(190, 226, 250, 150))
    gd.ellipse([150, 140, 210, 164], fill=(190, 226, 250, 110))
    gd.ellipse([60, 170, 100, 184], fill=(190, 226, 250, 90))
    for k in (60, 100, 140):
        gd.ellipse([128 - k // 2, 128 - k // 2, 128 + k // 2, 128 + k // 2], outline=(200, 232, 250, 70), width=2)
    flat_decal(s, cx - r + 0.08, cy - r + 0.08, cx + r - 0.08, cy + r - 0.08, wz, glint)
    for lx, ly, rot in ((0.8, 1.1, 20), (1.2, 0.8, 70), (1.1, 1.3, 130)):
        s.xbox((lx, ly, wz + 0.004), (0.1, 0.05, 0.006), rotation((0, 0, 1), rot), (120, 130, 60), top=(138, 150, 70))
    # a name plate on the south side and the steel hoops that hold the tank
    fy = cy + r
    # the ladder up the south-east side
    a = math.radians(55)
    lx, ly = cx + r * math.cos(a) * 1.02, cy + r * math.sin(a) * 1.02
    for side in (-0.07, 0.07):
        s.tube((lx + side * -math.sin(a), ly + side * math.cos(a), 0.06), (lx + side * -math.sin(a), ly + side * math.cos(a), h + 0.34), 0.012, STEEL, segments=8, shine=0.6)
    for i in range(10):
        z = 0.14 + i * 0.1
        s.tube((lx + 0.07 * math.sin(a), ly - 0.07 * math.cos(a), z), (lx - 0.07 * math.sin(a), ly + 0.07 * math.cos(a), z), 0.01, STEEL, segments=6, shine=0.6)
    # the tap low on the front, a gate valve with a wheel, the pipe down
    tx, ty = cx - 0.3, cy + r * 0.955
    s.tube((tx, ty, 0.2), (tx, ty + 0.1, 0.2), 0.04, BRASS, segments=14, shine=0.6)
    s.tube((tx, ty + 0.1, 0.2), (tx, ty + 0.1, 0.12), 0.034, BRASS, segments=14, shine=0.6)
    s.tube((tx, ty + 0.04, 0.2), (tx, ty + 0.04, 0.3), 0.014, STEEL, segments=8, shine=0.6)
    valve_wheel(s, (tx, ty + 0.04, 0.32), 0.05, RED, axis='y')
    # the downspout from above at the back, bent over the rim; an overflow pipe on the east side
    dx, dy = cx + 0.45, cy - r * 0.8
    s.tube((dx, dy, 1.62), (dx, dy, h + 0.12), 0.04, GRAPHITE, segments=14, shine=0.3)
    s.tube((dx, dy, h + 0.12), (dx - 0.1, dy + 0.16, h + 0.02), 0.04, GRAPHITE, segments=14, shine=0.3)
    s.tube((dx, dy, 1.58), (dx, dy, 1.62), 0.055, GRAPHITE_DARK, segments=14)
    ox, oy = cx + r * 0.98, cy - 0.15
    s.tube((ox - 0.03, oy, h - 0.16), (ox + 0.13, oy, h - 0.16), 0.05, PLASTIC_DARK, segments=16, shine=0.3)
    s.tube((ox + 0.13, oy, h - 0.16), (ox + 0.13, oy, 0.18), 0.05, PLASTIC_DARK, segments=16, shine=0.3)
    ground = shadow((1.0, 1.0), 0.95, 0.95, 125)
    return compose(s, ground=ground, seed=170)
