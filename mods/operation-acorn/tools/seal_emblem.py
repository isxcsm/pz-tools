"""The operation's emblem for its seal title (PZExtAPI text, style "seal", spec.emblem): an acorn in a ring, white on clear
(the API draws it in the title's colour), the title lab's acorn() (extension-api/tools/title-lab/title-lab.html) to its
shapes: its cap (the scales cut out of it) over its nut (a stripe of light cut down its side), a stem on top, in a ring.

    python -X utf8 seal_emblem.py [out.png]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

SIDE = 256
OVER = 4
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'OperationAcorn', '42', 'media', 'textures', 'OA_SealEmblem.png')
# The ring's width over the emblem's side: the lab's iw * 1.4 (0.03 of a line) over E (1.1 lines).
RING = 0.03 * 1.4 / 1.1


def cubic(p0, p1, p2, p3, n=48):
    t = np.linspace(0, 1, n)[:, None]
    return ((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3).tolist()


def quad(p0, p1, p2, n=32):
    t = np.linspace(0, 1, n)[:, None]
    return ((1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t ** 2 * p2).tolist()


def half_ellipse(cx, cy, rx, ry, n=64):
    # canvas's ellipse from pi to 2 pi: over the top (y down)
    a = np.linspace(np.pi, 2 * np.pi, n)
    return [(cx + rx * np.cos(v), cy + ry * np.sin(v)) for v in a]


def mask(draw_fn, size):
    m = Image.new('L', (size, size), 0)
    draw_fn(ImageDraw.Draw(m))
    return np.asarray(m, dtype=np.float32) / 255


def emblem(side=SIDE):
    size = side * OVER
    E = float(size)
    x, y = E / 2, E / 2

    def P(u, v):
        return (x + u * E, y + v * E)

    def poly(points):
        return [(px, py) for px, py in points]

    def line(d, a, b, width, round_cap=False):
        d.line([a, b], fill=255, width=max(1, int(round(width))))
        if round_cap:
            for c in (a, b):
                r = width / 2
                d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=255)

    ring = RING * E
    cy = -0.06
    nut = cubic(np.array(P(-0.2, cy + 0.02)), np.array(P(-0.21, cy + 0.2)), np.array(P(-0.07, cy + 0.33)), np.array(P(0, cy + 0.37))) \
        + cubic(np.array(P(0, cy + 0.37)), np.array(P(0.07, cy + 0.33)), np.array(P(0.21, cy + 0.2)), np.array(P(0.2, cy + 0.02)))
    cap = half_ellipse(*P(0, cy), 0.26 * E, 0.15 * E) + [P(0.26, cy + 0.035), P(-0.26, cy + 0.035)]
    dome = half_ellipse(*P(0, cy), 0.26 * E, 0.15 * E)

    def solid(d):
        r = E / 2 - ring / 2
        d.ellipse([x - r - ring / 2, y - r - ring / 2, x + r + ring / 2, y + r + ring / 2], outline=255, width=int(round(ring)))
        d.polygon(poly(nut), fill=255)
        d.polygon(poly(cap), fill=255)
        d.rectangle([*P(-0.022, cy - 0.25), *P(0.022, cy - 0.14)], fill=255)

    def band(d):
        line(d, P(-0.27, cy + 0.06), P(0.27, cy + 0.06), 0.028 * E)

    def scales(d):
        for k in range(-5, 6):
            line(d, P(k * 0.07 - 0.2, cy + 0.05), P(k * 0.07 + 0.1, cy - 0.2), 0.018 * E)
            line(d, P(k * 0.07 + 0.2, cy + 0.05), P(k * 0.07 - 0.1, cy - 0.2), 0.018 * E)

    def clip(d):
        d.polygon(poly(dome), fill=255)

    def light(d):
        pts = quad(np.array(P(-0.11, cy + 0.11)), np.array(P(-0.13, cy + 0.22)), np.array(P(-0.06, cy + 0.29)))
        w = 0.03 * E
        for a, b in zip(pts, pts[1:]):
            line(d, tuple(a), tuple(b), w, round_cap=True)

    alpha = mask(solid, size)
    cut = np.maximum(mask(band, size), mask(scales, size) * mask(clip, size))
    cut = np.maximum(cut, mask(light, size))
    alpha = np.clip(alpha - cut, 0, 1)
    big = Image.fromarray((alpha * 255).astype(np.uint8), 'L')
    small = big.resize((side, side), Image.BOX)
    out = Image.new('RGBA', (side, side), (255, 255, 255, 0))
    out.putalpha(small)
    return out


if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else OUT
    emblem().save(path)
    print(path)
