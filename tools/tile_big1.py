"""Two-tile machines, part 1: the shred bench, the bulk shredder and the cutter. Each is drawn as one object on a
footprint of 2 x 1 squares (x from 0 to 2, y from 0 to 1, its front to the south, +y) and split into its tiles by
tile_engine.compose."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import (Scene, shadow, compose, unit, rotation, apply, add, mul, stencil_text, acorn_mark, project,
                         SS)
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, CANVAS, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, PIPE, WHITE,
                          STENCIL, YELLOW, RED, BRASS, WOOD, WOOD_DARK, BLUE, LIT, UNLIT, BEZEL, lamp, lamp_y, lamp_x,
                          front_decal, side_decal, back_decal, flat_decal, noise_texture)
from tile_trade import hazard_strip, plank_lines
from tile_machines import (GRAPHITE, GRAPHITE_DARK, GRAPHITE_LIGHT, double_poly, ring_top, disc, gauge_image,
                           valve_wheel, cutting_mat_image)


def board_image(w=256, h=60):
    """The bench's shadow board: tool outlines painted on a pegboard, a hammer, wrenches, pliers, a saw, driver sets."""
    img = Image.new('RGBA', (w, h), (74, 78, 68, 255))
    d = ImageDraw.Draw(img)
    for x in range(3, w, 6):
        for y in range(3, h, 6):
            d.ellipse([x - 1, y - 1, x, y], fill=(38, 40, 36, 255))
    steel, handle, red = (196, 200, 204, 255), (150, 100, 56, 255), (196, 50, 40, 255)
    paint = (104, 110, 96, 255)

    def outline(shape):  # the painted outline behind a tool
        shape(paint, 2)
    # hammers
    for x0 in (10, 150):
        d.rectangle([x0 + 6, 16, x0 + 9, 52], fill=handle)
        d.rectangle([x0, 10, x0 + 18, 18], fill=steel)
    # wrenches of several sizes
    for i, x0 in enumerate((36, 46, 56, 66)):
        L = 40 - i * 4
        d.rectangle([x0, 14, x0 + 3, 14 + L], fill=steel)
        d.ellipse([x0 - 3, 6, x0 + 6, 16], fill=steel)
        d.rectangle([x0, 6, x0 + 3, 12], fill=(74, 78, 68, 255))
    # pliers and cutters
    for x0, col in ((84, red), (104, (224, 170, 40, 255)), (122, red)):
        d.polygon([(x0, 12), (x0 + 5, 12), (x0 + 8, 30), (x0 + 2, 30)], fill=col)
        d.polygon([(x0 + 10, 12), (x0 + 15, 12), (x0 + 12, 30), (x0 + 6, 30)], fill=col)
        d.polygon([(x0 + 2, 30), (x0 + 12, 30), (x0 + 10, 44), (x0 + 4, 44)], fill=steel)
    # a handsaw
    d.polygon([(170, 14), (214, 14), (214, 34), (170, 34)], fill=steel)
    for x in range(170, 214, 3):
        d.polygon([(x, 34), (x + 1.5, 38), (x + 3, 34)], fill=steel)
    d.rectangle([214, 16, 226, 32], fill=handle)
    # a row of screwdrivers and files
    for i, x0 in enumerate(range(232, 254, 5)):
        d.rectangle([x0, 24, x0 + 2, 46], fill=steel)
        d.rectangle([x0 - 1, 8, x0 + 3, 24], fill=(224, 170, 40, 255) if i % 2 else red)
    return img


def warning_sign(size=48):
    """A yellow warning triangle with a black border and its mark: a hand caught between two blades."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pts = [(size / 2, 2), (size - 2, size - 4), (2, size - 4)]
    d.polygon(pts, fill=(28, 28, 26, 255))
    inset = [(size / 2, 8), (size - 8, size - 7), (8, size - 7)]
    d.polygon(inset, fill=(226, 188, 40, 255))
    c = size / 2
    d.polygon([(c - 7, size - 12), (c - 1, size - 26), (c + 1, size - 26), (c - 3, size - 12)], fill=(28, 28, 26, 255))
    d.polygon([(c + 7, size - 12), (c + 1, size - 26), (c + 3, size - 26), (c + 3, size - 12)], fill=(28, 28, 26, 255))
    d.ellipse([c - 4, size - 33, c + 4, size - 25], fill=(28, 28, 26, 255))
    return img


def shred_bench(turns):
    """The shred bench: a long steel workbench (2 x 1) with a plank top, a shadow board of tools behind, a big vise at
    one end, a teardown in the middle (a radio chassis opened up, a tray of small parts), a drawer unit at the other
    end and a scrap bin and a parts box on the lower shelf; a task lamp on an arm."""
    s = Scene(turns, foot=(2, 1))
    glows = []
    x0, x1, y0, y1 = 0.06, 1.94, 0.24, 0.80
    zt = 0.52
    # legs and frame
    for lx in (x0 + 0.02, 0.98, x1 - 0.06):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx, ly, 0.0, lx + 0.045, ly + 0.045, zt, OD_DARK, shine=0.1)
    s.box(x0, y0, zt, x1, y1, zt + 0.05, OD_DARK)
    s.box(x0 - 0.01, y0 - 0.01, zt + 0.05, x1 + 0.01, y1 + 0.01, zt + 0.08, WOOD, top=WOOD)
    flat_decal(s, x0 - 0.01, y0 - 0.01, x1 + 0.01, y1 + 0.01, zt + 0.08, plank_lines(300, 70, 3, WOOD, lines=5, spread=12))
    front_decal(s, x0 - 0.01, x1 + 0.01, zt + 0.05, zt + 0.08, y1 + 0.01, plank_lines(300, 8, 4, WOOD_DARK, lines=1))
    # the lower shelf with the scrap bin and a box of parts
    s.box(x0 + 0.03, y0 + 0.03, 0.14, 1.28, y1 - 0.03, 0.17, OD_DARK, top=OD)
    s.box(0.16, 0.34, 0.17, 0.52, 0.72, 0.38, GRAPHITE_DARK, top=GRAPHITE, shine=0.1)
    s.box(0.17, 0.35, 0.36, 0.51, 0.71, 0.38, (20, 20, 20))
    rn = random.Random(8)
    for i in range(9):
        bx, by = 0.2 + rn.random() * 0.26, 0.38 + rn.random() * 0.28
        s.box(bx, by, 0.36, bx + 0.05, by + 0.03, 0.40 + rn.random() * 0.03,
              rn.choice([(150, 70, 40), (120, 124, 128), (70, 100, 150), (190, 170, 120)]))
    s.box(0.66, 0.34, 0.17, 1.0, 0.7, 0.33, OD, top=OD_LIGHT)
    front_decal(s, 0.72, 0.94, 0.2, 0.3, 0.701, stencil_text('PARTS', 44, 14, STENCIL))
    # the drawer unit under the east end
    s.box(1.34, y0 + 0.03, 0.02, x1 - 0.03, y1 - 0.03, zt, OD, top=OD_LIGHT, shine=0.1)
    for i in range(3):
        z0 = 0.06 + i * 0.14
        s.box(1.37, y1 - 0.03, z0, x1 - 0.06, y1 - 0.016, z0 + 0.12, OD_LIGHT, shine=0.1)
        s.box(1.55, y1 - 0.016, z0 + 0.05, 1.76, y1 - 0.002, z0 + 0.075, STEEL, shine=0.6)
    front_decal(s, 1.4, 1.86, 0.43, 0.5, y1 - 0.016, stencil_text('TEARDOWN', 90, 14, STENCIL))
    # the shadow board and its rail
    s.box(x0, y0, zt + 0.08, x1, y0 + 0.02, zt + 0.62, OD_DARK)
    front_decal(s, x0 + 0.02, x1 - 0.02, zt + 0.12, zt + 0.60, y0 + 0.02, board_image())
    s.box(x0, y0 + 0.02, zt + 0.62, x1, y0 + 0.05, zt + 0.645, STEEL_DARK, shine=0.3)
    # the board's back: its frame of studs and rails, a clipboard of the day's teardowns, a coiled cord on a hook
    b = y0 - 0.014
    for sx in (x0 + 0.02, 0.98, x1 - 0.05):
        s.box(sx, b, zt + 0.08, sx + 0.04, y0, zt + 0.62, OD, top=OD_LIGHT)
    for rz in (zt + 0.14, zt + 0.56):
        s.box(x0 + 0.02, b, rz, x1 - 0.02, y0, rz + 0.035, OD, top=OD_LIGHT)
    s.box(0.36, b - 0.012, zt + 0.2, 0.62, b, zt + 0.5, (120, 92, 60), shine=0.2)
    sheet = Image.new('RGBA', (52, 64), (226, 222, 204, 255))
    sd = ImageDraw.Draw(sheet)
    for k in range(6):
        sd.line([(6, 10 + k * 9), (44, 10 + k * 9)], fill=(90, 90, 96, 255), width=2)
        sd.rectangle([2, 8 + k * 9, 5, 12 + k * 9], outline=(60, 60, 64, 255))
    back_decal(s, 0.38, 0.60, zt + 0.22, zt + 0.46, b - 0.012, sheet)
    s.box(0.44, b - 0.02, zt + 0.46, 0.54, b - 0.012, zt + 0.5, STEEL, shine=0.6)
    s.tube((1.5, b, zt + 0.48), (1.5, b - 0.06, zt + 0.48), 0.01, STEEL, segments=8, shine=0.6)
    for k in range(3):
        s.tube((1.42 + k * 0.012, b - 0.05, zt + 0.47), (1.42 + k * 0.012, b - 0.05, zt + 0.25 + k * 0.02), 0.018,
               (196, 110, 30), segments=10, shine=0.3)
    s.tube((1.42, b - 0.05, zt + 0.47), (1.58, b - 0.05, zt + 0.47), 0.018, (196, 110, 30), segments=10, shine=0.3)
    back_decal(s, 1.0, 1.34, zt + 0.3, zt + 0.4, b, stencil_text('OAK-D1', 70, 18, STENCIL))
    # shelf with tins on the board
    s.box(0.50, y0 + 0.02, zt + 0.35, 1.18, y0 + 0.12, zt + 0.37, WOOD_DARK)
    for i, c in enumerate(((176, 70, 56), (200, 190, 150), (72, 110, 160), (150, 140, 120))):
        s.tube((0.58 + i * 0.16, y0 + 0.07, zt + 0.37), (0.58 + i * 0.16, y0 + 0.07, zt + 0.45), 0.04, c, cap=STEEL, shine=0.4, segments=14)
    # a task lamp on an arm from the board
    s.tube((1.62, y0 + 0.06, zt + 0.35), (1.62, y0 + 0.06, zt + 0.55), 0.008, STEEL_DARK, segments=8)
    s.tube((1.62, y0 + 0.06, zt + 0.55), (1.46, y0 + 0.2, zt + 0.55), 0.008, STEEL_DARK, segments=8)
    s.tube((1.46, y0 + 0.2, zt + 0.56), (1.46, y0 + 0.2, zt + 0.42), 0.055, OD_DARK, r2=0.024, cap=(250, 232, 190), segments=16, shine=0.3)
    # the vise at the west end, a big cast iron one
    s.box(0.10, 0.44, zt + 0.08, 0.30, 0.66, zt + 0.17, GRAPHITE_DARK, top=GRAPHITE, shine=0.3)
    s.box(0.06, 0.47, zt + 0.12, 0.10, 0.63, zt + 0.19, GRAPHITE, shine=0.3)
    s.tube((0.02, 0.55, zt + 0.14), (0.10, 0.55, zt + 0.14), 0.014, STEEL, shine=0.6, segments=8)
    s.tube((0.015, 0.45, zt + 0.14), (0.015, 0.65, zt + 0.14), 0.01, STEEL, shine=0.6, segments=8)
    s.box(0.30, 0.46, zt + 0.12, 0.34, 0.64, zt + 0.19, GRAPHITE, shine=0.3)
    # the teardown: a radio chassis laid open, a tray of parts, a coil of wire
    s.box(0.52, 0.42, zt + 0.08, 0.92, 0.70, zt + 0.15, OD_DARK, top=OD, shine=0.15)
    s.box(0.55, 0.45, zt + 0.15, 0.89, 0.67, zt + 0.16, (40, 90, 52))
    for i in range(7):
        bx, by = 0.58 + rn.random() * 0.26, 0.47 + rn.random() * 0.16
        s.box(bx, by, zt + 0.16, bx + 0.03, by + 0.025, zt + 0.19, rn.choice([(30, 30, 32), (170, 60, 40), (200, 170, 70)]))
    s.tube((0.76, 0.52, zt + 0.16), (0.76, 0.52, zt + 0.22), 0.025, STEEL, segments=10, shine=0.6)
    s.box(1.02, 0.42, zt + 0.08, 1.26, 0.64, zt + 0.11, GRAPHITE_DARK)
    s.box(1.025, 0.425, zt + 0.11, 1.255, 0.635, zt + 0.113, (24, 24, 24))
    for i in range(12):
        bx, by = 1.05 + rn.random() * 0.18, 0.45 + rn.random() * 0.16
        s.tube((bx, by, zt + 0.113), (bx, by, zt + 0.128), 0.012, rn.choice([BRASS, STEEL, (150, 70, 40)]), shine=0.5, segments=8)
    s.tube((1.4, 0.55, zt + 0.08), (1.4, 0.55, zt + 0.14), 0.07, (176, 80, 48), cap=(176, 80, 48), segments=18)
    s.tube((1.4, 0.55, zt + 0.14), (1.4, 0.55, zt + 0.155), 0.05, (60, 30, 20), segments=18)
    # a hammer and a hacksaw lying on the top, a pair of snips
    s.tube((1.55, 0.44, zt + 0.095), (1.82, 0.5, zt + 0.095), 0.011, WOOD_DARK, segments=8)
    s.box(1.78, 0.45, zt + 0.08, 1.88, 0.56, zt + 0.12, STEEL, shine=0.5)
    s.box(1.5, 0.68, zt + 0.08, 1.86, 0.70, zt + 0.125, STEEL, shine=0.5)
    s.box(1.84, 0.67, zt + 0.08, 1.92, 0.72, zt + 0.135, RED)
    front_decal(s, x0 + 0.02, x0 + 0.5, zt + 0.0, zt + 0.05, y1, stencil_text('OAK-D1', 80, 16, STENCIL))
    ground = shadow((1.0, 0.52), 1.0, 0.36, 120)
    return compose(s, ground=ground, seed=100 + turns, glows=glows)


def conveyor_belt_image(running, w=200, h=48, phase=0):
    img = Image.new('RGBA', (w, h), (36, 36, 38, 255))
    d = ImageDraw.Draw(img)
    for x in range(phase % 16, w, 16):
        d.rectangle([x, 0, x + 1, h], fill=(58, 58, 60, 255))
    if running:
        rn = random.Random(4)
        for _ in range(26):
            x, y = rn.randint(2, w - 12), rn.randint(2, h - 8)
            d.rectangle([x, y, x + rn.randint(3, 8), y + rn.randint(2, 5)],
                        fill=rn.choice([(170, 160, 130, 255), (150, 70, 50, 255), (70, 100, 150, 255), (200, 190, 170, 255), (120, 124, 128, 255)]))
    return img


def bulk_shredder(turns, look):
    """The bulk shredder (2 x 1): an olive cabinet with a motor on its front and a funnel hopper with a yellow-black
    rim over twin shafts, a discharge chute on its east side onto a belt conveyor that runs on to a collecting bin; a
    control box with lamps, a stop button and a beacon on a post. On: the green lamp and the beacon are lit. Running:
    shredded pieces ride the belt and fill the bin as well.
    look: 0 stopped (switched off or no power: the red lamp), 2 ready (switched on and waiting: the green lamp, nothing
    moves), 1 running (working)."""
    running, on = look == 1, look >= 1
    s = Scene(turns, foot=(2, 1))
    glows = []
    # the hopper's rim stands out 0.02 past the cabinet: the cabinet ends at 0.95 so that the whole hopper is on the
    # input square (a pixel goes to the square its point stands on; at x 1.0 the rim was the output square's)
    x0, x1, y0, y1 = 0.10, 0.95, 0.12, 0.70
    zb = 0.50
    s.box(x0 - 0.03, y0 - 0.03, 0.0, x1 + 0.03, y1 + 0.03, 0.07, GRAPHITE_DARK)
    s.box(x0, y0, 0.07, x1, y1, zb, OD, top=OD_LIGHT, shine=0.1)
    s.box(x0 - 0.004, y0 - 0.004, 0.07, x1 + 0.004, y1 + 0.004, 0.10, OD_DARK)
    s.box(x0 - 0.004, y0 - 0.004, zb - 0.03, x1 + 0.004, y1 + 0.004, zb, OD_DARK)
    for i in range(5):
        s.box(x0 + 0.08 + i * 0.17, y1, 0.14, x0 + 0.095 + i * 0.17, y1 + 0.006, 0.44, OD_DARK)
    # the hopper
    zh = 0.98
    top = [(x0 - 0.02, y0 - 0.03, zh), (x1 + 0.02, y0 - 0.03, zh), (x1 + 0.02, y1 + 0.04, zh), (x0 - 0.02, y1 + 0.04, zh)]
    low = [(x0 + 0.1, y0 + 0.1, zb), (x1 - 0.1, y0 + 0.1, zb), (x1 - 0.1, y1 - 0.1, zb), (x0 + 0.1, y1 - 0.1, zb)]
    cx_, cy_ = (x0 + x1) / 2, (y0 + y1) / 2
    for i in range(4):
        j = (i + 1) % 4
        mid = ((top[i][0] + top[j][0]) / 2, (top[i][1] + top[j][1]) / 2)
        out = unit((mid[0] - cx_, mid[1] - cy_, 0.0))
        double_poly(s, [low[i], low[j], top[j], top[i]], OD, (58, 62, 50), (out[0], out[1], 0.3), shine=0.1)
    s.box(low[0][0], low[0][1], zb - 0.001, low[2][0], low[2][1], zb + 0.0005, (14, 14, 14))
    # two shafts of hooked cutter discs in the throat, turning toward each other, and wear on the walls above them
    for i in range(2):
        y = 0.34 + i * 0.16
        s.tube((x0 + 0.12, y, zb + 0.1), (x1 - 0.12, y, zb + 0.1), 0.03, STEEL_DARK, shine=0.4, segments=12)
        for k in range(9):
            xx = x0 + 0.15 + k * 0.08 + i * 0.04
            s.tube((xx, y, zb + 0.1), (xx + 0.035, y, zb + 0.1), 0.085, STEEL, cap=(150, 154, 158), shine=0.7, segments=8)
    rim_h = 0.09
    for i in range(4):
        j = (i + 1) % 4
        p0, p1 = top[i], top[j]
        out = unit(((p0[0] + p1[0]) / 2 - cx_, (p0[1] + p1[1]) / 2 - cy_, 0.0))
        double_poly(s, [(p0[0], p0[1], zh - rim_h), (p1[0], p1[1], zh - rim_h), (p1[0], p1[1], zh + 0.012), (p0[0], p0[1], zh + 0.012)],
                    YELLOW, (44, 44, 40), out)
    front_decal(s, top[0][0], top[1][0], zh - rim_h, zh + 0.012, top[2][1] + 0.002, hazard_strip(220, 18, YELLOW, (30, 30, 28), 9))
    s.poly([(top[1][0], top[1][1], zh - rim_h), (top[2][0], top[2][1], zh - rim_h), (top[2][0], top[2][1], zh + 0.012),
            (top[1][0], top[1][1], zh + 0.012)], YELLOW, (1, 0, 0))
    # ladder rungs up the hopper's front for the loader
    # the motor on the cabinet's front: a finned drum on a bed, a belt guard
    s.box(0.22, y1 + 0.0, 0.07, 0.78, y1 + 0.2, 0.12, GRAPHITE_DARK)
    s.tube((0.28, y1 + 0.12, 0.25), (0.62, y1 + 0.12, 0.25), 0.11, BLUE, cap=(44, 62, 88), segments=32, shine=0.2,
           bands=[(0.0, 0.06, (44, 62, 88))] + [(0.09 + 0.12 * i, 0.17 + 0.12 * i, (54, 76, 102)) for i in range(7)])
    s.tube((0.62, y1 + 0.12, 0.25), (0.72, y1 + 0.12, 0.25), 0.04, STEEL, shine=0.7, segments=12)
    s.box(0.72, y1 + 0.04, 0.12, 0.80, y1 + 0.2, 0.40, GRAPHITE_DARK, shine=0.2)
    s.box(0.40, y1 + 0.06, 0.36, 0.52, y1 + 0.18, 0.43, (44, 62, 88), top=BLUE)
    s.box(0.28, y1, 0.2, 0.7, y1 + 0.02, 0.42, OD_DARK)
    # the discharge chute on the east side and the belt conveyor
    s.poly([(x1, 0.28, 0.34), (x1, 0.54, 0.34), (1.14, 0.54, 0.26), (1.14, 0.28, 0.26)], GRAPHITE_DARK, (0.3, 0, 1), shine=0.2)
    s.box(x1, 0.26, 0.2, x1 + 0.03, 0.56, 0.36, GRAPHITE_DARK)
    bz = 0.30
    for lx in (1.16, 1.5, 1.72):
        for ly in (0.2, 0.62):
            s.box(lx, ly, 0.0, lx + 0.04, ly + 0.04, bz, GRAPHITE_DARK, shine=0.1)
    s.box(1.1, 0.2, bz - 0.04, 1.84, 0.26, bz + 0.07, GRAPHITE, top=GRAPHITE_LIGHT, shine=0.2)
    s.box(1.1, 0.58, bz - 0.04, 1.84, 0.64, bz + 0.07, GRAPHITE, top=GRAPHITE_LIGHT, shine=0.2)
    s.box(1.1, 0.26, bz - 0.01, 1.84, 0.58, bz + 0.01, (36, 36, 38))
    front_decal(s, 1.1, 1.84, bz - 0.04, bz + 0.07, 0.64 + 0.001, hazard_strip(180, 14, YELLOW, (30, 30, 28), 8))
    flat_decal(s, 1.12, 0.265, 1.82, 0.575, bz + 0.012, conveyor_belt_image(running), offset=0.0)
    s.tube((1.12, 0.26, bz + 0.03), (1.12, 0.58, bz + 0.03), 0.045, STEEL_DARK, shine=0.4, segments=12)
    s.tube((1.82, 0.26, bz + 0.03), (1.82, 0.58, bz + 0.03), 0.045, STEEL_DARK, shine=0.4, segments=12)
    # the bin at the end of the belt
    s.box(1.58, 0.14, 0.0, 1.96, 0.72, 0.30, GRAPHITE_LIGHT, top=GRAPHITE, shine=0.1)
    s.box(1.60, 0.16, 0.24, 1.94, 0.70, 0.301, (20, 20, 20))
    front_decal(s, 1.62, 1.92, 0.04, 0.2, 0.721, stencil_text('OAK-S', 60, 24, STENCIL))
    if running:
        rn = random.Random(3)
        s.box(1.62, 0.18, 0.24, 1.92, 0.68, 0.27, (60, 56, 50))
        for i in range(48):
            px, py = 1.63 + rn.random() * 0.26, 0.2 + rn.random() * 0.44
            s.box(px, py, 0.26 + rn.random() * 0.02, px + 0.03 + rn.random() * 0.03, py + 0.025 + rn.random() * 0.025,
                  0.29 + rn.random() * 0.03, rn.choice([(170, 160, 130), (150, 70, 50), (70, 100, 150), (200, 190, 170), (120, 124, 128), (90, 130, 80)]))
    # the control box at the cabinet's west front, lamps and the stop button
    s.box(0.14, y1, 0.22, 0.24, y1 + 0.05, 0.44, GRAPHITE_DARK, top=GRAPHITE, shine=0.2)
    lamp_y(s, glows, 0.165, y1 + 0.05, 0.39, 0.022, 'green', on)
    lamp_y(s, glows, 0.215, y1 + 0.05, 0.39, 0.022, 'red', not on)
    s.tube((0.19, y1 + 0.05, 0.29), (0.19, y1 + 0.085, 0.29), 0.026, YELLOW, segments=16)
    s.tube((0.19, y1 + 0.085, 0.29), (0.19, y1 + 0.102, 0.29), 0.022, RED, cap=(220, 70, 56), segments=16, shine=0.3)
    # the beacon on a post at the hopper's north-west corner
    bx_, by_ = x0 + 0.0, y0 - 0.02
    s.tube((bx_, by_, zh), (bx_, by_, zh + 0.3), 0.009, STEEL_DARK, segments=8)
    s.tube((bx_, by_, zh + 0.3), (bx_, by_, zh + 0.32), 0.03, BEZEL, segments=14)
    if on:
        s.tube((bx_, by_, zh + 0.32), (bx_, by_, zh + 0.38), 0.026, LIT['amber'], cap=(255, 240, 200), segments=14, emit=True)
        glows.append(((bx_, by_, zh + 0.36), LIT['amber'], 0.2))
    else:
        s.tube((bx_, by_, zh + 0.32), (bx_, by_, zh + 0.38), 0.026, UNLIT['amber'], segments=14, shine=0.8)
    front_decal(s, 0.30, 0.78, 0.16, 0.30, y1 + 0.001, stencil_text('SHREDDER', 100, 22, STENCIL))
    front_decal(s, 0.84, 0.96, 0.18, 0.40, y1 + 0.001, acorn_mark(26, STENCIL))
    ground = shadow((1.0, 0.45), 1.0, 0.4, 125)
    return compose(s, ground=ground, seed=110 + turns + 4 * int(look), glows=glows)


def cutter(turns, look):
    """The cutter (2 x 1): a long cutting table with a green grid mat, a roll of canvas on arms at its west end, a
    gantry with a blade carriage over the mat, a vacuum blower under the table and a cart of cut pieces at the east end.
    Stopped: the carriage waits at the west and the cloth is whole. Running: the carriage is mid-table with its lamp
    lit, the cloth behind it is cut and the first pieces lie stacked on the cart. The lamps say on (green) or off (red).
    look: 0 stopped (switched off or no power: the red lamp), 2 ready (switched on and waiting: the green lamp, nothing
    moves), 1 running (working)."""
    running, on = look == 1, look >= 1
    s = Scene(turns, foot=(2, 1))
    glows = []
    x0, x1, y0, y1 = 0.20, 1.92, 0.22, 0.78
    zt = 0.50
    for lx in (x0 + 0.02, 0.98, x1 - 0.06):
        for ly in (y0 + 0.02, y1 - 0.06):
            s.box(lx, ly, 0.0, lx + 0.045, ly + 0.045, zt, GRAPHITE_DARK, shine=0.2)
    s.box(x0, y0, 0.12, x1, y1, 0.14, GRAPHITE_DARK)
    s.box(x0, y0, zt, x1, y1, zt + 0.05, OD_DARK)
    s.box(x0 + 0.015, y0 + 0.015, zt + 0.05, x1 - 0.015, y1 - 0.015, zt + 0.06, (30, 60, 44))
    flat_decal(s, x0 + 0.015, y0 + 0.015, x1 - 0.015, y1 - 0.015, zt + 0.06, cutting_mat_image(300, 90), offset=0.001)
    # the vacuum blower under the table: a blue motor and its hose up to the table
    s.tube((0.50, 0.50, 0.24), (0.86, 0.50, 0.24), 0.13, BLUE, cap=(44, 62, 88), segments=28, shine=0.2,
           bands=[(0, 0.06, (44, 62, 88))] + [(0.1 + 0.11 * i, 0.17 + 0.11 * i, (54, 76, 102)) for i in range(8)])
    s.box(0.44, 0.38, 0.14, 0.92, 0.62, 0.17, GRAPHITE_DARK)
    s.tube((0.86, 0.5, 0.24), (0.96, 0.5, 0.24), 0.05, STEEL_DARK, segments=14, shine=0.4)
    # spare rolls on a rack under the east half
    for i, c in enumerate(((176, 70, 56), (72, 110, 160), (200, 190, 150))):
        s.tube((1.2 + i * 0.2, y0 + 0.04, 0.24), (1.2 + i * 0.2, y1 - 0.04, 0.24), 0.07, c, cap=(220, 214, 190), segments=18)
    # the roll of canvas on two arms at the west end
    s.box(0.06, y0 - 0.02, 0.0, 0.16, y0 + 0.04, 0.84, GRAPHITE_DARK)
    s.box(0.06, y1 - 0.04, 0.0, 0.16, y1 + 0.02, 0.84, GRAPHITE_DARK)
    s.tube((0.11, y0, 0.70), (0.11, y1, 0.70), 0.016, STEEL, shine=0.6, segments=10)
    s.tube((0.11, y0 + 0.05, 0.70), (0.11, y1 - 0.05, 0.70), 0.15, CANVAS, cap=(210, 200, 170), segments=28,
           bands=[(0, 0.06, (110, 104, 80))] + [(0.06 + 0.06 * i, 0.09 + 0.06 * i, (170, 160, 122)) for i in range(15)])
    cloth_z = zt + 0.065
    gx = 1.30 if running else 0.52
    s.poly([(0.20, y0 + 0.04, 0.66), (0.34, y0 + 0.04, cloth_z), (0.34, y1 - 0.04, cloth_z), (0.20, y1 - 0.04, 0.66)], CANVAS, (0, 0, 1))
    s.face([(0.34, y0 + 0.04, cloth_z), (1.66, y0 + 0.04, cloth_z), (1.66, y1 - 0.04, cloth_z), (0.34, y1 - 0.04, cloth_z)], CANVAS, (0, 0, 1))
    if running:
        s.face([(0.34, 0.49, cloth_z + 0.001), (gx, 0.49, cloth_z + 0.001), (gx, 0.51, cloth_z + 0.001), (0.34, 0.51, cloth_z + 0.001)], (36, 70, 52), (0, 0, 1))
        s.box(gx + 0.14, y0 + 0.04, cloth_z, gx + 0.22, y1 - 0.04, cloth_z + 0.004, (190, 70, 56))
    # the gantry: two posts, a cross beam, a rail, the carriage with its knife
    for yy in (y0 - 0.04, y1 + 0.0):
        s.box(gx - 0.035, yy, zt + 0.02, gx + 0.035, yy + 0.04, 0.84, OD, top=OD_LIGHT, shine=0.1)
    s.box(gx - 0.045, y0 - 0.04, 0.78, gx + 0.045, y1 + 0.04, 0.86, OD, top=OD_LIGHT, shine=0.1)
    s.tube((gx, y0 - 0.02, 0.75), (gx, y1 + 0.02, 0.75), 0.013, STEEL, shine=0.6, segments=8)
    cy = 0.50 if running else 0.34
    s.box(gx - 0.06, cy - 0.07, 0.62, gx + 0.06, cy + 0.07, 0.78, GRAPHITE_DARK, top=GRAPHITE, shine=0.2)
    s.box(gx - 0.014, cy - 0.018, cloth_z, gx + 0.014, cy + 0.018, 0.62, STEEL, shine=0.7)
    s.poly([(gx - 0.014, cy + 0.019, cloth_z), (gx + 0.014, cy + 0.019, cloth_z), (gx + 0.014, cy + 0.019, 0.60), (gx - 0.014, cy + 0.019, 0.60)], (220, 224, 226), (0, 1, 0), shine=0.8)
    lamp_y(s, glows, gx, cy + 0.07, 0.73, 0.018, 'green', on)
    lamp_y(s, glows, gx, cy + 0.07, 0.67, 0.013, 'amber', False)
    # the cart of cut pieces at the east end
    s.box(1.68, 0.2, 0.08, 1.98, 0.8, 0.12, GRAPHITE_DARK)
    for cx_ in (1.72, 1.94):
        for cy2 in (0.22, 0.76):
            s.tube((cx_, cy2 - 0.01, 0.04), (cx_, cy2 + 0.01, 0.04), 0.04, RUBBER, segments=12)
    if running:
        for i in range(4):
            s.box(1.72, 0.24, 0.12 + i * 0.045, 1.94, 0.76, 0.155 + i * 0.045,
                  (190, 70, 56) if i % 2 else CANVAS, top=(210, 100, 80) if i % 2 else (176, 166, 128))
    # a control pedestal at the east end of the table's front
    s.box(1.5, y1, 0.0, 1.62, y1 + 0.12, 0.60, OD, top=OD_LIGHT, shine=0.1)
    lamp_y(s, glows, 1.56, y1 + 0.12, 0.52, 0.024, 'green', on)
    lamp_y(s, glows, 1.56, y1 + 0.12, 0.44, 0.024, 'red', not on)
    s.box(1.51, y1 + 0.12, 0.26, 1.61, y1 + 0.124, 0.38, GRAPHITE_DARK)
    front_decal(s, 0.62, 0.98, 0.22, 0.32, y1 + 0.001, stencil_text('OAK-C1', 70, 20, STENCIL))
    front_decal(s, 1.08, 1.22, 0.2, 0.34, y1 + 0.002, warning_sign())
    ground = shadow((1.0, 0.5), 1.0, 0.36, 120)
    return compose(s, ground=ground, seed=120 + turns + 4 * int(look), glows=glows)
