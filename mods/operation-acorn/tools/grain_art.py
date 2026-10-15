#!/usr/bin/env python3
"""The research tab's grit (Upgrades/Window.lua): the textures that make its columns read as a worn field document
rather than a clean panel.

    py tools/grain_art.py      writes into OperationAcorn/42/media/textures:
        OA_Grain.png        128 px, white, its alpha soft specks: the film grain, tiled at its own pixels at a low
                            alpha over each column
        OA_Grime.png        256 px, black, its alpha uneven stains, a few dark specks and hairline scratches: the wear
                            of the print, tiled the same way under the grain
    (A node's burst of static reuses the terminals' tiles, tools/static_art.py.)

Seeded, so the same files come out every time. The tiles wrap (blurs are taken around the edges), so their seams do
not show when tiled. Alphas are kept to a few levels: at the strengths they are drawn at nothing finer shows, and the
files stay small.
"""
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
TEXTURES = os.path.join(ROOT, 'OperationAcorn', '42', 'media', 'textures')
SIZE = 128
LEVELS = 8


def rgba(alpha, white):
    n = alpha.shape[0]
    out = np.zeros((n, n, 4), np.uint8)
    out[..., :3] = 255 if white else 0
    out[..., 3] = (np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def levels(a, k=LEVELS):
    return np.round(np.clip(a, 0, 1) * (k - 1)) / (k - 1)


def wrap_blur(g, passes):
    for _ in range(passes):
        b = g * 4
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            b = b + np.roll(np.roll(g, dy, 0), dx, 1)
        g = b / 8
    return g


def norm(a):
    return (a - a.min()) / (a.max() - a.min())


def grain(n=SIZE, seed=4242):
    rng = np.random.default_rng(seed)
    blur = norm(wrap_blur(rng.normal(0, 1, (n, n)).astype(np.float32), 1))
    a = np.clip((blur - 0.35) / 0.65, 0, 1) ** 1.5
    return rgba(levels(a), True)


def grime(n=256, seed=1993):
    rng = np.random.default_rng(seed)
    # stains: noise at a few scales, blurred hard, only the darker half kept so it reads as blotches, not a fog
    big = norm(wrap_blur(rng.normal(0, 1, (n, n)).astype(np.float32), 40))
    mid = norm(wrap_blur(rng.normal(0, 1, (n, n)).astype(np.float32), 10))
    stain = np.clip((0.62 * big + 0.38 * mid - 0.45) / 0.55, 0, 1) ** 1.3 * 0.55
    # specks: a few dark dots of a pixel or two
    specks = np.zeros((n, n), np.float32)
    for _ in range(140):
        y, x = rng.integers(0, n, 2)
        r = 1 if rng.random() < 0.8 else 2
        specks[y:y + r, x:x + r] = rng.uniform(0.5, 1.0)
    # scratches: thin near-vertical and near-horizontal hairlines that fade along their length
    scratch = np.zeros((n, n), np.float32)
    for _ in range(7):
        vertical = rng.random() < 0.6
        length = int(rng.integers(40, 160))
        x0, y0 = rng.integers(0, n, 2)
        drift = rng.uniform(-0.15, 0.15)
        strength = rng.uniform(0.35, 0.7)
        for k in range(length):
            fade = np.sin(np.pi * k / length)
            if vertical:
                y, x = (y0 + k) % n, int(x0 + drift * k) % n
            else:
                y, x = int(y0 + drift * k) % n, (x0 + k) % n
            scratch[y, x] = max(scratch[y, x], strength * fade)
    a = np.maximum(np.maximum(stain, specks), scratch)
    return rgba(levels(a, 12), False)


def save(image, name):
    path = os.path.join(TEXTURES, name)
    image.save(path, optimize=True)
    print('wrote', os.path.relpath(path, ROOT), os.path.getsize(path), 'bytes')


def main():
    save(grain(), 'OA_Grain.png')
    save(grime(), 'OA_Grime.png')


if __name__ == '__main__':
    main()
