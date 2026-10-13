#!/usr/bin/env python3
"""The film grain over the research tab's tree columns (Upgrades/Window.lua, the columns' background): one small
tile of soft white specks that the game draws tiled at its own pixels, at a very low alpha, over each column.

    py tools/grain_art.py      writes OperationAcorn/42/media/textures/OA_Grain.png (128 px, white, its alpha the
                               specks)

Seeded, so the same file comes out every time. The tile wraps (its blur is taken around the edges), so the seam does
not show when it is tiled. Its alpha is kept to a few levels: at the strength it is drawn at nothing finer shows, and
the file stays small.
"""
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
TEXTURES = os.path.join(ROOT, 'OperationAcorn', '42', 'media', 'textures')
SIZE = 128
LEVELS = 8


def grain(n=SIZE, seed=4242):
    rng = np.random.default_rng(seed)
    g = rng.normal(0, 1, (n, n)).astype(np.float32)
    blur = g * 4
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        blur += np.roll(np.roll(g, dy, 0), dx, 1)
    blur /= 8
    blur = (blur - blur.min()) / (blur.max() - blur.min())
    a = np.clip((blur - 0.35) / 0.65, 0, 1) ** 1.5
    a = np.round(a * (LEVELS - 1)) / (LEVELS - 1)
    out = np.zeros((n, n, 4), np.uint8)
    out[..., :3] = 255
    out[..., 3] = (a * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def main():
    path = os.path.join(TEXTURES, 'OA_Grain.png')
    grain().save(path, optimize=True)
    print('wrote', os.path.relpath(path, ROOT), os.path.getsize(path), 'bytes')


if __name__ == '__main__':
    main()
