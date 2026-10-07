"""Draws the water units' tiles (pump, sprinkler, filter) and writes them as the mod's second tile sheet.

The art is made here, not painted: each object is a few solids (boxes, cylinders) in a tile's space, projected the
way the game draws a square, shaded by a light from above and the viewer's left, drawn four times larger with a depth
buffer and scaled down. Units are a square's side; the game's 2x tiles show a square as a 128x64 diamond at the bottom
of a 128x256 tile, and a unit up as UP pixels (the game's 2:1 view looks down 30 degrees). The viewer sees the south
(+y, screen left) and east (+x, screen right) sides of things.

    py tools/water_art.py            writes media/bu_water.tiles and media/texturepacks/BuildingUtilitiesWater.pack,
                                     and the items' icons (media/textures/Item_BU*.png) from the tiles
    py tools/water_art.py --preview  also writes tools/water_art_preview.png (every tile on a floor, for a look)

Needs Pillow and numpy (py -m pip install --user pillow numpy).
"""
import io
import math
import os
import random
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'BuildingUtilities', '42', 'media')
SHEET = 'bu_water_01'
PACK = 'BuildingUtilitiesWater'
COLS, ROWS = 8, 2
W, H = 128, 256
SS = 4  # drawn this many times larger, then scaled down
UP = 64 * math.sqrt(1.5)  # pixels of a unit up: a square's side across is 64 * sqrt(2), looked at from 30 degrees


def unit(v):
    length = math.sqrt(sum(c * c for c in v))
    return tuple(c / length for c in v)


VIEW = unit((1, 1, 32 * 2 / UP))  # towards the viewer: the points along it fall on one pixel
LIGHT = unit((0.3, 0.75, 1.1))
HALF = unit(tuple(l + v for l, v in zip(LIGHT, VIEW)))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def project(x, y, z):
    return ((64 + (x - y) * 64) * SS, (192 + (x + y) * 32 - z * UP) * SS)


def shade(colour, normal, shine):
    """Lit by the light (ambient, diffuse) and, for metal, a highlight."""
    diffuse = max(0.0, dot(normal, LIGHT))
    f = 0.45 + 0.62 * diffuse
    spec = shine * max(0.0, dot(normal, HALF)) ** 24 * 255
    return tuple(max(0, min(255, int(c * f + spec))) for c in colour[:3])


class Scene:
    """Faces of solids, drawn into a depth buffer; what is added is turned a number of quarter turns about the
    tile's middle."""
    def __init__(self, turns=0):
        self.turns = turns
        self.faces = []

    def turn(self, p, vector=False):
        x, y, z = p
        for _ in range(self.turns % 4):
            x, y = (-y, x) if vector else (1 - y, x)
        return (x, y, z)

    def face(self, points, colour, normal, shine=0.0):
        normal = self.turn(normal, True)
        if dot(normal, VIEW) <= 1e-6:
            return
        self.faces.append(([self.turn(p) for p in points], shade(colour, normal, shine)))

    def box(self, x0, y0, z0, x1, y1, z1, colour, top=None, shine=0.0):
        self.face([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], top or colour, (0, 0, 1), shine)
        self.face([(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)], colour, (0, 0, -1), shine)
        self.face([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], colour, (0, 1, 0), shine)
        self.face([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], colour, (0, -1, 0), shine)
        self.face([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], colour, (1, 0, 0), shine)
        self.face([(x0, y0, z0), (x0, y1, z0), (x0, y1, z1), (x0, y0, z1)], colour, (-1, 0, 0), shine)

    def tube(self, a, b, r, colour, cap=None, shine=0.0, segments=40, bands=None):
        """A cylinder from point a to point b; bands: [(from, to, colour)] along it, 0..1."""
        axis = tuple(q - p for p, q in zip(a, b))
        length = math.sqrt(dot(axis, axis))
        d = unit(axis)
        helper = (0, 0, 1) if abs(d[2]) < 0.9 else (1, 0, 0)
        u = unit((d[1] * helper[2] - d[2] * helper[1], d[2] * helper[0] - d[0] * helper[2], d[0] * helper[1] - d[1] * helper[0]))
        v = (d[1] * u[2] - d[2] * u[1], d[2] * u[0] - d[0] * u[2], d[0] * u[1] - d[1] * u[0])
        def at(angle, t):
            c, s = math.cos(angle) * r, math.sin(angle) * r
            return tuple(p + d_ * t * length + u_ * c + v_ * s for p, d_, u_, v_ in zip(a, d, u, v))
        for i in range(segments):
            a0, a1 = 2 * math.pi * i / segments, 2 * math.pi * (i + 1) / segments
            mid = (a0 + a1) / 2
            n = tuple(u_ * math.cos(mid) + v_ * math.sin(mid) for u_, v_ in zip(u, v))
            for t0, t1, c in bands or [(0, 1, colour)]:
                self.face([at(a0, t0), at(a1, t0), at(a1, t1), at(a0, t1)], c, n, shine)
        ring = range(segments)
        self.face([at(2 * math.pi * i / segments, 1) for i in ring], cap or colour, d, shine)
        self.face([at(2 * math.pi * i / segments, 0) for i in ring], cap or colour, tuple(-c for c in d), shine)

    def render(self):
        """The faces in a depth buffer: an RGBA image of the big canvas."""
        size = (W * SS, H * SS)
        depth = np.full((size[1], size[0]), -1e9, dtype=np.float64)
        colour = np.zeros((size[1], size[0], 4), dtype=np.uint8)
        for points, rgb in self.faces:
            screen = [project(*p) for p in points]
            xs, ys = [s[0] for s in screen], [s[1] for s in screen]
            x0, y0 = max(0, int(math.floor(min(xs)))), max(0, int(math.floor(min(ys))))
            x1, y1 = min(size[0] - 1, int(math.ceil(max(xs)))), min(size[1] - 1, int(math.ceil(max(ys))))
            if x1 < x0 or y1 < y0:
                continue
            mask = Image.new('L', (x1 - x0 + 1, y1 - y0 + 1), 0)
            ImageDraw.Draw(mask).polygon([(sx - x0, sy - y0) for sx, sy in screen], fill=255)
            m = np.asarray(mask) > 0
            if not m.any():
                continue
            # The face's depth is a plane over the screen: fitted to its corners, kept within them.
            corners = np.array([[sx, sy, 1.0] for sx, sy in screen])
            values = np.array([dot(p, VIEW) for p in points])
            plane, *_ = np.linalg.lstsq(corners, values, rcond=None)
            gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
            d = np.clip(plane[0] * gx + plane[1] * gy + plane[2], values.min(), values.max())
            region = depth[y0:y1 + 1, x0:x1 + 1]
            nearer = m & (d > region)
            region[nearer] = d[nearer]
            colour[y0:y1 + 1, x0:x1 + 1][nearer] = rgb + (255,)
        return Image.fromarray(colour, 'RGBA')


def shadow(centre, rx, ry, strength=110):
    """A soft shadow on the floor (big canvas)."""
    layer = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    cx, cy = centre
    pts = [project(cx + math.cos(a) * rx, cy + math.sin(a) * ry, 0) for a in [i * math.pi / 32 for i in range(64)]]
    ImageDraw.Draw(layer).polygon(pts, fill=(0, 0, 0, strength))
    return layer.filter(ImageFilter.GaussianBlur(5 * SS))


def compose(scene, ground=None, over=None, seed=1):
    big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    if ground:
        big.alpha_composite(ground)
    solid = scene.render()
    big.alpha_composite(solid)
    if over:
        over(big)
    small = big.convert('RGBa').resize((W, H), Image.LANCZOS).convert('RGBA')
    return finish(small, solid.getchannel('A').resize((W, H), Image.LANCZOS), seed)


def finish(image, solid, seed):
    """A little grain, and a darker rim where a thing meets the air, as the game's tiles have."""
    rnd = random.Random(seed)
    px = image.load()
    inner = solid.filter(ImageFilter.MinFilter(3)).load()
    sp = solid.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = px[x, y]
            if a == 0 or sp[x, y] < 40:
                continue
            n = 1 + (rnd.random() - 0.5) * 0.06
            if inner[x, y] < 128:
                n *= 0.7
            px[x, y] = (min(255, int(r * n)), min(255, int(g * n)), min(255, int(b * n)), a)
    return image


# Colours.
CONCRETE = (156, 152, 144)
FRAME = (64, 66, 70)
MOTOR = (46, 88, 124)
MOTOR_DARK = (34, 66, 94)
CASING = (170, 52, 40)
CASING_DARK = (128, 40, 32)
STEEL = (160, 164, 168)
PIPE = (84, 88, 92)
BRASS = (200, 158, 70)
BRASS_DARK = (150, 112, 48)
RUBBER = (36, 36, 38)
HOSE = (54, 128, 66)
WHITE = (228, 232, 234)
BLUE = (52, 104, 168)


def pump(turns):
    """An electric pump on a concrete pad: the motor with its fan cover, fins and terminal box, the coupling, the red
    casing; the suction leaves the casing's eye east and goes down into the ground, the delivery rises from the top of
    the casing through a valve and turns east to a flange."""
    s = Scene(turns)
    s.box(0.14, 0.26, 0.0, 0.84, 0.74, 0.05, CONCRETE)
    s.box(0.2, 0.36, 0.05, 0.76, 0.64, 0.085, FRAME)
    axis_z, motor_r = 0.25, 0.13
    # Feet of the motor and of the casing.
    for x0 in (0.26, 0.44):
        s.box(x0, 0.39, 0.085, x0 + 0.06, 0.61, 0.15, MOTOR_DARK)
    s.box(0.6, 0.42, 0.085, 0.7, 0.58, 0.14, CASING_DARK)
    # The motor: its fan cover at the back, then the finned body.
    s.tube((0.18, 0.5, axis_z), (0.24, 0.5, axis_z), motor_r - 0.008, MOTOR_DARK, cap=(30, 34, 38), segments=48)
    fins = []
    t = 0.0
    while t < 0.999:
        fins.append((t, min(1.0, t + 0.09), MOTOR))
        fins.append((min(1.0, t + 0.09), min(1.0, t + 0.14), MOTOR_DARK))
        t += 0.14
    s.tube((0.24, 0.5, axis_z), (0.53, 0.5, axis_z), motor_r, MOTOR, cap=MOTOR_DARK, segments=48, bands=fins, shine=0.15)
    s.tube((0.53, 0.5, axis_z), (0.56, 0.5, axis_z), motor_r - 0.02, MOTOR_DARK, segments=48)
    s.box(0.33, 0.43, axis_z + motor_r - 0.02, 0.44, 0.57, axis_z + motor_r + 0.06, MOTOR_DARK, top=MOTOR)
    s.box(0.44, 0.47, axis_z + motor_r + 0.01, 0.47, 0.53, axis_z + motor_r + 0.04, RUBBER)
    # Coupling and casing.
    s.tube((0.56, 0.5, axis_z), (0.6, 0.5, axis_z), 0.05, STEEL, shine=0.5)
    s.tube((0.6, 0.5, axis_z), (0.62, 0.5, axis_z), 0.16, CASING_DARK, segments=56)
    s.tube((0.62, 0.5, axis_z), (0.7, 0.5, axis_z), 0.165, CASING, segments=56, shine=0.25)
    s.tube((0.7, 0.5, axis_z), (0.73, 0.5, axis_z), 0.11, CASING, cap=CASING_DARK, segments=48, shine=0.25)
    # Suction: out of the eye, an elbow down into the ground.
    s.tube((0.73, 0.5, axis_z), (0.77, 0.5, axis_z), 0.07, STEEL, shine=0.5)
    s.tube((0.77, 0.5, axis_z), (0.9, 0.5, axis_z), 0.05, PIPE, shine=0.3)
    s.tube((0.9, 0.5, axis_z + 0.05), (0.9, 0.5, -0.02), 0.05, PIPE, shine=0.3)
    s.tube((0.9, 0.5, 0.0), (0.9, 0.5, 0.02), 0.07, STEEL)
    # Delivery: up from the top of the casing, a valve with its wheel, a flange.
    top = axis_z + 0.16
    s.tube((0.66, 0.5, top - 0.03), (0.66, 0.5, top + 0.08), 0.045, CASING, shine=0.25)
    s.tube((0.66, 0.5, top + 0.08), (0.66, 0.5, top + 0.1), 0.065, STEEL, shine=0.5)
    s.box(0.62, 0.46, top + 0.1, 0.7, 0.54, top + 0.16, PIPE, shine=0.3)
    s.tube((0.66, 0.5, top + 0.16), (0.66, 0.5, top + 0.22), 0.012, STEEL)
    s.tube((0.66, 0.5, top + 0.22), (0.66, 0.5, top + 0.235), 0.06, CASING, cap=CASING_DARK)
    s.tube((0.7, 0.5, top + 0.13), (0.8, 0.5, top + 0.13), 0.04, PIPE, shine=0.3)
    s.tube((0.8, 0.5, top + 0.13), (0.82, 0.5, top + 0.13), 0.065, STEEL, shine=0.5)
    ground = shadow(s.turn((0.5, 0.5, 0))[:2], 0.42, 0.32)
    return compose(s, ground=ground, seed=10 + turns)


def sprinkler(spraying):
    """An impact sprinkler on a spike: a weighted base, the riser with the hose coupling, the brass head, its nozzle
    looking up and out and the arm that knocks it round. Spraying, drops leave the nozzle in arcs."""
    s = Scene()
    s.tube((0.5, 0.5, 0.0), (0.5, 0.5, 0.025), 0.1, (70, 72, 74), cap=(90, 92, 94))
    s.tube((0.5, 0.5, 0.025), (0.5, 0.5, 0.05), 0.06, (70, 72, 74))
    s.tube((0.5, 0.5, 0.05), (0.5, 0.5, 0.42), 0.022, STEEL, shine=0.5)
    # The hose coupling, toward the viewer.
    s.tube((0.5, 0.5, 0.1), (0.5, 0.62, 0.1), 0.032, HOSE, shine=0.2)
    s.tube((0.5, 0.62, 0.1), (0.5, 0.66, 0.1), 0.042, (40, 100, 52))
    # The head.
    s.tube((0.5, 0.5, 0.42), (0.5, 0.5, 0.47), 0.045, BRASS, shine=0.6)
    s.tube((0.5, 0.5, 0.47), (0.5, 0.5, 0.5), 0.033, BRASS_DARK, shine=0.6)
    s.tube((0.5, 0.5, 0.5), (0.5, 0.5, 0.56), 0.028, BRASS, shine=0.6)
    nozzle = (0.66, 0.5, 0.6)
    s.tube((0.5, 0.5, 0.54), nozzle, 0.016, BRASS, cap=BRASS_DARK, shine=0.6)
    # The arm with its spring and the deflector at its end.
    s.tube((0.5, 0.5, 0.62), (0.5, 0.5, 0.56), 0.008, STEEL)
    s.tube((0.38, 0.5, 0.62), (0.66, 0.5, 0.64), 0.009, (150, 150, 154), shine=0.5)
    s.box(0.64, 0.47, 0.6, 0.68, 0.53, 0.65, (150, 150, 154), shine=0.5)
    s.tube((0.38, 0.5, 0.62), (0.38, 0.5, 0.58), 0.018, (150, 150, 154), shine=0.5)
    over = None
    if spraying:
        def over(big):
            layer = Image.new('RGBA', big.size, (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            rnd = random.Random(7)
            # The jets fan out away from the viewer and thin out in the air: the sprite keeps inside its tile.
            for jet in range(7):
                angle = -1.25 + jet * 0.14
                reach = 0.42 + rnd.random() * 0.1
                for i in range(1, 19):
                    t = (i + rnd.random() * 0.5) / 18
                    x = nozzle[0] + t * reach * math.cos(angle)
                    y = nozzle[1] + t * reach * math.sin(angle)
                    z = nozzle[2] + t * 0.4 - t * t * 0.45
                    px, py = project(x, y, z)
                    r = (1.9 - 0.9 * t) * SS * (0.7 + rnd.random() * 0.6)
                    d.ellipse([px - r, py - r, px + r, py + r], fill=(205, 232, 255, int(220 * max(0.0, 1 - t) ** 1.3)))
            layer = layer.filter(ImageFilter.GaussianBlur(SS * 0.25))
            big.alpha_composite(layer)
    ground = shadow((0.5, 0.5), 0.13, 0.13, 90)
    return compose(s, ground=ground, over=over, seed=20 + (1 if spraying else 0))


def water_filter(turns):
    """A pair of filter housings on a stand: a pad, two posts and a bar, the pipe through the heads, the white
    housings with their blue caps hanging under them, a pressure gauge between."""
    s = Scene(turns)
    s.box(0.18, 0.3, 0.0, 0.82, 0.7, 0.04, CONCRETE)
    for x0 in (0.22, 0.74):
        s.box(x0, 0.36, 0.04, x0 + 0.04, 0.4, 0.78, FRAME, shine=0.2)
    s.box(0.22, 0.36, 0.74, 0.78, 0.4, 0.78, FRAME, shine=0.2)
    s.box(0.22, 0.4, 0.62, 0.26, 0.5, 0.64, FRAME)
    s.box(0.74, 0.4, 0.62, 0.78, 0.5, 0.64, FRAME)
    pipe_z = 0.66
    s.tube((0.15, 0.5, pipe_z), (0.85, 0.5, pipe_z), 0.035, PIPE, shine=0.3)
    for x in (0.15, 0.83):
        s.tube((x, 0.5, pipe_z), (x + 0.02, 0.5, pipe_z), 0.055, STEEL, shine=0.5)
    for x in (0.39, 0.61):
        s.tube((x, 0.5, pipe_z - 0.08), (x, 0.5, pipe_z + 0.05), 0.075, BLUE, cap=(70, 128, 196), shine=0.35)
        s.tube((x, 0.5, pipe_z - 0.11), (x, 0.5, pipe_z - 0.08), 0.08, (40, 84, 140), shine=0.35)
        s.tube((x, 0.5, 0.14), (x, 0.5, pipe_z - 0.11), 0.068, WHITE, shine=0.35)
        s.tube((x, 0.5, 0.11), (x, 0.5, 0.14), 0.05, WHITE, shine=0.35)
        s.tube((x, 0.5, 0.09), (x, 0.5, 0.11), 0.02, RUBBER)
    # The gauge: a stem up from the pipe, the dial facing the viewer's left.
    s.tube((0.5, 0.5, pipe_z + 0.03), (0.5, 0.5, pipe_z + 0.1), 0.01, BRASS, shine=0.5)
    s.tube((0.5, 0.49, pipe_z + 0.14), (0.5, 0.53, pipe_z + 0.14), 0.045, STEEL, cap=(240, 240, 232), shine=0.5)
    ground = shadow(s.turn((0.5, 0.5, 0))[:2], 0.36, 0.26)
    return compose(s, ground=ground, seed=30 + turns)


# The sheet: what each tile is, and its properties for the game.
PUMP = {'CustomName': 'Water Pump', 'BlocksPlacement': '', 'solidtrans': ''}
FILTER = {'CustomName': 'Water Filter', 'BlocksPlacement': '', 'solidtrans': ''}
TILES = [
    # Pumps: the suction goes into the ground on the side they face.
    (lambda: pump(0), dict(PUMP, Facing='E')),
    (lambda: pump(1), dict(PUMP, Facing='S')),
    (lambda: pump(2), dict(PUMP, Facing='W')),
    (lambda: pump(3), dict(PUMP, Facing='N')),
    (lambda: sprinkler(False), {'CustomName': 'Sprinkler', 'IsLow': ''}),
    (lambda: sprinkler(True), {'CustomName': 'Sprinkler', 'IsLow': ''}),
    # Filters: the pipe runs W-E, then N-S; the stand is behind.
    (lambda: water_filter(0), dict(FILTER, Facing='S')),
    (lambda: water_filter(3), dict(FILTER, Facing='E')),
]


def write_tiles(path):
    out = io.BytesIO()
    out.write(b'tdef')
    out.write(struct.pack('<ii', 1, 1))
    out.write((SHEET + '\n').encode('latin1'))
    out.write((SHEET + '.png\n').encode('latin1'))
    out.write(struct.pack('<iiii', COLS, ROWS, 1, COLS * ROWS))
    for index in range(COLS * ROWS):
        props = TILES[index][1] if index < len(TILES) else {}
        out.write(struct.pack('<i', len(props)))
        for key, value in props.items():
            out.write((key + '\n' + value + '\n').encode('latin1'))
    with open(path, 'wb') as f:
        f.write(out.getvalue())


def trim(image):
    box = image.getbbox() or (0, 0, 1, 1)
    return image.crop(box), box[0], box[1]


def write_pack(path, images):
    """The header-less pack the game reads for mods: one page, an entry per sprite (its place in the page and its
    offset in the full tile), the page as PNG, the end mark."""
    pieces = [(name, *trim(image)) for name, image in images]
    x = y = row = 0
    placed = []
    for name, crop, ox, oy in pieces:
        if x + crop.width > 1024:
            x, y, row = 0, y + row + 2, 0
        placed.append((name, crop, x, y, ox, oy))
        x += crop.width + 2
        row = max(row, crop.height)
    page = Image.new('RGBA', (1024, y + row), (0, 0, 0, 0))
    for name, crop, px, py, ox, oy in placed:
        page.alpha_composite(crop, (px, py))
    png = io.BytesIO()
    page.save(png, 'PNG')
    out = io.BytesIO()
    def string(text):
        data = text.encode('latin1')
        out.write(struct.pack('<i', len(data)) + data)
    out.write(struct.pack('<i', 1))
    string(SHEET + '0')
    out.write(struct.pack('<ii', len(placed), 1))
    for name, crop, px, py, ox, oy in placed:
        string(name)
        out.write(struct.pack('<8i', px, py, crop.width, crop.height, ox, oy, W, H))
    out.write(png.getvalue())
    out.write(b'\xef\xbe\xad\xde')
    with open(path, 'wb') as f:
        f.write(out.getvalue())


# The items' icons: a tile's thing, fitted into 64x64.
ICONS = {'BUWaterPump': 1, 'BUSprinkler': 4, 'BUWaterFilter': 6}


def write_icons(images):
    for name, index in ICONS.items():
        crop = trim(images[index][1])[0]
        scale = 60 / max(crop.width, crop.height)
        crop = crop.resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))), Image.LANCZOS)
        icon = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
        icon.alpha_composite(crop, ((64 - crop.width) // 2, (64 - crop.height) // 2))
        icon.save(os.path.join(ROOT, 'textures', 'Item_%s.png' % name))


def preview(images, path):
    """Each tile on a floor square, side by side, at twice the size."""
    sheet = Image.new('RGBA', (W * len(images), H - 64), (40, 44, 40, 255))
    floor = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(floor).polygon([(64, 192), (128, 224), (64, 256), (0, 224)], fill=(96, 110, 80, 255))
    for index, (_, image) in enumerate(images):
        tile = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        tile.alpha_composite(floor)
        tile.alpha_composite(image)
        sheet.alpha_composite(tile.crop((0, 64, W, H)), (index * W, 0))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(path)


def main():
    images = [('%s_%d' % (SHEET, index), make()) for index, (make, _) in enumerate(TILES)]
    write_tiles(os.path.join(ROOT, 'bu_water.tiles'))
    write_pack(os.path.join(ROOT, 'texturepacks', PACK + '.pack'), images)
    write_icons(images)
    if '--preview' in sys.argv:
        preview(images, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'water_art_preview.png'))
    print('wrote', len(images), 'tiles')


if __name__ == '__main__':
    main()
