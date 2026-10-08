"""The trade sheet's objects (besides the terminal): the delivery box, the supply crate, the parachute crate, the scorched
ground, the meteor rocks and the drop-site stake."""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from tile_engine import (Scene, shadow, compose, unit, rotation, apply, add, sub, mul, stencil_text, acorn_mark,
                         IDENTITY, project, SS, W, H, UP)
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, lamp, stick, flat_decal, front_decal,
                          side_decal, noise_texture, face_frame)

FOAM = (58, 64, 56)
STRAW = (190, 168, 110)
ORANGE = (226, 112, 36)


def hazard_strip(w, h, colour=YELLOW, other=(30, 30, 30), slant=10):
    img = Image.new('RGBA', (w, h), colour + (255,))
    d = ImageDraw.Draw(img)
    for x in range(-h, w + h, slant * 2):
        d.polygon([(x, h), (x + slant, h), (x + slant + h, 0), (x + h, 0)], fill=other + (255,))
    return img


def plank_lines(w, h, seed, base, lines=5, vertical=False, spread=10):
    """Boards of a crate: the base colour with seams between the planks and a little grain."""
    img = noise_texture(w, h, seed, base, spread=spread)
    d = ImageDraw.Draw(img)
    dark = tuple(int(c * 0.6) for c in base) + (255,)
    for i in range(1, lines):
        if vertical:
            x = int(w * i / lines)
            d.line([(x, 0), (x, h)], fill=dark, width=1)
        else:
            y = int(h * i / lines)
            d.line([(0, y), (w, y)], fill=dark, width=1)
    return img


def delivery_box(sealed):
    """The delivery box: a hard olive case (corner guards, two latches, carrying handles) with a small transmitter
    bolted to its east end, its antenna up. Open: the lid stands back on its hinge showing the foam, the transmitter's
    lamp is green. Sealed: the lid is down under a yellow security strap and the lamp is red (it reports to the helicopter)."""
    s = Scene(0)
    glows = []
    x0, x1, y0, y1 = 0.12, 0.76, 0.22, 0.78
    zb = 0.34
    s.box(x0, y0, 0.02, x1, y1, zb, OD, top=OD_DARK, shine=0.15)
    s.box(x0 + 0.02, y0 + 0.02, 0.0, x1 - 0.02, y1 - 0.02, 0.03, RUBBER)
    # ribs along the body
    for z in (0.10, 0.19):
        s.box(x0 - 0.005, y1 - 0.005, z, x1 + 0.005, y1 + 0.005, z + 0.018, OD_DARK)
        s.box(x1 - 0.005, y0 - 0.005, z, x1 + 0.005, y1 + 0.005, z + 0.018, OD_DARK)
    # steel corner guards
    for cx, cy in ((x0, y1), (x1, y1)):
        s.box(cx - (0.02 if cx == x0 else 0), cy - 0.0, 0.02, cx + (0.0 if cx == x0 else 0.02), cy + 0.02, zb, STEEL_DARK, shine=0.5)
    s.box(x1, y0, 0.02, x1 + 0.02, y0 + 0.02, zb, STEEL_DARK, shine=0.5)
    # the front: stencil and the team's mark
    front_decal(s, x0 + 0.05, x0 + 0.40, 0.08, 0.20, y1 + 0.005, stencil_text('DELIVERY', 70, 22, STENCIL))
    front_decal(s, x0 + 0.44, x0 + 0.58, 0.08, 0.24, y1 + 0.005, acorn_mark(28, STENCIL))
    side_decal(s, y0 + 0.07, y1 - 0.07, 0.10, 0.20, x1 + 0.005, stencil_text('OAK-D', 54, 18, STENCIL))
    # latches
    for lx in (x0 + 0.12, x1 - 0.20):
        s.box(lx, y1 + 0.005, zb - 0.06, lx + 0.07, y1 + 0.022, zb + 0.07, STEEL_DARK, shine=0.5)
        s.box(lx + 0.015, y1 + 0.022, zb - 0.02, lx + 0.055, y1 + 0.03, zb + 0.02, STEEL, shine=0.7)
    # the transmitter on the east end: a black housing on a bracket, an antenna, its lamp
    tx0, tx1, ty0, ty1, tz0, tz1 = x1 + 0.02, x1 + 0.12, 0.39, 0.55, 0.10, 0.25
    s.box(x1, 0.40, 0.12, tx0, 0.54, 0.16, STEEL_DARK, shine=0.4)
    s.box(tx0, ty0, tz0, tx1, ty1, tz1, BLACK, top=(60, 62, 64), shine=0.3)
    s.box(tx0 + 0.005, ty0 + 0.015, tz0 + 0.015, tx0 + 0.012, ty1 - 0.015, tz1 - 0.015, STEEL_DARK)
    s.tube((tx1 - 0.03, ty0 + 0.04, tz1), (tx1 - 0.03, ty0 + 0.04, tz1 + 0.5), 0.011, STEEL, r2=0.004, shine=0.5,
           segments=8)
    s.tube((tx1 - 0.03, ty1 - 0.04, tz1), (tx1 - 0.03, ty1 - 0.04, tz1 + 0.32), 0.008, STEEL, r2=0.004, shine=0.5,
           segments=8)
    s.tube((tx1 - 0.03, ty0 + 0.04, tz1 + 0.5), (tx1 - 0.03, ty0 + 0.04, tz1 + 0.515), 0.008, RED, segments=8)
    lamp(s, glows, (tx0 + tx1) / 2, 0.47, tz1, 0.016, 'red' if sealed else 'green', True)
    s.tube((tx0 + 0.03, 0.43, tz1), (tx0 + 0.03, 0.43, tz1 + 0.006), 0.012, (70, 74, 76), segments=10)

    if sealed:
        lid_z0, lid_z1 = zb, zb + 0.14
        s.box(x0 - 0.012, y0 - 0.012, lid_z0, x1 + 0.012, y1 + 0.012, lid_z1, OD, top=OD_LIGHT, shine=0.15)
        for lx in (x0 + 0.1, x0 + 0.26, x0 + 0.42):
            s.box(lx, y0 + 0.04, lid_z1, lx + 0.025, y1 - 0.04, lid_z1 + 0.012, OD_DARK)
        # the security strap and its tag
        sx = (x0 + x1) / 2 + 0.06
        s.box(sx - 0.035, y0 - 0.014, lid_z0 + 0.01, sx + 0.035, y1 + 0.014, lid_z1 + 0.006, YELLOW, shine=0.1)
        flat_decal(s, sx - 0.035, y0 - 0.014, sx + 0.035, y1 + 0.014, lid_z1 + 0.006, hazard_strip(16, 100, YELLOW, (36, 36, 34), 7))
        front_decal(s, sx - 0.035, sx + 0.035, lid_z0 + 0.01, lid_z1 + 0.006, y1 + 0.014, hazard_strip(16, 30, YELLOW, (36, 36, 34), 7))
        s.box(sx - 0.045, y1 + 0.01, lid_z0 - 0.02, sx + 0.045, y1 + 0.04, lid_z0 + 0.05, RED, shine=0.3)
        s.box(sx - 0.032, y1 + 0.04, lid_z0 - 0.005, sx + 0.032, y1 + 0.046, lid_z0 + 0.035, WHITE)
        flat_decal(s, x0 + 0.03, y0 + 0.04, x0 + 0.16, y0 + 0.2, lid_z1 + 0.012, acorn_mark(30, STENCIL))
    else:
        # the lid stands open on its hinge at the back, leaning over the back edge
        rot = rotation((1, 0, 0), 24)
        size = (x1 - x0 + 0.024, 0.11, y1 - y0 + 0.02)
        hinge = ((x0 + x1) / 2, y0 + 0.02, zb)
        centre = add(hinge, apply(rot, (0, -0.045, size[2] / 2)))
        # inside the lid: foam
        s.xbox(centre, size, rot, OD, top=OD_DARK, shine=0.15)
        stick(s, centre, rot, size, '+y', noise_texture(40, 40, 3, FOAM, spread=22), margin=0.02, offset=0.002)
        stick(s, centre, rot, size, '-y', acorn_mark(50, STENCIL), margin=0.14, offset=0.003)
        # the body's inside: the foam bed with the cut-outs
        s.box(x0 + 0.02, y0 + 0.02, zb - 0.03, x1 - 0.02, y1 - 0.02, zb - 0.01, (28, 30, 28))
        s.box(x0 + 0.045, y0 + 0.045, zb - 0.01, x1 - 0.045, y1 - 0.045, zb, FOAM, top=(72, 80, 68))
        for i in range(3):
            bx = x0 + 0.09 + i * 0.185
            s.box(bx, y0 + 0.09, zb - 0.005, bx + 0.13, y1 - 0.09, zb + 0.004, (30, 34, 30))
        # a rim around the opening
        for (ax, ay, bx2, by2) in ((x0, y0, x1, y0 + 0.025), (x0, y1 - 0.025, x1, y1), (x0, y0, x0 + 0.025, y1),
                                   (x1 - 0.025, y0, x1, y1)):
            s.box(ax, ay, zb, bx2, by2, zb + 0.015, OD_DARK)
    ground = shadow((0.52, 0.5), 0.46, 0.32, 120)
    return compose(s, ground=ground, seed=21 + (1 if sealed else 0), glows=glows)


def supply_crate(opened):
    """The supply crate: a military crate of olive boards with steel corner brackets and rope handles, the team's mark
    and stencilled lettering on its sides. Sealed: a steel strap over the lid and a lead seal. Opened: the lid is
    propped open and the packing straw shows with a few supplies in it."""
    s = Scene(0)
    glows = []
    x0, x1, y0, y1 = 0.12, 0.88, 0.20, 0.80
    zb, zt = 0.36, 0.46
    s.box(x0, y0, 0.0, x1, y1, zb, OD, top=OD_DARK, shine=0.05)
    # board texture on the visible sides
    front_decal(s, x0, x1, 0.0, zb, y1 + 0.001, plank_lines(120, 40, 5, OD, lines=4, spread=9), offset=0.001)
    side_decal(s, y0, y1, 0.0, zb, x1 + 0.001, plank_lines(100, 40, 6, OD, lines=4, spread=9), offset=0.001)
    # skids and battens
    for bx in (x0 + 0.02, x1 - 0.05):
        s.box(bx, y1, 0.0, bx + 0.03, y1 + 0.012, zb, OD_DARK)
    for by in (y0 + 0.02, y1 - 0.05):
        s.box(x1, by, 0.0, x1 + 0.012, by + 0.03, zb, OD_DARK)
    s.box(x0 - 0.02, y0 - 0.02, 0.0, x1 + 0.02, y0 + 0.02, 0.025, WOOD_DARK)
    s.box(x0 - 0.02, y1 - 0.02, 0.0, x1 + 0.02, y1 + 0.02, 0.025, WOOD_DARK)
    # steel corner brackets
    for cx, w in ((x0, 0.0), (x1 - 0.06, 0.0)):
        s.box(cx - 0.004, y1 - 0.004, 0.0, cx + 0.064, y1 + 0.018, zb, STEEL_DARK, shine=0.5)
    s.box(x1 - 0.004, y0 - 0.004, 0.0, x1 + 0.018, y0 + 0.06, zb, STEEL_DARK, shine=0.5)
    s.box(x1 - 0.004, y1 - 0.06, 0.0, x1 + 0.018, y1 + 0.004, zb, STEEL_DARK, shine=0.5)
    # stencil: lettering and the mark
    front_decal(s, x0 + 0.13, x0 + 0.52, 0.14, 0.26, y1 + 0.02, stencil_text('SUPPLY', 76, 24, STENCIL))
    front_decal(s, x0 + 0.08, x0 + 0.52, 0.06, 0.12, y1 + 0.02, stencil_text('OAK-7  NO.0000', 80, 12, STENCIL))
    front_decal(s, x1 - 0.30, x1 - 0.12, 0.07, 0.30, y1 + 0.02, acorn_mark(36, STENCIL))
    side_decal(s, y0 + 0.14, y1 - 0.14, 0.12, 0.26, x1 + 0.02, stencil_text('OAK-7', 54, 20, STENCIL))
    # rope handles at the short ends
    for z in (0.22,):
        s.tube((x1 + 0.012, y0 + 0.19, z), (x1 + 0.05, y0 + 0.19, z), 0.012, TAN, segments=8)
        s.tube((x1 + 0.012, y1 - 0.19, z), (x1 + 0.05, y1 - 0.19, z), 0.012, TAN, segments=8)
        s.tube((x1 + 0.05, y0 + 0.19, z), (x1 + 0.05, y1 - 0.19, z), 0.014, TAN, segments=8, shine=0.05)
    if not opened:
        s.box(x0 - 0.012, y0 - 0.012, zb, x1 + 0.012, y1 + 0.012, zt, OD, top=OD_LIGHT, shine=0.05)
        flat_decal(s, x0 - 0.012, y0 - 0.012, x1 + 0.012, y1 + 0.012, zt,
                   plank_lines(120, 80, 8, OD_LIGHT, lines=4, vertical=False, spread=9), offset=0.001)
        front_decal(s, x0 - 0.012, x1 + 0.012, zb, zt, y1 + 0.012, plank_lines(120, 10, 9, OD, lines=1), offset=0.001)
        # the steel strap over the lid with its seal
        sx = 0.60
        s.box(sx - 0.03, y0 - 0.016, zb - 0.02, sx + 0.03, y1 + 0.016, zt + 0.008, STEEL, shine=0.5)
        s.box(sx - 0.03, y1 + 0.016, zb - 0.02, sx + 0.03, y1 + 0.022, zt + 0.008, STEEL_DARK, shine=0.3)
        s.box(sx - 0.016, y1 + 0.024, zb - 0.01, sx + 0.016, y1 + 0.05, zb + 0.04, (120, 124, 128), shine=0.6)
        s.box(sx - 0.011, y1 + 0.05, zb - 0.002, sx + 0.011, y1 + 0.056, zb + 0.032, RED)
        s.tube((sx, 0.46, zt + 0.008), (sx, 0.5, zt + 0.011), 0.02, RED, segments=12)
        # the mark on the lid
        flat_decal(s, x0 + 0.05, y0 + 0.08, x0 + 0.33, y0 + 0.36, zt + 0.001, acorn_mark(50, STENCIL))
    else:
        # the body's rim and its inside: straw, goods
        s.box(x0, y0, zb - 0.01, x0 + 0.03, y1, zb, OD_DARK)
        s.box(x1 - 0.03, y0, zb - 0.01, x1, y1, zb, OD_DARK)
        s.box(x0, y0, zb - 0.01, x1, y0 + 0.03, zb, OD_DARK)
        s.box(x0, y1 - 0.03, zb - 0.01, x1, y1, zb, OD_DARK)
        s.box(x0 + 0.03, y0 + 0.03, zb - 0.1, x1 - 0.03, y1 - 0.03, zb - 0.03, (36, 34, 30))
        rnd = random.Random(4)
        s.box(x0 + 0.03, y0 + 0.03, zb - 0.03, x1 - 0.03, y1 - 0.03, zb - 0.01, STRAW)
        for i in range(10):
            bx, by = x0 + 0.06 + rnd.random() * 0.56, y0 + 0.06 + rnd.random() * 0.34
            s.box(bx, by, zb - 0.012, bx + 0.12, by + 0.04, zb - 0.002, tuple(int(c * (0.8 + rnd.random() * 0.3)) for c in STRAW))
        # goods in the straw: an ammo can, a first-aid box, ration tins, a wrapped bundle
        s.box(0.20, 0.28, zb - 0.04, 0.42, 0.44, zb + 0.07, OD_DARK, top=OD, shine=0.2)
        s.box(0.285, 0.275, zb + 0.07, 0.335, 0.285, zb + 0.09, STEEL_DARK)
        s.box(0.46, 0.3, zb - 0.03, 0.66, 0.46, zb + 0.06, WHITE, top=(236, 234, 224))
        s.box(0.545, 0.455, zb + 0.005, 0.575, 0.465, zb + 0.05, RED)
        s.box(0.53, 0.46, zb + 0.02, 0.59, 0.466, zb + 0.035, RED)
        for i, (tx, ty) in enumerate(((0.22, 0.56), (0.31, 0.62), (0.40, 0.55), (0.50, 0.63))):
            s.tube((tx, ty, zb - 0.03), (tx, ty, zb + 0.04), 0.036, (150, 140, 120), cap=STEEL, shine=0.4, segments=16)
        s.box(0.60, 0.52, zb - 0.03, 0.80, 0.70, zb + 0.05, CANVAS, top=(166, 156, 120))
        s.box(0.605, 0.60, zb + 0.0, 0.795, 0.615, zb + 0.052, (110, 100, 70))
        # the lid, propped open at the back over its hinge, its inside showing
        rot = rotation((1, 0, 0), 22)
        size = (x1 - x0 + 0.024, 0.07, y1 - y0 + 0.024)
        hinge = ((x0 + x1) / 2, y0 + 0.02, zb)
        centre = add(hinge, apply(rot, (0, -0.03, size[2] / 2)))
        s.xbox(centre, size, rot, OD, top=OD_DARK, shine=0.05)
        stick(s, centre, rot, size, '+y', plank_lines(110, 60, 11, OD_DARK, lines=4, spread=9), margin=0.012, offset=0.002)
        stick(s, centre, rot, size, '-y', acorn_mark(60, STENCIL), margin=0.2, offset=0.003)
        # the strap hanging off the lid
        s.box(0.58, y1 - 0.015, zb - 0.12, 0.64, y1 + 0.0, zb, STEEL, shine=0.5)
    ground = shadow((0.5, 0.5), 0.5, 0.36, 130)
    return compose(s, ground=ground, seed=31 + (1 if opened else 0), glows=glows)


def parachute_crate():
    """The crate on its parachute for the drop: a small crate hanging from risers under an orange-and-cream canopy."""
    s = Scene(0)
    glows = []
    cx, cy = 0.5, 0.5
    # the crate
    s.box(0.32, 0.34, 0.0, 0.68, 0.66, 0.30, OD, top=OD_LIGHT, shine=0.05)
    s.box(0.30, 0.32, 0.0, 0.70, 0.36, 0.03, WOOD_DARK)
    s.box(0.30, 0.64, 0.0, 0.70, 0.68, 0.03, WOOD_DARK)
    front_decal(s, 0.34, 0.60, 0.07, 0.19, 0.661, stencil_text('SUPPLY', 60, 22, STENCIL))
    front_decal(s, 0.60, 0.67, 0.08, 0.22, 0.661, acorn_mark(24, STENCIL))
    side_decal(s, 0.38, 0.62, 0.07, 0.19, 0.681, stencil_text('DROP', 50, 20, STENCIL))
    for (sx, sy) in ((0.32, 0.66), (0.68, 0.66), (0.68, 0.34)):
        s.box(sx - 0.015, sy - 0.015, 0.0, sx + 0.015, sy + 0.015, 0.30, STEEL_DARK, shine=0.5)
    # the risers: four straps to a ring above the crate, then the shroud lines out to the canopy's rim
    ring = (0.5, 0.5, 0.80)
    for (sx, sy) in ((0.32, 0.66), (0.68, 0.66), (0.68, 0.34), (0.32, 0.34)):
        s.tube((sx, sy, 0.30), ring, 0.007, TAN, segments=6)
    s.tube((0.5, 0.5, 0.78), (0.5, 0.5, 0.82), 0.022, STEEL, shine=0.6, segments=12)
    # the canopy: a deflated dome of eight panels, the rim at z 1.25 and a crown at 1.78
    colours = [ORANGE, (236, 226, 200)]
    centre = (0.5, 0.5, 1.22)
    s.sphere(centre, (0.62, 0.62, 0.62), ORANGE, rings=8, segments=16, z_from=2, z_to=88, colours=colours, shine=0.05)
    rim_r = 0.62 * math.cos(math.radians(2))
    for i in range(16):
        a = 2 * math.pi * i / 16
        px, py = 0.5 + rim_r * math.cos(a), 0.5 + rim_r * math.sin(a)
        s.tube(ring, (px, py, 1.22 + 0.62 * math.sin(math.radians(2))), 0.004, (210, 200, 176), segments=5)
    s.tube((0.5, 0.5, 1.84), (0.5, 0.5, 1.87), 0.02, (200, 190, 160), segments=8)
    ground = shadow((0.5, 0.5), 0.34, 0.26, 110)
    return compose(s, ground=ground, seed=41, glows=glows)


def scorched_ground():
    """A burnt patch on the ground where something came down: a black core, a ragged brown scorch round it, ash and
    cinder, thin streaks thrown outward. A decal on the floor, nothing standing."""
    n = 320
    rnd = np.random.RandomState(7)
    yy, xx = np.mgrid[0:n, 0:n]
    cx = cy = n / 2
    dx, dy = (xx - cx) / (n / 2), (yy - cy) / (n / 2)
    r = np.sqrt(dx * dx + dy * dy)
    theta = np.arctan2(dy, dx)
    # a ragged outline: radius as a sum of a few waves of the angle
    ragged = 0.80 + 0.10 * np.sin(3 * theta + 1.0) + 0.07 * np.sin(5 * theta + 2.2) + 0.05 * np.sin(9 * theta + 0.4)
    # streaks thrown out
    streak = np.maximum(0, np.cos(7 * theta + 0.5)) ** 12 * 0.3 * np.exp(-r * 1.4)
    edge = ragged + streak
    noise = rnd.randn(n // 8 + 1, n // 8 + 1)
    noise = np.asarray(Image.fromarray(((noise - noise.min()) / (np.ptp(noise)) * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC)) / 255.0
    fine = rnd.rand(n, n)
    t = r / edge  # 0 at the middle, 1 at the outline
    t = t + (noise - 0.5) * 0.35
    core = np.clip(1 - t / 0.7, 0, 1) ** 0.7
    alpha = np.clip((1.0 - t) * 4.0, 0, 1) * 0.95
    alpha *= 0.85 + 0.15 * fine
    rgb = np.zeros((n, n, 3))
    scorch = np.array([70, 56, 44], float)
    black = np.array([14, 13, 12], float)
    rgb[:] = scorch + (black - scorch) * core[..., None]
    # ash: pale dust, mostly in the middle band
    ash = (noise > 0.58) & (t < 0.8) & (fine > 0.35)
    rgb[ash] = rgb[ash] * 0.5 + np.array([124, 120, 112]) * 0.5
    # cinder specks
    speck = (fine > 0.992) & (t < 0.7)
    rgb[speck] = np.array([150, 70, 30])
    out = np.concatenate([rgb, (alpha * 255)[..., None]], axis=2).astype(np.uint8)
    img = Image.fromarray(out, 'RGBA').filter(ImageFilter.GaussianBlur(0.8))
    s = Scene(0)
    # the whole square: the image spans the diamond's bounding square on the ground
    flat_decal(s, 0.0, 0.0, 1.0, 1.0, 0.0, img, offset=0.0)
    # a few charred scraps lying about, flat boards and bits of metal
    rn = random.Random(5)
    for i in range(6):
        a = rn.random() * 6.28
        d = 0.18 + rn.random() * 0.22
        px, py = 0.5 + math.cos(a) * d, 0.5 + math.sin(a) * d
        w, l = 0.025 + rn.random() * 0.03, 0.06 + rn.random() * 0.07
        rot = rotation((0, 0, 1), rn.random() * 180)
        s.xbox((px, py, 0.012), (l, w, 0.022), rot, (30, 26, 24), top=(46, 40, 36))
    return compose(s, seed=51)


def meteor_rocks():
    """Where the fragments lie: a few dark lumps of the stone with rust-brown crust, one large, some chips round
    them, on a small scorch of their own."""
    s = Scene(0)
    base = (66, 58, 54)
    crust = (122, 78, 48)
    # a small scorch under them
    rn = random.Random(2)
    n = 200
    yy, xx = np.mgrid[0:n, 0:n]
    r = np.sqrt(((xx - n / 2) / (n / 2)) ** 2 + ((yy - n / 2) / (n / 2)) ** 2)
    a = np.clip((0.95 - r) * 2.2, 0, 1) * 0.7 * (0.8 + 0.2 * np.random.RandomState(3).rand(n, n))
    img = np.zeros((n, n, 4), np.uint8)
    img[..., :3] = (34, 30, 28)
    img[..., 3] = (a * 255).astype(np.uint8)
    flat_decal(s, 0.1, 0.1, 0.9, 0.9, 0.0, Image.fromarray(img, 'RGBA').filter(ImageFilter.GaussianBlur(2)), offset=0.0)
    s.rock((0.46, 0.50, 0.17), 0.27, 11, base, squash=(1.1, 0.95, 0.85), detail=1, jitter=0.30, colour2=crust, shine=0.12)
    s.rock((0.70, 0.62, 0.07), 0.13, 12, base, squash=(1.0, 1.0, 0.75), detail=1, jitter=0.30, colour2=crust, shine=0.12)
    s.rock((0.30, 0.72, 0.05), 0.10, 13, (74, 64, 58), squash=(1.2, 0.9, 0.7), detail=1, jitter=0.30, colour2=crust, shine=0.1)
    s.rock((0.66, 0.30, 0.04), 0.075, 14, (60, 54, 52), squash=(1.0, 1.0, 0.7), detail=0, jitter=0.25, colour2=crust)
    s.rock((0.24, 0.36, 0.03), 0.06, 15, (70, 62, 58), squash=(1.0, 1.0, 0.7), detail=0, jitter=0.25)
    for i in range(7):
        px, py = 0.15 + rn.random() * 0.7, 0.2 + rn.random() * 0.65
        s.rock((px, py, 0.012), 0.025 + rn.random() * 0.02, 20 + i, (78, 68, 62), squash=(1, 1, 0.6), detail=0, jitter=0.3)
    # the freshly broken face of the big one: a pale metallic gleam
    ground = None
    return compose(s, ground=ground, seed=61)


def site_stake():
    """A survey stake with its number: a wood post with an orange head, a tag with the stake number on both sides,
    a streamer of hazard tape, and a ring of stones holding it up."""
    s = Scene(0)
    cx, cy = 0.5, 0.5
    # the stones round its foot
    for i, (dx, dy, r) in enumerate(((0.10, 0.06, 0.07), (-0.08, 0.09, 0.06), (-0.11, -0.04, 0.065), (0.06, -0.10, 0.06),
                                     (0.0, 0.14, 0.05))):
        s.rock((cx + dx, cy + dy, 0.02), r, 70 + i, (110, 106, 98), squash=(1, 1, 0.65), detail=0, jitter=0.2,
               colour2=(86, 82, 76))
    # the stake: square post, its top painted orange, tapered tip
    h = 1.05
    s.box(cx - 0.028, cy - 0.028, 0.02, cx + 0.028, cy + 0.028, h, WOOD, top=WOOD_DARK, shine=0.05)
    s.box(cx - 0.0285, cy - 0.0285, h - 0.17, cx + 0.0285, cy + 0.0285, h, ORANGE, top=(250, 150, 60))
    # the tag: an aluminium plate turned to face the viewer, the number on it
    rot = rotation((0, 0, 1), -45)
    size = (0.22, 0.012, 0.2)
    centre = (cx + 0.045, cy + 0.045, 0.72)
    s.xbox(centre, size, rot, (196, 200, 202), shine=0.5)
    stick(s, centre, rot, size, '+y', stencil_text('NO.07', 50, 30, (40, 40, 40)), margin=0.02, offset=0.002)
    # a streamer of tape knotted below the head, blowing east
    pts = [(cx + 0.03, cy, 0.95), (cx + 0.16, cy + 0.02, 0.93), (cx + 0.28, cy - 0.02, 0.97), (cx + 0.38, cy + 0.02, 0.92)]
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        col = ORANGE if i % 2 == 0 else (236, 232, 220)
        s.poly([(a[0], a[1], a[2] + 0.035), (b[0], b[1], b[2] + 0.035), (b[0], b[1], b[2] - 0.035), (a[0], a[1], a[2] - 0.035)],
               col, (0, 1, 0.2))
        s.poly([(a[0], a[1], a[2] + 0.035), (b[0], b[1], b[2] + 0.035), (b[0], b[1], b[2] - 0.035), (a[0], a[1], a[2] - 0.035)],
               col, (0, -1, -0.2))
    ground = shadow((0.5, 0.5), 0.22, 0.16, 100)
    return compose(s, ground=ground, seed=71)
