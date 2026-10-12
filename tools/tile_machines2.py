"""The installable lure (a 1x1 object; the big machines are in tile_big1/2/3.py)."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import Scene, shadow, compose, rotation, stencil_text, acorn_mark, project, SS, W, H
from tile_objects import (OD, OD_DARK, OD_LIGHT, BLACK, RUBBER, STEEL, STEEL_DARK, STENCIL, RED, BRASS, BLUE, LIT, UNLIT,
                          BEZEL, lamp_y, front_decal, side_decal, flat_decal)
from tile_machines import (GRAPHITE, GRAPHITE_DARK, ring_top, disc)

def lure(on):
    """The installable lure: a field loudspeaker on a tripod, two big horns back to back up on its mast with a beacon
    over them, a battery box with its lamp, a whip antenna and a cable reel at its foot. On: the lamp and the beacon are
    lit (the sound rings that spread out from the horns are an animation drawn over it: lure_rings)."""
    s = Scene(0)
    glows = []
    cx, cy = 0.5, 0.5
    for ang in (90, 210, 330):
        a = math.radians(ang)
        s.tube((cx + 0.28 * math.cos(a), cy + 0.28 * math.sin(a), 0.0), (cx, cy, 0.5), 0.016, STEEL_DARK, segments=8,
               shine=0.4)
        s.box(cx + 0.28 * math.cos(a) - 0.03, cy + 0.28 * math.sin(a) - 0.03, 0.0, cx + 0.28 * math.cos(a) + 0.03,
              cy + 0.28 * math.sin(a) + 0.03, 0.015, RUBBER)
    s.tube((cx, cy, 0.45), (cx, cy, 0.6), 0.036, GRAPHITE_DARK, segments=14, shine=0.3)
    s.tube((cx, cy, 0.6), (cx, cy, 0.95), 0.018, GRAPHITE, segments=10, shine=0.4)
    # the clamp ring on the mast and its wing screw
    s.tube((cx, cy, 0.7), (cx, cy, 0.74), 0.03, STEEL, segments=12, shine=0.6)
    s.tube((cx, cy, 0.72), (cx + 0.06, cy, 0.72), 0.008, STEEL, segments=6)
    s.box(cx - 0.065, cy - 0.065, 0.84, cx + 0.065, cy + 0.065, 0.93, OD, top=OD_LIGHT, shine=0.1)
    # the horns point across the view (to the screen's left and right), so both read as horns from the side
    for (ax, ay) in ((0.13, -0.13), (-0.13, 0.13)):
        s.tube((cx, cy, 0.885), (cx + ax * 0.5, cy + ay * 0.5, 0.885), 0.03, GRAPHITE, segments=10)
        s.tube((cx + ax * 0.5, cy + ay * 0.5, 0.885), (cx + ax * 1.7, cy + ay * 1.7, 0.95), 0.04, GRAPHITE, r2=0.15,
               cap=(20, 22, 24), segments=28, shine=0.35)
        s.tube((cx + ax * 1.68, cy + ay * 1.68, 0.948), (cx + ax * 1.72, cy + ay * 1.72, 0.952), 0.155, OD_DARK,
               segments=28, shine=0.3, caps=False)
    s.tube((cx, cy, 0.92), (cx, cy, 1.1), 0.008, STEEL, r2=0.004, segments=6, shine=0.5)
    s.tube((cx, cy, 0.92), (cx, cy, 0.95), 0.03, BEZEL, segments=14)
    if on:
        s.tube((cx, cy, 0.95), (cx, cy, 1.0), 0.026, LIT['amber'], cap=(255, 240, 200), segments=14, emit=True)
        glows.append(((cx, cy, 0.98), LIT['amber'], 0.2))
    else:
        s.tube((cx, cy, 0.95), (cx, cy, 1.0), 0.026, UNLIT['amber'], segments=14, shine=0.8)
    s.box(0.56, 0.6, 0.0, 0.88, 0.82, 0.22, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.555, 0.595, 0.18, 0.885, 0.825, 0.2, OD_DARK)
    s.tube((0.6, 0.71, 0.22), (0.84, 0.71, 0.22), 0.012, GRAPHITE_DARK, segments=6)
    front_decal(s, 0.6, 0.8, 0.05, 0.14, 0.821, stencil_text('LURE', 40, 12, STENCIL), offset=0.0)
    lamp_y(s, glows, 0.84, 0.82, 0.12, 0.016, 'green', on)
    s.tube((0.62, 0.64, 0.22), (0.62, 0.64, 0.28), 0.012, BLACK, segments=6)
    s.tube((0.62, 0.64, 0.28), (cx + 0.02, cy + 0.02, 0.52), 0.007, BLACK, segments=5)
    s.tube((0.82, 0.66, 0.22), (0.82, 0.66, 0.62), 0.006, STEEL, r2=0.003, segments=6, shine=0.5)
    # the cable reel by the box
    s.tube((0.2, 0.74, 0.12), (0.34, 0.74, 0.12), 0.1, (196, 110, 30), cap=(60, 60, 62), segments=20, shine=0.3)
    for x in (0.19, 0.35):
        s.tube((x, 0.74, 0.12), (x + 0.01, 0.74, 0.12), 0.12, GRAPHITE_DARK, cap=GRAPHITE, segments=20)
    ground = shadow((0.5, 0.55), 0.36, 0.32, 105)
    return compose(s, ground=ground, seed=180 + (1 if on else 0), glows=glows)


# The speaker head the sound rings spread from.
LURE_HEAD = (0.5, 0.5, 0.9)
LURE_FX_FRAMES = 6


def lure_rings(frame, frames=LURE_FX_FRAMES):
    """One frame of the working lure's sound rings, drawn over its tile (a looping animation the game plays on the
    object): three rings to each side of the speaker head, each born at the head, spreading out and fading, a third
    of the loop apart."""
    big = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big, 'RGBA')
    px, py = project(*LURE_HEAD)
    for k in range(3):
        t = (frame / frames + k / 3) % 1.0
        rr = 14 + 30 * t
        fade = (1 - t) ** 1.2
        box = [px - rr * SS, py - rr * SS * 0.75, px + rr * SS, py + rr * SS * 0.75]
        d.arc(box, -40, 40, fill=(255, 220, 140, int(235 * fade)), width=int(2.4 * SS))
        d.arc(box, 140, 220, fill=(255, 220, 140, int(200 * fade)), width=int(2.4 * SS))
    return big.convert('RGBa').resize((W, H), Image.LANCZOS).convert('RGBA')
