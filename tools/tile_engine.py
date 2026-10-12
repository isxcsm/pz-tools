"""The drawing engine of tools/tile_art.py (taken from Building Utilities' tool and extended): solids in a tile's space,
projected the way the game draws a square, shaded by a light from above and the viewer's left, drawn four times larger
with a depth buffer and scaled down.

Units are a square's side; the game's 2x tiles show a square as a 128x64 diamond at the bottom of a 128x256 tile, and a
unit up as UP pixels (the game's 2:1 view looks down 30 degrees). The viewer sees the south (+y, screen left) and east
(+x, screen right) sides of things. A lit lamp keeps its colour whatever the light, and glows.

Additions to the original: boxes turned by any rotation (xbox), flat images stuck on a plane (decal: stencils,
screens, labels), cones, spheres and domes, rocks (flat-shaded lumps), and small image helpers.
"""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

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


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a, k):
    return (a[0] * k, a[1] * k, a[2] * k)


# The canvas the scene is drawn on. A single tile is 128x256 (W x H); a machine of several tiles is drawn once on a
# canvas that holds every tile's window: the anchor tile's window sits at x offset dx (so the tiles west of it fit).
CV = {'w': W, 'h': H, 'dx': 0}


def set_canvas(fw, fh):
    """The canvas of a footprint of fw x fh tiles (as it stands in the world, after the turns)."""
    CV['w'] = (fw + fh - 2) * 64 + 128
    CV['h'] = (fw + fh - 2) * 32 + 256
    CV['dx'] = (fh - 1) * 64


def reset_canvas():
    CV['w'], CV['h'], CV['dx'] = W, H, 0


def project(x, y, z):
    return ((64 + (x - y) * 64 + CV['dx']) * SS, (192 + (x + y) * 32 - z * UP) * SS)


def shade(colour, normal, shine):
    """Lit by the light (ambient, diffuse) and, for metal, a highlight."""
    diffuse = max(0.0, dot(normal, LIGHT))
    f = 0.45 + 0.62 * diffuse
    spec = shine * max(0.0, dot(normal, HALF)) ** 24 * 255
    return tuple(max(0, min(255, int(c * f + spec))) for c in colour[:3])


def light_factor(normal):
    return 0.45 + 0.62 * max(0.0, dot(normal, LIGHT))


ICE = (214, 228, 242)


def frosted(colour, normal, amount):
    k = amount * (0.35 + 0.65 * max(0.0, normal[2]))
    return tuple(c + (i - c) * k for c, i in zip(colour[:3], ICE))


def rotation(axis, degrees):
    """A 3x3 rotation matrix (as three rows) about an axis through the origin."""
    x, y, z = unit(axis)
    a = math.radians(degrees)
    c, s = math.cos(a), math.sin(a)
    t = 1 - c
    return ((t * x * x + c, t * x * y - s * z, t * x * z + s * y),
            (t * x * y + s * z, t * y * y + c, t * y * z - s * x),
            (t * x * z - s * y, t * y * z + s * x, t * z * z + c))


def apply(m, p):
    return (m[0][0] * p[0] + m[0][1] * p[1] + m[0][2] * p[2],
            m[1][0] * p[0] + m[1][1] * p[1] + m[1][2] * p[2],
            m[2][0] * p[0] + m[2][1] * p[1] + m[2][2] * p[2])


def matmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


IDENTITY = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


class Scene:
    """Faces of solids, drawn into a depth buffer; what is added is turned a number of quarter turns about the
    tile's middle. Frost whitens every face by so much (0 to 1); a face that emits keeps its colour unshaded."""
    def __init__(self, turns=0, frost=0.0, foot=(1, 1)):
        self.turns = turns
        self.frost = frost
        self.foot = foot   # the footprint (tiles along x, along y) the object is drawn for, facing south
        self.faces = []
        self.tilt = None   # (rotation matrix, centre): the whole scene leaned about a point (item icons)

    def turn(self, p, vector=False):
        if self.tilt:
            rot, centre = self.tilt
            p = apply(rot, p) if vector else add(centre, apply(rot, sub(p, centre)))
        x, y, z = p
        cw, ch = self.foot
        for _ in range(self.turns % 4):
            x, y = (-y, x) if vector else (ch - y, x)
            cw, ch = ch, cw
        return (x, y, z)

    def final_foot(self):
        """The footprint after the turns: (tiles along x, tiles along y) as it stands in the world."""
        cw, ch = self.foot
        if self.turns % 2:
            cw, ch = ch, cw
        return cw, ch

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
        self.faces.append(('poly', [self.turn(p) for p in points], rgb))

    def poly(self, points, colour, outward, shine=0.0, emit=False):
        """A flat polygon; its normal from its points, on the side of outward."""
        n = (0.0, 0.0, 0.0)
        for i, p in enumerate(points):
            q = points[(i + 1) % len(points)]
            n = (n[0] + (p[1] - q[1]) * (p[2] + q[2]), n[1] + (p[2] - q[2]) * (p[0] + q[0]),
                 n[2] + (p[0] - q[0]) * (p[1] + q[1]))
        if dot(n, n) < 1e-12:
            return
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

    def xbox(self, centre, size, rot, colour, top=None, shine=0.0, emit=False):
        """A box of size (sx, sy, sz) about centre, its axes the columns of the matrix rot: local +z is its
        top. A hinged lid, a tilted screen, a slanted plate."""
        hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
        c = {}
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    c[(sx, sy, sz)] = add(centre, apply(rot, (sx * hx, sy * hy, sz * hz)))
        faces = (
            ((-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1), (0, 0, 1), top or colour),
            ((-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), (0, 0, -1), colour),
            ((-1, 1, -1), (1, 1, -1), (1, 1, 1), (-1, 1, 1), (0, 1, 0), colour),
            ((-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1), (0, -1, 0), colour),
            ((1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1), (1, 0, 0), colour),
            ((-1, -1, -1), (-1, 1, -1), (-1, 1, 1), (-1, -1, 1), (-1, 0, 0), colour),
        )
        for a, b, cc, d, n, col in faces:
            self.face([c[a], c[b], c[cc], c[d]], col, unit(apply(rot, n)), shine, emit)

    def tube(self, a, b, r, colour, cap=None, shine=0.0, segments=40, bands=None, emit=False, r2=None, inward=False, caps=True):
        """A cylinder (a cone if r2 is given: radius r at a, r2 at b) from point a to point b; bands:
        [(from, to, colour)] along it, 0..1. inward: the wall seen from inside (an open vessel's far wall), no caps."""
        axis = tuple(q - p for p, q in zip(a, b))
        length = math.sqrt(dot(axis, axis))
        if length < 1e-9:
            return
        d = unit(axis)
        helper = (0, 0, 1) if abs(d[2]) < 0.9 else (1, 0, 0)
        u = unit(cross(d, helper))
        v = cross(d, u)
        rb = r if r2 is None else r2
        slope = (r - rb) / length

        def at(angle, t):
            rr = r + (rb - r) * t
            c, s = math.cos(angle) * rr, math.sin(angle) * rr
            return tuple(p + d_ * t * length + u_ * c + v_ * s for p, d_, u_, v_ in zip(a, d, u, v))
        for i in range(segments):
            a0, a1 = 2 * math.pi * i / segments, 2 * math.pi * (i + 1) / segments
            mid = (a0 + a1) / 2
            n = unit(tuple(u_ * math.cos(mid) + v_ * math.sin(mid) + d_ * slope for u_, v_, d_ in zip(u, v, d)))
            if inward:
                n = mul(n, -1)
            for t0, t1, c in bands or [(0, 1, colour)]:
                self.face([at(a0, t0), at(a1, t0), at(a1, t1), at(a0, t1)], c, n, shine, emit)
        ring = range(segments)
        if inward or not caps:
            return
        if rb > 1e-6:
            self.face([at(2 * math.pi * i / segments, 1) for i in ring], cap or colour, d, shine, emit)
        if r > 1e-6:
            self.face([at(2 * math.pi * i / segments, 0) for i in ring], cap or colour, tuple(-c for c in d), shine, emit)

    def sphere(self, centre, radii, colour, shine=0.0, rings=10, segments=20, z_from=-90, z_to=90, colours=None,
               emit=False):
        """An ellipsoid (or a cap of one, between two latitudes in degrees). colours: [colour] cycled round the
        segments, for a parachute's panels."""
        cx, cy, cz = centre
        rx, ry, rz = radii
        for i in range(rings):
            l0 = math.radians(z_from + (z_to - z_from) * i / rings)
            l1 = math.radians(z_from + (z_to - z_from) * (i + 1) / rings)
            for j in range(segments):
                a0, a1 = 2 * math.pi * j / segments, 2 * math.pi * (j + 1) / segments

                def pt(l, a):
                    return (cx + rx * math.cos(l) * math.cos(a), cy + ry * math.cos(l) * math.sin(a),
                            cz + rz * math.sin(l))
                pts = [pt(l0, a0), pt(l0, a1), pt(l1, a1), pt(l1, a0)]
                lm, am = (l0 + l1) / 2, (a0 + a1) / 2
                n = unit((math.cos(lm) * math.cos(am) / rx, math.cos(lm) * math.sin(am) / ry, math.sin(lm) / rz))
                col = colours[j % len(colours)] if colours else colour
                self.face(pts, col, n, shine, emit)

    def rock(self, centre, radius, seed, colour, squash=(1.0, 1.0, 0.7), detail=1, jitter=0.28, shine=0.05,
             colour2=None):
        """A rough lump: an icosphere pushed about, each face flat with a slightly different tone."""
        rnd = random.Random(seed)
        t = (1 + 5 ** 0.5) / 2
        verts = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
                 (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
        verts = [unit(v) for v in verts]
        tris = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
                (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
                (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        for _ in range(detail):
            cache = {}

            def mid(i, j):
                key = (min(i, j), max(i, j))
                if key not in cache:
                    verts.append(unit(tuple((p + q) / 2 for p, q in zip(verts[i], verts[j]))))
                    cache[key] = len(verts) - 1
                return cache[key]
            new = []
            for a, b, c in tris:
                ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
                new += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            tris = new
        radii = [1 + (rnd.random() - 0.5) * 2 * jitter for _ in verts]
        pts = [mul(v, r * radius) for v, r in zip(verts, radii)]
        pts = [(p[0] * squash[0], p[1] * squash[1], p[2] * squash[2]) for p in pts]
        pts = [add(centre, p) for p in pts]
        for a, b, c in tris:
            pa, pb, pc = pts[a], pts[b], pts[c]
            if (pa[2] + pb[2] + pc[2]) / 3 < centre[2] - radius * squash[2] * 0.55:
                continue  # the underside is never seen
            n = unit(cross(sub(pb, pa), sub(pc, pa)))
            mid_p = mul(add(add(pa, pb), pc), 1 / 3)
            if dot(n, sub(mid_p, centre)) < 0:
                n = mul(n, -1)
            tone = 0.82 + rnd.random() * 0.3
            base = colour2 if (colour2 and rnd.random() < 0.18) else colour
            col = tuple(max(0, min(255, int(ch * tone))) for ch in base)
            self.face([pa, pb, pc], col, n, shine)

    def decal(self, origin, u, v, image, outward, offset=0.004, emit=False):
        """An RGBA image stuck on a plane: its left-top corner at origin, its width along vector u, its height
        along vector v (so v points down the image), over the side of the plane that outward points to."""
        n = unit(cross(u, v))
        if dot(n, outward) < 0:
            n = mul(n, -1)
        nt = self.turn(n, True)
        if dot(nt, VIEW) <= 1e-6:
            return
        o = add(origin, mul(n, max(offset, 0.0015)))
        pts = [o, add(o, u), add(add(o, u), v), add(o, v)]
        arr = np.asarray(image.convert('RGBA'))
        factor = 1.0 if emit else light_factor(nt)
        self.faces.append(('tex', [self.turn(p) for p in pts], arr, factor))

    def render(self):
        """The faces in a depth buffer: an RGBA image of the big canvas."""
        return self.render_full()[0]

    def render_full(self):
        """The faces in a depth buffer: the RGBA image of the canvas and, for every pixel it drew, the world x and y
        of the point it shows (to tell which tile of a machine the pixel belongs to); nan where nothing is drawn."""
        size = (CV['w'] * SS, CV['h'] * SS)
        depth = np.full((size[1], size[0]), -1e9, dtype=np.float64)
        colour = np.zeros((size[1], size[0], 4), dtype=np.uint8)
        wx = np.full((size[1], size[0]), np.nan, dtype=np.float32)
        wy = np.full((size[1], size[0]), np.nan, dtype=np.float32)
        for entry in self.faces:
            kind, points = entry[0], entry[1]
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
            # The face's depth, and the world x and y of its points, are planes over the screen: fitted to its
            # corners, kept within them.
            corners = np.array([[sx, sy, 1.0] for sx, sy in screen])
            values = np.array([[dot(p, VIEW), p[0], p[1]] for p in points])
            plane, *_ = np.linalg.lstsq(corners, values, rcond=None)
            gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
            fit = np.stack([gx, gy, np.ones_like(gx)], axis=-1) @ plane
            d = np.clip(fit[..., 0], values[:, 0].min(), values[:, 0].max())
            region = depth[y0:y1 + 1, x0:x1 + 1]
            nearer = m & (d > region)
            owner_x = np.clip(fit[..., 1], values[:, 1].min(), values[:, 1].max())
            owner_y = np.clip(fit[..., 2], values[:, 2].min(), values[:, 2].max())
            if kind == 'poly':
                region[nearer] = d[nearer]
                colour[y0:y1 + 1, x0:x1 + 1][nearer] = entry[2] + (255,)
                wx[y0:y1 + 1, x0:x1 + 1][nearer] = owner_x[nearer]
                wy[y0:y1 + 1, x0:x1 + 1][nearer] = owner_y[nearer]
                continue
            # A decal: each screen pixel is mapped back to the image by the plane's affine projection.
            arr, factor = entry[2], entry[3]
            (sx0, sy0), (sx1, sy1), _, (sx3, sy3) = screen
            a = np.array([[sx1 - sx0, sx3 - sx0], [sy1 - sy0, sy3 - sy0]])
            if abs(np.linalg.det(a)) < 1e-6:
                continue
            inv = np.linalg.inv(a)
            rx, ry = gx - sx0 + 0.5, gy - sy0 + 0.5
            fu = inv[0][0] * rx + inv[0][1] * ry
            fv = inv[1][0] * rx + inv[1][1] * ry
            inside = nearer & (fu >= 0) & (fu < 1) & (fv >= 0) & (fv < 1)
            if not inside.any():
                continue
            ih, iw = arr.shape[0], arr.shape[1]
            iu = np.clip((fu * iw).astype(int), 0, iw - 1)
            iv = np.clip((fv * ih).astype(int), 0, ih - 1)
            texel = arr[iv, iu].astype(np.float64)
            alpha = texel[..., 3] / 255.0
            lit = np.clip(texel[..., :3] * factor, 0, 255)
            target = colour[y0:y1 + 1, x0:x1 + 1]
            t_alpha = target[..., 3].astype(np.float64) / 255.0
            out_a = alpha + t_alpha * (1 - alpha)
            out_rgb = (lit * alpha[..., None] + target[..., :3].astype(np.float64) * (t_alpha * (1 - alpha))[..., None]) \
                / np.maximum(out_a, 1e-9)[..., None]
            write = inside & (alpha > 0.03)
            target[write, :3] = np.clip(out_rgb[write], 0, 255).astype(np.uint8)
            target[write, 3] = np.clip(out_a[write] * 255, 0, 255).astype(np.uint8)
            solid_write = write & (alpha > 0.5)
            region[solid_write] = d[solid_write]
            wx[y0:y1 + 1, x0:x1 + 1][solid_write] = owner_x[solid_write]
            wy[y0:y1 + 1, x0:x1 + 1][solid_write] = owner_y[solid_write]
        return Image.fromarray(colour, 'RGBA'), wx, wy


def shadow(centre, rx, ry, strength=110):
    """A soft shadow on the floor, in the object's own (south-facing) footprint: it turns with the object. It is
    drawn when the scene is composed (the canvas is known then)."""
    def draw(scene):
        layer = Image.new('RGBA', (CV['w'] * SS, CV['h'] * SS), (0, 0, 0, 0))
        cx, cy, _ = scene.turn((centre[0], centre[1], 0))
        ax, ay = (ry, rx) if scene.turns % 2 else (rx, ry)
        pts = [project(cx + math.cos(a) * ax, cy + math.sin(a) * ay, 0) for a in [i * math.pi / 32 for i in range(64)]]
        ImageDraw.Draw(layer).polygon(pts, fill=(0, 0, 0, strength))
        return layer.filter(ImageFilter.GaussianBlur(5 * SS))
    return draw


OWNERS = {}   # owner maps kept by compose(owner_key=...), so looks of one object split the same way


def compose(scene, ground=None, over=None, seed=1, glows=None, owner_key=None):
    """The finished picture: a 128x256 image for a one-tile object, or {(i, j): image} for each tile of a bigger
    one (i along x, j along y of the footprint as it stands in the world). The picture is drawn whole and every
    finished pixel goes to the one tile its point stands on, so the tiles meet without a seam."""
    fw, fh = scene.final_foot()
    set_canvas(fw, fh)
    try:
        cw, ch = CV['w'], CV['h']
        big = Image.new('RGBA', (cw * SS, ch * SS), (0, 0, 0, 0))
        if ground:
            big.alpha_composite(ground(scene) if callable(ground) else ground)
        solid, wx, wy = scene.render_full()
        big.alpha_composite(solid)
        if over:
            over(big)
        small = big.convert('RGBa').resize((cw, ch), Image.LANCZOS).convert('RGBA')
        small = finish(small, solid.getchannel('A').resize((cw, ch), Image.LANCZOS), seed)
        if glows:
            small = glow(small, scene, glows)
        if (fw, fh) == (1, 1):
            return small
        # which tile does each finished pixel belong to: the mean of the points its subpixels show, else the ground
        # point under it
        known = ~np.isnan(wx)
        count = known.reshape(ch, SS, cw, SS).sum(axis=(1, 3))
        sx = np.where(known, wx, 0).reshape(ch, SS, cw, SS).sum(axis=(1, 3))
        sy = np.where(known, wy, 0).reshape(ch, SS, cw, SS).sum(axis=(1, 3))
        gy, gx = np.mgrid[0:ch, 0:cw]
        u = (gx + 0.5 - 64 - CV['dx']) / 64.0           # x - y of the ground point
        v = (gy + 0.5 - 192) / 32.0                      # x + y
        ground_x, ground_y = (u + v) / 2, (v - u) / 2
        owner_x = np.where(count > 0, sx / np.maximum(count, 1), ground_x)
        owner_y = np.where(count > 0, sy / np.maximum(count, 1), ground_y)
        owner_x = np.clip(np.floor(owner_x), 0, fw - 1).astype(int)
        owner_y = np.clip(np.floor(owner_y), 0, fh - 1).astype(int)
        # a pixel that falls outside its tile's window (a flame, steam or glow high above the machine) goes to the tile
        # whose window holds it and whose column is nearest
        best = np.full((ch, cw), 1e18)
        near_x = np.zeros((ch, cw), dtype=int)
        near_y = np.zeros((ch, cw), dtype=int)
        inside_own = np.zeros((ch, cw), dtype=bool)
        for j in range(fh):
            for i in range(fw):
                x0, y0 = CV['dx'] + (i - j) * 64, (i + j) * 32
                holds = (gx >= x0) & (gx < x0 + W) & (gy >= y0) & (gy < y0 + H)
                cost = np.where(holds, np.abs(gx + 0.5 - (x0 + 64)) + 0.01 * (i + j), 1e18)
                better = cost < best
                best = np.where(better, cost, best)
                near_x = np.where(better, i, near_x)
                near_y = np.where(better, j, near_y)
                inside_own |= holds & (owner_x == i) & (owner_y == j)
        owner_x = np.where(inside_own, owner_x, near_x)
        owner_y = np.where(inside_own, owner_y, near_y)
        if owner_key:
            # the looks of one object (a tank at several water levels) must give the same tile to every pixel, or the
            # overlay of one over another does not come out equal: the first look's map is the map
            if owner_key not in OWNERS:
                OWNERS[owner_key] = (owner_x, owner_y)
            owner_x, owner_y = OWNERS[owner_key]
        arr = np.asarray(small)
        tiles = {}
        for j in range(fh):
            for i in range(fw):
                x0, y0 = CV['dx'] + (i - j) * 64, (i + j) * 32
                window = arr[y0:y0 + H, x0:x0 + W].copy()
                mine = (owner_x[y0:y0 + H, x0:x0 + W] == i) & (owner_y[y0:y0 + H, x0:x0 + W] == j)
                window[~mine] = 0
                tiles[(i, j)] = Image.fromarray(window, 'RGBA')
        return tiles
    finally:
        reset_canvas()


# How far the finish greys the colours toward their own lightness: the game's tiles are muted, and a clean saturated
# colour stands out among them (lit lamps are drawn after, and keep theirs).
GREY = 0.15


def finish(image, solid, seed):
    """A worn finish, as the game's tiles have: the colours a little greyed, a grain, blotches of wear a few pixels
    across, grime gathering toward the floor, and a darker rim where a thing meets the air."""
    rnd = random.Random(seed)
    px = image.load()
    inner = solid.filter(ImageFilter.MinFilter(3)).load()
    sp = solid.load()
    floor = image.height - 106
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = px[x, y]
            if a == 0 or sp[x, y] < 40:
                continue
            grey = r * 0.3 + g * 0.59 + b * 0.11
            r, g, b = r + (grey - r) * GREY, g + (grey - g) * GREY, b + (grey - b) * GREY
            n = 1 + (rnd.random() - 0.5) * 0.09
            n *= 1 + 0.045 * math.sin(x * 0.41 + y * 0.17 + seed) * math.sin(y * 0.37 - x * 0.23 + seed * 1.7)
            n *= 1 - 0.1 * min(1, max(0, (y - floor) / 80))
            if inner[x, y] < 128:
                n *= 0.7
            px[x, y] = (min(255, int(r * n)), min(255, int(g * n)), min(255, int(b * n)), a)
    return image


def glow(image, scene, glows):
    """Lit lamps on the finished tile: each a white-hot core and a halo of its colour that brightens what is around
    it, and faintly the air. glows: [(point, colour, radius in units[, the normal of the face it is on])]."""
    a = np.asarray(image).astype(np.float64) / 255
    alpha = a[..., 3:4]
    premultiplied = a[..., :3] * alpha
    gy, gx = np.mgrid[0:image.height, 0:image.width]
    air = np.zeros((image.height, image.width, 1))
    air_colour = np.zeros((image.height, image.width, 3))
    for entry in glows:
        point, colour, radius = entry[:3]
        if len(entry) > 3 and dot(scene.turn(entry[3], True), VIEW) <= 0.05:
            continue  # a lamp on a face turned away from the viewer
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
    tint = np.clip(air_colour / np.maximum(air, 1e-9), 0, 1)
    air = np.minimum(air, 0.6) * (1 - alpha)
    premultiplied += tint * air
    alpha = alpha + air
    rgb = np.where(alpha > 0, premultiplied / np.maximum(alpha, 1e-9), 0)
    out = np.concatenate([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)], axis=2)
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), 'RGBA')


# ----------------------------------------------------------------------------------------------------------------
# Images for decals: stencil lettering, the team's acorn mark.

FONT_DIR = 'C:/Windows/Fonts/'


def font(name, size):
    for candidate in (FONT_DIR + name, FONT_DIR + 'arialbd.ttf', 'arial.ttf'):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def stencil_text(text, width, height, colour=(224, 220, 196), face='impact.ttf'):
    """Text in a stencil: the letters fitted into width x height pixels, with the little bridges a stencil has."""
    scale = 4
    img = Image.new('RGBA', (width * scale, height * scale), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    size = height * scale
    f = font(face, size)
    while size > 6:
        box = d.textbbox((0, 0), text, font=f)
        if box[2] - box[0] <= width * scale * 0.96 and box[3] - box[1] <= height * scale * 0.96:
            break
        size -= 2
        f = font(face, size)
    box = d.textbbox((0, 0), text, font=f)
    x = (width * scale - (box[2] - box[0])) / 2 - box[0]
    y = (height * scale - (box[3] - box[1])) / 2 - box[1]
    d.text((x, y), text, font=f, fill=colour + (255,))
    a = np.asarray(img).copy()
    yy = int(a.shape[0] * 0.42)
    gap = max(2, scale)
    cols = (np.arange(a.shape[1]) % (size // 2 + 7)) < 4
    a[yy:yy + gap, cols, 3] = 0
    return Image.fromarray(a, 'RGBA').resize((width, height), Image.LANCZOS)


def acorn_mark(size, colour=(224, 220, 196), scale=4):
    """The team's mark: an acorn, its cap hatched, in one colour (the bridges are cut out so it stencils)."""
    s = size * scale
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = colour + (255,)
    cut = (0, 0, 0, 0)
    cx = s / 2
    d.ellipse([cx - s * 0.30, s * 0.40, cx + s * 0.30, s * 0.90], fill=c)
    d.polygon([(cx - s * 0.30, s * 0.62), (cx, s * 0.99), (cx + s * 0.30, s * 0.62)], fill=c)
    d.pieslice([cx - s * 0.40, s * 0.12, cx + s * 0.40, s * 0.74], 180, 360, fill=c)
    d.rectangle([cx - s * 0.40, s * 0.42, cx + s * 0.40, s * 0.47], fill=c)
    d.rectangle([cx - s * 0.04, s * 0.02, cx + s * 0.04, s * 0.16], fill=c)
    for i in range(-3, 4):
        d.line([(cx + i * s * 0.1, s * 0.18), (cx + i * s * 0.1 - s * 0.03, s * 0.40)], fill=cut, width=max(1, scale // 2))
    d.line([(cx - s * 0.42, s * 0.52), (cx + s * 0.42, s * 0.52)], fill=cut, width=scale)
    return img.resize((size, size), Image.LANCZOS)
