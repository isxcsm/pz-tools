"""The installable lure (a 1x1 object; the big machines are in tile_big1/2/3.py)."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import Scene, shadow, compose, rotation, stencil_text, acorn_mark, project, SS
from tile_objects import (OD, OD_DARK, OD_LIGHT, BLACK, RUBBER, STEEL, STEEL_DARK, STENCIL, RED, BRASS, BLUE, LIT, UNLIT,
                          BEZEL, lamp_y, front_decal, side_decal, flat_decal)
from tile_machines import (GRAPHITE, GRAPHITE_DARK, ring_top, disc)

def lure(on):
    """The installable lure: a field loudspeaker on a short tripod, two horns up on its mast, a battery box with a
    lamp at its foot and an antenna. On: the lamp and the beacon are lit and sound rings spread out from the horns."""
    s = Scene(0)
    glows = []
    cx, cy = 0.5, 0.5
    for ang in (90, 210, 330):
        a = math.radians(ang)
        s.tube((cx + 0.2 * math.cos(a), cy + 0.2 * math.sin(a), 0.0), (cx, cy, 0.5), 0.012, STEEL_DARK, segments=8,
               shine=0.4)
        s.box(cx + 0.2 * math.cos(a) - 0.025, cy + 0.2 * math.sin(a) - 0.025, 0.0, cx + 0.2 * math.cos(a) + 0.025,
              cy + 0.2 * math.sin(a) + 0.025, 0.012, RUBBER)
    s.tube((cx, cy, 0.45), (cx, cy, 0.58), 0.03, GRAPHITE_DARK, segments=14, shine=0.3)
    s.tube((cx, cy, 0.58), (cx, cy, 0.95), 0.014, GRAPHITE, segments=10, shine=0.4)
    s.box(cx - 0.05, cy - 0.05, 0.86, cx + 0.05, cy + 0.05, 0.92, OD, top=OD_LIGHT, shine=0.1)
    for (ax, ay) in ((0.12, 0.10), (-0.12, -0.10)):
        s.tube((cx, cy, 0.89), (cx + ax * 0.6, cy + ay * 0.6, 0.89), 0.02, GRAPHITE, segments=8)
        s.tube((cx + ax * 0.6, cy + ay * 0.6, 0.89), (cx + ax * 1.3, cy + ay * 1.3, 0.97), 0.03, GRAPHITE, r2=0.10,
               cap=(20, 22, 24), segments=24, shine=0.35)
    s.tube((cx, cy, 0.92), (cx, cy, 1.1), 0.008, STEEL, r2=0.004, segments=6, shine=0.5)
    s.tube((cx, cy, 0.92), (cx, cy, 0.95), 0.03, BEZEL, segments=14)
    if on:
        s.tube((cx, cy, 0.95), (cx, cy, 1.0), 0.026, LIT['amber'], cap=(255, 240, 200), segments=14, emit=True)
        glows.append(((cx, cy, 0.98), LIT['amber'], 0.2))
    else:
        s.tube((cx, cy, 0.95), (cx, cy, 1.0), 0.026, UNLIT['amber'], segments=14, shine=0.8)
    s.box(0.58, 0.58, 0.0, 0.82, 0.74, 0.17, OD, top=OD_LIGHT, shine=0.1)
    front_decal(s, 0.60, 0.80, 0.04, 0.12, 0.741, stencil_text('LURE', 40, 12, STENCIL), offset=0.0)
    lamp_y(s, glows, 0.72, 0.74, 0.13, 0.013, 'green', on)
    s.tube((0.62, 0.62, 0.17), (0.62, 0.62, 0.24), 0.012, BLACK, segments=6)
    s.tube((0.62, 0.62, 0.24), (cx + 0.02, cy + 0.02, 0.5), 0.006, BLACK, segments=5)
    s.tube((0.76, 0.62, 0.17), (0.76, 0.62, 0.34), 0.008, STEEL, segments=6)

    def rings(img):
        d = ImageDraw.Draw(img, 'RGBA')
        for (hx, hy, hz) in ((cx + 0.15, cy + 0.12, 0.97), (cx - 0.15, cy - 0.12, 0.97)):
            px, py = project(hx, hy, hz)
            for i, rr in enumerate((16, 26, 36)):
                d.arc([px - rr * SS, py - rr * SS * 0.7, px + rr * SS, py + rr * SS * 0.7], -50, 50,
                      fill=(255, 220, 140, 220 - i * 55), width=int(2.4 * SS))
                d.arc([px - rr * SS, py - rr * SS * 0.7, px + rr * SS, py + rr * SS * 0.7], 130, 230,
                      fill=(255, 220, 140, 150 - i * 40), width=int(2.0 * SS))
    ground = shadow((0.5, 0.5), 0.3, 0.26, 105)
    return compose(s, ground=ground, over=rings if on else None, seed=180 + (1 if on else 0), glows=glows)
