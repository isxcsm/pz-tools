"""The two refiners (2 x 2 squares each, x and y from 0 to 2, the front to the south): the propane refiner and the oil
refiner. See tile_big1.py."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import Scene, shadow, compose, unit, rotation, apply, add, mul, stencil_text, acorn_mark, project, SS
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, LIT, UNLIT, BEZEL, lamp, lamp_y, lamp_x,
                          front_decal, side_decal, flat_decal, noise_texture)
from tile_trade import hazard_strip
from tile_machines import (GRAPHITE, GRAPHITE_DARK, GRAPHITE_LIGHT, CREAM, CREAM_DARK, FLAME, STEAM, ring_top, disc,
                           gauge_image, valve_wheel)


def pipe(s, pts, r=0.02, colour=PIPE):
    """A pipe run through points, with a flange ring at each bend."""
    for a, b in zip(pts, pts[1:]):
        s.tube(a, b, r, colour, segments=10, shine=0.4)
    for p in pts[1:-1]:
        s.sphere(p, (r * 1.15, r * 1.15, r * 1.15), colour, rings=4, segments=10, shine=0.4)


def skid(s, x0, y0, x1, y1):
    s.box(x0, y0, 0.0, x1, y1, 0.08, GRAPHITE_DARK, top=GRAPHITE, shine=0.15)
    front_decal(s, x0, x1, 0.0, 0.08, y1 + 0.001, hazard_strip(300, 12, YELLOW, (30, 30, 28), 7))
    s.poly([(x1, y0, 0.0), (x1, y1, 0.0), (x1, y1, 0.08), (x1, y0, 0.08)], YELLOW, (1, 0, 0))


def control_cabinet(s, glows, x0, x1, y, z1, running, lamps=('green', 'amber', 'red')):
    """A control cabinet standing at the skid's front (its face looks south at y): lamps along its head."""
    s.box(x0, y - 0.26, 0.08, x1, y, z1, OD, top=OD_LIGHT, shine=0.1)
    s.box(x0 + 0.03, y, 0.14, x1 - 0.03, y + 0.004, z1 - 0.2, GRAPHITE_DARK)
    n = len(lamps)
    for i, c in enumerate(lamps):
        lit = running and c in ('green', 'amber') or (not running and c == 'red')
        lamp_y(s, glows, x0 + (i + 0.5) * (x1 - x0) / n, y, z1 - 0.1, 0.017, c, lit)
    front_decal(s, x0 + 0.04, x1 - 0.04, z1 - 0.18, z1 - 0.12, y + 0.001, stencil_text('OAK', 40, 9, STENCIL))


def propane_refiner(turns, running):
    """The propane refiner (2 x 2): a tall cream process column with a railed platform, a ladder and a gauge, a
    horizontal bullet tank on saddles, a rack of four bottles, red valve wheels, a flare stack and a control cabinet on
    a skid with a yellow-black edge. Running: a flare burns at the stack's tip, the gauge stands high, the lamp is
    green."""
    s = Scene(turns, foot=(2, 2))
    glows = []
    skid(s, 0.08, 0.08, 1.92, 1.92)
    # the column
    cx, cy, r, top = 0.64, 0.64, 0.30, 1.62
    s.tube((cx, cy, 0.08), (cx, cy, top), r, CREAM, cap=CREAM, segments=44, shine=0.25,
           bands=[(0, 0.04, CREAM_DARK), (0.04, 0.26, CREAM), (0.26, 0.29, BLUE), (0.29, 0.58, CREAM), (0.58, 0.61, BLUE),
                  (0.61, 0.95, CREAM), (0.95, 1.0, CREAM_DARK)])
    s.sphere((cx, cy, top), (r, r, 0.17), CREAM, rings=6, segments=44, z_from=0, z_to=90, shine=0.25)
    s.tube((cx, cy, top + 0.17), (cx, cy, top + 0.3), 0.04, STEEL_DARK, segments=12, shine=0.4)
    for z in (0.3, 0.7, 1.1):
        s.tube((cx, cy, z), (cx, cy, z + 0.025), r + 0.015, CREAM_DARK, segments=44, shine=0.2)
    # a railed platform half way up
    pz = 1.04
    ring_top(s, (cx, cy), r, r + 0.17, pz, STEEL_DARK, segments=44, shine=0.3)
    for i in range(14):
        a = 2 * math.pi * i / 14
        px, py = cx + (r + 0.16) * math.cos(a), cy + (r + 0.16) * math.sin(a)
        s.tube((px, py, pz), (px, py, pz + 0.3), 0.007, STEEL, segments=5, shine=0.5)
    for i in range(44):
        a0, a1 = 2 * math.pi * i / 44, 2 * math.pi * (i + 1) / 44
        s.tube((cx + (r + 0.16) * math.cos(a0), cy + (r + 0.16) * math.sin(a0), pz + 0.3),
               (cx + (r + 0.16) * math.cos(a1), cy + (r + 0.16) * math.sin(a1), pz + 0.3), 0.007, STEEL, segments=5, shine=0.5)
    # the ladder up the column's south-east
    la = math.radians(60)
    lx, ly = cx + (r + 0.02) * math.cos(la), cy + (r + 0.02) * math.sin(la)
    for side in (-0.06, 0.06):
        s.tube((lx - side * math.sin(la), ly + side * math.cos(la), 0.08), (lx - side * math.sin(la), ly + side * math.cos(la), pz), 0.008, STEEL_DARK, segments=6)
    for i in range(11):
        z = 0.14 + i * 0.085
        s.tube((lx + 0.06 * math.sin(la), ly - 0.06 * math.cos(la), z), (lx - 0.06 * math.sin(la), ly + 0.06 * math.cos(la), z), 0.007, STEEL_DARK, segments=5)
    # the gauge on the column's south face and a stencil
    gz = 0.86
    front_decal(s, cx - 0.2, cx + 0.0, 0.38, 0.5, cy + r + 0.0, stencil_text('PROPANE', 80, 20, (40, 70, 130)))
    s.tube((cx - 0.12, cy + r * 0.95, gz), (cx - 0.12, cy + r + 0.02, gz), 0.08, BEZEL, segments=22)
    front_decal(s, cx - 0.12 - 0.065, cx - 0.12 + 0.065, gz - 0.065, gz + 0.065, cy + r + 0.021, gauge_image(0.8 if running else 0.12, 56), offset=0.0)
    # the bullet tank on two saddles, along x, south of the column
    ty, tz, tr = 1.46, 0.46, 0.27
    s.tube((0.78, ty, tz), (1.66, ty, tz), tr, (214, 212, 200), cap=(190, 188, 176), segments=36, shine=0.35,
           bands=[(0, 0.46, (214, 212, 200)), (0.46, 0.52, BLUE), (0.52, 1, (214, 212, 200))])
    s.sphere((0.78, ty, tz), (0.14, tr, tr), (200, 198, 186), rings=7, segments=36, z_from=-90, z_to=90, shine=0.35)
    s.sphere((1.66, ty, tz), (0.14, tr, tr), (200, 198, 186), rings=7, segments=36, z_from=-90, z_to=90, shine=0.35)
    for x in (0.98, 1.46):
        s.box(x, ty - 0.2, 0.08, x + 0.06, ty + 0.2, 0.28, GRAPHITE_DARK)
    s.tube((1.2, ty, tz + tr - 0.02), (1.2, ty, tz + tr + 0.1), 0.07, STEEL_DARK, cap=STEEL, segments=18, shine=0.5)
    s.tube((1.4, ty, tz + tr - 0.02), (1.4, ty, tz + tr + 0.2), 0.022, STEEL, segments=8, shine=0.6)
    valve_wheel(s, (1.4, ty, tz + tr + 0.24), 0.06, RED, axis='x')
    front_decal(s, 1.0, 1.4, tz - 0.08, tz + 0.08, ty + tr * 0.97, stencil_text('LPG 4t', 70, 24, (80, 100, 150)), offset=0.0)
    # pipes: tank to column, column to the bottle rack
    pipe(s, [(1.2, ty, tz + tr + 0.1), (1.2, 1.1, tz + tr + 0.1), (cx + r * 0.85, 1.1, tz + tr + 0.1), (cx + r * 0.85, cy + r * 0.5, tz + tr + 0.1)], 0.018)
    pipe(s, [(0.92, 0.9, 0.18), (1.5, 0.9, 0.18)], 0.02)
    # the bottle rack: four bottles in a frame
    for ix, bx in enumerate((1.42, 1.62, 1.82)):
        for iy, by in enumerate((0.40, 0.70)):
            if ix == 2 and iy == 1:
                continue
            col = (176, 70, 52) if (ix + iy) % 2 == 0 else (190, 190, 176)
            s.tube((bx, by, 0.08), (bx, by, 0.64), 0.07, col, cap=col, segments=22, shine=0.3)
            s.sphere((bx, by, 0.64), (0.07, 0.07, 0.05), col, rings=3, segments=22, z_from=0, z_to=90, shine=0.3)
            s.tube((bx, by, 0.69), (bx, by, 0.76), 0.018, STEEL, segments=8, shine=0.6)
            s.tube((bx, by, 0.76), (bx - 0.01, by, 0.78), 0.03, BRASS, segments=10, shine=0.6)
    s.box(1.32, 0.3, 0.30, 1.92, 0.8, 0.33, STEEL_DARK)
    s.box(1.32, 0.3, 0.60, 1.92, 0.8, 0.63, STEEL_DARK)
    # the flare stack at the north-east corner, braced, a flame when running
    sx, sy = 1.78, 0.2
    s.tube((sx, sy, 0.08), (sx, sy, 2.0), 0.04, GRAPHITE, segments=14, shine=0.3)
    s.tube((sx, sy, 2.0), (sx, sy, 2.1), 0.055, GRAPHITE_DARK, r2=0.035, segments=14)
    for ang in (30, 150, 270):
        a = math.radians(ang)
        s.tube((sx + 0.4 * math.cos(a), sy + 0.4 * math.sin(a), 0.08), (sx, sy, 1.4), 0.004, STEEL_DARK, segments=4)
    pipe(s, [(cx + r, cy, 1.4), (1.1, cy, 1.4), (1.1, sy, 1.4), (sx, sy, 1.4)], 0.016)
    # the control cabinet at the front-left
    control_cabinet(s, glows, 0.14, 0.58, 1.9, 0.92, running)
    front_decal(s, 0.18, 0.54, 0.2, 0.34, 1.9 + 0.001, stencil_text('LPG UNIT', 80, 18, STENCIL))
    # a small compressor beside it: a blue motor and a receiver
    s.tube((0.70, 1.7, 0.2), (0.92, 1.7, 0.2), 0.1, BLUE, cap=(34, 66, 94), segments=24, shine=0.2)
    s.box(0.62, 1.6, 0.08, 0.98, 1.8, 0.1, GRAPHITE_DARK)

    def flame(img):
        d = ImageDraw.Draw(img, 'RGBA')
        px, py = project(*s.turn((sx, sy, 2.1)))
        for (scale, col) in ((1.0, (255, 120, 30, 190)), (0.7, (255, 190, 60, 230)), (0.4, (255, 250, 200, 255))):
            h = 30 * SS * scale
            w = 10 * SS * scale
            d.polygon([(px, py - h), (px + w, py - h * 0.25), (px + w * 0.5, py), (px - w * 0.5, py), (px - w, py - h * 0.25)], fill=col)
    if running:
        glows.append(((sx, sy, 2.2), FLAME, 0.32))
    ground = shadow((1.0, 1.0), 1.0, 1.0, 125)
    return compose(s, ground=ground, over=flame if running else None, seed=130 + turns + (4 if running else 0), glows=glows)


def oil_refiner(turns, running):
    """The oil refiner (2 x 2): a graphite horizontal vessel on a frame, a tall fractionating column with yellow bands,
    a pipe rack between them with hand wheels, draw-off pipes down to a row of drums at the front, a blue pump, a
    heat exchanger, a control cabinet, on a skid. Running: lamps lit, steam rising from the column, oil running into
    the drums."""
    s = Scene(turns, foot=(2, 2))
    glows = []
    skid(s, 0.08, 0.08, 1.92, 1.92)
    # the vessel
    vy, vz, vr = 0.55, 0.85, 0.30
    for fx in (0.34, 0.92):
        for fy in (vy - 0.2, vy + 0.2):
            s.box(fx, fy - 0.03, 0.08, fx + 0.05, fy + 0.03, vz - vr * 0.7, GRAPHITE_DARK, shine=0.1)
        s.box(fx - 0.01, vy - 0.26, vz - vr - 0.02, fx + 0.06, vy + 0.26, vz - vr * 0.72, GRAPHITE_DARK)
    s.box(0.3, 0.2, 0.28, 1.0, 0.24, 0.31, STEEL_DARK)
    s.box(0.3, 0.86, 0.28, 1.0, 0.9, 0.31, STEEL_DARK)
    s.tube((0.2, vy, vz), (1.2, vy, vz), vr, GRAPHITE_LIGHT, cap=GRAPHITE, segments=40, shine=0.5,
           bands=[(0, 0.04, GRAPHITE), (0.04, 0.3, GRAPHITE_LIGHT), (0.3, 0.33, YELLOW), (0.33, 0.67, GRAPHITE_LIGHT), (0.67, 0.7, YELLOW),
                  (0.7, 0.96, GRAPHITE_LIGHT), (0.96, 1, GRAPHITE)])
    s.sphere((0.2, vy, vz), (0.12, vr, vr), GRAPHITE, rings=7, segments=40, z_from=-90, z_to=90, shine=0.4)
    s.sphere((1.2, vy, vz), (0.12, vr, vr), GRAPHITE, rings=7, segments=40, z_from=-90, z_to=90, shine=0.4)
    front_decal(s, 0.4, 1.0, vz - 0.1, vz + 0.1, vy + vr * 0.97, stencil_text('OIL  CRUDE', 100, 22, STENCIL), offset=0.0)
    s.tube((0.55, vy, vz + vr - 0.02), (0.55, vy, vz + vr + 0.1), 0.09, GRAPHITE, cap=GRAPHITE_DARK, segments=22, shine=0.3)
    s.tube((0.55, vy, vz + vr + 0.1), (0.55, vy, vz + vr + 0.13), 0.11, STEEL_DARK, cap=STEEL, segments=22, shine=0.5)
    s.tube((0.9, vy, vz + vr - 0.02), (0.9, vy, vz + vr + 0.22), 0.02, STEEL, segments=8, shine=0.6)
    valve_wheel(s, (0.9, vy, vz + vr + 0.26), 0.055, YELLOW, axis='x')
    # the column
    cx, cy, cr, ctop = 1.58, 0.58, 0.20, 1.8
    s.tube((cx, cy, 0.08), (cx, cy, ctop), cr, GRAPHITE_LIGHT, cap=GRAPHITE, segments=36, shine=0.45,
           bands=[(0, 0.2, GRAPHITE_LIGHT), (0.2, 0.225, YELLOW), (0.225, 0.47, GRAPHITE_LIGHT), (0.47, 0.495, YELLOW),
                  (0.495, 0.73, GRAPHITE_LIGHT), (0.73, 0.755, YELLOW), (0.755, 1, GRAPHITE_LIGHT)])
    s.sphere((cx, cy, ctop), (cr, cr, 0.1), GRAPHITE, rings=5, segments=36, z_from=0, z_to=90, shine=0.4)
    for z in (0.4, 0.85, 1.3, 1.7):
        s.tube((cx, cy, z), (cx, cy, z + 0.03), cr + 0.025, GRAPHITE_DARK, segments=36, shine=0.2)
    s.tube((cx, cy, ctop + 0.1), (cx, cy, ctop + 0.3), 0.015, STEEL_DARK, segments=6)
    # a ladder on the column's east side
    for side in (-0.05, 0.05):
        s.tube((cx + cr + 0.02, cy + side, 0.1), (cx + cr + 0.02, cy + side, 1.7), 0.007, STEEL_DARK, segments=6)
    for i in range(18):
        s.tube((cx + cr + 0.02, cy - 0.05, 0.16 + i * 0.087), (cx + cr + 0.02, cy + 0.05, 0.16 + i * 0.087), 0.006, STEEL_DARK, segments=5)
    # the pipe rack from vessel to column, with wheels
    pipe(s, [(1.2, vy, vz), (1.34, vy, vz), (1.34, cy, vz), (cx - cr, cy, vz)], 0.04, PIPE)
    valve_wheel(s, (1.34, 0.4, vz + 0.12), 0.05, YELLOW, axis='y')
    s.tube((1.34, 0.4, vz + 0.02), (1.34, 0.4, vz + 0.1), 0.012, STEEL, segments=6)
    pipe(s, [(cx, cy + cr, 1.62), (cx, 1.05, 1.62), (cx, 1.05, 1.0)], 0.022)
    pipe(s, [(cx, cy + cr, 0.9), (cx - 0.12, 1.2, 0.9), (cx - 0.12, 1.2, 0.5)], 0.022)
    # the heat exchanger: a short thick vertical cylinder with a coil
    hx, hy = 1.0, 1.25
    s.tube((hx, hy, 0.08), (hx, hy, 0.75), 0.13, GRAPHITE_LIGHT, cap=GRAPHITE, segments=30, shine=0.4,
           bands=[(0, 0.1, GRAPHITE), (0.1, 0.9, GRAPHITE_LIGHT), (0.9, 1, GRAPHITE)])
    s.tube((hx, hy, 0.75), (hx, hy, 0.82), 0.05, STEEL_DARK, segments=12)
    pipe(s, [(1.0, hy - 0.1, 0.75), (1.0, 0.95, 0.75), (1.34, 0.95, 0.75)], 0.018)
    # the row of drums at the front, draw-off pipes over them
    for i, dx in enumerate((0.40, 0.78, 1.16, 1.54)):
        dy = 1.62
        s.tube((dx, dy, 0.08), (dx, dy, 0.58), 0.15, (32, 34, 36), cap=(22, 24, 26), segments=26, shine=0.35,
               bands=[(0, 0.07, (24, 26, 28)), (0.07, 0.33, (34, 36, 38)), (0.33, 0.37, (24, 26, 28)), (0.37, 0.63, (34, 36, 38)),
                      (0.63, 0.67, (24, 26, 28)), (0.67, 0.93, (34, 36, 38)), (0.93, 1, (24, 26, 28))])
        if i in (0, 1) or running:
            disc(s, (dx, dy), 0.12, 0.581, (60, 40, 14) if running and i < 3 else (12, 12, 12), segments=22, shine=0.7)
    pipe(s, [(1.34, 1.05, 1.0), (1.34, 1.05, 1.12)], 0.02)
    for i, dx in enumerate((0.40, 0.78, 1.16, 1.54)):
        if i < 3:
            pipe(s, [(dx, 1.62, 0.66), (dx, 1.62, 0.72), (dx, 1.3, 0.72)], 0.014)
    s.tube((0.40, 1.3, 0.72), (1.16, 1.3, 0.72), 0.014, PIPE, segments=8, shine=0.4)
    if running:
        for dx in (0.40, 0.78, 1.16):
            s.tube((dx, 1.62, 0.66), (dx, 1.62, 0.58), 0.006, (40, 28, 10), segments=5, shine=0.7)
            glows.append(((dx, 1.62, 0.6), (255, 150, 30), 0.1))
    # a pump: a blue motor and its pump head on a plate, by the vessel
    s.box(0.14, 1.0, 0.08, 0.58, 1.3, 0.12, GRAPHITE_DARK)
    s.tube((0.18, 1.15, 0.24), (0.46, 1.15, 0.24), 0.1, BLUE, cap=(34, 66, 94), segments=24, shine=0.2,
           bands=[(0, 0.08, (34, 66, 94))] + [(0.12 + 0.14 * i, 0.2 + 0.14 * i, (40, 84, 128)) for i in range(6)])
    s.tube((0.46, 1.15, 0.24), (0.58, 1.15, 0.24), 0.07, STEEL_DARK, segments=16, shine=0.4)
    pipe(s, [(0.6, 1.15, 0.24), (0.6, 0.8, 0.24), (0.6, 0.8, 0.6)], 0.02)
    # the control cabinet at the front-right
    control_cabinet(s, glows, 1.56, 1.9, 1.9, 0.9, running, lamps=('green', 'amber', 'red'))
    front_decal(s, 1.6, 1.86, 0.2, 0.32, 1.9 + 0.001, stencil_text('OIL UNIT', 70, 16, STENCIL))
    s.box(0.14, 1.8, 0.08, 0.5, 1.9, 0.5, OD_DARK)
    front_decal(s, 0.16, 0.48, 0.24, 0.4, 1.9 + 0.001, acorn_mark(24, STENCIL))

    def steam(img):
        d = ImageDraw.Draw(img, 'RGBA')
        px, py = project(*s.turn((cx, cy, ctop + 0.22)))
        rn = random.Random(5)
        for i in reversed(range(7)):
            r_ = (5 + i * 1.5) * SS
            ox = (rn.random() - 0.5) * 6 * SS + i * 1.2 * SS
            oy = -i * 6.5 * SS
            a = max(30, 185 - i * 24)
            d.ellipse([px + ox - r_, py + oy - r_, px + ox + r_, py + oy + r_], fill=STEAM + (a,))
    ground = shadow((1.0, 1.0), 1.0, 1.0, 125)
    return compose(s, ground=ground, over=steam if running else None, seed=140 + turns + (4 if running else 0), glows=glows)
