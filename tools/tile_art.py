"""Draws this mod's own tiles and writes them as its second tile sheet (bu_water_01): the water units (pump, sprinkler,
filter, booster pump) in each of their looks, the utility panel (the breaker box) in its looks, the relays (a pole for power,
a yard hydrant for water), and the snow that lies on a solar panel (overlays over the first sheet's panels, bu_solar_01).

The art is made here, not painted: each object is a few solids (boxes, cylinders) in a tile's space, projected the
way the game draws a square, shaded by a light from above and the viewer's left, drawn four times larger with a depth
buffer and scaled down. Units are a square's side; the game's 2x tiles show a square as a 128x64 diamond at the bottom
of a 128x256 tile, and a unit up as UP pixels (the game's 2:1 view looks down 30 degrees). The viewer sees the south
(+y, screen left) and east (+x, screen right) sides of things. A lit lamp keeps its colour whatever the light, and
glows: a white-hot core and a soft halo over what is around it.

Saves name the tiles by their place in the sheet: a new tile goes in a free place or a new row, never in a used one,
and the sheet keeps its eight columns.

    py tools/tile_art.py            writes media/bu_water.tiles and media/texturepacks/BuildingUtilitiesWater.pack,
                                    and the items' icons (media/textures/Item_BU*.png) from the tiles
    py tools/tile_art.py --preview  also writes tools/tile_art_preview.png (the tiles on a floor, for a look); a path
                                    after it writes the preview there instead

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
SOLAR_PACK = 'BuildingUtilitiesSolar'
COLS, ROWS = 8, 9
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


# Rime: frozen things whiten, the more the more a face looks up.
ICE = (214, 228, 242)


def frosted(colour, normal, amount):
    k = amount * (0.35 + 0.65 * max(0.0, normal[2]))
    return tuple(c + (i - c) * k for c, i in zip(colour[:3], ICE))


class Scene:
    """Faces of solids, drawn into a depth buffer; what is added is turned a number of quarter turns about the
    tile's middle. Frost whitens every face by so much (0 to 1); a face that emits keeps its colour unshaded."""
    def __init__(self, turns=0, frost=0.0):
        self.turns = turns
        self.frost = frost
        self.faces = []

    def turn(self, p, vector=False):
        x, y, z = p
        for _ in range(self.turns % 4):
            x, y = (-y, x) if vector else (1 - y, x)
        return (x, y, z)

    def face(self, points, colour, normal, shine=0.0, emit=False):
        normal = self.turn(normal, True)
        if dot(normal, VIEW) <= 1e-6:
            return
        if emit:
            rgb = tuple(int(c) for c in colour[:3])
        else:
            if self.frost:
                colour = frosted(colour, normal, self.frost)
            rgb = shade(colour, normal, shine)
        self.faces.append(([self.turn(p) for p in points], rgb))

    def poly(self, points, colour, outward, shine=0.0, emit=False):
        """A flat polygon; its normal from its points, on the side of outward."""
        n = (0.0, 0.0, 0.0)
        for i, p in enumerate(points):
            q = points[(i + 1) % len(points)]
            n = (n[0] + (p[1] - q[1]) * (p[2] + q[2]), n[1] + (p[2] - q[2]) * (p[0] + q[0]),
                 n[2] + (p[0] - q[0]) * (p[1] + q[1]))
        n = unit(n)
        if dot(n, outward) < 0:
            n = tuple(-c for c in n)
        self.face(points, colour, n, shine, emit)

    def box(self, x0, y0, z0, x1, y1, z1, colour, top=None, shine=0.0, emit=False):
        self.face([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], top or colour, (0, 0, 1), shine, emit)
        self.face([(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)], colour, (0, 0, -1), shine, emit)
        self.face([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], colour, (0, 1, 0), shine, emit)
        self.face([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], colour, (0, -1, 0), shine, emit)
        self.face([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], colour, (1, 0, 0), shine, emit)
        self.face([(x0, y0, z0), (x0, y1, z0), (x0, y1, z1), (x0, y0, z1)], colour, (-1, 0, 0), shine, emit)

    def tube(self, a, b, r, colour, cap=None, shine=0.0, segments=40, bands=None, emit=False):
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
                self.face([at(a0, t0), at(a1, t0), at(a1, t1), at(a0, t1)], c, n, shine, emit)
        ring = range(segments)
        self.face([at(2 * math.pi * i / segments, 1) for i in ring], cap or colour, d, shine, emit)
        self.face([at(2 * math.pi * i / segments, 0) for i in ring], cap or colour, tuple(-c for c in d), shine, emit)

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


def compose(scene, ground=None, over=None, seed=1, glows=None):
    big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    if ground:
        big.alpha_composite(ground)
    solid = scene.render()
    big.alpha_composite(solid)
    if over:
        over(big)
    small = big.convert('RGBa').resize((W, H), Image.LANCZOS).convert('RGBA')
    small = finish(small, solid.getchannel('A').resize((W, H), Image.LANCZOS), seed)
    if glows:
        small = glow(small, scene, glows)
    return trim_faint(small)


# The faintest alpha a finished tile keeps: the tails of the soft shadow, of a lamp's haze and of the scaling's ringing
# are taken away below it and the rest stretched to meet it, so no edge shows. The game draws a tile the player stands
# behind dithered (its see-through circle), and a faint pixel comes out there as a lone black dot (seen in game as a
# speckled ring round a machine).
FAINT = 32


def trim_faint(image):
    a = np.array(image)
    alpha = a[..., 3].astype(np.float64)
    a[..., 3] = np.clip((alpha - FAINT) * 255.0 / (255 - FAINT) + 0.5, 0, 255).astype(np.uint8)
    return Image.fromarray(a, 'RGBA')


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
            # a grain, blotches of wear a few pixels across, and grime gathering toward the floor
            n = 1 + (rnd.random() - 0.5) * 0.09
            n *= 1 + 0.045 * math.sin(x * 0.41 + y * 0.17 + seed) * math.sin(y * 0.37 - x * 0.23 + seed * 1.7)
            n *= 1 - 0.1 * min(1, max(0, (y - 150) / 80))
            if inner[x, y] < 128:
                n *= 0.7
            px[x, y] = (min(255, int(r * n)), min(255, int(g * n)), min(255, int(b * n)), a)
    return image


def glow(image, scene, glows):
    """Lit lamps on the finished tile: each a white-hot core and a halo of its colour that brightens what is around
    it, and faintly the air. glows: [(point, colour, radius in units)]."""
    a = np.asarray(image).astype(np.float64) / 255
    alpha = a[..., 3:4]
    premultiplied = a[..., :3] * alpha
    gy, gx = np.mgrid[0:H, 0:W]
    air = np.zeros((H, W, 1))
    air_colour = np.zeros((H, W, 3))
    for point, colour, radius in glows:
        sx, sy = project(*scene.turn(point))
        sx, sy = sx / SS, sy / SS
        r = radius * 64
        d2 = ((gx - sx) ** 2 + (gy - sy) ** 2) / (r * r)
        halo = np.exp(-d2 * 2.2)[..., None]
        core = np.exp(-d2 * 30)[..., None]
        c = np.array(colour[:3]) / 255
        premultiplied += (halo * c * 0.7 + core * (0.55 + 0.45 * c)) * alpha
        haze = halo * 0.3
        air += haze
        air_colour += haze * c
    # The haze in the air takes the colours of the lamps it comes from.
    tint = np.clip(air_colour / np.maximum(air, 1e-9), 0, 1)
    air = np.minimum(air, 0.6) * (1 - alpha)
    premultiplied += tint * air
    alpha = alpha + air
    rgb = np.where(alpha > 0, premultiplied / np.maximum(alpha, 1e-9), 0)
    out = np.concatenate([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)], axis=2)
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), 'RGBA')


# Colours.
CONCRETE = (156, 152, 144)
FRAME = (64, 66, 70)
MOTOR = (58, 80, 98)
MOTOR_DARK = (44, 60, 74)
CASING = (132, 58, 46)
CASING_DARK = (98, 44, 36)
STEEL = (146, 148, 148)
PIPE = (84, 88, 92)
BRASS = (170, 138, 74)
BRASS_DARK = (126, 100, 56)
RUBBER = (36, 36, 38)
HOSE = (62, 100, 64)
WHITE = (196, 196, 190)
BLUE = (66, 92, 124)
# Lamps: their lens lit, and the dark glass of an unlit one.
LIT = {'green': (80, 255, 120), 'amber': (255, 150, 30), 'red': (255, 60, 44)}
UNLIT = {'green': (36, 74, 46), 'amber': (96, 60, 24), 'red': (92, 32, 28)}
BEZEL = (54, 56, 58)


def lamp(s, glows, x, y, z, r, colour, lit):
    """A small round signal lamp on a surface at height z: a black bezel and a domed lens, lit or dark."""
    s.tube((x, y, z), (x, y, z + 0.012), r * 1.35, BEZEL, shine=0.3, segments=32)
    if lit:
        rim, top = LIT[colour], tuple(int(c + (255 - c) * 0.3) for c in LIT[colour])
        s.tube((x, y, z + 0.012), (x, y, z + 0.012 + r * 0.7), r, rim, cap=top, segments=32, emit=True)
        s.tube((x, y, z + 0.012 + r * 0.7), (x, y, z + 0.012 + r * 1.05), r * 0.62, top, cap=(255, 255, 240),
               segments=32, emit=True)
        glows.append(((x, y, z + 0.012 + r), LIT[colour], 0.09 + r))
    else:
        glass = UNLIT[colour]
        s.tube((x, y, z + 0.012), (x, y, z + 0.012 + r * 0.7), r, glass, shine=0.9, segments=32)
        s.tube((x, y, z + 0.012 + r * 0.7), (x, y, z + 0.012 + r * 1.05), r * 0.62, glass, shine=0.9, segments=32)


# The pump's looks: its lamp dark (stopped), green (running), amber (running dry: no water beside it), or dark under
# rime (its box's pipes are frozen).
PUMP_LAMP = {'stopped': None, 'running': 'green', 'dry': 'amber', 'frozen': None}


def pump(turns, look='stopped'):
    """An electric pump on a concrete pad: the motor with its fan cover, fins and terminal box with its lamp, the
    coupling, the red casing; the suction leaves the casing's eye east and goes down into the ground, the delivery
    rises from the top of the casing through a valve and turns east to a flange."""
    frozen = look == 'frozen'
    s = Scene(turns, frost=0.45 if frozen else 0.0)
    glows = []
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
    box_top = axis_z + motor_r + 0.06
    s.box(0.33, 0.43, axis_z + motor_r - 0.02, 0.44, 0.57, box_top, MOTOR_DARK, top=MOTOR)
    s.box(0.44, 0.47, axis_z + motor_r + 0.01, 0.47, 0.53, axis_z + motor_r + 0.04, RUBBER)
    # The running lamp on the terminal box.
    lamp(s, glows, 0.385, 0.5, box_top, 0.026, PUMP_LAMP[look] or 'green', PUMP_LAMP[look] is not None)
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
    over = None
    if frozen:
        # Icicles under the delivery pipe and the suction's elbow, and rime in specks over it all.
        for x, length in ((0.73, 0.07), (0.76, 0.045), (0.79, 0.06)):
            s.tube((x, 0.5, top + 0.09), (x, 0.5, top + 0.09 - length), 0.007, ICE, shine=0.8, segments=12)
        s.tube((0.86, 0.5, axis_z - 0.05), (0.86, 0.5, axis_z - 0.1), 0.006, ICE, shine=0.8, segments=12)
        over = rime(17 + turns)
    ground = shadow(s.turn((0.5, 0.5, 0))[:2], 0.42, 0.32)
    return compose(s, ground=ground, over=over, seed=10 + turns, glows=glows)


def rime(seed):
    """Specks of rime over what was drawn (big canvas)."""
    def over(big):
        rnd = random.Random(seed)
        alpha = big.getchannel('A')
        layer = Image.new('RGBA', big.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        box = alpha.getbbox()
        for _ in range(500):
            x, y = rnd.uniform(box[0], box[2]), rnd.uniform(box[1], box[3])
            if alpha.getpixel((int(x), int(y))) < 250:
                continue
            r = rnd.uniform(0.4, 1.0) * SS
            d.ellipse([x - r, y - r, x + r, y + r], fill=(240, 247, 255, rnd.randint(60, 140)))
        layer = layer.filter(ImageFilter.GaussianBlur(SS * 0.5))
        mask = Image.fromarray(np.minimum(np.asarray(layer.getchannel('A')), np.asarray(alpha)).astype(np.uint8))
        layer.putalpha(mask)
        big.alpha_composite(layer)
    return over


# The frames of a spraying sprinkler: its head turned so far each, round once.
SPRAY_FRAMES = 8


def sprinkler(spraying, frame=0):
    """An impact sprinkler on a spike: a weighted base, the riser with the hose coupling, the brass head, its nozzle
    looking up and out and the arm that knocks it round. Spraying, drops leave the nozzle in arcs; each frame has the
    head turned on by an eighth."""
    angle = 2 * math.pi * frame / SPRAY_FRAMES
    ca, sa = math.cos(angle), math.sin(angle)

    def head(dx, dy, z):
        """A point of the head, dx out along the nozzle and dy across it from the riser."""
        return (0.5 + dx * ca - dy * sa, 0.5 + dx * sa + dy * ca, z)

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
    nozzle = head(0.16, 0, 0.6)
    s.tube((0.5, 0.5, 0.54), nozzle, 0.016, BRASS, cap=BRASS_DARK, shine=0.6)
    # The arm with its spring and the deflector at its end.
    s.tube((0.5, 0.5, 0.62), (0.5, 0.5, 0.56), 0.008, STEEL)
    s.tube(head(-0.12, 0, 0.62), head(0.16, 0, 0.64), 0.009, (150, 150, 154), shine=0.5)
    s.tube(head(0.14, 0, 0.625), head(0.18, 0, 0.625), 0.03, (150, 150, 154), shine=0.5)
    s.tube(head(-0.12, 0, 0.62), head(-0.12, 0, 0.58), 0.018, (150, 150, 154), shine=0.5)
    over = None
    if spraying:
        def over(big):
            layer = Image.new('RGBA', big.size, (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            rnd = random.Random(7)
            # The jets fan out along the nozzle and thin out in the air: the sprite keeps inside its tile.
            for jet in range(7):
                direction = angle + (jet - 3) * 0.14
                reach = 0.42 + rnd.random() * 0.1
                for i in range(1, 19):
                    t = (i + rnd.random() * 0.5) / 18
                    x = nozzle[0] + t * reach * math.cos(direction)
                    y = nozzle[1] + t * reach * math.sin(direction)
                    z = nozzle[2] + t * 0.4 - t * t * 0.45
                    px, py = project(x, y, z)
                    r = (1.9 - 0.9 * t) * SS * (0.7 + rnd.random() * 0.6)
                    d.ellipse([px - r, py - r, px + r, py + r], fill=(205, 232, 255, int(220 * max(0.0, 1 - t) ** 1.3)))
            layer = layer.filter(ImageFilter.GaussianBlur(SS * 0.25))
            big.alpha_composite(layer)
    ground = shadow((0.5, 0.5), 0.13, 0.13, 90)
    return compose(s, ground=ground, over=over, seed=20 + (1 + frame if spraying else 0))


# The filter's looks: its lamp dark (resting: the pipes purify, or another filter of its group works), green (working)
# or red (its media spent).
FILTER_LAMP = {'resting': None, 'working': 'green', 'spent': 'red'}


def water_filter(turns, look='resting'):
    """A pair of filter housings on a stand: a pad, two posts and a bar with the status lamp on it, the pipe through
    the heads, the white housings with their blue caps hanging under them, a pressure gauge between."""
    s = Scene(turns)
    glows = []
    s.box(0.18, 0.3, 0.0, 0.82, 0.7, 0.04, CONCRETE)
    for x0 in (0.22, 0.74):
        s.box(x0, 0.36, 0.04, x0 + 0.04, 0.4, 0.78, FRAME, shine=0.2)
    s.box(0.22, 0.36, 0.74, 0.78, 0.4, 0.78, FRAME, shine=0.2)
    s.box(0.22, 0.4, 0.62, 0.26, 0.5, 0.64, FRAME)
    s.box(0.74, 0.4, 0.62, 0.78, 0.5, 0.64, FRAME)
    # The lamp's housing on the bar, its cable down the post.
    s.box(0.27, 0.35, 0.78, 0.35, 0.41, 0.81, FRAME, top=(78, 80, 84), shine=0.2)
    lamp(s, glows, 0.31, 0.38, 0.81, 0.022, FILTER_LAMP[look] or 'green', FILTER_LAMP[look] is not None)
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
    return compose(s, ground=ground, seed=30 + turns, glows=glows)


# The booster pump's looks: its lamp dark and its display dark (stopped: no power, or its pipes frozen under rime),
# green with the display lit (boosting), amber with the display lit (powered, but no water reaches its floor).
BOOSTER_LAMP = {'stopped': None, 'running': 'green', 'dry': 'amber', 'frozen': None}
STAINLESS = (164, 166, 166)
STAINLESS_DARK = (118, 120, 122)
VESSEL = (60, 86, 120)
VESSEL_DARK = (44, 62, 88)
DISPLAY_LIT = (90, 230, 210)
DISPLAY_DARK = (24, 40, 40)


def handwheel(s, x, y, z, r, colour):
    """A valve's handwheel lying flat at height z: the rim, the hub and four spokes."""
    s.tube((x, y, z), (x, y, z + 0.012), r, colour, cap=CASING_DARK, segments=40, shine=0.3)
    s.tube((x, y, z + 0.012), (x, y, z + 0.02), r * 0.3, CASING_DARK, segments=24)
    s.tube((x, y, z + 0.02), (x, y, z + 0.03), r * 0.14, STEEL, shine=0.5, segments=16)


def booster(turns, look='stopped'):
    """A booster set on a skid, its front (the control box) to the south: the header runs west to east with a valve on
    each side; between them the vertical multistage pump (its cast base on the header, the stack of stages held by
    tie rods, the motor standing on top with its ribs, fan cover and terminal box); behind, the blue pressure vessel
    on its ring stand; on the delivery side a check valve and a gauge; in front, the control box on its post, a lamp
    on its top and a display on its door, a conduit up to the motor."""
    frozen = look == 'frozen'
    powered = look in ('running', 'dry')
    s = Scene(turns, frost=0.45 if frozen else 0.0)
    glows = []
    # Pad and skid.
    s.box(0.08, 0.2, 0.0, 0.92, 0.84, 0.04, CONCRETE)
    for y0 in (0.3, 0.66):
        s.box(0.1, y0, 0.04, 0.9, y0 + 0.05, 0.075, FRAME, top=(80, 82, 86), shine=0.2)
    # The header, west to east, with its flanges at the ends.
    hz, hy = 0.16, 0.56
    s.tube((0.05, hy, hz), (0.95, hy, hz), 0.038, PIPE, shine=0.3)
    for x in (0.05, 0.93):
        s.tube((x, hy, hz), (x + 0.02, hy, hz), 0.058, STEEL, shine=0.5)
    for x in (0.08, 0.92):
        s.box(x - 0.03, hy - 0.03, 0.075, x + 0.03, hy + 0.03, hz - 0.035, FRAME)
    # Suction valve (west) and its wheel.
    s.box(0.16, hy - 0.05, hz - 0.05, 0.24, hy + 0.05, hz + 0.05, PIPE, top=(98, 102, 106), shine=0.3)
    s.tube((0.2, hy, hz + 0.05), (0.2, hy, hz + 0.13), 0.01, STEEL, shine=0.5)
    handwheel(s, 0.2, hy, hz + 0.13, 0.05, CASING)
    # The pump: its cast base on the header, the stages, the tie rods, the lantern and the motor.
    px, py = 0.42, hy
    s.tube((px, py, 0.075), (px, py, 0.11), 0.1, MOTOR_DARK, segments=56)
    s.tube((px, py, 0.11), (px, py, 0.23), 0.085, MOTOR, cap=MOTOR_DARK, segments=56, shine=0.2)
    s.tube((px - 0.12, py, hz), (px + 0.12, py, hz), 0.05, MOTOR, shine=0.2)
    stages = []
    t = 0.0
    while t < 0.999:
        stages.append((t, min(1.0, t + 0.16), STAINLESS))
        stages.append((min(1.0, t + 0.16), min(1.0, t + 0.2), STAINLESS_DARK))
        t += 0.2
    s.tube((px, py, 0.23), (px, py, 0.53), 0.062, STAINLESS, cap=STAINLESS_DARK, segments=56, bands=stages, shine=0.7)
    for angle in (0.25, 1.82, 3.39, 4.96):
        rx, ry = px + math.cos(angle) * 0.078, py + math.sin(angle) * 0.078
        s.tube((rx, ry, 0.22), (rx, ry, 0.56), 0.008, STEEL, shine=0.6, segments=12)
    s.tube((px, py, 0.53), (px, py, 0.57), 0.085, MOTOR_DARK, segments=56)
    s.box(px - 0.05, py - 0.05, 0.57, px + 0.05, py + 0.05, 0.6, (60, 62, 66))
    s.tube((px, py, 0.6), (px, py, 0.63), 0.09, MOTOR_DARK, segments=56)
    s.tube((px, py, 0.63), (px, py, 0.83), 0.082, MOTOR, cap=MOTOR_DARK, segments=56, shine=0.15)
    for i in range(14):
        angle = 2 * math.pi * i / 14
        rx, ry = px + math.cos(angle) * 0.084, py + math.sin(angle) * 0.084
        s.tube((rx, ry, 0.64), (rx, ry, 0.82), 0.007, MOTOR_DARK, segments=8)
    s.tube((px, py, 0.83), (px, py, 0.9), 0.078, (40, 44, 48), cap=(30, 33, 36), segments=56)
    s.tube((px, py, 0.9), (px, py, 0.91), 0.05, (30, 33, 36), segments=40)
    s.box(px - 0.04, py + 0.08, 0.68, px + 0.04, py + 0.12, 0.77, MOTOR_DARK, top=MOTOR)
    # Behind the pump, the pressure vessel on its ring stand, piped to the header.
    vx, vy = 0.74, 0.36
    s.tube((vx, vy, 0.075), (vx, vy, 0.11), 0.07, FRAME, segments=40)
    s.tube((vx, vy, 0.11), (vx, vy, 0.14), 0.11, VESSEL_DARK, segments=56)
    s.tube((vx, vy, 0.14), (vx, vy, 0.5), 0.115, VESSEL, segments=56, shine=0.45,
           bands=[(0, 0.5, VESSEL), (0.5, 0.52, VESSEL_DARK), (0.52, 1, VESSEL)])
    for r0, z0, z1 in ((0.108, 0.5, 0.53), (0.094, 0.53, 0.555), (0.072, 0.555, 0.574), (0.042, 0.574, 0.586)):
        s.tube((vx, vy, z0), (vx, vy, z1), r0, VESSEL, segments=56, shine=0.45)
    s.tube((vx, vy, 0.586), (vx, vy, 0.605), 0.014, BRASS, cap=BRASS_DARK, shine=0.6, segments=16)
    s.tube((vx, hy, hz), (vx, hy - 0.08, hz), 0.022, PIPE, shine=0.3)
    s.tube((vx, hy - 0.08, hz), (vx, vy + 0.1, 0.12), 0.022, PIPE, shine=0.3)
    # The delivery side: a check valve, a tee up to the gauge facing the front, a valve and its wheel.
    s.tube((0.6, hy, hz), (0.66, hy, hz), 0.055, CASING_DARK, segments=40, shine=0.25)
    s.box(0.6, hy - 0.035, hz + 0.03, 0.66, hy + 0.035, hz + 0.065, CASING, shine=0.25)
    s.tube((0.86, hy, hz + 0.03), (0.86, hy, hz + 0.16), 0.011, BRASS, shine=0.5)
    s.tube((0.86, hy - 0.01, hz + 0.2), (0.86, hy + 0.035, hz + 0.2), 0.048, STEEL, cap=DIAL, shine=0.5)
    s.tube((0.86, hy + 0.035, hz + 0.2), (0.86, hy + 0.038, hz + 0.2), 0.008, (30, 30, 30))
    s.box(0.76, hy - 0.05, hz - 0.05, 0.82, hy + 0.05, hz + 0.05, PIPE, top=(98, 102, 106), shine=0.3)
    s.tube((0.79, hy, hz + 0.05), (0.79, hy, hz + 0.12), 0.01, STEEL, shine=0.5)
    handwheel(s, 0.79, hy, hz + 0.12, 0.045, CASING)
    # The control box on its post in front: the lamp on its top, the display on its door; the conduit to the motor.
    s.box(0.17, 0.74, 0.04, 0.2, 0.77, 0.44, FRAME, shine=0.2)
    s.box(0.09, 0.73, 0.44, 0.29, 0.8, 0.68, HOUSING, top=HOUSING_DARK, shine=0.15)
    s.box(0.1, 0.8, 0.45, 0.28, 0.805, 0.67, DOOR, shine=0.2)
    display = DISPLAY_LIT if powered else DISPLAY_DARK
    s.box(0.13, 0.805, 0.58, 0.25, 0.81, 0.635, display, emit=powered)
    if powered:
        glows.append(((0.19, 0.81, 0.607), DISPLAY_LIT, 0.05))
    for x in (0.14, 0.19, 0.24):
        s.box(x - 0.012, 0.805, 0.5, x + 0.012, 0.812, 0.53, TOGGLE)
    s.box(0.12, 0.805, 0.465, 0.26, 0.808, 0.48, HAZARD)
    lamp(s, glows, 0.19, 0.765, 0.68, 0.024, BOOSTER_LAMP[look] or 'green', BOOSTER_LAMP[look] is not None)
    s.tube((0.27, 0.76, 0.66), (0.37, 0.7, 0.74), 0.011, RUBBER, segments=12)
    over = None
    if frozen:
        # Icicles under the header where nothing is fitted on it, and under the branch to the vessel (not inside it).
        for x, length in ((0.27, 0.06), (0.57, 0.05), (0.71, 0.07), (0.86, 0.045)):
            s.tube((x, hy, hz - 0.035), (x, hy, hz - 0.035 - length), 0.007, ICE, shine=0.8, segments=12)
        for y, length in ((0.53, 0.05), (0.5, 0.04)):
            s.tube((vx, y, hz - 0.02), (vx, y, hz - 0.02 - length), 0.006, ICE, shine=0.8, segments=12)
        over = rime(41 + turns)
    ground = shadow(s.turn((0.5, 0.52, 0))[:2], 0.44, 0.34)
    return compose(s, ground=ground, over=over, seed=60 + turns, glows=glows)


# The utility panel (the breaker box): a floor-standing console in grey sheet steel. Its looks: off (every lamp dark),
# on (the green and amber power lamps lit, the meter up), tripped (the red lamp lit, the main breaker's handle fallen
# to its middle, the meter down) and tripped with the red lamp dark: the client turns a tripped box between the two.
HOUSING = (140, 146, 148)
HOUSING_DARK = (104, 109, 112)
DOOR = (150, 156, 158)
TRIM = (66, 69, 72)
PLINTH = (44, 46, 48)
MODULE = (196, 194, 186)
TOGGLE = (40, 40, 42)
HANDLE = (160, 52, 40)
DIAL = (220, 216, 200)
LABEL = (204, 200, 188)
HAZARD = (196, 160, 52)
BOX_LAMPS = {'off': (), 'on': ('green', 'amber'), 'tripped': ('red',), 'tripped_dim': ()}


def console(turns, look):
    """The console faces south (+y): a plinth; the cabinet with its door (a row of breakers behind a window, the main
    breaker with its red handle, a label and a warning sign, louvres), a sloped desk (two rotary switches and a key
    switch), a meter bridge at the back (a round meter on its front, the three signal lamps on its top, where they are
    seen from every side); on the back a conduit into the floor and louvres, louvres on the sides too."""
    s = Scene(turns)
    glows = []
    x0, x1, yb, yf = 0.16, 0.84, 0.3, 0.7
    zt, yd, zd, zb = 0.58, 0.5, 0.66, 0.8
    s.box(x0 + 0.02, yb + 0.02, 0.0, x1 - 0.02, yf - 0.02, 0.04, PLINTH)
    s.box(x0, yb, 0.04, x1, yf, zt, HOUSING, shine=0.15)
    # The desk slopes up from the front to the meter bridge.
    slope = unit((0, zd - zt, yf - yd))
    s.poly([(x0, yf, zt), (x1, yf, zt), (x1, yd, zd), (x0, yd, zd)], HOUSING_DARK, slope, shine=0.15)
    s.poly([(x1, yf, zt), (x1, yd, zt), (x1, yd, zd)], HOUSING, (1, 0, 0), shine=0.15)
    s.poly([(x0, yf, zt), (x0, yd, zt), (x0, yd, zd)], HOUSING, (-1, 0, 0), shine=0.15)
    s.box(x0, yb, zt, x1, yd, zb, HOUSING, shine=0.15)
    s.box(x0 - 0.008, yb - 0.008, zb, x1 + 0.008, yd + 0.008, zb + 0.016, TRIM, shine=0.3)
    s.box(x0 - 0.008, yf - 0.012, zt - 0.012, x1 + 0.008, yf + 0.006, zt + 0.004, TRIM, shine=0.3)

    # The door, a little proud of the front, and what is on it.
    f = yf + 0.008
    s.box(x0 + 0.03, yf, 0.07, x1 - 0.03, f, zt - 0.03, DOOR, shine=0.2)
    # The breakers behind their window: a dark recess, six modules with their toggles up.
    s.box(0.24, f, 0.32, 0.6, f + 0.005, 0.46, (36, 38, 40))
    for i in range(6):
        bx = 0.252 + i * 0.058
        s.box(bx, f + 0.005, 0.335, bx + 0.046, f + 0.02, 0.445, MODULE, shine=0.2)
        s.box(bx + 0.015, f + 0.02, 0.395, bx + 0.031, f + 0.04, 0.43, TOGGLE)
    # The main breaker: its body, and its handle up, or fallen to the middle when it tripped.
    s.box(0.645, f, 0.3, 0.775, f + 0.03, 0.48, (58, 60, 62), shine=0.25)
    s.box(0.665, f + 0.03, 0.315, 0.755, f + 0.034, 0.465, (30, 31, 33))
    hz = 0.37 if look.startswith('tripped') else 0.42
    s.box(0.685, f + 0.03, hz, 0.735, f + 0.075, hz + 0.035, HANDLE, shine=0.35)
    # A label over the breakers with lines of print, the warning sign beside it.
    s.box(0.24, f, 0.485, 0.5, f + 0.004, 0.53, LABEL)
    for i, length in enumerate((0.2, 0.15, 0.17)):
        lz = 0.495 + i * 0.012
        s.box(0.255, f + 0.004, lz, 0.255 + length, f + 0.006, lz + 0.005, (70, 70, 72))
    s.poly([(0.66, f + 0.004, 0.49), (0.74, f + 0.004, 0.49), (0.70, f + 0.004, 0.545)], (40, 40, 40), (0, 1, 0))
    s.poly([(0.668, f + 0.006, 0.495), (0.732, f + 0.006, 0.495), (0.70, f + 0.006, 0.535)], HAZARD, (0, 1, 0))
    # The door's latch, louvres at its foot.
    s.box(0.2, f, 0.22, 0.215, f + 0.025, 0.3, (52, 54, 56), shine=0.5)
    for i in range(4):
        lz = 0.1 + i * 0.03
        s.box(0.3, f, lz, 0.7, f + 0.01, lz + 0.012, HOUSING_DARK)

    # The desk: two rotary switches and a key switch, standing out of the slope.
    def on_desk(x, t, height):
        """A point on the desk, t of the way up it, so far out of it."""
        y, z = yf - (yf - yd) * t, zt + (zd - zt) * t
        return (x, y + slope[1] * height, z + slope[2] * height)
    for x in (0.27, 0.39):
        s.tube(on_desk(x, 0.5, 0), on_desk(x, 0.5, 0.012), 0.032, TRIM, shine=0.3, segments=32)
        s.tube(on_desk(x, 0.5, 0.012), on_desk(x, 0.5, 0.036), 0.02, (24, 24, 26), cap=(44, 44, 46), shine=0.4,
               segments=32)
    s.tube(on_desk(0.52, 0.5, 0), on_desk(0.52, 0.5, 0.016), 0.026, STEEL, shine=0.7, segments=32)
    s.tube(on_desk(0.52, 0.5, 0.016), on_desk(0.52, 0.5, 0.03), 0.008, BRASS, shine=0.6, segments=16)
    s.poly([on_desk(0.62, 0.3, 0.003), on_desk(0.8, 0.3, 0.003), on_desk(0.8, 0.7, 0.003), on_desk(0.62, 0.7, 0.003)],
           LABEL, slope)

    # The meter on the bridge's front: a bezel, the dial with its scale, the needle up when there is power.
    mx, mz, mr = 0.3, (zd + zb) / 2, 0.052
    s.tube((mx, yd, mz), (mx, yd + 0.012, mz), mr, TRIM, shine=0.4, segments=48)
    s.tube((mx, yd + 0.012, mz), (mx, yd + 0.015, mz), mr * 0.8, DIAL, segments=48)
    for i in range(7):
        a = math.radians(160 - i * 23.3)
        r0, r1 = mr * (0.58 if i % 3 == 0 else 0.66), mr * 0.74
        s.tube((mx + r0 * math.cos(a), yd + 0.016, mz + r0 * math.sin(a)),
               (mx + r1 * math.cos(a), yd + 0.016, mz + r1 * math.sin(a)), 0.0025, (40, 40, 40), segments=6)
    s.box(mx + mr * 0.3, yd + 0.015, mz - mr * 0.62, mx + mr * 0.62, yd + 0.017, mz - mr * 0.42, (200, 50, 40))
    a = math.radians(55 if look == 'on' else 155)
    s.tube((mx, yd + 0.019, mz), (mx + mr * 0.68 * math.cos(a), yd + 0.019, mz + mr * 0.68 * math.sin(a)), 0.0035,
           (24, 24, 24), segments=6)
    s.tube((mx, yd + 0.015, mz), (mx, yd + 0.022, mz), 0.008, (30, 30, 30), segments=12)
    # A nameplate beside the meter.
    s.box(0.42, yd, 0.7, 0.78, yd + 0.004, 0.77, (52, 56, 60), shine=0.3)
    s.box(0.44, yd + 0.004, 0.725, 0.66, yd + 0.006, 0.745, (196, 198, 196))

    # The signal lamps on the bridge's top: green and amber for power, red for a tripped breaker.
    for colour, x in (('green', 0.5), ('amber', 0.62), ('red', 0.74)):
        lamp(s, glows, x, 0.4, zb + 0.016, 0.03, colour, colour in BOX_LAMPS[look])

    # The door's hinges.
    for hz in (0.12, 0.47):
        s.tube((x1 - 0.035, f + 0.004, hz), (x1 - 0.035, f + 0.004, hz + 0.04), 0.008, TRIM, shine=0.5, segments=12)
    # The back: a panel screwed on, louvres in it, a plate, and the supply's conduit into the floor through a gland box.
    s.box(x0 + 0.04, yb - 0.006, 0.08, x1 - 0.04, yb, zb - 0.06, DOOR, shine=0.2)
    for sx in (x0 + 0.06, x1 - 0.06):
        for sz in (0.1, zb - 0.08):
            s.tube((sx, yb - 0.006, sz), (sx, yb - 0.01, sz), 0.007, STEEL, shine=0.6, segments=10)
    for i in range(4):
        lz = 0.44 + i * 0.03
        s.box(0.3, yb - 0.014, lz, 0.7, yb - 0.006, lz + 0.012, HOUSING_DARK)
    s.box(0.4, yb - 0.01, 0.32, 0.6, yb - 0.006, 0.38, LABEL)
    s.box(0.415, yb - 0.012, 0.35, 0.56, yb - 0.01, 0.356, (70, 70, 72))
    s.box(0.44, yb - 0.04, 0.12, 0.56, yb, 0.22, HOUSING_DARK, shine=0.2)
    s.tube((0.5, yb - 0.02, 0.13), (0.5, yb - 0.02, -0.02), 0.028, PIPE, shine=0.4, segments=24)
    # The sides: louvres high up.
    for xs, xo in ((x1, 0.01), (x0, -0.01)):
        for i in range(3):
            lz = 0.38 + i * 0.03
            s.box(min(xs, xs + xo), 0.38, lz, max(xs, xs + xo), 0.62, lz + 0.012, HOUSING_DARK)
    ground = shadow(s.turn((0.5, 0.5, 0))[:2], 0.42, 0.3, 120)
    return compose(s, ground=ground, seed=40 + turns, glows=glows)


# Snow on a solar panel: an overlay over its tile in the first sheet (bu_solar_01), light or heavy.
SOLAR_TILES = {}


def read_pack(path):
    """The sprites of a header-less pack (as write_pack writes them), each as a full tile."""
    data = open(path, 'rb').read()
    pos = 0

    def number():
        nonlocal pos
        value = struct.unpack_from('<i', data, pos)[0]
        pos += 4
        return value

    def string():
        nonlocal pos
        length = number()
        text = data[pos:pos + length].decode('latin1')
        pos += length
        return text

    tiles = {}
    for _ in range(number()):
        string()
        entries = []
        count, _alpha = number(), number()
        for _ in range(count):
            name = string()
            entries.append((name, struct.unpack_from('<8i', data, pos)))
            pos += 32
        end = data.index(b'IEND', pos) + 8
        page = Image.open(io.BytesIO(data[pos:end])).convert('RGBA')
        pos = data.index(b'\xef\xbe\xad\xde', end) + 4
        for name, (px, py, w, h, ox, oy, fw, fh) in entries:
            tile = Image.new('RGBA', (fw, fh), (0, 0, 0, 0))
            tile.alpha_composite(page.crop((px, py, px + w, py + h)), (ox, oy))
            tiles[name] = tile
    return tiles


def solar_tile(index):
    if not SOLAR_TILES:
        SOLAR_TILES.update(read_pack(os.path.join(ROOT, 'texturepacks', SOLAR_PACK + '.pack')))
    return SOLAR_TILES['bu_solar_01_%d' % index]


def hull(points):
    """The convex hull of points (x, y), counter-clockwise (Andrew's monotone chain)."""
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for q in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], q) <= 0:
            lower.pop()
        lower.append(q)
    for q in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], q) <= 0:
            upper.pop()
        upper.append(q)
    return lower[:-1] + upper[:-1]


def snow(index, heavy):
    """Snow over the cells of a solar panel tile: a thin dusting the cells show through, thicker toward the low edge,
    or a cover all over it."""
    panel = np.asarray(solar_tile(index)).astype(np.int32)
    r, g, b, a = panel[..., 0], panel[..., 1], panel[..., 2], panel[..., 3]
    cells = ((b > r + 30) & (b > 60) & (a > 200))
    # the face is the hull of the cells found (a cell under the panel's sheen is too pale to be found by its colour,
    # and was left as a dark square in the snow), drawn a pixel in from the frame
    ys, xs = np.nonzero(cells)
    face = Image.new('L', (W, H), 0)
    ImageDraw.Draw(face).polygon(hull(list(zip(xs.tolist(), ys.tolist()))), fill=255)
    mask = face.filter(ImageFilter.MinFilter(3))
    mask = np.asarray(mask.filter(ImageFilter.GaussianBlur(0.6))).astype(np.float64) / 255 * (a > 200)
    rnd = np.random.RandomState(50 + index * 2 + heavy)
    # soft drifts a few cells across (a finer noise read as static on the cells)
    noise = Image.fromarray((rnd.rand(H // 16, W // 16) * 255).astype(np.uint8)).resize((W, H), Image.BICUBIC)
    noise = np.asarray(noise.filter(ImageFilter.GaussianBlur(4))).astype(np.float64) / 255
    fine = np.asarray(Image.fromarray((rnd.rand(H // 4, W // 4) * 255).astype(np.uint8)).resize((W, H), Image.BICUBIC)
                      .filter(ImageFilter.GaussianBlur(1.2))).astype(np.float64) / 255
    # Lower on the screen is lower on the panel: snow slides down and lies thicker there.
    rows = np.nonzero(mask.max(axis=1) > 0.5)[0]
    low = np.clip((np.arange(H)[:, None] - rows.min()) / max(1, rows.max() - rows.min()), 0, 1)
    if heavy:
        cover = mask * np.clip(0.94 + 0.06 * noise, 0, 1)
    else:
        cover = mask * np.clip(0.3 + 0.35 * (noise - 0.5) + 0.05 * (fine - 0.5) + 0.5 * low ** 2, 0, 0.9)
    light = 0.9 + 0.07 * noise + 0.02 * fine
    rgb = np.stack([238 * light, 243 * light, 251 * light], axis=2)
    out = np.concatenate([np.clip(rgb, 0, 255), (cover * 255)[..., None]], axis=2)
    return Image.fromarray(out.astype(np.uint8), 'RGBA')


# The sheet: what each tile is, and its properties for the game. Facing as the vanilla object it stands for.
POLE = {'CustomName': 'Utility Pole', 'BlocksPlacement': '', 'solidtrans': ''}
HYDRANT = {'CustomName': 'Yard Hydrant', 'IsLow': ''}
PUMP = {'CustomName': 'Water Pump', 'BlocksPlacement': '', 'solidtrans': ''}
FILTER = {'CustomName': 'Water Filter', 'BlocksPlacement': '', 'solidtrans': ''}
SPRINKLER = {'CustomName': 'Sprinkler', 'IsLow': ''}
BOX = {'CustomName': 'Utility Panel', 'BlocksPlacement': '', 'solidtrans': ''}
BOOSTER = {'CustomName': 'Booster Pump', 'BlocksPlacement': '', 'solidtrans': ''}
PUMP_FACINGS = ((0, 'E'), (1, 'S'), (2, 'W'), (3, 'N'))
FILTER_FACINGS = ((0, 'S'), (3, 'E'))
BOX_FACINGS = ((0, 'S'), (3, 'E'), (2, 'N'), (1, 'W'))
SNOW_PANELS = (8, 9, 10)  # flat, W, N


def pumps(look):
    return [(lambda t=t, look=look: pump(t, look), dict(PUMP, Facing=f)) for t, f in PUMP_FACINGS]


def filters(look):
    return [(lambda t=t, look=look: water_filter(t, look), dict(FILTER, Facing=f)) for t, f in FILTER_FACINGS]


def boxes(look):
    return [(lambda t=t, look=look: console(t, look), dict(BOX, Facing=f)) for t, f in BOX_FACINGS]


def boosters(look):
    return [(lambda t=t, look=look: booster(t, look), dict(BOOSTER, Facing=f)) for t, f in BOX_FACINGS]


WOOD = (112, 84, 58)
WOOD_DARK = (84, 62, 42)
PORCELAIN = (226, 226, 218)


def pole():
    """A power relay, for now: a wooden pole on the square's middle with a crossarm across the top, a white insulator
    at each end and one on the pole's top (a stand-in until the art is drawn)."""
    s = Scene()
    s.tube((0.5, 0.5, 0.0), (0.5, 0.5, 2.3), 0.07, WOOD, cap=WOOD_DARK)
    s.box(0.12, 0.46, 2.0, 0.88, 0.54, 2.08, WOOD_DARK, top=WOOD)
    for x in (0.18, 0.82):
        s.tube((x, 0.5, 2.08), (x, 0.5, 2.18), 0.028, PORCELAIN, cap=PORCELAIN, shine=0.6)
    s.tube((0.5, 0.5, 2.3), (0.5, 0.5, 2.38), 0.03, PORCELAIN, cap=PORCELAIN, shine=0.6)
    return compose(s, ground=shadow((0.5, 0.5), 0.14, 0.07))


def hydrant():
    """A water relay, for now: a valve box set in the ground, its green lid, and a riser with a red handwheel beside
    it (a stand-in until the art is drawn)."""
    s = Scene()
    s.box(0.3, 0.3, 0.0, 0.7, 0.7, 0.06, (88, 90, 86), top=(46, 92, 60))
    s.tube((0.5, 0.5, 0.06), (0.5, 0.5, 0.42), 0.035, STEEL, cap=STEEL, shine=0.4)
    handwheel(s, 0.5, 0.5, 0.44, 0.09, (170, 40, 34))
    return compose(s, ground=shadow((0.5, 0.5), 0.25, 0.13))


def snows(heavy):
    return [(lambda index=index: snow(index, heavy), {}) for index in SNOW_PANELS]


TILES = (
    # 0-3: pumps, stopped: the suction goes into the ground on the side they face (E, S, W, N).
    pumps('stopped')
    # 4, 5: the sprinkler idle, then its first spraying frame; the others follow the filters.
    + [(lambda: sprinkler(False), SPRINKLER), (lambda: sprinkler(True, 0), SPRINKLER)]
    # 6, 7: filters resting: the pipe runs W-E, then N-S; the stand is behind.
    + filters('resting')
    # 8-14: the sprinkler's other spraying frames; 15 free.
    + [(lambda frame=frame: sprinkler(True, frame), SPRINKLER) for frame in range(1, SPRAY_FRAMES)]
    + [None]
    # 16-27: pumps running, running dry and frozen, each E, S, W, N.
    + pumps('running') + pumps('dry') + pumps('frozen')
    # 28-31: filters working, then spent.
    + filters('working') + filters('spent')
    # 32-47: the utility panel off, on, tripped and tripped with its lamp dark, each S, E, N, W.
    + boxes('off') + boxes('on') + boxes('tripped') + boxes('tripped_dim')
    # 48-53: snow on a solar panel (flat, W, N), light then heavy; 54 the power relay's pole, 55 the water relay's
    # hydrant (stand-ins).
    + snows(False) + snows(True) + [(pole, POLE), (hydrant, HYDRANT)]
    # 56-71: the booster pump stopped, running, running with no water at its floor and frozen, each facing S, E, N, W.
    + boosters('stopped') + boosters('running') + boosters('dry') + boosters('frozen')
)


def write_tiles(path):
    out = io.BytesIO()
    out.write(b'tdef')
    out.write(struct.pack('<ii', 1, 1))
    out.write((SHEET + '\n').encode('latin1'))
    out.write((SHEET + '.png\n').encode('latin1'))
    out.write(struct.pack('<iiii', COLS, ROWS, 1, COLS * ROWS))
    for index in range(COLS * ROWS):
        props = TILES[index][1] if index < len(TILES) and TILES[index] else {}
        out.write(struct.pack('<i', len(props)))
        for key, value in props.items():
            out.write((key + '\n' + value + '\n').encode('latin1'))
    with open(path, 'wb') as f:
        f.write(out.getvalue())


def trim(image):
    box = image.getbbox() or (0, 0, 1, 1)
    return image.crop(box), box[0], box[1]


def write_pack(path, images):
    write_pack_named(path, SHEET, images)


def write_pack_named(path, sheet, images):
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
    string(sheet + '0')
    out.write(struct.pack('<ii', len(placed), 1))
    for name, crop, px, py, ox, oy in placed:
        string(name)
        out.write(struct.pack('<8i', px, py, crop.width, crop.height, ox, oy, W, H))
    out.write(png.getvalue())
    out.write(b'\xef\xbe\xad\xde')
    with open(path, 'wb') as f:
        f.write(out.getvalue())


# The items' icons: a tile's thing at the game's 32 px, a little brighter, with a dark outline (as Operation Acorn's
# items have; a 64 px tile shrunk by the game read soft and grey beside them).
ICONS = {'BUWaterPump': 1, 'BUSprinkler': 4, 'BUWaterFilter': 6, 'BUBreakerBox': 32, 'BUBoosterPump': 56,
         'BUPowerPole': 54, 'BUYardHydrant': 55}
ICON = 32


def item_icon(image):
    crop = trim(image)[0]
    a = np.asarray(crop).astype(np.float64)
    a[..., :3] = np.clip(a[..., :3] * 1.18, 0, 255)
    crop = Image.fromarray(a.astype(np.uint8), 'RGBA')
    inner = ICON - 4
    scale = inner / max(crop.width, crop.height)
    small = crop.convert('RGBa').resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))),
                                        Image.LANCZOS).convert('RGBA')
    out = Image.new('RGBA', (ICON, ICON), (0, 0, 0, 0))
    out.alpha_composite(small, ((ICON - small.width) // 2, (ICON - small.height) // 2))
    grown = out.getchannel('A').filter(ImageFilter.MaxFilter(3))
    ring = Image.new('RGBA', out.size, (22, 24, 22, 0))
    ring.putalpha(Image.eval(grown, lambda v: 215 if v > 20 else 0))
    ring.alpha_composite(out)
    return ring


def write_icons(images):
    for name, index in ICONS.items():
        item_icon(images[index]).save(os.path.join(ROOT, 'textures', 'Item_%s.png' % name))


def preview(images, path):
    """Each tile on a floor square, eight to a row as in the sheet, at twice the size; a snow overlay over its solar
    panel."""
    rows = (len(images) + COLS - 1) // COLS
    sheet = Image.new('RGBA', (W * COLS, (H - 64) * rows), (40, 44, 40, 255))
    floor = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(floor).polygon([(64, 192), (128, 224), (64, 256), (0, 224)], fill=(96, 110, 80, 255))
    for index, image in enumerate(images):
        if image is None:
            continue
        tile = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        tile.alpha_composite(floor)
        if 48 <= index < 54:
            tile.alpha_composite(solar_tile(SNOW_PANELS[(index - 48) % 3]))
        tile.alpha_composite(image)
        sheet.alpha_composite(tile.crop((0, 64, W, H)), ((index % COLS) * W, (index // COLS) * (H - 64)))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(path)


def main():
    images = [entry[0]() if entry else None for entry in TILES]
    write_tiles(os.path.join(ROOT, 'bu_water.tiles'))
    write_pack(os.path.join(ROOT, 'texturepacks', PACK + '.pack'),
               [('%s_%d' % (SHEET, index), image) for index, image in enumerate(images) if image is not None])
    write_icons(images)
    if '--preview' in sys.argv:
        at = sys.argv.index('--preview') + 1
        path = sys.argv[at] if at < len(sys.argv) else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                   'tile_art_preview.png')
        preview(images, path)
    print('wrote', sum(1 for image in images if image is not None), 'tiles')


if __name__ == '__main__':
    main()
