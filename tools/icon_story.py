"""The story package's item icons (32x32): the mission props, the evidence and records, the documents of the story.
Drawn like the other icons (tools/icon_art.py): a few solids, shaded, fitted and outlined; 1993 paper and field gear
(manila, kraft, carbon copy, ledgers, a cassette, a handheld field radio). icon_art passes itself in, so the helpers
(from_scene, paper_image, pictogram) are shared: pictures(icon_art) -> {key: function returning the icon}."""
import math
import random

from PIL import Image, ImageDraw

from tile_engine import Scene, rotation, stencil_text, acorn_mark
from tile_objects import (OD, OD_DARK, OD_LIGHT, TAN, BLACK, RUBBER, GREY, STEEL, STEEL_DARK, WHITE, STENCIL, YELLOW,
                          RED, BRASS, WOOD, WOOD_DARK, BLUE, flat_decal, front_decal, noise_texture)

PAPER = (232, 228, 208)
PAPER_OLD = (214, 202, 160)
MANILA = (206, 176, 116)
MANILA_DARK = (178, 148, 92)
KRAFT = (168, 128, 82)
CARBON = (150, 176, 214)
INK = (40, 44, 48, 255)
PENCIL = (96, 98, 100, 255)
RED_INK = (184, 44, 36, 255)


def lying(turn=-34):
    s = Scene(0)
    s.tilt = (rotation((1, 0, 0), turn), (0.5, 0.5, 0.1))
    return s


def lines_image(w, h, rows, colour=INK, seed=1, gap=None, left=4, right=4, top=5, numbers=False, head=None):
    """A sheet of writing: rows of ruled text lines of different lengths (a column of numbers at the right on request)."""
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rnd = random.Random(seed)
    gap = gap or max(3, (h - top - 4) // max(1, rows))
    if head:
        d.rectangle([left, top, w - right, top + 3], fill=head)
        top += 7
    for i in range(rows):
        y = top + i * gap
        if y > h - 3:
            break
        end = rnd.randint(w // 2, w - right - (12 if numbers else 0))
        d.line([(left, y), (end, y)], fill=colour, width=1)
        if numbers:
            d.line([(w - right - 9, y), (w - right - 2, y)], fill=colour, width=2)
    return img


def sheet(s, x0, y0, x1, y1, z, thickness=0.012, colour=PAPER, image=None):
    s.box(x0, y0, z, x1, y1, z + thickness, colour)
    if image is not None:
        flat_decal(s, x0, y0, x1, y1, z + thickness + 0.0005, image, offset=0.0)


# --------------------------------------------------------------------------------------------------------------
# Mission props.

def mission_envelope(I):
    s = lying()
    s.box(0.1, 0.22, 0.0, 0.9, 0.78, 0.05, MANILA_DARK, top=MANILA, shine=0.05)
    img = Image.new('RGBA', (80, 56), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.line([(0, 0), (40, 28), (80, 0)], fill=(120, 92, 52, 255), width=2)
    d.line([(0, 56), (30, 26)], fill=(150, 120, 74, 255), width=1)
    d.line([(80, 56), (50, 26)], fill=(150, 120, 74, 255), width=1)
    d.ellipse([31, 20, 49, 38], fill=RED_INK)
    d.ellipse([35, 24, 45, 34], outline=(120, 24, 20, 255), width=1)
    flat_decal(s, 0.1, 0.22, 0.9, 0.78, 0.0505, img, offset=0.0)
    return I.from_scene(s)


def mission_sample_tin(I):
    s = Scene(0)
    s.tube((0.5, 0.5, 0.0), (0.5, 0.5, 0.26), 0.3, (186, 188, 186), segments=24, shine=0.6)
    s.tube((0.5, 0.5, 0.26), (0.5, 0.5, 0.31), 0.32, (206, 208, 206), segments=24, shine=0.7)
    s.tube((0.5, 0.5, 0.0), (0.5, 0.5, 0.06), 0.31, (150, 152, 152), segments=24, shine=0.4)
    # the numbered tag tied to the lid
    s.tube((0.76, 0.6, 0.31), (0.88, 0.7, 0.2), 0.012, TAN, segments=6)
    s.box(0.78, 0.66, 0.1, 0.96, 0.8, 0.22, (236, 232, 210))
    front_decal(s, 0.8, 0.94, 0.13, 0.2, 0.801, stencil_text('17', 24, 14, INK[:3]), offset=0.0)
    flat_decal(s, 0.32, 0.32, 0.68, 0.68, 0.312, stencil_text('SMP', 40, 16, (120, 40, 30)), offset=0.0)
    return I.from_scene(s)


def mission_logbook(I):
    s = lying(-30)
    s.box(0.14, 0.12, 0.0, 0.86, 0.88, 0.1, (46, 74, 62), top=(60, 92, 78), shine=0.05)
    s.box(0.18, 0.15, 0.1, 0.84, 0.86, 0.15, PAPER)
    s.box(0.12, 0.1, 0.15, 0.86, 0.9, 0.2, (46, 74, 62), top=(60, 92, 78), shine=0.05)
    s.box(0.12, 0.1, 0.0, 0.26, 0.9, 0.2, (122, 38, 34), top=(150, 52, 44))
    flat_decal(s, 0.38, 0.22, 0.78, 0.46, 0.201, stencil_text('LOG', 50, 22, STENCIL), offset=0.0)
    flat_decal(s, 0.38, 0.54, 0.74, 0.62, 0.201, lines_image(40, 8, 2, colour=STENCIL + (255,)), offset=0.0)
    # folded corners: pale triangles at the page edge
    for y in (0.3, 0.55, 0.76):
        s.poly([(0.84, y, 0.152), (0.9, y + 0.05, 0.152), (0.84, y + 0.06, 0.152)], (246, 242, 224), (0, 0, 1))
    return I.from_scene(s)


def mission_filter_case(I):
    s = Scene(0)
    s.box(0.12, 0.28, 0.0, 0.88, 0.74, 0.34, (96, 102, 106), top=(124, 130, 134), shine=0.2)
    s.box(0.12, 0.28, 0.2, 0.88, 0.74, 0.215, (60, 64, 68))
    s.box(0.36, 0.2, 0.32, 0.64, 0.28, 0.38, STEEL_DARK)
    for x in (0.22, 0.7):
        s.box(x, 0.74, 0.1, x + 0.08, 0.77, 0.3, STEEL, shine=0.7)
    s.box(0.12, 0.74, 0.0, 0.88, 0.75, 0.05, (60, 64, 68))
    # a white pleated filter label on the lid and the open end
    img = Image.new('RGBA', (60, 28), (236, 232, 214, 255))
    d = ImageDraw.Draw(img)
    for x in range(4, 56, 5):
        d.line([(x, 4), (x + 2, 24)], fill=(120, 126, 130, 255), width=1)
    d.rectangle([0, 0, 59, 27], outline=(70, 74, 78, 255))
    flat_decal(s, 0.34, 0.36, 0.66, 0.66, 0.341, img, offset=0.0)
    return I.from_scene(s)


def mission_tape(I):
    s = lying(-40)
    s.box(0.08, 0.2, 0.0, 0.92, 0.8, 0.13, (44, 46, 48), top=(60, 62, 66), shine=0.3)
    img = Image.new('RGBA', (84, 60), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.polygon([(6, 4), (78, 4), (78, 24), (66, 30), (6, 24)], fill=(232, 228, 208, 255))
    d.polygon([(58, 4), (78, 4), (78, 20), (70, 14)], fill=(60, 62, 66, 0))
    d.line([(10, 10), (50, 10)], fill=INK, width=1)
    d.line([(10, 17), (40, 17)], fill=INK, width=1)
    d.line([(60, 22), (74, 26)], fill=(150, 146, 130, 255), width=1)
    for cx in (22, 62):
        d.ellipse([cx - 11, 36, cx + 11, 58], fill=(236, 234, 226, 255))
        d.ellipse([cx - 6, 41, cx + 6, 53], fill=(30, 30, 32, 255))
        for k in range(6):
            a = k * math.pi / 3
            d.line([(cx, 47), (cx + 5 * math.cos(a), 47 + 5 * math.sin(a))], fill=(236, 234, 226, 255))
    d.rectangle([34, 40, 50, 54], fill=(30, 30, 32, 160))
    flat_decal(s, 0.08, 0.2, 0.92, 0.8, 0.1305, img, offset=0.0)
    return I.from_scene(s)


def mission_fabric_roll(I):
    s = Scene(0)
    colours = ((150, 140, 104), (112, 124, 150), (170, 96, 80), (124, 140, 100), (190, 180, 150), (96, 100, 108))
    bands = [(i / 6, (i + 1) / 6, colours[i]) for i in range(6)]
    s.tube((0.1, 0.5, 0.26), (0.9, 0.5, 0.26), 0.24, (150, 140, 104), segments=24, bands=bands, shine=0.05)
    for x in (0.3, 0.7):
        s.tube((x - 0.02, 0.5, 0.26), (x + 0.02, 0.5, 0.26), 0.255, TAN, segments=24, caps=False)
    s.box(0.84, 0.3, 0.02, 0.96, 0.7, 0.07, (184, 176, 140))
    return I.from_scene(s)


def mission_heavy_case(I):
    s = Scene(0)
    # a tall hard transport case: grey, a seam, two side handles, latches, a yellow band and the weight stencilled
    s.box(0.1, 0.22, 0.0, 0.9, 0.78, 0.5, (88, 94, 98), top=(116, 122, 126), shine=0.2)
    s.box(0.1, 0.22, 0.24, 0.9, 0.78, 0.256, (52, 56, 60))
    s.box(0.03, 0.38, 0.2, 0.1, 0.62, 0.34, STEEL_DARK)
    s.box(0.9, 0.38, 0.2, 0.97, 0.62, 0.34, STEEL_DARK)
    for x in (0.2, 0.7):
        s.box(x, 0.78, 0.2, x + 0.1, 0.8, 0.31, STEEL, shine=0.7)
    s.box(0.1, 0.78, 0.4, 0.9, 0.785, 0.46, YELLOW)
    front_decal(s, 0.34, 0.66, 0.07, 0.19, 0.781, stencil_text('15', 40, 16, STENCIL), offset=0.0)
    return I.from_scene(s)


# --------------------------------------------------------------------------------------------------------------
# Evidence and records.

def evidence_envelope(I):
    s = lying()
    s.box(0.1, 0.18, 0.0, 0.9, 0.82, 0.06, (140, 104, 64), top=KRAFT, shine=0.02)
    img = Image.new('RGBA', (80, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 22, 79, 40], fill=(206, 56, 44, 255))
    for x in range(0, 80, 10):
        d.line([(x, 22), (x + 6, 40)], fill=(236, 226, 206, 255), width=2)
    d.polygon([(0, 0), (80, 0), (80, 8), (40, 18), (0, 8)], fill=(120, 90, 52, 100))
    d.rectangle([6, 46, 36, 60], fill=(236, 232, 210, 255))
    d.line([(9, 51), (32, 51)], fill=INK, width=1)
    d.line([(9, 56), (26, 56)], fill=INK, width=1)
    flat_decal(s, 0.1, 0.18, 0.9, 0.82, 0.0605, img, offset=0.0)
    return I.from_scene(s)


def clinic_record(I):
    s = lying()
    s.box(0.14, 0.1, 0.0, 0.86, 0.9, 0.05, (206, 210, 196), top=(222, 226, 210))
    s.box(0.18, 0.16, 0.05, 0.84, 0.88, 0.1, PAPER)
    s.box(0.14, 0.1, 0.1, 0.86, 0.9, 0.14, (176, 200, 184), top=(196, 218, 202), shine=0.05)
    img = Image.new('RGBA', (64, 72), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([24, 6, 40, 30], fill=RED_INK)
    d.rectangle([14, 14, 50, 22], fill=RED_INK)
    for k in range(5):
        d.line([(6, 40 + k * 6), (54 - k * 3, 40 + k * 6)], fill=(70, 80, 74, 255), width=1)
    d.ellipse([34, 44, 56, 60], fill=(120, 96, 70, 90))   # the smear
    flat_decal(s, 0.14, 0.1, 0.86, 0.9, 0.1405, img, offset=0.0)
    return I.from_scene(s)


def weather_log(I):
    s = lying(-30)
    s.box(0.1, 0.16, 0.0, 0.9, 0.86, 0.08, (92, 112, 134), top=(116, 138, 160), shine=0.05)
    s.box(0.14, 0.2, 0.08, 0.88, 0.84, 0.12, PAPER)
    s.box(0.1, 0.16, 0.12, 0.9, 0.86, 0.17, (92, 112, 134), top=(116, 138, 160), shine=0.05)
    img = Image.new('RGBA', (64, 56), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([8, 18, 30, 40], fill=(236, 236, 226, 255))
    d.ellipse([20, 10, 46, 38], fill=(236, 236, 226, 255))
    d.ellipse([36, 20, 58, 42], fill=(236, 236, 226, 255))
    d.rectangle([12, 32, 54, 42], fill=(236, 236, 226, 255))
    for x in (16, 28, 40):
        d.line([(x, 46), (x - 3, 54)], fill=(40, 52, 70, 255), width=2)
    flat_decal(s, 0.18, 0.24, 0.82, 0.78, 0.1705, img, offset=0.0)
    # the torn-out page: ragged stubs at the spine
    for y in (0.3, 0.4, 0.5, 0.6, 0.7):
        s.box(0.88, y, 0.08, 0.93, y + 0.04, 0.115, (222, 218, 198))
    return I.from_scene(s)


def farm_journal(I):
    s = lying(-30)
    s.box(0.14, 0.12, 0.0, 0.86, 0.88, 0.14, (104, 72, 44), top=(124, 88, 54), shine=0.04)
    s.box(0.18, 0.16, 0.14, 0.84, 0.84, 0.17, PAPER_OLD)
    s.box(0.1, 0.08, 0.17, 0.86, 0.88, 0.22, (104, 72, 44), top=(124, 88, 54), shine=0.04)
    flat_decal(s, 0.1, 0.08, 0.86, 0.88, 0.2205, noise_texture(30, 30, 7, (124, 88, 54), spread=10), offset=0.0)
    # a rubber band round it and a pencil under the band
    s.box(0.58, 0.07, 0.17, 0.64, 0.89, 0.235, (36, 36, 38))
    s.tube((0.2, 0.3, 0.255), (0.82, 0.62, 0.255), 0.022, (230, 190, 52), segments=6, shine=0.3)
    s.tube((0.82, 0.62, 0.255), (0.9, 0.66, 0.255), 0.022, (214, 214, 206), segments=6, shine=0.3)
    flat_decal(s, 0.2, 0.2, 0.52, 0.44, 0.2215, lines_image(40, 30, 4, colour=(70, 52, 34, 255)), offset=0.0)
    return I.from_scene(s)


def sample_cooler(I):
    s = Scene(0)
    s.box(0.1, 0.22, 0.0, 0.9, 0.78, 0.34, (176, 56, 46), top=(196, 70, 58), shine=0.25)
    s.box(0.08, 0.2, 0.34, 0.92, 0.8, 0.46, (232, 230, 220), top=(246, 244, 236), shine=0.3)
    s.box(0.34, 0.44, 0.46, 0.66, 0.56, 0.5, (150, 150, 146), top=(180, 180, 176), shine=0.4)
    s.box(0.04, 0.4, 0.28, 0.1, 0.6, 0.36, (150, 150, 146))
    s.box(0.9, 0.4, 0.28, 0.96, 0.6, 0.36, (150, 150, 146))
    img = Image.new('RGBA', (48, 24), (236, 232, 214, 255))
    d = ImageDraw.Draw(img)
    d.line([(4, 6), (36, 6)], fill=INK, width=1)
    d.line([(4, 12), (28, 12)], fill=INK, width=1)
    d.line([(30, 14), (44, 22)], fill=(226, 220, 200, 255), width=3)   # the scraped corner
    front_decal(s, 0.34, 0.66, 0.1, 0.28, 0.781, img, offset=0.0)
    return I.from_scene(s)


def roster_page(I):
    s = lying()
    s.box(0.18, 0.1, 0.0, 0.84, 0.9, 0.012, PAPER)
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(8, 76, 6):
        d.line([(8, y), (36, y)], fill=INK, width=1)
        d.line([(42, y), (51, y)], fill=(70, 80, 120, 255), width=2)
    d.line([(40, 4), (40, 78)], fill=(190, 80, 70, 255), width=1)
    d.rectangle([10, 1, 36, 4], fill=INK)
    for y in range(8, 76, 14):                       # the torn spiral holes
        d.ellipse([1, y, 5, y + 4], fill=(40, 44, 48, 255))
    flat_decal(s, 0.18, 0.1, 0.84, 0.9, 0.0125, img, offset=0.0)
    for y in (0.16, 0.3, 0.44, 0.58, 0.72, 0.84):
        s.box(0.14, y, 0.0, 0.18, y + 0.03, 0.012, PAPER)
    return I.from_scene(s)


def review_memo(I):
    s = lying()
    s.box(0.16, 0.1, 0.0, 0.84, 0.9, 0.012, (226, 222, 204))
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([6, 5, 30, 10], fill=INK)
    for y in range(18, 74, 6):
        d.line([(6, y), (48 - (y % 12), y)], fill=INK, width=1)
    d.rectangle([34, 12, 52, 20], fill=(246, 244, 236, 255))      # the erased number
    d.line([(6, 30), (50, 62)], fill=(150, 146, 130, 170), width=2)  # the creases
    d.line([(50, 24), (8, 70)], fill=(150, 146, 130, 150), width=2)
    d.line([(4, 44), (52, 40)], fill=(150, 146, 130, 140), width=1)
    flat_decal(s, 0.16, 0.1, 0.84, 0.9, 0.0125, img, offset=0.0)
    return I.from_scene(s)


def ward_record(I):
    s = lying(-30)
    s.box(0.18, 0.1, 0.0, 0.82, 0.9, 0.1, (92, 150, 134), top=(114, 172, 154), shine=0.05)
    s.box(0.2, 0.14, 0.1, 0.8, 0.88, 0.12, PAPER)
    s.box(0.16, 0.1, 0.12, 0.84, 0.9, 0.16, (92, 150, 134), top=(114, 172, 154), shine=0.05)
    img = Image.new('RGBA', (64, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([14, 18, 50, 34], fill=(236, 232, 214, 255))
    d.line([(18, 24), (46, 24)], fill=(60, 80, 70, 255), width=2)
    d.line([(18, 29), (38, 29)], fill=(60, 80, 70, 255), width=1)
    d.ellipse([30, 46, 58, 70], fill=(150, 120, 80, 90))   # a stain, the stuck pages
    flat_decal(s, 0.16, 0.1, 0.84, 0.9, 0.1605, img, offset=0.0)
    for x in (0.26, 0.34, 0.42, 0.5, 0.58, 0.66, 0.74):    # the spiral at the top
        s.tube((x, 0.1, 0.12), (x, 0.1, 0.22), 0.016, STEEL, segments=6, shine=0.6)
    return I.from_scene(s)


def cell_log(I):
    s = lying()
    s.box(0.14, 0.08, 0.0, 0.86, 0.92, 0.05, (44, 46, 50), top=(60, 62, 68), shine=0.1)
    s.box(0.2, 0.16, 0.05, 0.8, 0.88, 0.062, (206, 206, 196))
    img = Image.new('RGBA', (52, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for r_ in range(5):
        for c in range(3):
            x, y = 6 + c * 16, 6 + r_ * 14
            for k in range(4):
                d.line([(x + k * 3, y), (x + k * 3, y + 8)], fill=PENCIL, width=1)
            if r_ % 2 == 0:
                d.line([(x - 1, y + 7), (x + 11, y + 1)], fill=PENCIL, width=1)
    flat_decal(s, 0.2, 0.16, 0.8, 0.88, 0.0625, img, offset=0.0)
    s.box(0.4, 0.04, 0.05, 0.6, 0.14, 0.09, STEEL, top=(196, 200, 204), shine=0.7)
    return I.from_scene(s)


def soil_sample(I):
    s = Scene(0)
    s.tube((0.5, 0.5, 0.0), (0.5, 0.5, 0.3), 0.3, (214, 220, 222), segments=24, shine=0.5, caps=False)
    s.tube((0.5, 0.5, 0.0), (0.5, 0.5, 0.04), 0.29, (170, 176, 178), segments=24)
    s.tube((0.5, 0.5, 0.03), (0.5, 0.5, 0.22), 0.28, (88, 62, 40), segments=24, shine=0.0)
    s.tube((0.5, 0.5, 0.3), (0.5, 0.5, 0.34), 0.32, (232, 236, 238), segments=24, shine=0.5, caps=False)
    s.tube((0.5, 0.5, 0.215), (0.5, 0.5, 0.225), 0.285, (104, 74, 48), segments=24)
    rn = random.Random(3)
    for _ in range(6):
        s.rock((0.3 + rn.random() * 0.4, 0.3 + rn.random() * 0.4, 0.23), 0.03, rn.randint(1, 9), (70, 50, 34), detail=0)
    s.box(0.72, 0.7, 0.04, 0.9, 0.78, 0.24, (236, 232, 210))
    front_decal(s, 0.74, 0.88, 0.1, 0.22, 0.781, stencil_text('09', 24, 14, INK[:3]), offset=0.0)
    return I.from_scene(s)


def stake_tag(I):
    s = lying(-40)
    pts = [(0.3, 0.1), (0.7, 0.1), (0.8, 0.22), (0.8, 0.9), (0.2, 0.9), (0.2, 0.22)]
    I.prism(s, pts, 0.0, 0.025, MANILA_DARK, top=MANILA, shine=0.02)
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([22, 8, 34, 20], fill=(60, 50, 36, 255))
    d.ellipse([25, 11, 31, 17], fill=(0, 0, 0, 0))
    d.ellipse([20, 6, 36, 22], outline=(236, 232, 210, 255), width=2)
    flat_decal(s, 0.2, 0.1, 0.8, 0.9, 0.0255, img, offset=0.0)
    flat_decal(s, 0.3, 0.42, 0.7, 0.7, 0.0256, stencil_text('07', 40, 24, (60, 30, 24)), offset=0.0)
    s.tube((0.5, 0.15, 0.03), (0.5, 0.15, 0.13), 0.012, RED, segments=6)
    s.tube((0.5, 0.15, 0.13), (0.62, 0.05, 0.1), 0.012, RED, segments=6)
    return I.from_scene(s)


def roster_lost_page(I):
    s = lying(-36)
    pts = [(0.16, 0.14), (0.4, 0.1), (0.62, 0.15), (0.84, 0.1), (0.84, 0.9), (0.16, 0.9)]
    I.prism(s, pts, 0.0, 0.014, PAPER_OLD, top=(224, 214, 172))
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(10, 74, 7):
        d.line([(6, y), (30, y)], fill=INK, width=1)
        d.rectangle([36, y - 2, 48, y + 1], outline=(70, 80, 120, 255))
    d.polygon([(40, 78), (56, 78), (56, 62)], fill=(244, 238, 210, 255))
    flat_decal(s, 0.16, 0.1, 0.84, 0.9, 0.0145, img, offset=0.0)
    s.box(0.7, 0.04, 0.0, 0.76, 0.34, 0.03, STEEL, top=(200, 204, 208), shine=0.7)   # a paper clip
    return I.from_scene(s)


def filter_bundle(I):
    s = Scene(0)
    # three pleated panel filters in cardboard frames, stood against each other and tied with twine
    for k, (x, y) in enumerate(((0.1, 0.5), (0.3, 0.38), (0.5, 0.26))):
        s.box(x, y, 0.0, x + 0.4, y + 0.1, 0.62, (150, 126, 90), top=(176, 150, 108))
        img = Image.new('RGBA', (40, 60), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rectangle([3, 3, 36, 56], fill=(200, 198, 188, 255))
        for xx in range(4, 36, 3):
            d.line([(xx, 3), (xx, 56)], fill=(112, 110, 100, 255), width=1)
        d.line([(3, 30), (36, 27)], fill=(84, 82, 74, 170), width=4)
        front_decal(s, x + 0.03, x + 0.37, 0.04, 0.58, y + 0.1, img, offset=0.0)
    s.tube((0.06, 0.62, 0.34), (0.96, 0.62, 0.34), 0.016, TAN, segments=6)
    s.tube((0.06, 0.62, 0.22), (0.96, 0.62, 0.22), 0.016, TAN, segments=6)
    return I.from_scene(s)


def pharmacy_ledger(I):
    s = lying(-30)
    s.box(0.1, 0.1, 0.0, 0.9, 0.9, 0.1, (110, 36, 40), top=(134, 48, 52), shine=0.05)
    s.box(0.14, 0.14, 0.1, 0.88, 0.88, 0.17, PAPER)
    s.box(0.08, 0.08, 0.17, 0.9, 0.92, 0.22, (110, 36, 40), top=(134, 48, 52), shine=0.05)
    for (x0, y0, x1, y1) in ((0.08, 0.08, 0.2, 0.2), (0.78, 0.08, 0.9, 0.2), (0.08, 0.8, 0.2, 0.92), (0.78, 0.8, 0.9, 0.92)):
        s.box(x0, y0, 0.17, x1, y1, 0.225, (196, 170, 100), top=BRASS, shine=0.5)
    img = Image.new('RGBA', (60, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([4, 4, 56, 60], outline=(220, 200, 150, 255), width=2)
    d.text((14, 8), 'Rx', fill=(230, 214, 170, 255), font=I.font('impact.ttf', 40))
    flat_decal(s, 0.26, 0.24, 0.72, 0.76, 0.2205, img, offset=0.0)
    return I.from_scene(s)


def copy_original(I):
    s = lying()
    s.box(0.2, 0.14, 0.0, 0.86, 0.9, 0.012, CARBON)
    s.box(0.14, 0.1, 0.012, 0.8, 0.86, 0.026, PAPER)
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(10, 72, 6):
        d.line([(6, y), (46 - (y % 11), y)], fill=INK, width=1)
    d.rectangle([4, 2, 52, 12], outline=RED_INK, width=2)
    d.line([(8, 7), (48, 7)], fill=RED_INK, width=2)
    d.text((38, 62), '4', fill=RED_INK, font=I.font('impact.ttf', 14))
    flat_decal(s, 0.14, 0.1, 0.8, 0.86, 0.0265, img, offset=0.0)
    return I.from_scene(s)


def sample_case(I):
    s = Scene(0)
    s.box(0.1, 0.26, 0.0, 0.9, 0.74, 0.36, OD, top=OD_LIGHT, shine=0.15)
    s.box(0.1, 0.26, 0.19, 0.9, 0.74, 0.205, OD_DARK)
    s.box(0.36, 0.18, 0.34, 0.64, 0.26, 0.4, OD_DARK)
    for x in (0.2, 0.72):
        s.box(x, 0.74, 0.08, x + 0.08, 0.77, 0.32, STEEL, shine=0.7)
    # two bands of red seal tape over the lid and a stencil
    s.box(0.28, 0.26, 0.355, 0.36, 0.74, 0.366, (196, 48, 40))
    s.box(0.64, 0.26, 0.355, 0.72, 0.74, 0.366, (196, 48, 40))
    flat_decal(s, 0.38, 0.36, 0.62, 0.64, 0.3665, acorn_mark(40, STENCIL), offset=0.0)
    front_decal(s, 0.3, 0.7, 0.07, 0.17, 0.771, stencil_text('SAMPLE', 60, 14, STENCIL), offset=0.0)
    return I.from_scene(s)


def dead_drop_case(I):
    s = Scene(0)
    s.box(0.1, 0.3, 0.0, 0.9, 0.7, 0.34, (96, 62, 38), top=(120, 80, 50), shine=0.12)
    s.box(0.1, 0.7, 0.0, 0.9, 0.72, 0.34, (80, 52, 32))
    s.box(0.1, 0.3, 0.2, 0.9, 0.72, 0.215, (60, 40, 26))
    s.tube((0.34, 0.5, 0.34), (0.34, 0.5, 0.44), 0.02, (60, 40, 26), segments=8)
    s.tube((0.66, 0.5, 0.34), (0.66, 0.5, 0.44), 0.02, (60, 40, 26), segments=8)
    s.tube((0.34, 0.5, 0.44), (0.66, 0.5, 0.44), 0.025, (60, 40, 26), segments=8)
    for x in (0.26, 0.66):
        s.box(x, 0.72, 0.18, x + 0.08, 0.745, 0.26, BRASS, shine=0.7)
    s.box(0.44, 0.72, 0.19, 0.56, 0.745, 0.25, BRASS, shine=0.7)
    s.box(0.08, 0.32, 0.0, 0.14, 0.68, 0.34, (80, 52, 32))
    return I.from_scene(s)


def field_call_device(I):
    s = Scene(0)
    s.box(0.3, 0.3, 0.0, 0.7, 0.62, 0.62, (50, 54, 52), top=(70, 74, 72), shine=0.25)
    s.box(0.3, 0.62, 0.0, 0.7, 0.66, 0.62, (40, 44, 42))
    # speaker grille, the push-to-talk bar, an amber lamp, a knob
    img = Image.new('RGBA', (32, 36), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(3, 34, 4):
        d.line([(3, y), (29, y)], fill=(20, 22, 22, 255), width=2)
    front_decal(s, 0.34, 0.66, 0.1, 0.34, 0.661, img, offset=0.0)
    s.box(0.34, 0.66, 0.4, 0.66, 0.69, 0.5, OD, shine=0.2)
    s.box(0.36, 0.66, 0.54, 0.44, 0.68, 0.58, (240, 170, 40), emit=True)
    s.tube((0.56, 0.5, 0.62), (0.56, 0.5, 0.7), 0.04, (30, 32, 32), segments=10, shine=0.4)
    s.tube((0.4, 0.4, 0.62), (0.4, 0.4, 1.0), 0.012, STEEL, segments=6, shine=0.7)
    s.tube((0.4, 0.4, 0.97), (0.4, 0.4, 1.02), 0.02, (232, 120, 30), segments=6)
    s.box(0.26, 0.36, 0.1, 0.3, 0.56, 0.5, (30, 32, 32))
    return I.from_scene(s)


def analysis_reply(I):
    s = lying()
    s.box(0.18, 0.1, 0.0, 0.84, 0.9, 0.014, PAPER)
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([4, 3, 52, 10], fill=(84, 96, 64, 255))
    d.rectangle([8, 5, 20, 8], fill=(220, 214, 190, 255))
    for y in range(16, 36, 5):
        d.line([(5, y), (50, y)], fill=INK, width=1)
    d.line([(6, 70), (6, 44)], fill=INK, width=1)
    d.line([(6, 70), (52, 70)], fill=INK, width=1)
    d.line([(6, 64), (16, 58), (26, 62), (36, 50), (50, 46)], fill=RED_INK, width=2)
    flat_decal(s, 0.18, 0.1, 0.84, 0.9, 0.0145, img, offset=0.0)
    return I.from_scene(s)


def appendix(I):
    s = lying()
    for k in range(3):
        s.box(0.2 + k * 0.02, 0.16 + k * 0.02, k * 0.012, 0.8 + k * 0.02, 0.88 + k * 0.01, k * 0.012 + 0.012, PAPER if k < 2 else (236, 232, 214))
    img = Image.new('RGBA', (52, 68), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(12, 60, 6):
        d.line([(5, y), (44 - (y % 13), y)], fill=INK, width=1)
    d.rectangle([4, 3, 24, 8], fill=INK)
    flat_decal(s, 0.24, 0.2, 0.84, 0.9, 0.0385, img, offset=0.0)
    s.box(0.78, 0.2, 0.0, 0.88, 0.34, 0.04, (214, 150, 44))          # the index tab
    s.box(0.2, 0.18, 0.036, 0.3, 0.26, 0.044, STEEL, top=(200, 204, 208), shine=0.7)   # the staple
    return I.from_scene(s)


def serum_sheet(I):
    s = lying(-36)
    for k, (x0, x1, lift) in enumerate(((0.1, 0.38, 0.0), (0.38, 0.66, 0.0), (0.66, 0.9, 0.0))):
        s.box(x0, 0.16, lift, x1, 0.86, lift + 0.012, PAPER if k != 1 else (238, 234, 216))
    img = Image.new('RGBA', (80, 70), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 79, 8], fill=(226, 134, 40, 255))
    # a vial on the middle panel, text lines on the others
    d.rectangle([32, 18, 46, 50], fill=(200, 224, 226, 255), outline=INK)
    d.rectangle([34, 32, 44, 48], fill=(226, 150, 46, 255))
    d.rectangle([34, 12, 44, 18], fill=INK)
    for y in range(18, 62, 7):
        d.line([(4, y), (24, y)], fill=INK, width=1)
        d.line([(56, y), (76, y)], fill=INK, width=1)
    flat_decal(s, 0.1, 0.16, 0.9, 0.86, 0.0125, img, offset=0.0)
    s.box(0.378, 0.16, 0.0, 0.382, 0.86, 0.013, (170, 166, 150))
    s.box(0.658, 0.16, 0.0, 0.662, 0.86, 0.013, (170, 166, 150))
    return I.from_scene(s)


def unresolved_list(I):
    s = lying()
    s.box(0.18, 0.1, 0.0, 0.84, 0.9, 0.012, (238, 236, 224))
    img = Image.new('RGBA', (56, 80), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([6, 4, 30, 8], fill=INK)
    for k, y in enumerate(range(16, 74, 9)):
        d.rectangle([5, y, 11, y + 6], outline=INK)
        if k in (0, 2):
            d.line([(5, y + 3), (8, y + 7), (13, y - 2)], fill=(40, 120, 50, 255), width=2)
        d.line([(16, y + 3), (46 - (k % 3) * 6, y + 3)], fill=INK, width=1)
    d.ellipse([12, 38, 52, 56], outline=RED_INK, width=2)
    d.line([(46, 4), (46, 14)], fill=RED_INK, width=3)
    d.ellipse([44, 17, 49, 22], fill=RED_INK)
    flat_decal(s, 0.18, 0.1, 0.84, 0.9, 0.0125, img, offset=0.0)
    s.tube((0.12, 0.92, 0.03), (0.5, 0.78, 0.03), 0.02, RED, segments=6, shine=0.3)
    return I.from_scene(s)


def handover_file(I):
    s = lying(-28)
    s.box(0.1, 0.1, 0.0, 0.9, 0.9, 0.22, (52, 66, 92), top=(68, 84, 112), shine=0.05)
    s.box(0.12, 0.12, 0.22, 0.88, 0.88, 0.28, (236, 232, 212))
    s.box(0.1, 0.1, 0.28, 0.9, 0.9, 0.34, (52, 66, 92), top=(68, 84, 112), shine=0.05)
    s.box(0.1, 0.1, 0.34, 0.9, 0.9, 0.345, (52, 66, 92))
    s.box(0.4, 0.04, 0.0, 0.6, 0.12, 0.3, (232, 226, 200))           # the tab
    flat_decal(s, 0.18, 0.22, 0.82, 0.5, 0.3455, stencil_text('HANDOVER', 80, 20, (226, 222, 200)), offset=0.0)
    for x in (0.34, 0.66):
        s.tube((x, 0.1, 0.17), (x, 0.9, 0.17), 0.012, RED, segments=6)
    s.tube((0.34, 0.5, 0.345), (0.66, 0.5, 0.345), 0.014, RED, segments=6)
    return I.from_scene(s)


def kit_voucher(I):
    s = lying(-40)
    pts = [(0.1, 0.22), (0.9, 0.22), (0.9, 0.44), (0.86, 0.5), (0.9, 0.56), (0.9, 0.78), (0.1, 0.78), (0.1, 0.56), (0.14, 0.5), (0.1, 0.44)]
    I.prism(s, pts, 0.0, 0.02, (210, 150, 40), top=(236, 176, 56), shine=0.05)
    img = Image.new('RGBA', (80, 56), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([2, 2, 77, 53], outline=(120, 70, 20, 255), width=1)
    for y in range(6, 50, 5):
        d.point((60, y), fill=(120, 70, 20, 255))
    d.line([(60, 4), (60, 52)], fill=(120, 70, 20, 255), width=1)
    d.text((8, 6), '1', fill=(100, 56, 16, 255), font=I.font('impact.ttf', 40))
    d.line([(24, 36), (54, 36)], fill=(120, 70, 20, 255), width=2)
    d.line([(24, 44), (44, 44)], fill=(120, 70, 20, 255), width=1)
    flat_decal(s, 0.1, 0.22, 0.9, 0.78, 0.0205, img, offset=0.0)
    return I.from_scene(s)


FUNCTIONS = {
    'mission_envelope': mission_envelope, 'mission_sample_tin': mission_sample_tin, 'mission_logbook': mission_logbook,
    'mission_filter_case': mission_filter_case, 'mission_tape': mission_tape, 'mission_fabric_roll': mission_fabric_roll,
    'mission_heavy_case': mission_heavy_case,
    'evidence_envelope': evidence_envelope, 'clinic_record': clinic_record, 'weather_log': weather_log,
    'farm_journal': farm_journal, 'sample_cooler': sample_cooler, 'roster_page': roster_page, 'review_memo': review_memo,
    'ward_record': ward_record, 'cell_log': cell_log, 'soil_sample': soil_sample, 'stake_tag': stake_tag,
    'roster_lost_page': roster_lost_page, 'filter_bundle': filter_bundle, 'pharmacy_ledger': pharmacy_ledger,
    'copy_original': copy_original, 'sample_case': sample_case, 'dead_drop_case': dead_drop_case,
    'field_call_device': field_call_device, 'analysis_reply': analysis_reply, 'appendix': appendix,
    'serum_sheet': serum_sheet, 'unresolved_list': unresolved_list, 'handover_file': handover_file,
    'kit_voucher': kit_voucher,
}


def pictures(icon_art):
    return {key: (lambda f=f: f(icon_art)) for key, f in FUNCTIONS.items()}
