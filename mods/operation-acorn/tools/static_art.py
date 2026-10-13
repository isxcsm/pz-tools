#!/usr/bin/env python3
"""The crude terminal's static (Trade/TerminalStatic.lua): two 256x256 tiles of white specks and short streaks on a clear
background, tinted and laid very faintly over the window's body by the game, the two swapped as it scrolls.

    py tools/static_art.py        writes OperationAcorn/42/media/textures/OA_Static_1.png and OA_Static_2.png

Seeded, so the same files come out every time. The tiles wrap (specks and streaks are placed modulo the size), so the
seam does not show when they are tiled.
"""
import os
import random

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TEXTURES = os.path.join(HERE, '..', 'OperationAcorn', '42', 'media', 'textures')
SIZE = 256


def tile(seed):
    rnd = random.Random(seed)
    img = Image.new('RGBA', (SIZE, SIZE), (255, 255, 255, 0))
    px = img.load()
    # specks: most faint, a few bright
    for _ in range(SIZE * SIZE // 9):
        x, y = rnd.randrange(SIZE), rnd.randrange(SIZE)
        a = int(rnd.random() ** 2.2 * 255)
        px[x, y] = (255, 255, 255, max(px[x, y][3], a))
    # short horizontal streaks, the static's grain
    for _ in range(70):
        x, y, n = rnd.randrange(SIZE), rnd.randrange(SIZE), rnd.randint(4, 22)
        a = rnd.randint(60, 170)
        for i in range(n):
            xx = (x + i) % SIZE
            px[xx, y] = (255, 255, 255, max(px[xx, y][3], int(a * (1 - abs(i / n - 0.5)))))
    return img


def main():
    for i, seed in ((1, 4101), (2, 7723)):
        path = os.path.join(TEXTURES, 'OA_Static_%d.png' % i)
        tile(seed).save(path)
        print('wrote', os.path.relpath(path, os.path.join(HERE, '..')))


if __name__ == '__main__':
    main()
