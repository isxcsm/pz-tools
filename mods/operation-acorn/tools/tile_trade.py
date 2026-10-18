"""The trade sheet's objects (besides the terminal): the delivery box, the supply crate, the parachute crate, the scorched
ground, the meteor rocks, the drop-site stake, the crude terminal (the first-day one the terminal upgrades), and what
lies round a drop site (dark soil that looks wet, a cut length of marker tape, an empty sample bag, stones in a row)."""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from tile_engine import (Scene, shadow, compose, unit, rotation, apply, add, sub, mul, stencil_text, acorn_mark,
                         IDENTITY, project, SS, W, H, UP)
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, lamp, stick, flat_decal, front_decal,
                          side_decal, noise_texture, face_frame, lamp_y, knob_y, dial_image)

FOAM = (58, 64, 56)


def egg_crate(w=96, h=96, cell=12, base=FOAM):
    """Egg-crate packing foam: rows of soft bumps, each lit on its upper left and shaded on its lower right."""
    img = Image.new('RGBA', (w, h), base + (255,))
    d = ImageDraw.Draw(img)
    light = tuple(min(255, c + 22) for c in base) + (255,)
    dark = tuple(int(c * 0.72) for c in base) + (255,)
    for row, y in enumerate(range(0, h + cell, cell)):
        for x in range(-cell, w + cell, cell):
            ox = x + (cell // 2 if row % 2 else 0)
            d.ellipse([ox + 2, y + 2, ox + cell - 1, y + cell - 1], fill=dark)
            d.ellipse([ox + 1, y + 1, ox + cell - 3, y + cell - 3], fill=light)
            d.ellipse([ox + 3, y + 3, ox + cell - 4, y + cell - 4], fill=base + (255,))
    return img
STRAW = (190, 168, 110)
ORANGE = (196, 104, 46)


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
        stick(s, centre, rot, size, '+y', egg_crate(), margin=0.02, offset=0.002)
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


# The supply crate's box: its sides and its lid's top (the parachute crate hangs the same crate from its risers).
CRATE_X0, CRATE_X1, CRATE_Y0, CRATE_Y1 = 0.12, 0.88, 0.20, 0.80
CRATE_ZB, CRATE_ZT = 0.36, 0.46


def supply_crate(opened):
    """The supply crate: a military crate of olive boards with steel corner brackets and rope handles, the team's mark
    and stencilled lettering on its sides. Sealed: a steel strap over the lid and a lead seal. Opened: the lid is
    propped open and the packing straw shows with a few supplies in it."""
    s = Scene(0)
    glows = []
    crate_parts(s, opened)
    ground = shadow((0.5, 0.5), 0.5, 0.36, 130)
    return compose(s, ground=ground, seed=31 + (1 if opened else 0), glows=glows)


def crate_parts(s, opened):
    """The supply crate's solids, added to a scene."""
    x0, x1, y0, y1 = CRATE_X0, CRATE_X1, CRATE_Y0, CRATE_Y1
    zb, zt = CRATE_ZB, CRATE_ZT
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


def parachute_crate():
    """The crate on its parachute for the drop: the sealed supply crate itself (as large as it lies once landed, the
    canopy alone goes) hanging from risers under an orange-and-cream canopy."""
    s = Scene(0)
    glows = []
    crate_parts(s, False)
    # the risers: four straps from the lid's corners to a ring above the crate, then the shroud lines out to the
    # canopy's rim
    x0, x1, y0, y1, zt = CRATE_X0, CRATE_X1, CRATE_Y0, CRATE_Y1, CRATE_ZT
    ring = (0.5, 0.5, 1.02)
    for (sx, sy) in ((x0 + 0.02, y1 - 0.02), (x1 - 0.02, y1 - 0.02), (x1 - 0.02, y0 + 0.02), (x0 + 0.02, y0 + 0.02)):
        s.tube((sx, sy, zt), ring, 0.012, TAN, segments=6)
    s.tube((0.5, 0.5, 1.00), (0.5, 0.5, 1.04), 0.024, STEEL, shine=0.6, segments=12)
    # the canopy: a low dome of sixteen gores in faded orange and cream (a full half sphere in clean colours read as
    # a beach ball), eight shroud lines down to the ring (sixteen hair-thin ones broke into dots). As wide as the tile
    # lets it be: a canopy narrower than the crate under it would read as a toy.
    colours = [(178, 104, 58), (186, 178, 158)]
    cz = 1.46
    centre = (0.5, 0.5, cz)
    s.sphere(centre, (0.66, 0.66, 0.46), colours[0], rings=8, segments=16, z_from=4, z_to=90, colours=colours,
             shine=0.05)
    rim_r, rim_z = 0.66 * math.cos(math.radians(4)), cz + 0.46 * math.sin(math.radians(4))
    for i in range(8):
        a = 2 * math.pi * (i + 0.5) / 8
        px, py = 0.5 + rim_r * math.cos(a), 0.5 + rim_r * math.sin(a)
        s.tube(ring, (px, py, rim_z), 0.007, (176, 166, 140), segments=5)
    s.tube((0.5, 0.5, cz + 0.45), (0.5, 0.5, cz + 0.48), 0.03, (170, 160, 136), segments=8)
    ground = shadow((0.5, 0.5), 0.5, 0.36, 130)
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
    s.rock((0.46, 0.50, 0.17), 0.27, 11, base, squash=(1.1, 0.95, 0.85), detail=2, jitter=0.2, colour2=crust, shine=0.22, patches=True)
    s.rock((0.70, 0.62, 0.07), 0.13, 12, base, squash=(1.0, 1.0, 0.75), detail=2, jitter=0.22, colour2=crust, shine=0.2, patches=True)
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
    s.box(cx - 0.0285, cy - 0.0285, h - 0.17, cx + 0.0285, cy + 0.0285, h, ORANGE, top=(214, 136, 66))
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
        col = ORANGE if i % 2 == 0 else (206, 200, 186)
        s.poly([(a[0], a[1], a[2] + 0.035), (b[0], b[1], b[2] + 0.035), (b[0], b[1], b[2] - 0.035), (a[0], a[1], a[2] - 0.035)],
               col, (0, 1, 0.2))
        s.poly([(a[0], a[1], a[2] + 0.035), (b[0], b[1], b[2] + 0.035), (b[0], b[1], b[2] - 0.035), (a[0], a[1], a[2] - 0.035)],
               col, (0, -1, -0.2))
    ground = shadow((0.5, 0.5), 0.22, 0.16, 100)
    return compose(s, ground=ground, seed=71)


# ----------------------------------------------------------------------------------------------------------------
# What lies round a drop site (story-improvements 10): flat things on the ground, nothing that gives light.

def _patch(n, seed, ragged_waves, cx=0.5, cy=0.5, size=0.8):
    """A ragged blob for a ground decal: (t, noise, fine) arrays, t 0 at its middle and 1 at its outline."""
    rnd = np.random.RandomState(seed)
    yy, xx = np.mgrid[0:n, 0:n]
    dx, dy = (xx - cx * n) / (n * size / 2), (yy - cy * n) / (n * size / 2)
    r = np.sqrt(dx * dx + dy * dy)
    theta = np.arctan2(dy, dx)
    ragged = 0.82 + sum(a * np.sin(k * theta + ph) for k, a, ph in ragged_waves)
    noise = rnd.randn(n // 8 + 1, n // 8 + 1)
    noise = np.asarray(Image.fromarray(((noise - noise.min()) / (np.ptp(noise)) * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC)) / 255.0
    fine = rnd.rand(n, n)
    t = r / ragged + (noise - 0.5) * 0.3
    return t, noise, fine


def damp_soil():
    """Earth darker than the ground round it, as if just rained on: a deep brown patch, nearly black in the middle,
    with a faint wet sheen in a few places and a few small stones. A decal on the floor."""
    n = 300
    t, noise, fine = _patch(n, 17, ((3, 0.08, 0.6), (5, 0.06, 2.0), (8, 0.04, 1.1)), size=0.86)
    alpha = np.clip((1.0 - t) * 3.0, 0, 1) * 0.92
    rgb = np.zeros((n, n, 3))
    edge = np.array([78, 60, 42], float)
    deep = np.array([46, 34, 24], float)
    mix = np.clip(1 - t, 0, 1) ** 0.6
    rgb[:] = edge + (deep - edge) * mix[..., None]
    rgb += (fine[..., None] - 0.5) * 10
    # the sheen: pale smears where the noise peaks, as on wet clay
    sheen = np.clip((noise - 0.66) * 6, 0, 1) * (t < 0.75)
    rgb = rgb + (np.array([118, 112, 104]) - rgb) * (sheen[..., None] * 0.6)
    out = np.concatenate([np.clip(rgb, 0, 255), (alpha * 255)[..., None]], axis=2).astype(np.uint8)
    img = Image.fromarray(out, 'RGBA').filter(ImageFilter.GaussianBlur(0.9))
    s = Scene(0)
    flat_decal(s, 0.0, 0.0, 1.0, 1.0, 0.0, img, offset=0.0)
    rn = random.Random(23)
    for i in range(5):
        a = rn.random() * 6.28
        d = 0.08 + rn.random() * 0.25
        s.rock((0.5 + math.cos(a) * d, 0.5 + math.sin(a) * d, 0.01), 0.018 + rn.random() * 0.012, 80 + i,
               (70, 62, 56), squash=(1, 1, 0.6), detail=0, jitter=0.3)
    return compose(s, seed=81)


def _ribbon(s, pts, width, colours, z=0.006):
    """A flat ribbon along a path on the ground, in alternating colours a segment each."""
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length * width / 2, dx / length * width / 2
        quad = [(ax + nx, ay + ny, z), (bx + nx, by + ny, z), (bx - nx, by - ny, z), (ax - nx, ay - ny, z)]
        s.poly(quad, colours[i % len(colours)], (0, 0, 1))


def cut_tape():
    """A length of orange and white marker tape on the ground, cut in two: one end still knotted to a short peg
    that was pushed in and snapped off, the rest blown a little way, its cut ends square."""
    s = Scene(0)
    white = (206, 200, 186)
    # the snapped peg, a stub of wood with the knot
    s.box(0.24, 0.30, 0.0, 0.29, 0.35, 0.10, WOOD, top=(168, 130, 84), shine=0.05)
    s.tube((0.265, 0.325, 0.07), (0.265, 0.325, 0.085), 0.034, ORANGE, segments=10)
    # the piece tied to it, lying out from the peg
    _ribbon(s, [(0.28, 0.34), (0.36, 0.40), (0.44, 0.43), (0.50, 0.47)], 0.05, (ORANGE, white))
    # the other piece, further off, curled once
    _ribbon(s, [(0.58, 0.52), (0.66, 0.53), (0.73, 0.58), (0.76, 0.66), (0.71, 0.72), (0.64, 0.70)], 0.05,
            (white, ORANGE), z=0.007)
    ground = shadow((0.5, 0.5), 0.3, 0.2, 40)
    return compose(s, ground=ground, seed=91)


def sample_bag():
    """An empty sample bag dropped on the ground: clear plastic gone milky, a red seal strip along its top, a white
    label with nothing written on it, creased."""
    w, h = 180, 140
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([4, 4, w - 5, h - 5], fill=(214, 220, 222, 120), outline=(240, 244, 246, 190), width=3)
    d.rectangle([4, 4, w - 5, 20], fill=(196, 52, 44, 210))                     # the seal strip
    d.line([(4, 24), (w - 5, 24)], fill=(240, 244, 246, 170), width=2)
    d.rectangle([22, 44, 98, 92], fill=(246, 244, 236, 235), outline=(170, 168, 160, 235))   # the label
    for y in (58, 70, 82):
        d.line([(30, y), (90, y)], fill=(176, 172, 160, 235), width=1)            # its empty lines
    for x0, y0, x1, y1 in ((110, 30, 150, 120), (60, 100, 170, 112), (30, 30, 40, 128)):
        d.line([(x0, y0), (x1, y1)], fill=(250, 252, 252, 110), width=2)          # creases
    img = img.rotate(-24, resample=Image.BICUBIC, expand=True)
    s = Scene(0)
    flat_decal(s, 0.24, 0.26, 0.76, 0.74, 0.0, img, offset=0.004)
    return compose(s, seed=101)


def stone_row():
    """Stones about the size of a fist laid in a straight row across one side of the square, as if to mark a line:
    grey field stones, much alike, evenly spaced."""
    s = Scene(0)
    rn = random.Random(9)
    for i in range(6):
        t = i / 5.0
        x, y = 0.18 + t * 0.62, 0.70 - t * 0.38
        r = 0.045 + rn.random() * 0.012
        s.rock((x, y, r * 0.55), r, 110 + i, (124, 120, 112), squash=(1.1, 0.95, 0.65), detail=1, jitter=0.18,
               colour2=(98, 94, 88), shine=0.05)
    ground = shadow((0.49, 0.51), 0.36, 0.12, 60)
    return compose(s, ground=ground, seed=111)


# ----------------------------------------------------------------------------------------------------------------
# The crude terminal: the first-day communication terminal the player puts together from a home computer and a ham
# radio. The polished terminal (tile_objects.terminal) is the upgrade bought later; this one stands on the same square
# with about the same height, so it reads as the same object, only jury-rigged.

BEIGE = (176, 166, 140)          # an old home computer's yellowed plastic
BEIGE_DARK = (140, 132, 108)
BEIGE_LIGHT = (190, 182, 158)
HAM = (56, 58, 60)               # the ham radio's black case
HAM_FACE = (178, 180, 176)       # its brushed front panel
TAPE = (172, 174, 170)           # duct tape
CRATE = (160, 126, 82)           # a fruit crate's raw boards
CRATE_DARK = (118, 90, 56)
PHOSPHOR = (90, 255, 120)        # a green monochrome monitor's glow


def crt_image(on, w=64, h=48):
    """The CRT's glass: on, a green monochrome screen of lines of text with a prompt and a cursor, the corners dimmed
    by the tube's curve; off, dark grey glass with a pale reflection."""
    if not on:
        img = Image.new('RGBA', (w, h), (44, 48, 46, 255))
        d = ImageDraw.Draw(img)
        d.polygon([(w * 0.08, 0), (w * 0.42, 0), (w * 0.12, h * 0.7)], fill=(62, 68, 64, 255))
        d.polygon([(w * 0.5, 0), (w * 0.58, 0), (w * 0.3, h), (w * 0.22, h)], fill=(54, 60, 56, 255))
    else:
        img = Image.new('RGBA', (w, h), (8, 34, 14, 255))
        d = ImageDraw.Draw(img)
        bright, dim = (150, 255, 160, 255), (60, 190, 80, 255)
        rnd = random.Random(23)
        for row in range(6):
            y = 4 + row * 7
            x = 4
            limit = rnd.randint(w // 2, w - 6)
            while x < limit:
                word = rnd.randint(2, 6) * 3
                d.rectangle([x, y, min(limit, x + word), y + 2], fill=bright if row % 2 == 0 else dim)
                x += word + 4
        d.rectangle([4, h - 7, 8, h - 4], fill=bright)       # the prompt
        d.rectangle([12, h - 7, 15, h - 4], fill=bright)     # the cursor
    a = np.asarray(img).astype(np.float64)
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.sqrt(((xx - w / 2) / (w / 2)) ** 2 + ((yy - h / 2) / (h / 2)) ** 2)
    a[..., :3] *= np.clip(1.25 - r * 0.45, 0.45, 1.0)[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), 'RGBA')


def tower_front_image(w=32, h=72):
    """The computer tower's front: two 5.25-inch drive bays, a floppy slot, the badge and the vents."""
    img = Image.new('RGBA', (w, h), BEIGE + (255,))
    d = ImageDraw.Draw(img)
    for i in range(2):
        y = 6 + i * 11
        d.rectangle([3, y, w - 4, y + 8], fill=BEIGE_DARK + (255,))
        d.rectangle([6, y + 3, w - 7, y + 5], fill=(40, 40, 38, 255))
    d.rectangle([7, 31, w - 8, 36], fill=BEIGE_DARK + (255,))
    d.rectangle([9, 33, w - 10, 34], fill=(40, 40, 38, 255))
    d.rectangle([4, 42, 13, 46], fill=(70, 90, 150, 255))      # the maker's badge
    for i in range(5):
        d.line([(5, 54 + i * 3), (w - 6, 54 + i * 3)], fill=BEIGE_DARK + (255,), width=1)
    return img


def tape_x_image(w=48, h=48):
    """Two crossed strips of duct tape."""
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = TAPE + (255,)
    d.polygon([(2, 8), (8, 2), (46, 40), (40, 46)], fill=c)
    d.polygon([(40, 2), (46, 8), (8, 46), (2, 40)], fill=c)
    d.line([(9, 4), (44, 39)], fill=(196, 198, 194, 255), width=1)
    return img


def note_image(w=40, h=32):
    """A sheet of notepaper with a frequency and a call sign scrawled on it, taped at the top."""
    img = Image.new('RGBA', (w, h), (236, 232, 206, 255))
    d = ImageDraw.Draw(img)
    rnd = random.Random(5)
    for row in range(4):
        y = 9 + row * 6
        x = 4
        while x < w - 8:
            seg = rnd.randint(3, 8)
            d.line([(x, y + rnd.randint(-1, 1)), (x + seg, y + rnd.randint(-1, 1))], fill=(40, 50, 120, 255), width=1)
            x += seg + 3
    d.rectangle([w // 2 - 8, 0, w // 2 + 8, 4], fill=TAPE + (255,))
    return img


def cable(s, pts, r, colour):
    """A loose cable through the points: a chain of thin tubes with round joints."""
    for a, b in zip(pts, pts[1:]):
        s.tube(a, b, r, colour, segments=8)
    for p in pts[1:-1]:
        s.sphere(p, (r, r, r), colour, rings=3, segments=6)


def crude_terminal(turns, on):
    """The crude communication terminal: a beige home computer (tower, CRT monitor, keyboard) and a ham radio set on a
    fruit crate, joined with loose cables and duct tape; the radio sits on a phone book, its whip antenna taped on, the
    frequency on a note taped to the crate. Its front (the screen) is south. Lit: the monitor glows green with text, the
    radio's meter glows amber, its lamp and the computer's power lamp are lit."""
    s = Scene(turns)
    glows = []
    # The crate: raw boards with gaps on every side, darker corner posts, the top's boards across.
    x0, x1, y0, y1, zt = 0.12, 0.88, 0.25, 0.77, 0.40
    s.box(x0, y0, 0.0, x1, y1, zt, CRATE, top=CRATE, shine=0.03)
    centre, size = ((x0 + x1) / 2, (y0 + y1) / 2, zt / 2), (x1 - x0, y1 - y0, zt)
    for face, seed in (('+y', 81), ('-y', 82), ('+x', 83), ('-x', 84)):
        stick(s, centre, IDENTITY, size, face, plank_lines(96, 40, seed, CRATE, lines=4, spread=12), offset=0.001)
    flat_decal(s, x0, y0, x1, y1, zt, plank_lines(96, 64, 85, CRATE, lines=5, vertical=True, spread=12), offset=0.001)
    for cx, cy in ((x0, y0), (x1 - 0.035, y0), (x0, y1 - 0.035), (x1 - 0.035, y1 - 0.035)):
        s.box(cx - 0.006, cy - 0.006, 0.0, cx + 0.041, cy + 0.041, zt + 0.004, CRATE_DARK)
    # a faded stencil of the crate's first life, and the note with the frequency taped beside it
    front_decal(s, x0 + 0.08, x0 + 0.40, 0.08, 0.17, y1 + 0.002, stencil_text('APPLES', 60, 18, (88, 62, 36)))
    front_decal(s, x1 - 0.30, x1 - 0.10, 0.17, 0.33, y1 + 0.004, note_image())

    # The tower on the west, standing on the crate; tape crossed on its side where the panel came loose.
    tx0, tx1, ty0, ty1, tz1 = 0.15, 0.29, 0.31, 0.69, 0.82
    s.box(tx0, ty0, zt, tx1, ty1, tz1, BEIGE, top=BEIGE_LIGHT, shine=0.15)
    front_decal(s, tx0 + 0.01, tx1 - 0.01, zt + 0.03, tz1 - 0.02, ty1 + 0.001, tower_front_image())
    side_decal(s, ty0 + 0.08, ty0 + 0.24, tz1 - 0.24, tz1 - 0.08, tx1 + 0.001, tape_x_image())
    lamp_y(s, glows, tx0 + 0.035, ty1, zt + 0.08, 0.009, 'green', on)
    s.box(tx1 - 0.05, ty1, zt + 0.06, tx1 - 0.02, ty1 + 0.012, zt + 0.10, BEIGE_DARK)

    # The CRT monitor in the middle: the beige front with the glass, the tube's housing behind, a swivel foot.
    mx0, mx1, my1, mz0, mz1 = 0.30, 0.63, 0.67, 0.445, 0.77
    s.box(0.40, 0.44, zt, 0.54, 0.62, mz0, BEIGE_DARK, top=BEIGE)
    s.box(mx0, 0.50, mz0, mx1, my1, mz1, BEIGE, top=BEIGE_LIGHT, shine=0.15)
    s.box(mx0 + 0.04, 0.34, mz0 + 0.03, mx1 - 0.04, 0.50, mz1 - 0.03, BEIGE_DARK, top=BEIGE, shine=0.1)
    # the vents on the tube's back: the screen's green shows through them when it is on (seen from behind)
    vents = Image.new('RGBA', (40, 24), (0, 0, 0, 0))
    vd = ImageDraw.Draw(vents)
    for i in range(6):
        vd.rectangle([3 + i * 6, 3, 6 + i * 6, 20], fill=(70, 200, 96, 255) if on else (52, 50, 44, 255))
    s.decal((mx1 - 0.06, 0.34, mz1 - 0.06), (-(mx1 - mx0 - 0.12), 0, 0), (0, 0, -0.14), vents, (0, -1, 0), 0.003, on)
    front_decal(s, mx0 + 0.02, mx1 - 0.02, mz0 + 0.025, mz1 - 0.015, my1 + 0.001,
                Image.new('RGBA', (8, 8), (70, 68, 60, 255)))
    front_decal(s, mx0 + 0.03, mx1 - 0.03, mz0 + 0.045, mz1 - 0.025, my1 + 0.003, crt_image(on), emit=on)
    s.box(mx1 - 0.06, my1, mz0 + 0.005, mx1 - 0.035, my1 + 0.01, mz0 + 0.02, BEIGE_DARK)
    # a strip of tape over the top front corner
    s.box(mx0 + 0.03, 0.56, mz1, mx0 + 0.08, my1 + 0.004, mz1 + 0.004, TAPE, shine=0.3)
    s.box(mx0 + 0.03, my1, mz1 - 0.03, mx0 + 0.08, my1 + 0.004, mz1, TAPE, shine=0.3)
    # the keyboard in front of it
    s.box(0.31, 0.685, zt, 0.62, 0.765, zt + 0.018, BEIGE, top=BEIGE_LIGHT)
    kb = Image.new('RGBA', (60, 16), BEIGE_LIGHT + (255,))
    kd = ImageDraw.Draw(kb)
    for row in range(3):
        for col in range(13):
            kd.rectangle([2 + col * 4.4, 2 + row * 4.4, 4.8 + col * 4.4, 4.8 + row * 4.4], fill=(150, 142, 118, 255))
    flat_decal(s, 0.32, 0.695, 0.61, 0.755, zt + 0.018, kb)
    if on:
        glows.append(((0.47, my1 + 0.05, (mz0 + mz1) / 2), PHOSPHOR, 0.20, (0, 1, 0)))
        glows.append(((0.47, 0.72, zt + 0.03), PHOSPHOR, 0.12, (0, 1, 0.6)))   # seen only from the front

    # The ham radio on the east, on a phone book: black case, a brushed front with the meter, the tuning knob, two
    # small knobs, the lamp, handles; a whip antenna taped to its back corner.
    s.box(0.63, 0.40, zt, 0.87, 0.72, zt + 0.045, (200, 190, 90), top=(226, 222, 206))   # the phone book
    s.box(0.632, 0.402, zt + 0.006, 0.868, 0.718, zt + 0.04, (236, 232, 214))
    rx0, rx1, ry0, ry1, rz0, rz1 = 0.645, 0.87, 0.42, 0.70, zt + 0.045, zt + 0.20
    s.box(rx0, ry0, rz0, rx1, ry1, rz1, HAM, top=(72, 74, 76), shine=0.25)
    s.box(rx0, ry1, rz0, rx1, ry1 + 0.008, rz1, HAM_FACE, shine=0.45)
    front_decal(s, rx0 + 0.02, rx0 + 0.11, rz1 - 0.06, rz1 - 0.02, ry1 + 0.008, dial_image(on), emit=on)
    knob_y(s, rx0 + 0.16, ry1 + 0.008, rz0 + 0.065, 0.032, BLACK, 0.025)
    knob_y(s, rx0 + 0.04, ry1 + 0.008, rz0 + 0.03, 0.013, BLACK, 0.02)
    knob_y(s, rx0 + 0.085, ry1 + 0.008, rz0 + 0.03, 0.013, BLACK, 0.02)
    lamp_y(s, glows, rx1 - 0.025, ry1 + 0.008, rz1 - 0.025, 0.011, 'green', on)
    for hx in (rx0 - 0.004, rx1 - 0.008):
        s.box(hx, ry1 + 0.008, rz0 + 0.01, hx + 0.012, ry1 + 0.03, rz1 - 0.01, STEEL, shine=0.6)
    lamp(s, glows, rx0 + 0.04, ry0 + 0.06, rz1, 0.014, 'green', on)   # the power lamp on top, seen from every side
    if on:
        glows.append(((rx0 + 0.065, ry1 + 0.02, rz1 - 0.04), (255, 170, 60), 0.10, (0, 1, 0)))
    # the telescoping whip: three sections, a ball at the tip, leaning a little; tape round its foot
    base = (rx1 - 0.03, ry0 + 0.04, rz1)
    tip = (rx1 - 0.06, ry0 + 0.0, rz1 + 0.62)
    sec = [base, add(base, mul(sub(tip, base), 0.38)), add(base, mul(sub(tip, base), 0.7)), tip]
    for (a, b), r in zip(zip(sec, sec[1:]), (0.011, 0.008, 0.005)):
        s.tube(a, b, r, STEEL, shine=0.6, segments=8)
    s.sphere(tip, (0.012, 0.012, 0.012), STEEL, rings=4, segments=8, shine=0.6)
    s.tube((base[0], base[1], rz1 - 0.04), (base[0], base[1], rz1 + 0.05), 0.026, TAPE, cap=(150, 152, 148), shine=0.3,
           segments=12)
    # a strap of tape over the radio's east end and down onto the crate
    s.box(rx1 - 0.075, ry0 - 0.004, rz1, rx1 - 0.035, ry1 + 0.012, rz1 + 0.005, TAPE, shine=0.3)
    s.box(rx1 - 0.075, ry1 + 0.008, zt - 0.06, rx1 - 0.035, ry1 + 0.014, rz1 + 0.005, TAPE, shine=0.3)
    s.box(rx1 - 0.075, ry1 + 0.008, zt, rx1 - 0.035, y1 + 0.004, zt + 0.004, TAPE, shine=0.3)
    s.box(rx1 - 0.075, y1, zt - 0.08, rx1 - 0.035, y1 + 0.006, zt + 0.004, TAPE, shine=0.3)

    # The cables: the computer to the radio behind them, a red and a yellow lead draped over the crate's front with a
    # tape splice, the power leads down the east side and the back to the floor.
    cable(s, [(0.24, ty0, 0.60), (0.27, 0.27, 0.46), (0.40, 0.30, 0.43), (0.47, 0.34, 0.55)], 0.009, BLACK)
    cable(s, [(0.52, 0.34, 0.52), (0.58, 0.31, 0.43), (0.70, 0.36, 0.45), (0.74, ry0, rz0 + 0.06)], 0.009, BLACK)
    for dz, colour in ((0.0, (190, 44, 36)), (0.018, (220, 186, 50))):
        cable(s, [(rx0, ry1 - 0.03, rz0 + 0.05 + dz), (0.62, 0.775, zt - 0.05 + dz), (0.47, 0.785, zt - 0.11 + dz),
                  (0.32, 0.775, zt - 0.05 + dz), (tx1, ty1 - 0.04, zt + 0.10 + dz)], 0.007, colour)
    s.tube((0.50, 0.787, zt - 0.10), (0.44, 0.787, zt - 0.10), 0.02, TAPE, cap=(150, 152, 148), shine=0.3, segments=10)
    cable(s, [(rx1, 0.56, rz0 + 0.05), (x1 + 0.02, 0.58, zt - 0.02), (x1 + 0.03, 0.62, 0.15), (x1 + 0.04, 0.66, 0.008),
              (x1 + 0.05, 0.80, 0.008)], 0.011, BLACK)
    cable(s, [(0.20, y0, 0.45), (0.19, y0 - 0.02, 0.30), (0.18, y0 - 0.03, 0.008), (0.30, y0 - 0.06, 0.008)], 0.011,
          BLACK)
    ground = shadow((0.5, 0.5), 0.48, 0.34, 120)
    return compose(s, ground=ground, seed=90 + turns + (4 if on else 0), glows=glows)
