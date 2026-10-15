"""The two refiners (2 x 2 squares each, x and y from 0 to 2, the front to the south): the propane refiner and the oil
refiner. See tile_big1.py."""
import math
import random

from PIL import Image, ImageDraw, ImageFilter

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


def tread_plate(w=256, h=256, base=(74, 78, 82)):
    """Steel checker plate: raised diamond lugs in alternating rows over worn grey."""
    img = noise_texture(w, h, 21, base, spread=10)
    d = ImageDraw.Draw(img)
    light = tuple(min(255, c + 34) for c in base) + (255,)
    dark = tuple(int(c * 0.7) for c in base) + (255,)
    for row, y in enumerate(range(6, h, 12)):
        for x in range(6 + (row % 2) * 6, w, 12):
            if row % 2:
                d.line([(x - 3, y + 2), (x + 3, y - 2)], fill=light, width=2)
                d.line([(x - 2, y + 3), (x + 4, y - 1)], fill=dark, width=1)
            else:
                d.line([(x - 3, y - 2), (x + 3, y + 2)], fill=light, width=2)
                d.line([(x - 2, y - 1), (x + 4, y + 3)], fill=dark, width=1)
    return img


def skid(s, x0, y0, x1, y1):
    s.box(x0, y0, 0.0, x1, y1, 0.08, GRAPHITE_DARK, top=GRAPHITE, shine=0.15)
    flat_decal(s, x0, y0, x1, y1, 0.08, tread_plate())
    front_decal(s, x0, x1, 0.0, 0.08, y1 + 0.001, hazard_strip(300, 12, YELLOW, (30, 30, 28), 7))
    s.poly([(x1, y0, 0.0), (x1, y1, 0.0), (x1, y1, 0.08), (x1, y0, 0.08)], YELLOW, (1, 0, 0))


def control_cabinet(s, glows, x0, x1, y, z1, look, lamps=('green', 'amber', 'red')):
    """A control cabinet standing at the skid's front (its face looks south at y): lamps along its head, all dark when stopped (no lamp lights without power). On:
    green. Running: green and amber."""
    s.box(x0, y - 0.26, 0.08, x1, y, z1, OD, top=OD_LIGHT, shine=0.1)
    s.box(x0 + 0.03, y, 0.14, x1 - 0.03, y + 0.004, z1 - 0.2, GRAPHITE_DARK)
    n = len(lamps)
    for i, c in enumerate(lamps):
        lit = {'green': look >= 1, 'amber': look == 1}.get(c, False)
        lamp_y(s, glows, x0 + (i + 0.5) * (x1 - x0) / n, y, z1 - 0.1, 0.026, c, lit)
    front_decal(s, x0 + 0.04, x1 - 0.04, z1 - 0.18, z1 - 0.12, y + 0.001, stencil_text('OAK', 40, 9, STENCIL))


def propane_refiner(turns, look):
    """The propane refiner (2 x 2): a tall cream process column with a railed platform, a ladder and a gauge, a
    horizontal bullet tank on saddles, a rack of four bottles, red valve wheels, a flare stack and a control cabinet on
    a skid with a yellow-black edge. Running: a flare burns at the stack's tip, the gauge stands high. The cabinet's
    lamps say off, on or running.
    look: 0 stopped (switched off or no power: every lamp dark), 2 ready (switched on and waiting: the green lamp, nothing
    moves), 1 running (working)."""
    running = look == 1
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
    # a manway low on the column's south-east: a round hatch on a short neck, its bolts round the flange
    ma = math.radians(70)
    mx, my, mz = cx + r * math.cos(ma), cy + r * math.sin(ma), 0.19
    out = (math.cos(ma), math.sin(ma), 0)
    s.tube((mx - out[0] * 0.02, my - out[1] * 0.02, mz), (mx + out[0] * 0.06, my + out[1] * 0.06, mz), 0.085,
           CREAM_DARK, cap=CREAM, segments=24, shine=0.3)
    for k in range(8):
        a = 2 * math.pi * k / 8
        tx, ty = -math.sin(ma), math.cos(ma)
        bx = mx + out[0] * 0.062 + tx * 0.065 * math.cos(a)
        by = my + out[1] * 0.062 + ty * 0.065 * math.cos(a)
        s.sphere((bx, by, mz + 0.065 * math.sin(a)), (0.011, 0.011, 0.011), STEEL_DARK, rings=3, segments=6, shine=0.5)
    # No ladder and no platform: the column stands about a man's height, so a skid unit's are read from the ground. On
    # the column's south-east, a magnetic level indicator: two nozzles out of the column, a chamber between them, and
    # its flag strip (orange below the liquid, white above) behind a bezel, a drain valve at its foot.
    la = math.radians(60)
    out = (math.cos(la), math.sin(la))
    side = (-math.sin(la), math.cos(la))
    lr = r + 0.11

    def around(dist, z, across=0.0):
        return (cx + dist * out[0] + across * side[0], cy + dist * out[1] + across * side[1], z)
    low, high = 0.3, 1.36
    for nz in (low, high):
        s.tube(around(r - 0.02, nz), around(lr, nz), 0.026, STEEL_DARK, segments=10, shine=0.3)
        s.tube(around(r + 0.03, nz), around(r + 0.05, nz), 0.05, STEEL_DARK, segments=12)
    s.tube(around(lr, low - 0.1), around(lr, high + 0.06), 0.034, STEEL, cap=STEEL_DARK, segments=14, shine=0.5)
    level = low + 0.12 + (0.62 if running else 0.36)
    face = lr + 0.034
    s.tube(around(face, low + 0.08), around(face, high - 0.04), 0.022, BEZEL, segments=10, shine=0.4)
    s.tube(around(face + 0.024, low + 0.1), around(face + 0.024, level), 0.017, (236, 110, 28), segments=10, shine=0.5)
    s.tube(around(face + 0.024, level), around(face + 0.024, high - 0.06), 0.017, (238, 238, 230), segments=10, shine=0.5)
    s.tube(around(lr, low - 0.1), around(lr, low - 0.18), 0.016, STEEL, segments=8, shine=0.5)
    valve_wheel(s, around(lr, low - 0.2), 0.04, RED, axis='x')
    # the safety relief valve on the head, a yellow body and its vent pipe turned up
    s.tube((cx, cy, top + 0.3), (cx, cy, top + 0.36), 0.06, STEEL_DARK, segments=14, shine=0.4)
    s.tube((cx, cy, top + 0.36), (cx, cy, top + 0.5), 0.045, YELLOW, cap=YELLOW, segments=14, shine=0.4)
    pipe(s, [(cx, cy, top + 0.44), (cx + 0.14, cy, top + 0.44), (cx + 0.14, cy, top + 0.7)], 0.02)
    s.tube((cx + 0.14, cy, top + 0.7), (cx + 0.14, cy, top + 0.73), 0.03, STEEL_DARK, segments=10)
    # the gauge on the column's south face and a stencil
    gz = 0.86
    front_decal(s, cx - 0.2, cx + 0.0, 0.38, 0.5, cy + r + 0.0, stencil_text('PROPANE', 80, 20, (40, 70, 130)))
    s.tube((cx - 0.12, cy + r * 0.95, gz), (cx - 0.12, cy + r + 0.02, gz), 0.08, BEZEL, segments=22)
    front_decal(s, cx - 0.12 - 0.065, cx - 0.12 + 0.065, gz - 0.065, gz + 0.065, cy + r + 0.021, gauge_image(0.8 if running else 0.12, 56), offset=0.0)
    # the bullet tank on two saddles, along x, south of the column
    ty, tz, tr = 1.46, 0.46, 0.27
    seam = (136, 132, 122)
    s.tube((0.78, ty, tz), (1.66, ty, tz), tr, (164, 160, 148), cap=(150, 146, 136), segments=36, shine=0.35,
           bands=[(0, 0.22, (164, 160, 148)), (0.22, 0.235, seam), (0.235, 0.46, (164, 160, 148)), (0.46, 0.52, BLUE),
                  (0.52, 0.765, (164, 160, 148)), (0.765, 0.78, seam), (0.78, 1, (164, 160, 148))])
    s.sphere((0.78, ty, tz), (0.14, tr, tr), (172, 168, 156), rings=7, segments=36, z_from=-90, z_to=90, shine=0.35)
    s.sphere((1.66, ty, tz), (0.14, tr, tr), (172, 168, 156), rings=7, segments=36, z_from=-90, z_to=90, shine=0.35)
    for x in (0.98, 1.46):
        s.box(x, ty - 0.2, 0.08, x + 0.06, ty + 0.2, 0.28, GRAPHITE_DARK)
    s.tube((1.2, ty, tz + tr - 0.02), (1.2, ty, tz + tr + 0.1), 0.07, STEEL_DARK, cap=STEEL, segments=18, shine=0.5)
    s.tube((1.4, ty, tz + tr - 0.02), (1.4, ty, tz + tr + 0.2), 0.022, STEEL, segments=8, shine=0.6)
    valve_wheel(s, (1.4, ty, tz + tr + 0.24), 0.06, RED, axis='x')
    front_decal(s, 1.0, 1.4, tz - 0.08, tz + 0.08, ty + tr * 0.97, stencil_text('LPG 4t', 70, 24, (80, 100, 150)), offset=0.0)
    # pipes: tank to column, column to the bottle rack
    # (round the ladder: up the tank's side, then into the column's east face)
    pipe(s, [(1.2, ty, tz + tr + 0.1), (1.2, cy, tz + tr + 0.1), (cx + r * 0.95, cy, tz + tr + 0.1)], 0.018)
    pipe(s, [(0.92, 0.9, 0.18), (1.5, 0.9, 0.18)], 0.02)
    # the bottle rack: four bottles in a frame
    for ix, bx in enumerate((1.42, 1.62, 1.82)):
        for iy, by in enumerate((0.40, 0.70)):
            if ix == 2 and iy == 1:
                continue
            col = (176, 70, 52) if (ix + iy) % 2 == 0 else (168, 166, 154)
            s.tube((bx, by, 0.08), (bx, by, 0.64), 0.07, col, cap=col, segments=22, shine=0.3)
            s.sphere((bx, by, 0.64), (0.07, 0.07, 0.05), col, rings=3, segments=22, z_from=0, z_to=90, shine=0.3)
            s.tube((bx, by, 0.69), (bx, by, 0.76), 0.018, STEEL, segments=8, shine=0.6)
            s.tube((bx, by, 0.76), (bx - 0.01, by, 0.78), 0.03, BRASS, segments=10, shine=0.6)
    s.box(1.32, 0.3, 0.30, 1.92, 0.8, 0.33, STEEL_DARK)
    s.box(1.32, 0.3, 0.60, 1.92, 0.8, 0.63, STEEL_DARK)
    # the flare stack at the north-east corner on a wide foot (guy wires were too thin to read: broken lines), a flame
    # when running
    sx, sy = 1.78, 0.2
    s.tube((sx, sy, 0.08), (sx, sy, 2.0), 0.055, GRAPHITE, segments=16, shine=0.3,
           bands=[(0, 0.84, GRAPHITE), (0.84, 0.88, RED), (0.88, 0.92, WHITE), (0.92, 0.96, RED), (0.96, 1, WHITE)])
    s.tube((sx, sy, 2.0), (sx, sy, 2.1), 0.07, GRAPHITE_DARK, r2=0.045, segments=16)
    s.tube((sx, sy, 0.08), (sx, sy, 0.14), 0.1, GRAPHITE_DARK, cap=GRAPHITE, segments=16)
    pipe(s, [(cx + r, cy, 1.4), (1.1, cy, 1.4), (1.1, sy, 1.4), (sx, sy, 1.4)], 0.016)
    # the control cabinet at the front-left
    control_cabinet(s, glows, 0.14, 0.58, 1.9, 0.92, look)
    front_decal(s, 0.18, 0.54, 0.2, 0.34, 1.9 + 0.001, stencil_text('LPG UNIT', 80, 18, STENCIL))
    # a small compressor beside it: a blue motor and a receiver
    s.tube((0.70, 1.7, 0.2), (0.92, 1.7, 0.2), 0.1, BLUE, cap=(44, 62, 88), segments=24, shine=0.2)
    s.box(0.62, 1.6, 0.08, 0.98, 1.8, 0.1, GRAPHITE_DARK)

    def flame(img):
        # a flare's flame: soft teardrops one inside another (a red-orange skirt, an orange body, a pale core low down),
        # bulging just above the tip and drawn up to a curved point, leaning a little downwind, a second smaller
        # tongue beside it; each blurred so no edge shows (a flat polygon read as a triangle)
        px, py = project(*s.turn((sx, sy, 2.1)))

        def tongue(cx_, base, h, w, lean, colour, blur):
            layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
            left, right = [], []
            for k in range(25):
                u = k / 24
                half = w * (1 - u) ** 0.8 * (0.55 + 1.6 * u * (1 - u))
                x = cx_ + lean * h * u * u
                y = base - h * u
                left.append((x - half, y))
                right.append((x + half, y))
            ImageDraw.Draw(layer).polygon(left + right[::-1], fill=colour)
            img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur * SS)))
        tongue(px + 3 * SS, py, 17 * SS, 5 * SS, 0.35, (255, 110, 30, 150), 1.4)
        tongue(px, py, 32 * SS, 9 * SS, 0.18, (255, 96, 24, 170), 1.6)
        tongue(px, py + SS, 25 * SS, 7 * SS, 0.15, (255, 168, 48, 225), 1.1)
        tongue(px, py + SS, 13 * SS, 4.5 * SS, 0.1, (255, 244, 196, 255), 0.7)
    if running:
        glows.append(((sx, sy, 2.2), FLAME, 0.32))
    ground = shadow((1.0, 1.0), 1.0, 1.0, 125)
    return compose(s, ground=ground, over=flame if running else None, seed=130 + turns + 4 * int(look), glows=glows)


def oil_refiner(turns, look):
    """The oil refiner (2 x 2): a graphite horizontal vessel on a frame, a tall fractionating column with yellow bands,
    a pipe rack between them with hand wheels, draw-off pipes down to a row of drums at the front, a blue pump, a
    heat exchanger, a control cabinet, on a skid. Running: lamps lit, steam rising from the column, oil running into
    the drums.
    look: 0 stopped (switched off or no power: every lamp dark), 2 ready (switched on and waiting: the green lamp, nothing
    moves), 1 running (working)."""
    running = look == 1
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
    # a level bridle on the column's east side: two nozzles out of the column, a standpipe between them with its
    # sight glass and the oil's level in it, a drain valve at its foot (where a bare ladder led nowhere)
    bx = cx + cr + 0.09
    for nz in (0.34, 1.34):
        s.tube((cx + cr - 0.02, cy, nz), (bx, cy, nz), 0.024, GRAPHITE_DARK, segments=10, shine=0.3)
        s.tube((cx + cr + 0.03, cy, nz), (cx + cr + 0.045, cy, nz), 0.045, GRAPHITE_DARK, segments=12)
    s.tube((bx, cy, 0.26), (bx, cy, 1.42), 0.026, GRAPHITE, cap=GRAPHITE_DARK, segments=12, shine=0.4)
    s.box(bx - 0.03, cy - 0.034, 0.62, bx + 0.03, cy + 0.034, 1.1, STEEL_DARK, top=STEEL, shine=0.4)
    s.box(bx + 0.03, cy - 0.016, 0.66, bx + 0.036, cy + 0.016, 1.06, (196, 206, 210), shine=0.6)
    s.box(bx + 0.031, cy - 0.016, 0.66, bx + 0.037, cy + 0.016, 0.66 + (0.32 if running else 0.18), (40, 30, 18), shine=0.6)
    s.tube((bx, cy, 0.26), (bx, cy, 0.18), 0.016, STEEL, segments=8, shine=0.5)
    valve_wheel(s, (bx, cy, 0.16), 0.035, RED, axis='x')
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
    # the row of drums at the front, draw-off pipes over them: painted steel, a worn blue-grey (black they read as holes)
    DRUM, DRUM_RIB, DRUM_HOLE = (70, 78, 86), (52, 58, 64), (30, 32, 34)
    for i, dx in enumerate((0.40, 0.78, 1.16, 1.54)):
        dy = 1.62
        s.tube((dx, dy, 0.08), (dx, dy, 0.58), 0.15, DRUM, cap=DRUM_RIB, segments=26, shine=0.35,
               bands=[(0, 0.07, DRUM_RIB), (0.07, 0.33, DRUM), (0.33, 0.37, DRUM_RIB), (0.37, 0.63, DRUM),
                      (0.63, 0.67, DRUM_RIB), (0.67, 0.93, DRUM), (0.93, 1, DRUM_RIB)])
        if i in (0, 1) or running:
            disc(s, (dx, dy), 0.12, 0.581, (60, 40, 14) if running and i < 3 else DRUM_HOLE, segments=22, shine=0.7)
    pipe(s, [(1.34, 1.05, 1.0), (1.34, 1.05, 1.12)], 0.02)
    for i, dx in enumerate((0.40, 0.78, 1.16, 1.54)):
        if i < 3:
            pipe(s, [(dx, 1.62, 0.66), (dx, 1.62, 0.72), (dx, 1.3, 0.72)], 0.014)
    s.tube((0.40, 1.3, 0.72), (1.16, 1.3, 0.72), 0.014, PIPE, segments=8, shine=0.4)
    if running:
        for dx in (0.40, 0.78, 1.16):
            s.tube((dx, 1.62, 0.66), (dx, 1.62, 0.58), 0.006, (40, 28, 10), segments=5, shine=0.7)
    # a pump: a blue motor and its pump head on a plate, by the vessel
    s.box(0.14, 1.0, 0.08, 0.58, 1.3, 0.12, GRAPHITE_DARK)
    s.tube((0.18, 1.15, 0.24), (0.46, 1.15, 0.24), 0.1, BLUE, cap=(44, 62, 88), segments=24, shine=0.2,
           bands=[(0, 0.08, (44, 62, 88))] + [(0.12 + 0.14 * i, 0.2 + 0.14 * i, (54, 76, 102)) for i in range(6)])
    s.tube((0.46, 1.15, 0.24), (0.58, 1.15, 0.24), 0.07, STEEL_DARK, segments=16, shine=0.4)
    pipe(s, [(0.6, 1.15, 0.24), (0.6, 0.8, 0.24), (0.6, 0.8, 0.6)], 0.02)
    # the control cabinet at the front-right
    control_cabinet(s, glows, 1.56, 1.9, 1.9, 0.9, look, lamps=('green', 'amber', 'red'))
    front_decal(s, 1.6, 1.86, 0.2, 0.32, 1.9 + 0.001, stencil_text('OIL UNIT', 70, 16, STENCIL))
    s.box(0.14, 1.8, 0.08, 0.5, 1.9, 0.5, OD_DARK)
    front_decal(s, 0.16, 0.48, 0.24, 0.4, 1.9 + 0.001, acorn_mark(24, STENCIL))

    def steam(img):
        # puffs one over another, each blurred so the plume is soft (hard-edged discs read as clip art)
        layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer, 'RGBA')
        px, py = project(*s.turn((cx, cy, ctop + 0.22)))
        rn = random.Random(5)
        for i in reversed(range(7)):
            r_ = (5 + i * 1.5) * SS
            ox = (rn.random() - 0.5) * 6 * SS + i * 1.2 * SS
            oy = -i * 6.5 * SS
            a = max(40, 200 - i * 24)
            d.ellipse([px + ox - r_, py + oy - r_, px + ox + r_, py + oy + r_], fill=STEAM + (a,))
        img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(2.2 * SS)))
    ground = shadow((1.0, 1.0), 1.0, 1.0, 125)
    return compose(s, ground=ground, over=steam if running else None, seed=140 + turns + 4 * int(look), glows=glows)
