#!/usr/bin/env python3
"""Builds the Operation Acorn research team backpack ('연구팀 배낭'): meshes, texture and the files the game needs.

    py tools/backpack_mesh.py            build everything and render tools/backpack_preview.png
    py tools/backpack_mesh.py --check    re-parse every produced file and assert it is consistent (no building)

What it writes (all under OperationAcorn/42/media):
    models_X/Skinned/BackPacks/OA_ResearchPack_M.x, _F.x, _LHand.x, _RHand.x   worn / carried skinned meshes
    models_X/WorldItems/Clothing/OA_ResearchPack_Ground.fbx                     the floor model
    textures/Clothes/Bag/OA_ResearchPack.png                                    256x256 atlas
    clothing/clothingItems/OA_Bag_ResearchPack.xml (+ _LHand, _RHand)           the clothing items
    fileGuidTable.xml                                                           registers the three clothing items
    scripts/OA_backpack_models.txt                                              the floor model script

The mesh is our own low-poly pack (boxes, prisms and strips below). The only vanilla content copied is structure, not art:
the skeleton frames, templates and animation set of the vanilla pack .x files are spliced around our mesh frame, the
bone offset matrices are reused verbatim for the same bone, and the floor .fbx keeps the vanilla node layout and unit
settings (we replace its geometry). The generator therefore needs the game installed (PZ_DIR env var, default is the
Steam folder). Every vertex is weighted 1.0 to a single bone (Bip01_BackPack worn, Bip01_Prop1/Prop2 in the hands).

Model space of the worn .x files: x lateral (left positive), y up, z toward the back; the torso is around z 0.
"""
import argparse
import math
import os
import re
import struct
import sys
import zlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MEDIA = os.path.join(ROOT, 'OperationAcorn', '42', 'media')
PZ_DIR = os.environ.get('PZ_DIR', r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid')
VANILLA_BP = os.path.join(PZ_DIR, 'media', 'models_X', 'Skinned', 'BackPacks')
VANILLA_GROUND = os.path.join(PZ_DIR, 'media', 'models_X', 'WorldItems', 'Clothing', 'ALICE_Pack_Ground.fbx')
PREVIEW = os.path.join(HERE, 'backpack_preview.png')

NAME = 'OA_ResearchPack'
TEX_REF = NAME + '.png'
OUT = {
    'M': os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', NAME + '_M.x'),
    'F': os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', NAME + '_F.x'),
    'L': os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', NAME + '_LHand.x'),
    'R': os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', NAME + '_RHand.x'),
    'G': os.path.join(MEDIA, 'models_X', 'WorldItems', 'Clothing', NAME + '_Ground.fbx'),
    'TEX': os.path.join(MEDIA, 'textures', 'Clothes', 'Bag', NAME + '.png'),
    'GUID': os.path.join(MEDIA, 'fileGuidTable.xml'),
    'SCRIPT': os.path.join(MEDIA, 'scripts', 'OA_backpack_models.txt'),
}
CLOTHING_DIR = os.path.join(MEDIA, 'clothing', 'clothingItems')
# vanilla source of the skeleton/animation text, the bone the mesh is weighted to, and the bone's offset matrix source
VARIANTS = {
    'M': dict(src='M_ALICE_Pack.x', bone='Bip01_BackPack', frame=NAME + '_M'),
    'F': dict(src='F_ALICE_Pack.x', bone='Bip01_BackPack', frame=NAME + '_F'),
    'L': dict(src='ALICE_Pack_LHand.x', bone='Bip01_Prop2', frame=NAME + '_LHand'),
    'R': dict(src='ALICE_Pack_RHand.x', bone='Bip01_Prop1', frame=NAME + '_RHand'),
}
CLOTHING = {  # file -> (guid, male model, female model)
    'OA_Bag_ResearchPack': ('4fbba45f-fbcf-4f9e-a4bb-cfadf3fbbe5d', NAME + '_M', NAME + '_F'),
    'OA_Bag_ResearchPack_LHand': ('8a9c34b3-a4b9-4341-80c4-3c11785722d6', NAME + '_LHand', NAME + '_LHand'),
    'OA_Bag_ResearchPack_RHand': ('13b5d057-5a2d-436e-8d37-8dbac94fa075', NAME + '_RHand', NAME + '_RHand'),
}

# ----------------------------------------------------------------------------------------------------------------------
# Texture atlas layout (pixels, 256x256, origin top left). Every face of the mesh maps into one of these rectangles.
# ----------------------------------------------------------------------------------------------------------------------
ATLAS = 256
RECT = {
    'front': (0, 0, 100, 100),      # sack front, olive canvas
    'side': (100, 0, 170, 100),     # sack sides
    'back': (170, 0, 256, 100),     # padded back panel (dark mesh)
    'flap': (0, 100, 100, 250),     # top flap: top part, then the drape with the acorn
    'strap': (100, 100, 126, 250),  # shoulder strap, darker and padded
    'pocket': (126, 100, 170, 160),  # front pocket
    'lid': (140, 162, 170, 192),    # pocket lid with a snap
    'cham': (128, 162, 138, 250),   # chamfer strips of the sack
    'webbing': (170, 100, 194, 190),  # webbing strip on the sides
    'base': (146, 196, 194, 250),   # bottom and top caps, dark coated nylon
    'buckle': (196, 140, 226, 170),  # the metal buckle on the flap strap
}
SWATCH_ORIGIN = (196, 104)
SWATCH_CELL = 14
SWATCH = {'edge': (0, 0), 'olive': (1, 0), 'tan': (2, 0), 'metal': (3, 0),
          'black': (0, 1), 'dark': (1, 1), 'brown': (2, 1), 'pocket': (3, 1)}
COL = {  # base colours
    'olive': (92, 95, 62), 'edge': (74, 77, 50), 'tan': (150, 136, 98), 'metal': (122, 124, 118),
    'black': (40, 40, 36), 'dark': (66, 70, 46), 'brown': (84, 68, 46), 'pocket': (86, 90, 58),
}


def swatch_rect(key):
    i, j = SWATCH[key]
    x0 = SWATCH_ORIGIN[0] + i * SWATCH_CELL
    y0 = SWATCH_ORIGIN[1] + j * SWATCH_CELL
    return (x0 + 4, y0 + 4, x0 + SWATCH_CELL - 4, y0 + SWATCH_CELL - 4)


def rect_of(key):
    return RECT[key] if key in RECT else swatch_rect(key)


# ----------------------------------------------------------------------------------------------------------------------
# Mesh building
# ----------------------------------------------------------------------------------------------------------------------
class Mesh:
    """Flat shaded triangle soup: every polygon owns its vertices, so positions, normals and uvs stay parallel lists."""

    def __init__(self):
        self.P = []
        self.N = []
        self.UV = []
        self.TAG = []
        self.F = []

    def poly(self, pts, uvs, hint, tag=''):
        """A convex polygon. Winding is fixed so that cross(p1-p0, p2-p0) points along `hint` (outward)."""
        p = [np.array(q, float) for q in pts]
        n = np.zeros(3)
        for i in range(len(p)):  # Newell
            a, b = p[i], p[(i + 1) % len(p)]
            n += np.array([(a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]), (a[0] - b[0]) * (a[1] + b[1])])
        if np.linalg.norm(n) < 1e-12:
            return
        n /= np.linalg.norm(n)
        order = list(range(len(p)))
        if np.dot(n, hint) < 0:
            order.reverse()
            n = -n
        base = len(self.P)
        for k in order:
            self.P.append(p[k])
            self.N.append(n)
            self.UV.append(uvs[k])
            self.TAG.append(tag)
        for i in range(1, len(order) - 1):
            self.F.append((base, base + i, base + i + 1))

    def arrays(self):
        return (np.array(self.P, float), np.array(self.N, float), np.array(self.UV, float),
                np.array(self.F, int))

    def transformed(self, fn_pos, fn_dir=None, flip=False):
        """A copy with positions mapped by fn_pos (Nx3 -> Nx3) and normals by fn_dir (default fn_pos minus its offset)."""
        m = Mesh()
        P = np.array(self.P)
        N = np.array(self.N)
        m.P = list(fn_pos(P))
        m.N = list(fn_dir(N)) if fn_dir else list(fn_pos(N) - fn_pos(np.zeros((1, 3))))
        m.UV = list(self.UV)
        m.TAG = list(self.TAG)
        m.F = [(a, c, b) if flip else (a, b, c) for a, b, c in self.F]
        return m


def px_uv(rect, s, t):
    """Atlas uv (.x convention: v grows downward) for the normalised position (s, t) inside a pixel rect."""
    x0, y0, x1, y1 = rect
    x0, y0, x1, y1 = x0 + 1, y0 + 1, x1 - 1, y1 - 1  # keep one pixel off the neighbours
    return ((x0 + s * (x1 - x0)) / ATLAS, (y0 + t * (y1 - y0)) / ATLAS)


# default texture axes per face normal: screen right / down while looking at the face from outside
FACE_AXES = {
    '+z': ((-1, 0, 0), (0, -1, 0)), '-z': ((1, 0, 0), (0, -1, 0)),
    '+x': ((0, 0, 1), (0, -1, 0)), '-x': ((0, 0, -1), (0, -1, 0)),
    '+y': ((-1, 0, 0), (0, 0, 1)), '-y': ((-1, 0, 0), (0, 0, -1)),
}


def mapped_uvs(pts, rect_key, face):
    """Maps a face's own bounding box onto its atlas rect (planar projection along the face's texture axes)."""
    ua, va = FACE_AXES[face]
    ua, va = np.array(ua, float), np.array(va, float)
    s = np.array([np.dot(p, ua) for p in pts])
    t = np.array([np.dot(p, va) for p in pts])
    ds = (s.max() - s.min()) or 1.0
    dt = (t.max() - t.min()) or 1.0
    rect = rect_of(rect_key)
    return [px_uv(rect, (s[i] - s.min()) / ds, (t[i] - t.min()) / dt) for i in range(len(pts))]


def dominant_face(n):
    k = int(np.argmax(np.abs(n)))
    return ('+' if n[k] > 0 else '-') + 'xyz'[k]


def hexa(m, y0, y1, r0, r1, faces, tag=''):
    """Frustum-like solid: rectangle r=(x0, x1, z0, z1) at height y0 and another at y1.
    faces maps '+x','-x','+y','-y','+z','-z' to an atlas rect key; missing faces are not built."""
    def corners(y, r):
        x0, x1, z0, z1 = r
        return [(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)]
    b, t = corners(y0, r0), corners(y1, r1)
    allp = np.array(b + t)
    centre = allp.mean(0)
    quads = {
        '-y': [b[0], b[1], b[2], b[3]], '+y': [t[0], t[1], t[2], t[3]],
        '-z': [b[0], b[1], t[1], t[0]], '+z': [b[3], b[2], t[2], t[3]],
        '-x': [b[0], b[3], t[3], t[0]], '+x': [b[1], b[2], t[2], t[1]],
    }
    for f, key in faces.items():
        pts = quads[f]
        hint = np.mean(pts, axis=0) - centre
        m.poly(pts, mapped_uvs(pts, key, f), hint, tag)


def prism(m, y0, y1, ring0, ring1, side_keys, cap_key, tag=''):
    """Chamfered sack: two 8-point rings (x, z) at y0/y1. side_keys[i] is the atlas key of side i."""
    def ring(r):
        xh, z0, z1, ch = r
        return [(xh - ch, z1), (-(xh - ch), z1), (-xh, z1 - ch), (-xh, z0 + ch),
                (-(xh - ch), z0), (xh - ch, z0), (xh, z0 + ch), (xh, z1 - ch)]
    a, b = ring(ring0), ring(ring1)
    centre = np.array([0, (y0 + y1) / 2, (ring0[1] + ring0[2]) / 2])
    for i in range(8):
        j = (i + 1) % 8
        pts = [(a[i][0], y0, a[i][1]), (a[j][0], y0, a[j][1]), (b[j][0], y1, b[j][1]), (b[i][0], y1, b[i][1])]
        face = dominant_face(np.cross(np.array(pts[1]) - np.array(pts[0]), np.array(pts[3]) - np.array(pts[0])))
        # the side's own outward direction (dominant axis of the hint), used to pick the texture axes
        hint = np.mean(pts, axis=0) - centre
        fdir = dominant_face(hint * np.array([1, 0, 1]))
        m.poly(pts, mapped_uvs(pts, side_keys[i], fdir), hint, tag)
    for y, r, face in ((y0, a, '-y'), (y1, b, '+y')):
        pts = [(p[0], y, p[1]) for p in r]
        m.poly(pts, mapped_uvs(pts, cap_key, face), np.array([0, -1 if face == '-y' else 1, 0]), tag)


def strip(m, path, xc, width, thick, inside, rect_key, s_range=None, total=None, edge_key='edge', caps=(), tag=''):
    """A band that follows `path` (list of (z, y)) at lateral centre xc: outer face with texture running along the path,
    plus the two thin edge faces. `inside` is a (z, y) point on the hollow side, normals point away from it.
    s_range/total: texture v is the arc length / total mapped into the rect (so several strips share one rect)."""
    P = [np.array(p, float) for p in path]
    n = len(P)
    seg = [P[i + 1] - P[i] for i in range(n - 1)]
    ins = np.array(inside, float)
    seg_n = []
    for i in range(n - 1):
        d = seg[i] / np.linalg.norm(seg[i])
        nn = np.array([d[1], -d[0]])
        if np.dot(nn, (P[i] + P[i + 1]) / 2 - ins) < 0:
            nn = -nn
        seg_n.append(nn)
    vn = []  # mitered vertex offsets (unit-distance along both neighbouring normals)
    for i in range(n):
        if i == 0:
            vn.append(seg_n[0])
        elif i == n - 1:
            vn.append(seg_n[-1])
        else:
            s = seg_n[i - 1] + seg_n[i]
            vn.append(s / (1 + np.dot(seg_n[i - 1], seg_n[i])))
    inner = [P[i] - vn[i] * thick for i in range(n)]
    lens = [0.0]
    for i in range(n - 1):
        lens.append(lens[-1] + np.linalg.norm(seg[i]))
    total = total or lens[-1]
    rect = rect_of(rect_key)
    erect = rect_of(edge_key)
    xl, xr = xc + width / 2, xc - width / 2  # +x is the wearer's left; texture u grows toward -x

    def v3(x, q):
        return (x, q[1], q[0])
    for i in range(n - 1):
        outer = [v3(xl, P[i]), v3(xl, P[i + 1]), v3(xr, P[i + 1]), v3(xr, P[i])]
        s0 = lens[i] / total
        s1 = lens[i + 1] / total
        uvs = [px_uv(rect, 0, s0), px_uv(rect, 0, s1), px_uv(rect, 1, s1), px_uv(rect, 1, s0)]
        hint = np.array([0, seg_n[i][1], seg_n[i][0]])
        m.poly(outer, uvs, hint, tag)
        for x, hx in ((xl, 1), (xr, -1)):
            q = [v3(x, P[i]), v3(x, P[i + 1]), v3(x, inner[i + 1]), v3(x, inner[i])]
            m.poly(q, [px_uv(erect, .5, .5)] * 4, np.array([hx, 0, 0]), tag)
    for idx in caps:  # closing the band at an end
        if idx == 'start':
            a, b, nn = 0, 0, -seg[0] / np.linalg.norm(seg[0])
        else:
            a, b, nn = n - 1, n - 1, seg[-1] / np.linalg.norm(seg[-1])
        q = [v3(xl, P[a]), v3(xr, P[a]), v3(xr, inner[a]), v3(xl, inner[a])]
        m.poly(q, [px_uv(erect, .5, .5)] * 4, np.array([0, nn[1], nn[0]]), tag)
    return lens[-1]


# --- the pack -----------------------------------------------------------------------------------------------------------
Z_BACK = 0.075                       # back panel plane
Y_BOT, Y_TOP = 0.565, 0.845          # sack bottom and top
FLAP = [(0.078, 0.846), (0.094, 0.872), (0.258, 0.872), (0.290, 0.846), (0.288, 0.700)]  # (z, y) outer surface
FLAP_X = 0.118                       # flap half width
FLAP_THICK = 0.010
STRAP_WORN = [(0.078, 0.800), (0.035, 0.830), (-0.030, 0.795), (-0.046, 0.700), (-0.010, 0.605), (0.076, 0.592)]
STRAP_GROUND = [(0.078, 0.800), (0.045, 0.812), (0.026, 0.730), (0.040, 0.640), (0.076, 0.592)]
STRAP_X, STRAP_W, STRAP_T = 0.072, 0.044, 0.010
GRIP_ON_STRAP = (0.036, 0.771)       # (z, y) on the hanging strap loop of the carried pack: where the hand holds it
Y_SHIFT = -0.010                     # the whole pack sits a little lower than drawn below, clear of the back of the head
POCKET_X = (0.042, 0.118)
LOOP_Y = (0.665, 0.745)


def sack_x(y):
    return 0.120 + 0.006 * (y - Y_BOT) / (Y_TOP - Y_BOT)


def sack_front(y):
    return 0.262 + 0.014 * (y - Y_BOT) / (Y_TOP - Y_BOT)


def build_pack(ground=False):
    m = Mesh()
    # main sack, chamfered; sides: 0 front, 1 chamfer, 2 -x side, 3 chamfer, 4 back, 5 chamfer, 6 +x side, 7 chamfer
    keys = ['front', 'cham', 'side', 'cham', 'back', 'cham', 'side', 'cham']
    prism(m, Y_BOT, Y_TOP, (0.120, Z_BACK, 0.262, 0.020), (0.126, Z_BACK, 0.276, 0.022), keys, 'base', 'sack')
    # top flap with the acorn on its drape
    s_total = sum(math.dist(FLAP[i], FLAP[i + 1]) for i in range(len(FLAP) - 1))
    strip(m, FLAP, 0.0, 2 * FLAP_X, FLAP_THICK, (0.18, 0.72), 'flap', total=s_total, caps=('end',), tag='flap')
    # buckle: a strap down the drape onto the sack, and the buckle plate on it
    hexa(m, 0.600, 0.745, (-0.013, 0.013, 0.264, 0.270), (-0.013, 0.013, 0.287, 0.293),
         {'+z': 'strap', '+x': 'edge', '-x': 'edge', '-y': 'edge'}, 'buckle')
    hexa(m, 0.622, 0.660, (-0.021, 0.021, 0.271, 0.282), (-0.021, 0.021, 0.273, 0.284),
         {'+z': 'buckle', '+x': 'metal', '-x': 'metal', '+y': 'metal', '-y': 'metal'}, 'buckle')
    # two front side pockets, each with a lid
    for sgn in (1, -1):
        x0, x1 = sorted((sgn * POCKET_X[0], sgn * POCKET_X[1]))
        xi0, xi1 = (x0 + 0.003, x1 - 0.002) if sgn > 0 else (x0 + 0.002, x1 - 0.003)
        side = '+x' if sgn > 0 else '-x'
        inner_side = '-x' if sgn > 0 else '+x'
        hexa(m, 0.572, 0.690, (x0, x1, 0.240, 0.306), (xi0, xi1, 0.240, 0.300),
             {'+z': 'pocket', side: 'pocket', inner_side: 'pocket', '-y': 'base'}, 'pocket')
        hexa(m, 0.640, 0.692, (x0 - 0.002, x1 + 0.002, 0.290, 0.310), (x0 - 0.002, x1 + 0.002, 0.290, 0.310),
             {'+z': 'lid', side: 'edge', inner_side: 'edge', '-y': 'edge'}, 'lid')
    # webbing strips on both sides, two loops each (where canteens hang)
    for sgn in (1, -1):
        face = '+x' if sgn > 0 else '-x'
        zs = (0.150, 0.197)
        ya, yb = 0.600, 0.815

        def xr(y, a, b):
            lo, hi = sack_x(y) + a, sack_x(y) + b
            return (lo, hi) if sgn > 0 else (-hi, -lo)
        hexa(m, ya, yb, xr(ya, -0.001, 0.005) + zs, xr(yb, -0.001, 0.005) + zs,
             {face: 'webbing', '+z': 'tan', '-z': 'tan', '+y': 'tan', '-y': 'tan'}, 'webbing')
        for y in LOOP_Y:
            hexa(m, y - 0.011, y + 0.011, xr(y - 0.011, 0.002, 0.020) + (0.138, 0.209),
                 xr(y + 0.011, 0.002, 0.020) + (0.138, 0.209),
                 {face: 'tan', '+z': 'tan', '-z': 'tan', '+y': 'tan', '-y': 'tan'}, 'loop')
    # shoulder straps, wrapped around the body (flat against the panel on the ground model)
    path = STRAP_GROUND if ground else STRAP_WORN
    inside = (0.06, 0.70) if ground else (0.0, 0.70)
    for sgn in (1, -1):
        strip(m, path, sgn * STRAP_X, STRAP_W, STRAP_T, inside, 'strap', tag='strap')
    m.P = [p + np.array([0.0, Y_SHIFT, 0.0]) for p in m.P]
    return m


# ----------------------------------------------------------------------------------------------------------------------
# Variant transforms
# ----------------------------------------------------------------------------------------------------------------------
FEMALE_SHIFT = np.array([0.0, 0.0099, -0.0092])  # mean difference of the vanilla F_ALICE_Pack to M_ALICE_Pack
FEMALE_CHEST = -0.012                            # strap parts in front of the chest are pushed forward further
# Rigid transform of the vanilla pack into the right-hand carry pose (fitted from ALICE_Pack_RHand.x against the worn pack:
# hand = worn @ R.T + T), and the point of the worn pack the hand holds (the Prop1 bone origin expressed in worn space).
HAND_R = np.array([[0.42794772, 0.62795350, -0.65002704],
                   [0.71353707, 0.20669363, 0.66943454],
                   [0.55473021, -0.75030137, -0.35961402]])
HAND_T = np.array([-0.90079746, 0.43881414, 0.60467455])
HAND_GRIP = np.array([0.076, 0.751, 0.075])


def worn_variant(m, female):
    if not female:
        return m
    P = np.array(m.P)
    shifted = P + FEMALE_SHIFT
    for i, tag in enumerate(m.TAG):
        if tag == 'strap' and P[i][2] < 0.02:
            shifted[i][2] += FEMALE_CHEST
    out = m.transformed(lambda A: A)
    out.P = list(shifted)
    return out


def hand_variant(m, left):
    """The pack carried by the strap in the right hand; the left is its mirror image in x (as in the vanilla files)."""
    grip = np.array([STRAP_X, GRIP_ON_STRAP[1] + Y_SHIFT, GRIP_ON_STRAP[0]])
    shift = HAND_GRIP - grip  # put our strap's grip point where the vanilla pack is held

    def pos(A):
        B = (A + shift) @ HAND_R.T + HAND_T
        if left:
            B = B * np.array([-1, 1, 1])
        return B

    def direction(A):
        B = A @ HAND_R.T
        if left:
            B = B * np.array([-1, 1, 1])
        return B
    return m.transformed(pos, direction, flip=left)


# ----------------------------------------------------------------------------------------------------------------------
# DirectX .x writer (text, 0303txt 0032), vanilla skeleton spliced in
# ----------------------------------------------------------------------------------------------------------------------
def read_text(path):
    with open(path, 'rb') as f:
        return f.read().decode('latin-1').replace('\r\n', '\n')


MATRIX = r'(-?[0-9.]+(?:,-?[0-9.]+){15});;'


def vanilla_parts(src, bone):
    """(prefix text up to our mesh frame, suffix from AnimTicksPerSecond, the bone's offset matrix text)."""
    txt = read_text(os.path.join(VANILLA_BP, src))
    mm = re.search(r'^Frame (?!Dummy01\b|Translation_Data\b)(\w+) \{\n', txt, re.M)
    anim = txt.index('\nAnimTicksPerSecond') + 1
    prefix, suffix = txt[:mm.start()], txt[anim:]
    prefix = re.sub(r'TextureFilename \{\n(\s*)"[^"]*";', lambda g: 'TextureFilename {\n%s"%s";' % (g.group(1), TEX_REF), prefix)
    k = txt.index('"%s";' % bone, mm.start())
    mat = re.compile(MATRIX).search(txt, k).group(1)
    return prefix, suffix, mat


def f6(v):
    return '%.6f' % (0.0 if abs(v) < 5e-7 else v)


def mesh_frame_text(name, P, N, UV, F, bone, matrix, material):
    n, nf = len(P), len(F)
    out = ['Frame %s {' % name, ' ', '', ' FrameTransformMatrix {',
           '  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,'
           '0.000000,0.000000,0.000000,1.000000;;', ' }', '', ' Mesh %s {' % name, '  %d;' % n]
    for i, p in enumerate(P):
        out.append('  %s;%s;%s;%s' % (f6(p[0]), f6(p[1]), f6(p[2]), ',' if i < n - 1 else ';'))
    faces = ['  3;%d,%d,%d;%s' % (a, b, c, ',' if i < nf - 1 else ';') for i, (a, b, c) in enumerate(F)]
    out.append('  %d;' % nf)
    out += faces
    out += ['', '  MeshNormals {', '   %d;' % n]
    for i, q in enumerate(N):
        out.append('   %s;%s;%s;%s' % (f6(q[0]), f6(q[1]), f6(q[2]), ',' if i < n - 1 else ';'))
    out.append('   %d;' % nf)
    out += [' ' + f for f in faces]
    out += ['  }', '', '  MeshMaterialList {', '   1;', '   %d;' % nf]
    out += ['   0,'] * (nf - 1) + ['   0;']
    out += ['   { %s }' % material, '  }', '', '  MeshTextureCoords c1 {', '   %d;' % n]
    for i, t in enumerate(UV):
        out.append('   %s;%s;%s' % (f6(t[0]), f6(t[1]), ',' if i < n - 1 else ';'))
    out += ['  }', '', '  XSkinMeshHeader {', '   1;', '   1;', '   1;', '  }', '', '  SkinWeights {', '   "%s";' % bone,
            '   %d;' % n]
    out += ['   %d,' % i for i in range(n - 1)] + ['   %d;' % (n - 1)]
    out += ['   1.000000,'] * (n - 1) + ['   1.000000;']
    out += ['   %s;;' % matrix, '  }', ' }', '}', '']
    return '\n'.join(out)


def write_x(key, mesh):
    v = VARIANTS[key]
    prefix, suffix, matrix = vanilla_parts(v['src'], v['bone'])
    P, N, UV, F = mesh.arrays()
    material = re.search(r'^Material (\S+) \{', prefix, re.M).group(1)
    text = prefix + mesh_frame_text(v['frame'], P, N, UV, F, v['bone'], matrix, material) + '\n' + suffix
    os.makedirs(os.path.dirname(OUT[key]), exist_ok=True)
    with open(OUT[key], 'wb') as f:
        f.write(text.encode('latin-1'))
    return len(P), len(F)


# ----------------------------------------------------------------------------------------------------------------------
# Binary FBX 7.3 (read and write; the floor model reuses the vanilla ground model's node layout)
# ----------------------------------------------------------------------------------------------------------------------
MAGIC = b'Kaydara FBX Binary  \x00\x1a\x00'


def fbx_read(data):
    ver = struct.unpack_from('<I', data, 23)[0]
    assert ver < 7500, 'only the 32 bit offset layout is handled'

    def node(pos):
        end, nprops, plen = struct.unpack_from('<III', data, pos)
        pos += 12
        nl = data[pos]
        pos += 1
        if end == 0:
            return None, pos
        name = data[pos:pos + nl].decode()
        pos += nl
        props = []
        pend = pos + plen
        for _ in range(nprops):
            t = chr(data[pos])
            pos += 1
            if t == 'Y':
                props.append(('Y', struct.unpack_from('<h', data, pos)[0])); pos += 2
            elif t == 'C':
                props.append(('C', data[pos])); pos += 1
            elif t == 'I':
                props.append(('I', struct.unpack_from('<i', data, pos)[0])); pos += 4
            elif t == 'F':
                props.append(('F', struct.unpack_from('<f', data, pos)[0])); pos += 4
            elif t == 'D':
                props.append(('D', struct.unpack_from('<d', data, pos)[0])); pos += 8
            elif t == 'L':
                props.append(('L', struct.unpack_from('<q', data, pos)[0])); pos += 8
            elif t in 'fdlib':
                n, enc, clen = struct.unpack_from('<III', data, pos)
                pos += 12
                raw = data[pos:pos + clen]
                pos += clen
                if enc:
                    raw = zlib.decompress(raw)
                code = 'B' if t == 'b' else t
                props.append((t, struct.unpack('<%d%s' % (n, code), raw)))
            elif t in 'SR':
                n = struct.unpack_from('<I', data, pos)[0]
                pos += 4
                props.append((t, bytes(data[pos:pos + n]))); pos += n
            else:
                raise ValueError('bad property type ' + t)
        assert pos == pend
        kids = []
        while pos < end:
            c, pos = node(pos)
            if c is None:
                break
            kids.append(c)
        return [name, props, kids], end

    pos, nodes = 27, []
    while True:
        n, pos = node(pos)
        if n is None:
            break
        nodes.append(n)
    return ver, nodes


def fbx_write(ver, nodes, footer_id):
    buf = bytearray(MAGIC + struct.pack('<I', ver))

    def put(nd):
        name, props, kids = nd
        start = len(buf)
        buf.extend(b'\0' * 12)
        nm = name.encode()
        buf.append(len(nm))
        buf.extend(nm)
        pstart = len(buf)
        for p in props:
            t = p[0]
            if t == 'Y':
                buf.extend(b'Y' + struct.pack('<h', p[1]))
            elif t == 'C':
                buf.extend(b'C' + bytes([p[1]]))
            elif t == 'I':
                buf.extend(b'I' + struct.pack('<i', p[1]))
            elif t == 'F':
                buf.extend(b'F' + struct.pack('<f', p[1]))
            elif t == 'D':
                buf.extend(b'D' + struct.pack('<d', p[1]))
            elif t == 'L':
                buf.extend(b'L' + struct.pack('<q', p[1]))
            elif t in 'fdlib':
                vals = p[1]
                raw = struct.pack('<%d%s' % (len(vals), 'B' if t == 'b' else t), *vals)
                comp = zlib.compress(raw, 6)
                buf.extend(t.encode() + struct.pack('<III', len(vals), 1, len(comp)) + comp)
            else:
                buf.extend(t.encode() + struct.pack('<I', len(p[1])) + p[1])
        plen = len(buf) - pstart
        for k in kids:
            put(k)
        if kids:
            buf.extend(b'\0' * 13)
        struct.pack_into('<III', buf, start, len(buf), len(props), plen)
    for nd in nodes:
        put(nd)
    buf.extend(b'\0' * 13)
    buf.extend(footer_id)
    buf.extend(b'\0' * ((-len(buf)) % 16))
    buf.extend(b'\0' * 4)
    buf.extend(struct.pack('<I', ver))
    buf.extend(b'\0' * 120)
    buf.extend(bytes.fromhex('f85a8c6adef5d97eece90ce3758f290b'))
    return bytes(buf)


def fbx_find(nodes, name):
    for n in nodes:
        if n[0] == name:
            return n
        r = fbx_find(n[2], name)
        if r:
            return r
    return None


def fbx_set(node, name, props):
    """Replace (or append) the child `name` of node with the given property list."""
    for c in node[2]:
        if c[0] == name:
            c[1] = props
            return c
    c = [name, props, []]
    node[2].append(c)
    return c


# raw coordinates of the ground model: the vanilla file is 3ds Max inches (z up, standing on z = 0) with the back of the pack
# toward +x and the width along y. canonical (x left, y up, z back) -> raw (x = -z, y = x, z = y) * 100, a mirror image
# (determinant -1) because .x is left handed and the .fbx right handed.
GROUND_SCALE = 100.0
GROUND_Z_CENTRE = 0.19


def ground_raw(P):
    P = np.asarray(P, float)
    return np.stack([-(P[:, 2] - GROUND_Z_CENTRE), P[:, 0], P[:, 1] - (Y_BOT + Y_SHIFT)], axis=1) * GROUND_SCALE


def write_fbx(mesh):
    with open(VANILLA_GROUND, 'rb') as f:
        data = f.read()
    ver, nodes = fbx_read(data)
    footer_id = data[data.rfind(b'\0' * 13) + 13:][:16] if False else bytes.fromhex('fabcae04d8c1d86dbe7ef38519f5227c')
    P, N, UV, F = mesh.arrays()
    raw = ground_raw(P)
    rawN = np.stack([-N[:, 2], N[:, 0], N[:, 1]], axis=1)
    nf = len(F)
    # winding: cross(p1-p0, p2-p0) must be outward in the right-handed raw space too (the mirror flipped it)
    F = F.copy()
    c = np.cross(raw[F[:, 1]] - raw[F[:, 0]], raw[F[:, 2]] - raw[F[:, 0]])
    flip = (c * rawN[F[:, 0]]).sum(1) < 0
    F[flip] = F[flip][:, [0, 2, 1]]
    fv = np.where(np.arange(3)[None, :] == 2, ~F, F).reshape(-1)   # last index of each polygon is stored negated (~i)
    uvf = np.stack([UV[:, 0], 1.0 - UV[:, 1]], axis=1)             # fbx v grows upward
    pn = rawN[F.reshape(-1)]
    pu = F.reshape(-1)
    # tangents per polygon vertex from the uv gradient of the triangle
    tang = np.zeros((nf * 3, 3))
    binm = np.zeros((nf * 3, 3))
    for fi in range(nf):
        a, b, c3 = F[fi]
        e1, e2 = raw[b] - raw[a], raw[c3] - raw[a]
        d1, d2 = uvf[b] - uvf[a], uvf[c3] - uvf[a]
        det = d1[0] * d2[1] - d2[0] * d1[1]
        if abs(det) < 1e-12:
            t, bi = np.array([1.0, 0, 0]), np.array([0, 1.0, 0])
        else:
            t = (e1 * d2[1] - e2 * d1[1]) / det
            bi = (e2 * d1[0] - e1 * d2[0]) / det
        t = t / (np.linalg.norm(t) or 1)
        bi = bi / (np.linalg.norm(bi) or 1)
        tang[fi * 3:fi * 3 + 3] = t
        binm[fi * 3:fi * 3 + 3] = bi
    objects = fbx_find(nodes, 'Objects')
    geo = [c for c in objects[2] if c[0] == 'Geometry'][0]
    old_kids = {c[0]: c for c in geo[2]}

    def layer(name, version, label, mapping, ref, arrname, arr, extra=None):
        kids = [['Version', [('I', version)], []], ['Name', [('S', label)], []],
                ['MappingInformationType', [('S', mapping)], []], ['ReferenceInformationType', [('S', ref)], []],
                [arrname, [('d', tuple(float(x) for x in arr.reshape(-1)))], []]]
        return [name, [('I', 0)], kids]
    uvlayer = ['LayerElementUV', [('I', 0)], [
        ['Version', [('I', 101)], []], ['Name', [('S', b'UVChannel_1')], []],
        ['MappingInformationType', [('S', b'ByPolygonVertex')], []],
        ['ReferenceInformationType', [('S', b'IndexToDirect')], []],
        ['UV', [('d', tuple(float(x) for x in uvf.reshape(-1)))], []],
        ['UVIndex', [('i', tuple(int(x) for x in pu))], []]]]
    smooth = ['LayerElementSmoothing', [('I', 0)], [
        ['Version', [('I', 102)], []], ['Name', [('S', b'')], []],
        ['MappingInformationType', [('S', b'ByPolygon')], []], ['ReferenceInformationType', [('S', b'Direct')], []],
        ['Smoothing', [('i', tuple([1] * nf))], []]]]
    mat = ['LayerElementMaterial', [('I', 0)], [
        ['Version', [('I', 101)], []], ['Name', [('S', b'')], []],
        ['MappingInformationType', [('S', b'AllSame')], []], ['ReferenceInformationType', [('S', b'IndexToDirect')], []],
        ['Materials', [('i', (0,))], []]]]
    geo[2] = [
        old_kids['Properties70'],
        ['Vertices', [('d', tuple(float(x) for x in raw.reshape(-1)))], []],
        ['PolygonVertexIndex', [('i', tuple(int(x) for x in fv))], []],
        ['GeometryVersion', [('I', 124)], []],
        layer('LayerElementNormal', 101, b'', b'ByPolygonVertex', b'Direct', 'Normals', pn),
        layer('LayerElementBinormal', 101, b'UVChannel_1', b'ByPolygonVertex', b'Direct', 'Binormals', binm),
        layer('LayerElementTangent', 101, b'UVChannel_1', b'ByPolygonVertex', b'Direct', 'Tangents', tang),
        uvlayer, smooth, mat, old_kids['Layer']]
    # names and texture paths: nothing of the vanilla file's author or art remains
    def rename(nd):
        nm, props, kids = nd
        for i, p in enumerate(props):
            if p[0] == 'S':
                s = p[1]
                s = s.replace(b'ALICE_Pack_Ground', (NAME + '_Ground').encode())
                s = re.sub(rb'[^\x00\x01"]*ALICEpack\.png', TEX_REF.encode(), s)
                s = re.sub(rb'[A-Za-z]:\\[^\x00]*\.FBX', (NAME + '_Ground.fbx').encode(), s, flags=re.I)
                s = s.replace(b'Material #180', (NAME + '_Mat').encode()).replace(b'Map #91', (NAME + '_Map').encode())
                props[i] = ('S', s)
        for k in kids:
            rename(k)
    rename(nodes[0])
    rename(objects)
    out = fbx_write(ver, nodes, footer_id)
    os.makedirs(os.path.dirname(OUT['G']), exist_ok=True)
    with open(OUT['G'], 'wb') as f:
        f.write(out)
    return len(raw), nf


# ----------------------------------------------------------------------------------------------------------------------
# Texture painting
# ----------------------------------------------------------------------------------------------------------------------
class Painter:
    def __init__(self):
        self.rng = np.random.default_rng(42)
        self.img = np.zeros((ATLAS, ATLAS, 3), float)

    def fill(self, rect, color, noise=5.0, weave=3.0, blotch=5.0):
        x0, y0, x1, y1 = rect
        h, w = y1 - y0, x1 - x0
        base = np.array(color, float)[None, None, :]
        arr = np.tile(base, (h, w, 1))
        yy, xx = np.mgrid[0:h, 0:w]
        arr += (((xx + yy) % 2) * weave - weave / 2)[..., None]
        arr += ((xx // 2 + yy // 3) % 2 * weave * 0.6 - weave * 0.3)[..., None]
        arr += self.rng.normal(0, noise, (h, w, 1))
        low = self.rng.normal(0, 1, (max(2, h // 12), max(2, w // 12)))
        low = np.array(Image.fromarray(low.astype(np.float32), 'F').resize((w, h), Image.BICUBIC))
        arr += low[..., None] * blotch
        self.img[y0:y1, x0:x1] = arr

    def patch(self, rect):
        x0, y0, x1, y1 = rect
        return self.img[y0:y1, x0:x1]

    def stitch(self, rect, inset, color, dash=(3, 2), sides='lrtb'):
        x0, y0, x1, y1 = rect
        a = self.img
        c = np.array(color, float)
        period = dash[0] + dash[1]
        for x in range(x0 + inset, x1 - inset):
            if (x - x0) % period < dash[0]:
                if 't' in sides:
                    a[y0 + inset, x] = c
                if 'b' in sides:
                    a[y1 - 1 - inset, x] = c
        for y in range(y0 + inset, y1 - inset):
            if (y - y0) % period < dash[0]:
                if 'l' in sides:
                    a[y, x0 + inset] = c
                if 'r' in sides:
                    a[y, x1 - 1 - inset] = c

    def line(self, p0, p1, color, dash=None, width=1):
        n = int(max(abs(p1[0] - p0[0]), abs(p1[1] - p0[1])) + 1)
        for i in range(n):
            if dash and i % (dash[0] + dash[1]) >= dash[0]:
                continue
            x = round(p0[0] + (p1[0] - p0[0]) * i / max(1, n - 1))
            y = round(p0[1] + (p1[1] - p0[1]) * i / max(1, n - 1))
            for d in range(width):
                self.img[y, min(x + d, ATLAS - 1)] = np.array(color, float)

    def wear(self, rect, amount=10, thickness=2):
        x0, y0, x1, y1 = rect
        a = self.img
        for k in range(thickness):
            f = amount * (1 - k / thickness)
            for sl in (a[y0 + k, x0:x1], a[y1 - 1 - k, x0:x1], a[y0:y1, x0 + k], a[y0:y1, x1 - 1 - k]):
                sl += (f * (0.5 + self.rng.random((sl.shape[0], 1))))
        # scuffs
        for _ in range(int((x1 - x0) * (y1 - y0) / 500)):
            x = self.rng.integers(x0, x1)
            y = self.rng.integers(y0, y1)
            a[y, x] += self.rng.integers(6, 14)

    def dirt(self, rect, strength=0.35, height=0.35, color=(66, 52, 34)):
        x0, y0, x1, y1 = rect
        h, w = y1 - y0, x1 - x0
        yy = np.linspace(0, 1, h)[:, None]
        grad = np.clip((yy - (1 - height)) / height, 0, 1) ** 1.5
        speck = (self.rng.random((h, w)) > 0.55) * self.rng.random((h, w))
        alpha = np.clip(grad * (0.5 + 0.8 * speck) * strength, 0, 0.8)[..., None]
        self.img[y0:y1, x0:x1] = self.img[y0:y1, x0:x1] * (1 - alpha) + np.array(color, float) * alpha

    def rgb(self):
        return np.clip(self.img, 0, 255).astype(np.uint8)


def acorn_mask(size):
    """A stencilled acorn (white on black), drawn big and scaled down so the edges stay crisp."""
    S = 8
    n = size * S
    im = Image.new('L', (n, n), 0)
    d = ImageDraw.Draw(im)
    u = n / 48.0
    # nut body with a pointed tip, cap with a stem
    d.ellipse([13 * u, 22 * u, 35 * u, 42 * u], fill=255)
    d.polygon([(19 * u, 38 * u), (29 * u, 38 * u), (24 * u, 47 * u)], fill=255)
    d.ellipse([8 * u, 10 * u, 40 * u, 28 * u], fill=255)
    d.rectangle([22 * u, 3 * u, 26 * u, 11 * u], fill=255)
    # cap crosshatch cut-outs and the stencil bridges
    for k in range(-2, 8):
        d.line([(8 * u + k * 6 * u, 28 * u), (8 * u + k * 6 * u + 14 * u, 10 * u)], fill=0, width=int(1.2 * u))
    d.rectangle([6 * u, 25.2 * u, 42 * u, 27.0 * u], fill=0)
    d.rectangle([23.2 * u, 28 * u, 24.8 * u, 36 * u], fill=0)
    d.line([(18 * u, 33 * u), (21 * u, 41 * u)], fill=0, width=int(1.2 * u))
    return np.array(im.resize((size, size), Image.LANCZOS), float) / 255.0


def paint_atlas():
    P = Painter()
    stitch = (58, 60, 38)
    P.fill((0, 0, ATLAS, ATLAS), COL['edge'], noise=3, weave=2, blotch=3)  # no black left over between the regions
    # swatches
    for key in SWATCH:
        i, j = SWATCH[key]
        x0 = SWATCH_ORIGIN[0] + i * SWATCH_CELL
        y0 = SWATCH_ORIGIN[1] + j * SWATCH_CELL
        P.fill((x0, y0, x0 + SWATCH_CELL, y0 + SWATCH_CELL), COL[key], noise=2.5, weave=2.0, blotch=2.0)
    # sack: canvas, stitching, dirt
    P.fill(RECT['front'], COL['olive'])
    r = RECT['front']
    P.stitch(r, 3, stitch)
    P.stitch(r, 5, stitch, dash=(5, 3), sides='b')
    P.line((r[0] + 33, r[1] + 4), (r[0] + 33, r[3] - 8), (74, 77, 52), dash=(3, 2))
    P.line((r[0] + 66, r[1] + 4), (r[0] + 66, r[3] - 8), (74, 77, 52), dash=(3, 2))
    P.wear(r)
    P.dirt(r, 0.5, 0.45)
    P.fill(RECT['side'], COL['olive'])
    r = RECT['side']
    P.stitch(r, 3, stitch)
    P.wear(r)
    P.dirt(r, 0.5, 0.45)
    # padded back panel: dark mesh, diamond pattern and padding channels
    P.fill(RECT['back'], (50, 52, 40), noise=3, weave=2, blotch=3)
    r = RECT['back']
    for k in range(0, (r[2] - r[0]) + (r[3] - r[1]), 6):
        P.line((r[0] + k, r[1]), (r[0], r[1] + k), (40, 42, 32)) if k < r[3] - r[1] else None
    for x in range(r[0] + 14, r[2], 22):
        P.line((x, r[1] + 3), (x, r[3] - 3), (36, 38, 30), width=2)
    P.stitch(r, 2, (70, 72, 56))
    P.wear(r, 5)
    # chamfers and base
    P.fill(RECT['cham'], COL['olive'])
    r = RECT['cham']
    P.line((r[0] + 6, r[1] + 2), (r[0] + 6, r[3] - 2), stitch, dash=(3, 2))
    P.dirt(r, 0.5, 0.45)
    P.fill(RECT['base'], (60, 62, 44), noise=3, weave=2.5, blotch=4)
    P.stitch(RECT['base'], 3, (44, 46, 32))
    P.dirt(RECT['base'], 0.7, 0.8)
    # top flap
    P.fill(RECT['flap'], COL['olive'])
    r = RECT['flap']
    s_total = sum(math.dist(FLAP[i], FLAP[i + 1]) for i in range(len(FLAP) - 1))
    s_drape0 = sum(math.dist(FLAP[i], FLAP[i + 1]) for i in range(3))
    h = r[3] - r[1]
    row_drape = r[1] + int(round(h * s_drape0 / s_total))
    P.stitch(r, 3, stitch)
    P.stitch(r, 6, stitch, dash=(4, 3), sides='lr')
    P.line((r[0] + 3, row_drape), (r[2] - 4, row_drape), (80, 83, 56))   # the fold between top and drape
    P.line((r[0] + 6, r[3] - 6), (r[2] - 7, r[3] - 6), stitch, dash=(4, 3))
    P.wear(r, 12)
    P.dirt((r[0], row_drape, r[2], r[3]), 0.35, 0.6)
    # the acorn stencil, centred above the buckle strap on the drape (strap top at y 0.745, drape from 0.846 to 0.700)
    drape_len = math.dist(FLAP[3], FLAP[4])
    y_c = 0.788
    s_c = s_drape0 + (FLAP[3][1] - y_c) * drape_len / (FLAP[3][1] - FLAP[4][1])
    cy = r[1] + h * s_c / s_total
    cx = (r[0] + r[2]) / 2
    size = 22
    mask = acorn_mask(size)
    mask *= (P.rng.random(mask.shape) > 0.10)  # chipped stencil paint
    x0, y0 = int(round(cx - size / 2)), int(round(cy - size / 2))
    paint = np.array((205, 198, 160), float)
    reg = P.img[y0:y0 + size, x0:x0 + size]
    a = (mask * 0.82)[..., None]
    P.img[y0:y0 + size, x0:x0 + size] = reg * (1 - a) + paint * a
    # shoulder strap: darker padded webbing
    P.fill(RECT['strap'], COL['dark'], noise=3, weave=3, blotch=3)
    r = RECT['strap']
    for y in range(r[1] + 4, r[3] - 4, 5):
        P.line((r[0] + 4, y), (r[2] - 5, y), (56, 60, 40))
    P.line((r[0] + 3, r[1] + 2), (r[0] + 3, r[3] - 3), (92, 96, 66), dash=(3, 2))
    P.line((r[2] - 4, r[1] + 2), (r[2] - 4, r[3] - 3), (92, 96, 66), dash=(3, 2))
    P.wear(r, 8, 1)
    # buckle: dull metal frame with a dark slot, a centre bar and a worn edge
    r = RECT['buckle']
    P.fill(r, (96, 98, 94), noise=4, weave=2, blotch=4)
    P.img[r[1] + 7:r[3] - 7, r[0] + 5:r[2] - 5] = np.array((40, 42, 38), float)
    P.img[r[1] + 7:r[3] - 7, r[0] + 13:r[0] + 17] = np.array((132, 134, 128), float)
    P.line((r[0] + 2, r[1] + 3), (r[2] - 3, r[1] + 3), (150, 152, 146))
    P.line((r[0] + 2, r[3] - 4), (r[2] - 3, r[3] - 4), (62, 64, 60))
    # pockets and lids
    P.fill(RECT['pocket'], COL['pocket'])
    r = RECT['pocket']
    P.stitch(r, 3, stitch)
    P.line((r[0] + 22, r[1] + 4), (r[0] + 22, r[3] - 5), (70, 74, 50), dash=(3, 2))
    P.wear(r)
    P.dirt(r, 0.55, 0.5)
    P.fill(RECT['lid'], COL['olive'])
    r = RECT['lid']
    P.stitch(r, 3, stitch)
    cx, cy = (r[0] + r[2]) // 2, r[3] - 8
    for yy in range(-3, 4):
        for xx in range(-3, 4):
            if xx * xx + yy * yy <= 9:
                P.img[cy + yy, cx + xx] = np.array((126, 128, 122)) - (xx + yy) * 3
    P.wear(r, 8, 1)
    # webbing strip: woven tan with bar-tack rows
    P.fill(RECT['webbing'], COL['tan'], noise=4, weave=5, blotch=3)
    r = RECT['webbing']
    for y in range(r[1] + 3, r[3] - 3, 8):
        P.line((r[0] + 2, y), (r[2] - 3, y), (96, 84, 56), width=1)
        P.line((r[0] + 2, y + 1), (r[2] - 3, y + 1), (96, 84, 56), dash=(2, 1))
        P.line((r[0] + 2, y + 4), (r[2] - 3, y + 4), (122, 110, 76))
    P.wear(r, 6, 1)
    P.dirt(r, 0.4, 0.5)
    return Image.fromarray(P.rgb(), 'RGB')


# ----------------------------------------------------------------------------------------------------------------------
# Text files
# ----------------------------------------------------------------------------------------------------------------------
BOM = '\ufeff'


def write_text(path, text, bom=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write((BOM if bom else '').encode('utf-8') + text.replace('\r\n', '\n').encode('utf-8'))


def write_clothing():
    for fname, (guid, male, female) in CLOTHING.items():
        carried = fname.endswith('Hand')
        text = (
            '<?xml version="1.0" encoding="utf-8"?>\n<clothingItem>\n'
            '\t<m_MaleModel>media\\models_X\\Skinned\\BackPacks\\%s.X</m_MaleModel>\n'
            '\t<m_FemaleModel>media\\models_X\\Skinned\\BackPacks\\%s.X</m_FemaleModel>\n'
            '\t<m_GUID>%s</m_GUID>\n'
            '\t<m_Static>false</m_Static>\n'
            '\t<m_AllowRandomHue>false</m_AllowRandomHue>\n'
            '\t<m_AllowRandomTint>false</m_AllowRandomTint>\n'
            '\t<m_AttachBone></m_AttachBone>\n'
            '\t<textureChoices>clothes\\bag\\%s</textureChoices>\n'
            '</clothingItem>') % (male, female, guid, NAME.lower())
        write_text(os.path.join(CLOTHING_DIR, fname + '.xml'), text, bom=True)
    entries = ''.join('\t<files>\n\t\t<path>media/clothing/clothingItems/%s.xml</path>\n\t\t<guid>%s</guid>\n\t</files>\n'
                      % (f, g[0]) for f, g in CLOTHING.items())
    write_text(OUT['GUID'], '<?xml version="1.0" encoding="utf-8"?>\n<fileGuidTable>\n' + entries + '</fileGuidTable>\n')


def write_script():
    write_text(OUT['SCRIPT'], (
        'module OperationAcorn\n{\n'
        '\t/* The research team backpack lying on the floor (same pack as the worn model, own atlas). */\n'
        '\tmodel OA_ResearchPack_Ground\n\t{\n'
        '\t\tmesh = WorldItems/Clothing/OA_ResearchPack_Ground,\n'
        '\t\ttexture = Clothes/Bag/OA_ResearchPack,\n'
        '\t\tscale = 0.4,\n\t}\n}\n'))


# ----------------------------------------------------------------------------------------------------------------------
# Software renderer (preview)
# ----------------------------------------------------------------------------------------------------------------------
def cross(a, b):
    a, b = np.asarray(a, float), np.asarray(b, float)
    return np.array([a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]])


def unit(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v)


def box_mesh(lo, hi, color):
    """A plain box (preview body proxy): (verts, tris, colour)."""
    lo, hi = np.array(lo, float), np.array(hi, float)
    V = np.array([[x, y, z] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])])
    quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    T = []
    for q in quads:
        T += [(q[0], q[1], q[2]), (q[0], q[2], q[3])]
    return V, np.array(T), color


def render(meshes, tex, d, up, size=380, ss=2, bodies=(), marker=None, bg=(226, 228, 224)):
    """Orthographic render. meshes: list of (P, N, UV, F). Faces looking away from the camera are culled (as in the game)."""
    d, up = unit(d), unit(up)
    right = unit(cross(up, d))
    upv = unit(cross(d, right))
    allp = np.concatenate([m[0] for m in meshes])
    centre = (allp.min(0) + allp.max(0)) / 2
    ext = max(np.ptp(np.dot(allp - centre, right)), np.ptp(np.dot(allp - centre, upv)))
    sc = size * ss * 0.86 / ext
    W = size * ss
    img = np.zeros((W, W, 3), float)
    img[:] = bg
    zb = np.full((W, W), 1e9)
    light = unit(-d * 0.8 + upv * 0.55 - right * 0.35)

    def proj(P):
        q = P - centre
        return np.stack([W / 2 + sc * q @ right, W / 2 - sc * q @ upv, q @ d], axis=1)

    def raster(Pp, tri, shade, uvs=None, color=None):
        xs, ys, zs = Pp[tri, 0], Pp[tri, 1], Pp[tri, 2]
        x0, x1 = max(int(np.floor(xs.min())), 0), min(int(np.ceil(xs.max())) + 1, W)
        y0, y1 = max(int(np.floor(ys.min())), 0), min(int(np.ceil(ys.max())) + 1, W)
        if x0 >= x1 or y0 >= y1:
            return
        gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
        den = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if abs(den) < 1e-9:
            return
        l0 = ((ys[1] - ys[2]) * (gx - xs[2]) + (xs[2] - xs[1]) * (gy - ys[2])) / den
        l1 = ((ys[2] - ys[0]) * (gx - xs[2]) + (xs[0] - xs[2]) * (gy - ys[2])) / den
        l2 = 1 - l0 - l1
        inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
        if not inside.any():
            return
        z = l0 * zs[0] + l1 * zs[1] + l2 * zs[2]
        win = inside & (z < zb[y0:y1, x0:x1])
        if not win.any():
            return
        if uvs is not None:
            u = l0 * uvs[0][0] + l1 * uvs[1][0] + l2 * uvs[2][0]
            v = l0 * uvs[0][1] + l1 * uvs[1][1] + l2 * uvs[2][1]
            tx = np.clip((u * ATLAS).astype(int), 0, ATLAS - 1)
            ty = np.clip((v * ATLAS).astype(int), 0, ATLAS - 1)
            col = tex[ty, tx].astype(float)
        else:
            col = np.array(color, float)[None, None, :] + np.zeros((y1 - y0, x1 - x0, 3))
        sub = img[y0:y1, x0:x1]
        sub[win] = (col * shade)[win]
        zb[y0:y1, x0:x1][win] = z[win]

    for V, T, color in bodies:
        Pp = proj(V)
        for t in T:
            n = unit(cross(V[t[1]] - V[t[0]], V[t[2]] - V[t[0]]))
            raster(Pp, t, 0.55 + 0.45 * max(0.0, float(np.dot(n, light))), color=color)
    for P, N, UV, F in meshes:
        Pp = proj(P)
        for f in F:
            n = cross(P[f[1]] - P[f[0]], P[f[2]] - P[f[0]])
            ln = np.linalg.norm(n)
            if ln < 1e-12:
                continue
            n = n / ln
            if np.dot(n, d) > 0:      # faces away from the camera
                continue
            shade = 0.42 + 0.58 * max(0.0, float(np.dot(n, light)))
            raster(Pp, f, shade, uvs=[UV[i] for i in f])
    if marker is not None:
        q = proj(np.array([marker]))[0]
        for dx in range(-9, 10):
            for dy in range(-9, 10):
                if dx * dx + dy * dy <= 49:
                    x, y = int(q[0]) + dx, int(q[1]) + dy
                    if 0 <= x < W and 0 <= y < W:
                        img[y, x] = (210, 40, 40)
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), 'RGB')
    return im.resize((size, size), Image.LANCZOS)


def body_proxy(female=False):
    """Coarse torso, neck/head and upper arms in the worn model space (positions from the vanilla skeleton)."""
    zf = -0.075 if not female else -0.085
    col = (150, 120, 100)
    return [box_mesh((-0.095, 0.50, zf), (0.095, 0.80, 0.060), col),
            box_mesh((-0.035, 0.80, -0.045), (0.035, 0.84, 0.030), col),
            box_mesh((-0.060, 0.84, -0.075), (0.060, 0.97, 0.050), (140, 110, 90)),
            box_mesh((0.095, 0.62, -0.03), (0.150, 0.80, 0.05), col),
            box_mesh((-0.150, 0.62, -0.03), (-0.095, 0.80, 0.05), col)]


def make_preview(meshes, tex):
    worn, female, rhand, lhand, ground = (meshes[k] for k in ('M', 'F', 'R', 'L', 'G'))
    tile = 380
    sheet = Image.new('RGB', (tile * 4, tile * 2 + 24), (255, 255, 255))
    dr = ImageDraw.Draw(sheet)
    body = body_proxy()
    views = [
        ('worn: from behind the wearer (pack front)', worn, (0, 0, -1), (0, 1, 0), [], None),
        ('worn: wearer left side', worn, (-1, 0, 0), (0, 1, 0), body, None),
        ('worn: from the wearer front (straps)', worn, (0, 0, 1), (0, 1, 0), body, None),
        ('worn: top, with body', worn, (0, -1, 0), (0, 0, -1), body, None),
    ]
    for i, (label, m, d, up, bodies, mk) in enumerate(views):
        sheet.paste(render([m.arrays()], tex, d, up, tile, bodies=bodies, marker=mk), (i * tile, 0))
        dr.text((i * tile + 6, 4), label, fill=(0, 0, 0))
    # 3/4 views through the body for the strap fit, female, hands, ground
    sheet.paste(render([worn.arrays()], tex, unit((-0.6, -0.15, -0.8)), (0, 1, 0), tile, bodies=body), (0, tile))
    dr.text((6, tile + 4), 'worn M: 3/4 with body', fill=(0, 0, 0))
    sheet.paste(render([female.arrays()], tex, unit((-0.6, -0.15, -0.8)), (0, 1, 0), tile, bodies=body_proxy(True)),
                (tile, tile))
    dr.text((tile + 6, tile + 4), 'worn F: 3/4 with body', fill=(0, 0, 0))
    sheet.paste(render([rhand.arrays()], tex, unit((-0.4, -0.2, -1)), (0, 1, 0), tile, marker=prop_origin('R')), (2 * tile, tile))
    dr.text((2 * tile + 6, tile + 4), 'right hand carry (red: Prop1 bone)', fill=(0, 0, 0))
    g = ground.arrays()
    sheet.paste(render([g], tex, unit((-0.6, -0.3, -0.75)), (0, 1, 0), tile), (3 * tile, tile))
    dr.text((3 * tile + 6, tile + 4), 'ground model (canonical axes)', fill=(0, 0, 0))
    return sheet


def prop_origin(key):
    """Origin of the carry bone in the hand mesh space: the inverse of its offset matrix (row-vector convention)."""
    _, _, mat = vanilla_parts(VARIANTS[key]['src'], VARIANTS[key]['bone'])
    M = np.array([float(x) for x in mat.split(',')]).reshape(4, 4)
    return -M[3, :3] @ np.linalg.inv(M[:3, :3])


# ----------------------------------------------------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------------------------------------------------
def build_all():
    for p in (VANILLA_BP, VANILLA_GROUND):
        if not os.path.exists(p):
            sys.exit('vanilla reference missing (set PZ_DIR): ' + p)
    pack = build_pack(False)
    carried = build_pack(True)   # carried and lying packs have their straps hanging in a relaxed loop
    meshes = {
        'M': worn_variant(pack, False),
        'F': worn_variant(pack, True),
        'R': hand_variant(carried, False),
        'L': hand_variant(carried, True),
        'G': carried,
    }
    for k in 'MFLR':
        nv, nf = write_x(k, meshes[k])
        print('%-4s %4d vertices %4d faces  %s' % (k, nv, nf, os.path.relpath(OUT[k], ROOT)))
    nv, nf = write_fbx(meshes['G'])
    print('G    %4d vertices %4d faces  %s' % (nv, nf, os.path.relpath(OUT['G'], ROOT)))
    tex = paint_atlas()
    os.makedirs(os.path.dirname(OUT['TEX']), exist_ok=True)
    tex.save(OUT['TEX'])
    write_clothing()
    write_script()
    sheet = make_preview(meshes, np.array(tex))
    sheet.save(PREVIEW)
    print('preview', os.path.relpath(PREVIEW, ROOT))


# ----------------------------------------------------------------------------------------------------------------------
# --check: parse every produced file again
# ----------------------------------------------------------------------------------------------------------------------
class Fail(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Fail(msg)


def numbers(s):
    return [float(x) for x in re.findall(r'-?\d+\.?\d*(?:e-?\d+)?', s)]


def check_x(key):
    path = OUT[key]
    v = VARIANTS[key]
    with open(path, 'rb') as f:
        raw = f.read()
    need(raw.startswith(b'xof 0303txt 0032'), 'header')
    txt = raw.decode('latin-1').replace('\r\n', '\n')
    body = re.sub(r'"[^"]*"', '""', txt)
    need(body.count('{') == body.count('}'), 'unbalanced braces %d/%d' % (body.count('{'), body.count('}')))
    frames = set(re.findall(r'^\s*Frame (\w+) \{', txt, re.M))
    mm = re.search(r'\n\s*Mesh (\w+) \{\n\s*(\d+);\n', txt)
    need(mm, 'no mesh')
    nv = int(mm.group(2))
    pos = mm.end()
    verts = []
    for _ in range(nv):
        e = txt.index('\n', pos)
        verts.append([float(x) for x in txt[pos:e].strip().rstrip(',;').split(';')])
        pos = e + 1
    nf = int(re.match(r'\s*(\d+);\n', txt[pos:]).group(1))
    pos += re.match(r'\s*(\d+);\n', txt[pos:]).end()
    faces = []
    for _ in range(nf):
        e = txt.index('\n', pos)
        c, idx = txt[pos:e].strip().rstrip(',;').split(';')[:2]
        need(c == '3', 'face is not a triangle')
        faces.append([int(i) for i in idx.split(',')])
        pos = e + 1
    verts = np.array(verts)
    faces = np.array(faces)
    need(verts.shape == (nv, 3), 'vertex rows')
    need(faces.min() >= 0 and faces.max() < nv, 'face index out of range')
    # normals
    nm = re.search(r'MeshNormals \{\n\s*(\d+);\n', txt)
    nn = int(nm.group(1))
    block = txt[nm.end():]
    nrm = np.array([[float(x) for x in ln.strip().rstrip(',;').split(';')] for ln in block.split('\n')[:nn]])
    need(nn == nv, 'normal count %d != vertex count %d' % (nn, nv))
    need(np.abs(np.linalg.norm(nrm, axis=1) - 1).max() < 1e-3, 'normals not unit length')
    nfn = int(block.split('\n')[nn].strip().rstrip(';'))
    need(nfn == nf, 'normal face count')
    nfaces = np.array([[int(i) for i in ln.strip().rstrip(',;').split(';')[1].split(',')] for ln in block.split('\n')[nn + 1:nn + 1 + nf]])
    need(nfaces.max() < nn and (nfaces == faces).all(), 'normal faces differ from faces')
    # face winding agrees with the normals
    c = np.cross(verts[faces[:, 1]] - verts[faces[:, 0]], verts[faces[:, 2]] - verts[faces[:, 0]])
    need(((c * nrm[faces[:, 0]]).sum(1) > 0).all(), 'a face is wound against its normal')
    # material list
    ml = re.search(r'MeshMaterialList \{\n\s*1;\n\s*(\d+);\n((?:\s*0[,;]\n)+)\s*\{ (\S+) \}', txt)
    need(ml and int(ml.group(1)) == nf and ml.group(2).count('\n') == nf, 'material list')
    need('Material %s {' % ml.group(3) in txt, 'material %s missing' % ml.group(3))
    need('"%s"' % TEX_REF in txt, 'texture filename')
    # uv
    um = re.search(r'MeshTextureCoords c1 \{\n\s*(\d+);\n', txt)
    nu = int(um.group(1))
    need(nu == nv, 'uv count %d != vertex count %d' % (nu, nv))
    uv = np.array([[float(x) for x in ln.strip().rstrip(',;').split(';')] for ln in txt[um.end():].split('\n')[:nu]])
    need(uv.min() >= 0 and uv.max() <= 1, 'uv outside 0..1')
    # skin
    hm = re.search(r'XSkinMeshHeader \{\n\s*(\d+);\n\s*(\d+);\n\s*(\d+);', txt)
    need(hm and tuple(int(x) for x in hm.groups()) == (1, 1, 1), 'XSkinMeshHeader must be 1;1;1 for a single bone')
    sw = list(re.finditer(r'SkinWeights \{\n\s*"(\w+)";\n\s*(\d+);\n', txt))
    need(len(sw) == 1, 'expected exactly one SkinWeights, found %d' % len(sw))
    s = sw[0]
    need(s.group(1) == v['bone'], 'weighted to %s, expected %s' % (s.group(1), v['bone']))
    need(s.group(1) in frames, 'bone %s is no Frame' % s.group(1))
    cnt = int(s.group(2))
    need(cnt == nv, 'SkinWeights covers %d of %d vertices' % (cnt, nv))
    rest = txt[s.end():].split('\n')
    idx = [int(x.strip().rstrip(',;')) for x in rest[:cnt]]
    need(sorted(idx) == list(range(nv)), 'SkinWeights indices are not each vertex once')
    w = [float(x.strip().rstrip(',;')) for x in rest[cnt:2 * cnt]]
    need(all(abs(x - 1.0) < 1e-9 for x in w), 'a weight is not 1.0')
    mt = re.match(r'\s*' + MATRIX, rest[2 * cnt])
    need(mt, 'bone offset matrix missing')
    # offset matrix is the vanilla one for that bone
    if os.path.exists(os.path.join(VANILLA_BP, v['src'])):
        _, _, vm = vanilla_parts(v['src'], v['bone'])
        need(mt.group(1) == vm, 'offset matrix differs from the vanilla bone matrix')
    need('AnimTicksPerSecond' in txt and 'AnimationSet' in txt, 'animation set missing')
    need(len(txt) and '\r' not in txt, 'unexpected CR')
    return nv, nf


def check_fbx():
    with open(OUT['G'], 'rb') as f:
        data = f.read()
    need(data.startswith(MAGIC), 'fbx magic')
    need(data.endswith(bytes.fromhex('f85a8c6adef5d97eece90ce3758f290b')), 'fbx footer magic')
    ver, nodes = fbx_read(data)
    need(ver == 7300, 'fbx version')
    objects = fbx_find(nodes, 'Objects')
    geo = [c for c in objects[2] if c[0] == 'Geometry'][0]
    kids = {c[0]: c for c in geo[2]}
    V = np.array(kids['Vertices'][1][0][1]).reshape(-1, 3)
    pv = np.array(kids['PolygonVertexIndex'][1][0][1])
    need(len(pv) % 3 == 0 and (pv[2::3] < 0).all() and (pv[0::3] >= 0).all() and (pv[1::3] >= 0).all(), 'triangles')
    idx = np.where(pv < 0, ~pv, pv)
    need(idx.max() < len(V), 'fbx index range')
    nv_ = len(pv)
    lay = {c[0]: c for c in geo[2] if c[0].startswith('LayerElement')}
    for nm, arr in (('LayerElementNormal', 'Normals'), ('LayerElementBinormal', 'Binormals'), ('LayerElementTangent', 'Tangents')):
        a = [c for c in lay[nm][2] if c[0] == arr][0][1][0][1]
        need(len(a) == nv_ * 3, '%s count %d != %d' % (arr, len(a), nv_ * 3))
    uvn = [c for c in lay['LayerElementUV'][2] if c[0] == 'UV'][0][1][0][1]
    uvi = [c for c in lay['LayerElementUV'][2] if c[0] == 'UVIndex'][0][1][0][1]
    need(len(uvi) == nv_ and max(uvi) < len(uvn) // 2, 'uv index')
    need(0 <= min(uvn) and max(uvn) <= 1, 'fbx uv range')
    N = np.array([c for c in lay['LayerElementNormal'][2] if c[0] == 'Normals'][0][1][0][1]).reshape(-1, 3)
    need(abs(np.linalg.norm(N, axis=1) - 1).max() < 1e-3, 'fbx normals unit')
    F = idx.reshape(-1, 3)
    c = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
    need(((c * N.reshape(-1, 3, 3).mean(1)).sum(1) > 0).all(), 'fbx face wound against its normal')
    # connections point at objects that exist
    ids = {c[1][0][1] for c in objects[2] if c[1] and c[1][0][0] == 'L'}
    for c in fbx_find(nodes, 'Connections')[2]:
        for p in c[1][1:3]:
            need(p[1] == 0 or p[1] in ids, 'connection to a missing object %s' % p[1])
    lo, hi = V.min(0), V.max(0)
    need(abs(lo[2]) < 0.1 and 15 < hi[2] < 40, 'ground model should stand on z=0 and be about 25 units tall: %s %s' % (lo, hi))
    return len(V), len(F)


def check_files():
    img = Image.open(OUT['TEX'])
    need(img.size == (256, 256), 'texture size %s' % (img.size,))
    table = open(OUT['GUID'], encoding='utf-8').read()
    for fname, (guid, male, female) in CLOTHING.items():
        xml = open(os.path.join(CLOTHING_DIR, fname + '.xml'), encoding='utf-8-sig').read()
        need('<m_GUID>%s</m_GUID>' % guid in xml, fname + ': guid')
        need('media/clothing/clothingItems/%s.xml</path>\n\t\t<guid>%s</guid>' % (fname, guid) in table, fname + ': not in fileGuidTable')
        for m in (male, female):
            need(os.path.exists(os.path.join(MEDIA, 'models_X', 'Skinned', 'BackPacks', m + '.x')), fname + ': model ' + m + ' missing')
            need('\\%s.X</m_' % m in xml, fname + ': model path')
    need(len(set(g[0] for g in CLOTHING.values())) == len(CLOTHING), 'duplicate guid')
    sc = open(OUT['SCRIPT'], encoding='utf-8').read()
    need('mesh = WorldItems/Clothing/%s_Ground' % NAME in sc and sc.count('{') == sc.count('}'), 'model script')
    need(os.path.exists(OUT['G']), 'ground model file')


def check_all():
    bad = 0
    for k in 'MFLR':
        try:
            nv, nf = check_x(k)
            print('ok   %-28s %d vertices %d faces' % (os.path.basename(OUT[k]), nv, nf))
        except (Fail, FileNotFoundError, AttributeError, ValueError, IndexError) as e:
            bad += 1
            print('FAIL %-28s %s: %s' % (os.path.basename(OUT[k]), type(e).__name__, e))
    for nm, fn in (('ground fbx', check_fbx), ('textures, clothing xml, guid table, script', check_files)):
        try:
            r = fn()
            print('ok   %s %s' % (nm, r or ''))
        except (Fail, FileNotFoundError, AttributeError, ValueError, IndexError, KeyError) as e:
            bad += 1
            print('FAIL %s %s: %s' % (nm, type(e).__name__, e))
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
