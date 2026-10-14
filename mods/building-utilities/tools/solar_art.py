"""Draws this mod's first tile sheet (bu_solar_01): the solar panel in its three mountings and the battery rack with the
overlays of its batteries and charge. The names the game knows stay as they were (saves keep them): the rack 0, its
overlays 1-5 (its batteries on one to five shelves, charge low) and 16-35 (the same at four levels of charge, shelf
by shelf), the panels 8 (flat, on a roof), 9 (on a ground frame, its face to the E) and 10 (its face to the S). The
rack turned, its front to the S, the W and the N, is the same block of rows again from 40, 80 and 120 (its base, then
its overlays at the same places in the block).

Drawn as tile_art draws the water sheet (its solids, light and projection); then run tile_art, which draws the snow
over these panels from them.

    py tools/solar_art.py            writes media/bu_solar.tiles, media/texturepacks/BuildingUtilitiesSolar.pack and
                                     the items' icons (Item_BUSolarPanel, Item_BUBatteryRack)
    py tools/solar_art.py --preview  also writes tools/solar_art_preview.png (the tiles on a floor, the rack against
                                     a wall); a path after it writes it there instead
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tile_art as T  # noqa: E402
from tile_art import Scene, project, shadow, glow, unit, dot, W, H, SS  # noqa: E402

SHEET = 'bu_solar_01'
PACK = 'BuildingUtilitiesSolar'
COLS, ROWS = 8, 20
# The rack's blocks: one a way it faces, in quarter turns from its front to the E (against a W wall): S, W, N.
RACK_BLOCK = 40
RACK_TURNS = 4

# Colours.
ALU = (160, 163, 164)
ALU_DARK = (112, 116, 118)
CELL = (34, 44, 74)
CELL_EDGE = (24, 30, 52)
BACKSHEET = (188, 188, 184)
BUSBAR = (118, 124, 134)
CONCRETE = (150, 146, 138)
RUBBER = (34, 34, 36)
CABLE = (28, 28, 30)
UPRIGHT = (66, 70, 74)
BEAM = (150, 96, 48)
DECK = (126, 126, 122)
CASE = (54, 55, 57)
LID = (68, 69, 71)
LABEL = (182, 180, 172)
STRIPE = (72, 92, 118)
PLUS = (190, 40, 34)
MINUS = (30, 30, 32)
COPPER = (196, 128, 74)
BOX = (184, 184, 176)
BOX_DARK = (134, 134, 128)
CONTROLLER = (82, 86, 88)
CONTROLLER_TRIM = (56, 59, 62)
SCREEN_OFF = (40, 52, 48)
SCREEN_ON = (88, 140, 118)  # a backlit LCD, dim (a bright mint read as neon)
LED_OFF = (52, 56, 54)
LED = {'red': (255, 64, 46), 'amber': (255, 160, 40), 'yellow': (236, 226, 60), 'green': (80, 255, 120)}


def compose(scene, ground=None, over=None, glows=None, seed=1):
    big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    if ground and not T.ICON_DRAW['on']:
        big.alpha_composite(ground)
    solid = scene.render()
    big.alpha_composite(solid)
    if over:
        over(big, solid)
    small = big.convert('RGBa').resize((W, H), Image.LANCZOS).convert('RGBA')
    small = T.finish(small, solid.getchannel('A').resize((W, H), Image.LANCZOS), seed, T.facing_up(scene.up))
    if glows:
        small = glow(small, scene, glows)
    return T.trim_faint(small)


# Oriented solids: a box along three axes from a corner, and a flat piece on a plane.
def obox(s, o, u, v, n, lu, lv, ln, colour, top=None, shine=0.0, emit=False):
    def p(a, b, c):
        return tuple(o[i] + u[i] * a + v[i] * b + n[i] * c for i in range(3))
    c = [p(a, b, d) for d in (0, ln) for b in (0, lv) for a in (0, lu)]
    s.face([c[4], c[5], c[7], c[6]], top or colour, n, shine, emit)
    s.face([c[0], c[1], c[3], c[2]], colour, tuple(-x for x in n), shine, emit)
    s.face([c[1], c[3], c[7], c[5]], colour, u, shine, emit)
    s.face([c[0], c[2], c[6], c[4]], colour, tuple(-x for x in u), shine, emit)
    s.face([c[2], c[3], c[7], c[6]], colour, v, shine, emit)
    s.face([c[0], c[1], c[5], c[4]], colour, tuple(-x for x in v), shine, emit)


def bar(s, a, b, size, colour, up=(0, 0, 1), shine=0.0):
    """A square bar from a to b, size across."""
    d = unit(tuple(q - p for p, q in zip(a, b)))
    if abs(dot(d, unit(up))) > 0.99:
        up = (1, 0, 0)
    side =unit((d[1] * up[2] - d[2] * up[1], d[2] * up[0] - d[0] * up[2], d[0] * up[1] - d[1] * up[0]))
    top = (side[1] * d[2] - side[2] * d[1], side[2] * d[0] - side[0] * d[2], side[0] * d[1] - side[1] * d[0])
    length = math.sqrt(sum((q - p) ** 2 for p, q in zip(a, b)))
    o = tuple(a[i] - side[i] * size / 2 - top[i] * size / 2 for i in range(3))
    obox(s, o, d, side, top, length, size, size, colour, shine=shine)


# The panel: a module lying on a plane from its low corner o, u along its long side (lu), v up its slope (lv), n its
# face. An aluminium frame around glass over sixty cells (10 x 6), each with its corners cut and its busbars.
THICK = 0.035
RIM = 0.026


def module(s, o, u, v, n, lu, lv):
    def p(a, b, c):
        return tuple(o[i] + u[i] * a + v[i] * b + n[i] * c for i in range(3))
    obox(s, o, u, v, n, lu, lv, THICK, ALU_DARK, top=BACKSHEET, shine=0.2)
    lift = THICK + 0.004
    # The frame: four bars standing a little over the glass.
    for a0, b0, a1, b1 in ((0, 0, lu, RIM), (0, lv - RIM, lu, lv), (0, RIM, RIM, lv - RIM), (lu - RIM, RIM, lu, lv - RIM)):
        obox(s, p(a0, b0, THICK - 0.002), u, v, n, a1 - a0, b1 - b0, 0.012, ALU, shine=0.7)
    cols, rows = 10, 6
    gap = 0.006
    cw, ch = (lu - 2 * RIM - (cols + 1) * gap) / cols, (lv - 2 * RIM - (rows + 1) * gap) / rows
    cut = min(cw, ch) * 0.16
    for i in range(cols):
        for j in range(rows):
            a0 = RIM + gap + i * (cw + gap)
            b0 = RIM + gap + j * (ch + gap)
            # a slight unevenness from cell to cell, as wafers have
            k = 1 + 0.06 * math.sin(i * 1.7 + j * 2.3) + 0.03 * math.cos(i * 0.9 - j * 1.3)
            colour = tuple(int(c * k) for c in CELL)
            pts = [(a0 + cut, b0), (a0 + cw - cut, b0), (a0 + cw, b0 + cut), (a0 + cw, b0 + ch - cut),
                   (a0 + cw - cut, b0 + ch), (a0 + cut, b0 + ch), (a0, b0 + ch - cut), (a0, b0 + cut)]
            s.face([p(a, b, lift) for a, b in pts], colour, n, shine=0.35)
            # Busbars up the slope, and the faint fingers across.
            for t in (0.25, 0.5, 0.75):
                a = a0 + cw * t
                s.face([p(a - 0.0022, b0, lift + 0.001), p(a + 0.0022, b0, lift + 0.001),
                        p(a + 0.0022, b0 + ch, lift + 0.001), p(a - 0.0022, b0 + ch, lift + 0.001)], BUSBAR, n, shine=0.5)
            s.face([p(a0, b0, lift + 0.0005), p(a0 + cw, b0, lift + 0.0005), p(a0 + cw, b0 + 0.003, lift + 0.0005),
                    p(a0, b0 + 0.003, lift + 0.0005)], CELL_EDGE, n)
    return [p(RIM, RIM, lift), p(lu - RIM, RIM, lift), p(lu - RIM, lv - RIM, lift), p(RIM, lv - RIM, lift)]


def sheen(scene, corners):
    """The glass catching the sky: a soft bright band across it, brighter toward its far edge (big canvas)."""
    def over(big, solid):
        pts = [project(*scene.turn(c)) for c in corners]
        mask = Image.new('L', big.size, 0)
        ImageDraw.Draw(mask).polygon(pts, fill=255)
        m = np.asarray(mask.filter(ImageFilter.GaussianBlur(SS))).astype(np.float64) / 255
        m *= np.asarray(solid.getchannel('A')).astype(np.float64) / 255
        xs, ys = np.array([q[0] for q in pts]), np.array([q[1] for q in pts])
        gy, gx = np.mgrid[0:big.size[1], 0:big.size[0]]
        # across the glass from its top left on screen to its bottom right
        t = ((gx - xs.min()) / max(1, xs.max() - xs.min()) * 0.55 + (gy - ys.min()) / max(1, ys.max() - ys.min()) * 0.45)
        band = np.exp(-((t - 0.32) / 0.13) ** 2) * 0.18 + np.exp(-((t - 0.58) / 0.05) ** 2) * 0.06 + (1 - t) * 0.05
        a = np.asarray(big).astype(np.float64)
        k = (band * m)[..., None]
        sky = np.array([196, 204, 214], dtype=np.float64)
        a[..., :3] = a[..., :3] * (1 - k) + sky * k
        big.paste(Image.fromarray(a.astype(np.uint8), 'RGBA'))
    return over


def ground_panel(turns):
    """On a frame on the ground, its face to the S (turned: to the E): two A-frames on concrete footings, the module
    on them at 28 degrees, its cable down to the ground at the back."""
    s = Scene(turns)
    tilt = math.radians(28)
    lu, lv = 0.9, 0.74
    x0, y_low, z_low = 0.05, 0.86, 0.2
    u, v, n = (1, 0, 0), (0, -math.cos(tilt), math.sin(tilt)), (0, math.sin(tilt), math.cos(tilt))
    y_high, z_high = y_low - lv * math.cos(tilt), z_low + lv * math.sin(tilt)
    # Footings front and back, the rails on them.
    for y in (y_low - 0.05, y_high + 0.06):
        s.box(0.06, y - 0.05, 0.0, 0.94, y + 0.05, 0.055, CONCRETE)
    for x in (0.16, 0.84):
        bar(s, (x, y_high + 0.02, 0.07), (x, y_low - 0.0, 0.07), 0.03, ALU_DARK, shine=0.4)
        # the posts up to the module's underside, and the brace between them
        bar(s, (x, y_low - 0.04, 0.07), (x, y_low - 0.04, z_low + 0.03), 0.028, ALU, shine=0.5)
        bar(s, (x, y_high + 0.06, 0.07), (x, y_high + 0.06, z_high - 0.04), 0.028, ALU, shine=0.5)
        bar(s, (x, y_low - 0.06, 0.08), (x, y_high + 0.1, z_high - 0.08), 0.022, ALU_DARK, shine=0.4)
        # the rafter under the module
        bar(s, (x, y_low - 0.01, z_low - 0.012), (x, y_high + 0.01, z_high - 0.012), 0.03, ALU_DARK, up=n, shine=0.4)
    corners = module(s, (x0, y_low, z_low), u, v, n, lu, lv)
    # The cable from its back down to the ground, and a plug on it.
    s.tube((0.5, y_high + 0.12, z_high - 0.08), (0.5, y_high + 0.14, 0.12), 0.007, CABLE, segments=10)
    s.tube((0.5, y_high + 0.14, 0.12), (0.62, y_high + 0.12, 0.03), 0.007, CABLE, segments=10)
    ground = shadow(s.turn((0.5, 0.52, 0))[:2], 0.46, 0.42, strength=90)
    return compose(s, ground=ground, over=sheen(s, corners), seed=5 + turns)


def roof_panel():
    """On a roof: the module on two low rails, tipped 8 degrees toward the S to shed the rain."""
    s = Scene(0)
    tilt = math.radians(8)
    lu, lv = 0.94, 0.86
    y_low, z_low = 0.94, 0.07
    u, v, n = (1, 0, 0), (0, -math.cos(tilt), math.sin(tilt)), (0, math.sin(tilt), math.cos(tilt))
    y_high, z_high = y_low - lv * math.cos(tilt), z_low + lv * math.sin(tilt)
    for x in (0.18, 0.82):
        for y in (y_low - 0.06, y_high + 0.06):
            s.box(x - 0.04, y - 0.04, 0.0, x + 0.04, y + 0.04, 0.02, RUBBER)
        bar(s, (x, y_low - 0.03, 0.035), (x, y_high + 0.03, 0.035), 0.03, ALU_DARK, shine=0.4)
        bar(s, (x, y_high + 0.06, 0.04), (x, y_high + 0.06, z_high - 0.02), 0.024, ALU, shine=0.5)
        bar(s, (x, y_low - 0.02, z_low - 0.012), (x, y_high + 0.01, z_high - 0.012), 0.026, ALU_DARK, up=n, shine=0.4)
    corners = module(s, (0.03, y_low, z_low), u, v, n, lu, lv)
    ground = shadow((0.5, 0.52), 0.48, 0.45, strength=70)
    return compose(s, ground=ground, over=sheen(s, corners), seed=4)


# The rack, against a W wall: steel uprights, orange beams and galvanised decks for five shelves of four car batteries
# each, and its charge controller on its S side (a screen, four lamps). Shelves fill from the bottom.
SHELVES = (0.1, 0.44, 0.78, 1.12, 1.46)
TOP = 1.76
XS = (0.07, 0.49)
YS = (0.08, 0.92)
POST = 0.036
BATTERY = (0.29, 0.165, 0.19)  # across (x), along (y), high


def rack(shelves=-1, level=None, turns=0):
    """shelves: the highest shelf with batteries (-1 none); level: 0-4 of charge, its lamps (None: dark, no batteries);
    turns: quarter turns from its front to the E."""
    s = Scene(turns)
    glows = []
    # Uprights: angle steel, with a foot plate.
    for x in XS:
        for y in YS:
            s.box(x - POST / 2, y - POST / 2, 0.0, x + POST / 2, y + POST / 2, TOP, UPRIGHT, shine=0.25)
            s.box(x - 0.035, y - 0.035, 0.0, x + 0.035, y + 0.035, 0.012, UPRIGHT)
    # Cross braces on the S side, behind the controller.
    for z0, z1 in ((0.12, 0.76), (0.82, 1.44)):
        bar(s, (XS[0], YS[1], z0), (XS[1], YS[1], z1), 0.014, UPRIGHT, up=(0, 1, 0))
    for z in SHELVES + (TOP - 0.03,):
        # beams front and back, the deck between
        s.box(XS[1] - 0.012, YS[0], z - 0.05, XS[1] + 0.022, YS[1], z, BEAM, shine=0.3)
        s.box(XS[0] - 0.022, YS[0], z - 0.05, XS[0] + 0.012, YS[1], z, BEAM, shine=0.3)
        if z < TOP - 0.1:
            s.box(XS[0] + 0.012, YS[0] + 0.02, z - 0.016, XS[1] - 0.012, YS[1] - 0.02, z, DECK, shine=0.35)
    # The charge controller on the S side: a box, its screen and four lamps, its conduit up to the wall.
    # A small wall-box controller, as sold for battery banks: a dark case the size of a book, a little screen, a row
    # of small lamps under it.
    bx0, bx1, by, bz0, bz1 = 0.17, 0.37, YS[1] + POST / 2, 1.0, 1.24
    s.box(bx0, by, bz0, bx1, by + 0.045, bz1, CONTROLLER, top=CONTROLLER, shine=0.15)
    s.box(bx0 + 0.012, by + 0.045, bz1 - 0.018, bx1 - 0.012, by + 0.048, bz1 - 0.01, CONTROLLER_TRIM)
    lit = shelves >= 0 and level is not None
    s.box(bx0 + 0.03, by + 0.045, 1.13, bx1 - 0.03, by + 0.049, 1.2, SCREEN_ON if lit else SCREEN_OFF, emit=lit)
    lamps = {0: ['red'], 1: ['amber'], 2: ['yellow', 'yellow'], 3: ['green'] * 3, 4: ['green'] * 4}.get(level, []) if lit else []
    step = (bx1 - bx0 - 0.06) / 4
    for i in range(4):
        x = bx0 + 0.03 + i * step + step * 0.25
        on = i < len(lamps)
        s.box(x, by + 0.045, 1.05, x + step * 0.5, by + 0.05, 1.075, LED[lamps[i]] if on else LED_OFF, emit=on,
              shine=0.0 if on else 0.6)
        if on:
            glows.append(((x + step * 0.25, by + 0.06, 1.062), LED[lamps[i]], 0.045))
    if lit:
        glows.append((((bx0 + bx1) / 2, by + 0.06, 1.165), SCREEN_ON, 0.04))
    # its conduit up the side into the top beam (the rack may stand away from a wall)
    s.tube(((bx0 + bx1) / 2, by + 0.02, bz1), ((bx0 + bx1) / 2, by + 0.02, TOP - 0.06), 0.011, BOX_DARK, segments=16)
    s.tube(((bx0 + bx1) / 2, by + 0.02, TOP - 0.06), ((bx0 + bx1) / 2, YS[1], TOP - 0.06), 0.011, BOX_DARK, segments=16)
    # The batteries: four to a shelf, linked in a row, their bus down the back to the controller.
    for shelf in range(shelves + 1):
        z = SHELVES[shelf]
        for i in range(4):
            yc = YS[0] + (YS[1] - YS[0]) * (i + 0.5) / 4
            battery(s, 0.135, yc, z)
        for i in range(3):
            y0 = YS[0] + (YS[1] - YS[0]) * (i + 0.5) / 4 + 0.05
            y1 = YS[0] + (YS[1] - YS[0]) * (i + 1.5) / 4 - 0.05
            zt = z + BATTERY[2] + 0.035
            s.tube((0.38, y0, zt), (0.38, (y0 + y1) / 2, zt + 0.03), 0.009, PLUS if i % 2 else MINUS, segments=10)
            s.tube((0.38, (y0 + y1) / 2, zt + 0.03), (0.38, y1, zt), 0.009, PLUS if i % 2 else MINUS, segments=10)
    if shelves >= 0:
        top = SHELVES[shelves] + BATTERY[2] + 0.04
        for dy, colour in ((-0.012, PLUS), (0.012, MINUS)):
            y = YS[1] - 0.05 + dy
            s.tube((0.11, y, 0.06), (0.11, y, max(top, bz0 + 0.1)), 0.011, colour, segments=12)
        s.tube((0.11, YS[1] - 0.05, bz0 + 0.1), (0.2, by, bz0 + 0.1), 0.014, CABLE, segments=12)
    rx, ry = (0.3, 0.48) if turns % 2 == 0 else (0.48, 0.3)
    ground = shadow(s.turn((0.28, 0.5, 0))[:2], rx, ry, strength=90)
    # the lamps' glow is laid over the finished tile: none while the controller is turned away (to the W or the N),
    # behind the rack
    if turns % 4 in (1, 2):
        glows = []
    return s, ground, glows


def battery(s, x0, yc, z):
    """A car battery on a deck at height z, its long side across the shelf, terminals and label to the front (E)."""
    bx, by, bz = BATTERY
    y0, y1 = yc - by / 2, yc + by / 2
    s.box(x0, y0, z, x0 + bx, y1, z + bz - 0.025, CASE, shine=0.25)
    s.box(x0 - 0.004, y0 - 0.004, z + bz - 0.025, x0 + bx + 0.004, y1 + 0.004, z + bz, LID, shine=0.3)
    # the handle's grooves and the vent caps along the lid
    s.box(x0 + 0.05, y0 + 0.02, z + bz, x0 + bx - 0.07, y1 - 0.02, z + bz + 0.006, CASE)
    # its sticker on the front: blue, a white band across
    s.box(x0 + bx, y0 + 0.025, z + 0.05, x0 + bx + 0.003, y1 - 0.025, z + bz - 0.06, STRIPE)
    s.box(x0 + bx + 0.003, y0 + 0.025, z + 0.085, x0 + bx + 0.005, y1 - 0.025, z + 0.1, LABEL)
    # terminals, their caps
    for y, cap in ((y0 + 0.035, PLUS), (y1 - 0.035, MINUS)):
        s.tube((x0 + bx - 0.05, y, z + bz), (x0 + bx - 0.05, y, z + bz + 0.02), 0.016, COPPER, segments=14, shine=0.5)
        s.tube((x0 + bx - 0.05, y, z + bz + 0.02), (x0 + bx - 0.05, y, z + bz + 0.035), 0.02, cap, segments=14, shine=0.3)


def rack_tiles(turns=0):
    """The rack (0 in its block) and its overlays: what differs from it with batteries on so many shelves at a charge
    level."""
    s, ground, glows = rack(turns=turns)
    base = compose(s, ground=ground, seed=3)
    overlays = {}
    for shelves in range(5):
        for level in range(5):
            s, ground, glows = rack(shelves, level, turns)
            full = compose(s, ground=ground, glows=glows, seed=3)
            a, b = np.asarray(full).astype(np.int32), np.asarray(base).astype(np.int32)
            changed = np.abs(a - b).max(axis=2) > 2
            out = np.where(changed[..., None], a, 0).astype(np.uint8)
            index = 1 + shelves if level == 0 else 16 + (level - 1) + 4 * shelves
            overlays[index] = Image.fromarray(out, 'RGBA')
    return base, overlays


# The wall side each turn stands against: its front away from it.
RACK_WALL = ('W', 'N', 'E', 'S')
RACK = {'BlocksPlacement': '', 'CustomName': 'Battery Rack', 'Facing': 'W', 'solidtrans': ''}
OVERLAY = {'attachedW': ''}
PANEL = {'CustomName': 'Solar Panel', 'IsLow': ''}


def tiles():
    images, props = {}, {}
    for turns in range(RACK_TURNS):
        block, wall = RACK_BLOCK * turns, RACK_WALL[turns]
        base, overlays = rack_tiles(turns)
        images[block], props[block] = base, dict(RACK, Facing=wall)
        for index, image in overlays.items():
            images[block + index], props[block + index] = image, {'attached' + wall: ''}
    images[8], props[8] = roof_panel(), PANEL
    images[9], props[9] = ground_panel(3), dict(PANEL, Facing='W', solidtrans='')
    images[10], props[10] = ground_panel(0), dict(PANEL, Facing='N', solidtrans='')
    return images, props


def write_tiles(path, props):
    import struct
    import io
    out = io.BytesIO()
    out.write(b'tdef')
    out.write(struct.pack('<ii', 1, 1))
    out.write((SHEET + '\n').encode('latin1'))
    out.write((SHEET + '.png\n').encode('latin1'))
    out.write(struct.pack('<iiii', COLS, ROWS, 1, COLS * ROWS))
    for index in range(COLS * ROWS):
        p = props.get(index, {})
        out.write(struct.pack('<i', len(p)))
        for key, value in p.items():
            out.write((key + '\n' + value + '\n').encode('latin1'))
    with open(path, 'wb') as f:
        f.write(out.getvalue())


def icon(image, name, top=0.0):
    """An item's icon from a tile (tile_art.item_icon); top: the share of the thing's height cut from its top first (the
    tall rack shows its batteries and monitor then, not a thin column)."""
    if top:
        crop = T.trim(image)[0]
        image = crop.crop((0, int(crop.height * top), crop.width, crop.height))
    T.item_icon(image).save(os.path.join(T.ROOT, 'textures', 'Item_%s.png' % name))


# The panel as an item on the ground: a slab (DirectX text model, Y up, metres, its bottom at 0) under a texture of
# its face (the top of the texture) and its aluminium and back sheet (strips below).
MODEL_W, MODEL_D, MODEL_T = 0.9, 0.72, 0.035
FACE_V = 0.8125  # the face takes the texture down to here; then aluminium, then the back sheet


# The standard templates of the DirectX text format, as the game's own models carry them.
X_TEMPLATES = '''
template ColorRGBA {
 <35ff44e0-6c7c-11cf-8f52-0040333594a3>
 FLOAT red;
 FLOAT green;
 FLOAT blue;
 FLOAT alpha;
}

template ColorRGB {
 <d3e16e81-7835-11cf-8f52-0040333594a3>
 FLOAT red;
 FLOAT green;
 FLOAT blue;
}

template Material {
 <3d82ab4d-62da-11cf-ab39-0020af71e433>
 ColorRGBA faceColor;
 FLOAT power;
 ColorRGB specularColor;
 ColorRGB emissiveColor;
 [...]
}

template TextureFilename {
 <a42790e1-7810-11cf-8f52-0040333594a3>
 STRING filename;
}

template Frame {
 <3d82ab46-62da-11cf-ab39-0020af71e433>
 [...]
}

template Matrix4x4 {
 <f6f23f45-7686-11cf-8f52-0040333594a3>
 array FLOAT matrix[16];
}

template FrameTransformMatrix {
 <f6f23f41-7686-11cf-8f52-0040333594a3>
 Matrix4x4 frameMatrix;
}

template Vector {
 <3d82ab5e-62da-11cf-ab39-0020af71e433>
 FLOAT x;
 FLOAT y;
 FLOAT z;
}

template MeshFace {
 <3d82ab5f-62da-11cf-ab39-0020af71e433>
 DWORD nFaceVertexIndices;
 array DWORD faceVertexIndices[nFaceVertexIndices];
}

template Mesh {
 <3d82ab44-62da-11cf-ab39-0020af71e433>
 DWORD nVertices;
 array Vector vertices[nVertices];
 DWORD nFaces;
 array MeshFace faces[nFaces];
 [...]
}

template MeshNormals {
 <f6f23f43-7686-11cf-8f52-0040333594a3>
 DWORD nNormals;
 array Vector normals[nNormals];
 DWORD nFaceNormals;
 array MeshFace faceNormals[nFaceNormals];
}

template MeshMaterialList {
 <f6f23f42-7686-11cf-8f52-0040333594a3>
 DWORD nMaterials;
 DWORD nFaceIndexes;
 array DWORD faceIndexes[nFaceIndexes];
 [Material <3d82ab4d-62da-11cf-ab39-0020af71e433>]
}

template Coords2d {
 <f6f23f44-7686-11cf-8f52-0040333594a3>
 FLOAT u;
 FLOAT v;
}

template MeshTextureCoords {
 <f6f23f40-7686-11cf-8f52-0040333594a3>
 DWORD nTextureCoords;
 array Coords2d textureCoords[nTextureCoords];
}
'''


def model_texture():
    size = 256
    img = Image.new('RGBA', (size, size), BACKSHEET + (255,))
    d = ImageDraw.Draw(img)
    face_h = int(size * FACE_V)
    d.rectangle((0, 0, size - 1, face_h - 1), fill=ALU)
    rim = 7
    d.rectangle((rim, rim, size - 1 - rim, face_h - 1 - rim), fill=BACKSHEET)
    cols, rows, gap = 10, 6, 2
    cw = (size - 2 * rim - (cols + 1) * gap) / cols
    ch = (face_h - 2 * rim - (rows + 1) * gap) / rows
    cut = min(cw, ch) * 0.16
    for i in range(cols):
        for j in range(rows):
            x0, y0 = rim + gap + i * (cw + gap), rim + gap + j * (ch + gap)
            k = 1 + 0.06 * math.sin(i * 1.7 + j * 2.3) + 0.03 * math.cos(i * 0.9 - j * 1.3)
            colour = tuple(int(c * k * 1.15) for c in CELL) + (255,)
            d.polygon([(x0 + cut, y0), (x0 + cw - cut, y0), (x0 + cw, y0 + cut), (x0 + cw, y0 + ch - cut),
                       (x0 + cw - cut, y0 + ch), (x0 + cut, y0 + ch), (x0, y0 + ch - cut), (x0, y0 + cut)], fill=colour)
            for t in (0.25, 0.5, 0.75):
                d.line((x0 + cw * t, y0 + 1, x0 + cw * t, y0 + ch - 1), fill=BUSBAR + (255,))
    # a soft sheen across the glass
    a = np.asarray(img).astype(np.float64)
    gy, gx = np.mgrid[0:size, 0:size]
    t = gx / size * 0.55 + gy / face_h * 0.45
    k = (np.exp(-((t - 0.32) / 0.13) ** 2) * 0.22) * (gy < face_h - rim) * (gy >= rim) * (gx >= rim) * (gx < size - rim)
    a[..., :3] = a[..., :3] * (1 - k[..., None]) + np.array([214, 228, 246]) * k[..., None]
    img = Image.fromarray(a.astype(np.uint8), 'RGBA')
    d = ImageDraw.Draw(img)
    d.rectangle((0, face_h + 4, size - 1, face_h + 20), fill=ALU + (255,))
    d.rectangle((0, face_h + 28, size - 1, size - 1), fill=BACKSHEET + (255,))
    return img


def model_text():
    w, dd, t = MODEL_W / 2, MODEL_D / 2, MODEL_T
    alu_v = (FACE_V + 6 / 256, FACE_V + 18 / 256)
    back_v = (FACE_V + 32 / 256, 0.98)
    faces = [
        # (corners, normal, uvs): the top first, as the texture shows it
        ([(-w, t, -dd), (w, t, -dd), (w, t, dd), (-w, t, dd)], (0, 1, 0), [(0, 0), (1, 0), (1, FACE_V), (0, FACE_V)]),
        ([(-w, 0, dd), (w, 0, dd), (w, 0, -dd), (-w, 0, -dd)], (0, -1, 0),
         [(0, back_v[0]), (1, back_v[0]), (1, back_v[1]), (0, back_v[1])]),
    ]
    for corners, normal in (
            ([(-w, 0, dd), (w, 0, dd), (w, t, dd), (-w, t, dd)], (0, 0, 1)),
            ([(w, 0, -dd), (-w, 0, -dd), (-w, t, -dd), (w, t, -dd)], (0, 0, -1)),
            ([(w, 0, dd), (w, 0, -dd), (w, t, -dd), (w, t, dd)], (1, 0, 0)),
            ([(-w, 0, -dd), (-w, 0, dd), (-w, t, dd), (-w, t, -dd)], (-1, 0, 0))):
        faces.append((corners, normal, [(0, alu_v[1]), (1, alu_v[1]), (1, alu_v[0]), (0, alu_v[0])]))
    verts, normals, uvs, tris = [], [], [], []
    for corners, normal, uv in faces:
        base = len(verts)
        verts += corners
        normals += [normal] * 4
        uvs += uv
        # wound so that the face looks along its normal
        a, b, c = corners[0], corners[1], corners[2]
        e1 = tuple(b[i] - a[i] for i in range(3))
        e2 = tuple(c[i] - a[i] for i in range(3))
        cross = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        if dot(cross, normal) > 0:
            tris += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
        else:
            tris += [(base, base + 2, base + 1), (base, base + 3, base + 2)]

    def vec(v):
        return ';'.join('%.6f' % c for c in v) + ';'

    def rows(items, last):
        return (',\n'.join('   ' + item for item in items)) + last
    out = ['xof 0303txt 0032' + X_TEMPLATES,
           'Material Panel {', ' 1.000000;1.000000;1.000000;1.000000;;', ' 9.999999;', ' 0.000000;0.000000;0.000000;;',
           ' 0.000000;0.000000;0.000000;;', ' TextureFilename {', '  "BUSolarPanel.png";', ' }', '}', '',
           'Frame BUSolarPanel {', ' FrameTransformMatrix {',
           '  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,'
           '0.000000,0.000000,0.000000,1.000000;;', ' }',
           ' Mesh BUSolarPanel {', '  %d;' % len(verts), rows([vec(v) for v in verts], ';'),
           '  %d;' % len(tris), rows(['3;%d,%d,%d;' % tri for tri in tris], ';'),
           '  MeshNormals {', '   %d;' % len(normals), rows([vec(n) for n in normals], ';'),
           '   %d;' % len(tris), rows(['3;%d,%d,%d;' % tri for tri in tris], ';'), '  }',
           '  MeshMaterialList {', '   1;', '   %d;' % len(tris), rows(['0'] * len(tris), ';'), '   { Panel }', '  }',
           '  MeshTextureCoords {', '   %d;' % len(uvs), rows(['%.6f;%.6f;' % uv for uv in uvs], ';'), '  }',
           ' }', '}', '']
    return '\n'.join(out)


def preview(images, path):
    """The panels on a floor; the rack against a wall, empty and then at each shelf (full charge) and each charge
    (all shelves); twice the size."""
    wall = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(wall).polygon([(0, 224), (64, 192), (64, 0), (0, 32)], fill=(150, 140, 120, 255))
    floor = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(floor).polygon([(64, 192), (128, 224), (64, 256), (0, 224)], fill=(96, 110, 80, 255))
    shows = [(8, None), (9, None), (10, None), (0, None)]
    shows += [(0, 16 + 3 + 4 * shelf) for shelf in range(5)]
    shows += [(0, 1 + 4)] + [(0, 16 + (level - 1) + 16) for level in range(1, 5)]
    cols = 5
    rows = (len(shows) + cols - 1) // cols
    sheet = Image.new('RGBA', (W * cols, H * rows), (40, 44, 40, 255))
    for k, (index, over) in enumerate(shows):
        tile = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        tile.alpha_composite(floor)
        if index == 0:
            tile.alpha_composite(wall)
        tile.alpha_composite(images[index])
        if over is not None:
            tile.alpha_composite(images[over])
        sheet.alpha_composite(tile, ((k % cols) * W, (k // cols) * H))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.LANCZOS).save(path)


def main():
    images, props = tiles()
    write_tiles(os.path.join(T.ROOT, 'bu_solar.tiles'), props)
    T.write_pack_named(os.path.join(T.ROOT, 'texturepacks', PACK + '.pack'), SHEET,
                       [('%s_%d' % (SHEET, index), images[index]) for index in sorted(images)])
    # the icons: the things without their shadows (tile_art.write_icons)
    T.ICON_DRAW['on'] = True
    try:
        s_, ground, glows = rack(4, 4)
        icon(compose(s_, ground=ground, glows=glows, seed=3), 'BUBatteryRack', top=0.3)
        icon(ground_panel(0), 'BUSolarPanel')
    finally:
        T.ICON_DRAW['on'] = False
    model_texture().save(os.path.join(T.ROOT, 'textures', 'WorldItems', 'BUSolarPanel.png'))
    with open(os.path.join(T.ROOT, 'models_X', 'WorldItems', 'BUSolarPanel.x'), 'w', newline='\n') as f:
        f.write(model_text())
    if '--preview' in sys.argv:
        at = sys.argv.index('--preview') + 1
        path = sys.argv[at] if at < len(sys.argv) else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                   'solar_art_preview.png')
        preview(images, path)
    print('wrote', len(images), 'tiles')


if __name__ == '__main__':
    main()
