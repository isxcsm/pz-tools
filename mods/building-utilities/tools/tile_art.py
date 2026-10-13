"""Draws this mod's own tiles and writes them as its second tile sheet (bu_water_01): the water units (pump, sprinkler,
filter, booster pump) in each of their looks, the utility panel (the breaker box) of each tier in its looks, indoors and
outdoors on a pedestal, the relays (a junction box for power, a yard hydrant for water), the snow that lies on a solar
panel (overlays over the first sheet's panels, bu_solar_01), and the lines laid on the floor (a cable, a pipe). Also the
items' icons, and the control board's.

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
COLS, ROWS = 8, 32
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


def smooth_segments(segments, radius):
    """The facets round a tube or a dome: as asked, but never so few that one shows on its outline at the game's size."""
    return max(segments, min(96, int(radius * 220)))


class Scene:
    """Faces of solids, drawn into a depth buffer; what is added is turned a number of quarter turns about the
    tile's middle. Frost whitens every face by so much (0 to 1); a face that emits keeps its colour unshaded."""
    def __init__(self, turns=0, frost=0.0):
        self.turns = turns
        self.frost = frost
        self.faces = []
        # How far up what is drawn stands (an outdoor box on its pedestal); the ground is at -lift.
        self.lift = 0.0

    def turn(self, p, vector=False):
        x, y, z = p
        for _ in range(self.turns % 4):
            x, y = (-y, x) if vector else (1 - y, x)
        return (x, y, z) if vector else (x, y, z + self.lift)

    def face(self, points, colour, normal, shine=0.0, emit=False, normals=None):
        """A flat face. normals: the surface's normal at each point (a tube's or a sphere's facet), so it is shaded
        smooth across, its normal blended pixel by pixel (shaded flat, a round thing showed its facets as bands)."""
        normal = self.turn(normal, True)
        if dot(normal, VIEW) <= 1e-6:
            return
        smooth = None
        if emit:
            rgb = tuple(int(c) for c in colour[:3])
        else:
            if self.frost:
                colour = frosted(colour, normal, self.frost)
            rgb = shade(colour, normal, shine)
            if normals:
                smooth = (colour[:3], shine, [self.turn(n, True) for n in normals])
        self.faces.append(([self.turn(p) for p in points], rgb, normal[2], smooth))

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

    def tube(self, a, b, r, colour, cap=None, shine=0.0, segments=40, bands=None, emit=False, ends=True, paint=None,
             sunk=False):
        """A cylinder from point a to point b; bands: [(from, to, colour)] along it, 0..1; ends: its caps (an open
        tube's ends are hidden in what it runs into); paint(normal, colour): a face's colour by which way it faces (a
        stripe along it); sunk: what of it is under the ground (z 0) is left out, its faces there pressed onto it."""
        axis = tuple(q - p for p, q in zip(a, b))
        length = math.sqrt(dot(axis, axis))
        d = unit(axis)
        segments = smooth_segments(segments, r)
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
            n0 = tuple(u_ * math.cos(a0) + v_ * math.sin(a0) for u_, v_ in zip(u, v))
            n1 = tuple(u_ * math.cos(a1) + v_ * math.sin(a1) for u_, v_ in zip(u, v))
            for t0, t1, c in bands or [(0, 1, colour)]:
                quad = [at(a0, t0), at(a1, t0), at(a1, t1), at(a0, t1)]
                if sunk:
                    if all(q[2] <= 0 for q in quad):
                        continue
                    quad = [(q[0], q[1], max(0.0, q[2])) for q in quad]
                self.face(quad, paint(n, c) if paint else c, n, shine, emit, normals=[n0, n1, n1, n0])
        if not ends:
            return
        ring = range(segments)
        self.face([at(2 * math.pi * i / segments, 1) for i in ring], cap or colour, d, shine, emit)
        self.face([at(2 * math.pi * i / segments, 0) for i in ring], cap or colour, tuple(-c for c in d), shine, emit)

    def dome(self, centre, r, h, colour, shine=0.0, rings=10, segments=56):
        """A vessel's head: the upper half of an ellipsoid over centre, r across and h high, shaded smooth (tubes
        stacked narrower and narrower read as steps)."""
        cx, cy, cz = centre
        segments = smooth_segments(segments, r)

        def pt(l, a):
            return (cx + r * math.cos(l) * math.cos(a), cy + r * math.cos(l) * math.sin(a), cz + h * math.sin(l))

        def nrm(l, a):
            return unit((math.cos(l) * math.cos(a) / r, math.cos(l) * math.sin(a) / r, math.sin(l) / h))
        for i in range(rings):
            l0, l1 = math.pi / 2 * i / rings, math.pi / 2 * (i + 1) / rings
            for j in range(segments):
                a0, a1 = 2 * math.pi * j / segments, 2 * math.pi * (j + 1) / segments
                points = [pt(l0, a0), pt(l0, a1), pt(l1, a1), pt(l1, a0)]
                if i == rings - 1:
                    points = points[:3]
                normals = [nrm(l0, a0), nrm(l0, a1), nrm(l1, a1), nrm(l1, a0)][:len(points)]
                self.face(points, colour, nrm((l0 + l1) / 2, (a0 + a1) / 2), shine, normals=normals)

    def render(self):
        """The faces in a depth buffer: an RGBA image of the big canvas. Which way each pixel's face looks up is kept in
        self.up (the normal's z, NaN where nothing is), for the finish."""
        size = (W * SS, H * SS)
        depth = np.full((size[1], size[0]), -1e9, dtype=np.float64)
        colour = np.zeros((size[1], size[0], 4), dtype=np.uint8)
        self.up = np.full((size[1], size[0]), np.nan, dtype=np.float32)
        for points, rgb, up, smooth in self.faces:
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
            if smooth is None:
                colour[y0:y1 + 1, x0:x1 + 1][nearer] = rgb + (255,)
                self.up[y0:y1 + 1, x0:x1 + 1][nearer] = up
                continue
            # Shaded smooth: the normal is a plane over the screen too, fitted to the corners' normals.
            base, shine, normals = smooth
            nplane, *_ = np.linalg.lstsq(corners, np.array(normals, dtype=np.float64), rcond=None)
            px = np.stack([gx[nearer], gy[nearer], np.ones(int(nearer.sum()))], axis=-1)
            n = px @ nplane
            n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)
            f = 0.45 + 0.62 * np.maximum(0.0, n @ np.array(LIGHT))
            spec = shine * np.maximum(0.0, n @ np.array(HALF)) ** 24 * 255
            lit = np.clip(np.array(base, dtype=np.float64)[None, :] * f[:, None] + spec[:, None], 0, 255)
            colour[y0:y1 + 1, x0:x1 + 1][nearer] = np.concatenate(
                [lit.astype(np.uint8), np.full((len(lit), 1), 255, np.uint8)], axis=1)
            self.up[y0:y1 + 1, x0:x1 + 1][nearer] = n[:, 2]
        return Image.fromarray(colour, 'RGBA')


def shadow(centre, rx, ry, strength=110):
    """A soft shadow on the floor (big canvas)."""
    layer = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    cx, cy = centre
    pts = [project(cx + math.cos(a) * rx, cy + math.sin(a) * ry, 0) for a in [i * math.pi / 32 for i in range(64)]]
    ImageDraw.Draw(layer).polygon(pts, fill=(0, 0, 0, strength))
    return layer.filter(ImageFilter.GaussianBlur(5 * SS))


# Set while the items' icons are drawn: a tile's thing without its shadow on the floor (the shadow took the icon's room
# and read as a grey smear round it).
ICON_DRAW = {'on': False}


def compose(scene, ground=None, over=None, seed=1, glows=None):
    big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    if ground and not ICON_DRAW['on']:
        big.alpha_composite(ground)
    solid = scene.render()
    big.alpha_composite(solid)
    if over:
        over(big)
    small = big.convert('RGBa').resize((W, H), Image.LANCZOS).convert('RGBA')
    small = finish(small, solid.getchannel('A').resize((W, H), Image.LANCZOS), seed, facing_up(scene.up))
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


def facing_up(up):
    """How much each pixel of the tile looks up (the big canvas's normals averaged over the pixel; -1 where nothing is)."""
    filled = np.where(np.isnan(up), 0.0, up).reshape(H, SS, W, SS)
    count = (~np.isnan(up)).reshape(H, SS, W, SS).sum(axis=(1, 3))
    return np.where(count > 0, filled.sum(axis=(1, 3)) / np.maximum(count, 1), -1.0)


def smooth_noise(rnd, sigma_x, sigma_y):
    """A field of noise, -1 to 1, blurred sigma_x across and sigma_y down (pixels)."""
    field = Image.fromarray((rnd.rand(H, W) * 255).astype(np.uint8), 'L')
    field = np.asarray(field.resize((max(1, int(W / sigma_x)), max(1, int(H / sigma_y))), Image.BILINEAR)
                       .resize((W, H), Image.BICUBIC)).astype(np.float64)
    field -= field.mean()
    return field / max(1e-6, np.abs(field).max())


def finish(image, solid, seed, up=None):
    """The game's tiles are painted, not rendered: broad blotches of wear rather than a grain, streaks of grime running
    down their sides and gathering toward the floor, a darker rim where a thing meets the air, and a light edge where a
    top meets a side."""
    a = np.asarray(image).astype(np.float64)
    rgb, alpha = a[..., :3], a[..., 3]
    sp = np.asarray(solid).astype(np.float64)
    inner = np.asarray(solid.filter(ImageFilter.MinFilter(3))).astype(np.float64)
    rnd = np.random.RandomState(seed)
    if up is None:
        up = np.where(sp > 40, 0.0, -1.0)
    n = 1 + (rnd.rand(H, W) - 0.5) * 0.02
    n *= 1 + 0.05 * smooth_noise(rnd, 6, 6)
    side = (up > -0.5) & (up < 0.5)
    streaks = np.maximum(0, smooth_noise(rnd, 1.5, 14))
    n *= np.where(side, 1 - 0.09 * streaks, 1)
    rows = np.arange(H)[:, None]
    n *= 1 - 0.1 * np.clip((rows - 150) / 80, 0, 1)
    n *= np.where(inner < 128, 0.72, 1)
    top = up > 0.8
    below = np.roll(side & (sp > 200), -1, axis=0)
    n *= np.where(top & below & (sp > 200), 1.2, 1)
    keep = (alpha > 0) & (sp >= 40)
    a[..., :3] = np.where(keep[..., None], np.clip(rgb * n[..., None], 0, 255), rgb)
    return Image.fromarray(a.astype(np.uint8), 'RGBA')


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
        premultiplied += (halo * c * 0.4 + core * (0.55 + 0.45 * c)) * alpha
        haze = halo * 0.15
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
    """An impact sprinkler on the water lane's middle (RUN_LANE), on the pipe's end laid to it: the riser's fitting on
    the ground over the pipe's cap, so that the pipe runs into it, the riser, the brass head, its nozzle looking up and
    out and the arm that knocks it round. Spraying, drops leave the nozzle in arcs; each frame has the
    head turned on by an eighth."""
    angle = 2 * math.pi * frame / SPRAY_FRAMES
    ca, sa = math.cos(angle), math.sin(angle)

    def head(dx, dy, z):
        """A point of the head, dx out along the nozzle and dy across it from the riser."""
        return (c + dx * ca - dy * sa, c + dx * sa + dy * ca, z)

    c = 0.5 + RUN_LANE['water']
    s = Scene()
    # (A thin riser and a small head read as a lamp post: the riser is a stout galvanized pipe in a coupling, the head
    # a cast brass body the size of a fist.)
    s.tube((c, c, 0.0), (c, c, 0.035), 0.11, FITTING, cap=(74, 75, 76), shine=0.1)
    s.tube((c, c, 0.035), (c, c, 0.09), 0.05, FITTING, cap=(74, 75, 76), shine=0.1)
    s.tube((c, c, 0.09), (c, c, 0.36), 0.032, STEEL, shine=0.4)
    s.tube((c, c, 0.33), (c, c, 0.37), 0.04, FITTING, shine=0.2)
    # The head.
    s.tube((c, c, 0.37), (c, c, 0.43), 0.06, BRASS, shine=0.5)
    s.tube((c, c, 0.43), (c, c, 0.46), 0.045, BRASS_DARK, shine=0.5)
    s.tube((c, c, 0.46), (c, c, 0.53), 0.04, BRASS, shine=0.5)
    nozzle = head(0.2, 0, 0.58)
    s.tube((c, c, 0.5), nozzle, 0.024, BRASS, cap=BRASS_DARK, shine=0.5)
    # The arm with its spring and the deflector at its end.
    s.tube((c, c, 0.6), (c, c, 0.53), 0.012, STEEL)
    s.tube(head(-0.14, 0, 0.6), head(0.19, 0, 0.62), 0.014, (150, 150, 154), shine=0.4)
    s.tube(head(0.17, 0, 0.605), head(0.22, 0, 0.605), 0.038, (150, 150, 154), shine=0.4)
    s.tube(head(-0.14, 0, 0.6), head(-0.14, 0, 0.55), 0.024, (150, 150, 154), shine=0.4)
    over = None
    if spraying:
        def over(big):
            layer = Image.new('RGBA', big.size, (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            rnd = random.Random(7)
            # The jets fan out along the nozzle and thin out in the air: the sprite keeps inside its tile. Under them a
            # mist, soft and wider, so the spray reads as water and not as a few white dots.
            mist = Image.new('RGBA', big.size, (0, 0, 0, 0))
            m = ImageDraw.Draw(mist)
            for jet in range(9):
                direction = angle + (jet - 4) * 0.13
                reach = 0.42 + rnd.random() * 0.1
                for i in range(1, 22):
                    t = (i + rnd.random() * 0.5) / 21
                    x = nozzle[0] + t * reach * math.cos(direction)
                    y = nozzle[1] + t * reach * math.sin(direction)
                    z = nozzle[2] + t * 0.4 - t * t * 0.45
                    px, py = project(x, y, z)
                    r = (2.4 - 1.0 * t) * SS * (0.7 + rnd.random() * 0.6)
                    fade = max(0.0, 1 - t) ** 1.2
                    d.ellipse([px - r, py - r, px + r, py + r], fill=(214, 236, 252, int(235 * fade)))
                    r *= 2.6
                    m.ellipse([px - r, py - r, px + r, py + r], fill=(200, 222, 236, int(60 * fade)))
            big.alpha_composite(mist.filter(ImageFilter.GaussianBlur(SS * 2)))
            big.alpha_composite(layer.filter(ImageFilter.GaussianBlur(SS * 0.3)))
    ground = shadow((c, c), 0.13, 0.13, 90)
    return compose(s, ground=ground, over=over, seed=20 + (1 + frame if spraying else 0))


# The filter's looks: its lamp dark (resting: the pipes purify, or another filter of its group works), green (working)
# or red (its media spent).
FILTER_LAMP = {'resting': None, 'working': 'green', 'spent': 'red'}


FILTER_TANK = (138, 128, 104)  # a fibreglass media tank, wound and almond
FILTER_TANK_DARK = (104, 96, 78)
FILTER_HEAD = (44, 46, 48)


def water_filter(turns, look='resting'):
    """A whole-house filter on a steel skid, the pipe running through it W to E: a tall fibreglass media tank with its
    control head on top (the status lamp on the head), the pipe into the head and out to a cartridge housing (a black
    head, a blue bowl under it, a gauge on top), a drain valve at the tank's foot. (Two thin white housings on posts
    over a wide pad read as a toy; a tank has the weight of what it does.)"""
    s = Scene(turns)
    glows = []
    s.box(0.2, 0.3, 0.0, 0.8, 0.7, 0.035, FRAME, top=(78, 80, 84), shine=0.2)
    for x0 in (0.22, 0.74):
        s.box(x0, 0.3, 0.0, x0 + 0.04, 0.7, 0.05, FRAME, shine=0.2)
    pipe_z = 0.62
    # The media tank: its foot ring, the wound body, the dome, the head straddling the pipe.
    tx, ty, tr = 0.38, 0.5, 0.13
    s.tube((tx, ty, 0.035), (tx, ty, 0.08), tr * 0.9, FILTER_TANK_DARK, shine=0.1)
    s.tube((tx, ty, 0.08), (tx, ty, 0.5), tr, FILTER_TANK, shine=0.15,
           bands=[(0, 0.05, FILTER_TANK_DARK), (0.05, 0.95, FILTER_TANK), (0.95, 1, FILTER_TANK_DARK)])
    s.dome((tx, ty, 0.5), tr, 0.07, FILTER_TANK, shine=0.15)
    s.box(tx - 0.075, ty - 0.07, 0.55, tx + 0.075, ty + 0.07, 0.69, FILTER_HEAD, top=(60, 62, 64), shine=0.25)
    s.box(tx - 0.05, ty + 0.07, 0.6, tx + 0.05, ty + 0.074, 0.66, (24, 40, 40))
    lamp(s, glows, tx, ty, 0.69, 0.022, FILTER_LAMP[look] or 'green', FILTER_LAMP[look] is not None)
    # The pipe: in at the west edge, through the head, over to the cartridge, out at the east edge.
    s.tube((0.15, 0.5, pipe_z), (0.85, 0.5, pipe_z), 0.032, PIPE, shine=0.3)
    for x in (0.15, 0.83):
        s.tube((x, 0.5, pipe_z), (x + 0.02, 0.5, pipe_z), 0.05, STEEL, shine=0.4)
    s.tube((0.53, 0.5, pipe_z), (0.55, 0.5, pipe_z), 0.045, STEEL, shine=0.4)
    # The cartridge housing: its head on the pipe, the blue bowl hanging under it, a gauge on top.
    cx_ = 0.66
    s.box(cx_ - 0.06, 0.44, pipe_z - 0.05, cx_ + 0.06, 0.56, pipe_z + 0.05, FILTER_HEAD, shine=0.25)
    s.tube((cx_, 0.5, pipe_z - 0.05), (cx_, 0.5, pipe_z - 0.08), 0.068, (40, 84, 140), shine=0.3)
    s.tube((cx_, 0.5, 0.2), (cx_, 0.5, pipe_z - 0.08), 0.06, BLUE, shine=0.3,
           bands=[(0, 0.08, (52, 74, 100)), (0.08, 1, BLUE)])
    s.tube((cx_, 0.5, pipe_z + 0.05), (cx_, 0.5, pipe_z + 0.09), 0.008, BRASS, shine=0.5)
    s.tube((cx_, 0.49, pipe_z + 0.12), (cx_, 0.53, pipe_z + 0.12), 0.036, STEEL, cap=(232, 232, 224), shine=0.4)
    # The drain valve at the tank's foot.
    s.tube((tx, ty + tr - 0.01, 0.12), (tx, ty + tr + 0.05, 0.12), 0.014, BRASS, shine=0.5)
    s.box(tx - 0.03, ty + tr + 0.035, 0.135, tx + 0.03, ty + tr + 0.05, 0.145, (170, 50, 40))
    ground = shadow(s.turn((0.5, 0.5, 0))[:2], 0.34, 0.24)
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
    s.dome((vx, vy, 0.5), 0.115, 0.088, VESSEL, shine=0.45)
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
HOUSING = (116, 122, 118)
HOUSING_DARK = (84, 89, 86)
DOOR = (124, 130, 126)
BOX_TOP = (150, 154, 148)  # the lid's top: the lightest face of the box, as the game's furniture has it
TRIM = (66, 69, 72)
PLINTH = (44, 46, 48)
MODULE = (196, 194, 186)
TOGGLE = (40, 40, 42)
HANDLE = (160, 52, 40)
DIAL = (220, 216, 200)
LABEL = (204, 200, 188)
HAZARD = (196, 160, 52)
BOX_LAMPS = {'off': (), 'on': ('green', 'amber'), 'tripped': ('red',), 'tripped_dim': ()}
CONDUIT = (88, 92, 98)
CONDUIT_DARK = (60, 62, 66)
# Where each tier's box stands on its square: x0, x1, back, front.
FOOT = {1: (0.3, 0.7, 0.38, 0.62), 2: (0.2, 0.8, 0.36, 0.64), 3: (0.2, 0.8, 0.36, 0.64), 4: (0.16, 0.84, 0.3, 0.7)}
# How high an outdoor box stands on its pedestal, and its lid against the rain.
STAND = 0.3
ROOF = 0.022


def warning(s, x, y, z, size):
    """The warning sign on a front at y: a yellow triangle in a black one, its base at height z."""
    s.poly([(x - size * 0.8, y + 0.004, z), (x + size * 0.8, y + 0.004, z), (x, y + 0.004, z + size * 1.1)],
           (40, 40, 40), (0, 1, 0))
    s.poly([(x - size * 0.64, y + 0.006, z + size * 0.1), (x + size * 0.64, y + 0.006, z + size * 0.1),
            (x, y + 0.006, z + size * 0.9)], HAZARD, (0, 1, 0))


def label(s, x0, x1, y, z0, z1, lines):
    """A label on a front at y, with lines of print."""
    s.box(x0, y, z0, x1, y + 0.004, z1, LABEL)
    step = (z1 - z0) / (len(lines) + 1)
    for i, share in enumerate(lines):
        lz = z0 + step * (i + 0.6)
        s.box(x0 + 0.015, y + 0.004, lz, x0 + 0.015 + (x1 - x0 - 0.03) * share, y + 0.006, lz + 0.005, (70, 70, 72))


def louvres(s, x0, x1, y, z, rows, out=0.01):
    for i in range(rows):
        lz = z + i * 0.045
        s.box(x0, min(y, y + out), lz, x1, max(y, y + out), lz + 0.02, HOUSING_DARK)


def side_louvres(s, x0, x1, y0, y1, z, rows):
    for xs, xo in ((x1, 0.01), (x0, -0.01)):
        for i in range(rows):
            lz = z + i * 0.03
            s.box(min(xs, xs + xo), y0, lz, max(xs, xs + xo), y1, lz + 0.012, HOUSING_DARK)


def hinges(s, x, y, zs):
    for hz in zs:
        s.tube((x, y + 0.004, hz), (x, y + 0.004, hz + 0.04), 0.008, TRIM, shine=0.5, segments=12)


def lever(s, x, y, z, look, length):
    """The main switch's lever on the box's east side at x: a plate, its boss, the red handle up (on), down (off) or
    fallen to the middle (tripped), a knob at its end."""
    a = math.radians(0 if look.startswith('tripped') else 60 if look == 'on' else -60)
    s.box(x, y - 0.05, z - 0.05, x + 0.012, y + 0.05, z + 0.05, TRIM, shine=0.3)
    s.tube((x + 0.012, y, z), (x + 0.045, y, z), 0.024, (58, 60, 62), shine=0.4, segments=24)
    end = (x + 0.05, y + length * math.cos(a), z + length * math.sin(a))
    s.tube((x + 0.05, y, z), end, 0.011, HANDLE, shine=0.35, segments=16)
    s.tube((end[0] - 0.016, end[1], end[2]), (end[0] + 0.022, end[1], end[2]), 0.019, HANDLE, shine=0.35,
           segments=20)


def feed(s, x, yb):
    """The supply's conduit out of the back, through a gland box, into the ground."""
    s.box(x - 0.05, yb - 0.035, 0.1, x + 0.05, yb, 0.18, HOUSING_DARK, shine=0.2)
    s.tube((x, yb - 0.018, 0.11), (x, yb - 0.018, -s.lift - 0.02), 0.022, PIPE, shine=0.4, segments=24)


def timer_dial(s, x, y, z, r):
    """A time switch's dial on a front at y: its bezel, the face with the day's pins round it (two hours each, the
    hours it runs pushed out, red), the knob, and the mark at the top that says the hour now."""
    s.tube((x, y, z), (x, y + 0.014, z), r * 1.14, TRIM, shine=0.4, segments=48)
    s.tube((x, y + 0.014, z), (x, y + 0.018, z), r, DIAL, segments=48)
    for i in range(12):
        a = math.pi / 2 - 2 * math.pi * i / 12
        px, pz = x + r * 0.8 * math.cos(a), z + r * 0.8 * math.sin(a)
        out = 4 <= i < 8
        s.box(px - 0.008, y + 0.018, pz - 0.008, px + 0.008, y + (0.032 if out else 0.022), pz + 0.008,
              (196, 56, 40) if out else (96, 96, 98), shine=0.3)
    s.tube((x, y + 0.018, z), (x, y + 0.034, z), r * 0.26, (40, 40, 42), cap=(60, 60, 62), shine=0.4, segments=24)
    s.poly([(x - 0.012, y + 0.016, z + r * 1.14 + 0.002), (x + 0.012, y + 0.016, z + r * 1.14 + 0.002),
            (x, y + 0.016, z + r * 0.98)], (200, 50, 40), (0, 1, 0))


def plain_box(s, glows, look, roof):
    """Tier 1: a plain box; its door with a label and the warning sign, the main switch's lever on its side, one lamp on
    its top (green with power, red when tripped)."""
    x0, x1, yb, yf = FOOT[1]
    zt = 0.66
    s.box(x0, yb, 0.04, x1, yf, zt, HOUSING, shine=0.15)
    s.box(x0 - 0.006, yb - 0.006, zt, x1 + 0.006, yf + 0.006, zt + 0.012, HOUSING_DARK, top=BOX_TOP, shine=0.2)
    f = yf + 0.008
    s.box(x0 + 0.025, yf, 0.07, x1 - 0.025, f, zt - 0.025, DOOR, shine=0.2)
    label(s, 0.37, 0.63, f, 0.52, 0.6, (0.8, 0.55, 0.65))
    warning(s, 0.5, f, 0.39, 0.055)
    s.box(0.34, f, 0.26, 0.355, f + 0.025, 0.34, (52, 54, 56), shine=0.5)
    hinges(s, x1 - 0.035, f, (0.12, 0.54))
    louvres(s, 0.4, 0.6, f, 0.1, 3)
    lever(s, x1, 0.5, 0.4, look, 0.14)
    tripped = look.startswith('tripped')
    lamp(s, glows, 0.5, 0.5, zt + 0.012 + roof, 0.026, 'red' if tripped else 'green', look in ('on', 'tripped'))
    feed(s, 0.5, yb)
    return x0, x1, yb, yf, zt + 0.012


def breaker_box(s, glows, look, roof, timer=False):
    """Tier 2: a taller box, its breakers in a row behind a window in the door (one fallen to the middle when it
    tripped), the circuits' list over them, the main switch's lever on its side, a green and a red lamp on its top.
    Tier 3 (timer): the same with a time switch's dial on the door and an amber lamp between."""
    x0, x1, yb, yf = FOOT[3 if timer else 2]
    zt = 0.76
    s.box(x0, yb, 0.04, x1, yf, zt, HOUSING, shine=0.15)
    s.box(x0 - 0.006, yb - 0.006, zt, x1 + 0.006, yf + 0.006, zt + 0.012, HOUSING_DARK, top=BOX_TOP, shine=0.2)
    f = yf + 0.008
    s.box(x0 + 0.03, yf, 0.07, x1 - 0.03, f, zt - 0.03, DOOR, shine=0.2)
    tripped = look.startswith('tripped')
    s.box(0.27, f, 0.44, 0.67, f + 0.005, 0.625, (36, 38, 40))
    for i in range(4):
        bx = 0.283 + i * 0.0935
        s.box(bx, f + 0.005, 0.455, bx + 0.08, f + 0.022, 0.61, MODULE, shine=0.2)
        tz = 0.495 if tripped and i == 2 else 0.535
        s.box(bx + 0.025, f + 0.022, tz, bx + 0.055, f + 0.048, tz + 0.045, TOGGLE)
    label(s, 0.27, 0.55, f, 0.645, 0.7, (0.8, 0.55))
    warning(s, 0.63, f, 0.645, 0.045)
    s.box(0.23, f, 0.32, 0.252, f + 0.03, 0.44, (52, 54, 56), shine=0.5)
    hinges(s, x1 - 0.04, f, (0.12, 0.62))
    if timer:
        timer_dial(s, 0.37, f, 0.25, 0.1)
        louvres(s, 0.53, 0.72, f, 0.13, 3)
    else:
        louvres(s, 0.32, 0.68, f, 0.13, 3)
    lever(s, x1, 0.5, 0.46, look, 0.15)
    colours = ('green', 'amber', 'red') if timer else ('green', 'red')
    for i, colour in enumerate(colours):
        x = 0.5 + (i - (len(colours) - 1) / 2) * 0.12
        lamp(s, glows, x, 0.5, zt + 0.012 + roof, 0.026, colour, colour in BOX_LAMPS[look])
    feed(s, 0.5, yb)
    return x0, x1, yb, yf, zt + 0.012


def timer_box(s, glows, look, roof):
    return breaker_box(s, glows, look, roof, timer=True)


def console(s, glows, look, roof):
    """Tier 4: the console faces south (+y): the cabinet with its door (a row of breakers behind a window, the main
    breaker with its red handle, a label and a warning sign, louvres), a sloped desk (two rotary switches and a key
    switch), a meter bridge at the back (a round meter on its front, the three signal lamps on its top, where they are
    seen from every side); on the back a conduit into the floor and louvres, louvres on the sides too."""
    x0, x1, yb, yf = FOOT[4]
    zt, yd, zd, zb = 0.58, 0.5, 0.66, 0.8
    s.box(x0, yb, 0.04, x1, yf, zt, HOUSING, shine=0.15)
    # The desk slopes up from the front to the meter bridge.
    slope = unit((0, zd - zt, yf - yd))
    s.poly([(x0, yf, zt), (x1, yf, zt), (x1, yd, zd), (x0, yd, zd)], HOUSING, slope, shine=0.15)
    s.poly([(x1, yf, zt), (x1, yd, zt), (x1, yd, zd)], HOUSING, (1, 0, 0), shine=0.15)
    s.poly([(x0, yf, zt), (x0, yd, zt), (x0, yd, zd)], HOUSING, (-1, 0, 0), shine=0.15)
    s.box(x0, yb, zt, x1, yd, zb, HOUSING, shine=0.15)
    s.box(x0 - 0.008, yb - 0.008, zb, x1 + 0.008, yd + 0.008, zb + 0.016, HOUSING_DARK, top=BOX_TOP, shine=0.2)
    s.box(x0 - 0.008, yf - 0.012, zt - 0.012, x1 + 0.008, yf + 0.006, zt + 0.004, TRIM, shine=0.3)

    # The door, a little proud of the front, and what is on it.
    f = yf + 0.008
    s.box(x0 + 0.03, yf, 0.07, x1 - 0.03, f, zt - 0.03, DOOR, shine=0.2)
    # The breakers behind their window: a dark recess, four modules with their toggles up.
    s.box(0.24, f, 0.32, 0.6, f + 0.005, 0.46, (36, 38, 40))
    for i in range(4):
        bx = 0.252 + i * 0.087
        s.box(bx, f + 0.005, 0.335, bx + 0.075, f + 0.022, 0.445, MODULE, shine=0.2)
        s.box(bx + 0.024, f + 0.022, 0.385, bx + 0.051, f + 0.046, 0.425, TOGGLE)
    # The main breaker: its body, and its handle up, or fallen to the middle when it tripped.
    s.box(0.645, f, 0.3, 0.775, f + 0.03, 0.48, (58, 60, 62), shine=0.25)
    s.box(0.665, f + 0.03, 0.315, 0.755, f + 0.034, 0.465, (30, 31, 33))
    hz = 0.37 if look.startswith('tripped') else 0.42
    s.box(0.685, f + 0.03, hz, 0.735, f + 0.075, hz + 0.035, HANDLE, shine=0.35)
    # A label over the breakers with lines of print, the warning sign beside it.
    label(s, 0.24, 0.5, f, 0.485, 0.53, (0.77, 0.58, 0.65))
    warning(s, 0.70, f, 0.49, 0.05)
    # The door's latch, louvres at its foot.
    s.box(0.2, f, 0.22, 0.215, f + 0.025, 0.3, (52, 54, 56), shine=0.5)
    louvres(s, 0.3, 0.7, f, 0.1, 4)

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
        lamp(s, glows, x, 0.4, zb + 0.016 + roof, 0.03, colour, colour in BOX_LAMPS[look])

    hinges(s, x1 - 0.035, f, (0.12, 0.47))
    # The back: a panel screwed on, louvres in it, a plate, and the supply's conduit into the floor through a gland box.
    s.box(x0 + 0.04, yb - 0.006, 0.08, x1 - 0.04, yb, zb - 0.06, DOOR, shine=0.2)
    for sx in (x0 + 0.06, x1 - 0.06):
        for sz in (0.1, zb - 0.08):
            s.tube((sx, yb - 0.006, sz), (sx, yb - 0.01, sz), 0.007, STEEL, shine=0.6, segments=10)
    louvres(s, 0.3, 0.7, yb - 0.006, 0.44, 4, out=-0.008)
    s.box(0.4, yb - 0.01, 0.32, 0.6, yb - 0.006, 0.38, LABEL)
    s.box(0.415, yb - 0.012, 0.35, 0.56, yb - 0.01, 0.356, (70, 70, 72))
    s.box(0.44, yb - 0.04, 0.12, 0.56, yb, 0.22, HOUSING_DARK, shine=0.2)
    s.tube((0.5, yb - 0.02, 0.13), (0.5, yb - 0.02, -s.lift - 0.02), 0.028, PIPE, shine=0.4, segments=24)
    side_louvres(s, x0, x1, 0.38, 0.62, 0.38, 3)
    # The trunk to the relays: a thick conduit out of the east side through a gland box, its couplings, down into the
    # floor at the square's edge.
    s.box(x1, 0.42, 0.14, x1 + 0.04, 0.58, 0.3, HOUSING_DARK, shine=0.2)
    tz, tx = 0.22, 0.925
    rings = [(0, 0.12, CONDUIT_DARK), (0.12, 0.88, CONDUIT), (0.88, 1, CONDUIT_DARK)]
    s.tube((x1 + 0.04, 0.5, tz), (tx + 0.038, 0.5, tz), 0.038, CONDUIT, shine=0.35, segments=28, bands=rings)
    s.tube((tx, 0.5, tz + 0.038), (tx, 0.5, -s.lift - 0.02), 0.038, CONDUIT, shine=0.35, segments=28,
           bands=[(0, 0.08, CONDUIT_DARK), (0.08, 1, CONDUIT)])
    return x0, x1, yb, yd, zb + 0.016


def pedestal(s, x0, x1, yb, yf):
    """What an outdoor box stands on: a concrete pad, four steel legs on their foot plates, a crossbar low on the long
    sides, the frame the box sits on."""
    s.box(max(0.04, x0 - 0.08), max(0.04, yb - 0.08), 0.0, min(0.96, x1 + 0.08), min(0.96, yf + 0.08), 0.06, CONCRETE)
    for lx in (x0 + 0.03, x1 - 0.065):
        for ly in (yb + 0.03, yf - 0.065):
            s.box(lx - 0.012, ly - 0.012, 0.06, lx + 0.047, ly + 0.047, 0.07, FRAME, shine=0.3)
            s.box(lx, ly, 0.07, lx + 0.035, ly + 0.035, STAND - 0.03, STEEL, shine=0.4)
    for ly in (yb + 0.035, yf - 0.06):
        s.box(x0 + 0.04, ly, 0.13, x1 - 0.04, ly + 0.025, 0.16, STEEL, shine=0.4)
    s.box(x0 + 0.015, yb + 0.015, STAND - 0.03, x1 - 0.015, yf - 0.015, STAND, FRAME, shine=0.3)


TIER_BODY = {1: plain_box, 2: breaker_box, 3: timer_box, 4: console}


def panel(turns, look, tier, outdoor):
    """A tier's box in a look, facing S (turns 0) and round; indoors on a plinth, outdoors on a pedestal under a lid."""
    s = Scene(turns)
    glows = []
    x0, x1, yb, yf = FOOT[tier]
    if outdoor:
        pedestal(s, x0, x1, yb, yf)
        s.lift = STAND
    else:
        s.box(x0 + 0.02, yb + 0.02, 0.0, x1 - 0.02, yf - 0.02, 0.04, PLINTH)
    roof = ROOF if outdoor else 0.0
    rx0, rx1, ry0, ry1, rz = TIER_BODY[tier](s, glows, look, roof)
    if outdoor:
        s.box(rx0 - 0.025, ry0 - 0.03, rz, rx1 + 0.025, ry1 + 0.035, rz + roof, HOUSING_DARK, top=BOX_TOP, shine=0.25)
    rx, ry = (x1 - x0) / 2 + 0.07, (yf - yb) / 2 + 0.07
    if turns % 2:
        rx, ry = ry, rx
    ground = shadow((0.5, 0.5), rx, ry, 120)
    seed = (40 + turns) if tier == 4 and not outdoor else 200 + tier * 10 + turns + (5 if outdoor else 0)
    return compose(s, ground=ground, seed=seed, glows=glows)


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
JUNCTION = {'CustomName': 'Junction Box', 'BlocksPlacement': '', 'solidtrans': ''}
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


BOX_LOOKS = ('off', 'on', 'tripped', 'tripped_dim')


def panels(tier, outdoor):
    """A tier's box, indoors or out: off, on, tripped and tripped with its lamp dark, each facing S, E, N, W."""
    return [(lambda t=t, look=look: panel(t, look, tier, outdoor), dict(BOX, Facing=f))
            for look in BOX_LOOKS for t, f in BOX_FACINGS]


def boosters(look):
    return [(lambda t=t, look=look: booster(t, look), dict(BOOSTER, Facing=f)) for t, f in BOX_FACINGS]


CABINET = (78, 102, 84)
CABINET_DARK = (56, 74, 62)
CABINET_DOOR = (86, 112, 92)
CABLE = (44, 44, 46)
HYDRANT_BODY = (52, 84, 128)
HYDRANT_DARK = (38, 62, 96)


def junction_box():
    """The power relay: a junction box standing on the ground, as the cables of a street run into one. A steel cabinet
    painted green on a concrete pad at the back of its square, its hood over the top against the rain; on its front the
    door with its handle, lock, hinges, the warning sign and a label; louvres on its side. The power lane's middle
    (RUN_LANE) is under it: a cable laid from the east or the south goes in at an opening in the pad's side,
    and the water lane passes in front of the pad, clear of it."""
    s = Scene()
    lane = 0.5 + RUN_LANE['power']
    s.box(0.17, 0.19, 0.0, 0.57, 0.53, 0.045, CONCRETE)
    x0, x1, yb, yf, zb, zt = 0.21, 0.53, 0.24, 0.47, 0.1, 0.68
    s.box(x0, yb, zb, x1, yf, zt, CABINET, shine=0.15)
    s.box(x0 + 0.02, yb + 0.02, 0.045, x1 - 0.02, yf - 0.02, zb, CABINET_DARK, shine=0.1)
    s.box(x0 - 0.018, yb - 0.018, zt, x1 + 0.018, yf + 0.018, zt + 0.02, CABINET_DARK, top=CABINET, shine=0.2)
    s.box(x0 - 0.008, yb - 0.008, zt + 0.02, x1 + 0.008, yf + 0.008, zt + 0.034, CABINET_DARK, shine=0.2)
    f = yf + 0.006
    mid = (x0 + x1) / 2
    s.box(x0 + 0.02, yf, zb + 0.025, x1 - 0.02, f, zt - 0.03, CABINET_DOOR, shine=0.2)
    hinges(s, x0 + 0.03, f, (zb + 0.08, zt - 0.12))
    s.box(x1 - 0.05, f, 0.34, x1 - 0.035, f + 0.018, 0.42, TRIM, shine=0.5)
    s.tube((x1 - 0.042, f, 0.45), (x1 - 0.042, f + 0.012, 0.45), 0.011, BRASS, shine=0.6, segments=16)
    warning(s, mid, f, 0.45, 0.05)
    label(s, mid - 0.09, mid + 0.08, f, 0.28, 0.36, (0.8, 0.55))
    side_louvres(s, x0, x1, yb + 0.05, yf - 0.05, 0.42, 4)
    # the cables' openings in the pad's east and south sides, at the power lane
    s.box(0.57, lane - 0.03, 0.004, 0.573, lane + 0.03, 0.04, (26, 26, 26))
    s.box(lane - 0.03, 0.53, 0.004, lane + 0.03, 0.533, 0.04, (26, 26, 26))
    return compose(s, ground=shadow((0.38, 0.4), 0.3, 0.2), seed=54)


def hydrant():
    """The water relay: a yard hydrant on the water lane's middle (RUN_LANE), so that a pipe laid to it runs into its
    collar. A concrete collar round its standpipe, the galvanized standpipe up to the cast head, its lever up over it
    with the link down, the spout turned down with its hose thread. (A valve box lid lying beside it read as a circuit
    board on the ground.)"""
    s = Scene()
    c = 0.5 + RUN_LANE['water']
    s.box(c - 0.13, c - 0.13, 0.0, c + 0.13, c + 0.13, 0.05, CONCRETE)
    s.tube((c, c, 0.05), (c, c, 0.54), 0.04, STEEL, shine=0.4, segments=24,
           bands=[(0, 0.04, PIPE), (0.04, 1, STEEL)])
    s.tube((c, c, 0.5), (c, c, 0.54), 0.05, HYDRANT_DARK, shine=0.3)
    s.box(c - 0.06, c - 0.06, 0.54, c + 0.06, c + 0.06, 0.68, HYDRANT_BODY, top=HYDRANT_DARK, shine=0.3)
    s.tube((c, c + 0.06, 0.62), (c, c + 0.14, 0.62), 0.026, HYDRANT_BODY, shine=0.3, segments=20)
    s.tube((c, c + 0.14, 0.646), (c, c + 0.14, 0.53), 0.026, HYDRANT_BODY, shine=0.3, segments=20,
           bands=[(0, 0.62, HYDRANT_BODY), (0.62, 1, BRASS)])
    s.box(c - 0.015, c - 0.035, 0.68, c + 0.015, c + 0.035, 0.72, HYDRANT_DARK)
    s.tube((c, c, 0.71), (c, c - 0.16, 0.9), 0.018, HYDRANT_BODY, shine=0.3, segments=14)
    s.tube((c, c - 0.16, 0.9), (c, c - 0.2, 0.95), 0.024, RUBBER, segments=14)
    s.tube((c, c - 0.09, 0.81), (c, c - 0.07, 0.62), 0.008, STEEL, shine=0.5, segments=8)
    return compose(s, ground=shadow((c, c + 0.05), 0.2, 0.16), seed=55)


PCB = (34, 102, 58)
PCB_TRACE = (60, 140, 80)
GOLD = (210, 172, 82)
CHIP = (30, 30, 32)


def control_board():
    """The control board, for its icon: a green board lying flat, gold fingers along its edge, two chips with their
    legs, a relay, capacitors and a few traces."""
    s = Scene()
    s.box(0.12, 0.28, 0.1, 0.88, 0.72, 0.125, PCB, shine=0.35)
    for i in range(11):
        x = 0.18 + i * 0.058
        s.box(x, 0.67, 0.125, x + 0.034, 0.715, 0.127, GOLD, shine=0.6)
    for x0, y0, x1, y1 in ((0.2, 0.36, 0.42, 0.52), (0.48, 0.34, 0.62, 0.46)):
        s.box(x0, y0, 0.125, x1, y1, 0.15, CHIP, shine=0.3)
        n = int((x1 - x0) / 0.03)
        for i in range(n):
            x = x0 + 0.01 + i * (x1 - x0 - 0.02) / max(1, n - 1)
            for y, d in ((y0, -0.012), (y1, 0.012)):
                s.box(x - 0.005, min(y, y + d), 0.125, x + 0.005, max(y, y + d), 0.132, STEEL, shine=0.5)
    s.box(0.66, 0.36, 0.125, 0.82, 0.5, 0.21, (224, 222, 210), shine=0.2)
    for x, y in ((0.3, 0.6), (0.4, 0.6)):
        s.tube((x, y, 0.125), (x, y, 0.2), 0.026, BLUE, cap=(160, 168, 176), shine=0.4, segments=20)
    for y in (0.56, 0.6, 0.64):
        s.box(0.48, y, 0.125, 0.84, y + 0.008, 0.127, PCB_TRACE)
    return compose(s, seed=7)


# The lines on the floor: a square's run, from its lane's middle out to each side it leaves by (N, E, S, W as the
# bits 1, 2, 4, 8), a little past the side so that the next square's piece meets it without a seam. Each utility has
# its lane, off the square's middle along the diagonal (on the screen, power above and water below), so that both run
# side by side in a square and every piece of a lane meets the others there. Both lie a little sunk (RUN_REST), at one
# height on every floor so that a line runs on unbroken where soil meets tiles: on soil and grass crumbled over here and
# there, the ground showing through a little, no gloss, no shadow cast, so they lie in it, not on it; in the game's dull
# colours: power a weathered rubber cable, water a black HDPE pipe with blue stripes. A turn
# is a bend (the cable and the pipe both bend); a branch is a splice box on the cable and a tee on the pipe; an end
# (under what it feeds) a cap. The straight runs have a second look each, mixed in along a line: the cable pinned by a
# ground staple, the pipe joined by a coupling. On a made floor (tiles, paving, boards) the same runs at the same height
# are clean, with a soft shadow, held down by cable clips and pipe straps screwed to the floor instead.
RUN_FIRST = 184
RUN_DETAIL_FIRST = 214  # the straight runs' second looks: power N-S, power E-W, water N-S, water E-W
RUN_LAID_FIRST = 218  # the runs on a made floor: power, then water (15 each), then their second looks (248-251)
RUN_SIDES = ((1, (0, -1)), (2, (1, 0)), (4, (0, 1)), (8, (-1, 0)))
RUN_LANE = {'power': -0.1, 'water': 0.1}
RUN_PAST = 0.025
RUN_RADIUS = {'power': 0.024, 'water': 0.034}
RUN_BEND = {'power': 0.13, 'water': 0.17}
RUN_REST = 0.4  # of the radius: how high the middle lies over the ground, on every floor (what is under it is not drawn)
RUN_SEEN = 0.94  # how much of the ground the line covers: a little shows through
CABLE_RUBBER = (62, 58, 52)
HDPE = (46, 48, 50)
HDPE_STRIPE = (60, 72, 84)
FITTING = (64, 65, 66)
SOIL_DUST = (128, 112, 90)
SOIL_CLOD = (96, 80, 60)


def run_paint(utility):
    if utility == 'power':
        return None
    # stripes along the pipe: on its top and on its sides
    return lambda n, c: HDPE_STRIPE if c == HDPE and (n[2] > 0.96 or abs(n[2]) < 0.12) else c


def run_finish(image, seed, laid=False):
    """Dust and wear: a grain, specks of soil on what lies there, a little of the colour gone; laid on a made floor, a
    finer grain alone and nothing of the floor through it."""
    a = np.asarray(image).astype(np.float64)
    rnd = np.random.RandomState(seed)
    rgb, alpha = a[..., :3], a[..., 3:4]
    grey = rgb.mean(axis=2, keepdims=True)
    rgb = rgb + (grey - rgb) * 0.18
    rgb = rgb * (1 + (rnd.rand(*rgb.shape[:2], 1) - 0.5) * (0.06 if laid else 0.12))
    if not laid:
        specks = (rnd.rand(*rgb.shape[:2], 1) < 0.08) & (alpha > 200)
        rgb = np.where(specks, rgb + (np.array(SOIL_DUST) - rgb) * 0.3, rgb)
    a[..., :3] = np.clip(rgb, 0, 255)
    if not laid:
        a[..., 3] = a[..., 3] * RUN_SEEN
    return Image.fromarray(a.astype(np.uint8), 'RGBA')


def floor_run(utility, sides, detail=False, laid=False):
    s = Scene()
    cx = cy = 0.5 + RUN_LANE[utility]
    r = RUN_RADIUS[utility]
    z = r * RUN_REST
    sunk = True
    colour = CABLE_RUBBER if utility == 'power' else HDPE
    shine = (0.05 if utility == 'power' else 0.12) if laid else (0.03 if utility == 'power' else 0.08)
    paint = run_paint(utility)
    seed = 300 + sides * 2 + (utility == 'water') + detail * 50 + laid * 100
    rnd = random.Random(seed)
    ground = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(ground)
    soil = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    crumbs = ImageDraw.Draw(soil)

    def lay(a, b, overlap=0.0):
        """A straight piece from a to b on the ground (x, y): the darker soil where it was pressed in along it, and
        crumbs of soil over it here and there; laid on a made floor, its shadow."""
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        ux, uy = dx / length, dy / length
        a = (a[0] - ux * overlap, a[1] - uy * overlap)
        b = (b[0] + ux * overlap, b[1] + uy * overlap)
        s.tube((a[0], a[1], z), (b[0], b[1], z), r, colour, shine=shine, segments=24, ends=False, paint=paint, sunk=sunk)
        if laid:
            for w, fill in ((r * 1.1, (0, 0, 0, 95)), (r * 2.0, (0, 0, 0, 30))):
                px, py = -uy * w, ux * w
                draw.polygon([project(a[0] + px, a[1] + py, 0), project(b[0] + px, b[1] + py, 0),
                              project(b[0] - px, b[1] - py, 0), project(a[0] - px, a[1] - py, 0)], fill=fill)
            return
        w = r * 1.4
        px, py = -uy * w, ux * w
        draw.polygon([project(a[0] + px, a[1] + py, 0), project(b[0] + px, b[1] + py, 0),
                      project(b[0] - px, b[1] - py, 0), project(a[0] - px, a[1] - py, 0)], fill=(20, 14, 8, 70))
        for _ in range(int(length / 0.05)):
            if rnd.random() < 0.45:
                continue
            t, across = rnd.random(), rnd.uniform(-1.1, 1.1) * r
            x, y = a[0] + (b[0] - a[0]) * t - uy * across, a[1] + (b[1] - a[1]) * t + ux * across
            sx, sy = project(x, y, max(0.0, math.sqrt(max(0.0, r * r - across * across)) + z))
            size = rnd.uniform(0.5, 1.3) * SS
            crumbs.ellipse([sx - size * 1.4, sy - size, sx + size * 1.4, sy + size],
                           fill=SOIL_CLOD + (rnd.randint(150, 220),))

    def edge(dx, dy):
        return (cx if dx == 0 else (1 + RUN_PAST if dx > 0 else -RUN_PAST),
                cy if dy == 0 else (1 + RUN_PAST if dy > 0 else -RUN_PAST))

    arms = [(dx, dy) for bit, (dx, dy) in RUN_SIDES if sides & bit]
    if len(arms) == 2 and arms[0][0] * arms[1][0] + arms[0][1] * arms[1][1] == 0:
        # a bend: straight in from each side, round the corner between
        (d1x, d1y), (d2x, d2y) = arms
        bend = RUN_BEND[utility]
        p1, p2 = (cx + d1x * bend, cy + d1y * bend), (cx + d2x * bend, cy + d2y * bend)
        lay(edge(d1x, d1y), p1)
        lay(edge(d2x, d2y), p2)
        ox, oy = cx + (d1x + d2x) * bend, cy + (d1y + d2y) * bend
        steps = 8
        points = [(ox - d2x * bend * math.cos(t) - d1x * bend * math.sin(t),
                   oy - d2y * bend * math.cos(t) - d1y * bend * math.sin(t))
                  for t in (math.pi / 2 * i / steps for i in range(steps + 1))]
        for a, b in zip(points, points[1:]):
            lay(a, b, overlap=r * 0.35)
    else:
        for dx, dy in arms:
            lay((cx, cy), edge(dx, dy), overlap=r * 0.5 if len(arms) > 1 else 0.0)
        if len(arms) != 2:
            if utility == 'power' and len(arms) > 2:
                # a splice box: a flat rubber block with a lid
                s.box(cx - 0.055, cy - 0.055, 0.0, cx + 0.055, cy + 0.055, 2.3 * r, (48, 48, 46), top=(56, 56, 54), shine=0.1)
                s.box(cx - 0.035, cy - 0.035, 2.3 * r, cx + 0.035, cy + 0.035, 2.5 * r, (40, 40, 40), shine=0.15)
            elif utility == 'power':
                s.tube((cx, cy, 0), (cx, cy, r * 1.6), r, colour, shine=shine, segments=24)
            else:
                # a tee or a cap: sleeves on its arms round a body
                for dx, dy in arms:
                    s.tube((cx, cy, z), (cx + dx * 0.075, cy + dy * 0.075, z), r * 1.22, FITTING, shine=0.1, segments=24,
                           bands=[(0, 0.75, FITTING), (0.75, 0.85, (48, 49, 50)), (0.85, 1, FITTING)], sunk=sunk)
                s.box(cx - r * 1.25, cy - r * 1.25, 0, cx + r * 1.25, cy + r * 1.25, z + r * 1.22, FITTING, shine=0.1)
    if detail and laid:
        # held down: a cable clip (a saddle over it, its two tabs screwed to the floor) or a pipe strap (a band round
        # it, the same tabs)
        (dx, dy) = arms[0]
        px, py = -dy, dx
        metal = utility == 'water'
        band = (138, 140, 138) if metal else (104, 104, 100)
        reach = r + 0.022
        if metal:
            s.tube((cx - dx * 0.01, cy - dy * 0.01, z), (cx + dx * 0.01, cy + dy * 0.01, z), r * 1.12, band, shine=0.4, segments=24)
        else:
            s.box(cx - abs(dx) * 0.013 - abs(px) * (r + 0.006), cy - abs(dy) * 0.013 - abs(py) * (r + 0.006), 0,
                  cx + abs(dx) * 0.013 + abs(px) * (r + 0.006), cy + abs(dy) * 0.013 + abs(py) * (r + 0.006), z + r + 0.005,
                  band, shine=0.15)
        for side in (-1, 1):
            tx, ty = cx + px * reach * side, cy + py * reach * side
            s.box(tx - abs(dx) * 0.013 - abs(px) * 0.012, ty - abs(dy) * 0.013 - abs(py) * 0.012, 0,
                  tx + abs(dx) * 0.013 + abs(px) * 0.012, ty + abs(dy) * 0.013 + abs(py) * 0.012, 0.005, band,
                  shine=0.3 if metal else 0.15)
            s.box(tx - 0.004, ty - 0.004, 0.005, tx + 0.004, ty + 0.004, 0.008, (70, 70, 68), shine=0.4)
    elif detail and utility == 'power':
        # a ground staple across the cable: two legs into the ground, a bar over it
        (dx, dy) = arms[0]
        px, py = -dy, dx
        w, h = r + 0.012, z + r + 0.008
        for side in (-1, 1):
            s.tube((cx + px * w * side, cy + py * w * side, 0), (cx + px * w * side, cy + py * w * side, h), 0.0055,
                   (118, 116, 110), shine=0.5, segments=10)
        s.tube((cx - px * w, cy - py * w, h), (cx + px * w, cy + py * w, h), 0.0055, (118, 116, 110), shine=0.5, segments=10)
    elif detail:
        # a coupling: a ribbed sleeve with its nuts
        (dx, dy) = arms[0]
        s.tube((cx - dx * 0.07, cy - dy * 0.07, z), (cx + dx * 0.07, cy + dy * 0.07, z), r * 1.28, FITTING, shine=0.1,
               segments=24, bands=[(0, 0.18, (50, 51, 52)), (0.18, 0.82, FITTING), (0.82, 1, (50, 51, 52))], sunk=True)
    ground = ground.filter(ImageFilter.GaussianBlur((1.0 if laid else 0.8) * SS))
    big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    big.alpha_composite(ground)
    big.alpha_composite(s.render())
    big.alpha_composite(soil.filter(ImageFilter.GaussianBlur(0.35 * SS)))
    small = big.convert('RGBa').resize((W, H), Image.LANCZOS).convert('RGBA')
    return trim_faint(run_finish(small, seed, laid))


def runs(utility, laid=False):
    return [(lambda sides=sides: floor_run(utility, sides, laid=laid), {}) for sides in range(1, 16)]


def run_details(laid=False):
    return [(lambda utility=utility, sides=sides: floor_run(utility, sides, True, laid), {})
            for utility in ('power', 'water') for sides in (5, 10)]


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
    # 32-47: the utility panel of tier 4 (the console) off, on, tripped and tripped with its lamp dark, each S, E, N, W.
    + panels(4, False)
    # 48-53: snow on a solar panel (flat, W, N), light then heavy; 54 the power relay's junction box, 55 the water
    # relay's yard hydrant.
    + snows(False) + snows(True) + [(junction_box, JUNCTION), (hydrant, HYDRANT)]
    # 56-71: the booster pump stopped, running, running with no water at its floor and frozen, each facing S, E, N, W.
    + boosters('stopped') + boosters('running') + boosters('dry') + boosters('frozen')
    # 72-119: the utility panel of tiers 1, 2 and 3 indoors, in its looks as the console's (16 each).
    + panels(1, False) + panels(2, False) + panels(3, False)
    # 120-183: the utility panel of tiers 1 to 4 outdoors, on its pedestal (16 each).
    + panels(1, True) + panels(2, True) + panels(3, True) + panels(4, True)
    # 184-198: the power cable laid on the floor, 199-213 the water pipe, for each set of sides it leaves a square by
    # (RUN_FIRST + sides - 1; no properties: never an object, drawn by the API's floor decals).
    + runs('power') + runs('water')
    # 214-217: the straight runs' second looks (RUN_DETAIL_FIRST): power N-S and E-W, water N-S and E-W.
    + run_details()
    # 218-251: the same on a made floor (RUN_LAID_FIRST): power, water, then their second looks.
    + runs('power', True) + runs('water', True) + run_details(True)
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
ICONS = {'BUWaterPump': 1, 'BUSprinkler': 4, 'BUWaterFilter': 6, 'BUBreakerBox': 72, 'BUBreakerBox2': 88,
         'BUBreakerBox3': 104, 'BUBreakerBox4': 32, 'BUBoosterPump': 56, 'BUJunctionBox': 54, 'BUYardHydrant': 55}
# Icons of items that are no tile.
DRAWN_ICONS = {'BUControlBoard': control_board}
ICON = 32


def item_icon(image):
    """A thing drawn without its shadow, at the icon's size: brighter and a little more contrasted, sharpened after the
    shrink (shrunk alone it read soft beside the game's painted icons), hard-edged (no faint fringe), in a dark
    outline."""
    crop = trim(image)[0]
    a = np.asarray(crop).astype(np.float64)
    rgb = a[..., :3] * 1.15
    a[..., :3] = np.clip((rgb - 118) * 1.12 + 118, 0, 255)
    crop = Image.fromarray(a.astype(np.uint8), 'RGBA')
    inner = ICON - 3
    scale = inner / max(crop.width, crop.height)
    small = crop.convert('RGBa').resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))),
                                        Image.LANCZOS).convert('RGBA')
    sharp = small.filter(ImageFilter.UnsharpMask(radius=1, percent=70, threshold=0))
    sharp.putalpha(Image.eval(small.getchannel('A'), lambda v: 0 if v < 70 else 255))
    out = Image.new('RGBA', (ICON, ICON), (0, 0, 0, 0))
    out.alpha_composite(sharp, ((ICON - sharp.width) // 2, (ICON - sharp.height) // 2))
    grown = out.getchannel('A').filter(ImageFilter.MaxFilter(3))
    ring = Image.new('RGBA', out.size, (22, 24, 22, 0))
    ring.putalpha(Image.eval(grown, lambda v: 230 if v > 20 else 0))
    ring.alpha_composite(out)
    return ring


def write_icons(images):
    ICON_DRAW['on'] = True
    try:
        for name, index in ICONS.items():
            item_icon(TILES[index][0]()).save(os.path.join(ROOT, 'textures', 'Item_%s.png' % name))
        for name, draw in DRAWN_ICONS.items():
            item_icon(draw()).save(os.path.join(ROOT, 'textures', 'Item_%s.png' % name))
    finally:
        ICON_DRAW['on'] = False


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
