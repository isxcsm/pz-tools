#!/usr/bin/env python3
"""Backgrounds tried for the research tab's tree columns (Upgrades/Window.lua), as a preview only: nothing here is
drawn by the game yet.

    py tools/tree_bg_art.py      writes tools/tree_bg_preview.png

The preview draws one column (the scout tree: its nodes, lines, pips and header strip, in the tab's colours and at its
size, UI.S 1.6) three ways, side by side:

    A  a soft light falling from the header in the tree's colour (strongest under the strip, gone about 40% down), a
       gentle vignette to the sides and the bottom, a fine film grain at a very low alpha
    B  A, with a faint emblem in the lower half (about 6%, in the tree's colour): the scout tree's radar rings and
       sweep, the load tree's truss lattice in a hexagon, the survival tree's leaf veins
    C  A, with a faint blueprint grid (about 4%) on the node grid's rows

and under them B for the load and survival trees, and the three emblems strong enough to see their shapes. Every
layer is made as the picture the game would draw (white, tinted and faded by the game; the grain and the grid tile;
the emblems 512 px, as they are drawn about 270 px across), so wiring one in is a matter of drawing these pictures.
Seeded, so the same preview comes out every time.
"""
import json
import math
import os
import random
import re

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
MEDIA = os.path.join(ROOT, 'OperationAcorn', '42', 'media')
TEXTURES = os.path.join(MEDIA, 'textures')
PREVIEW = os.path.join(HERE, 'tree_bg_preview.png')
SS = 4                      # the emblems are drawn this many times larger, then shrunk (smooth edges)

# ---- the tab's numbers (Window.lua, Trade/UI.lua's "field" palette) -------------------------------------------------
S = 1.6
COL_W, STRIP = 194, 58
ICON, CAP, GX, ROW, PIPS, GRID_PAD = 32, 40, 14, 52, 10, 12
GRID_H = GRID_PAD + 4 * ROW + CAP + PIPS + 4
BG = (0.10, 0.11, 0.08)
INSET = (0.06, 0.065, 0.045)
BORDER = (0.42, 0.45, 0.30)
VALUE = (1, 0.82, 0.25)
DIM = (0.62, 0.60, 0.52)
GOLD = (1.0, 0.84, 0.30)
LINE_DIM = (0.30, 0.32, 0.25)
TREES = {
    'scout': ((0.25, 0.66, 0.70), (0.62, 0.90, 0.95)),
    'load': ((0.86, 0.55, 0.22), (1.0, 0.80, 0.52)),
    'survival': ((0.46, 0.74, 0.32), (0.70, 0.93, 0.58)),
}

# ---- the layers' strengths in the game (the alpha each picture would be drawn at) ----------------------------------
LIGHT_A = 0.16              # the header's light at its strongest
LIGHT_END = 0.40            # gone by this share of the column's grid
VIGNETTE_A = 0.42
GRAIN_A = 0.05
EMBLEM_A = 0.07
EMBLEM_DU = 170             # the emblem's size in design units, its centre this share down the grid
EMBLEM_Y = 0.68
GRID_A, GRID_MAJOR_A = 0.035, 0.06
GRID_DU = ROW / 4           # minor lines a quarter row apart, a major one on each row's top


def mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def rgb(c, a=1.0):
    return tuple(int(round(v * 255)) for v in c) + (int(round(a * 255)),)


def px(v):
    return int(math.floor(v * S + 0.5))


def smooth(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


def white(alpha):
    """A white picture with this alpha (a float array 0..1)."""
    h, w = alpha.shape
    out = np.zeros((h, w, 4), np.uint8)
    out[..., :3] = 255
    out[..., 3] = np.clip(alpha * 255 + 0.5, 0, 255).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


# ---- the pictures --------------------------------------------------------------------------------------------------
def header_light(w=128, h=256):
    """The light under the header: full at the top, gone at the bottom (the game draws it LIGHT_END of the grid tall),
    a little narrower further down, as from a lamp over the strip."""
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    v = ys / (h - 1)
    u = (xs + 0.5) / w * 2 - 1
    fall = (1 - smooth(v)) ** 1.6
    spread = 0.55 + 0.45 * v
    side = np.exp(-(u / (1.25 - 0.5 * v)) ** 2 * spread * 1.4)
    return white(fall * side)


def vignette(n=256):
    """Dark towards the sides and the bottom (black: the game tints it), nothing at the top's middle."""
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    u = np.abs((xs + 0.5) / n * 2 - 1)
    v = (ys + 0.5) / n
    sides = smooth((u - 0.35) / 0.65) ** 1.4
    bottom = smooth((v - 0.45) / 0.55) ** 1.6
    a = 1 - (1 - 0.75 * sides) * (1 - bottom)
    img = white(a)
    arr = np.array(img)
    arr[..., :3] = 0
    return Image.fromarray(arr, 'RGBA')


def grain(n=256, seed=4242):
    """Film grain that tiles: soft specks, a third of a pixel's blur taken around the edges (it wraps)."""
    rng = np.random.default_rng(seed)
    g = rng.normal(0, 1, (n, n)).astype(np.float32)
    blur = g * 4
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        blur += np.roll(np.roll(g, dy, 0), dx, 1)
    blur /= 8
    blur = (blur - blur.min()) / (blur.max() - blur.min())
    return white(np.clip((blur - 0.35) / 0.65, 0, 1) ** 1.5)


def radar(n=512):
    """The scout tree's emblem: range rings, a crosshair, the bearing ticks and a sweep with its fading wake, blips."""
    big = n * SS
    c = big / 2
    r0 = big * 0.47
    img = Image.new('L', (big, big), 0)
    d = ImageDraw.Draw(img)
    for k, (f, w, a) in enumerate(((1.0, 14, 255), (0.75, 9, 190), (0.5, 9, 190), (0.25, 9, 190))):
        r = r0 * f
        d.ellipse((c - r, c - r, c + r, c + r), outline=a, width=w)
    d.line((c - r0, c, c + r0, c), fill=150, width=6)
    d.line((c, c - r0, c, c + r0), fill=150, width=6)
    for deg in range(0, 360, 10):
        t = math.radians(deg)
        long = deg % 30 == 0
        ri = r0 * (0.92 if long else 0.955)
        d.line((c + math.cos(t) * ri, c + math.sin(t) * ri, c + math.cos(t) * r0, c + math.sin(t) * r0),
               fill=230 if long else 160, width=8 if long else 5)
    base = np.array(img, np.float32) / 255
    # the sweep: a wake behind the leading edge (fading with the angle), the edge bright
    ys, xs = np.mgrid[0:big, 0:big].astype(np.float32)
    ang = np.degrees(np.arctan2(ys - c, xs - c))
    rad = np.hypot(xs - c, ys - c)
    lead = -50.0
    behind = np.mod(lead - ang, 360)
    wake = np.clip(1 - behind / 75, 0, 1) ** 2.2 * 0.55
    wake *= np.clip((r0 - rad) / (big * 0.01), 0, 1)
    edge = img.copy()
    ed = ImageDraw.Draw(edge)
    ed.rectangle((0, 0, big, big), fill=0)
    t = math.radians(lead)
    ed.line((c, c, c + math.cos(t) * r0, c + math.sin(t) * r0), fill=255, width=12)
    sweep = np.maximum(wake, np.array(edge, np.float32) / 255)
    # blips: a bright point with a soft halo, the nearer to the edge the fresher
    rnd = random.Random(31)
    blips = np.zeros_like(base)
    for _ in range(4):
        bt = math.radians(lead - rnd.uniform(8, 70))
        br = r0 * rnd.uniform(0.3, 0.85)
        bx, by = c + math.cos(bt) * br, c + math.sin(bt) * br
        dist = np.hypot(xs - bx, ys - by)
        blips = np.maximum(blips, np.exp(-(dist / (big * 0.012)) ** 2) * 0.95
                           + np.exp(-(dist / (big * 0.035)) ** 2) * 0.35)
    a = np.clip(np.maximum(base, np.maximum(sweep, blips)), 0, 1)
    return white(a).resize((n, n), Image.LANCZOS)


def truss(n=512):
    """The load tree's emblem: a hexagon (a bolt at each corner) braced inside by a triangular truss lattice."""
    big = n * SS
    c = big / 2
    r0 = big * 0.46
    hexagon = [(c + r0 * math.cos(math.radians(60 * k)), c + r0 * math.sin(math.radians(60 * k))) for k in range(6)]
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).polygon(hexagon, fill=255)
    lattice = Image.new('L', (big, big), 0)
    d = ImageDraw.Draw(lattice)
    step = r0 / 3
    h = step * math.sqrt(3) / 2
    span = int(big / step) + 4
    for k in range(-span, span):
        for deg in (0, 60, 120):
            t = math.radians(deg)
            nx, ny = -math.sin(t), math.cos(t)
            off = k * h
            ox, oy = c + nx * off, c + ny * off
            d.line((ox - math.cos(t) * big, oy - math.sin(t) * big, ox + math.cos(t) * big, oy + math.sin(t) * big),
                   fill=150, width=8)
    nodes = Image.new('L', (big, big), 0)
    nd = ImageDraw.Draw(nodes)
    rows = int(r0 / h) + 2
    for j in range(-rows, rows + 1):
        for i in range(-rows - 2, rows + 3):
            x = c + i * step + (j % 2) * step / 2
            y = c + j * h
            nd.ellipse((x - 16, y - 16, x + 16, y + 16), fill=200)
    inner = np.minimum(np.maximum(np.array(lattice), np.array(nodes)), np.array(mask)).astype(np.float32) / 255
    frame = Image.new('L', (big, big), 0)
    fd = ImageDraw.Draw(frame)
    fd.polygon(hexagon, outline=255, width=22)
    r1 = r0 * 0.93
    inset = [(c + r1 * math.cos(math.radians(60 * k)), c + r1 * math.sin(math.radians(60 * k))) for k in range(6)]
    fd.polygon(inset, outline=170, width=8)
    for x, y in hexagon:
        fd.ellipse((x - 34, y - 34, x + 34, y + 34), fill=255)
        fd.ellipse((x - 14, y - 14, x + 14, y + 14), fill=0)
    # the lattice fainter towards the hexagon's middle (the frame carries the shape)
    ys, xs = np.mgrid[0:big, 0:big].astype(np.float32)
    rad = np.hypot(xs - c, ys - c) / r0
    inner *= 0.45 + 0.55 * smooth(rad)
    a = np.maximum(inner, np.array(frame, np.float32) / 255)
    return white(a).resize((n, n), Image.LANCZOS)


def leaf(n=512):
    """The survival tree's emblem: a leaf, its outline, midrib, alternate side veins curving to the tip and the small
    veins between them."""
    big = n * SS
    img = Image.new('L', (big, big), 0)
    d = ImageDraw.Draw(img)
    length = big * 0.86
    tilt = math.radians(-40)
    base = (big * 0.5 - math.cos(tilt) * length / 2, big * 0.5 - math.sin(tilt) * length / 2)

    def at(t, side):
        """A point t along the leaf (0 base, 1 tip), `side` of its half width off the midrib (-1..1)."""
        bend = 0.05 * math.sin(math.pi * t) * length
        half = 0.30 * length * math.sin(math.pi * min(1, t ** 0.85)) ** 1.15
        along, across = t * length, bend + side * half
        x = base[0] + math.cos(tilt) * along - math.sin(tilt) * across
        y = base[1] + math.sin(tilt) * along + math.cos(tilt) * across
        return x, y

    steps = 120
    outline = [at(i / steps, 1) for i in range(steps + 1)] + [at(1 - i / steps, -1) for i in range(steps + 1)]
    d.line(outline + [outline[0]], fill=255, width=16, joint='curve')
    d.line([at(i / steps, 0) for i in range(steps + 1)], fill=255, width=18, joint='curve')
    # the stem
    sx, sy = at(0, 0)
    d.line((sx, sy, sx - math.cos(tilt) * big * 0.06, sy - math.sin(tilt) * big * 0.06), fill=255, width=18)
    rnd = random.Random(77)
    count = 9
    for i in range(count):
        t0 = 0.08 + i * 0.84 / count
        for side in (-1, 1):
            t0s = t0 + (0.04 if side > 0 else 0)
            pts = []
            for k in range(30):
                f = k / 29
                t = t0s + f * 0.22 * (1 - t0s * 0.4)
                pts.append(at(min(t, 0.985), side * 0.9 * (f ** 0.8)))
            d.line(pts, fill=215, width=10, joint='curve')
            # small veins off it, towards the outline
            for j in range(3):
                f = 0.25 + j * 0.22 + rnd.uniform(-0.04, 0.04)
                t = t0s + f * 0.22 * (1 - t0s * 0.4)
                a0 = at(min(t, 0.985), side * 0.9 * (f ** 0.8))
                a1 = at(min(t + 0.035, 0.985), side * min(0.97, 0.9 * (f ** 0.8) + 0.16))
                d.line((a0, a1), fill=140, width=6)
    return white(np.array(img, np.float32) / 255).resize((n, n), Image.LANCZOS)


EMBLEMS = {'scout': radar, 'load': truss, 'survival': leaf}


# ---- a column as the tab draws it ----------------------------------------------------------------------------------
def nodes_of(tree):
    """The tree's nodes from Data.lua: id -> (row, col, ranks, needs, icon slug)."""
    text = open(os.path.join(MEDIA, 'lua', 'shared', 'OperationAcorn', 'Upgrades', 'Data.lua'), encoding='utf-8').read()
    icons = dict(re.findall(r'(\w+) = "(\w+)"', text[text.index('local ICONS = {'):]))
    out = {}
    for line in text.splitlines():
        m = re.match(r'node\("(\w+)", "(\w+)", (\d+), (\d+), (\d+), "\w+"(.*)\)\s*$', line)
        if m and m.group(1) == tree:
            needs = re.findall(r'\{ "(\w+)", (\d+) \}', m.group(6))
            out[m.group(2)] = (int(m.group(3)), int(m.group(4)), int(m.group(5)), needs, icons[m.group(2)])
    return out


def cell(row, col):
    capstone = row >= 5
    if capstone:
        cx = GRID_PAD + (col - 1) * (ICON + GX) + ICON / 2
        return cx - CAP / 2, GRID_PAD + (row - 1) * ROW, CAP
    return GRID_PAD + (col - 1) * (ICON + GX), GRID_PAD + (row - 1) * ROW, ICON


def route(cells, c1, r1, c2, r2):
    """Links.route: the line's waypoints in grid units (from the bottom of the first node to the top of the second)."""
    def wp(x, c, y, r):
        xx = GRID_PAD + (c * (ICON + GX) - GX / 2 if x == 'gutter' else (c - 1) * (ICON + GX) + ICON / 2)
        top = GRID_PAD + (r - 1) * ROW
        size = CAP if r >= 5 else ICON
        yy = {'top': top, 'bottom': top + size + PIPS}.get(y, top + size + PIPS + (ROW - ICON - PIPS) / 2)
        return xx, yy

    def clear(c, ra, rb):
        return all((r, c) not in cells for r in range(ra + 1, rb))
    a, b = wp('center', c1, 'bottom', r1), wp('center', c2, 'top', r2)
    if c1 == c2 and clear(c1, r1, r2):
        return [a, b]
    if clear(c2, r1, r2):
        return [a, wp('center', c1, 'below', r1), wp('center', c2, 'below', r1), b]
    g = c2 - 1 if c1 < c2 else c2
    return [a, wp('center', c1, 'below', r1), wp('gutter', g, 'below', r1), wp('gutter', g, 'below', r2 - 1),
            wp('center', c2, 'below', r2 - 1), b]


# what the mock shows of each tree: the ranks taken (the rest open, or locked when its prerequisite is not met)
RANKS = {
    'scout': {'sixth': 2, 'sight': 2, 'alarm': 1, 'rich': 2, 'night': 1},
    'load': {'overload': 2, 'moveSpeed': 1, 'furniture': 2, 'runSpeed': 1},
    'survival': {'serumAdapt': 2, 'crowbar': 1, 'stiff': 3, 'brush': 1, 'fall': 1},
}


def font(size, bold=False):
    name = 'malgunbd.ttf' if bold else 'malgun.ttf'
    return ImageFont.truetype(os.path.join('C:/Windows/Fonts', name), size)


def tree_name(tree):
    with open(os.path.join(MEDIA, 'lua', 'shared', 'Translate', 'KO', 'IG_UI.json'), encoding='utf-8') as f:
        return json.load(f)['IGUI_OA_Tree_Name_' + tree]


def layer(dst, tex, box, c, a):
    """Draw a white picture over `box` (pixels), tinted c, at alpha a, as drawTextureScaled does."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0 or a <= 0:
        return
    img = tex.resize((w, h), Image.BICUBIC) if tex.size != (w, h) else tex
    arr = np.array(img, np.float32)
    arr[..., :3] = arr[..., :3] * np.array(c, np.float32).reshape(1, 1, 3)
    arr[..., 3] *= a
    piece = Image.fromarray(np.clip(arr + 0.5, 0, 255).astype(np.uint8), 'RGBA')
    dst.paste(piece, (x0, y0), piece)


def tiled(dst, tex, box, c, a):
    """A tiling picture over `box`, at its own pixels."""
    x0, y0, x1, y1 = box
    sheet = Image.new('RGBA', (x1 - x0, y1 - y0), (0, 0, 0, 0))
    for y in range(0, y1 - y0, tex.height):
        for x in range(0, x1 - x0, tex.width):
            sheet.paste(tex, (x, y))
    layer(dst, sheet, box, c, a)


PICS = {}


def pics():
    if not PICS:
        PICS.update(light=header_light(), vignette=vignette(), grain=grain(),
                    **{t: f() for t, f in EMBLEMS.items()})
    return PICS


def column(tree, variant):
    """One column, `variant` "A", "B" or "C", in pixels at UI.S."""
    c, light = TREES[tree]
    strip = mix(BG, c, 0.26)
    body = mix(INSET, c, 0.12)
    W, H = px(COL_W), px(STRIP + GRID_H)
    img = Image.new('RGB', (W, H), rgb(body)[:3])     # RGB: Draw(img, 'RGBA') blends what it draws
    p = pics()
    gy = px(STRIP)
    # the background under everything: the light from the header, the vignette, the grain
    layer(img, p['light'], (0, gy, W, gy + px(GRID_H * LIGHT_END)), light, LIGHT_A)
    if variant == 'B':
        size = px(EMBLEM_DU)
        cx, cy = W // 2, gy + px(GRID_H * EMBLEM_Y)
        layer(img, p[tree], (cx - size // 2, cy - size // 2, cx - size // 2 + size, cy - size // 2 + size), light,
              EMBLEM_A)
    if variant == 'C':
        d = ImageDraw.Draw(img, 'RGBA')
        k = 0
        y = 0.0
        while y <= GRID_H:
            a = GRID_MAJOR_A if k % 4 == 0 else GRID_A
            yy = gy + px(GRID_PAD + y)
            if yy < H:
                d.line((0, yy, W, yy), fill=rgb(light, a))
            k, y = k + 1, y + GRID_DU
        k, x = 0, 0.0
        while GRID_PAD + x < COL_W:
            a = GRID_MAJOR_A if k % 4 == 0 else GRID_A
            xx = px(GRID_PAD + x)
            d.line((xx, gy, xx, H), fill=rgb(light, a))
            k, x = k + 1, x + GRID_DU
    layer(img, p['vignette'], (0, gy, W, H), (0, 0, 0), VIGNETTE_A)
    tiled(img, p['grain'], (0, 0, W, H), (1, 1, 1), GRAIN_A)
    d = ImageDraw.Draw(img, 'RGBA')
    # the strip
    d.rectangle((0, 0, W - 1, gy - 1), fill=rgb(strip))
    d.rectangle((0, 0, W - 1, px(2) - 1), fill=rgb(c))
    d.text((px(10), px(5)), tree_name(tree), font=font(px(13), True), fill=rgb(light))
    d.text((px(10), px(27)), '남은 포인트 3', font=font(px(10)), fill=rgb(VALUE))
    bx, by, bw, bh = px(10), px(STRIP - 7 - 6), px(COL_W - 20), px(7)
    d.rectangle((bx, by, bx + bw - 1, by + bh - 1), fill=rgb(INSET))
    d.rectangle((bx, by, bx + int(bw * 0.45) - 1, by + bh - 1), fill=rgb(c))
    tiled(img, p['grain'], (0, 0, W, gy), (1, 1, 1), GRAIN_A * 0.6)
    # the lines, then the nodes with their pips
    nodes = nodes_of(tree)
    ranks = RANKS[tree]
    cells = {(r, col): i for i, (r, col, _, _, _) in nodes.items()}
    lw = max(2, px(1.5))
    for nid, (r, col, _, needs, _) in nodes.items():
        for need, k in needs:
            nr, ncol = nodes[need][0], nodes[need][1]
            pts = route(cells, ncol, nr, col, r)
            lit = ranks.get(need, 0) >= int(k)
            colour = rgb(c, 0.95) if lit else rgb(LINE_DIM)
            tip = max(3, px(3))
            for i in range(len(pts) - 1):
                (xa, ya), (xb, yb) = pts[i], pts[i + 1]
                if i == len(pts) - 2:
                    yb -= tip / S
                x0, x1 = sorted((px(xa), px(xb)))
                y0, y1 = sorted((gy + px(ya), gy + px(yb)))
                d.rectangle((x0 - lw // 2, y0 - lw // 2, x1 - lw // 2 + lw - 1, y1 - lw // 2 + lw - 1), fill=colour)
            ex, ey = px(pts[-1][0]), gy + px(pts[-1][1]) - tip
            for i in range(tip):
                w = 2 * (tip - i) - 1
                d.rectangle((ex - w // 2, ey + i, ex - w // 2 + w - 1, ey + i), fill=colour)
    for nid, (r, col, total, needs, slug) in nodes.items():
        x, y, s = cell(r, col)
        met = all(ranks.get(need, 0) >= int(k) for need, k in needs)
        taken = ranks.get(nid, 0)
        X0, Y0, S0 = px(x), gy + px(y), px(s)
        icon = Image.open(os.path.join(TEXTURES, 'OA_Node_%s%s.png' % (slug, '' if met else '_Gray')))
        ipx = max(16, 8 * int(s * S / 8))
        icon = icon.resize((ipx, ipx), Image.LANCZOS)
        if not met:
            icon.putalpha(icon.getchannel('A').point(lambda v: int(v * 0.8)))
        img.paste(icon, (X0 + (S0 - ipx) // 2, Y0 + (S0 - ipx) // 2), icon)
        th = max(2, int(S * 1.25 + 0.5))
        o = px(2)
        if not met:
            d.rectangle((X0 - o, Y0 - o, X0 + S0 + o - 1, Y0 + S0 + o - 1), outline=rgb(BORDER, 0.45), width=1)
            rr = px(7.5)
            cx, cy = X0 + S0 - rr + 1, Y0 + S0 - rr + 1
            d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=(8, 8, 8, 235))
            d.rectangle((cx - px(3), cy - px(1), cx + px(3), cy + px(3.5)), fill=rgb((0.92, 0.90, 0.82), 0.9))
            d.arc((cx - px(2.5), cy - px(5), cx + px(2.5), cy + px(1)), 180, 360, fill=rgb((0.92, 0.90, 0.82), 0.9),
                  width=max(1, px(1)))
        else:
            frame_c = rgb(GOLD) if taken >= total else rgb(c, 0.75)
            d.rectangle((X0 - o, Y0 - o, X0 + S0 + o - 1, Y0 + S0 + o - 1), outline=frame_c, width=th)
        # the pips
        pr = px(2.2)
        gap = px(7)
        py_ = Y0 + S0 + px(6)
        start = X0 + S0 // 2 - (total - 1) * gap // 2
        for i in range(total):
            cx = start + i * gap
            fill = rgb(GOLD) if i < taken else rgb(DIM, 0.35)
            d.ellipse((cx - pr, py_ - pr, cx + pr, py_ + pr), fill=fill)
    d.rectangle((0, 0, W - 1, H - 1), outline=rgb(BORDER))
    return img


def emblem_sheet():
    """The three emblems strong enough to see, each tinted as its tree's, on the tab's inset colour."""
    size = 200
    gap = 16
    out = Image.new('RGB', (3 * size + 4 * gap, size + 2 * gap), rgb(INSET)[:3])
    for i, tree in enumerate(('scout', 'load', 'survival')):
        x = gap + i * (size + gap)
        layer(out, pics()[tree], (x, gap, x + size, gap + size), TREES[tree][1], 0.8)
    return out


def main():
    label = font(22, True)
    small = font(17)
    row1 = [('A', column('scout', 'A')), ('B', column('scout', 'B')), ('C', column('scout', 'C'))]
    row2 = [('B', column('load', 'B')), ('B', column('survival', 'B'))]
    notes = {
        'A': 'A  빛 · 비네트 · 그레인',
        'B': 'B  A + 옅은 문양 (%d%%)' % round(EMBLEM_A * 100),
        'C': 'C  A + 청사진 격자 (%d%%)' % round(GRID_A * 100 + 0.5),
    }
    gap, top = 28, 46
    W1, H1 = row1[0][1].size
    sheet = emblem_sheet()
    width = gap + 3 * (W1 + gap)
    height = top + H1 + top + H1 + gap + 30
    out = Image.new('RGB', (max(width, 2 * (W1 + gap) + sheet.width + gap * 2), height), (24, 24, 22))
    d = ImageDraw.Draw(out)
    for i, (v, img) in enumerate(row1):
        x = gap + i * (W1 + gap)
        d.text((x, 12), notes[v], font=label, fill=(225, 220, 200))
        out.paste(img.convert('RGB'), (x, top))
    y2 = top + H1 + top
    for i, ((v, img), tree) in enumerate(zip(row2, ('load', 'survival'))):
        x = gap + i * (W1 + gap)
        d.text((x, y2 - 34), 'B  ' + tree_name(tree), font=label, fill=(225, 220, 200))
        out.paste(img.convert('RGB'), (x, y2))
    sx = gap + 2 * (W1 + gap)
    d.text((sx, y2 - 34), '문양 원본 (진하게)', font=label, fill=(225, 220, 200))
    out.paste(sheet.convert('RGB'), (sx, y2))
    d.text((sx, y2 + sheet.height + 10), '레이더 · 트러스 · 잎맥', font=small, fill=(170, 165, 150))
    d.text((gap, height - 30), '실제 크기 (UI.S %.1f, 열 %d×%d px), 게임 미적용 미리보기' % (S, W1, H1), font=small,
           fill=(160, 156, 140))
    out.save(PREVIEW)
    print('wrote', os.path.relpath(PREVIEW, ROOT))


if __name__ == '__main__':
    main()
