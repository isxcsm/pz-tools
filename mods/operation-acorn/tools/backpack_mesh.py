#!/usr/bin/env python3
"""Builds the Operation Acorn research team backpack ('연구팀 배낭'): meshes, texture and the files the game needs.

    py tools/backpack_mesh.py              build everything, render tools/backpack_preview.png and the mockup sheets
    py tools/backpack_mesh.py --check      re-parse every produced file and assert it is consistent (no building)
    py tools/backpack_mesh.py --icon       only render tools/backpack_icon_source.png from the meshes and the atlas as
                                           they are (then tools/icon_art.py makes the item icons from it)

What it writes (all under OperationAcorn/42/media):
    models_X/Skinned/BackPacks/OA_ResearchPack_M.x, _F.x, _LHand.x, _RHand.x   worn / carried skinned meshes
    models_X/WorldItems/Clothing/OA_ResearchPack_Ground.fbx                     the floor model
    textures/Clothes/Bag/OA_ResearchPack.png                                    512x512 atlas (painted at 1024)
    clothing/clothingItems/OA_Bag_ResearchPack.xml (+ _LHand, _RHand)           the clothing items
    fileGuidTable.xml                                                           registers the three clothing items
    scripts/OA_backpack_models.txt                                              the floor model script
and tools/backpack_icon_source.png (the floor model on a clear background, the source of the item icon that
tools/icon_art.py makes), and the preview sheets: tools/backpack_preview.png, and mockups/backpack/*.png next to the repository (when that folder's
parent exists).

The pack is our own: soft rounded shapes (rounded boxes with bulged sides and a domed top), a lid, a front pouch with
MOLLE rows, side compression straps, a grab handle, and two military canteens built into side pouches (the pack's water
storage). Everything is generated below; nothing of another mod's mesh or texture is used.

What comes from the game install (PZ_DIR, default the Steam folder), structure only:
  * the vanilla bodies MaleBody.x / FemaleBody.x: the pack's back panel follows the body's back, the shoulder straps are
    laid onto the body surface (each kept in its own x plane, so it comes over the shoulder and straight down the chest
    parallel to the other, then pushed out ring by ring to a clearance), and every strap cross-section takes the skin
    weights of the body surface under it (Spine, Spine1, the clavicles, the upper arms; head and neck folded into
    Spine1), blended into Bip01_BackPack where the strap meets the pack. So the straps move with the torso and shoulders
    like the body's own skin instead of floating with the pack bone. The bone offset matrices of those bones are the
    body's own, verbatim.
  * the vanilla pack .x files: skeleton frames, templates and animation set are spliced around our mesh frame, and the
    Bip01_BackPack / Bip01_Prop1 / Bip01_Prop2 offset matrices are reused verbatim.
  * the vanilla ground model: the floor .fbx keeps its node layout and unit settings (we replace the geometry).

Model space of the worn .x files: x lateral (wearer's left positive), y up, z toward the back; the torso is around z 0.
Pack-local space (where the pack is built): x lateral, y up (same heights as the model), z out from the back panel.
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
SKINNED = os.path.join(PZ_DIR, 'media', 'models_X', 'Skinned')
VANILLA_BP = os.path.join(SKINNED, 'BackPacks')
VANILLA_GROUND = os.path.join(PZ_DIR, 'media', 'models_X', 'WorldItems', 'Clothing', 'ALICE_Pack_Ground.fbx')
PREVIEW = os.path.join(HERE, 'backpack_preview.png')
ICON_SOURCE = os.path.join(HERE, 'backpack_icon_source.png')
MOCKUPS = os.path.join(os.path.dirname(ROOT), 'mockups', 'backpack')

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
# vanilla source of the skeleton/animation text and of the pack bone's offset matrix, the body the straps are fitted to
VARIANTS = {
    'M': dict(src='M_ALICE_Pack.x', bone='Bip01_BackPack', frame=NAME + '_M', body='MaleBody.x'),
    'F': dict(src='F_ALICE_Pack.x', bone='Bip01_BackPack', frame=NAME + '_F', body='FemaleBody.x'),
    'L': dict(src='ALICE_Pack_LHand.x', bone='Bip01_Prop2', frame=NAME + '_LHand', body=None),
    'R': dict(src='ALICE_Pack_RHand.x', bone='Bip01_Prop1', frame=NAME + '_RHand', body=None),
}
CLOTHING = {  # file -> (guid, male model, female model)
    'OA_Bag_ResearchPack': ('4fbba45f-fbcf-4f9e-a4bb-cfadf3fbbe5d', NAME + '_M', NAME + '_F'),
    'OA_Bag_ResearchPack_LHand': ('8a9c34b3-a4b9-4341-80c4-3c11785722d6', NAME + '_LHand', NAME + '_LHand'),
    'OA_Bag_ResearchPack_RHand': ('13b5d057-5a2d-436e-8d37-8dbac94fa075', NAME + '_RHand', NAME + '_RHand'),
}
PACK_BONE = 'Bip01_BackPack'
MAX_WEIGHTS = 3          # bones per vertex (the vanilla bodies and packs use at most 3)
UPPER_ARM_MAX = 0.35     # most a strap vertex follows an upper arm (the rest of that share goes to the clavicle)
# body bones a strap may follow; the rest of the body's weights fold into the bone named here
STRAP_BONES = ('Bip01_Spine', 'Bip01_Spine1', 'Bip01_L_Clavicle', 'Bip01_R_Clavicle', 'Bip01_L_UpperArm',
               'Bip01_R_UpperArm')
FOLD = {'Bip01_Neck': 'Bip01_Spine1', 'Bip01_Head': 'Bip01_Spine1', 'Bip01_Pelvis': 'Bip01_Spine',
        'Bip01_L_Forearm': 'Bip01_L_UpperArm', 'Bip01_R_Forearm': 'Bip01_R_UpperArm'}

ATLAS = 1024
DENSITY = 1250.0         # texture pixels per model unit on the visible surfaces (about 7 px per real centimetre)
SHIP = 512               # the atlas is painted at ATLAS and shipped at this size (in the game the pack is a few dozen
                         # pixels tall: the painted detail survives the halving, the file is a quarter)
# Mesh resolution: the soft boxes' flat-face steps, and the shoulder straps' samples along and around. Chosen against
# the before/after sheet so that the silhouette and the straps' run over the shoulders look the same in the game.
MAIN_RES = 4
STRAP_STEPS, STRAP_PROF = 26, 8
WEB_STEPS = 16


# ======================================================================================================================
# Small math helpers
# ======================================================================================================================
def unit(v):
    v = np.asarray(v, float)
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def units(A):
    A = np.asarray(A, float)
    n = np.linalg.norm(A, axis=-1, keepdims=True)
    return A / np.where(n > 0, n, 1)


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, float) - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def rot(axis, deg):
    """3x3 rotation (column vectors: p' = R @ p) about a unit axis."""
    a = unit(axis)
    t = math.radians(deg)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(t) * K + (1 - math.cos(t)) * K @ K


def catmull(points, n):
    """Centripetal Catmull-Rom through `points`, resampled to n points evenly spaced by arc length."""
    P = [np.asarray(p, float) for p in points]
    P = [2 * P[0] - P[1]] + P + [2 * P[-1] - P[-2]]
    dense = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]

        def tj(ti, a, b):
            return ti + max(np.linalg.norm(b - a), 1e-9) ** 0.5
        t0 = 0.0
        t1 = tj(t0, p0, p1)
        t2 = tj(t1, p1, p2)
        t3 = tj(t2, p2, p3)
        for t in np.linspace(t1, t2, 24, endpoint=False):
            a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
            a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
            a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
            b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
            b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
            dense.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
    dense.append(P[-2])
    return resample(np.array(dense), n)


def resample(D, n):
    seg = np.linalg.norm(np.diff(D, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    out = []
    for target in np.linspace(0, s[-1], n):
        k = min(np.searchsorted(s, target, side='right') - 1, len(D) - 2)
        f = (target - s[k]) / max(seg[k], 1e-12)
        out.append(D[k] * (1 - f) + D[k + 1] * f)
    return np.array(out)


def arclen(D):
    return np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(D, axis=0), axis=1))])


def closest_on_tris(p, A, B, C):
    """Closest point on each triangle (Ericson), vectorised over the triangles: points (m,3), barycentrics (m,3)."""
    ab, ac, ap = B - A, C - A, p - A
    d1 = (ab * ap).sum(1)
    d2 = (ac * ap).sum(1)
    bp = p - B
    d3 = (ab * bp).sum(1)
    d4 = (ac * bp).sum(1)
    cp = p - C
    d5 = (ab * cp).sum(1)
    d6 = (ac * cp).sum(1)
    vc = d1 * d4 - d3 * d2
    vb = d5 * d2 - d1 * d6
    va = d3 * d6 - d5 * d4
    m = len(A)
    bc = np.zeros((m, 3))
    done = np.zeros(m, bool)

    def put(mask, u, v, w):
        mask = mask & ~done
        bc[mask, 0] = u[mask]
        bc[mask, 1] = v[mask]
        bc[mask, 2] = w[mask]
        done[mask] = True
    one, zero = np.ones(m), np.zeros(m)
    with np.errstate(divide='ignore', invalid='ignore'):
        put((d1 <= 0) & (d2 <= 0), one, zero, zero)
        put((d3 >= 0) & (d4 <= d3), zero, one, zero)
        v = d1 / (d1 - d3)
        put((vc <= 0) & (d1 >= 0) & (d3 <= 0), 1 - v, v, zero)
        put((d6 >= 0) & (d5 <= d6), zero, zero, one)
        w = d2 / (d2 - d6)
        put((vb <= 0) & (d2 >= 0) & (d6 <= 0), 1 - w, zero, w)
        w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        put((va <= 0) & ((d4 - d3) >= 0) & ((d5 - d6) >= 0), zero, 1 - w, w)
        den = 1.0 / (va + vb + vc)
        v = vb * den
        w = vc * den
        put(np.ones(m, bool), 1 - v - w, v, w)
    bc = np.nan_to_num(bc)
    return A * bc[:, :1] + B * bc[:, 1:2] + C * bc[:, 2:3], bc


def raycast(o, d, A, B, C):
    """First hit of the ray o + t d (t > 0) on the triangles: (t, triangle, barycentric u, v) or None."""
    e1, e2 = B - A, C - A
    pv = np.cross(d, e2)
    det = (e1 * pv).sum(1)
    ok = np.abs(det) > 1e-14
    inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
    tv = o - A
    u = (tv * pv).sum(1) * inv
    qv = np.cross(tv, e1)
    v = (qv @ d) * inv
    t = (qv * e2).sum(1) * inv
    hit = ok & (u >= -1e-9) & (v >= -1e-9) & (u + v <= 1 + 1e-9) & (t > 1e-7)
    if not hit.any():
        return None
    k = np.where(hit)[0][np.argmin(t[hit])]
    return t[k], k, u[k], v[k]


# ======================================================================================================================
# DirectX .x reading (vanilla bodies and packs)
# ======================================================================================================================
MATRIX = r'(-?[0-9.]+(?:,-?[0-9.]+){15});;'


def read_text(path):
    with open(path, 'rb') as f:
        return f.read().decode('latin-1').replace('\r\n', '\n')


def parse_x(path):
    """First mesh of a .x file: dict(V, T (triangles), UV, N (per vertex, may be None), bones {name: (idx, w, matrix
    text)})."""
    txt = read_text(path)
    mm = re.search(r'\n\s*Mesh (\w*) \{\n\s*(\d+);\n', txt)
    nv = int(mm.group(2))
    pos = mm.end()

    def rows(pos, n):
        out = []
        for _ in range(n):
            e = txt.index('\n', pos)
            out.append(txt[pos:e].strip())
            pos = e + 1
        return out, pos
    r, pos = rows(pos, nv)
    V = np.array([[float(x) for x in s.rstrip(',;').split(';')[:3]] for s in r])
    m = re.match(r'\s*(\d+);\n', txt[pos:])
    r, pos = rows(pos + m.end(), int(m.group(1)))
    T = []
    for s in r:
        ids = [int(i) for i in s.rstrip(',;').split(';')[1].split(',')]
        T += [(ids[0], ids[k], ids[k + 1]) for k in range(1, len(ids) - 1)]
    um = re.search(r'MeshTextureCoords \w* ?\{\n\s*(\d+);\n', txt)
    UV = None
    if um:
        r, _ = rows(um.end(), int(um.group(1)))
        UV = np.array([[float(x) for x in s.rstrip(',;').split(';')[:2]] for s in r])
    nm = re.search(r'MeshNormals \{\n\s*(\d+);\n', txt)
    N = None
    if nm and int(nm.group(1)) == nv:
        r, _ = rows(nm.end(), nv)
        N = np.array([[float(x) for x in s.rstrip(',;').split(';')[:3]] for s in r])
    bones = {}
    for s in re.finditer(r'SkinWeights \{\n\s*"(\w+)";\n\s*(\d+);\n', txt):
        cnt = int(s.group(2))
        if cnt == 0:
            continue
        rest = txt[s.end():s.end() + 48 * (2 * cnt + 2)].split('\n')
        idx = np.array([int(x.strip().rstrip(',;')) for x in rest[:cnt]], int)
        w = np.array([float(x.strip().rstrip(',;')) for x in rest[cnt:2 * cnt]])
        mat = re.match(r'\s*' + MATRIX, rest[2 * cnt]).group(1)
        bones[s.group(1)] = (idx, w, mat)
    return dict(V=V, T=np.array(T, int), UV=UV, N=N, bones=bones, txt=txt)


def matrix_of(text):
    return np.array([float(x) for x in text.split(',')]).reshape(4, 4)


def bone_origin(text):
    M = matrix_of(text)
    return -M[3, :3] @ np.linalg.inv(M[:3, :3])


def vertex_normals(V, T):
    """Area weighted normals, welded by position (a .x mesh splits vertices at uv seams)."""
    fn = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
    key = np.round(V, 6)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros((inv.max() + 1, 3))
    for k in range(3):
        np.add.at(acc, inv[T[:, k]], fn)
    return units(acc[inv])


class Body:
    """A vanilla body in its bind pose: surface queries for fitting the straps, and its skin weights."""

    def __init__(self, fname):
        d = parse_x(os.path.join(SKINNED, fname))
        self.V, self.T = d['V'], d['T']
        self.names = sorted(d['bones'])
        self.mats = {b: d['bones'][b][2] for b in self.names}
        self.W = np.zeros((len(self.V), len(self.names)))
        for j, b in enumerate(self.names):
            idx, w, _ = d['bones'][b]
            self.W[idx, j] += w
        self.VN = vertex_normals(self.V, self.T)
        # orient outward: torso normals point away from the spine axis
        torso = (np.abs(self.V[:, 0]) < 0.08) & (self.V[:, 1] > 0.55) & (self.V[:, 1] < 0.75)
        axis = np.stack([np.zeros(torso.sum()), self.V[torso, 1], np.full(torso.sum(), 0.02)], 1)
        if ((self.V[torso] - axis) * self.VN[torso]).sum() < 0:
            self.VN = -self.VN
            self.T = self.T[:, [0, 2, 1]]
        # the surface the straps lie on: everything but the forearms, hands, legs and the head above the neck
        bad = [j for j, b in enumerate(self.names) if any(k in b for k in ('Forearm', 'Hand', 'Finger', 'Thigh', 'Calf',
                                                                           'Foot', 'Toe', 'Head'))]
        tri_bad = self.W[self.T][:, :, bad].sum(2).mean(1) > 0.5
        self.ST = self.T[~tri_bad]
        self.A, self.B, self.C = (self.V[self.ST[:, k]] for k in range(3))
        self.allA, self.allB, self.allC = (self.V[self.T[:, k]] for k in range(3))

    def origin(self, bone):
        return bone_origin(self.mats[bone])

    def closest(self, p, full=False):
        """(point, smooth normal, weights row, signed distance) of the strap surface point closest to p."""
        A, B, C, T = (self.allA, self.allB, self.allC, self.T) if full else (self.A, self.B, self.C, self.ST)
        q, bc = closest_on_tris(p, A, B, C)
        d = ((q - p) ** 2).sum(1)
        k = int(np.argmin(d))
        tri = T[k]
        n = unit((self.VN[tri] * bc[k][:, None]).sum(0))
        w = (self.W[tri] * bc[k][:, None]).sum(0)
        return q[k], n, w, float(np.dot(p - q[k], n))

    def ray(self, o, d):
        """(point, smooth normal) where the ray o + t d first meets the strap surface, or None."""
        r = raycast(np.asarray(o, float), unit(d), self.A, self.B, self.C)
        if r is None:
            return None
        t, k, u, v = r
        tri = self.ST[k]
        n = unit(self.VN[tri[0]] * (1 - u - v) + self.VN[tri[1]] * u + self.VN[tri[2]] * v)
        return np.asarray(o, float) + unit(d) * t, n

    def front_half_width(self, y):
        """How far out from the middle the chest still faces forward at height y (rays from the front)."""
        best = 0.0
        for x in np.arange(0.0, 0.14, 0.004):
            r = raycast(np.array([x, y, -1.0]), np.array([0, 0, 1.0]), self.A, self.B, self.C)
            if r is not None and r[0] - 1.0 < 0.0:
                best = x
        return best

    def back_z(self, x, y):
        """z of the back surface seen from behind at (x, y), or None."""
        r = raycast(np.array([x, y, 1.0]), np.array([0, 0, -1.0]), self.allA, self.allB, self.allC)
        return None if r is None else 1.0 - r[0]


# ======================================================================================================================
# Parts: indexed meshes with uv; normals are computed from the final positions
# ======================================================================================================================
class Part:
    def __init__(self, name, mat=''):
        self.name, self.mat = name, mat
        self.P, self.UV, self.F = [], [], []
        self.hard = False   # True: flat shaded (every triangle owns its vertices)

    def add(self, p, uv):
        self.P.append(np.asarray(p, float))
        self.UV.append(uv)
        return len(self.P) - 1

    def tri(self, a, b, c):
        self.F.append((a, b, c))

    def quad(self, a, b, c, d):
        self.F.append((a, b, c))
        self.F.append((a, c, d))

    def arrays(self):
        return np.array(self.P, float), np.array(self.UV, float), np.array(self.F, int)

    def copy(self, fn=None, mirror=False, name=None):
        out = Part(name or self.name, self.mat)
        P = np.array(self.P, float)
        if mirror:
            P = P * np.array([-1, 1, 1])
        if fn is not None:
            P = fn(P)
        out.P = list(P)
        out.UV = list(self.UV)
        out.F = [(a, c, b) for a, b, c in self.F] if mirror else list(self.F)
        out.hard = self.hard
        return out

    def orient(self):
        """Make the winding outward (positive signed volume about the part's own centre; parts are closed or have one
        small opening)."""
        P, _, F = self.arrays()
        P = P - P.mean(0)
        vol = np.einsum('ij,ij->i', P[F[:, 0]], np.cross(P[F[:, 1]], P[F[:, 2]])).sum()
        if vol < 0:
            self.F = [(a, c, b) for a, b, c in self.F]
        return self


def part_normals(P, F, hard=False):
    fn = np.cross(P[F[:, 1]] - P[F[:, 0]], P[F[:, 2]] - P[F[:, 0]])
    if hard:
        N = np.zeros_like(P)
        for k in range(3):
            N[F[:, k]] = units(fn)
        return N
    return vertex_normals(P, F) if len(F) else np.zeros_like(P)


class Mesh:
    """A whole model: parts concatenated, normals per part, skin weights per vertex {bone: array}."""

    def __init__(self, parts, normals=True):
        self.parts = parts
        P, N, UV, F, tag = [], [], [], [], []
        base = 0
        for pt in parts:
            p, uv, f = pt.arrays()
            if not len(f):
                continue
            if pt.hard:   # every triangle its own vertices
                p, uv = p[f.reshape(-1)], uv[f.reshape(-1)]
                f = np.arange(len(p)).reshape(-1, 3)
            P.append(p)
            UV.append(uv)
            N.append(part_normals(p, f, pt.hard))
            F.append(f + base)
            tag += [pt.name] * len(p)
            base += len(p)
        self.P = np.concatenate(P)
        self.N = np.concatenate(N)
        self.UV = np.concatenate(UV)
        self.F = np.concatenate(F)
        self.TAG = np.array(tag)
        self.W = {}

    def arrays(self):
        return self.P, self.N, self.UV, self.F

    def transformed(self, fn_pos, fn_dir, flip=False):
        m = Mesh.__new__(Mesh)
        m.parts = self.parts
        m.P = fn_pos(self.P)
        m.N = units(fn_dir(self.N))
        m.UV = self.UV.copy()
        m.F = self.F[:, [0, 2, 1]] if flip else self.F.copy()
        m.TAG = self.TAG
        m.W = {k: v.copy() for k, v in self.W.items()}
        return m


# ======================================================================================================================
# Texture charts and atlas packing
# ======================================================================================================================
class Chart:
    """A rectangle of the atlas. (s, t) in [0, 1] map to its inner area (1.5 px off the border)."""

    def __init__(self, name, w, h, mat):
        self.name, self.w, self.h, self.mat = name, int(math.ceil(w)), int(math.ceil(h)), mat
        self.rect = None

    def uv(self, s, t):
        x0, y0, x1, y1 = self.rect
        return ((x0 + 1.5 + s * (x1 - x0 - 3)) / ATLAS, (y0 + 1.5 + t * (y1 - y0 - 3)) / ATLAS)

    def px(self, s, t):
        x0, y0, x1, y1 = self.rect
        return x0 + 1.5 + s * (x1 - x0 - 3), y0 + 1.5 + t * (y1 - y0 - 3)


def pack_charts(charts, size=ATLAS, pad=3):
    """Shelf packing, tallest first. Raises when the charts do not fit."""
    order = sorted(charts, key=lambda c: (-c.h, -c.w, c.name))
    x = y = shelf = 0
    for c in order:
        if x + c.w + pad > size:
            x, y, shelf = 0, y + shelf + pad, 0
        if y + c.h > size:
            raise ValueError('atlas full at chart ' + c.name)
        c.rect = (x, y, x + c.w, y + c.h)
        x += c.w + pad
        shelf = max(shelf, c.h)
    return y + shelf


# ======================================================================================================================
# The pack's dimensions (pack-local units; 1 unit is about 1.85 m, so 0.1 is about 18 cm)
# ======================================================================================================================
Y0 = 0.556                                      # bottom of the main body
MAIN = dict(half=(0.092, 0.122, 0.054), r=0.028, centre=(0.0, Y0 + 0.122, 0.054),
            bulge={'+y': 0.026, '+z': 0.011, '-z': 0.003, '+x': 0.006, '-x': 0.006, '-y': 0.003},
            taper=(0.10, 0.22))                 # x and z shrink by these fractions from bottom to top
LID_CUT = (0.770, 0.752)                        # lid hem height at the back and at the front
LID_T = 0.0065                                  # lid thickness over the main body
POUCH = dict(half=(0.071, 0.050, 0.023), r=0.014, centre=(0.0, Y0 + 0.062, 0.108 + 0.016),
             bulge={'+z': 0.008, '+y': 0.004, '+x': 0.003, '-x': 0.003, '-y': 0.002, '-z': 0.0}, taper=(0.04, 0.10))
CPOUCH = dict(half=(0.0185, 0.040, 0.037), r=0.008, centre=(0.1065, Y0 + 0.056, 0.056),
              bulge={'+x': 0.004, '+z': 0.003, '-z': 0.003, '-y': 0.002, '+y': 0.0, '-x': 0.0}, taper=(0.0, 0.0))
CANTEEN = dict(half=(0.0145, 0.050, 0.032), r=0.0125, centre=(0.1075, Y0 + 0.071, 0.056),
               bulge={'+y': 0.010, '+x': 0.003, '-x': 0.0, '+z': 0.002, '-z': 0.002, '-y': 0.0}, taper=(0.0, 0.0))
CAP_R, NECK_R = 0.0105, 0.0075
STRAP_ROOT = (0.052, 0.792, 0.006)              # where a shoulder strap leaves the back panel (local, +x side)
STRAP_FOOT = (0.080, 0.578, 0.008)              # where the lower webbing enters the pack's bottom corner
STRAP_W, STRAP_T = 0.031, 0.0085                # padded shoulder strap
WEB_W, WEB_T = 0.0155, 0.0028                   # 1" webbing
CLEAR_BACK = 0.010                              # gap between the body's back and the back panel at the shoulder blades
CLEAR_STRAP = 0.0075                            # gap between the body and a strap's inner face


# ======================================================================================================================
# Soft rounded boxes
# ======================================================================================================================
# face: (axis, sign, u axis (screen right seen from outside), v axis (screen down))
FACES = {
    '+z': (2, 1, (-1, 0, 0), (0, -1, 0)), '-z': (2, -1, (1, 0, 0), (0, -1, 0)),
    '+x': (0, 1, (0, 0, 1), (0, -1, 0)), '-x': (0, -1, (0, 0, -1), (0, -1, 0)),
    '+y': (1, 1, (-1, 0, 0), (0, 0, 1)), '-y': (1, -1, (-1, 0, 0), (0, 0, -1)),
}


class SoftBox:
    """A box with rounded edges (radius r), its faces bulged outward like stuffed fabric, tapered toward the top.
    Faces are sampled on (a, b) in [-1, 1]^2 along the face's u and v axes (box-surface coordinates / half size)."""

    def __init__(self, centre, half, r, bulge=None, taper=(0.0, 0.0), bend=0.0, back=None, band=3):
        self.c = np.array(centre, float)
        self.h = np.array(half, float)
        self.r = r
        self.bulge = bulge or {}
        self.taper = taper
        self.bend = bend            # x displacement by depth^2 (a canteen's kidney curve)
        self.back = self.c[2] - self.h[2] if back is None else back
        self.band = band

    def axis_coords(self, k, n_mid, n_band=None):
        """Normalised coordinates along axis k: uniform arc steps on the rounded bands, linear in between."""
        n_band = n_band or self.band
        h, r = self.h[k], min(self.r, self.h[k] * 0.999)
        inner = h - r
        band = [inner + r * math.tan(math.radians(45.0 * i / n_band)) for i in range(1, n_band + 1)]
        mid = list(np.linspace(-inner, inner, n_mid + 1)) if inner > 1e-9 else [0.0]
        xs = [-b for b in reversed(band)] + mid + band
        return np.array(xs) / h

    def base(self, face, a, b):
        k, s, U, V = FACES[face]
        U, V = np.array(U, float), np.array(V, float)
        ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
        p = np.zeros(3)
        p[k] = s * self.h[k]
        p += U * a * self.h[ku] + V * b * self.h[kv]
        return p

    def point(self, face, a, b, offset=0.0):
        p = self.base(face, a, b)
        inner = np.maximum(self.h - self.r, 0)
        cl = np.clip(p, -inner, inner)
        d = p - cl
        n = unit(d) if np.linalg.norm(d) > 1e-12 else np.eye(3)[FACES[face][0]] * FACES[face][1]
        q = cl + n * (min(self.r, self.h.min()) + offset)
        q = q + n * self.bulge.get(face, 0.0) * (1 - a * a) * (1 - b * b)
        # taper about the back plane and the vertical axis
        yrel = np.clip((q[1] + self.h[1]) / (2 * self.h[1]), 0, 1.3)
        q[0] *= 1 - self.taper[0] * yrel
        zb = self.back - self.c[2]
        q[2] = zb + (q[2] - zb) * (1 - self.taper[1] * yrel)
        q[0] += self.bend * (q[2] / self.h[2]) ** 2
        return q + self.c

    def size(self, face):
        _, _, U, V = FACES[face]
        ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
        return 2 * self.h[ku], 2 * self.h[kv]

    def part(self, name, charts, mat, res=6, skip=(), offset=0.0, vrange=None, part=None):
        """charts: face -> Chart. vrange(face, a) -> (b0, b1) restricts a face's v range per column (for the lid)."""
        pt = part or Part(name, mat)
        for face, chart in charts.items():
            if face in skip:
                continue
            k, s, U, V = FACES[face]
            ku, kv = int(np.argmax(np.abs(U))), int(np.argmax(np.abs(V)))
            As = self.axis_coords(ku, res)
            Bs = self.axis_coords(kv, res)
            grid = []
            for a in As:
                col = []
                if vrange:
                    b0, b1 = vrange(face, a)
                    bs = np.linspace(b0, b1, max(3, int(round((b1 - b0) / 2 * (len(Bs) - 1))) + 1))
                else:
                    bs = Bs
                for b in bs:
                    q = self.point(face, a, b, offset)
                    col.append(pt.add(q, chart.uv((a + 1) / 2, (b + 1) / 2)))
                grid.append(col)
            for i in range(len(grid) - 1):
                c0, c1 = grid[i], grid[i + 1]
                n = min(len(c0), len(c1))
                for j in range(n - 1):
                    pt.quad(c0[j], c1[j], c1[j + 1], c0[j + 1])
        return pt


# ======================================================================================================================
# Swept bands (straps, webbing, handle) and small hardware
# ======================================================================================================================
def profile(width, thick, n=12, squareness=4.0):
    """A rounded-rectangle cross-section, starting at the middle of the inner face, counter-clockwise in (side, out)."""
    a, b = width / 2, thick / 2
    pts = []
    for i in range(n):
        t = -math.pi / 2 + 2 * math.pi * i / n
        c, s = math.cos(t), math.sin(t)
        pts.append((a * math.copysign(abs(c) ** (2 / squareness), c), b * math.copysign(abs(s) ** (2 / squareness), s)))
    return np.array(pts)


def sweep(name, path, outs, width, thick, chart, mat, n_prof=12, v_range=(0.0, 1.0), caps=True, squareness=4.0,
          widths=None):
    """A band along `path` (k,3) whose outer face looks along `outs` (k,3). u runs around the cross-section (outer face
    in the middle of the chart's width), v along the path."""
    path = np.asarray(path, float)
    k = len(path)
    T = np.gradient(path, axis=0)
    T = units(T)
    O = units(np.asarray(outs, float) - (np.asarray(outs, float) * T).sum(1, keepdims=True) * T)
    S = np.cross(T, O)
    s = arclen(path)
    s = s / max(s[-1], 1e-12)
    pt = Part(name, mat)
    rings = []
    for i in range(k):
        w = widths[i] if widths is not None else width
        prof = profile(w, thick, n_prof, squareness)
        per = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(np.vstack([prof, prof[:1]]), axis=0), axis=1))])
        per = per / per[-1]
        ring = []
        for j in range(n_prof + 1):
            px, py = prof[j % n_prof]
            q = path[i] + S[i] * px + O[i] * py
            ring.append(pt.add(q, chart.uv(per[j], v_range[0] + (v_range[1] - v_range[0]) * s[i])))
        rings.append(ring)
    for i in range(k - 1):
        for j in range(n_prof):
            pt.quad(rings[i][j], rings[i][j + 1], rings[i + 1][j + 1], rings[i + 1][j])
    if caps:
        for i, sign in ((0, -1), (k - 1, 1)):
            c = pt.add(path[i] + T[i] * 0.0, chart.uv(0.5, v_range[0] if i == 0 else v_range[1]))
            for j in range(n_prof):
                a, b = rings[i][j], rings[i][j + 1]
                if sign < 0:
                    pt.tri(c, b, a)
                else:
                    pt.tri(c, a, b)
    pt.orient()
    return pt


def box_part(name, centre, half, frame, chart, mat, hard=True):
    """A small box (buckles): centre, half sizes along the frame's columns (3x3: side, up, out)."""
    pt = Part(name, mat)
    pt.hard = hard
    c = np.asarray(centre, float)
    E = np.asarray(frame, float)
    idx = {}
    for i in (-1, 1):
        for j in (-1, 1):
            for k in (-1, 1):
                q = c + E[:, 0] * half[0] * i + E[:, 1] * half[1] * j + E[:, 2] * half[2] * k
                idx[(i, j, k)] = pt.add(q, chart.uv((i + 1) / 2, (1 - j) / 2))
    quads = [((1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)), ((-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)),
             ((-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)), ((-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)),
             ((-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)), ((-1, -1, -1), (-1, 1, -1), (1, 1, -1), (1, -1, -1))]
    for q in quads:
        pt.quad(*[idx[v] for v in q])
    return pt.orient()


def cylinder(name, base, axis, radius, height, chart, mat, n=14, cap_top=True, ridges=0.0):
    """A cylinder standing on `base` along `axis` (screw cap, canteen neck)."""
    ax = unit(axis)
    e1 = unit(np.cross(ax, [0, 0, 1.0]) if abs(ax[2]) < 0.9 else np.cross(ax, [1.0, 0, 0]))
    e2 = np.cross(ax, e1)
    pt = Part(name, mat)
    rings = []
    for yy, tv in ((0.0, 1.0), (height, 0.0)):
        ring = []
        for i in range(n + 1):
            t = 2 * math.pi * i / n
            r = radius * (1 + ridges * (1 if i % 2 else -1))
            q = np.asarray(base, float) + ax * yy + (e1 * math.cos(t) + e2 * math.sin(t)) * r
            ring.append(pt.add(q, chart.uv(i / n, tv * 0.75)))
        rings.append(ring)
    for i in range(n):
        pt.quad(rings[0][i], rings[0][i + 1], rings[1][i + 1], rings[1][i])
    if cap_top:
        c = pt.add(np.asarray(base, float) + ax * height, chart.uv(0.5, 0.9))
        for i in range(n):
            pt.tri(c, rings[1][i], rings[1][i + 1])
    pt.orient()
    return pt


# ======================================================================================================================
# The pack (pack-local space)
# ======================================================================================================================
def define_charts():
    """Every atlas rectangle, sized by the surface it covers. Mirrored parts (left/right) share a chart."""
    D = DENSITY
    C = {}

    def add(name, w, h, mat, dens=1.0):
        C[name] = Chart(name, w * D * dens, h * D * dens, mat)
    mb = SoftBox(MAIN['centre'], MAIN['half'], MAIN['r'])
    W, H = mb.size('+z')
    Dp, _ = mb.size('+x')
    add('main_front', W * 1.08, H * 1.06, 'canvas')
    add('main_back', W * 1.04, H * 1.04, 'padding', 0.7)
    add('main_side', Dp * 1.06, H * 1.04, 'canvas')
    add('main_bottom', W * 1.04, Dp * 1.04, 'base', 0.6)
    add('lid_top', W * 1.14, Dp * 1.2, 'canvas')
    add('lid_front', W * 1.12, 0.06, 'canvas')
    add('lid_side', Dp * 1.2, 0.05, 'canvas')
    add('lid_back', W * 1.1, 0.04, 'canvas', 0.6)
    add('lid_rim', 0.4, 0.012, 'binding', 0.6)
    pb = SoftBox(POUCH['centre'], POUCH['half'], POUCH['r'])
    add('pouch_front', pb.size('+z')[0] * 1.08, pb.size('+z')[1] * 1.08, 'canvas')
    add('pouch_side', pb.size('+x')[0] * 1.1, pb.size('+x')[1] * 1.08, 'canvas')
    add('pouch_top', pb.size('+y')[0] * 1.08, pb.size('+y')[1] * 1.1, 'canvas')
    add('pouch_bottom', pb.size('-y')[0], pb.size('-y')[1], 'base', 0.5)
    cp = SoftBox(CPOUCH['centre'], CPOUCH['half'], CPOUCH['r'])
    add('cpouch_out', cp.size('+x')[0] * 1.1, cp.size('+x')[1] * 1.1, 'canvas')
    add('cpouch_end', cp.size('+z')[0] * 1.2, cp.size('+z')[1] * 1.1, 'canvas')
    add('cpouch_top', cp.size('+y')[0] * 1.1, cp.size('+y')[1] * 1.2, 'binding')
    add('cpouch_bottom', cp.size('-y')[0], cp.size('-y')[1], 'base', 0.6)
    cb = SoftBox(CANTEEN['centre'], CANTEEN['half'], CANTEEN['r'])
    add('canteen_side', cb.size('+x')[0] * 1.1, cb.size('+x')[1] * 1.1, 'plastic')
    add('canteen_end', cb.size('+z')[0] * 1.2, cb.size('+z')[1] * 1.1, 'plastic')
    add('canteen_top', cb.size('+y')[0] * 1.1, cb.size('+y')[1] * 1.3, 'plastic')
    add('cap', 2 * math.pi * CAP_R, 0.016, 'cap', 1.6)
    add('neck', 2 * math.pi * NECK_R, 0.010, 'plastic', 1.4)
    add('strap', 0.075, 0.40, 'strap')
    add('web', 0.036, 0.32, 'web')
    add('hard', 0.016, 0.016, 'hard')
    add('metal', 0.016, 0.016, 'metal')
    add('handle', 0.07, 0.08, 'web')
    return C


def wrap_sweep(name, P, N, centre_on, width, thick, chart, mat, offset, v_len, n_prof=6):
    """A webbing band lying on a surface along hit points P with normals N (from drape)."""
    path = np.asarray(P) + np.asarray(N) * (offset + thick / 2)
    L = arclen(path)[-1]
    return sweep(name, path, N, width, thick, chart, mat, n_prof=n_prof, v_range=(0.0, min(1.0, L / v_len)))


class Drape:
    """Ray casting onto the pack built so far (smooth normals interpolated from the parts)."""

    def __init__(self, parts):
        m = Mesh(parts)
        self.P, self.N, self.F = m.P, m.N, m.F
        self.A, self.B, self.C = (self.P[self.F[:, k]] for k in range(3))

    def hit(self, o, d):
        r = raycast(np.asarray(o, float), unit(d), self.A, self.B, self.C)
        if r is None:
            return None, None
        t, k, u, v = r
        f = self.F[k]
        n = unit(self.N[f[0]] * (1 - u - v) + self.N[f[1]] * u + self.N[f[2]] * v)
        return np.asarray(o, float) + unit(d) * t, n

    def line(self, origins, dirs):
        P, N = [], []
        for o, d in zip(origins, dirs):
            p, n = self.hit(o, d)
            if p is not None:
                P.append(p)
                N.append(n)
        return np.array(P), np.array(N)


def lid_vrange(face, a):
    """The lid covers the top and the upper band of the four sides; its hem runs from LID_CUT back to front."""
    if face == '+y':
        return -1.0, 1.0
    h, cy = MAIN['half'][1], MAIN['centre'][1]
    if face == '+z':
        y = LID_CUT[1]
    elif face == '-z':
        y = LID_CUT[0]
    else:   # sides: u runs along z; on '+x' u = +1 is the front (z max), on '-x' u = -1 is the front
        front = (a + 1) / 2 if face == '+x' else (1 - a) / 2
        y = LID_CUT[0] + (LID_CUT[1] - LID_CUT[0]) * front
    b_cut = (cy - y) / h            # v axis points down: b = (cy - y) / h
    return -1.0, b_cut


def build_pack(C):
    """The pack without its shoulder straps, in pack-local space. Returns the parts (left/right pairs included)."""
    parts = []
    main = SoftBox(MAIN['centre'], MAIN['half'], MAIN['r'], MAIN['bulge'], MAIN['taper'], back=0.0)
    parts.append(main.part('main', {'+z': C['main_front'], '-z': C['main_back'], '+x': C['main_side'],
                                    '-x': C['main_side'], '-y': C['main_bottom']}, 'canvas',
                           res=MAIN_RES).orient())
    # lid: the main body's top region offset outward, with a hem band closing it to the body
    lid = main.part('lid', {'+y': C['lid_top'], '+z': C['lid_front'], '-z': C['lid_back'], '+x': C['lid_side'],
                            '-x': C['lid_side']}, 'canvas', res=MAIN_RES, offset=LID_T, vrange=lid_vrange)
    hem_outer, hem_inner = [], []
    for face in ('+z', '-x', '-z', '+x'):   # around the pack
        k, s, U, V = FACES[face]
        ku = int(np.argmax(np.abs(U)))
        for a in main.axis_coords(ku, MAIN_RES)[:-1]:
            _, b1 = lid_vrange(face, a)
            hem_outer.append(main.point(face, a, b1, LID_T))
            hem_inner.append(main.point(face, a, b1, -0.002))
    hem = Part('lid_hem', 'binding')
    ring_o, ring_i = [], []
    n = len(hem_outer)
    for i in range(n + 1):
        j = i % n
        ring_o.append(hem.add(hem_outer[j], C['lid_rim'].uv(i / n, 0.1)))
        ring_i.append(hem.add(hem_inner[j], C['lid_rim'].uv(i / n, 0.9)))
    for i in range(n):
        hem.quad(ring_o[i], ring_o[i + 1], ring_i[i + 1], ring_i[i])
    Ph, _, Fh = hem.arrays()
    if np.cross(Ph[Fh[:, 1]] - Ph[Fh[:, 0]], Ph[Fh[:, 2]] - Ph[Fh[:, 0]])[:, 1].sum() > 0:
        hem.F = [(a, c, b) for a, b, c in hem.F]
    # the lid is an open shell closed by the hem: orient it by a probe instead of by volume
    P, _, F = lid.arrays()
    top = [f for f in F if min(P[f, 1]) > MAIN['centre'][1] + MAIN['half'][1]]
    f = top[0]
    nrm = np.cross(P[f[1]] - P[f[0]], P[f[2]] - P[f[0]])
    if nrm[1] < 0:
        lid.F = [(a, c, b) for a, b, c in lid.F]
    parts.append(lid)
    parts.append(hem)
    # front pouch
    pouch = SoftBox(POUCH['centre'], POUCH['half'], POUCH['r'], POUCH['bulge'], POUCH['taper'], band=2)
    parts.append(pouch.part('pouch', {'+z': C['pouch_front'], '+x': C['pouch_side'], '-x': C['pouch_side'],
                                      '+y': C['pouch_top'], '-y': C['pouch_bottom']}, 'canvas', res=3,
                            skip=('-z',)).orient())
    # canteen pouch and canteen on the +x side, mirrored to -x
    cpouch = SoftBox(CPOUCH['centre'], CPOUCH['half'], CPOUCH['r'], CPOUCH['bulge'], band=2)
    cp = cpouch.part('cpouch', {'+x': C['cpouch_out'], '+z': C['cpouch_end'], '-z': C['cpouch_end'],
                                '+y': C['cpouch_top'], '-y': C['cpouch_bottom']}, 'canvas', res=2, skip=('-x',)).orient()
    canteen = SoftBox(CANTEEN['centre'], CANTEEN['half'], CANTEEN['r'], CANTEEN['bulge'], bend=-0.004, band=2)
    ct = canteen.part('canteen', {'+x': C['canteen_side'], '-x': C['canteen_side'], '+z': C['canteen_end'],
                                  '-z': C['canteen_end'], '+y': C['canteen_top']}, 'plastic', res=2,
                      skip=('-y',)).orient()
    top = canteen.point('+y', 0.0, 0.0)
    neck = cylinder('neck', top - np.array([0, 0.004, 0]), (0, 1, 0), NECK_R, 0.009, C['neck'], 'plastic', n=12,
                    cap_top=False)
    cap = cylinder('cap', top + np.array([0, 0.004, 0]), (0, 1, 0), CAP_R, 0.0105, C['cap'], 'cap', n=16, ridges=0.04)
    # the pouch's retaining strap over the canteen's shoulder (a short webbing band with a snap)
    dr = Drape([ct])
    zc = CANTEEN['centre'][2]
    ys = np.linspace(CPOUCH['centre'][1] + CPOUCH['half'][1] - 0.004, top[1] - 0.006, 6)
    o = [np.array([0.3, y, zc + 0.006]) for y in ys]
    Ph, Nh = dr.line(o, [np.array([-1.0, 0, 0])] * len(o))
    keeper = wrap_sweep('keeper', Ph, Nh, None, 0.014, 0.0025, C['web'], 'web', 0.0005, 0.32, n_prof=6)
    snap = box_part('snap', Ph[-1] + Nh[-1] * 0.003, (0.004, 0.004, 0.0015),
                    np.stack([np.array([0, 0, 1.0]), np.array([0, 1.0, 0]), Nh[-1]], 1), C['metal'], 'metal')
    for p in (cp, ct, neck, cap, keeper, snap):
        parts.append(p)
        parts.append(p.copy(mirror=True, name=p.name))
    base_parts = list(parts)
    drape = Drape(base_parts)
    # MOLLE rows across the pouch front
    for i, y in enumerate((POUCH['centre'][1] + 0.022, POUCH['centre'][1] - 0.002, POUCH['centre'][1] - 0.026)):
        xs = np.linspace(-0.062, 0.062, 11)
        P, N = drape.line([np.array([x, y, 0.5]) for x in xs], [np.array([0, 0, -1.0])] * len(xs))
        parts.append(wrap_sweep('molle', P, N, None, 0.0115, 0.0022, C['web'], 'web', 0.0004, 0.32, n_prof=6))
    drape = Drape(parts)
    # two vertical compression straps down the front, over lid, body and pouch, with a buckle each
    for sx in (-1, 1):
        x = sx * 0.050
        ys = np.linspace(0.835, Y0 + 0.004, 24)
        P, N = drape.line([np.array([x, y, 0.5]) for y in ys], [unit((0, -0.05, -1.0))] * len(ys))
        parts.append(wrap_sweep('front_strap', P, N, None, WEB_W * 0.9, WEB_T, C['web'], 'web', 0.0006, 0.32))
        k = int(np.argmin(np.abs(P[:, 1] - 0.703)))
        Tn = unit(P[k + 1] - P[k - 1])
        frame = np.stack([unit(np.cross(Tn, N[k])), -Tn, N[k]], 1)
        parts.append(box_part('buckle', P[k] + N[k] * 0.0045, (0.0115, 0.0085, 0.0022), frame, C['hard'], 'hard'))
    # side compression strap: wraps the side above the canteen, from the back corner round to the front corner
    for sx in (1, -1):
        y = 0.742
        angles = np.linspace(-0.25, 1.02, 16)   # 0: straight out to the side, pi/2: the front (+z)
        axis = np.array([0.0, y, 0.050])
        dirs = [-np.array([sx * math.cos(t), 0.0, math.sin(t) * 0.9]) for t in angles]
        P, N = drape.line([axis - d * 0.4 for d in dirs], dirs)
        parts.append(wrap_sweep('side_strap', P, N, None, WEB_W * 0.85, WEB_T, C['web'], 'web', 0.0006, 0.32))
        k = 8
        Tn = unit(P[k + 1] - P[k - 1])
        frame = np.stack([-Tn, unit(np.cross(N[k], -Tn)), N[k]], 1)
        parts.append(box_part('buckle', P[k] + N[k] * 0.0045, (0.010, 0.0115, 0.0022), frame, C['hard'], 'hard'))
    # grab handle on the top, behind the lid's back edge
    p0, n0 = drape.hit(np.array([-0.026, 1.2, 0.022]), (0, -1, 0))
    p1, n1 = drape.hit(np.array([0.026, 1.2, 0.022]), (0, -1, 0))
    mid = (p0 + p1) / 2 + np.array([0, 0.011, -0.003])
    path = catmull([p0 - n0 * 0.002, p0 + n0 * 0.006, mid, p1 + n1 * 0.006, p1 - n1 * 0.002], 14)
    outs = [unit(np.array([0, 0.3, -1.0]))] * len(path)
    parts.append(sweep('handle', path, outs, 0.0145, 0.0045, C['handle'], 'web', n_prof=8))
    return parts


# ======================================================================================================================
# Placing the pack on a body, fitting the straps
# ======================================================================================================================
def back_profile(body):
    """z of the back panel (before the clearance) as a function of height: the body's back envelope over the panel's
    width, following half of the hollow of the lower back, smoothed."""
    ys = np.arange(0.48, 0.92, 0.01)
    raw = []
    for y in ys:
        zs = [body.back_z(x, y) for x in np.linspace(-0.075, 0.075, 7)]
        zs = [z for z in zs if z is not None]
        raw.append(max(zs) if zs else np.nan)
    raw = np.array(raw)
    ok = ~np.isnan(raw)
    raw = np.interp(ys, ys[ok], raw[ok])
    top = raw[(ys > 0.56) & (ys < 0.84)].max()
    env = (raw + top) / 2
    k = np.exp(-0.5 * (np.arange(-6, 7) * 0.01 / 0.025) ** 2)
    k /= k.sum()
    env = np.convolve(np.pad(env, 6, mode='edge'), k, mode='valid')
    return ys, env


class Placement:
    """Pack-local -> model space for one body: the back panel follows the body's back profile."""

    def __init__(self, body):
        self.ys, self.env = back_profile(body)
        self.mean = float(np.mean(self.env[(self.ys > 0.56) & (self.ys < 0.84)]))

    def __call__(self, P):
        P = np.array(P, float)
        zb = np.interp(P[:, 1], self.ys, self.env)
        s = np.clip(P[:, 2] / 0.11, 0, 1.4)
        out = P.copy()
        out[:, 2] = P[:, 2] + CLEAR_BACK + zb - 0.45 * s * (zb - self.mean)
        return out


BUCKLE_Y = 0.658        # height of the ladder buckle at the strap's chest end


def strap_xs(body):
    """Strap centre x over the shoulder and at the chest buckle. Over the shoulder it clears the neck; in front it comes
    down straight, parallel to the other strap, about mid-clavicle, and stays where the chest still faces forward (on a
    woman: the outer side of the breast, never toward the sternum)."""
    sh = abs(body.origin('Bip01_L_UpperArm')[0])        # shoulder joint distance from the spine (0.103 / 0.089)
    top = 0.72 * sh
    chest = min(0.066, body.front_half_width(BUCKLE_Y) - 0.005)
    return top, min(top, chest)


def strap_controls(body, side, pl):
    """Strap centre line (control points) for the +x (side=1) or -x strap: pack root, over the shoulder, straight down
    the chest to the buckle, then the lower webbing under the arm to the pack's bottom corner."""
    top, chest = strap_xs(body)
    root = pl(np.array([[STRAP_ROOT[0] * side, STRAP_ROOT[1], STRAP_ROOT[2]]]))[0]
    foot = pl(np.array([[STRAP_FOOT[0] * side, STRAP_FOOT[1], STRAP_FOOT[2]]]))[0]

    def down(y):        # x on the straight front run, from the front of the shoulder (y 0.80) to the buckle
        return top + (chest - top) * float(np.clip((0.800 - y) / (0.800 - BUCKLE_Y), 0, 1))
    upper = [root, root + np.array([0.004 * side, 0.020, -0.012]),
             np.array([top * 0.95 * side, 0.818, 0.060]), np.array([top * side, 0.826, 0.025]),
             np.array([down(0.806) * side, 0.806, -0.012])]
    upper += [np.array([down(y) * side, y, -0.060]) for y in (0.765, 0.730, 0.695, BUCKLE_Y)]
    lower = [upper[-1], np.array([(chest + 0.020) * side, 0.640, -0.030]), np.array([(chest + 0.030) * side, 0.622, 0.010]),
             np.array([(chest + 0.022) * side, 0.600, 0.060]), foot]
    return upper, lower


def fit_to_body(body, ctrl, n, offset, ramp0, ramp1, keep_x=False):
    """Resample the control polyline, then pull it onto the body surface at `offset` (through `ramp0` arc length from
    the start and `ramp1` from the end it blends back to the raw curve, where it enters the pack).
    keep_x: the strap keeps the control line's x (it runs straight over the shoulder and down the chest): each point
    is cast onto the body inside its own x plane, across the line, instead of moving to the nearest surface point
    (which slides a strap off the slope of the chest toward the sternum)."""
    raw = catmull(ctrl, n)
    s = arclen(raw)
    L = s[-1]
    alpha = np.ones(n)
    if ramp0:
        alpha *= smoothstep(0.0, ramp0, s)
    if ramp1:
        alpha *= smoothstep(0.0, ramp1, L - s)
    P = raw.copy()
    N = np.zeros_like(P)
    D = np.zeros_like(P)
    centre = np.array([0.0, 0.735, 0.030])     # inside the upper torso: tells the outside of the line in its plane
    T = units(np.gradient(raw, axis=0))
    for _ in range(4):
        for i in range(n):
            hit = None
            if keep_x:
                t2 = np.array([0.0, T[i][1], T[i][2]])
                out = unit(np.array([0.0, -t2[2], t2[1]]))
                away = raw[i] - centre
                if np.dot(out, np.array([0.0, away[1], away[2]])) < 0:
                    out = -out
                hit = body.ray(raw[i] + out * 0.15, -out)
            if hit is not None:
                q, nn = hit
                target = q + nn * offset
                target[0] = raw[i][0]
            else:
                q, nn, _, _ = body.closest(P[i])
                target = q + nn * offset
            D[i] = (target - raw[i]) * alpha[i]
            # a strap kept in its plane lies flat across the chest: the band follows the body's slope only partly
            # sideways, so it does not twist where the low-poly shoulder and chest facets turn
            N[i] = unit(nn * np.array([0.35, 1.0, 1.0])) if keep_x else nn
        # the displacement from the smooth raw curve is smoothed along the strap, so the low-poly body's facets do
        # not show as kinks (the push-out after sweeping restores the clearance where smoothing cut a corner)
        # (kept in its plane, the strap also bridges the hollow under the collarbone like a strap under tension,
        # instead of dipping into it and folding over itself)
        D = smooth_rows(D, 4.0 if keep_x else 2.2)
        P = raw + D
    return P, units(smooth_rows(N, 2.5))


def smooth_rows(A, sigma):
    """Gaussian smoothing of a sequence of vectors along its length (ends clamped)."""
    r = int(math.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    pad = np.pad(A, ((r, r), (0, 0)), mode='edge')
    return np.array([np.convolve(pad[:, j], k, mode='valid') for j in range(A.shape[1])]).T


def push_out(part, body, clear):
    """Moves every vertex of a strap part that is closer than `clear` to the body (or inside it) out along the body
    normal. Returns the smallest signed distance before the push."""
    worst = 1.0
    for i, p in enumerate(part.P):
        q, n, _, sd = body.closest(p)
        worst = min(worst, sd)
        if sd < clear:
            part.P[i] = p + n * (clear - sd)
    return worst


def push_rings(part, body, clear, k, n_prof):
    """Pushes a swept strap clear of the body ring by ring: each cross-section moves as a whole by the largest push
    one of its vertices needs, smoothed along the strap, so the band keeps its shape instead of creasing where single
    edge vertices would be pushed."""
    for _ in range(3):
        P = np.array(part.P)
        ring = np.zeros((k, 3))
        for i in range(k):
            best = np.zeros(3)
            for j in range(i * (n_prof + 1), (i + 1) * (n_prof + 1)):
                _, n, _, sd = body.closest(P[j])
                if sd < clear and (clear - sd) > np.linalg.norm(best):
                    best = n * (clear - sd)
            ring[i] = best
        if not ring.any():
            return
        ring = smooth_rows(ring, 1.5) * 1.15
        for i in range(k):
            for j in range(i * (n_prof + 1), (i + 1) * (n_prof + 1)):
                part.P[j] = part.P[j] + ring[i]
        part.P[k * (n_prof + 1)] = part.P[k * (n_prof + 1)] + ring[0]           # the two cap centres
        part.P[k * (n_prof + 1) + 1] = part.P[k * (n_prof + 1) + 1] + ring[-1]


def strap_weights(body, P, s_from_root, s_to_foot):
    """Skin weights for strap vertices: the body's weights under each vertex (only the bones a strap may follow),
    blended into the pack bone where the strap enters the pack."""
    out = []
    for p, a, b in zip(P, s_from_root, s_to_foot):
        _, _, w, _ = body.closest(p, full=True)
        d = {}
        for j, bn in enumerate(body.names):
            if w[j] <= 1e-6:
                continue
            bn = FOLD.get(bn, bn)
            if bn not in STRAP_BONES:
                bn = 'Bip01_Spine1'
            d[bn] = d.get(bn, 0.0) + w[j]
        tot = sum(d.values()) or 1.0
        d = {k: v / tot for k, v in d.items()}
        for sd in ('L', 'R'):
            ua = 'Bip01_%s_UpperArm' % sd
            if d.get(ua, 0.0) > UPPER_ARM_MAX:
                d['Bip01_%s_Clavicle' % sd] = d.get('Bip01_%s_Clavicle' % sd, 0.0) + d[ua] - UPPER_ARM_MAX
                d[ua] = UPPER_ARM_MAX
        beta = max(1 - smoothstep(0.012, 0.050, a), 1 - smoothstep(0.012, 0.050, b))
        d = {k: v * (1 - beta) for k, v in d.items()}
        d[PACK_BONE] = d.get(PACK_BONE, 0.0) + beta
        out.append(d)
    return out


def limit_weights(d):
    items = sorted(((v, k) for k, v in d.items() if v > 1e-4), reverse=True)[:MAX_WEIGHTS]
    tot = sum(v for v, _ in items)
    res = {k: round(v / tot, 6) for v, k in items}
    # rounding: put the remainder on the largest so the sum is exactly 1
    big = max(res, key=res.get)
    res[big] = round(1.0 - sum(v for k, v in res.items() if k != big), 6)
    return res


def worn_straps(C, body, pl):
    """Both shoulder straps fitted to the body: padded strap, ladder buckle, lower webbing. Returns parts and per-part
    vertex weights."""
    parts, weights = [], []
    for side in (1, -1):
        upper, lower = strap_controls(body, side, pl)
        P, N = fit_to_body(body, upper, STRAP_STEPS, CLEAR_STRAP + STRAP_T / 2, ramp0=0.050, ramp1=0, keep_x=True)
        # taper the padded strap's width toward the pack root and the buckle
        s = arclen(P)
        L = s[-1]
        widths = STRAP_W * (0.72 + 0.28 * smoothstep(0.0, 0.06, s) * smoothstep(0.0, 0.035, L - s))
        strap = sweep('strap', P, N, STRAP_W, STRAP_T, C['strap'], 'strap', n_prof=STRAP_PROF, widths=widths,
                      v_range=(0.0, min(1.0, L / 0.40)))
        # ladder lock at the strap's chest end
        Tn = unit(P[-1] - P[-3])
        frame = np.stack([unit(np.cross(Tn, N[-1])), Tn, N[-1]], 1)
        buckle = box_part('buckle', P[-1] + Tn * 0.004 + N[-1] * 0.0005, (0.0105, 0.008, 0.0025), frame, C['hard'],
                          'hard')
        P2, N2 = fit_to_body(body, [P[-1] - N[-1] * 0.002] + lower[1:], WEB_STEPS, CLEAR_STRAP + WEB_T / 2, ramp0=0,
                             ramp1=0.05)
        L2 = arclen(P2)[-1]
        web = sweep('web', P2, N2, WEB_W, WEB_T, C['web'], 'web', n_prof=6, v_range=(0.0, min(1.0, L2 / 0.32)))
        push_rings(strap, body, CLEAR_STRAP * 0.6, len(P), STRAP_PROF)
        push_rings(web, body, CLEAR_STRAP * 0.6, len(P2), 6)
        for pt in (strap, web, buckle):
            push_out(pt, body, 0.0025)      # a last guard; the rings above already keep the clearance
        # weights: taken along the centre line (by arc length from the pack root for the strap, to the pack foot for
        # the webbing) and smoothed along it, so a whole cross-section moves together: weights that differed across
        # the strap's width would shear it into folds where the shoulder skin stretches
        rows = path_weights(body, P, arclen(P), np.full(len(P), 1.0))
        rows2 = path_weights(body, P2, np.full(len(P2), 1.0), L2 - arclen(P2))
        for pt, path, rw in ((strap, P, rows), (buckle, P, rows), (web, P2, rows2)):
            proj = [int(np.argmin(((path - q) ** 2).sum(1))) for q in np.array(pt.P)]
            parts.append(pt)
            weights.append([rw[k] for k in proj])
    return parts, weights


def path_weights(body, path, from_root, to_foot):
    """Skin weights of each centre-line point, smoothed along the line, at most MAX_WEIGHTS bones each."""
    ds = strap_weights(body, path, from_root, to_foot)
    bones = sorted({b for d in ds for b in d})
    M = smooth_rows(np.array([[d.get(b, 0.0) for b in bones] for d in ds]), 1.5)
    return [limit_weights({b: float(v) for b, v in zip(bones, row)}) for row in M]


def relaxed_straps(C):
    """The straps of a pack lying on the floor or carried: hanging loops off the back panel (pack-local space)."""
    parts = []
    for side in (1, -1):
        r = np.array(STRAP_ROOT) * np.array([side, 1, 1])
        f = np.array(STRAP_FOOT) * np.array([side, 1, 1])
        ctrl = [r, r + np.array([0.002 * side, 0.010, -0.010]), np.array([0.056 * side, 0.792, -0.030]),
                np.array([0.060 * side, 0.730, -0.044]), np.array([0.062 * side, 0.660, -0.040]),
                np.array([0.064 * side, 0.622, -0.026])]
        P = catmull(ctrl, STRAP_STEPS - 4)
        N = np.tile(np.array([0, 0, -1.0]), (len(P), 1))
        s = arclen(P)
        L = s[-1]
        widths = STRAP_W * (0.72 + 0.28 * smoothstep(0.0, 0.06, s) * smoothstep(0.0, 0.035, L - s))
        parts.append(sweep('strap', P, N, STRAP_W, STRAP_T, C['strap'], 'strap', n_prof=STRAP_PROF, widths=widths,
                           v_range=(0.0, min(1.0, L / 0.40))))
        Tn = unit(P[-1] - P[-3])
        frame = np.stack([unit(np.cross(Tn, N[-1])), Tn, N[-1]], 1)
        parts.append(box_part('buckle', P[-1] + Tn * 0.004, (0.0105, 0.008, 0.0025), frame, C['hard'], 'hard'))
        P2 = catmull([P[-1], np.array([0.070 * side, 0.600, -0.018]), np.array([0.077 * side, 0.586, -0.006]), f], WEB_STEPS - 4)
        N2 = np.tile(np.array([0, 0, -1.0]), (len(P2), 1))
        parts.append(sweep('web', P2, N2, WEB_W, WEB_T, C['web'], 'web', n_prof=6,
                           v_range=(0.0, min(1.0, arclen(P2)[-1] / 0.32))))
    return parts


GRIP_STRAP_S = 0.30    # where the hand holds the relaxed +x strap, as a fraction of its length from the root


def relaxed_grip(C):
    side = 1
    r = np.array(STRAP_ROOT)
    ctrl = [r, r + np.array([0.002 * side, 0.010, -0.010]), np.array([0.056, 0.792, -0.030]),
            np.array([0.060, 0.730, -0.044]), np.array([0.062, 0.660, -0.040]), np.array([0.064, 0.622, -0.026])]
    P = catmull(ctrl, 30)
    s = arclen(P)
    k = int(np.argmin(np.abs(s - GRIP_STRAP_S * s[-1])))
    return P[k]


# ======================================================================================================================
# Variants
# ======================================================================================================================
# Rigid transform of the vanilla pack into the right-hand carry pose (fitted from ALICE_Pack_RHand.x against the worn pack:
# hand = worn @ R.T + T), and the point of the worn pack the hand holds (the Prop1 bone origin expressed in worn space).
HAND_R = np.array([[0.42794772, 0.62795350, -0.65002704],
                   [0.71353707, 0.20669363, 0.66943454],
                   [0.55473021, -0.75030137, -0.35961402]])
HAND_T = np.array([-0.90079746, 0.43881414, 0.60467455])
HAND_GRIP = np.array([0.076, 0.751, 0.075])


def worn_mesh(C, pack_parts, body):
    pl = Placement(body)
    parts = [p.copy(fn=pl) for p in pack_parts]
    straps, sw = worn_straps(C, body, pl)
    m = Mesh(parts + straps)
    n_pack = sum(len(p.P) if not p.hard else 3 * len(p.F) for p in parts)
    weights = [{PACK_BONE: 1.0}] * n_pack
    for pt, ws in zip(straps, sw):
        if pt.hard:
            F = np.array(pt.F)
            ws = [ws[i] for i in F.reshape(-1)]
        weights += ws
    assert len(weights) == len(m.P)
    bones = sorted({b for d in weights for b in d})
    m.W = {b: np.array([d.get(b, 0.0) for d in weights]) for b in bones}
    return m, pl


def loose_mesh(C, pack_parts, pl):
    parts = [p.copy(fn=pl) for p in pack_parts + relaxed_straps(C)]
    m = Mesh(parts)
    m.W = {PACK_BONE: np.ones(len(m.P))}
    return m


def hand_variant(m, left, grip):
    shift = HAND_GRIP - grip

    def pos(A):
        B = (A + shift) @ HAND_R.T + HAND_T
        return B * np.array([-1, 1, 1]) if left else B

    def direction(A):
        B = A @ HAND_R.T
        return B * np.array([-1, 1, 1]) if left else B
    out = m.transformed(pos, direction, flip=left)
    out.W = {VARIANTS['L' if left else 'R']['bone']: np.ones(len(out.P))}
    return out


# ======================================================================================================================
# DirectX .x writer (text, 0303txt 0032), vanilla skeleton spliced in
# ======================================================================================================================
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


_BODY_CACHE = {}


def body_of(fname):
    if fname not in _BODY_CACHE:
        _BODY_CACHE[fname] = Body(fname)
    return _BODY_CACHE[fname]


def offset_matrices(key, bones):
    """Offset matrix text per bone: the pack/prop bone from the vanilla pack, every other bone from the variant's body."""
    v = VARIANTS[key]
    _, _, pm = vanilla_parts(v['src'], v['bone'])
    out = {}
    for b in bones:
        out[b] = pm if b == v['bone'] else body_of(v['body']).mats[b]
    return out


def f6(v):
    return '%.6f' % (0.0 if abs(v) < 5e-7 else v)


def f4(v):
    """A coordinate, a normal or a uv in a .x file: four decimals (0.2 mm of the model, a twentieth of a texel of the 512 atlas),
    the trailing zeros left out. The skin weights keep six (they must sum to 1)."""
    t = ('%.4f' % (0.0 if abs(v) < 5e-5 else v)).rstrip('0').rstrip('.')
    return '0' if t in ('', '-0') else t


def f3(v):
    """A unit normal's component: three decimals (a twentieth of a degree), the trailing zeros left out."""
    t = ('%.3f' % (0.0 if abs(v) < 5e-4 else v)).rstrip('0').rstrip('.')
    return '0' if t in ('', '-0') else t


def w6(v):
    """A skin weight: six decimals, the trailing zeros left out (a rigid vertex's 1.000000 is 1)."""
    t = f6(v).rstrip('0').rstrip('.')
    return '0' if t in ('', '-0') else t


def mesh_frame_text(name, mesh, mats, material):
    """The mesh frame of a .x file. The long lists (positions, faces, normals, uvs, material indices, skin weights) are
    written without indentation and the material indices many to a line: the format reads tokens, so this is only
    bytes (about a third of the file)."""
    P, N, UV, F = mesh.arrays()
    n, nf = len(P), len(F)
    bones = [b for b in sorted(mesh.W) if (mesh.W[b] > 0).any()]
    per_vertex = sum((mesh.W[b] > 0).astype(int) for b in bones)
    per_face = max(len({b for b in bones for i in f if mesh.W[b][i] > 0}) for f in F)
    out = ['Frame %s {' % name, ' ', '', ' FrameTransformMatrix {',
           '  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,'
           '0.000000,0.000000,0.000000,1.000000;;', ' }', '', ' Mesh %s {' % name, '  %d;' % n]
    for i, p in enumerate(P):
        out.append('%s;%s;%s;%s' % (f4(p[0]), f4(p[1]), f4(p[2]), ',' if i < n - 1 else ';'))
    faces = ['3;%d,%d,%d;%s' % (a, b, c, ',' if i < nf - 1 else ';') for i, (a, b, c) in enumerate(F)]
    out.append('  %d;' % nf)
    out += faces
    out += ['', '  MeshNormals {', '   %d;' % n]
    for i, q in enumerate(N):
        out.append('%s;%s;%s;%s' % (f3(q[0]), f3(q[1]), f3(q[2]), ',' if i < n - 1 else ';'))
    out.append('   %d;' % nf)
    out += faces
    out += ['  }', '', '  MeshMaterialList {', '   1;', '   %d;' % nf]
    zeros = ['0'] * nf
    out += [','.join(zeros[i:i + 40]) + (',' if i + 40 < nf else ';') for i in range(0, nf, 40)]
    out += ['   { %s }' % material, '  }', '', '  MeshTextureCoords c1 {', '   %d;' % n]
    for i, t in enumerate(UV):
        out.append('%s;%s;%s' % (f4(t[0]), f4(t[1]), ',' if i < n - 1 else ';'))
    out += ['  }', '', '  XSkinMeshHeader {', '   %d;' % int(per_vertex.max()), '   %d;' % per_face,
            '   %d;' % len(bones), '  }']
    for b in bones:
        idx = np.where(mesh.W[b] > 0)[0]
        out += ['', '  SkinWeights {', '   "%s";' % b, '   %d;' % len(idx)]
        out += ['%d%s' % (i, ',' if k < len(idx) - 1 else ';') for k, i in enumerate(idx)]
        out += ['%s%s' % (w6(mesh.W[b][i]), ',' if k < len(idx) - 1 else ';') for k, i in enumerate(idx)]
        out += ['   %s;;' % mats[b], '  }']
    out += [' }', '}', '']
    return '\n'.join(out)


def write_x(key, mesh):
    v = VARIANTS[key]
    prefix, suffix, _ = vanilla_parts(v['src'], v['bone'])
    material = re.search(r'^Material (\S+) \{', prefix, re.M).group(1)
    mats = offset_matrices(key, [b for b in mesh.W if (mesh.W[b] > 0).any()])
    text = prefix + mesh_frame_text(v['frame'], mesh, mats, material) + '\n' + suffix
    os.makedirs(os.path.dirname(OUT[key]), exist_ok=True)
    with open(OUT[key], 'wb') as f:
        f.write(text.encode('latin-1'))
    return len(mesh.P), len(mesh.F)


# ======================================================================================================================
# Binary FBX 7.3 (read and write; the floor model reuses the vanilla ground model's node layout)
# ======================================================================================================================
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


def fbx_strings(nodes):
    """Every string property of the nodes and their children."""
    out = []
    for n in nodes:
        out += [p[1] for p in n[1] if p[0] == 'S']
        out += fbx_strings(n[2])
    return out


def fbx_find(nodes, name):
    for n in nodes:
        if n[0] == name:
            return n
        r = fbx_find(n[2], name)
        if r:
            return r
    return None


# raw coordinates of the ground model: the vanilla file is 3ds Max inches (z up, standing on z = 0) with the back of the pack
# toward +x and the width along y. canonical (x left, y up, z back) -> raw (x = -z, y = x, z = y) * 100, a mirror image
# (determinant -1) because .x is left handed and the .fbx right handed.
GROUND_SCALE = 100.0


def ground_raw(P, zc, ybot):
    P = np.asarray(P, float)
    return np.stack([-(P[:, 2] - zc), P[:, 0], P[:, 1] - ybot], axis=1) * GROUND_SCALE


def write_fbx(mesh):
    P, N, UV, F = mesh.arrays()
    zc = (P[:, 2].min() + P[:, 2].max()) / 2
    raw = ground_raw(P, zc, P[:, 1].min())
    rawN = np.stack([-N[:, 2], N[:, 0], N[:, 1]], axis=1)

    def rename(s):   # names and texture paths: nothing of the vanilla file's author or art remains
        s = s.replace(b'ALICE_Pack_Ground', (NAME + '_Ground').encode())
        s = re.sub(rb'[^\x00\x01"]*ALICEpack\.png', TEX_REF.encode(), s)
        s = re.sub(rb'[A-Za-z]:\\[^\x00]*\.FBX', (NAME + '_Ground.fbx').encode(), s, flags=re.I)
        return s.replace(b'Material #180', (NAME + '_Mat').encode()).replace(b'Map #91', (NAME + '_Map').encode())
    return ground_fbx(VANILLA_GROUND, OUT['G'], raw, rawN, UV, F, rename)


def ground_fbx(vanilla, out_path, raw, rawN, UV, F, rename):
    """A floor model: the vanilla ground model `vanilla` with its geometry replaced by raw positions and normals (its
    own axes and units), the atlas uvs and the triangles F; rename(bytes) -> bytes rewrites every string property."""
    with open(vanilla, 'rb') as f:
        data = f.read()
    ver, nodes = fbx_read(data)
    footer_id = bytes.fromhex('fabcae04d8c1d86dbe7ef38519f5227c')
    nf = len(F)
    F = F.copy()
    c = np.cross(raw[F[:, 1]] - raw[F[:, 0]], raw[F[:, 2]] - raw[F[:, 0]])
    flip = (c * rawN[F].mean(1)).sum(1) < 0
    F[flip] = F[flip][:, [0, 2, 1]]
    fv = np.where(np.arange(3)[None, :] == 2, ~F, F).reshape(-1)   # last index of each polygon is stored negated (~i)
    uvf = np.stack([UV[:, 0], 1.0 - UV[:, 1]], axis=1)             # fbx v grows upward
    pn = rawN[F.reshape(-1)]
    pu = F.reshape(-1)
    e1 = raw[F[:, 1]] - raw[F[:, 0]]
    e2 = raw[F[:, 2]] - raw[F[:, 0]]
    d1 = uvf[F[:, 1]] - uvf[F[:, 0]]
    d2 = uvf[F[:, 2]] - uvf[F[:, 0]]
    det = d1[:, 0] * d2[:, 1] - d2[:, 0] * d1[:, 1]
    det = np.where(np.abs(det) < 1e-12, 1e-12, det)
    t = units((e1 * d2[:, 1:2] - e2 * d1[:, 1:2]) / det[:, None])
    bi = units((e2 * d1[:, 0:1] - e1 * d2[:, 0:1]) / det[:, None])
    t = np.where(np.linalg.norm(t, axis=1, keepdims=True) < 0.5, np.array([1.0, 0, 0]), t)
    bi = np.where(np.linalg.norm(bi, axis=1, keepdims=True) < 0.5, np.array([0, 1.0, 0]), bi)
    tang = np.repeat(t, 3, axis=0)
    binm = np.repeat(bi, 3, axis=0)
    objects = fbx_find(nodes, 'Objects')
    geo = [c for c in objects[2] if c[0] == 'Geometry'][0]
    old_kids = {c[0]: c for c in geo[2]}

    def layer(name, version, label, mapping, ref, arrname, arr):
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

    def walk(nd):   # and any absolute path left (the author's project and scene folders) goes
        nm, props, kids = nd
        for i, p in enumerate(props):
            if p[0] == 'S':
                props[i] = ('S', re.sub(rb'^[A-Za-z]:\\[^\x00]*$', b'', rename(p[1])))
        for k in kids:
            walk(k)
    walk(nodes[0])
    walk(objects)
    out = fbx_write(ver, nodes, footer_id)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'wb') as f:
        f.write(out)
    return len(raw), nf


# ======================================================================================================================
# Texture painting
# ======================================================================================================================
COL = {
    'canvas': (96, 101, 66), 'canvas_dark': (74, 78, 51), 'padding': (48, 51, 40), 'base': (58, 61, 44),
    'web': (68, 73, 48), 'strap': (86, 91, 59), 'binding': (52, 55, 38), 'plastic': (82, 88, 60), 'cap': (34, 34, 31),
    'hard': (36, 37, 34), 'metal': (118, 120, 114), 'stitch': (60, 63, 40), 'stencil': (198, 190, 150),
    'patch': (64, 68, 46), 'zip': (34, 35, 30),
}


class Painter:
    def __init__(self, charts):
        self.C = charts
        self.rng = np.random.default_rng(42)
        self.img = np.zeros((ATLAS, ATLAS, 3), float)
        self.img[:] = COL['canvas_dark']

    def region(self, ch):
        x0, y0, x1, y1 = ch.rect
        return self.img[y0:y1, x0:x1]

    def noise(self, h, w, scale):
        low = self.rng.normal(0, 1, (max(2, int(h / scale)), max(2, int(w / scale))))
        return np.array(Image.fromarray(low.astype(np.float32), 'F').resize((w, h), Image.BICUBIC))

    def fabric(self, ch, color, weave=2.6, fibre=3.0, mottle=2.6, ripstop=0):
        x0, y0, x1, y1 = ch.rect
        h, w = y1 - y0, x1 - x0
        yy, xx = np.mgrid[y0:y1, x0:x1]
        a = np.tile(np.array(color, float), (h, w, 1))
        weave_p = ((xx + yy) % 2) * weave - weave / 2 + (((xx // 2) + (yy // 2)) % 2) * weave * 0.5 - weave * 0.25
        a += weave_p[..., None]
        a += self.rng.normal(0, fibre, (h, w, 1))
        a += (self.noise(h, w, 10) * mottle + self.noise(h, w, 40) * mottle * 0.8)[..., None]
        if ripstop:
            grid = ((xx % ripstop) == 0) | ((yy % ripstop) == 0)
            a[grid] += 4
        self.img[y0:y1, x0:x1] = a

    def webbing(self, ch, color):
        x0, y0, x1, y1 = ch.rect
        h, w = y1 - y0, x1 - x0
        yy, xx = np.mgrid[0:h, 0:w]
        a = np.tile(np.array(color, float), (h, w, 1))
        a += (((yy // 1) % 2) * 5 - 2.5)[..., None]               # the woven ribs across the band
        a += ((xx % 3 == 0) * -3.0)[..., None]
        a += self.rng.normal(0, 2.5, (h, w, 1))
        a += (self.noise(h, w, 30) * 4)[..., None]
        self.img[y0:y1, x0:x1] = a

    def flat(self, ch, color, noise=3.0):
        x0, y0, x1, y1 = ch.rect
        h, w = y1 - y0, x1 - x0
        self.img[y0:y1, x0:x1] = np.array(color, float) + self.rng.normal(0, noise, (h, w, 1)) + \
            (self.noise(h, w, 8) * noise)[..., None]

    def line(self, p0, p1, color, width=1.0, dash=None, alpha=1.0):
        """Antialiased-ish line in atlas pixels (supersampled stamps)."""
        p0, p1 = np.array(p0, float), np.array(p1, float)
        L = max(np.linalg.norm(p1 - p0), 1e-6)
        n = int(L * 2) + 1
        c = np.array(color, float)
        for i in range(n + 1):
            t = i / n
            if dash and (t * L) % (dash[0] + dash[1]) >= dash[0]:
                continue
            q = p0 + (p1 - p0) * t
            r = width / 2
            for yy in range(int(math.floor(q[1] - r)), int(math.ceil(q[1] + r)) + 1):
                for xx in range(int(math.floor(q[0] - r)), int(math.ceil(q[0] + r)) + 1):
                    if 0 <= xx < ATLAS and 0 <= yy < ATLAS:
                        d = math.hypot(xx + 0.5 - q[0], yy + 0.5 - q[1])
                        a = alpha * float(np.clip(r + 0.5 - d, 0, 1))
                        if a > 0:
                            self.img[yy, xx] = self.img[yy, xx] * (1 - a) + c * a

    def chart_line(self, ch, s0, t0, s1, t1, color, width=1.0, dash=None, alpha=1.0):
        self.line(ch.px(s0, t0), ch.px(s1, t1), color, width, dash, alpha)

    def stitch_border(self, ch, inset_px, color=None, dash=(3, 2), sides='lrtb', width=1.0):
        x0, y0, x1, y1 = ch.rect
        c = color or COL['stitch']
        i = inset_px
        if 't' in sides:
            self.line((x0 + i, y0 + i), (x1 - i, y0 + i), c, width, dash)
        if 'b' in sides:
            self.line((x0 + i, y1 - i), (x1 - i, y1 - i), c, width, dash)
        if 'l' in sides:
            self.line((x0 + i, y0 + i), (x0 + i, y1 - i), c, width, dash)
        if 'r' in sides:
            self.line((x1 - i, y0 + i), (x1 - i, y1 - i), c, width, dash)

    def piping(self, ch, sides='lrtb', color=None, width=2.2):
        """The edge piping where two panels meet: the chart border is the middle of the rounded edge."""
        x0, y0, x1, y1 = ch.rect
        c = color or COL['binding']
        if 't' in sides:
            self.line((x0, y0 + 1), (x1, y0 + 1), c, width)
        if 'b' in sides:
            self.line((x0, y1 - 2), (x1, y1 - 2), c, width)
        if 'l' in sides:
            self.line((x0 + 1, y0), (x0 + 1, y1), c, width)
        if 'r' in sides:
            self.line((x1 - 2, y0), (x1 - 2, y1), c, width)

    def stamp(self, mask, cx, cy, color, alpha=0.85):
        h, w = mask.shape
        x0, y0 = int(round(cx - w / 2)), int(round(cy - h / 2))
        reg = self.img[y0:y0 + h, x0:x0 + w]
        a = (mask * alpha)[..., None]
        self.img[y0:y0 + h, x0:x0 + w] = reg * (1 - a) + np.array(color, float) * a

    def rect(self, x0, y0, x1, y1, color, alpha=1.0):
        x0, y0, x1, y1 = (int(round(v)) for v in (x0, y0, x1, y1))
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
    d.ellipse([13 * u, 22 * u, 35 * u, 42 * u], fill=255)
    d.polygon([(19 * u, 38 * u), (29 * u, 38 * u), (24 * u, 47 * u)], fill=255)
    d.ellipse([8 * u, 10 * u, 40 * u, 28 * u], fill=255)
    d.rectangle([22 * u, 3 * u, 26 * u, 11 * u], fill=255)
    for k in range(-2, 8):
        d.line([(8 * u + k * 6 * u, 28 * u), (8 * u + k * 6 * u + 14 * u, 10 * u)], fill=0, width=int(1.2 * u))
    d.rectangle([6 * u, 25.2 * u, 42 * u, 27.0 * u], fill=0)
    d.rectangle([23.2 * u, 28 * u, 24.8 * u, 36 * u], fill=0)
    d.line([(18 * u, 33 * u), (21 * u, 41 * u)], fill=0, width=int(1.2 * u))
    return np.array(im.resize((size, size), Image.LANCZOS), float) / 255.0


def paint_atlas(C):
    P = Painter(C)
    for ch in C.values():
        m = ch.mat
        if m in ('canvas',):
            P.fabric(ch, COL['canvas'], ripstop=0)
        elif m == 'padding':
            P.fabric(ch, COL['padding'], weave=4, mottle=3)
        elif m == 'base':
            P.fabric(ch, COL['base'], weave=2, mottle=4)
        elif m == 'binding':
            P.webbing(ch, COL['binding'])
        elif m == 'web':
            P.webbing(ch, COL['web'])
        elif m == 'strap':
            P.fabric(ch, COL['strap'], weave=2.2)
        elif m == 'plastic':
            P.flat(ch, COL['plastic'], 2.0)
        elif m == 'cap':
            P.flat(ch, COL['cap'], 2.0)
        elif m == 'hard':
            P.flat(ch, COL['hard'], 2.0)
        elif m == 'metal':
            P.flat(ch, COL['metal'], 4.0)
    st = COL['stitch']
    # ---- main body: piping on the panel edges, stitching, zipper around the front panel, the team patch
    for key in ('main_front', 'main_side', 'main_back', 'main_bottom', 'pouch_front', 'pouch_side',
                'pouch_top', 'cpouch_out', 'cpouch_end', 'lid_top', 'lid_side', 'lid_front'):
        P.piping(C[key])
        P.stitch_border(C[key], 5)
    ch = C['main_front']
    # zipper: a U around the front panel (left, top, right), with a pull at the upper right
    zl, zr, zt = 0.10, 0.90, 0.16
    for (s0, t0, s1, t1) in ((zl, 0.80, zl, zt), (zl, zt, zr, zt), (zr, zt, zr, 0.80)):
        P.chart_line(ch, s0, t0, s1, t1, COL['binding'], 4.0)
        P.chart_line(ch, s0, t0, s1, t1, COL['zip'], 1.6, dash=(1.2, 0.8))
    px, py = ch.px(zr, 0.24)
    P.rect(px - 2, py, px + 3, py + 14, COL['hard'])
    P.rect(px - 1, py + 14, px + 2, py + 22, COL['binding'])
    # the team patch (hook-and-loop field) with the acorn stencil, above the pouch
    cx, cy = ch.px(0.5, 0.37)
    pw, phh = 0.30 * (ch.rect[2] - ch.rect[0]), 0.20 * (ch.rect[3] - ch.rect[1])
    P.rect(cx - pw / 2, cy - phh / 2, cx + pw / 2, cy + phh / 2, COL['patch'])
    yy, xx = np.mgrid[int(cy - phh / 2):int(cy + phh / 2), int(cx - pw / 2):int(cx + pw / 2)]
    P.img[yy, xx] += ((xx + yy) % 3 == 0)[..., None] * -4.0
    for (a, b, c2, d) in ((cx - pw / 2 + 2, cy - phh / 2 + 2, cx + pw / 2 - 2, cy - phh / 2 + 2),
                          (cx - pw / 2 + 2, cy + phh / 2 - 3, cx + pw / 2 - 2, cy + phh / 2 - 3),
                          (cx - pw / 2 + 2, cy - phh / 2 + 2, cx - pw / 2 + 2, cy + phh / 2 - 3),
                          (cx + pw / 2 - 2, cy - phh / 2 + 2, cx + pw / 2 - 2, cy + phh / 2 - 3)):
        P.line((a, b), (c2, d), (82, 86, 58), 1.0, dash=(2, 1.5))
    size = int(phh * 0.82)
    mask = acorn_mask(size) * (P.rng.random((size, size)) > 0.08)
    P.stamp(mask, cx, cy, COL['stencil'], 0.85)
    # seams on the front panel's lower part (where the pouch is sewn on) and a centre seam on the back
    P.chart_line(ch, 0.12, 0.88, 0.88, 0.88, st, 1.0, dash=(3, 2))
    # ---- pouch: zipper along its top edge, a pull tab
    ch = C['pouch_front']
    P.chart_line(ch, 0.06, 0.07, 0.94, 0.07, COL['binding'], 3.4)
    P.chart_line(ch, 0.06, 0.07, 0.94, 0.07, COL['zip'], 1.4, dash=(1.2, 0.8))
    px, py = ch.px(0.80, 0.07)
    P.rect(px - 2, py, px + 2, py + 11, COL['hard'])
    ch = C['pouch_top']
    P.chart_line(ch, 0.04, 0.85, 0.96, 0.85, COL['binding'], 3.0)
    # ---- lid: its front edge is bound, a small name strip on top
    ch = C['lid_front']
    P.chart_line(ch, 0.02, 0.88, 0.98, 0.88, COL['binding'], 3.0)
    ch = C['lid_top']
    P.chart_line(ch, 0.08, 0.75, 0.92, 0.75, st, 1.0, dash=(3, 2))
    # ---- back panel: padded channels and an air mesh diamond pattern
    ch = C['main_back']
    x0, y0, x1, y1 = ch.rect
    yy, xx = np.mgrid[y0:y1, x0:x1]
    diamond = (((xx + yy) % 6) == 0) | (((xx - yy) % 6) == 0)
    P.img[y0:y1, x0:x1][diamond] = (40, 43, 34)
    for s in (0.33, 0.67):
        P.chart_line(ch, s, 0.05, s, 0.95, (34, 36, 28), 3.0)
    # ---- shoulder strap: padded, quilted outer face, bound edges
    ch = C['strap']
    x0, y0, x1, y1 = ch.rect
    w = x1 - x0
    for frac in (0.28, 0.72):          # bound edges of the outer face (the outer face spans u 0.31..0.69)
        P.chart_line(ch, frac, 0.0, frac, 1.0, COL['binding'], 3.2)
    for frac in (0.335, 0.665):
        P.chart_line(ch, frac, 0.0, frac, 1.0, (64, 68, 44), 1.0, dash=(3, 2))
    for y in range(y0 + 10, y1 - 4, 14):
        P.line((x0 + 0.34 * w, y), (x0 + 0.66 * w, y + 5), (68, 72, 46), 1.0)
    P.img[y0:y1, x0:int(x0 + 0.26 * w)] = P.img[y0:y1, x0:int(x0 + 0.26 * w)] * 0.75 + np.array(COL['padding']) * 0.25
    P.img[y0:y1, int(x0 + 0.74 * w):x1] = P.img[y0:y1, int(x0 + 0.74 * w):x1] * 0.75 + np.array(COL['padding']) * 0.25
    # ---- webbing: bar-tack stitches every MOLLE channel (1.5", about 0.0135 units)
    for key in ('web',):
        ch = C[key]
        x0, y0, x1, y1 = ch.rect
        step = 0.0135 * DENSITY
        y = y0 + 4
        while y < y1 - 2:
            P.line((x0 + 0.30 * (x1 - x0), y), (x0 + 0.70 * (x1 - x0), y), (44, 47, 32), 1.4)
            y += step
    # ---- canteen: moulded OD plastic, a seam line round its middle, a darker worn bottom; the cap ribbed black
    for key in ('canteen_side', 'canteen_end'):
        ch = C[key]
        P.chart_line(ch, 0.0, 0.08, 1.0, 0.08, (66, 71, 48), 1.2)
    ch = C['canteen_side']
    x0, y0, x1, y1 = ch.rect
    g = np.linspace(0, 1, y1 - y0)[:, None, None]
    P.img[y0:y1, x0:x1] *= (1.04 - 0.10 * g)
    ch = C['canteen_top']
    P.chart_line(ch, 0.0, 0.5, 1.0, 0.5, (66, 71, 48), 1.0)
    ch = C['cap']
    x0, y0, x1, y1 = ch.rect
    for x in range(x0, x1, 3):
        P.line((x, y0), (x, y1), (22, 22, 20), 1.0)
    # ---- canteen pouch: binding at the opening, a drain grommet
    ch = C['cpouch_out']
    P.chart_line(ch, 0.0, 0.06, 1.0, 0.06, COL['binding'], 5.0)
    gx, gy = ch.px(0.5, 0.86)
    for yy in range(-3, 4):
        for xx in range(-3, 4):
            r = math.hypot(xx, yy)
            if 1.5 <= r <= 3.2:
                P.img[int(gy) + yy, int(gx) + xx] = COL['metal']
            elif r < 1.5:
                P.img[int(gy) + yy, int(gx) + xx] = (30, 30, 28)
    ch = C['cpouch_end']
    P.chart_line(ch, 0.0, 0.06, 1.0, 0.06, COL['binding'], 5.0)
    ch = C['cpouch_top']
    x0, y0, x1, y1 = ch.rect
    P.img[y0 + 4:y1 - 4, x0 + 4:x1 - 4] = (26, 27, 22)    # the opening (mostly filled by the canteen)
    # ---- hardware
    ch = C['hard']
    x0, y0, x1, y1 = ch.rect
    P.img[y0 + 5:y1 - 5, x0 + 4:x1 - 4] = (24, 24, 22)
    P.img[y0 + 9:y1 - 9, x0 + 3:x1 - 3] = (46, 47, 44)
    return P


def blur(a, sigma):
    """Separable gaussian blur of a 2D float array (edges clamped)."""
    r = int(math.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    a = np.pad(a, r, mode='edge')
    a = sum(k[i] * a[:, i:i + a.shape[1] - 2 * r] for i in range(2 * r + 1))
    a = sum(k[i] * a[i:i + a.shape[0] - 2 * r, :] for i in range(2 * r + 1))
    return a


def finish_atlas(P, gbuf):
    """Baked shading from the uv-space position/normal buffer: ambient occlusion, dirt toward the bottom and in the
    creases, light wear on exposed edges."""
    ao, ypos, cov = gbuf
    img = P.img
    ao_full = np.array(Image.fromarray(ao.astype(np.float32), 'F').resize((ATLAS, ATLAS), Image.BILINEAR))
    yp = np.array(Image.fromarray(ypos.astype(np.float32), 'F').resize((ATLAS, ATLAS), Image.BILINEAR))
    covf = np.array(Image.fromarray((cov * 255).astype(np.uint8)).resize((ATLAS, ATLAS), Image.BILINEAR)) / 255.0
    ao_full = np.where(covf > 0.01, ao_full / np.maximum(covf, 1e-3), 1.0)
    yp = np.where(covf > 0.01, yp / np.maximum(covf, 1e-3), 0.7)
    ao_full = blur(ao_full, 1.6)
    img *= (0.42 + 0.58 * np.clip(ao_full, 0, 1))[..., None]
    # dirt: lower parts of the pack and the creases
    low = np.clip((0.640 - yp) / 0.09, 0, 1) ** 1.4
    crease = np.clip((0.82 - ao_full) / 0.4, 0, 1)
    speck = (P.rng.random((ATLAS, ATLAS)) > 0.5) * P.rng.random((ATLAS, ATLAS))
    a = np.clip((0.45 * low + 0.35 * crease) * (0.55 + 0.6 * speck), 0, 0.6)[..., None]
    img[:] = img * (1 - a) + np.array((70, 58, 40), float) * a
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), 'RGB')


def uv_gbuffer(mesh, res=256):
    """Rasterises the mesh into uv space: per texel position and normal (the last triangle written wins where charts
    are shared), then point-based ambient occlusion against the whole mesh."""
    P, N, UV, F = mesh.arrays()
    pos = np.zeros((res, res, 3))
    nrm = np.zeros((res, res, 3))
    cov = np.zeros((res, res))
    for f in F:
        uv = UV[f] * res - 0.5
        x0, x1 = int(np.floor(uv[:, 0].min())) - 1, int(np.ceil(uv[:, 0].max())) + 2
        y0, y1 = int(np.floor(uv[:, 1].min())) - 1, int(np.ceil(uv[:, 1].max())) + 2
        x0, y0 = max(x0, 0), max(y0, 0)
        x1, y1 = min(x1, res), min(y1, res)
        if x0 >= x1 or y0 >= y1:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1), np.arange(y0, y1))
        xs, ys = uv[:, 0], uv[:, 1]
        den = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if abs(den) < 1e-12:
            continue
        l0 = ((ys[1] - ys[2]) * (gx - xs[2]) + (xs[2] - xs[1]) * (gy - ys[2])) / den
        l1 = ((ys[2] - ys[0]) * (gx - xs[2]) + (xs[0] - xs[2]) * (gy - ys[2])) / den
        l2 = 1 - l0 - l1
        m = (l0 >= -0.35) & (l1 >= -0.35) & (l2 >= -0.35)   # a little dilation keeps the chart borders covered
        if not m.any():
            continue
        L = np.stack([l0, l1, l2], -1)[m]
        L = np.clip(L, 0, None)
        L /= L.sum(1, keepdims=True)
        pos[gy[m], gx[m]] = L @ P[f]
        nrm[gy[m], gx[m]] = units(L @ N[f])
        cov[gy[m], gx[m]] = 1
    # samples: triangle centres with areas and normals
    A = 0.5 * np.linalg.norm(np.cross(P[F[:, 1]] - P[F[:, 0]], P[F[:, 2]] - P[F[:, 0]]), axis=1)
    Q = P[F].mean(1)
    QN = units(N[F].mean(1))
    ys_, xs_ = np.nonzero(cov)
    rp = pos[ys_, xs_] + nrm[ys_, xs_] * 0.0015
    rn = nrm[ys_, xs_]
    occ = np.zeros(len(rp))
    for i in range(0, len(rp), 96):
        v = Q[None, :, :] - rp[i:i + 96, None, :]
        d2 = (v * v).sum(-1) + 1e-9
        d = np.sqrt(d2)
        vn = v / d[..., None]
        cos_r = np.clip((vn * rn[i:i + 96, None, :]).sum(-1), 0, 1)
        cos_e = np.abs((vn * QN[None, :, :]).sum(-1))
        omega = A[None, :] * cos_e / (d2 + A[None, :] / math.pi)
        far = d > 0.09
        omega[far] = 0
        occ[i:i + 96] = (omega * cos_r).sum(1) / math.pi
    ao = np.zeros((res, res))
    ao[ys_, xs_] = np.clip(1 - 1.15 * occ, 0, 1) ** 1.2
    ypos = np.zeros((res, res))
    ypos[ys_, xs_] = pos[ys_, xs_, 1]
    # dilate into the gaps so bilinear upscaling does not bleed the background into chart borders
    for _ in range(3):
        for arr in (ao, ypos):
            pad = np.pad(arr, 1, mode='edge')
            cp = np.pad(cov, 1)
            acc = np.zeros_like(arr)
            cnt = np.zeros_like(arr)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    acc += pad[1 + dy:res + 1 + dy, 1 + dx:res + 1 + dx] * cp[1 + dy:res + 1 + dy, 1 + dx:res + 1 + dx]
                    cnt += cp[1 + dy:res + 1 + dy, 1 + dx:res + 1 + dx]
            fill = (cov == 0) & (cnt > 0)
            arr[fill] = acc[fill] / cnt[fill]
        cp = np.pad(cov, 1)
        grow = np.zeros_like(cov)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                grow = np.maximum(grow, cp[1 + dy:res + 1 + dy, 1 + dx:res + 1 + dx])
        cov = grow
    return ao * cov, ypos * cov, cov


# ======================================================================================================================
# Text files
# ======================================================================================================================
BOM = '\ufeff'


def write_text(path, text, bom=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write((BOM if bom else '').encode('utf-8') + text.replace('\r\n', '\n').encode('utf-8'))


def write_clothing():
    for fname, (guid, male, female) in CLOTHING.items():
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
    merge_guid_table(OUT['GUID'], {f: g[0] for f, g in CLOTHING.items()})


def merge_guid_table(path, items):
    """Puts the clothing items {file name: guid} into media/fileGuidTable.xml, keeping the entries other tools wrote
    (tools/fuelcan_mesh.py registers its own there too) as long as their file is still there: a clothing item a tool
    no longer makes leaves the table with its file."""
    entries = {}
    folder = os.path.join(os.path.dirname(path), 'clothing', 'clothingItems')
    if os.path.exists(path):
        old = open(path, encoding='utf-8-sig').read()
        for m in re.finditer(r'<path>media/clothing/clothingItems/([^<]+)\.xml</path>\s*<guid>([^<]+)</guid>', old):
            if os.path.exists(os.path.join(folder, m.group(1) + '.xml')):
                entries[m.group(1)] = m.group(2)
    entries.update(items)
    text = ''.join('\t<files>\n\t\t<path>media/clothing/clothingItems/%s.xml</path>\n\t\t<guid>%s</guid>\n\t</files>\n'
                   % (f, g) for f, g in entries.items())
    write_text(path, '<?xml version="1.0" encoding="utf-8"?>\n<fileGuidTable>\n' + text + '</fileGuidTable>\n')


def write_script():
    write_text(OUT['SCRIPT'], (
        'module OperationAcorn\n{\n'
        '\t/* The research team backpack lying on the floor (same pack as the worn model, own atlas). */\n'
        '\tmodel OA_ResearchPack_Ground\n\t{\n'
        '\t\tmesh = WorldItems/Clothing/OA_ResearchPack_Ground,\n'
        '\t\ttexture = Clothes/Bag/OA_ResearchPack,\n'
        '\t\tscale = 0.4,\n\t}\n}\n'))


# ======================================================================================================================
# Posing (preview only): linear blend skinning with the arm chains rotated about the shoulders
# ======================================================================================================================
POSES = {
    'bind': {},
    'rest': {'L': ((0, 0, 1), -72), 'R': ((0, 0, 1), 72)},           # arms down along the body
    'aim': {'L': ((0, 1, 0), 80), 'R': ((0, 1, 0), -80), 'Ld': ((0, 0, 1), -12), 'Rd': ((0, 0, 1), 12)},
    'swing': {'L': ((1, 0.0, 0.25), 0), 'Lx': ((1, 0, 0), -40), 'R': ((0, 0, 1), 72), 'Rx': ((1, 0, 0), 40)},
}


def bone_transforms(body, pose):
    """{bone: (R, origin)} for the arm chains; everything else stays in the bind pose."""
    out = {}
    spec = POSES[pose]
    for side in ('L', 'R'):
        rs = []
        for key in (side, side + 'd', side + 'x'):
            if key in spec:
                ax, deg = spec[key]
                rs.append(rot(ax, deg))
        if pose == 'swing':     # the arm hangs down, then swings forward (L) / back (R)
            rs = [rot((1, 0, 0), -35 if side == 'L' else 35), rot((0, 0, 1), -72 if side == 'L' else 72)]
        if not rs:
            continue
        R = np.eye(3)
        for r in rs:
            R = R @ r
        o = body.origin('Bip01_%s_UpperArm' % side)
        for b in ('UpperArm', 'Forearm', 'Hand', 'Finger0', 'Finger1'):
            out['Bip01_%s_%s' % (side, b)] = (R, o)
    return out


def skin(P, N, W, tf):
    """W: {bone: weights array}. Bones without a transform stay put."""
    outP = np.zeros_like(P)
    outN = np.zeros_like(N)
    tot = np.zeros(len(P))
    for b, w in W.items():
        if b in tf:
            R, o = tf[b]
            q = (P - o) @ R.T + o
            n = N @ R.T
        else:
            q, n = P, N
        outP += q * w[:, None]
        outN += n * w[:, None]
        tot += w
    rest = np.clip(1 - tot, 0, 1)
    outP += P * rest[:, None]
    outN += N * rest[:, None]
    return outP, units(outN)


def posed_body(body, pose):
    tf = bone_transforms(body, pose)
    W = {b: body.W[:, j] for j, b in enumerate(body.names)}
    P, N = skin(body.V, body.VN, W, tf)
    return P, N, body.T


# ======================================================================================================================
# Software renderer (previews): smooth shaded, textured, z-buffered, back faces culled as in the game
# ======================================================================================================================
def render(meshes, tex, d, up, size=380, ss=2, bodies=(), bg=(226, 228, 224), frame=None, marker=None):
    """meshes: list of (P, N, UV, F). bodies: list of (P, N, T, colour). frame: (centre, extent) to share a framing."""
    d, up = unit(d), unit(up)
    right = unit(np.cross(up, d))
    upv = unit(np.cross(d, right))
    if frame is None:
        allp = np.concatenate([m[0] for m in meshes])
        centre = (allp.min(0) + allp.max(0)) / 2
        ext = max(np.ptp((allp - centre) @ right), np.ptp((allp - centre) @ upv))
    else:
        centre, ext = frame
    W = size * ss
    sc = W * 0.86 / ext
    img = np.zeros((W, W, 3), float)
    img[:] = bg
    zb = np.full((W, W), 1e9)
    light = unit(-d * 0.55 + upv * 0.75 - right * 0.35)
    th = tex.shape[0]

    def proj(P):
        q = P - centre
        return np.stack([W / 2 + sc * q @ right, W / 2 - sc * q @ upv, q @ d], axis=1)

    def raster(Pp, tri, Nv, uvs=None, color=None, cull=True):
        xs, ys, zs = Pp[tri, 0], Pp[tri, 1], Pp[tri, 2]
        x0, x1 = max(int(np.floor(xs.min())), 0), min(int(np.ceil(xs.max())) + 1, W)
        y0, y1 = max(int(np.floor(ys.min())), 0), min(int(np.ceil(ys.max())) + 1, W)
        if x0 >= x1 or y0 >= y1:
            return
        den = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if abs(den) < 1e-9:
            return
        gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
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
        n = l0[..., None] * Nv[0] + l1[..., None] * Nv[1] + l2[..., None] * Nv[2]
        n = n / np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-9)
        diff = np.clip((n * light).sum(-1), 0, 1)
        shade = (0.42 + 0.62 * diff)[..., None]
        if uvs is not None:
            u = l0 * uvs[0][0] + l1 * uvs[1][0] + l2 * uvs[2][0]
            v = l0 * uvs[0][1] + l1 * uvs[1][1] + l2 * uvs[2][1]
            tx = np.clip((u * th).astype(int), 0, th - 1)
            ty = np.clip((v * th).astype(int), 0, th - 1)
            col = tex[ty, tx].astype(float)
        else:
            col = np.array(color, float)[None, None, :] + np.zeros((y1 - y0, x1 - x0, 3))
        sub = img[y0:y1, x0:x1]
        sub[win] = (col * shade)[win]
        zb[y0:y1, x0:x1][win] = z[win]

    for P, N, T, color in bodies:
        Pp = proj(P)
        for t in T:
            raster(Pp, t, N[t], color=color)
    for P, N, UV, F in meshes:
        Pp = proj(P)
        fn = np.cross(P[F[:, 1]] - P[F[:, 0]], P[F[:, 2]] - P[F[:, 0]])
        vis = (fn @ d) < 0
        for f in F[vis]:
            raster(Pp, f, N[f], uvs=UV[f])
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


def iso_dir(azimuth_deg, elevation_deg=30.0):
    """Camera direction for the game's isometric view: looking down by `elevation`, from `azimuth` around the
    character (0: from behind the wearer (camera at +z), -90: from the wearer's left (+x), 90: from the right)."""
    a, e = math.radians(azimuth_deg), math.radians(elevation_deg)
    return unit((math.sin(a) * math.cos(e), -math.sin(e), -math.cos(a) * math.cos(e)))


BODY_COL = (150, 128, 112)


def posed(mesh, body, pose):
    tf = bone_transforms(body, pose)
    P, N = skin(mesh.P, mesh.N, mesh.W, tf)
    return P, N, mesh.UV, mesh.F


def frame_for(points, d, up=(0, 1, 0), pad=1.0):
    d, up = unit(d), unit(up)
    right = unit(np.cross(up, d))
    upv = unit(np.cross(d, right))
    c = (points.min(0) + points.max(0)) / 2
    ext = max(np.ptp((points - c) @ right), np.ptp((points - c) @ upv)) * pad
    return c, ext


def label(im, text):
    dr = ImageDraw.Draw(im)
    dr.rectangle([0, 0, im.width, 16], fill=(255, 255, 255))
    dr.text((5, 2), text, fill=(0, 0, 0))
    return im


def sheet(tiles, cols, size):
    rows = (len(tiles) + cols - 1) // cols
    out = Image.new('RGB', (cols * size, rows * size), (255, 255, 255))
    for i, im in enumerate(tiles):
        out.paste(im, ((i % cols) * size, (i // cols) * size))
    return out


def wearer_tiles(mesh, body, tex, size, views, pose='rest', crop=None):
    bp = posed_body(body, pose)
    pm = posed(mesh, body, pose)
    tiles = []
    for lab, d in views:
        region = np.concatenate([pm[0], bp[0][(bp[0][:, 1] > 0.45) & (np.abs(bp[0][:, 0]) < 0.30)]])
        fr = frame_for(region, d, pad=1.04)
        tiles.append(label(render([pm], tex, d, (0, 1, 0), size, bodies=[(bp[0], bp[1], bp[2], BODY_COL)], frame=fr), lab))
    return tiles


def make_icon_source(meshes, tex, size=512):
    """tools/backpack_icon_source.png: the floor model as the preview's 'ground model' shows it (from the front-left, a
    little from above: the lid, the front pouch with the team mark, a canteen), on a clear background. Rendered on black
    and on white: where they differ is how far the background shows through, which gives the alpha and the colour
    without a fringe."""
    g = meshes['G'].arrays()
    d = iso_dir(-35)
    black = np.asarray(render([g], tex, d, (0, 1, 0), size, ss=3, bg=(0, 0, 0)), float)
    white = np.asarray(render([g], tex, d, (0, 1, 0), size, ss=3, bg=(255, 255, 255)), float)
    alpha = np.clip(1.0 - (white - black).mean(-1) / 255.0, 0.0, 1.0)
    colour = np.where(alpha[..., None] > 1e-3, black / np.maximum(alpha[..., None], 1e-3), 0.0)
    rgba = np.dstack([np.clip(colour, 0, 255), alpha * 255]).astype(np.uint8)
    im = Image.fromarray(rgba, 'RGBA')
    im.crop(im.getbbox()).save(ICON_SOURCE)


def make_previews(meshes, tex, old=None):
    """tools/backpack_preview.png and, when the mockups folder's parent exists, the review sheets."""
    male, female = body_of('MaleBody.x'), body_of('FemaleBody.x')
    S = 380
    views = [('M back (arms down)', (0, 0, -1)), ('M left side', (-1, 0, 0)), ('M front', (0, 0, 1)),
             ('M game camera, behind-left', iso_dir(-40)), ('M game camera, behind-right', iso_dir(40)),
             ('M game camera, front-left', iso_dir(-140))]
    tiles = wearer_tiles(meshes['M'], male, tex, S, views)
    tiles += wearer_tiles(meshes['F'], female, tex, S, [('F back', (0, 0, -1)), ('F left side', (-1, 0, 0)),
                                                         ('F game camera, behind-left', iso_dir(-40)),
                                                         ('F front', (0, 0, 1))])
    g = meshes['G'].arrays()
    tiles.append(label(render([g], tex, iso_dir(-35), (0, 1, 0), S), 'ground model'))
    rh = meshes['R']
    tiles.append(label(render([rh.arrays()], tex, unit((-0.4, -0.2, -1)), (0, 1, 0), S, marker=prop_origin('R')),
                       'right hand carry (red: Prop1)'))
    sh = sheet(tiles, 4, S)
    sh.save(PREVIEW)
    if not os.path.isdir(os.path.dirname(MOCKUPS)):
        return
    os.makedirs(MOCKUPS, exist_ok=True)
    big = 520
    # 1. the new pack on both bodies, the game's camera angles
    t = wearer_tiles(meshes['M'], male, tex, big, [('male, game camera behind-left', iso_dir(-40)),
                                                  ('male, game camera behind-right', iso_dir(40)),
                                                  ('male, back', (0, 0, -1)), ('male, left side', (-1, 0, 0)),
                                                  ('male, front', (0, 0, 1)),
                                                  ('male, game camera front-right', iso_dir(140))])
    t += wearer_tiles(meshes['F'], female, tex, big, [('female, game camera behind-left', iso_dir(-40)),
                                                     ('female, game camera behind-right', iso_dir(40)),
                                                     ('female, back', (0, 0, -1)), ('female, left side', (-1, 0, 0)),
                                                     ('female, front', (0, 0, 1)),
                                                     ('female, game camera front-right', iso_dir(140))])
    sheet(t, 3, big).save(os.path.join(MOCKUPS, 'new_pack_views.png'))
    # the straps from the front: straight and parallel down the chest, both bodies, standing and in motion
    t = []
    for key, body, nm in (('M', male, 'male'), ('F', female, 'female')):
        t += wearer_tiles(meshes[key], body, tex, big, [('%s, front' % nm, (0, 0, 1)),
                                                       ('%s, game camera front-right' % nm, iso_dir(140)),
                                                       ('%s, game camera front-left' % nm, iso_dir(-140))])
        t += wearer_tiles(meshes[key], body, tex, big, [('%s, arms forward (aiming), front' % nm, iso_dir(160, 15))],
                          pose='aim')
        t += wearer_tiles(meshes[key], body, tex, big, [('%s, walk swing, front' % nm, iso_dir(160, 15))], pose='swing')
        t += wearer_tiles(meshes[key], body, tex, big, [('%s, bind pose, front' % nm, (0, 0, 1))], pose='bind')
    sheet(t, 3, big).save(os.path.join(MOCKUPS, 'strap_front.png'))
    # 2. strap fit in other poses (the straps carry the body's weights, so they follow the shoulders)
    t = []
    for pose, lab in (('bind', 'bind pose (T)'), ('aim', 'arms forward (aiming)'), ('swing', 'walk swing')):
        t += wearer_tiles(meshes['M'], male, tex, big, [('male, %s, front-left' % lab, iso_dir(-150, 15)),
                                                       ('male, %s, side' % lab, (-1, 0, 0))], pose=pose)
    sheet(t, 2, big).save(os.path.join(MOCKUPS, 'strap_poses.png'))
    # 3. carried and ground
    t = [label(render([meshes['G'].arrays()], tex, iso_dir(-35), (0, 1, 0), big), 'on the floor, game camera'),
         label(render([meshes['G'].arrays()], tex, iso_dir(145), (0, 1, 0), big), 'on the floor, other side'),
         label(render([meshes['R'].arrays()], tex, unit((-0.4, -0.2, -1)), (0, 1, 0), big, marker=prop_origin('R')),
               'carried in the right hand (red: the hand bone)')]
    sheet(t, 3, big).save(os.path.join(MOCKUPS, 'new_pack_carried.png'))
    Image.fromarray(tex).save(os.path.join(MOCKUPS, 'new_texture_atlas.png'))
    # 4. before / after at the game's camera
    if old:
        t = []
        for key, body, nm in (('M', male, 'male'), ('F', female, 'female')):
            om, otex = old[key]
            for az in (-40, 40):
                d = iso_dir(az)
                bp = posed_body(body, 'rest')
                region = bp[0][(bp[0][:, 1] > 0.45) & (np.abs(bp[0][:, 0]) < 0.30)]
                newp = posed(meshes[key], body, 'rest')
                fr = frame_for(np.concatenate([region, newp[0], om[0]]), d, pad=1.04)
                bod = [(bp[0], bp[1], bp[2], BODY_COL)]
                t.append(label(render([om], otex, d, (0, 1, 0), big, bodies=bod, frame=fr), 'BEFORE: %s, camera %s'
                               % (nm, 'behind-left' if az < 0 else 'behind-right')))
                t.append(label(render([newp], tex, d, (0, 1, 0), big, bodies=bod, frame=fr), 'AFTER: %s, camera %s'
                               % (nm, 'behind-left' if az < 0 else 'behind-right')))
        sheet(t, 4, big).save(os.path.join(MOCKUPS, 'before_after.png'))


def prop_origin(key):
    """Origin of the carry bone in the hand mesh space: the inverse of its offset matrix (row-vector convention)."""
    _, _, mat = vanilla_parts(VARIANTS[key]['src'], VARIANTS[key]['bone'])
    return bone_origin(mat)


def load_old(dirpath):
    """The previous model (files saved before a rebuild) for the before/after sheet: {key: ((P,N,UV,F), texture)}."""
    out = {}
    tex = np.array(Image.open(os.path.join(dirpath, TEX_REF)).convert('RGB'))
    for key in ('M', 'F'):
        d = parse_x(os.path.join(dirpath, os.path.basename(OUT[key])))
        N = d['N'] if d['N'] is not None else vertex_normals(d['V'], d['T'])
        out[key] = ((d['V'], N, d['UV'], d['T']), tex)
    return out


# ======================================================================================================================
# Build
# ======================================================================================================================
def build_meshes():
    C = define_charts()
    used = pack_charts(list(C.values()))
    pack = build_pack(C)
    male, female = body_of('MaleBody.x'), body_of('FemaleBody.x')
    M, plM = worn_mesh(C, pack, male)
    F, _ = worn_mesh(C, pack, female)
    loose = loose_mesh(C, pack, plM)
    grip = plM(np.array([relaxed_grip(C)]))[0]
    meshes = {'M': M, 'F': F, 'R': hand_variant(loose, False, grip), 'L': hand_variant(loose, True, grip), 'G': loose}
    return C, meshes, used


def build_all(old_dir=None):
    for p in (VANILLA_BP, VANILLA_GROUND, os.path.join(SKINNED, 'MaleBody.x')):
        if not os.path.exists(p):
            sys.exit('vanilla reference missing (set PZ_DIR): ' + p)
    C, meshes, used = build_meshes()
    print('atlas: %d charts, %d of %d rows used' % (len(C), used, ATLAS))
    for k in 'MFLR':
        nv, nf = write_x(k, meshes[k])
        print('%-4s %5d vertices %5d faces  %s' % (k, nv, nf, os.path.relpath(OUT[k], ROOT)))
    nv, nf = write_fbx(meshes['G'])
    print('G    %5d vertices %5d faces  %s' % (nv, nf, os.path.relpath(OUT['G'], ROOT)))
    P = paint_atlas(C)
    tex = finish_atlas(P, uv_gbuffer(meshes['M'])).resize((SHIP, SHIP), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT['TEX']), exist_ok=True)
    tex.save(OUT['TEX'], optimize=True)
    write_clothing()
    write_script()
    old = load_old(old_dir) if old_dir else None
    make_previews(meshes, np.array(tex), old)
    print('preview', os.path.relpath(PREVIEW, ROOT))
    make_icon_source(meshes, np.array(tex)[..., :3])
    print('icon source', os.path.relpath(ICON_SOURCE, ROOT))


# ======================================================================================================================
# --check: parse every produced file again
# ======================================================================================================================
class Fail(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Fail(msg)


def check_x(key):
    path = OUT[key]
    v = VARIANTS[key]
    with open(path, 'rb') as f:
        raw = f.read()
    need(raw.startswith(b'xof 0303txt 0032'), 'header')
    txt = raw.decode('latin-1').replace('\r\n', '\n')
    need('\r' not in txt, 'unexpected CR')
    body = re.sub(r'"[^"]*"', '""', txt)
    need(body.count('{') == body.count('}'), 'unbalanced braces %d/%d' % (body.count('{'), body.count('}')))
    frames = set(re.findall(r'^\s*Frame (\w+) \{', txt, re.M))
    need(v['frame'] in frames, 'mesh frame %s missing' % v['frame'])
    d = parse_x(path)
    verts, faces = d['V'], d['T']
    nv, nf = len(verts), len(faces)
    need(faces.min() >= 0 and faces.max() < nv, 'face index out of range')
    mesh_txt = txt[txt.index(' Mesh %s {' % v['frame']):]
    need(len(re.findall(r'\n\s*3;\d+,\d+,\d+;[,;]', mesh_txt.split('MeshNormals {')[0])) == nf, 'a face is not a triangle')
    nrm = d['N']
    need(nrm is not None and len(nrm) == nv, 'normal count')
    need(np.abs(np.linalg.norm(nrm, axis=1) - 1).max() < 1e-3, 'normals not unit length')
    block = txt[re.search(r'MeshNormals \{\n\s*(\d+);\n', txt).end():].split('\n')
    need(int(block[nv].strip().rstrip(';')) == nf, 'normal face count')
    nfaces = np.array([[int(i) for i in ln.strip().rstrip(',;').split(';')[1].split(',')] for ln in block[nv + 1:nv + 1 + nf]])
    need((nfaces == faces).all(), 'normal faces differ from faces')
    # winding: the face normal agrees with its vertex normals (smooth shading: the mean of the three)
    c = np.cross(verts[faces[:, 1]] - verts[faces[:, 0]], verts[faces[:, 2]] - verts[faces[:, 0]])
    agree = (c * nrm[faces].mean(1)).sum(1) > 0
    need(agree.mean() > 0.995, '%d faces wound against their normals' % (~agree).sum())
    ml = re.search(r'MeshMaterialList \{\n\s*1;\n\s*(\d+);\n((?:\s*0(?:,0)*[,;]\n)+)\s*\{ (\S+) \}', txt)
    need(ml and int(ml.group(1)) == nf and ml.group(2).count('0') == nf, 'material list')
    need('Material %s {' % ml.group(3) in txt, 'material %s missing' % ml.group(3))
    need('"%s"' % TEX_REF in txt, 'texture filename')
    uv = d['UV']
    need(uv is not None and len(uv) == nv, 'uv count')
    need(uv.min() >= 0 and uv.max() <= 1, 'uv outside 0..1')
    # skin: every vertex's weights sum to 1, at most MAX_WEIGHTS bones each, the header agrees, matrices are the sources'
    hm = re.search(r'XSkinMeshHeader \{\n\s*(\d+);\n\s*(\d+);\n\s*(\d+);', txt)
    need(hm, 'XSkinMeshHeader')
    per_v, per_f, nb = (int(x) for x in hm.groups())
    sw = list(re.finditer(r'SkinWeights \{\n\s*"(\w+)";\n\s*(\d+);\n', txt))
    need(len(sw) == nb, 'header says %d bones, %d SkinWeights' % (nb, len(sw)))
    need(nb <= 8, 'too many bones')
    total = np.zeros(nv)
    count = np.zeros(nv, int)
    bones = []
    for s in sw:
        b = s.group(1)
        need(b in frames, 'bone %s is no Frame' % b)
        idx, w, mat = d['bones'][b]
        need(len(set(idx.tolist())) == len(idx), '%s lists a vertex twice' % b)
        need((w > 0).all() and (w <= 1 + 1e-6).all(), '%s weight out of range' % b)
        total[idx] += w
        count[idx] += 1
        bones.append(b)
        if os.path.exists(os.path.join(VANILLA_BP, v['src'])):
            want = offset_matrices(key, [b])[b]
            need(mat == want, 'offset matrix of %s differs from its source' % b)
    need(np.abs(total - 1).max() < 1e-4, 'weights do not sum to 1 (%.5f..%.5f)' % (total.min(), total.max()))
    need(count.max() <= min(per_v, MAX_WEIGHTS), 'a vertex has %d bones (header %d)' % (count.max(), per_v))
    need(v['bone'] in bones, 'nothing weighted to %s' % v['bone'])
    if key in 'LR':
        need(bones == [v['bone']], 'a carried pack is rigid on %s' % v['bone'])
    need('AnimTicksPerSecond' in txt and 'AnimationSet' in txt, 'animation set missing')
    # worn: nothing inside the body (the straps lie on it at a clearance)
    if key in 'MF' and os.path.exists(os.path.join(SKINNED, v['body'])):
        bd = body_of(v['body'])
        near = (np.abs(verts[:, 0]) < 0.16) & (verts[:, 1] > 0.5)
        worst = min(bd.closest(p)[3] for p in verts[near][::3])
        need(worst > 0.0015, 'a vertex is %.4f from the body surface (inside or touching)' % worst)
    return nv, nf


def check_fbx():
    with open(OUT['G'], 'rb') as f:
        data = f.read()
    need(data.startswith(MAGIC), 'fbx magic')
    need(data.endswith(bytes.fromhex('f85a8c6adef5d97eece90ce3758f290b')), 'fbx footer magic')
    ver, nodes = fbx_read(data)
    need(not any(re.match(rb'[A-Za-z]:\\', s) for s in fbx_strings(nodes)), 'an absolute path of the vanilla file is left')
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
    agree = (c * N.reshape(-1, 3, 3).mean(1)).sum(1) > 0
    need(agree.mean() > 0.995, 'fbx: %d faces wound against their normals' % (~agree).sum())
    ids = {c[1][0][1] for c in objects[2] if c[1] and c[1][0][0] == 'L'}
    for c in fbx_find(nodes, 'Connections')[2]:
        for p in c[1][1:3]:
            need(p[1] == 0 or p[1] in ids, 'connection to a missing object %s' % p[1])
    lo, hi = V.min(0), V.max(0)
    need(abs(lo[2]) < 0.1 and 15 < hi[2] < 40, 'ground model should stand on z=0 and be about 25 units tall: %s %s' % (lo, hi))
    return len(V), len(F)


def check_files():
    img = Image.open(OUT['TEX'])
    need(img.size == (SHIP, SHIP), 'texture size %s' % (img.size,))
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
        except (Fail, FileNotFoundError, AttributeError, ValueError, IndexError, KeyError) as e:
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
    ap.add_argument('--icon', action='store_true', help='only render the icon source from the meshes and the atlas')
    ap.add_argument('--old', metavar='DIR', help='folder with the previous _M.x, _F.x and texture, for the before/after sheet')
    args = ap.parse_args()
    if args.check:
        sys.exit(check_all())
    if args.icon:
        _, meshes, _ = build_meshes()
        make_icon_source(meshes, np.array(Image.open(OUT['TEX']).convert('RGB')))
        print('icon source', os.path.relpath(ICON_SOURCE, ROOT))
        return
    build_all(args.old)
    sys.exit(check_all())


if __name__ == '__main__':
    main()
