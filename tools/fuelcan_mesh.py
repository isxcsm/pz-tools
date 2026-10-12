#!/usr/bin/env python3
"""Builds the Operation Acorn fuel cans ('연구팀 연료통 Mk.I/II/III'): meshes, textures and the files the game needs.

    py tools/fuelcan_mesh.py            build everything, render tools/fuelcan_preview.png and the icon sources
    py tools/fuelcan_mesh.py --check    re-parse every produced file and assert it is consistent (no building)

What it writes per mark n (all under OperationAcorn/42/media):
    models_X/OA_FuelCanMk<n>.x                                    the static model (the item's StaticModel)
    models_X/Skinned/BackPacks/OA_FuelCanMk<n>_RHand.x, _LHand.x  carried in a hand (rigid on Bip01_Prop1 / Prop2)
    models_X/WorldItems/OA_FuelCanMk<n>_Ground.fbx                 the floor model
    textures/OA_FuelCan/OA_FuelCanMk<n>.png                        512x512 atlas
    clothing/clothingItems/OA_Bag_FuelCanMk<n>_RHand.xml, _LHand.xml (registered in fileGuidTable.xml)
and scripts/OA_fuelcan_models.txt (the static and floor models), tools/fuelcan_icon_source_mk<n>.png (tools/icon_art.py
makes the item icons from them) and the preview sheet tools/fuelcan_preview.png.

The can is a jerry can of our own: a flat steel body with rounded edges, the X pressed into both broad sides, the welded
seam around its edge, three handles on top and the spout with its cam-lever cap at one corner. The marks differ in size
(15, 20, 25 L), paint (olive drab, sand, grey) and the yellow bands on the ends (one per mark).

What comes from the game install (structure only, as in tools/backpack_mesh.py, whose helpers this uses):
  * the vanilla petrol can GasCan.x: the templates and the material block around our mesh frame, and where the hand holds
    it. The prop bone's frame is the static model's (Bip01_Prop1 at its origin, the same axes), and in the bag-holding
    animations its z axis is the world's up: the can stands on z, the middle handle's bar where the vanilla handle's is.
  * GasCan_RHand.x / GasCan_LHand.x: skeleton frames, templates, animation set and the prop bone offset matrices around
    our mesh frame. Our carried meshes are the static mesh under the rigid transforms those files apply to the vanilla
    static mesh (fitted from the two, exact to 1e-6).
  * WorldItems/Clothing/GasCan.fbx: the floor model keeps its node layout and unit settings (we replace the geometry).

Model space: x across the can (its thickness), y along the handles (the spout toward +y), z up.
"""
import argparse
import math
import os
import re
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backpack_mesh as B  # noqa: E402
from backpack_mesh import Part, Mesh, Chart, unit, smoothstep, catmull, need, Fail  # noqa: E402
import tile_engine as E  # noqa: E402

ATLAS = 512
B.ATLAS = ATLAS          # the shared chart, painter and shading helpers read the atlas size from their module
DENSITY = 900.0          # texture pixels per model unit (about 5 px per real centimetre)

HERE, ROOT, MEDIA = B.HERE, B.ROOT, B.MEDIA
PZ_MEDIA = os.path.join(B.PZ_DIR, 'media')
VANILLA_STATIC = os.path.join(PZ_MEDIA, 'models_X', 'GasCan.x')
VANILLA_GROUND = os.path.join(PZ_MEDIA, 'models_X', 'WorldItems', 'Clothing', 'GasCan.fbx')
HANDS = {'R': dict(src='GasCan_RHand.x', bone='Bip01_Prop1'), 'L': dict(src='GasCan_LHand.x', bone='Bip01_Prop2')}
PREVIEW = os.path.join(HERE, 'fuelcan_preview.png')
SCRIPT = os.path.join(MEDIA, 'scripts', 'OA_fuelcan_models.txt')
GUID_TABLE = os.path.join(MEDIA, 'fileGuidTable.xml')
CLOTHING_DIR = os.path.join(MEDIA, 'clothing', 'clothingItems')
MAT = 'OA_FuelCan_Mat'

# litres: the item's capacity (scripts/OA_gear.txt); L, H, T: the body's length (along the handles), height and thickness
MARKS = {
    1: dict(litres=15, L=0.150, H=0.200, T=0.074, paint=(100, 110, 74), cap=(58, 64, 44), ink=(226, 220, 192),
            guids=('5d189b2f-5fda-4341-ab49-cbb740ea02ce', '24913c60-a361-43e5-8181-0556656e4a07')),
    2: dict(litres=20, L=0.160, H=0.215, T=0.080, paint=(166, 148, 104), cap=(92, 80, 56), ink=(56, 50, 38),
            guids=('8a2a00d5-7fba-4692-86b1-020710717443', 'ee8a79c3-ad3a-4115-ad5e-221b14682c0b')),
    3: dict(litres=25, L=0.170, H=0.230, T=0.086, paint=(158, 164, 168), cap=(62, 66, 70), ink=(44, 46, 48),
            guids=('70ff56b3-a755-4ab6-b9df-f64e4a484035', '33b0be17-11c0-4d05-a7a3-2c0fd101fa1f')),
}
ROMAN = {1: 'I', 2: 'II', 3: 'III'}
BAND = (214, 172, 46)            # the mark's bands on both ends, one per mark
STEEL = (146, 148, 146)
BARE = (70, 68, 62)              # bare steel where the paint has chipped

GRIP = np.array([0.0, 0.018, 0.006])   # the middle handle's bar centre: where the vanilla can's handle bar is
R_EDGE = 0.014                   # radius of the body's edges
HANDLE_R = 0.0045                # handle bar radius
HANDLE_UP = 0.024                # bar centre above the body's top
MID_W, SIDE_W, GAP = 0.050, 0.026, 0.005
END_ROOM = 0.010                 # body beyond the outer handle at the -y end
X_HALF, X_DEPTH = 0.010, 0.0035  # the pressed X: channel half width and depth
SPOUT_TILT = 30.0                # degrees from up toward +y
NX, NY, NZ = 2, 12, 16           # body grid (flat part) across, along, up


def name_of(mk):
    return 'OA_FuelCanMk%d' % mk


def out_paths(mk):
    n = name_of(mk)
    return {
        'S': os.path.join(MEDIA, 'models_X', n + '.x'),
        'R': os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', n + '_RHand.x'),
        'L': os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', n + '_LHand.x'),
        'G': os.path.join(MEDIA, 'models_X', 'WorldItems', n + '_Ground.fbx'),
        'TEX': os.path.join(MEDIA, 'textures', 'OA_FuelCan', n + '.png'),
        'ICON': os.path.join(HERE, 'fuelcan_icon_source_mk%d.png' % mk),
    }


def clothing_items(mk):
    """{clothing file name: (guid, model name)} of a mark's two carried models."""
    n = name_of(mk)
    g = MARKS[mk]['guids']
    return {'OA_Bag_FuelCanMk%d_RHand' % mk: (g[0], n + '_RHand'), 'OA_Bag_FuelCanMk%d_LHand' % mk: (g[1], n + '_LHand')}


# ======================================================================================================================
# Geometry
# ======================================================================================================================
# face: (normal axis, sign, u (screen right seen from outside, z up), v (screen down)); u x v is the outward normal
FACES = {
    '+x': (0, 1, (0, -1, 0), (0, 0, -1)), '-x': (0, -1, (0, 1, 0), (0, 0, -1)),
    '+y': (1, 1, (1, 0, 0), (0, 0, -1)), '-y': (1, -1, (-1, 0, 0), (0, 0, -1)),
    '+z': (2, 1, (0, 1, 0), (-1, 0, 0)), '-z': (2, -1, (0, 1, 0), (1, 0, 0)),
}
GRID = (NX, NY, NZ)


def seg_dist(py, pz, a, b):
    """Distance of points (py, pz) to the segment a-b in the y-z plane."""
    d = np.asarray(b, float) - np.asarray(a, float)
    t = np.clip(((py - a[0]) * d[0] + (pz - a[1]) * d[1]) / (d @ d), 0, 1)
    return np.hypot(py - a[0] - t * d[0], pz - a[1] - t * d[1])


class Body:
    """The can's body: a box with rounded edges (faces sampled like tools/backpack_mesh.py's SoftBox), the X pressed
    into both broad sides. Coordinates relative to the body's centre `c`."""

    def __init__(self, mk):
        m = MARKS[mk]
        self.h = np.array([m['T'], m['L'], m['H']]) / 2
        self.r = R_EDGE
        ztop = GRIP[2] - HANDLE_UP
        y_lo = GRIP[1] - (MID_W / 2 + GAP + SIDE_W) - END_ROOM
        self.c = np.array([0.0, y_lo + self.h[1], ztop - self.h[2]])
        hy, hz = self.h[1], self.h[2]
        # the X panel: corners of its two diagonals (y, z relative to the centre)
        py = hy - R_EDGE - 0.010
        z0, z1 = -hz + R_EDGE + 0.010, hz - R_EDGE - 0.034
        self.panel = (py, z0, z1)
        self.diagonals = (((-py, z0), (py, z1)), ((-py, z1), (py, z0)))

    @property
    def top(self):
        return self.c[2] + self.h[2]

    def press(self, y, z):
        """Depth of the X at (y, z) (relative to the centre)."""
        d = np.minimum(seg_dist(y, z, *self.diagonals[0]), seg_dist(y, z, *self.diagonals[1]))
        return X_DEPTH * smoothstep(X_HALF, X_HALF * 0.35, d)

    def axis_coords(self, k, n_mid, n_band=2):
        h, r = self.h[k], min(self.r, self.h[k] * 0.999)
        inner = h - r
        band = [inner + r * math.tan(math.radians(45.0 * i / n_band)) for i in range(1, n_band + 1)]
        mid = list(np.linspace(-inner, inner, n_mid + 1)) if inner > 1e-9 else [0.0]
        return np.array([-b for b in reversed(band)] + mid + band) / h

    def base(self, face, a, b):
        k, s, U, V = FACES[face]
        U, V = np.array(U, float), np.array(V, float)
        ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
        p = np.zeros(3)
        p[k] = s * self.h[k]
        return p + U * a * self.h[ku] + V * b * self.h[kv]

    def point(self, face, a, b):
        k, s = FACES[face][:2]
        p = self.base(face, a, b)
        inner = self.h - self.r
        cl = np.clip(p, -inner, inner)
        d = p - cl
        n = unit(d) if np.linalg.norm(d) > 1e-12 else np.eye(3)[k] * s
        q = cl + n * self.r
        if k == 0:
            q[0] -= s * float(self.press(q[1], q[2]))
        return q + self.c

    def part(self, charts):
        pt = Part('body')
        for face, chart in charts.items():
            k, s, U, V = FACES[face]
            ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
            As, Bs = self.axis_coords(ku, GRID[ku]), self.axis_coords(kv, GRID[kv])
            grid = [[pt.add(self.point(face, a, b), chart.uv((a + 1) / 2, (b + 1) / 2)) for b in Bs] for a in As]
            for i in range(len(As) - 1):
                for j in range(len(Bs) - 1):
                    pt.quad(grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1])
        return pt.orient()

    def outline(self, n=120):
        """The body's edge at x = 0 (its y-z profile, on the surface) and the outward normals there, as a closed loop."""
        hy, hz = self.h[1] - self.r, self.h[2] - self.r
        pts, outs = [], []
        corners = ((hy, hz, 0), (-hy, hz, 90), (-hy, -hz, 180), (hy, -hz, 270))
        for cy, cz, a0 in corners:
            for i in range(8):
                t = math.radians(a0 + 90.0 * i / 7)
                pts.append((0, cy + self.r * math.cos(t), cz + self.r * math.sin(t)))
                outs.append((0, math.cos(t), math.sin(t)))
        P = np.array(pts) + self.c
        O = np.array(outs)
        # evenly spaced along the loop
        loop = np.vstack([P, P[:1]])
        s = B.arclen(loop)
        ts = np.linspace(0, s[-1], n + 1)
        out_p, out_o = [], []
        for t in ts:
            k = min(np.searchsorted(s, t, side='right') - 1, len(P) - 1)
            seg = max(s[k + 1] - s[k], 1e-12)
            w = (t - s[k]) / seg
            out_p.append(loop[k] * (1 - w) + loop[k + 1] * w)
            o1 = O[(k + 1) % len(O)]
            out_o.append(unit(O[k] * (1 - w) + o1 * w))
        out_p[-1], out_o[-1] = out_p[0], out_o[0]
        return np.array(out_p), np.array(out_o)


def define_charts(body):
    D = DENSITY
    hx, hy, hz = body.h
    C = {
        '+x': Chart('+x', 2 * hy * D, 2 * hz * D, 'paint'), '-x': Chart('-x', 2 * hy * D, 2 * hz * D, 'paint'),
        '+y': Chart('+y', 2 * hx * D, 2 * hz * D, 'paint'), '-y': Chart('-y', 2 * hx * D, 2 * hz * D, 'paint'),
        '+z': Chart('+z', 2 * hy * D, 2 * hx * D, 'paint'), '-z': Chart('-z', 2 * hy * D, 2 * hx * D, 'paint'),
        'seam': Chart('seam', 16, 240, 'paint'),
        'handle': Chart('handle', 2 * math.pi * HANDLE_R * D, 80, 'paint'),
        'boss': Chart('boss', 66, 24, 'paint'), 'neck': Chart('neck', 50, 24, 'paint'),
        'cap': Chart('cap', 66, 24, 'cap'), 'lever': Chart('lever', 18, 18, 'steel'),
    }
    B.pack_charts(list(C.values()), size=ATLAS)
    return C


def handle_spans():
    gy = GRIP[1]
    mid = (gy - MID_W / 2, gy + MID_W / 2)
    left = (mid[0] - GAP - SIDE_W, mid[0] - GAP)
    right = (mid[1] + GAP, mid[1] + GAP + SIDE_W)
    return left, mid, right


def handle_part(body, span, C, i):
    a, b = span[0] + HANDLE_R, span[1] - HANDLE_R
    zt, zb = body.top - 0.004, GRIP[2]
    ctrl = [(0, a, zt), (0, a, zt + 0.012), (0, a + 0.004, zb - 0.002), (0, a + 0.010, zb), ((0, (a + b) / 2, zb)),
            (0, b - 0.010, zb), (0, b - 0.004, zb - 0.002), (0, b, zt + 0.012), (0, b, zt)]
    path = catmull(ctrl, 16)
    outs = np.tile([1.0, 0, 0], (len(path), 1))
    return B.sweep('handle%d' % i, path, outs, 2 * HANDLE_R, 2 * HANDLE_R, C['handle'], 'paint', n_prof=6,
                   squareness=2.0)


def spout_parts(body, C):
    left, mid, right = handle_spans()
    y_hi = body.c[1] + body.h[1]
    ys = (right[1] + y_hi) / 2 + 0.002
    t = math.radians(SPOUT_TILT)
    A = np.array([0, math.sin(t), math.cos(t)])
    base = np.array([0, ys, body.top])
    parts = [
        B.cylinder('boss', base - np.array([0, 0, 0.010]), (0, 0, 1), 0.0115, 0.012, C['boss'], 'paint', n=16),
        B.cylinder('neck', base, A, 0.0085, 0.016, C['neck'], 'paint', n=14, cap_top=False),
        B.cylinder('cap', base + A * 0.014, A, 0.0115, 0.010, C['cap'], 'cap', n=16, ridges=0.035),
    ]
    side = np.array([0, -math.cos(t), math.sin(t)])     # across the cap toward the handles
    centre = base + A * 0.0262 + side * 0.0045
    frame = np.stack([np.array([1.0, 0, 0]), side, A], axis=1)
    parts.append(B.box_part('lever', centre, (0.0035, 0.0125, 0.0018), frame, C['lever'], 'steel'))
    return parts


def build_mesh(mk):
    body = Body(mk)
    C = define_charts(body)
    parts = [body.part({f: C[f] for f in FACES})]
    path, outs = body.outline(64)
    parts.append(B.sweep('seam', path, outs, 0.0065, 0.005, C['seam'], 'paint', n_prof=4, caps=False, squareness=3.0))
    for i, span in enumerate(handle_spans()):
        parts.append(handle_part(body, span, C, i))
    parts += spout_parts(body, C)
    return body, C, Mesh(parts)


# ======================================================================================================================
# Texture
# ======================================================================================================================
def chart_grid(ch):
    """Per pixel of a chart: (a, b) in [-1, 1] along its face's u and v."""
    x0, y0, x1, y1 = ch.rect
    xs = (np.arange(x0, x1) + 0.5 - x0 - 1.5) / (x1 - x0 - 3)
    ys = (np.arange(y0, y1) + 0.5 - y0 - 1.5) / (y1 - y0 - 3)
    S, T = np.meshgrid(xs, ys)
    return S * 2 - 1, T * 2 - 1


def face_local(body, face, a, b):
    """Relative position (on the box before rounding) of chart coordinates (a, b) of a face."""
    k, s, U, V = FACES[face]
    U, V = np.array(U, float), np.array(V, float)
    ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
    out = [np.zeros_like(a) for _ in range(3)]
    out[k] = out[k] + s * body.h[k]
    for ax in range(3):
        out[ax] = out[ax] + U[ax] * a * body.h[ku] + V[ax] * b * body.h[kv]
    return out


def edge_mask(body, face, a, b):
    """1 on the rounded edges of a face's chart, 0 on its flat part."""
    _, _, U, V = FACES[face]
    ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
    ia = 1 - body.r / body.h[ku]
    ib = 1 - body.r / body.h[kv]
    return np.maximum(smoothstep(ia - 0.05, ia + 0.05, np.abs(a)), smoothstep(ib - 0.05, ib + 0.05, np.abs(b)))


def paste(P, im, cx, cy):
    """Alpha-composites a PIL RGBA image onto the painter's atlas, centred at atlas pixel (cx, cy)."""
    a = np.asarray(im, float)
    h, w = a.shape[:2]
    x0, y0 = int(round(cx - w / 2)), int(round(cy - h / 2))
    reg = P.img[y0:y0 + h, x0:x0 + w]
    al = a[..., 3:4] / 255.0
    P.img[y0:y0 + h, x0:x0 + w] = reg * (1 - al) + a[..., :3] * al


def chips(P, ch, mask, amount):
    """Paint chipped off to bare steel where `mask` (per chart pixel) is high, in small irregular flecks."""
    x0, y0, x1, y1 = ch.rect
    h, w = y1 - y0, x1 - x0
    n = P.noise(h, w, 2.2) + P.noise(h, w, 7) * 0.6
    fleck = (n + mask * amount) > 3.1
    reg = P.img[y0:y1, x0:x1]
    reg[fleck] = reg[fleck] * 0.25 + np.array(BARE, float) * 0.75


def paint_atlas(mk, body, C):
    m = MARKS[mk]
    P = B.Painter(C)
    P.img[:] = m['paint']
    for nm, ch in C.items():
        col = {'paint': m['paint'], 'cap': m['cap'], 'steel': STEEL}[ch.mat]
        if nm in ('boss', 'neck'):
            col = tuple(int(c * 0.86) for c in col)
        P.flat(ch, col, noise=2.2)
    for face in FACES:
        ch = C[face]
        x0, y0, x1, y1 = ch.rect
        a, b = chart_grid(ch)
        loc = face_local(body, face, a, b)
        reg = P.img[y0:y1, x0:x1]
        # the paint a little lighter on the upper part (weathered by the sun), the edges worn
        reg += (np.clip(loc[2] / body.h[2], -1, 1) * 5.0)[..., None]
        if face[1] == 'x':
            # the pressed X: its walls shaded for a light from above, the channels a little dirtier
            d = body.press(loc[1], loc[2])
            px = 1.0 / DENSITY
            gt, gs = np.gradient(d, px)
            delta = -55.0 * (0.30 * gs + 0.95 * gt) - 16.0 * d / X_DEPTH
            reg += delta[..., None]
        if face[1] == 'y':
            # the mark's bands near the top of both ends
            for i in range(mk):
                zt = body.h[2] - 0.030 - i * 0.016
                band = (loc[2] <= zt) & (loc[2] > zt - 0.010)
                reg[band] = reg[band] * 0.15 + np.array(BAND, float) * 0.85
        chips(P, ch, edge_mask(body, face, a, b), 1.6)
    # the stencils on both broad sides, above the X: the team's acorn and the mark with its litres
    py, z0, z1 = body.panel
    zm = (z1 + body.h[2] - R_EDGE) / 2
    band_h = (body.h[2] - R_EDGE - z1) * DENSITY
    text_h = int(round(band_h * 0.62))
    label = E.stencil_text('MK %s  %dL' % (ROMAN[mk], m['litres']), int(text_h * 3.8), text_h, colour=m['ink'])
    mark = E.acorn_mark(int(round(band_h * 0.82)), colour=m['ink'])
    for face in ('+x', '-x'):
        ch = C[face]
        b = -zm / body.h[2]
        cx, cy = ch.px(0.5, (b + 1) / 2)
        gap = 4
        total = mark.width + gap + label.width
        paste(P, mark, cx - total / 2 + mark.width / 2, cy)
        paste(P, label, cx - total / 2 + mark.width + gap + label.width / 2, cy)
    # the handles: worn to bare steel along the bars where hands go
    ch = C['handle']
    x0, y0, x1, y1 = ch.rect
    h, w = y1 - y0, x1 - x0
    tt = (np.arange(h)[:, None] + 0.5) / h + np.zeros((1, w))
    chips(P, ch, smoothstep(0.30, 0.42, tt) * smoothstep(0.70, 0.58, tt), 1.2)
    chips(P, C['seam'], np.ones((C['seam'].rect[3] - C['seam'].rect[1], C['seam'].rect[2] - C['seam'].rect[0])), 0.9)
    return P


def finish(P, mesh, body):
    """Baked shading: ambient occlusion (tools/backpack_mesh.py's uv-space buffer), dust toward the bottom."""
    swapped = mesh.transformed(lambda X: X[:, [0, 2, 1]], lambda X: X[:, [0, 2, 1]])   # its 'height' is our z
    ao, zpos, cov = B.uv_gbuffer(swapped, res=256)
    img = P.img

    def up(a):
        return np.array(Image.fromarray(a.astype(np.float32), 'F').resize((ATLAS, ATLAS), Image.BILINEAR))
    covf = up(cov)
    aof = np.where(covf > 0.01, up(ao) / np.maximum(covf, 1e-3), 1.0)
    zf = np.where(covf > 0.01, up(zpos) / np.maximum(covf, 1e-3), body.c[2])
    aof = B.blur(aof, 1.4)
    img *= (0.55 + 0.45 * np.clip(aof, 0, 1))[..., None]
    zlo = body.c[2] - body.h[2]
    low = np.clip((zlo + 0.045 - zf) / 0.045, 0, 1) ** 1.3
    crease = np.clip((0.85 - aof) / 0.4, 0, 1)
    speck = (P.rng.random((ATLAS, ATLAS)) > 0.5) * P.rng.random((ATLAS, ATLAS))
    a = np.clip((0.40 * low + 0.25 * crease) * (0.55 + 0.6 * speck), 0, 0.5)[..., None]
    img[:] = img * (1 - a) + np.array((88, 74, 54), float) * a
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), 'RGB')


# ======================================================================================================================
# Files
# ======================================================================================================================
def hand_fits():
    """{'R' | 'L': (M, t)}: the rigid transform each vanilla carried file applies to the vanilla static mesh
    (carried = static @ M + t)."""
    s = B.parse_x(VANILLA_STATIC)['V']
    out = {}
    for key, h in HANDS.items():
        v = B.parse_x(os.path.join(B.VANILLA_BP, h['src']))['V']
        need(len(v) == len(s), 'the vanilla carried can is not the static one')
        X = np.linalg.lstsq(np.hstack([s, np.ones((len(s), 1))]), v, rcond=None)[0]
        U, _, Vt = np.linalg.svd(X[:3])
        M = U @ Vt
        need(abs(np.linalg.det(M) - 1) < 1e-6, 'the vanilla carried can is mirrored')
        need(np.abs(s @ M + X[3] - v).max() < 1e-4, 'the vanilla carried can is not a rigid copy')
        out[key] = (M, X[3])
    return out


def vanilla_grip():
    """Centre of the vanilla can's handle bar (the vertices of the bar above the body)."""
    V = B.parse_x(VANILLA_STATIC)['V']
    bar = V[(V[:, 2] > 0.0) & (V[:, 2] < 0.012) & (V[:, 1] > -0.03) & (V[:, 1] < 0.06)]
    return (bar.min(0) + bar.max(0)) / 2


def static_text(name, mesh):
    m = mesh.transformed(lambda X: X, lambda X: X)
    m.W = {'_': np.ones(len(m.P))}
    text = B.mesh_frame_text(name, m, {'_': ''}, MAT)
    i = text.index('\n\n  XSkinMeshHeader {')
    j = text.rindex(' }\n}\n')
    return text[:i] + '\n' + text[j:]


def write_static(mk, mesh):
    txt = B.read_text(VANILLA_STATIC)
    prefix = txt[:txt.index('\nFrame GasCan {') + 1]
    prefix = re.sub(r'TextureFilename \{\n(\s*)"[^"]*";', lambda g: 'TextureFilename {\n%s"%s.png";' % (g.group(1), name_of(mk)),
                    prefix)
    prefix = re.sub(r'^Material \S+ \{', 'Material %s {' % MAT, prefix, flags=re.M)
    path = out_paths(mk)['S']
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write((prefix + static_text(name_of(mk), mesh)).encode('latin-1'))


def carried(mesh, fit):
    M, t = fit
    return mesh.transformed(lambda X: X @ M + t, lambda X: X @ M)


def write_hand(mk, key, mesh, fit):
    h = HANDS[key]
    B.TEX_REF = name_of(mk) + '.png'
    prefix, suffix, pm = B.vanilla_parts(h['src'], h['bone'])
    material = re.search(r'^Material (\S+) \{', prefix, re.M).group(1)
    m = carried(mesh, fit)
    m.W = {h['bone']: np.ones(len(m.P))}
    text = prefix + B.mesh_frame_text('%s_%sHand' % (name_of(mk), key), m, {h['bone']: pm}, material) + '\n' + suffix
    path = out_paths(mk)[key]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(text.encode('latin-1'))


def write_ground(mk, mesh):
    """The floor model: the vanilla ground model's raw axes are 3ds Max inches (z up, standing on z = 0), ours mapped as
    the vanilla can is (x, -y about the middle, z from the bottom) * 100: a mirror image, as .x is left handed."""
    P, N, UV, F = mesh.arrays()
    cy = (P[:, 1].min() + P[:, 1].max()) / 2
    raw = np.stack([P[:, 0], -(P[:, 1] - cy), P[:, 2] - P[:, 2].min()], axis=1) * 100.0
    rawN = np.stack([N[:, 0], -N[:, 1], N[:, 2]], axis=1)
    name = name_of(mk)

    def rename(s):   # names and texture paths: nothing of the vanilla file's author or art remains
        s = re.sub(rb'[^\x00\x01"]*GasCan\.png', (name + '.png').encode(), s, flags=re.I)
        s = re.sub(rb'[A-Za-z]:\\[^\x00]*\.(FBX|max)', (name + '_Ground.fbx').encode(), s, flags=re.I)
        s = s.replace(b'GasCan', (name + '_Ground').encode())
        return s.replace(b'02 - Default', (name + '_Mat').encode()).replace(b'Map #2', (name + '_Map').encode())
    return B.ground_fbx(VANILLA_GROUND, out_paths(mk)['G'], raw, rawN, UV, F, rename)


def write_clothing(mk):
    for fname, (guid, model) in clothing_items(mk).items():
        text = (
            '<?xml version="1.0" encoding="utf-8"?>\n<clothingItem>\n'
            '\t<m_MaleModel>media\\models_X\\Skinned\\BackPacks\\%s.X</m_MaleModel>\n'
            '\t<m_FemaleModel>media\\models_X\\Skinned\\BackPacks\\%s.X</m_FemaleModel>\n'
            '\t<m_GUID>%s</m_GUID>\n'
            '\t<m_Static>false</m_Static>\n'
            '\t<m_AllowRandomHue>false</m_AllowRandomHue>\n'
            '\t<m_AllowRandomTint>false</m_AllowRandomTint>\n'
            '\t<m_AttachBone></m_AttachBone>\n'
            '\t<textureChoices>OA_FuelCan\\%s</textureChoices>\n'
            '</clothingItem>') % (model, model, guid, name_of(mk))
        B.write_text(os.path.join(CLOTHING_DIR, fname + '.xml'), text, bom=True)
    B.merge_guid_table(GUID_TABLE, {f: g for f, (g, _) in clothing_items(mk).items()})


def write_script():
    blocks = []
    for mk in MARKS:
        n = name_of(mk)
        blocks.append('\tmodel %s\n\t{\n\t\tmesh = %s,\n\t\ttexture = OA_FuelCan/%s,\n\t}\n' % (n, n, n))
        blocks.append('\tmodel %s_Ground\n\t{\n\t\tmesh = WorldItems/%s_Ground,\n\t\ttexture = OA_FuelCan/%s,\n'
                      '\t\tscale = 0.4,\n\t}\n' % (n, n, n))
    B.write_text(SCRIPT, 'module OperationAcorn\n{\n'
                 '\t/* The research team fuel cans (tools/fuelcan_mesh.py): per mark the static model and the one lying on\n'
                 '\t   the floor. The carried models are clothing items (OA_Bag_FuelCanMk<n>_RHand / _LHand). */\n'
                 + '\n'.join(blocks) + '}\n')


# ======================================================================================================================
# Previews and the icon sources
# ======================================================================================================================
def y_up(X):
    """Our z-up space to the previews' y-up one (x kept, z -> y, y -> -z: a rotation)."""
    return np.stack([X[:, 0], X[:, 2], -X[:, 1]], axis=1)


def upright(mesh):
    P, N, UV, F = mesh.arrays()
    return y_up(P), y_up(N), UV, F


ICON_AZIMUTH = -122.0   # the broad +x side with its stencils, and the spout's end


def make_icon_source(mk, mesh, tex):
    """The can standing, seen as the floor model is (a little from above), on a clear background: rendered on black and
    on white, where they differ is how far the background shows through (the alpha), as tools/backpack_mesh.py does."""
    g = upright(mesh)
    d = B.iso_dir(ICON_AZIMUTH)
    black = np.asarray(B.render([g], tex, d, (0, 1, 0), 512, ss=3, bg=(0, 0, 0)), float)
    white = np.asarray(B.render([g], tex, d, (0, 1, 0), 512, ss=3, bg=(255, 255, 255)), float)
    alpha = np.clip(1.0 - (white - black).mean(-1) / 255.0, 0.0, 1.0)
    colour = np.where(alpha[..., None] > 1e-3, black / np.maximum(alpha[..., None], 1e-3), 0.0)
    im = Image.fromarray(np.dstack([np.clip(colour, 0, 255), alpha * 255]).astype(np.uint8), 'RGBA')
    im.crop(im.getbbox()).save(out_paths(mk)['ICON'])


def make_preview(built, fits):
    size = 300
    tiles = []
    body = B.body_of('MaleBody.x')
    for mk, (cb, C, mesh, tex) in built.items():
        g = upright(mesh)
        for lab, d in (('iso', B.iso_dir(ICON_AZIMUTH)), ('iso back', B.iso_dir(60)), ('+x side', (-1, 0, 0)),
                       ('spout end', (0, 0, 1)), ('top', (0.0001, -1, 0.3))):
            tiles.append(B.label(B.render([g], tex, d, (0, 1, 0), size), 'Mk%d %s' % (mk, lab)))
        # carried in the right hand, bind pose: the middle bar in the hand
        r = carried(mesh, fits['R'])
        P, N, UV, F = r.arrays()
        region = np.concatenate([P, body.V[np.linalg.norm(body.V - P.mean(0), axis=1) < 0.25]])
        d = B.unit((0.2, -0.35, -1.0))
        fr = B.frame_for(region, d, pad=1.05)
        tiles.append(B.label(B.render([(P, N, UV, F)], tex, d, (0, 1, 0), size,
                                      bodies=[(body.V, body.VN, body.T, B.BODY_COL)], frame=fr), 'Mk%d right hand' % mk))
    B.sheet(tiles, 6, size).save(PREVIEW)


# ======================================================================================================================
# Build and check
# ======================================================================================================================
def build_all():
    fits = hand_fits()
    grip = vanilla_grip()
    need(np.linalg.norm(grip[1:] - GRIP[1:]) < 0.01, 'the middle handle is not where the vanilla handle is: %s' % grip)
    built = {}
    for mk in MARKS:
        body, C, mesh = build_mesh(mk)
        P = paint_atlas(mk, body, C)
        img = finish(P, mesh, body)
        paths = out_paths(mk)
        os.makedirs(os.path.dirname(paths['TEX']), exist_ok=True)
        img.save(paths['TEX'])
        write_static(mk, mesh)
        for key in 'RL':
            write_hand(mk, key, mesh, fits[key])
        nv, nf = write_ground(mk, mesh)
        write_clothing(mk)
        tex = np.asarray(img)
        make_icon_source(mk, mesh, tex)
        built[mk] = (body, C, mesh, tex)
        print('Mk%d: %d vertices, %d triangles' % (mk, len(mesh.P), len(mesh.F)))
    write_script()
    make_preview(built, fits)


def check_x(path, frame, bone=None, src=None):
    raw = open(path, 'rb').read()
    need(raw.startswith(b'xof 0303txt 0032'), 'header')
    txt = raw.decode('latin-1')
    need('\r' not in txt, 'unexpected CR')
    body = re.sub(r'"[^"]*"', '""', txt)
    need(body.count('{') == body.count('}'), 'unbalanced braces')
    need(re.search(r'^\s*Frame %s \{' % frame, txt, re.M), 'mesh frame %s missing' % frame)
    d = B.parse_x(path)
    V, T, N, UV = d['V'], d['T'], d['N'], d['UV']
    need(T.min() >= 0 and T.max() < len(V), 'face index out of range')
    need(N is not None and len(N) == len(V) and np.abs(np.linalg.norm(N, axis=1) - 1).max() < 1e-3, 'normals')
    c = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    agree = (c * N[T].mean(1)).sum(1) > 0
    need(agree.mean() > 0.995, '%d faces wound against their normals' % (~agree).sum())
    need(UV is not None and len(UV) == len(V) and UV.min() >= 0 and UV.max() <= 1, 'uvs')
    ml = re.search(r'MeshMaterialList \{\n\s*1;\n\s*(\d+);\n((?:\s*0[,;]\n)+)\s*\{ (\S+) \}', txt)
    need(ml and int(ml.group(1)) == len(T) and 'Material %s {' % ml.group(3) in txt, 'material list')
    if bone:
        need(list(d['bones']) == [bone], 'rigid on %s' % bone)
        idx, w, mat = d['bones'][bone]
        need(len(idx) == len(V) and np.abs(w - 1).max() < 1e-6, 'every vertex fully on %s' % bone)
        need(mat == B.vanilla_parts(src, bone)[2], 'offset matrix differs from the vanilla one')
        need('AnimationSet' in txt, 'animation set missing')
    else:
        need(not d['bones'] and 'XSkinMeshHeader' not in txt, 'the static model has skin')
    return len(V), len(T)


def check_fbx(path, name):
    data = open(path, 'rb').read()
    need(data.startswith(B.MAGIC), 'fbx magic')
    ver, nodes = B.fbx_read(data)
    geo = [c for c in B.fbx_find(nodes, 'Objects')[2] if c[0] == 'Geometry'][0]
    kids = {c[0]: c for c in geo[2]}
    V = np.array(kids['Vertices'][1][0][1]).reshape(-1, 3)
    pv = np.array(kids['PolygonVertexIndex'][1][0][1])
    need(len(pv) % 3 == 0 and (pv[2::3] < 0).all() and (pv[0::3] >= 0).all(), 'triangles')
    need(np.where(pv < 0, ~pv, pv).max() < len(V), 'fbx index range')
    lo, hi = V.min(0), V.max(0)
    need(abs(lo[2]) < 1e-3 and 20 < hi[2] < 35 and abs(lo[1] + hi[1]) < 1e-3, 'ground model placement %s %s' % (lo, hi))
    strings = B.fbx_strings(nodes)
    need(not any(re.match(rb'[A-Za-z]:\\', s) or b'GasCan' in s for s in strings) and (name + '.png').encode() in strings,
         'fbx names')
    return len(V), len(pv) // 3


def check_all():
    bad = 0

    def run(label, fn, *a):
        nonlocal bad
        try:
            r = fn(*a)
            print('ok   %-34s %s' % (label, r or ''))
        except (Fail, FileNotFoundError, AttributeError, ValueError, IndexError, KeyError) as e:
            bad += 1
            print('FAIL %-34s %s: %s' % (label, type(e).__name__, e))
    table = open(GUID_TABLE, encoding='utf-8-sig').read() if os.path.exists(GUID_TABLE) else ''
    script = open(SCRIPT, encoding='utf-8').read() if os.path.exists(SCRIPT) else ''

    def files(mk):
        n = name_of(mk)
        need(Image.open(out_paths(mk)['TEX']).size == (ATLAS, ATLAS), 'texture size')
        for fname, (guid, model) in clothing_items(mk).items():
            xml = open(os.path.join(CLOTHING_DIR, fname + '.xml'), encoding='utf-8-sig').read()
            need('<m_GUID>%s</m_GUID>' % guid in xml and '\\%s.X</m_' % model in xml, fname + ': xml')
            need('%s.xml</path>\n\t\t<guid>%s</guid>' % (fname, guid) in table, fname + ': not in fileGuidTable')
            need('<textureChoices>OA_FuelCan\\%s</textureChoices>' % n in xml, fname + ': texture')
        need('model %s\n' % n in script and 'mesh = WorldItems/%s_Ground,' % n in script, 'model script')
        need(os.path.exists(out_paths(mk)['ICON']), 'icon source')
    for mk in MARKS:
        p, n = out_paths(mk), name_of(mk)
        run(os.path.basename(p['S']), check_x, p['S'], n)
        run(os.path.basename(p['R']), check_x, p['R'], n + '_RHand', 'Bip01_Prop1', HANDS['R']['src'])
        run(os.path.basename(p['L']), check_x, p['L'], n + '_LHand', 'Bip01_Prop2', HANDS['L']['src'])
        run(os.path.basename(p['G']), check_fbx, p['G'], n)
        run('Mk%d texture, clothing, guids, script' % mk, files, mk)
    run('model script braces', lambda: need(script.count('{') == script.count('}'), 'braces'))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='validate the produced files instead of building')
    args = ap.parse_args()
    if not args.check:
        build_all()
    sys.exit(check_all())


if __name__ == '__main__':
    main()
