#!/usr/bin/env python3
"""Operation Acorn map overlay pictures, drawn over the world map and the minimap by Story/Maps.lua.

Usage:
    python tools/map_art.py                     write media/textures/OA_Map_*.png
    python tools/map_art.py --mockup DIR        also render mockups of the overlay into DIR (PNG, and an animated PNG)

Every picture is made at twice the size it shows at with the UI scale 1 (the game draws UI textures without mipmaps:
a picture shrunk to half stays smooth, and at the scale 2 of a 4K screen it is drawn pixel for pixel). Shapes are
sampled 4x4 per pixel. White parts are tinted as they are drawn; the dark outlines stay dark under any tint. The
fully clear pixels carry the colour of their nearest neighbours, so the game's filtering leaves no dark fringe.
  OA_Map_Dash        a dash of the way and of the ring: a white capsule with a dark outline (drawn stretched along it)
  OA_Map_Fill        the circle's soft fill: faint in the middle, stronger toward the rim
  OA_Map_Pulse       the ring's pulse: a soft thin ring, drawn growing and fading
  OA_Map_Ripple      the pins' ripples: a soft ring for small sizes
  OA_Map_Shadow      a pin's soft shadow on the map
  OA_Map_Pin         the destination pin (tinted): a teardrop with a dark outline, its tip at the bottom middle
  OA_Map_PinDot      over it, untinted: the white dot in a dark ring, and a gloss
  OA_Map_Me          the player's pin (tinted): a round badge on a short point
  OA_Map_MeGlyph     over it, untinted: a person, and a gloss
  OA_Map_Crate       a supply crate (tinted): a rounded badge with a crate's planks drawn dark

The mockups draw the overlay the way Story/Maps.lua does (its sizes, colours and timing are repeated below, and the
dash geometry is Story/MapFx.lua's, ported) over a made-up paper map like the game's.
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
SS = 4
DARK = (0.075, 0.09, 0.105)


# ---- drawing helpers ---------------------------------------------------------------------------------------------

def grid(w, h):
    """Sample points (4x4 per pixel), in the picture's pixels."""
    xs = (np.arange(w * SS) + 0.5) / SS
    ys = (np.arange(h * SS) + 0.5) / SS
    return np.meshgrid(xs, ys)


def cover(sd):
    """How much of a sample a shape with this signed distance (pixels, inside < 0) covers: sharp, the 4x4 sampling
    does the smoothing."""
    return np.clip(0.5 - sd * SS, 0.0, 1.0)


def sd_circle(X, Y, cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def sd_capsule(X, Y, ax, ay, bx, by, r):
    px, py = X - ax, Y - ay
    dx, dy = bx - ax, by - ay
    t = np.clip((px * dx + py * dy) / (dx * dx + dy * dy), 0, 1)
    return np.hypot(px - dx * t, py - dy * t) - r


def sd_round_rect(X, Y, cx, cy, hw, hh, rad):
    qx = np.abs(X - cx) - (hw - rad)
    qy = np.abs(Y - cy) - (hh - rad)
    out = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    return out + np.minimum(np.maximum(qx, qy), 0) - rad


def sd_convex(X, Y, pts):
    """A convex polygon (points clockwise on the screen): the largest of its sides' distances."""
    d = None
    n = len(pts)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        ln = math.hypot(ex, ey)
        nx, ny = ey / ln, -ex / ln  # the outward normal of a clockwise polygon (y down)
        side = (X - ax) * nx + (Y - ay) * ny
        d = side if d is None else np.maximum(d, side)
    return d


def sd_teardrop(X, Y, cx, cy, r, tx, ty):
    """A circle and the tip below it joined by the two lines touching the circle: a map pin."""
    dx, dy = cx - tx, cy - ty
    d = math.hypot(dx, dy)
    a = math.asin(r / d)
    base = math.atan2(dy, dx)
    lt = math.sqrt(d * d - r * r)
    p1 = (tx + math.cos(base + a) * lt, ty + math.sin(base + a) * lt)
    p2 = (tx + math.cos(base - a) * lt, ty + math.sin(base - a) * lt)
    tri = sd_convex(X, Y, [(tx, ty), p2, (cx, cy), p1][::-1])
    tri2 = sd_convex(X, Y, [(tx, ty), p1, (cx, cy), p2][::-1])
    tri = np.minimum(tri, tri2)  # whichever winding is the clockwise one
    return np.minimum(sd_circle(X, Y, cx, cy, r), tri)


class Layer:
    """A picture being painted, premultiplied, at 4x4 samples per pixel."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.rgb = np.zeros((h * SS, w * SS, 3))
        self.a = np.zeros((h * SS, w * SS))

    def paint(self, color, alpha):
        """Paints `color` (one colour, or an array of greys or colours) over it where `alpha` says."""
        c = np.asarray(color, dtype=float)
        if c.ndim == 2:
            c = c[..., None]
        self.rgb = self.rgb * (1 - alpha)[..., None] + c * alpha[..., None]
        self.a = self.a * (1 - alpha) + alpha

    def image(self):
        h, w = self.h, self.w
        rgb = self.rgb.reshape(h, SS, w, SS, 3).mean(axis=(1, 3))
        a = self.a.reshape(h, SS, w, SS).mean(axis=(1, 3))
        return finish(rgb, a)


def finish(rgb_premul, a):
    """An RGBA picture from premultiplied colour and alpha, the clear pixels given their neighbours' colour."""
    rgb = np.where(a[..., None] > 1e-6, rgb_premul / np.maximum(a, 1e-6)[..., None], 0)
    have = a > 1e-6
    rgb = rgb.copy()
    for _ in range(6):
        if have.all():
            break
        acc = np.zeros_like(rgb)
        cnt = np.zeros(a.shape)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                sh = np.roll(np.roll(have, dy, 0), dx, 1)
                acc += np.roll(np.roll(rgb, dy, 0), dx, 1) * sh[..., None]
                cnt += sh
        fill = (~have) & (cnt > 0)
        rgb[fill] = acc[fill] / cnt[fill][..., None]
        have = have | fill
    out = np.dstack([np.clip(rgb, 0, 1), np.clip(a, 0, 1)])
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")


def radial(size, fn):
    """A white picture whose alpha is fn(r), r the distance from the middle over the half size."""
    X, Y = grid(size, size)
    r = np.hypot(X - size / 2, Y - size / 2) / (size / 2)
    a = np.clip(fn(r), 0, 1) * (r < 1)
    layer = Layer(size, size)
    layer.paint((1, 1, 1), a)
    return layer.image()


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def shade(X, Y, x0, y0, x1, y1, low):
    """Grey from 1 at (x0, y0) to `low` at (x1, y1): the light from the top left."""
    dx, dy = x1 - x0, y1 - y0
    t = np.clip(((X - x0) * dx + (Y - y0) * dy) / (dx * dx + dy * dy), 0, 1)
    return 1 - (1 - low) * t


def gloss(X, Y, cx, cy, rx, ry, angle, inside):
    """A soft white highlight: an ellipse, faded at its edge, inside the shape `inside` (a coverage)."""
    c, s = math.cos(angle), math.sin(angle)
    u = ((X - cx) * c + (Y - cy) * s) / rx
    v = (-(X - cx) * s + (Y - cy) * c) / ry
    return smoothstep(1.0, 0.35, np.hypot(u, v)) * inside


# ---- the pictures --------------------------------------------------------------------------------------------------

def dash():
    w, h = 40, 16
    X, Y = grid(w, h)
    layer = Layer(w, h)
    layer.paint(DARK, cover(sd_capsule(X, Y, 8, 8, 32, 8, 8)))
    layer.paint((1, 1, 1), cover(sd_capsule(X, Y, 8, 8, 32, 8, 5)))
    return layer.image()


def fill():
    return radial(256, lambda r: (0.40 + 0.60 * smoothstep(0.50, 0.985, r)) * smoothstep(1.0, 0.992, r))


def pulse():
    return radial(256, lambda r: np.exp(-0.5 * ((r - 0.92) / 0.032) ** 2) * smoothstep(1.0, 0.985, r))


def ripple():
    return radial(48, lambda r: np.exp(-0.5 * ((r - 0.74) / 0.13) ** 2) * smoothstep(1.0, 0.92, r))


def shadow():
    w, h = 32, 32
    X, Y = grid(w, h)
    r = np.hypot(X - w / 2, Y - h / 2) / (w / 2)
    layer = Layer(w, h)
    layer.paint((0, 0, 0), 0.9 * np.exp(-3.0 * r * r) * smoothstep(1.0, 0.8, r))
    return layer.image()


# The destination pin: 64 x 88 (32 x 44 shown): the head's middle and radius, the tip at the bottom middle.
PIN_W, PIN_H, PIN_C, PIN_R, PIN_TIP = 64, 88, (32, 30), 28.5, (32, 87.2)
OUTLINE = 3.0


def pin_shape(X, Y):
    return sd_teardrop(X, Y, PIN_C[0], PIN_C[1], PIN_R, PIN_TIP[0], PIN_TIP[1])


def pin():
    X, Y = grid(PIN_W, PIN_H)
    layer = Layer(PIN_W, PIN_H)
    outer = pin_shape(X, Y)
    layer.paint(DARK, cover(outer))
    cx, cy, r = PIN_C[0], PIN_C[1], PIN_R
    layer.paint(shade(X, Y, cx - r * 0.55, cy - r * 0.75, cx + r * 0.6, PIN_TIP[1] - 6, 0.72), cover(outer + OUTLINE))
    return layer.image()


def pin_dot():
    X, Y = grid(PIN_W, PIN_H)
    layer = Layer(PIN_W, PIN_H)
    cx, cy, r = PIN_C[0], PIN_C[1], PIN_R
    inside = cover(pin_shape(X, Y) + OUTLINE + 1)
    layer.paint((1, 1, 1), 0.55 * gloss(X, Y, cx - r * 0.42, cy - r * 0.5, r * 0.4, r * 0.2, -0.65, inside))
    layer.paint(DARK, 0.85 * cover(sd_circle(X, Y, cx, cy, r * 0.47)))
    layer.paint((1, 1, 1), cover(sd_circle(X, Y, cx, cy, r * 0.35)))
    return layer.image()


# The player's pin: 52 x 66 (26 x 33 shown): a round badge and a short point to the tip at the bottom middle.
ME_W, ME_H, ME_C, ME_R, ME_TIP = 52, 66, (26, 24), 22.5, (26, 65.2)


def me_shape(X, Y):
    cx, cy, r = ME_C[0], ME_C[1], ME_R
    badge = sd_circle(X, Y, cx, cy, r)
    point = sd_convex(X, Y, [ME_TIP, (cx - r * 0.5, cy + r * 0.7), (cx + r * 0.5, cy + r * 0.7)])
    return np.minimum(badge, point)


def me():
    X, Y = grid(ME_W, ME_H)
    layer = Layer(ME_W, ME_H)
    outer = me_shape(X, Y)
    layer.paint(DARK, cover(outer))
    cx, cy, r = ME_C[0], ME_C[1], ME_R
    layer.paint(shade(X, Y, cx - r * 0.55, cy - r * 0.8, cx + r * 0.6, ME_TIP[1] - 6, 0.74), cover(outer + OUTLINE))
    return layer.image()


def me_glyph():
    X, Y = grid(ME_W, ME_H)
    layer = Layer(ME_W, ME_H)
    cx, cy, r = ME_C[0], ME_C[1], ME_R
    inside = cover(me_shape(X, Y) + OUTLINE + 1)
    layer.paint((1, 1, 1), 0.5 * gloss(X, Y, cx - r * 0.42, cy - r * 0.5, r * 0.38, r * 0.19, -0.7, inside))
    # a person: a head, and shoulders cut round by the badge's inside
    hy = cy - r * 0.3
    head = sd_circle(X, Y, cx, hy, r * 0.27)
    body = np.maximum(sd_circle(X, Y, cx, cy + r * 0.62, r * 0.52), sd_circle(X, Y, cx, cy, r - OUTLINE - 1.5))
    body = np.maximum(body, -sd_circle(X, Y, cx, hy, r * 0.39))
    layer.paint((1, 1, 1), cover(np.minimum(head, body)))
    return layer.image()


def crate():
    w = h = 40
    X, Y = grid(w, h)
    layer = Layer(w, h)
    outer = sd_round_rect(X, Y, 20, 20, 17.8, 17.8, 7)
    layer.paint(DARK, cover(outer))
    inner = cover(outer + OUTLINE)
    layer.paint(shade(X, Y, 6, 6, 34, 34, 0.78), inner)
    # the planks: a frame inside and a brace across it
    frame = np.abs(sd_round_rect(X, Y, 20, 20, 9.6, 9.6, 1.5)) - 1.15
    brace = np.maximum(sd_capsule(X, Y, 11.5, 28.5, 28.5, 11.5, 1.15), sd_round_rect(X, Y, 20, 20, 9.6, 9.6, 1.5))
    layer.paint(DARK, 0.82 * cover(np.minimum(frame, brace)) * inner)
    return layer.image()


PICTURES = {
    "OA_Map_Dash": dash, "OA_Map_Fill": fill, "OA_Map_Pulse": pulse, "OA_Map_Ripple": ripple,
    "OA_Map_Shadow": shadow, "OA_Map_Pin": pin, "OA_Map_PinDot": pin_dot, "OA_Map_Me": me,
    "OA_Map_MeGlyph": me_glyph, "OA_Map_Crate": crate,
}


# ---- the mockups: Story/Maps.lua's drawing, repeated --------------------------------------------------------------

# Story/Maps.lua's numbers (pixels at the UI scale 1; ms).
WORLD = dict(ring_dash=14, ring_gap=9, ring_thick=6, ring_speed=10, path_dash=20, path_gap=12, path_thick=8,
             path_speed=34, path_start=10, fill_a=0.30, min_r=12, pin_w=32, pin_h=44, pulse=True, anim=True,
             crates=True, me=True)
MINI = dict(ring_dash=10, ring_gap=7, ring_thick=4.5, ring_speed=10, path_dash=14, path_gap=9, path_thick=6,
            path_speed=28, path_start=4, fill_a=0.30, min_r=8, pin_w=22, pin_h=30, pulse=False, anim=False,
            crates=False, me=False)
DIM_FILL, DIM_RING = 0.55, 0.5
PULSE_MS, PULSE_FROM, PULSE_TO, PULSE_A = 2600, 0.96, 1.32, 0.75
PULSE_RING = 0.92
DROP_MS, DROP_H, DROP_STAGGER = 650, 48, 90
BOB_MS, BOB_H = 1700, 3.5
TIP_FROM, TIP_TO, TIP_A = 3, 22, 1.0
ME_MS, ME_FROM, ME_TO, ME_A, ME_POP = 2200, 4, 26, 0.9, 0.08
ME_W_SHOWN, ME_H_SHOWN = 26, 33
CRATE_SHOWN = 20
SHADOW_R, SHADOW_A = 8, 0.38
TEAL, SKY, CRATE, MECOL = (0.08, 0.84, 0.76), (0.30, 0.62, 1.0), (1.0, 0.58, 0.12), (1.0, 0.36, 0.38)


# Story/MapFx.lua, ported.
def fx_phase(t, period):
    f = math.fmod(t, period) / period
    return f + 1 if f < 0 else f


def fx_wave(f):
    return 0.5 - 0.5 * math.cos(2 * math.pi * f)


def fx_ease_out(f):
    return 1 - (1 - f) * (1 - f)


def fx_bounce(f):
    if f <= 0:
        return 0.0
    if f >= 1:
        return 1.0
    n, d = 7.5625, 2.75
    if f < 1 / d:
        return n * f * f
    if f < 2 / d:
        f -= 1.5 / d
        return n * f * f + 0.75
    if f < 2.5 / d:
        f -= 2.25 / d
        return n * f * f + 0.9375
    f -= 2.625 / d
    return n * f * f + 0.984375


def fx_clip(x1, y1, x2, y2, minx, miny, maxx, maxy):
    t0, t1 = 0.0, 1.0
    dx, dy = x2 - x1, y2 - y1
    for p, q in ((-dx, x1 - minx), (dx, maxx - x1), (-dy, y1 - miny), (dy, maxy - y1)):
        if p == 0:
            if q < 0:
                return None
            continue
        r = q / p
        if p < 0:
            if r > t1:
                return None
            t0 = max(t0, r)
        else:
            if r < t0:
                return None
            t1 = min(t1, r)
    return t0, t1


def fx_line_dashes(x1, y1, x2, y2, dash_, gap, shift, view):
    out = []
    dx, dy = x2 - x1, y2 - y1
    ln = math.hypot(dx, dy)
    if ln < 0.5:
        return out
    c = fx_clip(x1, y1, x2, y2, view[0] - dash_, view[1] - dash_, view[2] + dash_, view[3] + dash_)
    if not c:
        return out
    period = dash_ + gap
    shift = math.fmod(shift, period)
    a, b = c[0] * ln, c[1] * ln
    ux, uy = dx / ln, dy / ln
    s = shift + math.floor((a - shift - dash_) / period) * period
    while s < b:
        e = s + dash_
        if e > a:
            cs, ce = max(s, 0), min(e, ln)
            if ce > cs:
                out.append((x1 + ux * cs, y1 + uy * cs, x1 + ux * ce, y1 + uy * ce))
        s += period
    return out


def fx_samples(radius):
    return (32 if radius < 120 else 64 if radius < 500 else 128 if radius < 2000 else 256 if radius < 8000
            else 512 if radius < 32000 else 1024)


def fx_ring(cx, cy, ax, ay, bx, by, dash_, gap, shift, view, pad):
    n = fx_samples(max(math.hypot(ax, ay), math.hypot(bx, by)))
    xs = [cx + math.cos(2 * math.pi * i / n) * ax + math.sin(2 * math.pi * i / n) * bx for i in range(n + 1)]
    ys = [cy + math.cos(2 * math.pi * i / n) * ay + math.sin(2 * math.pi * i / n) * by for i in range(n + 1)]
    lens = [0.0]
    for i in range(n):
        lens.append(lens[-1] + math.hypot(xs[i + 1] - xs[i], ys[i + 1] - ys[i]))
    total = lens[-1]
    count = max(3, int(math.floor(total / (dash_ + gap) + 0.5)))
    period = total / count
    d = dash_ * period / (dash_ + gap)
    shift = math.fmod(shift, period)
    out = []
    for k in range(count):
        s = shift + k * period
        e = s + d
        if e >= total:
            e -= total

        def at(v):
            i = 0
            while i < n - 1 and lens[i + 1] < v:
                i += 1
            g = lens[i + 1] - lens[i]
            f = (v - lens[i]) / g if g > 0 else 0
            return xs[i] + (xs[i + 1] - xs[i]) * f, ys[i] + (ys[i + 1] - ys[i]) * f
        out.append(at(s) + at(e))
    return out


class Canvas:
    def __init__(self, bg):
        self.img = bg.convert("RGBA")
        self.cache = {}

    def tex(self, name, tint):
        key = (name, tint)
        if key not in self.cache:
            t = Image.open(os.path.join(OUT_DIR, name + ".png")).convert("RGBA")
            a = np.asarray(t).astype(float) / 255
            a[..., 0] *= tint[0]
            a[..., 1] *= tint[1]
            a[..., 2] *= tint[2]
            self.cache[key] = a
        return self.cache[key]

    def quad(self, name, tl, tr, br, bl, tint, alpha):
        """The texture on the parallelogram tl, tr, br, bl (the corners the game takes), tinted, as the game's
        DrawTexture: bilinear, no mipmaps."""
        if alpha <= 0.003:
            return
        src = self.tex(name, tint)
        th, tw = src.shape[:2]
        xs = [tl[0], tr[0], br[0], bl[0]]
        ys = [tl[1], tr[1], br[1], bl[1]]
        x0, y0 = int(math.floor(min(xs))) - 1, int(math.floor(min(ys))) - 1
        x1, y1 = int(math.ceil(max(xs))) + 1, int(math.ceil(max(ys))) + 1
        x0, y0 = max(x0, 0), max(y0, 0)
        x1, y1 = min(x1, self.img.width), min(y1, self.img.height)
        if x1 <= x0 or y1 <= y0:
            return
        ux, uy = (tr[0] - tl[0]) / tw, (tr[1] - tl[1]) / tw
        vx, vy = (bl[0] - tl[0]) / th, (bl[1] - tl[1]) / th
        det = ux * vy - uy * vx
        if abs(det) < 1e-9:
            return
        gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5 - tl[0], np.arange(y0, y1) + 0.5 - tl[1])
        u = (gx * vy - gy * vx) / det - 0.5
        v = (-gx * uy + gy * ux) / det - 0.5
        inside = (u > -1) & (v > -1) & (u < tw) & (v < th)
        if not inside.any():
            return
        u0 = np.floor(u).astype(int)
        v0 = np.floor(v).astype(int)
        fu, fv = (u - u0)[..., None], (v - v0)[..., None]
        padded = np.zeros((th + 2, tw + 2, 4))
        padded[1:-1, 1:-1] = src
        padded[0, 1:-1] = src[0]
        padded[-1, 1:-1] = src[-1]
        padded[:, 0] = padded[:, 1]
        padded[:, -1] = padded[:, -2]
        padded[0, :, 3] = 0
        padded[-1, :, 3] = 0
        padded[:, 0, 3] = 0
        padded[:, -1, 3] = 0

        def at(uu, vv):
            return padded[np.clip(vv + 1, 0, th + 1), np.clip(uu + 1, 0, tw + 1)]
        c = (at(u0, v0) * (1 - fu) * (1 - fv) + at(u0 + 1, v0) * fu * (1 - fv) + at(u0, v0 + 1) * (1 - fu) * fv
             + at(u0 + 1, v0 + 1) * fu * fv)
        a = c[..., 3] * alpha * inside
        base = np.asarray(self.img.crop((x0, y0, x1, y1))).astype(float) / 255
        base[..., :3] = base[..., :3] * (1 - a[..., None]) + c[..., :3] * a[..., None]
        patch = Image.fromarray((np.clip(base, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")
        self.img.paste(patch, (x0, y0))


def draw_overlay(cv, view, frame, scene, style, s, now, drop_at):
    """Story/Maps.lua's draw: `frame` = (ox, oy, exX, exY, eyX, eyY, px, py), the screen's place of the player and of
    one square east and south; view = (0, 0, w, h)."""
    ox, oy, exX, exY, eyX, eyY, px, py = frame

    def screen(wx, wy):
        return ox + (wx - px) * exX + (wy - py) * eyX, oy + (wx - px) * exY + (wy - py) * eyY

    hs = math.hypot(exX, eyX)
    unit = 1 / hs

    def plane(name, cx, cy, rx, ry, tint, a):
        axx, axy = exX * unit * rx, exY * unit * rx
        bxx, bxy = eyX * unit * ry, eyY * unit * ry
        cv.quad(name, (cx - axx - bxx, cy - axy - bxy), (cx + axx - bxx, cy + axy - bxy),
                (cx + axx + bxx, cy + axy + bxy), (cx - axx + bxx, cy - axy + bxy), tint, a)

    def dash_quad(x1, y1, x2, y2, thick, tint, a):
        dx, dy = x2 - x1, y2 - y1
        ln = math.hypot(dx, dy)
        if ln < 0.01:
            return
        nx, ny = -dy / ln * thick / 2, dx / ln * thick / 2
        cv.quad("OA_Map_Dash", (x1 - nx, y1 - ny), (x2 - nx, y2 - ny), (x2 + nx, y2 + ny), (x1 + nx, y1 + ny), tint, a)

    def upright(name, x, y, w, h, tint, a):
        cv.quad(name, (x - w / 2, y - h), (x + w / 2, y - h), (x + w / 2, y), (x - w / 2, y), tint, a)

    circles = []
    for c in scene["circles"]:
        r = c["r"]
        if r * hs < style["min_r"] * s:
            r = style["min_r"] * s / hs
        cx, cy = screen(c["x"], c["y"])
        circles.append((c, cx, cy, r))
    for c, cx, cy, r in circles:
        ax, ay, bx, by = exX * r, exY * r, eyX * r, eyY * r
        corner = lambda i, j: (cx + i * ax + j * bx, cy + i * ay + j * by)
        a = style["fill_a"] * (DIM_FILL if c["dim"] else 1)
        cv.quad("OA_Map_Fill", corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1), c["color"], a)
        if style["pulse"] and not c["dim"]:
            f = fx_phase(now, PULSE_MS)
            k = (PULSE_FROM + (PULSE_TO - PULSE_FROM) * fx_ease_out(f)) / PULSE_RING
            corner = lambda i, j: (cx + (i * ax + j * bx) * k, cy + (i * ay + j * by) * k)
            cv.quad("OA_Map_Pulse", corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1), c["color"],
                    PULSE_A * (1 - f) ** 2)
    for c, cx, cy, r in circles:
        ax, ay, bx, by = exX * r, exY * r, eyX * r, eyY * r
        for d in fx_ring(cx, cy, ax, ay, bx, by, style["ring_dash"] * s, style["ring_gap"] * s,
                         now * style["ring_speed"] * s / 1000, view, style["ring_thick"] * s):
            dash_quad(*d, style["ring_thick"] * s, c["color"], DIM_RING if c["dim"] else 1)
    lead = scene.get("lead")
    if lead:
        for c, cx, cy, r in circles:
            if c is lead:
                dx, dy = px - c["x"], py - c["y"]
                dd = math.hypot(dx, dy)
                if dd > r:
                    ex, ey = screen(c["x"] + dx * r / dd, c["y"] + dy * r / dd)
                    sx, sy = ox, oy
                    ln = math.hypot(ex - sx, ey - sy)
                    if ln > style["path_start"] * s:
                        sx += (ex - sx) / ln * style["path_start"] * s
                        sy += (ey - sy) / ln * style["path_start"] * s
                        for d in fx_line_dashes(sx, sy, ex, ey, style["path_dash"] * s, style["path_gap"] * s,
                                                now * style["path_speed"] * s / 1000, view):
                            dash_quad(*d, style["path_thick"] * s, c["color"], 1)
    if style["crates"]:
        for k in scene["crates"]:
            x, y = screen(k["x"], k["y"])
            plane("OA_Map_Shadow", x, y + 1 * s, 9 * s, 9 * s, (1, 1, 1), 0.3)
            z = CRATE_SHOWN * s
            cv.quad("OA_Map_Crate", (x - z / 2, y - z / 2), (x + z / 2, y - z / 2), (x + z / 2, y + z / 2),
                    (x - z / 2, y + z / 2), CRATE, 1)
    index = 0
    for c, cx, cy, r in circles:
        if c["dim"]:
            continue
        h, a, tip = 0.0, 1.0, None
        if style["anim"]:
            t = now - drop_at - index * DROP_STAGGER
            if t < DROP_MS:
                h = DROP_H * s * (1 - fx_bounce(max(t, 0) / DROP_MS))
                a = min(1.0, max(t, 0) / 120)
            else:
                f = fx_phase(t - DROP_MS, BOB_MS)
                h = BOB_H * s * fx_wave(f)
                tip = f
        hf = h / (DROP_H * s)
        plane("OA_Map_Shadow", cx, cy, SHADOW_R * s * (1 - 0.35 * hf), SHADOW_R * s * (1 - 0.35 * hf), (1, 1, 1),
              SHADOW_A * (1 - 0.5 * hf) * a)
        if tip is not None:
            rr = (TIP_FROM + (TIP_TO - TIP_FROM) * fx_ease_out(tip)) * s
            plane("OA_Map_Ripple", cx, cy, rr, rr, c["color"], TIP_A * (1 - tip) ** 1.6)
        w, hh = style["pin_w"] * s, style["pin_h"] * s
        upright("OA_Map_Pin", cx, cy - h + hh / PIN_H * 0.8, w, hh, c["color"], a)
        upright("OA_Map_PinDot", cx, cy - h + hh / PIN_H * 0.8, w, hh, (1, 1, 1), a)
        index += 1
    if style["me"] and circles:
        for off in (0, ME_MS / 2):
            f = fx_phase(now + off, ME_MS)
            rr = (ME_FROM + (ME_TO - ME_FROM) * fx_ease_out(f)) * s
            plane("OA_Map_Ripple", ox, oy, rr, rr, MECOL, ME_A * (1 - f) ** 1.8)
        plane("OA_Map_Shadow", ox, oy, 6 * s, 6 * s, (1, 1, 1), SHADOW_A)
        k = 1 + ME_POP * (1 - fx_phase(now, ME_MS)) ** 4
        w, hh = ME_W_SHOWN * s * k, ME_H_SHOWN * s * k
        upright("OA_Map_Me", ox, oy + hh / ME_H * 0.8, w, hh, MECOL, 1)
        upright("OA_Map_MeGlyph", ox, oy + hh / ME_H * 0.8, w, hh, (1, 1, 1), 1)


# ---- a paper map like the game's ---------------------------------------------------------------------------------

PAPER = (219, 208, 178)
FOREST = (184, 194, 154)
WATER = (147, 173, 184)
ROAD = (238, 232, 216)
ROAD_EDGE = (196, 186, 160)
BUILDING = (170, 150, 120)


def paper_map(w, h, seed=7):
    """A world map of w x h squares-as-pixels (1 pixel a square at this scale is drawn larger by the caller)."""
    rnd = random.Random(seed)
    img = Image.new("RGB", (w, h), PAPER)
    d = ImageDraw.Draw(img)
    for _ in range(14):
        cx, cy = rnd.uniform(0, w), rnd.uniform(0, h)
        rad = rnd.uniform(60, 180)
        pts = []
        for i in range(9):
            ang = 2 * math.pi * i / 9 + rnd.uniform(-0.2, 0.2)
            rr = rad * rnd.uniform(0.6, 1.1)
            pts.append((cx + math.cos(ang) * rr, cy + math.sin(ang) * rr))
        d.polygon(pts, fill=FOREST)
    river = [(w * 0.18, -10), (w * 0.2, h * 0.18), (w * 0.16, h * 0.33), (w * 0.24, h * 0.55), (w * 0.2, h * 0.75),
             (w * 0.23, h + 10)]
    d.line(river, fill=WATER, width=22, joint="curve")
    d.ellipse((w * 0.62, h * 0.06, w * 0.74, h * 0.19), fill=WATER)
    for town in ((w * 0.30, h * 0.22, 9, 7), (w * 0.52, h * 0.66, 8, 7), (w * 0.06, h * 0.40, 7, 7)):
        tx, ty, nx, ny = town
        step = 34
        for i in range(nx + 1):
            d.line([(tx + i * step, ty), (tx + i * step, ty + ny * step)], fill=ROAD_EDGE, width=5)
        for j in range(ny + 1):
            d.line([(tx, ty + j * step), (tx + nx * step, ty + j * step)], fill=ROAD_EDGE, width=5)
        for i in range(nx + 1):
            d.line([(tx + i * step, ty), (tx + i * step, ty + ny * step)], fill=ROAD, width=3)
        for j in range(ny + 1):
            d.line([(tx, ty + j * step), (tx + nx * step, ty + j * step)], fill=ROAD, width=3)
        for i in range(nx):
            for j in range(ny):
                for _ in range(rnd.randint(1, 3)):
                    bx = tx + i * step + rnd.uniform(5, step - 15)
                    by = ty + j * step + rnd.uniform(5, step - 15)
                    d.rectangle((bx, by, bx + rnd.uniform(5, 11), by + rnd.uniform(5, 11)), fill=BUILDING)
    for line in (((-10, h * 0.36), (w + 10, h * 0.38)), ((-10, h * 0.81), (w + 10, h * 0.70)),
                 ((w * 0.86, -10), (w * 0.84, h + 10)), ((w * 0.32, -10), (w * 0.26, h + 10))):
        d.line(line, fill=ROAD_EDGE, width=7)
        d.line(line, fill=ROAD, width=5)
    return img


def map_view(world, frame_w, frame_h, center, scale, iso, dark):
    """The world picture as the map shows it: centred on `center` (world pixels), `scale` screen pixels a world
    pixel, flat or isometric, darkened as the game's map brightness does."""
    if iso:
        exX, exY, eyX, eyY = 0.7071 * scale, 0.3536 * scale, -0.7071 * scale, 0.3536 * scale
    else:
        exX, exY, eyX, eyY = scale, 0.0, 0.0, scale
    det = exX * eyY - exY * eyX
    # screen (x, y) -> world: inverse of world -> screen = O + M (w - c)
    ia, ib, ic, id_ = eyY / det, -eyX / det, -exY / det, exX / det
    ox, oy = frame_w / 2, frame_h / 2
    data = (ia, ib, center[0] - ia * ox - ib * oy, ic, id_, center[1] - ic * ox - id_ * oy)
    img = world.transform((frame_w, frame_h), Image.AFFINE, data, resample=Image.BICUBIC, fillcolor=PAPER)
    if dark:
        img = Image.blend(img, Image.new("RGB", img.size, (0, 0, 0)), dark)
    return img, (exX, exY, eyX, eyY)


def mockups(out_dir):
    """The overlay as a 1080p screen shows it (the UI scale 19/16 there: the Small font 19 high), fitted as 'show on
    the map' fits it; close-ups 2x; a 4K close-up at the scale 2; the minimap; an animated PNG of the drop and bob."""
    os.makedirs(out_dir, exist_ok=True)
    world = paper_map(1400, 900)
    player = (330.0, 640.0)
    regular = {"x": 980.0, "y": 250.0, "r": 60, "color": TEAL, "dim": False}
    crates = [{"x": 455.0, "y": 600.0}, {"x": 1010.0, "y": 330.0}]
    S1080 = 19 / 16
    W, H = 1920, 1080

    def fit(circle, iso):
        """View.fit's centre and scale (screen pixels a world pixel)."""
        ax, ay = abs(circle["x"] - player[0]) / 2, abs(circle["y"] - player[1]) / 2
        hx, hy = ax + circle["r"], ay + circle["r"]
        if iso:
            hx = hy = ax + ay + circle["r"] * 1.4143
        return ((player[0] + circle["x"]) / 2, (player[1] + circle["y"]) / 2), min((W / 2 - 96) / hx, (H / 2 - 96) / hy)

    def render(size, center, scale, iso, dark, scene, style, s, now, drop_at=-10000.0):
        bg, (exX, exY, eyX, eyY) = map_view(world, size[0], size[1], center, scale, iso, dark)
        ox = size[0] / 2 + (player[0] - center[0]) * exX + (player[1] - center[1]) * eyX
        oy = size[1] / 2 + (player[0] - center[0]) * exY + (player[1] - center[1]) * eyY
        cv = Canvas(bg)
        # the game's own player dot (6 x 6, red), under the overlay
        ImageDraw.Draw(cv.img).rectangle((math.floor(ox) - 3, math.floor(oy) - 3, math.floor(ox) + 2,
                                          math.floor(oy) + 2), fill=(255, 0, 0, 255))
        draw_overlay(cv, (0, 0, size[0], size[1]), (ox, oy, exX, exY, eyX, eyY, player[0], player[1]), scene,
                     style, s, now, drop_at)
        return cv.img.convert("RGB"), (ox, oy, exX, exY, eyX, eyY)

    def save(img, name):
        img.save(os.path.join(out_dir, name), optimize=True)

    def zoom2(img, cx, cy, w, h):
        x0, y0 = int(cx - w / 2), int(cy - h / 2)
        return img.crop((x0, y0, x0 + w, y0 + h)).resize((w * 2, h * 2), Image.NEAREST)

    def at(fr, wx, wy):
        ox, oy, exX, exY, eyX, eyY = fr
        dx, dy = wx - player[0], wy - player[1]
        return ox + dx * exX + dy * eyX, oy + dx * exY + dy * eyY

    one = {"circles": [regular], "crates": crates, "lead": regular}
    center, scale = fit(regular, False)
    img, fr = render((W, H), center, scale, False, 0, one, WORLD, S1080, 700.0)
    save(img, "1-paper-1080p.png")
    dx, dy = at(fr, regular["x"], regular["y"])
    save(zoom2(img, dx, dy - 20, 420, 300), "1a-destination-x2.png")
    save(zoom2(img, fr[0] + 60, fr[1] - 30, 420, 300), "1b-player-x2.png")

    story = dict(regular, color=SKY)
    special = {"x": 560.0, "y": 180.0, "r": 45, "color": TEAL, "dim": False}
    two = {"circles": [story, special], "crates": crates, "lead": story}
    center, scale = fit(story, True)
    img, fr = render((W, H), center, scale * 1.8, True, 0.45, two, WORLD, S1080, 1500.0)
    save(img, "2-isometric-darkened-story-and-special-1080p.png")

    swap = dict(regular)
    other = {"x": 1150.0, "y": 420.0, "r": 60, "color": TEAL, "dim": True}
    center, scale = fit(regular, False)
    img, fr = render((W, H), center, scale * 0.9, False, 0, {"circles": [swap, other], "crates": [], "lead": swap},
                     WORLD, S1080, 300.0)
    save(img, "3-swap-mission-dim-second-circle-1080p.png")

    center, scale = fit(regular, False)
    img, fr = render((1100, 700), (regular["x"] - 40, regular["y"] + 40), scale * 2, False, 0, one, WORLD, 2.0,
                     900.0)
    save(img, "4-4k-closeup-scale-2.png")

    mini, _ = render((236, 236), player, 0.6, False, 0, one, MINI, S1080, 400.0)
    framed = Image.new("RGB", (252, 252), (20, 20, 20))
    framed.paste(mini, (8, 8))
    save(framed.resize((504, 504), Image.NEAREST), "5-minimap-x2.png")

    frames = []
    center, scale = fit(regular, False)
    for i in range(56):
        now = 2000.0 + i * 50
        img, fr = render((W, H), center, scale, False, 0, one, WORLD, S1080, now, drop_at=2000.0)
        dx, dy = at(fr, regular["x"], regular["y"])
        crop = img.crop((int(dx - 330), int(dy - 160), int(dx + 330), int(dy + 220)))
        frames.append(crop.quantize(colors=255, method=Image.Quantize.MEDIANCUT,
                                    dither=Image.Dither.NONE).convert("RGB"))
    frames[0].save(os.path.join(out_dir, "6-destination-animated.png"), save_all=True, append_images=frames[1:],
                   duration=50, loop=0, optimize=True)
    sheet = Image.new("RGB", (660 * 2, 380 * 2))
    for k, idx in enumerate((2, 5, 9, 30)):
        sheet.paste(frames[idx], ((k % 2) * 660, (k // 2) * 380))
    save(sheet, "7-drop-frames.png")

    frames = []
    for i in range(44):
        now = 5000.0 + i * 50
        img, fr = render((W, H), center, scale, False, 0, one, WORLD, S1080, now)
        frames.append(img.crop((int(fr[0] - 200), int(fr[1] - 170), int(fr[0] + 300), int(fr[1] + 80))))
    frames[0].save(os.path.join(out_dir, "8-player-animated.png"), save_all=True, append_images=frames[1:],
                   duration=50, loop=0, optimize=True)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, make in PICTURES.items():
        img = make()
        img.save(os.path.join(OUT_DIR, name + ".png"), optimize=True)
        print(name, img.size, os.path.getsize(os.path.join(OUT_DIR, name + ".png")), "bytes")
    if "--mockup" in sys.argv:
        out = sys.argv[sys.argv.index("--mockup") + 1]
        mockups(out)
        print("mockups in", out)


if __name__ == "__main__":
    main()
