#!/usr/bin/env python3
"""Builds the Operation Acorn research team waist bag ('연구팀 허리 가방'): meshes, texture and the files the game needs.

    py tools/waistbag_mesh.py              build everything, render tools/waistbag_preview.png and the icon source
    py tools/waistbag_mesh.py --check      re-parse every produced file and assert it is consistent (no building)

What it writes (all under OperationAcorn/42/media):
    models_X/Skinned/BackPacks/OA_ResearchWaist_Front_M.x, _Front_F.x, _Back_M.x, _Back_F.x   worn on the belly / the back
    models_X/WorldItems/Clothing/OA_ResearchWaist_Ground.fbx                                    the floor model
    textures/Clothes/Bag/OA_ResearchWaist.png                                                   256x256 atlas
    clothing/clothingItems/OA_Bag_ResearchWaistFront.xml, OA_Bag_ResearchWaistBack.xml          the clothing items
    fileGuidTable.xml                                                                           registers them
    scripts/OA_waistbag_models.txt                                                              the floor model script
and tools/waistbag_icon_source.png (the bag from the front, the source of the item icon tools/icon_art.py makes) and
tools/waistbag_preview.png.

The bag is the vanilla fanny pack's kind, larger and the team's: a hip pouch (a soft box, deeper at the bottom) with a
zipped front pocket that carries the team patch, on a 1.5" webbing belt closed by a side release buckle opposite the
pouch. Like the vanilla bag it is worn on the belly or turned round to the back (two items, two models each).

What comes from the game install (PZ_DIR), structure only, as in tools/backpack_mesh.py (whose helpers this uses):
  * the vanilla bodies MaleBody.x / FemaleBody.x: the belt is laid round the body's waist at a clearance, and every
    belt cross-section takes the skin weights of the body under it (the pelvis, the spine and the thighs, as the vanilla
    fanny pack's belt has), so it moves with the hips; where the belt runs behind the pouch it blends into the pouch's
    weights. The pouch is rigid on the weights of the body at its middle. The bone offset matrices are the body's.
  * the vanilla fanny pack .x files (M_/F_FannyPackFront.x, M_/F_FannyPactBack.x): skeleton frames, templates and
    animation set are spliced around our mesh frame.
  * the vanilla floor model M_FannyPackFront_Ground.fbx: node layout and units (the geometry is replaced).

Model space: x lateral (the wearer's left positive), y up, z toward the back. Bag-local space (where the pouch is
built): x along the belt, y up, z out from the belt's outer face; it is wrapped round the waist when placed.
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
from backpack_mesh import (unit, units, smoothstep, arclen, raycast, Part, Mesh, Chart, SoftBox, sweep, box_part,  # noqa: E402
                           smooth_rows, limit_weights)

HERE = B.HERE
ROOT = B.ROOT
MEDIA = B.MEDIA
VANILLA_BP = B.VANILLA_BP
VANILLA_GROUND = os.path.join(B.PZ_DIR, 'media', 'models_X', 'WorldItems', 'Clothing', 'M_FannyPackFront_Ground.fbx')
PREVIEW = os.path.join(HERE, 'waistbag_preview.png')
ICON_SOURCE = os.path.join(HERE, 'waistbag_icon_source.png')

NAME = 'OA_ResearchWaist'
TEX_REF = NAME + '.png'
ATLAS = 512             # painted at this size (the stitches and zips are drawn in its pixels)
TEX_SIZE = 256          # and written at this: the bag is small on screen, half the size does not show
# the backpack's chart, painter and atlas helpers read the atlas size from their own module
B.ATLAS = ATLAS
DENSITY = 1100.0       # texture pixels per model unit on the visible surfaces
BONES = ('Bip01_Pelvis', 'Bip01_Spine', 'Bip01_Spine1', 'Bip01_L_Thigh', 'Bip01_R_Thigh')
SKINNED_DIR = os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks')
OUT = {
    'FM': os.path.join(SKINNED_DIR, NAME + '_Front_M.x'),
    'FF': os.path.join(SKINNED_DIR, NAME + '_Front_F.x'),
    'BM': os.path.join(SKINNED_DIR, NAME + '_Back_M.x'),
    'BF': os.path.join(SKINNED_DIR, NAME + '_Back_F.x'),
    'G': os.path.join(MEDIA, 'models_X', 'WorldItems', 'Clothing', NAME + '_Ground.fbx'),
    'TEX': os.path.join(MEDIA, 'textures', 'Clothes', 'Bag', TEX_REF),
    'GUID': os.path.join(MEDIA, 'fileGuidTable.xml'),
    'SCRIPT': os.path.join(MEDIA, 'scripts', 'OA_waistbag_models.txt'),
}
# per worn model: the vanilla file whose skeleton it takes, the body it is fitted to, the side the pouch is on
VARIANTS = {
    'FM': dict(src='M_FannyPackFront.x', body='MaleBody.x', back=False),
    'FF': dict(src='F_FannyPackFront.x', body='FemaleBody.x', back=False),
    'BM': dict(src='M_FannyPactBack.x', body='MaleBody.x', back=True),
    'BF': dict(src='F_FannyPactBack.x', body='FemaleBody.x', back=True),
}
CLOTHING_DIR = os.path.join(MEDIA, 'clothing', 'clothingItems')
CLOTHING = {  # file -> (guid, male model, female model)
    'OA_Bag_ResearchWaistFront': ('5b0e7c2a-91d4-4f63-a8e5-2c7f1d9b4e60', NAME + '_Front_M', NAME + '_Front_F'),
    'OA_Bag_ResearchWaistBack': ('a47d3e19-6c25-4b8f-9e02-7f5c1a3d8b24', NAME + '_Back_M', NAME + '_Back_F'),
}

# ======================================================================================================================
# Dimensions (model units; 1 unit is about 1.85 m)
# ======================================================================================================================
BELT_Y = 0.545                  # height of the belt's middle (the vanilla fanny pack's belt runs here)
BELT_W, BELT_T = 0.021, 0.0034  # 1.5" webbing
CLEAR_BELT = 0.0035             # gap between the body and the belt's inner face
POUCH = dict(half=(0.084, 0.042, 0.032), r=0.016,
             bulge={'+z': 0.005, '+y': 0.003, '-y': 0.002, '+x': 0.003, '-x': 0.003, '-z': 0.0}, taper=(0.06, 0.14))
POUCH_DROP = {False: 0.012, True: 0.004}    # how far the pouch's middle hangs below the belt (front, back)
POCKET = dict(half=(0.060, 0.024, 0.010), r=0.008, dy=-0.010,
              bulge={'+z': 0.004, '+y': 0.001, '-y': 0.001, '+x': 0.001, '-x': 0.001, '-z': 0.0}, taper=(0.03, 0.10))
BUCKLE = (0.0175, 0.0125, 0.0042)   # side release buckle, half sizes along the belt, up, out
GROUND_LOOP = (0.155, 0.072, 0.050)  # the belt lying in a loop on the floor: half length, half width, centre behind


# ======================================================================================================================
# The waist: rings of the body surface round a vertical axis
# ======================================================================================================================
class Waist:
    """The body's surface round the waist, as radii about one vertical axis at the belt's height."""

    def __init__(self, body, n=180):
        self.body = body
        self.n = n
        y = BELT_Y
        zf = raycast(np.array([0.0, y, -1.0]), np.array([0, 0, 1.0]), body.allA, body.allB, body.allC)
        zb = raycast(np.array([0.0, y, 1.0]), np.array([0, 0, -1.0]), body.allA, body.allB, body.allC)
        self.zc = ((-1.0 + zf[0]) + (1.0 - zb[0])) / 2
        self.thetas = np.linspace(0.0, 2 * math.pi, n, endpoint=False)

    def direction(self, th):
        """Out from the axis at angle th: 0 is the front (-z), pi/2 the wearer's left (+x)."""
        return np.array([math.sin(th), 0.0, -math.cos(th)])

    def radii(self, y):
        """The body's radius at each angle at height y (smoothed round the ring)."""
        r = np.zeros(self.n)
        for i, th in enumerate(self.thetas):
            d = self.direction(th)
            o = np.array([0.0, y, self.zc]) + d * 0.5
            hit = raycast(o, -d, self.body.allA, self.body.allB, self.body.allC)
            r[i] = 0.5 - hit[0] if hit is not None else np.nan
        ok = ~np.isnan(r)
        r = np.interp(self.thetas, self.thetas[ok], r[ok], period=2 * math.pi)
        k = np.exp(-0.5 * (np.arange(-6, 7) / 2.0) ** 2)
        k /= k.sum()
        return np.convolve(np.concatenate([r[-6:], r, r[:6]]), k, mode='valid')

    def at(self, radii, th, y):
        r = np.interp(th % (2 * math.pi), self.thetas, radii, period=2 * math.pi)
        return np.array([0.0, y, self.zc]) + self.direction(th) * r


def hull_radii(waist, radii):
    """The radii of the convex outline round a ring of radii (about the waist's axis, at the same angles)."""
    pts = np.stack([np.sin(waist.thetas) * radii, -np.cos(waist.thetas) * radii], axis=1)
    order = sorted(range(len(pts)), key=lambda i: (pts[i][0], pts[i][1]))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    hull = []
    for seq in (order, order[::-1]):
        part = []
        for i in seq:
            while len(part) >= 2 and cross(pts[part[-2]], pts[part[-1]], pts[i]) <= 0:
                part.pop()
            part.append(i)
        hull += part[:-1]
    poly = pts[hull]
    out = np.zeros(len(radii))
    for k, th in enumerate(waist.thetas):
        d = np.array([math.sin(th), -math.cos(th)])
        best = radii[k]
        for a, b in zip(poly, np.roll(poly, -1, axis=0)):
            e = b - a
            den = d[0] * e[1] - d[1] * e[0]
            if abs(den) < 1e-12:
                continue
            t = (a[0] * e[1] - a[1] * e[0]) / den
            u = (a[0] * d[1] - a[1] * d[0]) / den
            if t > 0 and -1e-9 <= u <= 1 + 1e-9:
                best = max(best, t)
        out[k] = best
    return out


class Belt:
    """The belt's centre line round the waist (closed), with its outward directions and arc lengths from the
    pouch's middle."""

    def __init__(self, waist, back, n=64):
        self.waist = waist
        # the belt never dips into a hollow (the small of the back): it runs round the body's convex outline like a
        # tightened strap
        across = np.max([waist.radii(y) for y in np.linspace(BELT_Y - BELT_W / 2 - 0.002, BELT_Y + BELT_W / 2 + 0.002, 5)],
                        axis=0)
        self.radii = hull_radii(waist, across) + CLEAR_BELT + BELT_T / 2
        radii = self.radii
        self.th0 = math.pi if back else 0.0
        ths = self.th0 + np.linspace(0.0, 2 * math.pi, n + 1)
        self.P = np.array([waist.at(radii, th, BELT_Y) for th in ths])
        ring = self.P[:-1]
        T = units(np.roll(ring, -1, axis=0) - np.roll(ring, 1, axis=0))
        out = units(np.cross(T, np.array([0, 1.0, 0])))
        if np.dot(out[0], ring[0] - np.array([0, BELT_Y, waist.zc])) < 0:
            out = -out
        self.out = np.vstack([out, out[:1]])
        s = arclen(self.P)
        self.L = s[-1]
        # signed arc length from the pouch's middle: positive toward the wearer's left
        self.s = np.where(s > self.L / 2, s - self.L, s)

    def frame(self, s):
        """(point on the belt's outer face, outward direction, along direction) at signed arc length s."""
        s = (s + self.L / 2) % self.L - self.L / 2
        order = np.argsort(self.s[:-1])
        ss, P, O = self.s[:-1][order], self.P[:-1][order], self.out[:-1][order]
        p = np.array([np.interp(s, ss, P[:, k]) for k in range(3)])
        o = unit(np.array([np.interp(s, ss, O[:, k]) for k in range(3)]))
        t = unit(np.cross(np.array([0, 1.0, 0]), o))
        return p + o * (BELT_T / 2), o, t


class Wrap:
    """Bag-local -> model space: x runs along the belt, z out from it; below the belt the pouch leans out where the
    body below is fuller than at the belt (the seat, for a bag worn on the back)."""

    def __init__(self, belt, back, half_w):
        self.belt = belt
        waist = belt.waist
        # the pouch's back at the belt is the belt's outer face; lower down it must stay 4 mm off the body
        self.lean = 0.0
        face = belt.radii + BELT_T / 2
        for y in np.arange(BELT_Y - 0.080, BELT_Y - 0.019, 0.006):
            r = waist.radii(y)
            for x in np.linspace(-half_w, half_w, 9):
                p, o, _ = belt.frame(x)
                th = math.atan2(p[0], -(p[2] - waist.zc))
                need = (np.interp(th % (2 * math.pi), waist.thetas, r, period=2 * math.pi)
                        - np.interp(th % (2 * math.pi), waist.thetas, face, period=2 * math.pi)) + 0.004
                self.lean = max(self.lean, need / (BELT_Y - y))

    def __call__(self, P):
        P = np.asarray(P, float)
        out = np.zeros_like(P)
        for i, (x, y, z) in enumerate(P):
            # the belt's arc length runs toward the wearer's left; bag-local x runs to the right seen from outside (the
            # wearer's right on the belly), so the wrap is a turn, not a mirror
            p, o, _ = self.belt.frame(-x)
            out[i] = p + o * (z + self.lean * max(0.0, BELT_Y - y)) + np.array([0, y - BELT_Y, 0])
        return out


# ======================================================================================================================
# The bag (bag-local space)
# ======================================================================================================================
def define_charts():
    D = DENSITY
    C = {}

    def add(name, w, h, mat, dens=1.0):
        C[name] = Chart(name, w * D * dens, h * D * dens, mat)
    pb = SoftBox((0, 0, 0), POUCH['half'], POUCH['r'])
    add('pouch_front', pb.size('+z')[0] * 1.08, pb.size('+z')[1] * 1.08, 'canvas')
    add('pouch_back', pb.size('-z')[0] * 1.04, pb.size('-z')[1] * 1.04, 'padding', 0.6)
    add('pouch_side', pb.size('+x')[0] * 1.1, pb.size('+x')[1] * 1.08, 'canvas')
    add('pouch_top', pb.size('+y')[0] * 1.08, pb.size('+y')[1] * 1.1, 'canvas')
    add('pouch_bottom', pb.size('-y')[0], pb.size('-y')[1], 'base', 0.6)
    kb = SoftBox((0, 0, 0), POCKET['half'], POCKET['r'])
    add('pocket_front', kb.size('+z')[0] * 1.08, kb.size('+z')[1] * 1.1, 'canvas')
    add('pocket_side', kb.size('+x')[0] * 1.2, kb.size('+x')[1] * 1.1, 'canvas')
    add('pocket_top', kb.size('+y')[0] * 1.08, kb.size('+y')[1] * 1.3, 'canvas')
    add('pocket_bottom', kb.size('-y')[0], kb.size('-y')[1] * 1.2, 'base', 0.6)
    add('belt', 0.05, 0.32, 'web', 0.8)
    add('hard', 0.03, 0.03, 'hard')
    return C


def build_pouch(C, back):
    """The pouch and its pocket, in bag-local space (the belt's outer face is z = 0)."""
    yc = BELT_Y - POUCH_DROP[back]
    hz = POUCH['half'][2]
    pouch = SoftBox((0.0, yc, hz), POUCH['half'], POUCH['r'], POUCH['bulge'], POUCH['taper'], back=0.0, band=2)
    parts = [pouch.part('pouch', {'+z': C['pouch_front'], '-z': C['pouch_back'], '+x': C['pouch_side'],
                                  '-x': C['pouch_side'], '+y': C['pouch_top'], '-y': C['pouch_bottom']}, 'canvas',
                        res=4).orient()]
    # the pocket sits on the pouch's front, where the pouch's taper has brought its face to
    ky = yc + POCKET['dy']
    yrel = (ky - (yc - POUCH['half'][1])) / (2 * POUCH['half'][1])
    face = 2 * hz * (1 - POUCH['taper'][1] * yrel)
    kz = POCKET['half'][2]
    pocket = SoftBox((0.0, ky, face - 0.002 + kz), POCKET['half'], POCKET['r'], POCKET['bulge'], POCKET['taper'],
                     back=face - 0.002, band=2)
    parts.append(pocket.part('pocket', {'+z': C['pocket_front'], '+x': C['pocket_side'], '-x': C['pocket_side'],
                                        '+y': C['pocket_top'], '-y': C['pocket_bottom']}, 'canvas', res=3,
                             skip=('-z',)).orient())
    return parts


def belt_parts(C, path, outs):
    """The belt along a closed centre line `path` (k+1 points, the last the first again) whose outer face looks along
    `outs`: two halves from the pouch's middle round to the opposite side (each its own run of the belt chart; the two
    seams are behind the pouch and under the buckle)."""
    k = len(path) - 1
    h = k // 2
    parts = []
    for a, b in ((0, h), (h, k)):
        P, N = path[a:b + 1], outs[a:b + 1]
        L = arclen(P)[-1]
        parts.append(sweep('belt', P, N, BELT_W, BELT_T, C['belt'], 'web', n_prof=8, caps=False,
                           v_range=(0.0, min(1.0, L / 0.32))))
    return parts


def buckle_part(C, p, out, along, up=(0, 1.0, 0)):
    frame = np.stack([along, np.array(up, float), out], 1)
    return box_part('buckle', p + out * (BELT_T / 2 + BUCKLE[2] * 0.6), BUCKLE, frame, C['hard'], 'hard')


# ======================================================================================================================
# Worn: on a body, front or back
# ======================================================================================================================
def fold(w, names):
    """A body weights row folded onto the bones a waist bag may follow."""
    d = {}
    for j, bn in enumerate(names):
        if w[j] <= 1e-6:
            continue
        bn = bn if bn in BONES else 'Bip01_Pelvis'
        d[bn] = d.get(bn, 0.0) + w[j]
    tot = sum(d.values()) or 1.0
    return {k: v / tot for k, v in d.items()}


def worn_mesh(C, key):
    v = VARIANTS[key]
    body = B.body_of(v['body'])
    waist = Waist(body)
    belt = Belt(waist, v['back'])
    wrap = Wrap(belt, v['back'], POUCH['half'][0])
    pouch = [p.copy(fn=wrap) for p in build_pouch(C, v['back'])]
    # the pouch is rigid on the body's weights at its middle (the thighs folded into the pelvis: it does not swing
    # with a leg)
    _, _, w, _ = body.closest(belt.P[0], full=True)
    pw = fold(w, body.names)
    for t in ('Bip01_L_Thigh', 'Bip01_R_Thigh'):
        pw['Bip01_Pelvis'] = pw.get('Bip01_Pelvis', 0.0) + pw.pop(t, 0.0)
    pw = limit_weights(pw)
    # the belt: the body's weights along it, smoothed, blended into the pouch's behind the pouch and beside it
    rows = []
    for p in belt.P:
        _, _, w, _ = body.closest(p, full=True)
        rows.append(fold(w, body.names))
    names = sorted(set(BONES))
    M = smooth_rows(np.array([[r.get(b, 0.0) for b in names] for r in rows]), 2.0)
    hw = POUCH['half'][0]
    beta = 1 - smoothstep(hw - 0.010, hw + 0.035, np.abs(belt.s))
    belt_rows = []
    for row, bt in zip(M, beta):
        d = {b: float(x) * (1 - bt) for b, x in zip(names, row)}
        for b, x in pw.items():
            d[b] = d.get(b, 0.0) + x * bt
        belt_rows.append(limit_weights(d))
    bparts = belt_parts(C, belt.P, belt.out)
    p, o, t = belt.frame(belt.L / 2)
    buckle = buckle_part(C, p - o * (BELT_T / 2), o, t)
    parts = pouch + bparts + [buckle]
    m = Mesh(parts)
    weights = []
    for pt in pouch:
        weights += [pw] * len(pt.P)
    for pt in bparts:
        for q in np.array(pt.P):
            weights.append(belt_rows[int(np.argmin(((belt.P - q) ** 2).sum(1)))])
    k = int(np.argmin(np.abs(np.abs(belt.s) - belt.L / 2)))
    weights += [belt_rows[k]] * (3 * len(buckle.F))
    assert len(weights) == len(m.P)
    bones = sorted({b for d in weights for b in d})
    m.W = {b: np.array([d.get(b, 0.0) for d in weights]) for b in bones}
    return m


# ======================================================================================================================
# On the floor: the pouch on its back, the belt in a loop beside it
# ======================================================================================================================
def ground_mesh(C):
    yc = BELT_Y - POUCH_DROP[False]

    def lie(P):     # bag-local -> floor: the pouch's outer face up, its top toward -z
        P = np.asarray(P, float)
        return np.stack([P[:, 0], P[:, 2] + BELT_T, -(P[:, 1] - yc)], axis=1)
    parts = [p.copy(fn=lie) for p in build_pouch(C, False)]
    a, b, zc = GROUND_LOOP
    ths = np.linspace(0.0, 2 * math.pi, 49)
    path = np.stack([a * np.sin(ths), np.full(len(ths), BELT_T / 2), zc - b * np.cos(ths)], axis=1)
    outs = np.tile(np.array([0, 1.0, 0]), (len(ths), 1))
    parts += belt_parts(C, path, outs)
    p = path[24]
    parts.append(buckle_part(C, p - np.array([0, BELT_T / 2, 0]), np.array([0, 1.0, 0]), np.array([1.0, 0, 0]), up=(0, 0, 1.0)))
    m = Mesh(parts)
    m.W = {'Bip01_Pelvis': np.ones(len(m.P))}
    return m


# ======================================================================================================================
# Texture
# ======================================================================================================================
def zip_line(P, ch, t, s0=0.06, s1=0.94, pull=0.80):
    P.chart_line(ch, s0, t, s1, t, B.COL['binding'], 3.2)
    P.chart_line(ch, s0, t, s1, t, B.COL['zip'], 1.3, dash=(1.2, 0.8))
    px, py = ch.px(pull, t)
    P.rect(px - 2, py, px + 2, py + 9, B.COL['hard'])


def paint_atlas(C):
    P = B.Painter(C)
    for ch in C.values():
        if ch.mat == 'canvas':
            P.fabric(ch, B.COL['canvas'])
        elif ch.mat == 'padding':
            P.fabric(ch, B.COL['padding'], weave=4, mottle=3)
        elif ch.mat == 'base':
            P.fabric(ch, B.COL['base'], weave=2, mottle=4)
        elif ch.mat == 'web':
            P.webbing(ch, B.COL['web'])
        elif ch.mat == 'hard':
            P.flat(ch, B.COL['hard'], 2.0)
    for key in ('pouch_front', 'pouch_side', 'pouch_top', 'pocket_front', 'pocket_side', 'pocket_top'):
        P.piping(C[key])
        P.stitch_border(C[key], 4)
    # the main zip runs along the top of the pouch's front edge, the pocket's across its top
    zip_line(P, C['pouch_top'], 0.80)
    zip_line(P, C['pocket_front'], 0.08)
    # the team patch on the pocket, the acorn stencilled on it
    ch = C['pocket_front']
    cx, cy = ch.px(0.5, 0.55)
    pw, ph = 0.34 * (ch.rect[2] - ch.rect[0]), 0.56 * (ch.rect[3] - ch.rect[1])
    P.rect(cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2, B.COL['patch'])
    for (a, b, c2, d) in ((cx - pw / 2 + 2, cy - ph / 2 + 2, cx + pw / 2 - 2, cy - ph / 2 + 2),
                          (cx - pw / 2 + 2, cy + ph / 2 - 3, cx + pw / 2 - 2, cy + ph / 2 - 3),
                          (cx - pw / 2 + 2, cy - ph / 2 + 2, cx - pw / 2 + 2, cy + ph / 2 - 3),
                          (cx + pw / 2 - 2, cy - ph / 2 + 2, cx + pw / 2 - 2, cy + ph / 2 - 3)):
        P.line((a, b), (c2, d), (82, 86, 58), 1.0, dash=(2, 1.5))
    size = int(ph * 0.80)
    mask = B.acorn_mask(size) * (P.rng.random((size, size)) > 0.08)
    P.stamp(mask, cx, cy, B.COL['stencil'], 0.85)
    # the back panel: padded channels against the body
    ch = C['pouch_back']
    for s in (0.33, 0.67):
        P.chart_line(ch, s, 0.08, s, 0.92, (34, 36, 28), 2.4)
    # the belt: bar-tacks where it is sewn to the pouch's back, the rib of the webbing
    ch = C['belt']
    x0, y0, x1, y1 = ch.rect
    for frac in (0.03, 0.30):
        y = y0 + frac * (y1 - y0)
        P.line((x0 + 0.30 * (x1 - x0), y), (x0 + 0.70 * (x1 - x0), y), (44, 47, 32), 1.4)
    # the buckle: dark plastic, the release tabs lighter
    ch = C['hard']
    x0, y0, x1, y1 = ch.rect
    P.img[y0 + 4:y1 - 4, x0 + 3:x1 - 3] = (26, 26, 24)
    P.img[y0 + 8:y1 - 8, x0 + 2:x0 + 7] = (48, 49, 45)
    P.img[y0 + 8:y1 - 8, x1 - 7:x1 - 2] = (48, 49, 45)
    return P


class Subdivided:
    """A mesh with every triangle cut in four, for baking only: the backpack's occlusion samples the triangle centres,
    and the pouch's triangles are large beside its size (a coarse sampling shows as blotches)."""

    def __init__(self, mesh):
        P, N, UV, F = mesh.arrays()
        a, b, c = F[:, 0], F[:, 1], F[:, 2]
        n = len(P)
        k = np.arange(len(F))
        ab, bc, ca = n + 3 * k, n + 3 * k + 1, n + 3 * k + 2
        mid = lambda X: np.stack([(X[a] + X[b]) / 2, (X[b] + X[c]) / 2, (X[c] + X[a]) / 2], axis=1).reshape(-1, X.shape[1])
        self.P = np.vstack([P, mid(P)])
        self.N = units(np.vstack([N, mid(N)]))
        self.UV = np.vstack([UV, mid(UV)])
        self.F = np.concatenate([np.stack([a, ab, ca], 1), np.stack([ab, b, bc], 1), np.stack([ca, bc, c], 1),
                                 np.stack([ab, bc, ca], 1)])

    def arrays(self):
        return self.P, self.N, self.UV, self.F


def finish_atlas(P, gbuf):
    """Baked shading (as the backpack's): ambient occlusion, dirt toward the pouch's bottom and in the creases."""
    ao, ypos, cov = gbuf
    img = P.img
    ao_full = np.array(Image.fromarray(ao.astype(np.float32), 'F').resize((ATLAS, ATLAS), Image.BILINEAR))
    yp = np.array(Image.fromarray(ypos.astype(np.float32), 'F').resize((ATLAS, ATLAS), Image.BILINEAR))
    covf = np.array(Image.fromarray((cov * 255).astype(np.uint8)).resize((ATLAS, ATLAS), Image.BILINEAR)) / 255.0
    ao_full = np.where(covf > 0.01, ao_full / np.maximum(covf, 1e-3), 1.0)
    yp = np.where(covf > 0.01, yp / np.maximum(covf, 1e-3), BELT_Y)
    ao_full = B.blur(ao_full, 1.4)
    img *= (0.45 + 0.55 * np.clip(ao_full, 0, 1))[..., None]
    low = np.clip((BELT_Y - 0.030 - yp) / 0.035, 0, 1) ** 1.4
    crease = np.clip((0.82 - ao_full) / 0.4, 0, 1)
    speck = (P.rng.random((ATLAS, ATLAS)) > 0.5) * P.rng.random((ATLAS, ATLAS))
    a = np.clip((0.40 * low + 0.30 * crease) * (0.55 + 0.6 * speck), 0, 0.5)[..., None]
    img[:] = img * (1 - a) + np.array((70, 58, 40), float) * a
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), 'RGB')


# ======================================================================================================================
# Files
# ======================================================================================================================
def vanilla_parts(src):
    """(prefix text up to our mesh frame, suffix from AnimTicksPerSecond) of a vanilla fanny pack file, its texture
    reference made ours."""
    txt = B.read_text(os.path.join(VANILLA_BP, src))
    mm = re.search(r'^Frame (?!Dummy01\b|Translation_Data\b)(\w+) \{\n', txt, re.M)
    anim = txt.index('\nAnimTicksPerSecond') + 1
    prefix, suffix = txt[:mm.start()], txt[anim:]
    prefix = re.sub(r'TextureFilename \{\n(\s*)"[^"]*";', lambda g: 'TextureFilename {\n%s"%s";' % (g.group(1), TEX_REF),
                    prefix)
    return prefix, suffix


def write_x(key, mesh):
    v = VARIANTS[key]
    prefix, suffix = vanilla_parts(v['src'])
    material = re.search(r'^Material (\S+) \{', prefix, re.M).group(1)
    body = B.body_of(v['body'])
    mats = {b: body.mats[b] for b in mesh.W if (mesh.W[b] > 0).any()}
    frame = os.path.splitext(os.path.basename(OUT[key]))[0]
    text = prefix + B.mesh_frame_text(frame, mesh, mats, material) + '\n' + suffix
    os.makedirs(os.path.dirname(OUT[key]), exist_ok=True)
    with open(OUT[key], 'wb') as f:
        f.write(text.encode('latin-1'))
    return len(mesh.P), len(mesh.F)


def write_fbx(mesh):
    P, N, UV, F = mesh.arrays()
    zc = (P[:, 2].min() + P[:, 2].max()) / 2
    raw = B.ground_raw(P, zc, P[:, 1].min())
    rawN = np.stack([-N[:, 2], N[:, 0], N[:, 1]], axis=1)

    def rename(s):   # names and texture paths: nothing of the vanilla file's author or art remains
        s = s.replace(b'M_FannyPackFront_Ground', (NAME + '_Ground').encode())
        s = re.sub(rb'[^\x00\x01"]*FannyPack\.png', TEX_REF.encode(), s)
        s = re.sub(rb'[A-Za-z]:\\[^\x00]*\.FBX', (NAME + '_Ground.fbx').encode(), s, flags=re.I)
        return s.replace(b'19 - Defaultaaa', (NAME + '_Mat').encode()).replace(b'Map #161', (NAME + '_Map').encode())
    return B.ground_fbx(VANILLA_GROUND, OUT['G'], raw, rawN, UV, F, rename)


def write_clothing():
    for fname, (guid, male, female) in CLOTHING.items():
        text = (
            '<?xml version="1.0" encoding="utf-8"?>\n<clothingItem>\n'
            '\t<m_MaleModel>media\\models_X\\Skinned\\BackPacks\\%s.X</m_MaleModel>\n'
            '\t<m_FemaleModel>media\\models_X\\Skinned\\BackPacks\\%s.X</m_FemaleModel>\n'
            '\t<m_AltMaleModel></m_AltMaleModel>\n'
            '\t<m_AltFemaleModel></m_AltFemaleModel>\n'
            '\t<m_GUID>%s</m_GUID>\n'
            '\t<m_Static>false</m_Static>\n'
            '\t<m_AllowRandomHue>false</m_AllowRandomHue>\n'
            '\t<m_AllowRandomTint>false</m_AllowRandomTint>\n'
            '\t<m_AttachBone></m_AttachBone>\n'
            '\t<textureChoices>clothes\\bag\\%s</textureChoices>\n'
            '</clothingItem>') % (male, female, guid, NAME.lower())
        B.write_text(os.path.join(CLOTHING_DIR, fname + '.xml'), text, bom=True)
    B.merge_guid_table(OUT['GUID'], {f: g[0] for f, g in CLOTHING.items()})


def write_script():
    B.write_text(OUT['SCRIPT'], (
        'module OperationAcorn\n{\n'
        '\t/* The research team waist bag lying on the floor (the worn bag\'s pouch on its back, the belt beside it). */\n'
        '\tmodel OA_ResearchWaist_Ground\n\t{\n'
        '\t\tmesh = WorldItems/Clothing/OA_ResearchWaist_Ground,\n'
        '\t\ttexture = Clothes/Bag/OA_ResearchWaist,\n'
        '\t\tscale = 0.4,\n\t}\n}\n'))


# ======================================================================================================================
# Previews and the icon source
# ======================================================================================================================
# the legs in a stride and seated (the bag follows the hips; the arms hang down)
LEG_POSES = {
    'rest': {},
    'stride': {'L': -32, 'R': 22},
    'sit': {'L': -80, 'R': -80},
}


def pose_transforms(body, pose):
    tf = {}
    for b, (R, o) in B.bone_transforms(body, 'rest').items():
        tf[b] = (R, o)
    for side, deg in LEG_POSES[pose].items():
        R = B.rot((1, 0, 0), deg)
        o = body.origin('Bip01_%s_Thigh' % side)
        for b in ('Thigh', 'Calf', 'Foot', 'Toe0'):
            tf['Bip01_%s_%s' % (side, b)] = (R, o)
    return tf


def posed(mesh, body, pose):
    tf = pose_transforms(body, pose)
    P, N = B.skin(mesh.P, mesh.N, mesh.W, tf)
    bW = {b: body.W[:, j] for j, b in enumerate(body.names)}
    bP, bN = B.skin(body.V, body.VN, bW, tf)
    return (P, N, mesh.UV, mesh.F), (bP, bN, body.T, B.BODY_COL)


def wearer_tiles(mesh, body, tex, size, views, pose='rest'):
    m, bd = posed(mesh, body, pose)
    tiles = []
    for lab, d in views:
        region = np.concatenate([m[0], bd[0][(bd[0][:, 1] > 0.40) & (bd[0][:, 1] < 0.70) & (np.abs(bd[0][:, 0]) < 0.22)]])
        fr = B.frame_for(region, d, pad=1.06)
        tiles.append(B.label(B.render([m], tex, d, (0, 1, 0), size, bodies=[bd], frame=fr), lab))
    return tiles


def make_previews(meshes, tex):
    male, female = B.body_of('MaleBody.x'), B.body_of('FemaleBody.x')
    S = 340
    tiles = []
    for key, body, nm in (('FM', male, 'M front'), ('FF', female, 'F front')):
        tiles += wearer_tiles(meshes[key], body, tex, S, [(nm + ', front', (0, 0, 1)), (nm + ', left side', (-1, 0, 0)),
                                                          (nm + ', game camera front-left', B.iso_dir(-140)),
                                                          (nm + ', game camera behind-left', B.iso_dir(-40))])
        tiles += wearer_tiles(meshes[key], body, tex, S, [(nm + ', stride, side', (-1, 0, 0))], pose='stride')
        tiles += wearer_tiles(meshes[key], body, tex, S, [(nm + ', seated, side', (-1, 0, 0))], pose='sit')
    for key, body, nm in (('BM', male, 'M back'), ('BF', female, 'F back')):
        tiles += wearer_tiles(meshes[key], body, tex, S, [(nm + ', back', (0, 0, -1)), (nm + ', left side', (-1, 0, 0)),
                                                          (nm + ', game camera behind-left', B.iso_dir(-40)),
                                                          (nm + ', game camera front-left', B.iso_dir(-140))])
        tiles += wearer_tiles(meshes[key], body, tex, S, [(nm + ', stride, side', (-1, 0, 0))], pose='stride')
        tiles += wearer_tiles(meshes[key], body, tex, S, [(nm + ', seated, side', (-1, 0, 0))], pose='sit')
    g = meshes['G'].arrays()
    tiles.append(B.label(B.render([g], tex, B.iso_dir(-35), (0, 1, 0), S), 'ground model'))
    tiles.append(B.label(B.render([g], tex, B.iso_dir(145), (0, 1, 0), S), 'ground model, other side'))
    B.sheet(tiles, 6, S).save(PREVIEW)


def make_icon_source(meshes, tex, size=512):
    """tools/waistbag_icon_source.png: the bag as worn, without the wearer, from the front and a little above (the
    pocket with the team mark, the belt round behind), on a clear background (alpha from a black and a white render,
    as the backpack's)."""
    m = meshes['FM'].arrays()
    d = unit((0.30, -0.42, 1.0))
    black = np.asarray(B.render([m], tex, d, (0, 1, 0), size, ss=3, bg=(0, 0, 0)), float)
    white = np.asarray(B.render([m], tex, d, (0, 1, 0), size, ss=3, bg=(255, 255, 255)), float)
    alpha = np.clip(1.0 - (white - black).mean(-1) / 255.0, 0.0, 1.0)
    colour = np.where(alpha[..., None] > 1e-3, black / np.maximum(alpha[..., None], 1e-3), 0.0)
    im = Image.fromarray(np.dstack([np.clip(colour, 0, 255), alpha * 255]).astype(np.uint8), 'RGBA')
    im.crop(im.getbbox()).save(ICON_SOURCE)


# ======================================================================================================================
# Build
# ======================================================================================================================
def build_meshes():
    C = define_charts()
    used = B.pack_charts(list(C.values()), size=ATLAS)
    meshes = {key: worn_mesh(C, key) for key in VARIANTS}
    meshes['G'] = ground_mesh(C)
    return C, meshes, used


def build_all():
    for p in (VANILLA_GROUND, os.path.join(B.SKINNED, 'MaleBody.x'), os.path.join(VANILLA_BP, 'M_FannyPackFront.x')):
        if not os.path.exists(p):
            sys.exit('vanilla reference missing (set PZ_DIR): ' + p)
    C, meshes, used = build_meshes()
    print('atlas: %d charts, %d of %d rows used' % (len(C), used, ATLAS))
    for k in VARIANTS:
        nv, nf = write_x(k, meshes[k])
        print('%-3s %5d vertices %5d faces  %s' % (k, nv, nf, os.path.relpath(OUT[k], ROOT)))
    nv, nf = write_fbx(meshes['G'])
    print('G   %5d vertices %5d faces  %s' % (nv, nf, os.path.relpath(OUT['G'], ROOT)))
    tex = finish_atlas(paint_atlas(C), B.uv_gbuffer(Subdivided(meshes['FM'])))
    os.makedirs(os.path.dirname(OUT['TEX']), exist_ok=True)
    shipped = tex.resize((TEX_SIZE, TEX_SIZE), Image.LANCZOS)
    shipped.save(OUT['TEX'], optimize=True)
    write_clothing()
    write_script()
    # the previews show the texture the game gets; the icon is drawn from the full painting
    make_previews(meshes, np.array(shipped))
    print('preview', os.path.relpath(PREVIEW, ROOT))
    make_icon_source(meshes, np.array(tex))
    print('icon source', os.path.relpath(ICON_SOURCE, ROOT))


# ======================================================================================================================
# --check
# ======================================================================================================================
def check_x(key):
    v = VARIANTS[key]
    raw = open(OUT[key], 'rb').read()
    B.need(raw.startswith(b'xof 0303txt 0032'), 'header')
    txt = raw.decode('latin-1')
    B.need('\r' not in txt, 'unexpected CR')
    stripped = re.sub(r'"[^"]*"', '""', txt)
    B.need(stripped.count('{') == stripped.count('}'), 'unbalanced braces')
    frames = set(re.findall(r'^\s*Frame (\w+) \{', txt, re.M))
    frame = os.path.splitext(os.path.basename(OUT[key]))[0]
    B.need(frame in frames, 'mesh frame missing')
    d = B.parse_x(OUT[key])
    V, T, N, UV = d['V'], d['T'], d['N'], d['UV']
    B.need(T.min() >= 0 and T.max() < len(V), 'face index out of range')
    B.need(N is not None and len(N) == len(V) and np.abs(np.linalg.norm(N, axis=1) - 1).max() < 1e-3, 'normals')
    c = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    agree = (c * N[T].mean(1)).sum(1) > 0
    B.need(agree.mean() > 0.995, '%d faces wound against their normals' % (~agree).sum())
    B.need(UV is not None and len(UV) == len(V) and UV.min() >= 0 and UV.max() <= 1, 'uv')
    B.need('"%s"' % TEX_REF in txt, 'texture filename')
    body = B.body_of(v['body'])
    total = np.zeros(len(V))
    count = np.zeros(len(V), int)
    for b, (idx, w, mat) in d['bones'].items():
        B.need(b in frames and b in BONES, 'bone %s' % b)
        B.need(mat == body.mats[b], 'offset matrix of %s is not the body\'s' % b)
        total[idx] += w
        count[idx] += 1
    B.need(np.abs(total - 1).max() < 1e-4, 'weights do not sum to 1')
    B.need(count.max() <= B.MAX_WEIGHTS, 'a vertex has %d bones' % count.max())
    B.need('AnimTicksPerSecond' in txt and 'AnimationSet' in txt, 'animation set missing')
    worst = min(body.closest(p, full=True)[3] for p in V[::2])
    B.need(worst > 0.0015, 'a vertex is %.4f from the body surface (inside or touching)' % worst)
    return len(V), len(T)


def check_files():
    B.need(Image.open(OUT['TEX']).size == (TEX_SIZE, TEX_SIZE), 'texture size')
    table = open(OUT['GUID'], encoding='utf-8').read()
    for fname, (guid, male, female) in CLOTHING.items():
        xml = open(os.path.join(CLOTHING_DIR, fname + '.xml'), encoding='utf-8-sig').read()
        B.need('<m_GUID>%s</m_GUID>' % guid in xml, fname + ': guid')
        B.need('media/clothing/clothingItems/%s.xml</path>\n\t\t<guid>%s</guid>' % (fname, guid) in table,
               fname + ': not in fileGuidTable')
        for m in (male, female):
            B.need(os.path.exists(os.path.join(SKINNED_DIR, m + '.x')), fname + ': model ' + m + ' missing')
    sc = open(OUT['SCRIPT'], encoding='utf-8').read()
    B.need('mesh = WorldItems/Clothing/%s_Ground' % NAME in sc and sc.count('{') == sc.count('}'), 'model script')
    ver, nodes = B.fbx_read(open(OUT['G'], 'rb').read())
    B.need(not any(re.match(rb'[A-Za-z]:\\', s) for s in B.fbx_strings(nodes)), 'an absolute path of the vanilla file is left')
    geo = [c for c in B.fbx_find(nodes, 'Objects')[2] if c[0] == 'Geometry'][0]
    V = np.array({c[0]: c for c in geo[2]}['Vertices'][1][0][1]).reshape(-1, 3)
    B.need(abs(V[:, 2].min()) < 0.1 and 3 < V[:, 2].max() < 12, 'the floor model lies on z = 0, a few units high')


def check_all():
    bad = 0
    for k in VARIANTS:
        try:
            nv, nf = check_x(k)
            print('ok   %-28s %d vertices %d faces' % (os.path.basename(OUT[k]), nv, nf))
        except (B.Fail, FileNotFoundError, AttributeError, ValueError, IndexError, KeyError) as e:
            bad += 1
            print('FAIL %-28s %s: %s' % (os.path.basename(OUT[k]), type(e).__name__, e))
    try:
        check_files()
        print('ok   floor model, texture, clothing xml, guid table, script')
    except (B.Fail, FileNotFoundError, AttributeError, ValueError, IndexError, KeyError) as e:
        bad += 1
        print('FAIL files %s: %s' % (type(e).__name__, e))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='validate the produced files instead of building')
    args = ap.parse_args()
    if args.check:
        sys.exit(check_all())
    build_all()
    sys.exit(check_all())


if __name__ == '__main__':
    main()
