"""The objects of tools/tile_art.py: each a function that draws one look of one tile (turns: the quarter turns of the
object about the tile's middle, 0 = its front to the south). See tile_engine.py for the drawing.

The team (참나무, 'oak') is a military research unit: olive drab steel and canvas, stencilled lettering, an acorn mark,
a field radio and a rugged case. Lamps are green for on/running, amber for working/waiting, red for sealed/alarm.
"""
import math
import random

import numpy as np
from PIL import Image, ImageDraw

from tile_engine import (Scene, shadow, compose, unit, rotation, apply, add, sub, mul, stencil_text, acorn_mark, font,
                         IDENTITY, project, SS, W, H, UP)

# Colours: olive drab (the team's paint), steel, rubber, canvas.
OD = (104, 114, 78)
OD_DARK = (74, 82, 56)
OD_LIGHT = (130, 140, 98)
TAN = (178, 160, 116)
CANVAS = (150, 140, 104)
BLACK = (40, 42, 44)
RUBBER = (34, 34, 36)
GREY = (122, 126, 128)
STEEL = (170, 174, 178)
STEEL_DARK = (110, 114, 118)
PIPE = (84, 88, 92)
WHITE = (226, 224, 210)
STENCIL = (222, 218, 190)
YELLOW = (224, 182, 44)
RED = (178, 50, 40)
BRASS = (200, 158, 70)
WOOD = (150, 116, 74)
WOOD_DARK = (112, 84, 52)
BLUE = (52, 104, 168)
# Lamps: their lens lit, and the dark glass of an unlit one.
LIT = {'green': (80, 255, 120), 'amber': (255, 150, 30), 'red': (255, 60, 44)}
UNLIT = {'green': (36, 74, 46), 'amber': (96, 60, 24), 'red': (92, 32, 28)}
BEZEL = (54, 56, 58)


def lamp(s, glows, x, y, z, r, colour, lit):
    """A small round signal lamp on a surface at height z: a black bezel and a domed lens, lit or dark."""
    s.tube((x, y, z), (x, y, z + 0.012), r * 1.35, BEZEL, shine=0.3, segments=24)
    if lit:
        rim, top = LIT[colour], tuple(int(c + (255 - c) * 0.3) for c in LIT[colour])
        s.tube((x, y, z + 0.012), (x, y, z + 0.012 + r * 0.7), r, rim, cap=top, segments=24, emit=True)
        s.tube((x, y, z + 0.012 + r * 0.7), (x, y, z + 0.012 + r * 1.05), r * 0.62, top, cap=(255, 255, 240),
               segments=24, emit=True)
        glows.append(((x, y, z + 0.012 + r), LIT[colour], 0.09 + r))
    else:
        glass = UNLIT[colour]
        s.tube((x, y, z + 0.012), (x, y, z + 0.012 + r * 0.7), r, glass, shine=0.9, segments=24)
        s.tube((x, y, z + 0.012 + r * 0.7), (x, y, z + 0.012 + r * 1.05), r * 0.62, glass, shine=0.9, segments=24)


def lamp_y(s, glows, x, y, z, r, colour, lit):
    """The same lamp on a face looking along +y (a front panel): at (x, y, z), standing out toward +y."""
    s.tube((x, y, z), (x, y + 0.01, z), r * 1.35, BEZEL, shine=0.3, segments=24)
    if lit:
        rim = LIT[colour]
        s.tube((x, y + 0.01, z), (x, y + 0.01 + r * 0.8, z), r, rim, cap=(255, 255, 240), segments=24, emit=True)
        glows.append(((x, y + 0.01 + r * 0.8, z), LIT[colour], 0.08 + r, (0, 1, 0)))
    else:
        s.tube((x, y + 0.01, z), (x, y + 0.01 + r * 0.8, z), r, UNLIT[colour], shine=0.9, segments=24)


def lamp_x(s, glows, x, y, z, r, colour, lit):
    """A lamp on a face looking along +x."""
    s.tube((x, y, z), (x + 0.01, y, z), r * 1.35, BEZEL, shine=0.3, segments=24)
    if lit:
        s.tube((x + 0.01, y, z), (x + 0.01 + r * 0.8, y, z), r, LIT[colour], cap=(255, 255, 240), segments=24,
               emit=True)
        glows.append(((x + 0.01 + r * 0.8, y, z), LIT[colour], 0.08 + r, (1, 0, 0)))
    else:
        s.tube((x + 0.01, y, z), (x + 0.01 + r * 0.8, y, z), r, UNLIT[colour], shine=0.9, segments=24)


def knob_y(s, x, y, z, r, colour=BLACK, length=0.03):
    s.tube((x, y, z), (x, y + length, z), r, colour, cap=tuple(min(255, c + 24) for c in colour), shine=0.4,
           segments=20)
    s.tube((x, y + length, z), (x, y + length + 0.004, z), r * 0.3, STEEL, segments=8)


def face_frame(centre, rot, size, face, margin=0.0):
    """Origin, u, v of a decal on a face of an xbox: face is one of '+y', '-y', '+x', '-x', '+z'."""
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    if face == '+y':
        o, u, v = (-hx + margin, hy, hz - margin), (2 * hx - 2 * margin, 0, 0), (0, 0, -(2 * hz - 2 * margin))
    elif face == '-y':
        o, u, v = (hx - margin, -hy, hz - margin), (-(2 * hx - 2 * margin), 0, 0), (0, 0, -(2 * hz - 2 * margin))
    elif face == '+x':
        o, u, v = (hx, hy - margin, hz - margin), (0, -(2 * hy - 2 * margin), 0), (0, 0, -(2 * hz - 2 * margin))
    elif face == '-x':
        o, u, v = (-hx, -hy + margin, hz - margin), (0, 2 * hy - 2 * margin, 0), (0, 0, -(2 * hz - 2 * margin))
    else:  # +z, seen from above: the image's top is toward -y
        o, u, v = (-hx + margin, -hy + margin, hz), (2 * hx - 2 * margin, 0, 0), (0, 2 * hy - 2 * margin, 0)
    return add(centre, apply(rot, o)), apply(rot, u), apply(rot, v)


def stick(s, centre, rot, size, face, image, emit=False, margin=0.0, offset=0.004):
    o, u, v = face_frame(centre, rot, size, face, margin)
    outward = {'+y': (0, 1, 0), '-y': (0, -1, 0), '+x': (1, 0, 0), '-x': (-1, 0, 0), '+z': (0, 0, 1)}[face]
    s.decal(o, u, v, image, apply(rot, outward), offset, emit)


def flat_decal(s, x0, y0, x1, y1, z, image, emit=False, offset=0.003):
    """An image lying on a horizontal surface at height z, its top toward -y (north), spanning the rectangle."""
    s.decal((x0, y0, z), (x1 - x0, 0, 0), (0, y1 - y0, 0), image, (0, 0, 1), offset, emit)


def front_decal(s, x0, x1, z0, z1, y, image, emit=False, offset=0.003):
    """An image on a face looking south (+y) at depth y, spanning x0..x1 and z0..z1 (z1 the top)."""
    s.decal((x0, y, z1), (x1 - x0, 0, 0), (0, 0, -(z1 - z0)), image, (0, 1, 0), offset, emit)


def side_decal(s, y0, y1, z0, z1, x, image, emit=False, offset=0.003):
    """An image on a face looking east (+x) at x, spanning y0..y1 (left to right on screen: y1 to y0) and z0..z1."""
    s.decal((x, y1, z1), (0, y0 - y1, 0), (0, 0, -(z1 - z0)), image, (1, 0, 0), offset, emit)


def noise_texture(w, h, seed, base, spread=14, streaks=False):
    """A painted-metal texture: the base colour with grain (a little wear)."""
    rnd = np.random.RandomState(seed)
    a = np.zeros((h, w, 4))
    a[..., :3] = np.array(base)
    a[..., 3] = 255
    a[..., :3] += rnd.randn(h, w, 1) * spread * 0.4
    if streaks:
        a[..., :3] += rnd.randn(1, w, 1) * spread * 0.5
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), 'RGBA')


# ----------------------------------------------------------------------------------------------------------------
# The trade sheet.

def screen_image(on, w=96, h=64):
    """The terminal's screen, a rugged field computer of 1993: a gas-plasma panel, orange pixels on black, blocky
    characters. Off: dark grey-green glass with a faint reflection of the room."""
    if not on:
        img = Image.new('RGBA', (w, h), (26, 32, 28, 255))
        d = ImageDraw.Draw(img)
        d.polygon([(0, 0), (w * 0.5, 0), (w * 0.2, h)], fill=(38, 46, 40, 255))
        d.polygon([(w * 0.55, 0), (w * 0.62, 0), (w * 0.32, h), (w * 0.25, h)], fill=(34, 42, 36, 255))
        return img
    img = Image.new('RGBA', (w, h), (22, 8, 2, 255))
    d = ImageDraw.Draw(img)
    on_px, dim = (255, 138, 28, 255), (170, 84, 14, 255)
    rnd = random.Random(11)
    # a status bar: an orange stripe with dark blocky characters
    d.rectangle([0, 0, w, 7], fill=on_px)
    for i in range(9):
        x = 3 + i * 5
        for _ in range(3):
            y0 = rnd.randint(1, 4)
            d.rectangle([x + rnd.randint(0, 2), y0, x + 2, y0 + rnd.randint(0, 2)], fill=(22, 8, 2, 255))
    # rows of blocky characters, 3x5 cells in words, a cursor block at the end
    for row in range(7):
        y = 11 + row * 7
        x = 4
        for word in range(rnd.randint(2, 4)):
            for _ in range(rnd.randint(2, 7)):
                cell = [(cx, cy) for cx in range(3) for cy in range(5) if rnd.random() < 0.55]
                for cx, cy in cell:
                    d.rectangle([x + cx, y + cy, x + cx, y + cy], fill=on_px if row % 3 else dim)
                x += 4
                if x > w - 8:
                    break
            x += 4
            if x > w - 8:
                break
    d.rectangle([w - 9, h - 8, w - 5, h - 3], fill=on_px)
    return img


def keyboard_image(w=96, h=48):
    img = Image.new('RGBA', (w, h), (58, 62, 54, 255))
    d = ImageDraw.Draw(img)
    for row in range(4):
        for col in range(14):
            x, y = 3 + col * 6.4, 3 + row * 6.2
            d.rectangle([x, y, x + 4.6, y + 4.4], fill=(28, 30, 30, 255))
    d.rectangle([22, 29, 68, 34], fill=(28, 30, 30, 255))
    d.rectangle([76, 29, 92, 44], fill=(90, 96, 84, 255))
    return img


def dial_image(on, w=56, h=24):
    img = Image.new('RGBA', (w, h), (22, 24, 22, 255) if not on else (210, 150, 52, 255))
    d = ImageDraw.Draw(img)
    ink = (210, 206, 190, 255) if not on else (70, 36, 10, 255)
    if not on:
        ink = (92, 96, 88, 255)
    for i in range(9):
        x = 3 + i * 6
        d.line([(x, 3), (x, 9 if i % 2 else 12)], fill=ink, width=1)
    d.rectangle([2, 15, 52, 17], fill=ink)
    if on:
        d.line([(33, 2), (33, 22)], fill=(180, 30, 20, 255), width=1)
    return img


def terminal(turns, on):
    """The communication terminal: a field radio and a rugged computer case on a steel stand; the stand's front
    is south. Lit: the screen shows the console, the radio's dial glows, a green lamp."""
    s = Scene(turns)
    glows = []
    # The stand: four legs, the top plate, a lower shelf with an ammo-can battery and a coil of cable.
    for lx in (0.11, 0.85):
        for ly in (0.25, 0.71):
            s.box(lx, ly, 0.0, lx + 0.04, ly + 0.04, 0.40, OD_DARK, shine=0.1)
    s.box(0.10, 0.24, 0.40, 0.90, 0.76, 0.43, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.12, 0.26, 0.13, 0.88, 0.74, 0.15, OD_DARK, top=OD)
    s.box(0.17, 0.36, 0.15, 0.40, 0.58, 0.29, OD, top=OD_LIGHT, shine=0.1)
    s.box(0.20, 0.355, 0.20, 0.37, 0.36, 0.26, STENCIL)
    s.box(0.26, 0.40, 0.29, 0.31, 0.54, 0.31, STEEL_DARK, shine=0.4)
    s.tube((0.62, 0.50, 0.15), (0.62, 0.50, 0.17), 0.09, BLACK, cap=(52, 54, 56), segments=24)
    s.tube((0.62, 0.50, 0.17), (0.62, 0.50, 0.19), 0.075, (30, 30, 32), cap=(44, 46, 48), segments=24)
    # A cable from the stand's back down to the floor.
    s.tube((0.50, 0.24, 0.20), (0.50, 0.24, 0.0), 0.012, BLACK, segments=8)

    # The rugged computer case: bumpers, the base with its keyboard, the lid standing back with the screen.
    bx0, bx1, by0, by1, bz0, bz1 = 0.14, 0.56, 0.46, 0.74, 0.43, 0.50
    s.box(bx0, by0, bz0, bx1, by1, bz1, OD_DARK, top=OD, shine=0.15)
    for cx in (bx0, bx1 - 0.035):
        for cy in (by0, by1 - 0.035):
            s.box(cx, cy, bz0, cx + 0.035, cy + 0.035, bz1 + 0.006, RUBBER)
    flat_decal(s, bx0 + 0.045, by0 + 0.05, bx1 - 0.045, by1 - 0.02, bz1, keyboard_image())
    # latches on the front
    for lx in (0.22, 0.48):
        s.box(lx, by1, bz0 + 0.015, lx + 0.045, by1 + 0.012, bz1 - 0.012, STEEL_DARK, shine=0.5)
    # The lid, tilted back about its hinge on the base's back edge.
    tilt = 17
    rot = rotation((1, 0, 0), tilt)
    lid_size = (bx1 - bx0, 0.045, 0.31)
    hinge = (0.35, by0 + 0.01, bz1)
    centre = add(hinge, apply(rot, (0, 0.0, lid_size[2] / 2)))
    s.xbox(centre, lid_size, rot, OD_DARK, top=OD, shine=0.15)
    stick(s, centre, rot, lid_size, '+y', Image.new('RGBA', (16, 16), (30, 32, 30, 255)), margin=0.0, offset=0.002)
    stick(s, centre, rot, lid_size, '+y', screen_image(on), emit=on, margin=0.03, offset=0.005)
    stick(s, centre, rot, lid_size, '-y', acorn_mark(40), margin=0.07, offset=0.003)
    if on:
        lx, ly, lz = add(centre, apply(rot, (0, 0.05, 0.0)))
        glows.append(((lx, ly, lz), (255, 140, 40), 0.20, apply(rot, (0, 1, 0))))
        # the screen's light on the keyboard
        glows.append(((0.35, 0.60, bz1 + 0.01), (255, 140, 40), 0.14))

    # The field radio: a rectangular set with its dial, two knobs, a speaker grille, an antenna and a handset.
    rx0, rx1, ry0, ry1, rz0, rz1 = 0.60, 0.88, 0.36, 0.66, 0.43, 0.68
    s.box(rx0, ry0, rz0, rx1, ry1, rz1, OD, top=OD_LIGHT, shine=0.2)
    s.box(rx0 - 0.008, ry0 - 0.008, rz0, rx1 + 0.008, ry0 + 0.01, rz0 + 0.03, OD_DARK)
    # front panel
    s.box(rx0 + 0.015, ry1, rz0 + 0.02, rx1 - 0.015, ry1 + 0.01, rz1 - 0.02, OD_DARK, shine=0.2)
    front_decal(s, rx0 + 0.03, rx1 - 0.03, rz1 - 0.085, rz1 - 0.035, ry1 + 0.01, dial_image(on), emit=on)
    knob_y(s, rx0 + 0.07, ry1 + 0.01, rz0 + 0.12, 0.028)
    knob_y(s, rx0 + 0.15, ry1 + 0.01, rz0 + 0.12, 0.022, STEEL_DARK)
    for i in range(4):
        s.box(rx0 + 0.045, ry1 + 0.01, rz0 + 0.04 + i * 0.012, rx1 - 0.045, ry1 + 0.016, rz0 + 0.047 + i * 0.012,
              (24, 26, 24))
    lamp_y(s, glows, rx1 - 0.05, ry1 + 0.01, rz0 + 0.12, 0.014, 'green', on)
    # the carrying handle, the antenna on its base, the handset on the east side
    s.box(rx0 + 0.05, ry0 + 0.1, rz1, rx0 + 0.065, ry0 + 0.2, rz1 + 0.035, RUBBER)
    s.box(rx0 + 0.05, ry0 + 0.1, rz1 + 0.025, rx0 + 0.15, ry0 + 0.115, rz1 + 0.04, RUBBER)
    s.tube((rx1 - 0.06, ry0 + 0.07, rz1), (rx1 - 0.06, ry0 + 0.07, rz1 + 0.03), 0.026, STEEL_DARK, cap=BLACK, shine=0.4,
           segments=16)
    s.tube((rx1 - 0.06, ry0 + 0.07, rz1 + 0.03), (rx1 - 0.06, ry0 + 0.07, rz1 + 0.52), 0.011, STEEL, r2=0.004,
           shine=0.5, segments=8)
    s.tube((rx1 - 0.06, ry0 + 0.07, rz1 + 0.52), (rx1 - 0.06, ry0 + 0.07, rz1 + 0.535), 0.009, RED, segments=8)
    s.box(rx1, ry0 + 0.1, rz0 + 0.07, rx1 + 0.035, ry0 + 0.14, rz0 + 0.2, BLACK, shine=0.3)
    s.box(rx1, ry0 + 0.1, rz0 + 0.2, rx1 + 0.05, ry0 + 0.14, rz0 + 0.235, BLACK, shine=0.3)
    s.box(rx1, ry0 + 0.1, rz0 + 0.04, rx1 + 0.05, ry0 + 0.14, rz0 + 0.07, BLACK, shine=0.3)
    s.tube((rx1 + 0.03, ry0 + 0.12, rz0 + 0.04), (rx1 + 0.03, ry0 + 0.12, rz0 - 0.1), 0.006, BLACK, segments=6)
    stick(s, ((rx0 + rx1) / 2, ry0, (rz0 + rz1) / 2), IDENTITY, (rx1 - rx0, 0.0, rz1 - rz0), '-y',
          stencil_text('OAK-1', 40, 14, STENCIL), margin=0.05)
    ground = shadow((0.5, 0.5), 0.46, 0.34, 120)
    return compose(s, ground=ground, seed=10 + turns + (4 if on else 0), glows=glows)
