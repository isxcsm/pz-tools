"""Shared parts of the machine drawings (the big machines are in tile_big1/2/3.py): colours, gauges, valve wheels, the
pegboard and the cutting mat. The 1x1 versions of the machines are gone: the big machines are multi-tile now."""
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from tile_engine import (Scene, shadow, compose, unit, rotation, apply, add, sub, mul, stencil_text, acorn_mark,
                         IDENTITY, project, SS, W, H, UP, font)
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, LIT, UNLIT, BEZEL, lamp, lamp_y, lamp_x,
                          knob_y, stick, flat_decal, front_decal, side_decal, noise_texture, face_frame)
from tile_trade import hazard_strip, plank_lines

GRAPHITE = (74, 78, 82)
GRAPHITE_DARK = (52, 55, 58)
GRAPHITE_LIGHT = (104, 108, 112)
CREAM = (164, 160, 144)
CREAM_DARK = (128, 124, 112)
STEAM = (236, 238, 240)
FLAME = (255, 168, 40)


def double_poly(s, pts, outside, inside, outward, shine=0.0):
    """A thin wall drawn from both sides: the near side in one colour, the inside seen across a vessel in another."""
    s.poly(pts, outside, outward, shine)
    s.poly(pts, inside, mul(outward, -1), shine)


def ring_top(s, centre, r0, r1, z, colour, segments=40, shine=0.0):
    """A flat ring (a rim) facing up between two radii."""
    cx, cy = centre
    for i in range(segments):
        a0, a1 = 2 * math.pi * i / segments, 2 * math.pi * (i + 1) / segments
        pts = [(cx + r1 * math.cos(a0), cy + r1 * math.sin(a0), z), (cx + r1 * math.cos(a1), cy + r1 * math.sin(a1), z),
               (cx + r0 * math.cos(a1), cy + r0 * math.sin(a1), z), (cx + r0 * math.cos(a0), cy + r0 * math.sin(a0), z)]
        s.face(pts, colour, (0, 0, 1), shine)


def disc(s, centre, r, z, colour, segments=40, shine=0.0, emit=False):
    cx, cy = centre
    s.face([(cx + r * math.cos(2 * math.pi * i / segments), cy + r * math.sin(2 * math.pi * i / segments), z)
            for i in range(segments)], colour, (0, 0, 1), shine, emit)


def gauge_image(value, size=40, dark=False):
    """A round pressure gauge: a white dial with a scale, a red zone, the needle at value 0..1."""
    scale = 4
    s = size * scale
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, s - 1, s - 1], fill=(40, 42, 44, 255))
    d.ellipse([s * 0.07, s * 0.07, s * 0.93, s * 0.93], fill=(226, 224, 210, 255))
    for i in range(11):
        a = math.radians(225 - i * 27)
        r0, r1 = s * 0.30, s * 0.42
        c, sn = math.cos(a), -math.sin(a)
        col = (180, 40, 30, 255) if i >= 8 else (40, 40, 40, 255)
        d.line([(s / 2 + c * r0, s / 2 + sn * r0), (s / 2 + c * r1, s / 2 + sn * r1)], fill=col, width=scale)
    a = math.radians(225 - value * 270)
    d.line([(s / 2, s / 2), (s / 2 + math.cos(a) * s * 0.38, s / 2 - math.sin(a) * s * 0.38)], fill=(20, 20, 20, 255), width=int(scale * 1.6))
    d.ellipse([s * 0.45, s * 0.45, s * 0.55, s * 0.55], fill=(30, 30, 30, 255))
    return img.resize((size, size), Image.LANCZOS)


def valve_wheel(s, centre, r, colour=RED, axis='x'):
    """A hand wheel standing on an axis: a rim of tube, spokes."""
    x, y, z = centre
    if axis == 'x':
        a, b = (x - 0.006, y, z), (x + 0.006, y, z)
        s.tube(a, b, r, colour, cap=colour, segments=20)
        s.tube(a, b, r * 0.78, colour, segments=20, inward=True)
        for ang in (0, 60, 120):
            c, sn = math.cos(math.radians(ang)) * r, math.sin(math.radians(ang)) * r
            s.tube((x, y - c, z - sn), (x, y + c, z + sn), 0.004, colour, segments=5)
    else:
        a, b = (x, y - 0.006, z), (x, y + 0.006, z)
        s.tube(a, b, r, colour, cap=colour, segments=20)
        for ang in (0, 60, 120):
            c, sn = math.cos(math.radians(ang)) * r, math.sin(math.radians(ang)) * r
            s.tube((x - c, y, z - sn), (x + c, y, z + sn), 0.004, colour, segments=5)


# ----------------------------------------------------------------------------------------------------------------

def pegboard_image(w=128, h=56):
    img = Image.new('RGBA', (w, h), (76, 80, 70, 255))
    d = ImageDraw.Draw(img)
    for x in range(3, w, 6):
        for y in range(3, h, 6):
            d.ellipse([x - 1, y - 1, x, y], fill=(40, 42, 38, 255))
    steel, handle = (190, 194, 198, 255), (150, 100, 56, 255)
    # a hammer
    d.rectangle([10, 12, 13, 44], fill=handle)
    d.rectangle([4, 8, 20, 15], fill=steel)
    # a big wrench
    d.rectangle([30, 14, 34, 46], fill=steel)
    d.ellipse([27, 6, 38, 18], fill=steel)
    d.rectangle([31, 6, 34, 12], fill=(76, 80, 70, 255))
    # pliers
    d.polygon([(48, 10), (53, 10), (56, 28), (50, 28)], fill=(196, 50, 40, 255))
    d.polygon([(58, 10), (63, 10), (60, 28), (54, 28)], fill=(196, 50, 40, 255))
    d.polygon([(50, 28), (56, 28), (55, 40), (51, 40)], fill=steel)
    d.polygon([(54, 28), (60, 28), (59, 40), (56, 40)], fill=steel)
    # a saw
    d.polygon([(70, 12), (100, 12), (100, 32), (70, 32)], fill=steel)
    for x in range(70, 100, 3):
        d.polygon([(x, 32), (x + 1.5, 36), (x + 3, 32)], fill=steel)
    d.rectangle([100, 14, 108, 30], fill=handle)
    # screwdrivers
    for i, x in enumerate((114, 119, 124)):
        d.rectangle([x, 22, x + 2, 36], fill=steel)
        d.rectangle([x - 1, 8, x + 3, 22], fill=(224, 170, 40, 255) if i != 1 else (196, 50, 40, 255))
    return img


def cutting_mat_image(w=176, h=84):
    # a worn, dull green (a bright mat stood out of the game's muted colours)
    img = Image.new('RGBA', (w, h), (48, 76, 62, 255))
    d = ImageDraw.Draw(img)
    for x in range(0, w, 8):
        d.line([(x, 0), (x, h)], fill=(118, 136, 122, 255) if x % 40 == 0 else (62, 92, 76, 255), width=1)
    for y in range(0, h, 8):
        d.line([(0, y), (w, y)], fill=(118, 136, 122, 255) if y % 40 == 0 else (62, 92, 76, 255), width=1)
    d.rectangle([0, 0, w - 1, h - 1], outline=(30, 60, 44, 255))
    return img
