#!/usr/bin/env python3
"""Operation Acorn tree-node icon generator.

Usage:
    python tools/node_icons.py             write all OA_Node_*.png (and the *_Gray.png of each) + tools/node_icons.txt
    python tools/node_icons.py --preview   also write tools/node_icons_preview.png

Every icon is drawn in a 64-unit space at 8x (512px) and downsampled with LANCZOS to OUT x OUT RGBA (128).

Why 128: the windows scale with the screen (S = floor(screenH / 540 * 4) / 4) and draw a node's icon at about 40
design units: 50 px at 720p, 60 at 900p, 80 at 1080p, 100 at 1440p, 160 at 4K. The game loads a texture from
media/textures without mipmaps (Texture.getSharedTexture: flags 0, or only compression), so an icon is sampled
bilinearly from its one level: shrunk more than about 2x it shimmers on its thin rims, enlarged it goes soft. 128 is
shrunk at most 2.6x (720p) and 1.3x at 1080p, is never enlarged up to 1440p, and is enlarged 1.25x at 4K. 256 would be
shrunk 3-5x on the common screens. VRAM (RGBA8, uncompressed): 64 KiB an icon, 7 MiB for all 56 icons and their
grey copies, and the game loads a texture only when it is first drawn (64 px was 16 KiB an icon, 1.8 MiB).
Style: rounded-square badge, 2-tone flat fill (dark plate + lighter disc), thin dark rim,
cream glyph with a soft drop shadow. Board colour: scout = blue-teal, load = amber-brown,
survival = green. Capstones get a gold rim and a gold star. Second-board nodes keep their
source colour but get a violet double rim and a violet infinity chip.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

S = 8
N = 64          # the drawing space, in units
W = N * S
OUT = 128       # the PNG's size
CREAM = (246, 240, 216, 255)
ERASE = (0, 0, 0, 0)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "OperationAcorn", "42", "media", "textures"))
TXT_PATH = os.path.join(HERE, "node_icons.txt")
PREVIEW_PATH = os.path.join(HERE, "node_icons_preview.png")

# board key -> (plate light, base dark, rim dark)
PALETTE = {
    "scout": ((52, 156, 168), (30, 108, 122), (12, 56, 68)),
    "load": ((206, 140, 58), (156, 98, 38), (72, 42, 16)),
    "surv": ((108, 160, 70), (68, 116, 46), (28, 56, 22)),
}
GOLD = (236, 190, 56)
VIOLET = (150, 96, 214)
BOARD_ASCII = {"정찰": "scout", "하중": "load", "생존": "survival", "2차-정찰": "B2 scout", "2차-하중": "B2 load", "2차-생존": "B2 survival"}


# ---------------------------------------------------------------- drawing helpers
class D:
    """Tiny drawing context in 64-unit space, rendered at 8x, optional rotation."""

    def __init__(self, im, ink):
        self.im = im
        self.dr = ImageDraw.Draw(im)
        self.ink = ink
        self.c = CREAM
        self.er = ERASE
        self.xf = None

    def rot(self, cx, cy, deg):
        r = math.radians(deg)
        self.xf = (cx, cy, math.cos(r), math.sin(r))

    def norot(self):
        self.xf = None

    def T(self, x, y):
        if self.xf:
            cx, cy, c, s = self.xf
            dx, dy = x - cx, y - cy
            x, y = cx + dx * c - dy * s, cy + dx * s + dy * c
        return (x * S, y * S)

    def poly(self, pts, c=None):
        self.dr.polygon([self.T(*p) for p in pts], fill=c or self.c)

    def circle(self, cx, cy, r, c=None):
        x, y = self.T(cx, cy)
        self.dr.ellipse([x - r * S, y - r * S, x + r * S, y + r * S], fill=c or self.c)

    def ring(self, cx, cy, r, w, c=None):
        x, y = self.T(cx, cy)
        self.dr.ellipse([x - r * S, y - r * S, x + r * S, y + r * S],
                        outline=c or self.c, width=max(1, int(round(w * S))))

    def ell(self, cx, cy, rx, ry, c=None, n=48):
        pts = [(cx + rx * math.cos(2 * math.pi * i / n), cy + ry * math.sin(2 * math.pi * i / n))
               for i in range(n)]
        self.poly(pts, c)

    def path(self, pts, w=3.4, c=None, closed=False):
        c = c or self.c
        tp = [self.T(*p) for p in pts]
        if closed:
            tp = tp + [tp[0]]
        for a, b in zip(tp, tp[1:]):
            self.dr.line([a, b], fill=c, width=int(round(w * S)))
        r = w * S / 2
        for (x, y) in tp:
            self.dr.ellipse([x - r, y - r, x + r, y + r], fill=c)

    def line(self, x0, y0, x1, y1, w=3.4, c=None):
        self.path([(x0, y0), (x1, y1)], w, c)

    def arc_pts(self, cx, cy, r, a0, a1, step=3.0):
        n = max(2, int(abs(a1 - a0) / step) + 1)
        return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / (n - 1))),
                 cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / (n - 1)))) for i in range(n)]

    def arc(self, cx, cy, r, a0, a1, w=3.4, c=None):
        self.path(self.arc_pts(cx, cy, r, a0, a1), w, c)

    def rrect(self, x0, y0, x1, y1, r, c=None):
        r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
        pts = []
        for (cx, cy, a0) in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
            for i in range(9):
                a = math.radians(a0 + 90 * i / 8)
                pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        self.poly(pts, c)

    def frame(self, x0, y0, x1, y1, r, w, c=None):
        self.rrect(x0, y0, x1, y1, r, c)
        self.rrect(x0 + w, y0 + w, x1 - w, y1 - w, max(0.5, r - w), self.er)

    def rect(self, x0, y0, x1, y1, c=None):
        self.poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], c)

    def star4(self, cx, cy, r, c=None, k=0.3):
        pts = []
        for i in range(8):
            rr = r if i % 2 == 0 else r * k
            a = math.radians(-90 + 45 * i)
            pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        self.poly(pts, c)

    def star5(self, cx, cy, r, c=None, k=0.45):
        pts = []
        for i in range(10):
            rr = r if i % 2 == 0 else r * k
            a = math.radians(-90 + 36 * i)
            pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        self.poly(pts, c)

    def leaf(self, x0, y0, deg, ln, wid, c=None):
        a = math.radians(deg)
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        top, bot = [], []
        for i in range(17):
            t = i / 16
            wd = math.sin(math.pi * t) ** 0.8 * wid / 2
            bx, by = x0 + ux * ln * t, y0 + uy * ln * t
            top.append((bx + px * wd, by + py * wd))
            bot.append((bx - px * wd, by - py * wd))
        self.poly(top + bot[::-1], c)

    def crescent(self, cx, cy, r, dx, dy, r2, c=None):
        """Circle (cx,cy,r) minus circle (cx+dx, cy+dy, r2), composited as one shape."""
        tmp = Image.new("RGBA", self.im.size, ERASE)
        sub = D(tmp, self.ink)
        sub.xf = self.xf
        sub.circle(cx, cy, r, c or self.c)
        sub.circle(cx + dx, cy + dy, r2, ERASE)
        self.im.alpha_composite(tmp)

    def arrow(self, x0, y0, x1, y1, w=3.6, head=6.5, c=None):
        a = math.atan2(y1 - y0, x1 - x0)
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        bx, by = x1 - ux * head * 0.9, y1 - uy * head * 0.9
        self.line(x0, y0, bx, by, w, c)
        self.poly([(x1, y1), (bx + px * head * 0.85, by + py * head * 0.85),
                   (bx - px * head * 0.85, by - py * head * 0.85)], c)


def quad_bezier(p0, p1, p2, n=12):
    out = []
    for i in range(n + 1):
        t = i / n
        out.append(((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
                    (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]))
    return out


def eye(g, cx, cy, a, h, iris=None, c=None):
    top = []
    bot = []
    for i in range(33):
        x = -a + 2 * a * i / 32
        y = h * math.cos(math.pi / 2 * x / a) ** 0.85
        top.append((cx + x, cy - y))
        bot.append((cx + x, cy + y))
    g.poly(top + bot[::-1], c)


def footprint(g, cx, cy, s=1.0):
    def P(x, y):
        return (cx + x * s, cy + y * s)
    x, y = P(0, 11)
    g.ell(x, y, 4.4 * s, 4.6 * s)
    x, y = P(0.5, -0.5)
    g.ell(x, y, 6.6 * s, 8.4 * s)
    for (tx, ty, tr) in ((-4.6, -12.6, 2.8), (0.4, -14.6, 2.2), (4.2, -13.6, 2.0), (7.2, -10.8, 1.8), (8.8, -7.0, 1.5)):
        x, y = P(tx, ty)
        g.circle(x, y, tr * s)


# ---------------------------------------------------------------- glyphs (64-unit space)
def g_sight_cone(g):
    cx, cy = 32, 49
    pts = [(cx, cy)] + g.arc_pts(cx, cy, 33, 226, 314, 3)
    g.poly(pts, (246, 240, 216, 105))
    g.path(pts, 2.6, g.c, closed=True)
    g.circle(cx, cy + 2, 4.4)
    g.arc(cx, cy, 20, 238, 302, 2.2)


def g_sense(g):  # a calm head in profile with flash lines behind it (the moodle, tools/moodle_art.py, is a face)
    ox, oy = 3, 3
    for ang, r0, r1 in ((-158, 19.5, 27.5), (-118, 19.5, 28.5), (-78, 19.5, 27.5)):
        a = math.radians(ang)
        g.line(ox + 29 + r0 * math.cos(a), oy + 30 + r0 * math.sin(a),
               ox + 29 + r1 * math.cos(a), oy + 30 + r1 * math.sin(a), 3.0)
    g.circle(ox + 29, oy + 30, 13.5)
    g.poly([(ox + x, oy + y) for x, y in ((29, 16.5), (37, 19), (41.5, 25), (42.5, 29), (46.5, 34.5), (43.5, 36),
                                          (44, 39), (42.8, 40.4), (43.2, 42.5), (40.5, 45.5), (35.5, 46.5),
                                          (35.5, 54), (21.5, 54), (22, 44), (17, 38))])


def g_alarm_read(g):
    pts = g.arc_pts(32, 32, 12.5, 180, 360, 5) + [(46, 43), (18, 43)]
    g.poly(pts)
    g.rrect(15, 42, 49, 46.5, 2)
    g.circle(32, 51, 3.4)
    g.circle(32, 19, 2.6)
    g.line(32, 27, 32, 34, 2.8, g.ink)
    g.circle(32, 38.4, 1.6, g.ink)
    g.arc(32, 31, 20, 158, 202, 3.0)
    g.arc(32, 31, 20, -22, 22, 3.0)


def g_search_log(g):
    g.rrect(16, 15, 48, 53, 4)
    g.rrect(22.5, 9.5, 41.5, 20.5, 3, g.ink)
    g.rrect(24.5, 11.5, 39.5, 18.5, 2)
    for i, y in enumerate((29, 37, 45)):
        if i < 2:
            g.path([(21, y), (23.2, y + 2.4), (27.5, y - 2.6)], 2.4, g.ink)
        else:
            g.circle(24, y, 1.7, g.ink)
        g.line(31, y, 43, y, 2.6, g.ink)


def g_thorough_search(g):
    g.ring(27, 27, 14, 4.6)
    g.line(38, 38, 50, 50, 6.0)
    g.star4(27, 27, 7.2)


def g_night_eye(g):
    eye(g, 34, 39, 17.5, 10.5)
    g.circle(34, 39, 7.2, g.ink)
    g.circle(31.6, 36.6, 2.0)
    g.crescent(18, 19, 8.4, 4.0, -2.8, 7.2)
    g.star4(44, 17, 4.6)


def g_presence(g):
    footprint(g, 22, 34, 0.95)
    for r in (17, 25):
        g.arc(24, 34, r, -40, 40, 3.2)


def g_sample_grade(g):  # one sample bag picked out of the rest, with sparkles
    g.rrect(16, 15, 35, 54, 8.0)
    g.rrect(19.8, 19, 31.2, 50.2, 4.6, g.er)
    g.rrect(19.8, 34, 31.2, 50.2, 4.6)
    g.star4(46, 21, 10.5)
    g.star4(49, 42, 5.5)


def bullet(g, cx, top, bot, w=10.0):
    ogive = [(cx - w / 2 * math.sin(t * math.pi / 2), top + w * 1.25 * (1 - math.cos(t * math.pi / 2)))
             for t in [i / 12 for i in range(13)]][::-1]
    right = [(2 * cx - x, y) for (x, y) in ogive][::-1]
    g.poly(ogive + right + [(cx + w / 2, bot), (cx - w / 2, bot)])
    ly = top + w * 1.25 + 0.55 * (bot - top - w * 1.25) * 0.55
    g.line(cx - w / 2, ly, cx + w / 2, ly, 1.8, g.ink)
    g.line(cx - w / 2, bot - 3.2, cx + w / 2, bot - 3.2, 1.6, g.ink)


def g_ammo_search(g):
    bullet(g, 19.5, 22, 51, 10)
    bullet(g, 32, 14, 51, 10)
    bullet(g, 44.5, 22, 51, 10)


def g_presence_boost(g):  # radar
    cx, cy = 32, 34
    g.ring(cx, cy, 18, 3.4)
    g.ring(cx, cy, 9, 1.9)
    wedge = [(cx, cy)] + g.arc_pts(cx, cy, 16.5, -88, -28, 4)
    g.poly(wedge, (246, 240, 216, 175))
    g.line(cx, cy, cx + 17 * math.cos(math.radians(-28)), cy + 17 * math.sin(math.radians(-28)), 2.8)
    g.circle(cx, cy, 3.4)
    g.circle(22, 27, 3.0)
    g.circle(42, 43, 3.0)
    g.circle(24, 44, 2.4)


def g_nocturnal_eye(g):  # capstone
    eye(g, 32, 35, 22, 14.5)
    g.circle(32, 35, 11, g.ink)
    g.crescent(32, 35, 8.2, 3.6, -2.6, 7.0)
    g.star4(13, 15, 4.6)
    g.star4(17, 53, 3.6)


# ---- load
def g_overload_endure(g):  # kettlebell
    g.ring(32, 24, 10.5, 4.2)
    g.circle(32, 38, 14.5)
    g.rrect(23, 48, 41, 52.5, 1.8)
    g.arc(25, 37, 8.5, 190, 250, 2.4, g.ink)


def g_transfer_speed(g):
    g.arrow(14, 26, 50, 26, 4.0, 8)
    g.arrow(50, 41, 14, 41, 4.0, 8)
    g.line(17, 33.5, 27, 33.5, 2.4)
    g.line(37, 33.5, 47, 33.5, 2.4)


def g_key_ring(g):
    g.ring(30, 24, 10.5, 3.4)
    # key right
    g.circle(41, 38, 6.6)
    g.circle(41, 38, 2.6, g.ink)
    g.line(41, 44, 41, 54, 4.0)
    g.line(41, 51, 46, 51, 3.0)
    g.line(41, 54, 45, 54, 3.0)
    # key left
    g.circle(20, 38, 6.0)
    g.circle(20, 38, 2.3, g.ink)
    g.line(20, 43, 20, 53, 3.8)
    g.line(20, 50, 25, 50, 3.0)


def g_furniture_weight(g):
    g.rrect(12, 14, 52, 21, 2.4)
    g.rrect(15, 20, 49, 49, 2.4)
    g.line(15, 34.5, 49, 34.5, 2.0, g.ink)
    g.circle(32, 27.5, 2.2, g.ink)
    g.circle(32, 42, 2.2, g.ink)
    g.rect(18, 49, 24, 54)
    g.rect(40, 49, 46, 54)


def g_material_weight(g):  # stacked planks
    g.rrect(18, 14, 50, 23, 2)
    g.rrect(13, 25, 45, 34, 2)
    g.rrect(18, 36, 50, 45, 2)
    g.rrect(13, 47, 45, 55, 2)
    for (x, y) in ((22, 18.5), (45, 18.5), (17, 29.5), (40, 29.5), (22, 40.5), (45, 40.5), (17, 51), (40, 51)):
        g.circle(x, y, 1.4, g.ink)


def g_run_speed(g):  # boot + speed lines
    boot = [(26, 13), (38, 13), (38, 30), (47, 33), (53, 40), (53, 50), (26, 50)]
    g.poly(boot)
    g.line(26, 45, 53, 45, 2.0, g.ink)
    g.line(26, 38, 38, 38, 1.8, g.ink)
    g.line(8, 24, 18, 24, 2.8)
    g.line(6, 33, 17, 33, 2.8)
    g.line(9, 42, 18, 42, 2.8)


def g_carry_capacity(g):  # backpack
    g.arc(32, 19, 6, 180, 360, 3.2)
    g.rrect(13, 28, 18.5, 46, 2.5)
    g.rrect(45.5, 28, 51, 46, 2.5)
    g.rrect(18, 18, 46, 53, 9)
    g.line(18, 31, 46, 31, 2.0, g.ink)
    g.rrect(23.5, 37, 40.5, 48, 3, g.ink)
    g.rrect(25.5, 39, 38.5, 46, 2)


def g_combat_speed(g):  # bat + swing
    g.rot(32, 32, -42)
    g.poly([(10, 30.5), (34, 29), (46, 26.5), (50, 27.5), (50, 36.5), (46, 37.5), (34, 35), (10, 33.5)])
    g.rrect(6, 29.5, 12, 34.5, 2)
    g.norot()
    g.arc(30, 32, 24, 18, 64, 2.8)
    g.arc(30, 32, 19, 22, 58, 2.4)


def g_material_weight_plus(g):  # log pyramid
    r = 6.6
    pos = [(32, 20), (25.4, 31.4), (38.6, 31.4), (19, 42.8), (32, 42.8), (45, 42.8)]
    for (x, y) in pos:
        g.circle(x, y, r)
    for (x, y) in pos:
        g.ring(x, y, 3.6, 1.7, g.ink)


def g_storage_capacity(g):  # crate
    g.rrect(13, 14, 51, 52, 3)
    g.rrect(18, 19, 46, 47, 1.2, g.ink)
    g.rrect(20, 21, 44, 45, 1.0, g.c)
    g.line(20, 21, 44, 45, 2.2, g.ink)
    g.line(44, 21, 20, 45, 2.2, g.ink)


def g_armor_constitution(g):  # capstone: shield
    def shield(k):
        right = quad_bezier((48, 30), (47, 45), (32, 54), 14)
        left = [(64 - x, y) for (x, y) in right][::-1]
        pts = [(16, 16), (32, 11), (48, 16)] + right + left
        return [(32 + (x - 32) * k, 32 + (y - 32) * k) for (x, y) in pts]
    g.poly(shield(1.0))
    g.poly(shield(0.72), g.ink)
    g.circle(32, 30.5, 6.0)
    g.circle(32, 30.5, 2.2, g.ink)


# ---- survival
def g_serum_adapt(g):  # syringe
    g.rot(32, 32, -45)
    g.rrect(19, 25.5, 43, 38.5, 2.4)
    for x in (25, 30, 35):
        g.line(x, 28, x, 33, 1.7, g.ink)
    g.rect(41, 28.5, 52, 35.5)
    g.rrect(51, 24, 54, 40, 1.2)
    g.rrect(16, 24, 20, 40, 1.4)
    g.line(19, 32, 7, 32, 2.0)
    g.norot()


def g_crowbar_pry(g):
    g.rot(32, 33, 34)
    g.line(32, 23, 32, 50, 5.6)
    g.arc(23.5, 23, 8.5, 0, -190, 5.6)
    g.poly([(13.5, 24), (21, 24), (17.2, 33)])
    g.poly([(27, 47), (37, 47), (41, 54), (23, 54)])
    g.norot()


def g_limb_stiffness(g):  # bandage
    g.rot(32, 32, -40)
    g.rrect(10, 23, 54, 41, 9)
    g.rrect(23, 23, 41, 41, 1.5, g.ink)
    for (x, y) in ((28, 28), (36, 28), (28, 36), (36, 36)):
        g.circle(x, y, 1.5)
    for (x, y) in ((16, 29), (16, 35), (48, 29), (48, 35)):
        g.circle(x, y, 1.4, g.ink)
    g.norot()


def g_break_fall(g):
    g.arrow(32, 11, 32, 40, 4.2, 9.5)
    g.line(11, 48, 53, 48, 3.6)
    g.arc(32, 48, 14, 198, 240, 3.0)
    g.arc(32, 48, 14, 300, 342, 3.0)


def g_lock_pick(g):
    g.arc(32, 28, 9.8, 180, 360, 4.4)
    g.line(22.2, 28, 22.2, 33, 4.4)
    g.line(41.8, 28, 41.8, 33, 4.4)
    g.rrect(16, 29, 48, 54, 5)
    g.circle(32, 39, 3.6, g.ink)
    g.poly([(32, 39), (29.8, 48), (34.2, 48)], g.ink)
    # pick tool (ink outline then cream)
    g.path([(54, 12), (45, 22), (33, 41)], 6.0, g.ink)
    g.path([(54, 12), (45, 22), (33, 41)], 3.0, g.c)


def g_brush_clear(g):
    for (deg, ln, wd) in ((-165, 22, 10), (-15, 22, 10), (-128, 33, 12), (-52, 33, 12), (-90, 38, 13)):
        g.leaf(32, 53, deg, ln, wd)
    for (deg, ln) in ((-90, 30), (-128, 25), (-52, 25)):
        a = math.radians(deg)
        g.line(32 + math.cos(a) * 5, 53 + math.sin(a) * 5, 32 + math.cos(a) * ln, 53 + math.sin(a) * ln, 1.7, g.ink)


def vest(g):
    g.poly([(20, 12), (27, 12), (32, 25), (37, 12), (44, 12), (53, 22), (49, 53), (15, 53), (11, 22)])
    g.circle(9.5, 31, 7.2, g.er)
    g.circle(54.5, 31, 7.2, g.er)


def g_gear_care(g):
    vest(g)
    g.line(32, 26, 32, 53, 1.9, g.ink)
    g.line(19.5, 43, 26.5, 43, 2.2, g.ink)
    g.path([(36.5, 41), (39, 44), (44.5, 37.5)], 2.4, g.ink)


def virus_body(g, cx, cy, r=10.0):
    for i in range(8):
        a = math.radians(45 * i + 22.5)
        g.line(cx + math.cos(a) * (r - 1), cy + math.sin(a) * (r - 1),
               cx + math.cos(a) * (r + 6.0), cy + math.sin(a) * (r + 6.0), 3.0)
        g.circle(cx + math.cos(a) * (r + 6.4), cy + math.sin(a) * (r + 6.4), 2.5)
    g.circle(cx, cy, r)


def g_infection_resist(g):
    virus_body(g, 32, 32, 10.5)
    g.circle(28.5, 28.5, 2.4, g.ink)
    g.circle(36, 34, 2.0, g.ink)
    g.circle(30, 37, 1.5, g.ink)


def g_walk_speed(g):  # wind arrow
    g.path(g.arc_pts(34, 18, 4, 90, -90, 20), 3.2)
    g.line(12, 22, 34, 22, 3.2)
    g.line(10, 34, 46, 34, 3.8)
    g.poly([(44, 26), (56, 34), (44, 42)])
    g.line(12, 46, 34, 46, 3.2)
    g.path(g.arc_pts(34, 50, 4, -90, 90, 20), 3.2)


def heart_pts(cx, cy, k):
    pts = []
    for i in range(61):
        t = 2 * math.pi * i / 60
        x = 16 * math.sin(t) ** 3
        y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((cx + x * k, cy + y * k))
    return pts


def g_infection_resist_plus(g):
    g.poly(heart_pts(32, 32, 1.4))
    g.path([(14, 34), (23, 34), (27, 25), (33, 43), (37, 34), (50, 34)], 2.6, g.ink)


def g_break_sprint(g):  # capstone
    g.path([(13, 18), (24, 32), (13, 46)], 4.8)
    g.path([(26, 18), (37, 32), (26, 46)], 4.8)
    shards = [((44, 20), 6, 20), ((51, 31), 5, -12), ((45, 43), 6, 35), ((52, 18), 4, 50), ((53, 44), 4, 10)]
    for (x, y), sz, deg in shards:
        g.rot(x, y, deg)
        g.poly([(x - sz / 2, y - sz / 2), (x + sz / 2, y - sz / 2), (x + sz / 2, y + sz / 2), (x - sz / 2, y + sz / 2)])
        g.norot()
    g.line(6, 24, 11, 24, 2.4)
    g.line(6, 40, 11, 40, 2.4)


# ---- second board: load
def g_b2_heavy_load(g):
    g.ring(32, 22, 8.4, 3.8)
    g.poly([(22, 28), (42, 28), (51, 51), (13, 51)])
    g.line(20, 43, 44, 43, 2.2, g.ink)
    g.line(24, 35, 40, 35, 2.2, g.ink)


def g_b2_category_weight(g):
    g.rrect(13, 13, 30, 30, 4)
    g.rrect(34, 13, 51, 30, 4)
    g.rrect(13, 34, 30, 51, 4)
    g.rrect(34, 34, 51, 51, 4)
    g.path([(37.5, 22), (41, 26), (47.5, 18)], 3.0, g.ink)
    g.circle(21.5, 21.5, 3.0, g.ink)
    g.rect(18, 40, 26, 46, g.ink)
    g.poly([(42.5, 37.5), (47, 47.5), (38, 47.5)], g.ink)


def g_b2_gear_adapt(g):  # helmet
    g.poly(g.arc_pts(32, 37, 20, 180, 360, 5) + [(53, 40), (11, 40)])
    g.rrect(8, 38, 56, 43.5, 2.6)
    g.line(14, 31, 50, 31, 2.0, g.ink)
    g.star5(32, 23, 4.4, g.ink)
    g.path([(15, 44), (17, 52)], 3.0)
    g.path([(49, 44), (47, 52)], 3.0)


def g_b2_gear_speed(g):  # speedometer
    g.arc(32, 40, 19, 180, 360, 4.4)
    for a in (205, 235, 270, 305, 335):
        r = math.radians(a)
        g.line(32 + math.cos(r) * 11.5, 40 + math.sin(r) * 11.5, 32 + math.cos(r) * 14, 40 + math.sin(r) * 14, 2.2)
    g.line(32, 40, 43, 27, 3.6)
    g.circle(32, 40, 4.4)
    g.rect(12, 47, 52, 51)


def g_b2_overload_penalty(g):  # balance scale
    g.line(32, 13, 32, 49, 3.4)
    g.rrect(21, 48, 43, 53, 2)
    g.line(14, 28, 50, 19, 3.0)
    g.circle(32, 23.5, 3.4)
    for (x, y) in ((14, 28), (50, 19)):
        g.line(x, y, x - 5.5, y + 11, 1.8)
        g.line(x, y, x + 5.5, y + 11, 1.8)
        g.poly(g.arc_pts(x, y + 11, 6.4, 0, 180, 8))


def g_b2_transfer_time(g):  # stopwatch
    g.ring(32, 36, 16, 3.8)
    g.rrect(28.5, 11.5, 35.5, 16, 1.5)
    g.line(32, 16, 32, 20, 3.0)
    g.line(46, 19, 49, 16, 3.2)
    g.line(32, 36, 32, 26, 3.2)
    g.line(32, 36, 39.5, 40, 3.2)
    g.circle(32, 36, 2.8)


def g_b2_carry_limit(g):
    g.frame(24, 13, 38, 52, 4, 3.0)
    g.rect(27, 32, 35, 49)
    for y in (20, 27, 34, 41, 48):
        g.line(15, y, 21, y, 2.2)
    g.arrow(47, 42, 47, 17, 3.6, 8)


def g_b2_storage_capacity(g):
    g.frame(13, 13, 51, 52, 3, 3.6)
    g.line(17, 32.5, 47, 32.5, 3.4)
    g.rect(19, 22, 27, 31)
    g.rect(31, 25, 41, 31)
    g.rect(19, 38, 30, 47)
    g.rect(34, 41, 44, 47)


# ---- second board: survival
def g_b2_scratch_infect(g):
    g.line(14, 14, 24, 42, 4.4)
    g.line(25, 12, 35, 40, 4.4)
    g.line(36, 14, 46, 36, 4.4)
    g.poly([(42, 40), (46, 46), (45.5, 51), (38.5, 51), (38, 46)])


def g_b2_sickness_rate(g):  # thermometer
    g.rrect(26, 11, 38, 40, 6)
    g.circle(32, 43, 9.6)
    g.rrect(29.2, 14.5, 34.8, 42, 2.8, g.ink)
    g.circle(32, 43, 6.0, g.ink)
    g.rrect(30.4, 28, 33.6, 44, 1.6)
    g.circle(32, 43, 3.9)
    for y in (17, 23, 29):
        g.line(41, y, 46, y, 2.2)


def g_b2_bite_cooldown(g):  # jaws
    g.rrect(11, 15, 53, 24, 4)
    for x in (19, 29, 39, 49):
        g.poly([(x - 4.2, 23), (x + 4.2, 23), (x, 32)])
    g.rrect(11, 41, 53, 50, 4)
    for x in (24, 34, 44):
        g.poly([(x - 4.2, 42), (x + 4.2, 42), (x, 34)])


def g_b2_limb_fatigue(g):  # dumbbell
    g.rot(32, 32, -35)
    g.line(16, 32, 48, 32, 5.0)
    g.rrect(7, 19, 17, 45, 3.0)
    g.rrect(47, 19, 57, 45, 3.0)
    g.rrect(16, 24, 22, 40, 1.6)
    g.rrect(42, 24, 48, 40, 1.6)
    g.norot()


def g_b2_stamina(g):  # battery
    g.rrect(27, 11, 37, 17, 1.6)
    g.frame(19, 15, 45, 54, 5, 3.4)
    g.rrect(24, 40, 40, 48, 1.4)
    g.rrect(24, 30, 40, 38, 1.4)
    g.rrect(24, 20, 40, 28, 1.4)
    g.rect(24, 20, 40, 28, g.er)
    g.line(25, 24, 39, 24, 1.4)


def g_b2_sleep_fatigue(g):
    g.crescent(26, 33, 16, 8, -6, 13)
    g.path([(37, 13), (48, 13), (37, 23), (48, 23)], 3.0)
    g.path([(42, 31), (50, 31), (42, 38), (50, 38)], 2.6)


def g_b2_gear_damage(g):
    vest(g)
    g.path([(42, 10), (34, 24), (41, 34), (30, 44), (37, 56)], 3.8, g.er)
    g.line(19.5, 43, 26.5, 43, 2.2, g.ink)


def g_b2_fall_damage(g):
    g.arrow(32, 10, 32, 30, 4.2, 9.0)
    g.line(11, 52, 53, 52, 3.4)
    pts = []
    for i in range(16):
        rr = 10.5 if i % 2 == 0 else 5.2
        a = math.radians(-180 + 180 * i / 15)
        pts.append((32 + rr * math.cos(a) * 1.5, 49 + rr * math.sin(a)))
    g.poly(pts)


def g_b2_sprint_stamina(g):
    g.poly([(36, 11), (19, 34), (30, 34), (25, 54), (46, 27), (35, 27), (42, 11)])
    g.line(8, 22, 15, 22, 2.8)
    g.line(6, 31, 13, 31, 2.8)
    g.line(8, 40, 15, 40, 2.8)


def g_b2_walk_speed(g):  # saturating curve + asymptote
    g.path([(14, 12), (14, 50), (52, 50)], 3.0)
    for x in range(17, 52, 7):
        g.line(x, 15, x + 3.5, 15, 2.0)
    pts = []
    for i in range(30):
        t = i / 29
        x = 18 + 32 * t
        y = 48 - 31 * (1 - math.exp(-t * 3.4))
        pts.append((x, y))
    g.path(pts, 3.6)


# ---- second board: scout
def g_b2_loot_chance(g):  # die
    g.rot(32, 32, 11)
    g.rrect(13, 13, 51, 51, 8)
    for (x, y) in ((22, 22), (42, 22), (32, 32), (22, 42), (42, 42)):
        g.circle(x, y, 3.3, g.ink)
    g.norot()


def g_b2_selected_sample(g):  # the selected sample with a grade tag
    g.rrect(14, 15, 33, 54, 8.0)
    g.rrect(17.8, 19, 29.2, 50.2, 4.6, g.er)
    g.rrect(17.8, 34, 29.2, 50.2, 4.6)
    g.line(31, 24, 41, 30, 2.6)
    g.rrect(38, 27, 53, 41, 2.4)
    g.circle(42.2, 31.2, 1.7, g.er)
    g.star4(47, 14, 7.0)


def g_b2_sample_bundle(g):
    for (cx, top) in ((20, 20), (32, 13), (44, 21)):
        g.rrect(cx - 5.4, top, cx + 5.4, 52, 5.4)
        g.rrect(cx - 2.6, top + 3.0, cx + 2.6, 49.6, 2.6, g.er)
        g.rrect(cx - 2.6, 35, cx + 2.6, 49.6, 2.6)
    g.rrect(13, 28, 51, 36, 2.0, g.ink)
    g.rrect(14.8, 29.8, 49.2, 34.2, 1.2)


def g_b2_presence_radius(g):
    g.ring(32, 32, 20, 3.0)
    footprint(g, 30, 33, 0.58)
    for a in (-45, 135):
        r = math.radians(a)
        g.line(32 + math.cos(r) * 20, 32 + math.sin(r) * 20, 32 + math.cos(r) * 26, 32 + math.sin(r) * 26, 3.0)
    for a in (45, -135):
        r = math.radians(a)
        g.line(32 + math.cos(r) * 20, 32 + math.sin(r) * 20, 32 + math.cos(r) * 25, 32 + math.sin(r) * 25, 3.0)


def g_b2_hunch_radius(g):
    g.circle(32, 46, 4.6)
    g.arc(32, 46, 11, 225, 315, 3.4)
    g.arc(32, 46, 19, 225, 315, 3.4)
    for a0 in (225, 255, 285):
        g.arc(32, 46, 27, a0 + 2, a0 + 28, 2.8)


def g_sealed(g):  # a capstone not yet known: a question mark
    g.path(g.arc_pts(32, 24, 10, 180, 400) + [(33.5, 33.5), (32, 37), (32, 40)], 5.2)
    g.circle(32, 49, 3.6)


# ---------------------------------------------------------------- icon table
# (board, korean name, slug, glyph function, flags)  flags: "cap" capstone, "b2" second board
ICONS = [
    ("정찰", "시야 보정", "SightCone", g_sight_cone, ""),
    ("정찰", "육감", "Hunch", g_sense, ""),
    ("정찰", "경보 읽기", "AlarmRead", g_alarm_read, ""),
    ("정찰", "털이 기록", "SearchLog", g_search_log, ""),
    ("정찰", "알찬 수색", "RichSearch", g_thorough_search, ""),
    ("정찰", "밤눈", "NightEye", g_night_eye, ""),
    ("정찰", "기척 감지", "Presence", g_presence, ""),
    ("정찰", "시료 감별", "SampleGrade", g_sample_grade, ""),
    ("정찰", "탄약 수색", "AmmoSearch", g_ammo_search, ""),
    ("정찰", "기척 감지 강화", "PresenceRadar", g_presence_boost, ""),
    ("정찰", "야행성 눈", "NocturnalEye", g_nocturnal_eye, "cap"),
    ("하중", "과적 견디기", "Overload", g_overload_endure, ""),
    ("하중", "옮기기 속도", "TransferSpeed", g_transfer_speed, ""),
    ("하중", "열쇠고리", "KeyRing", g_key_ring, ""),
    ("하중", "가구 무게", "FurnitureWeight", g_furniture_weight, ""),
    ("하중", "자재 무게", "MaterialWeight", g_material_weight, ""),
    ("하중", "달리기 속도", "RunSpeed", g_run_speed, ""),
    ("하중", "캐릭터 용량", "CarryCapacity", g_carry_capacity, ""),
    ("하중", "전투 속도", "CombatSpeed", g_combat_speed, ""),
    ("하중", "자재 무게 강화", "MaterialWeightPlus", g_material_weight_plus, ""),
    ("하중", "저장소 용량", "StorageCapacity", g_storage_capacity, ""),
    ("하중", "갑옷 체질", "ArmorBody", g_armor_constitution, "cap"),
    ("생존", "혈청 적응", "SerumAdapt", g_serum_adapt, ""),
    ("생존", "빠루 따기", "CrowbarPry", g_crowbar_pry, ""),
    ("생존", "부위 피로", "LimbStiffness", g_limb_stiffness, ""),
    ("생존", "낙법", "BreakFall", g_break_fall, ""),
    ("생존", "자물쇠 따기", "LockPick", g_lock_pick, ""),
    ("생존", "수풀 헤치기", "BrushClear", g_brush_clear, ""),
    ("생존", "장비 아끼기", "GearCare", g_gear_care, ""),
    ("생존", "감염 저항", "InfectionResist", g_infection_resist, ""),
    ("생존", "걷는 속도", "WalkSpeed", g_walk_speed, ""),
    ("생존", "감염 저항 강화", "InfectionResistPlus", g_infection_resist_plus, ""),
    ("생존", "돌파 질주", "BreakSprint", g_break_sprint, "cap"),
    # a capstone while its tree is sealed (the window shows the grey one)
    ("정찰", "봉인된 연구", "SealedScout", g_sealed, "cap"),
    ("하중", "봉인된 연구", "SealedLoad", g_sealed, "cap"),
    ("생존", "봉인된 연구", "SealedSurvival", g_sealed, "cap"),
    # second board (source tree order as in TREES.md)
    ("2차-하중", "무거운 짐 무게", "B2HeavyLoad", g_b2_heavy_load, "b2"),
    ("2차-하중", "계열 무게", "B2CategoryWeight", g_b2_category_weight, "b2"),
    ("2차-하중", "장비 적응", "B2GearAdapt", g_b2_gear_adapt, "b2"),
    ("2차-하중", "장비 속도 벌칙", "B2GearSpeed", g_b2_gear_speed, "b2"),
    ("2차-하중", "과적 벌칙", "B2OverloadPenalty", g_b2_overload_penalty, "b2"),
    ("2차-하중", "옮기기 시간", "B2TransferTime", g_b2_transfer_time, "b2"),
    ("2차-하중", "운반 한도", "B2CarryLimit", g_b2_carry_limit, "b2"),
    ("2차-하중", "저장소 용량", "B2StorageCapacity", g_b2_storage_capacity, "b2"),
    ("2차-생존", "긁힘·찢김 감염 확률", "B2ScratchInfect", g_b2_scratch_infect, "b2"),
    ("2차-생존", "병이 쌓이는 속도", "B2SicknessRate", g_b2_sickness_rate, "b2"),
    ("2차-생존", "물림 버티기 대기", "B2BiteCooldown", g_b2_bite_cooldown, "b2"),
    ("2차-생존", "부위 피로 쌓임", "B2LimbFatigue", g_b2_limb_fatigue, "b2"),
    ("2차-생존", "지구력 소모", "B2Stamina", g_b2_stamina, "b2"),
    ("2차-생존", "수면 피로 쌓임", "B2SleepFatigue", g_b2_sleep_fatigue, "b2"),
    ("2차-생존", "입은 장비 손상 확률", "B2GearDamage", g_b2_gear_damage, "b2"),
    ("2차-생존", "낙하 피해", "B2FallDamage", g_b2_fall_damage, "b2"),
    ("2차-생존", "돌파 질주 지구력 소모", "B2SprintStamina", g_b2_sprint_stamina, "b2"),
    ("2차-생존", "걷는 속도", "B2WalkSpeed", g_b2_walk_speed, "b2"),
    ("2차-정찰", "전리품 확률", "B2LootChance", g_b2_loot_chance, "b2"),
    ("2차-정찰", "선별 시료", "B2SelectedSample", g_b2_selected_sample, "b2"),
    ("2차-정찰", "시료 묶음", "B2SampleBundle", g_b2_sample_bundle, "b2"),
    ("2차-정찰", "기척 감지 반경", "B2PresenceRadius", g_b2_presence_radius, "b2"),
    ("2차-정찰", "육감 반경", "B2HunchRadius", g_b2_hunch_radius, "b2"),
]

BOARD_KEY = {"정찰": "scout", "하중": "load", "생존": "surv"}


def board_key(board):
    return BOARD_KEY[board.replace("2차-", "")]


# ---------------------------------------------------------------- badge + compose
def rr_mask(inset, radius):
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset * S, inset * S, W - 1 - inset * S, W - 1 - inset * S],
                                        radius=radius * S, fill=255)
    return m


def solid(color, mask):
    layer = Image.new("RGBA", (W, W), color + (255,) if len(color) == 3 else color)
    layer.putalpha(mask)
    return layer


def make_badge(key, flags):
    light, base, rim = PALETTE[key]
    cap = "cap" in flags
    b2 = "b2" in flags
    img = Image.new("RGBA", (W, W), ERASE)
    if cap:
        outer, inner_rim_w = GOLD, 1.0
    elif b2:
        outer, inner_rim_w = VIOLET, 1.5
    else:
        outer, inner_rim_w = rim, 0.0
    img.alpha_composite(solid(outer, rr_mask(1.0, 13)))
    if cap or b2:
        img.alpha_composite(solid(rim, rr_mask(3.0, 11)))
        fill_inset = 3.0 + inner_rim_w + 0.9
    else:
        fill_inset = 3.2
    fill_mask = rr_mask(fill_inset, max(6.0, 13 - fill_inset))
    img.alpha_composite(solid(base, fill_mask))
    # lighter plate disc
    plate = Image.new("L", (W, W), 0)
    ImageDraw.Draw(plate).ellipse([(32 - 23.5) * S, (32 - 23.5) * S, (32 + 23.5) * S, (32 + 23.5) * S], fill=255)
    from PIL import ImageChops
    plate = ImageChops.multiply(plate, fill_mask)
    img.alpha_composite(solid(light, plate))
    # subtle top highlight
    hl = Image.new("L", (W, W), 0)
    ImageDraw.Draw(hl).ellipse([-14 * S, -34 * S, 78 * S, 17 * S], fill=255)
    hl = ImageChops.multiply(hl, fill_mask)
    hl = hl.point(lambda v: int(v * 0.12))
    hlayer = Image.new("RGBA", (W, W), (255, 255, 255, 255))
    hlayer.putalpha(hl)
    img.alpha_composite(hlayer)
    return img


def corner_marks(img, key, flags):
    light, base, rim = PALETTE[key]
    d = ImageDraw.Draw(img)
    if "cap" in flags:
        layer = Image.new("RGBA", (W, W), ERASE)
        g = D(layer, rim)
        g.star5(50, 14.5, 10.5, rim)
        g.star5(50, 14.5, 8.4, GOLD)
        img.alpha_composite(layer)
    if "b2" in flags:
        layer = Image.new("RGBA", (W, W), ERASE)
        g = D(layer, rim)
        g.circle(50.5, 50.5, 10.4, rim)
        g.circle(50.5, 50.5, 8.6, VIOLET + (255,))
        g.ring(47.6, 50.5, 3.0, 1.9, CREAM)
        g.ring(53.4, 50.5, 3.0, 1.9, CREAM)
        img.alpha_composite(layer)


def render_icon(board, glyph, flags):
    key = board_key(board)
    light, base, rim = PALETTE[key]
    img = make_badge(key, flags)
    layer = Image.new("RGBA", (W, W), ERASE)
    g = D(layer, base)
    glyph(g)
    # fit glyph away from corner marks
    sc, dx, dy = 1.0, 0.0, 0.0
    if "b2" in flags:
        sc, dx, dy = 0.88, -2.2, -2.2
    elif "cap" in flags:
        sc, dx, dy = 0.9, -1.6, 2.0
    else:
        sc = 0.96
    if sc != 1.0:
        size = int(round(W * sc))
        scaled = layer.resize((size, size), Image.LANCZOS)
        layer = Image.new("RGBA", (W, W), ERASE)
        layer.paste(scaled, (int(round((W - size) / 2 + dx * S)), int(round((W - size) / 2 + dy * S))), scaled)
    # shadow
    alpha = layer.split()[3]
    sh = Image.new("RGBA", (W, W), rim + (255,))
    sh_mask = Image.new("L", (W, W), 0)
    sh_mask.paste(alpha.point(lambda v: int(v * 0.55)), (0, int(0.9 * S)))
    sh.putalpha(sh_mask)
    img.alpha_composite(sh)
    img.alpha_composite(layer)
    corner_marks(img, key, flags)
    return img.resize((OUT, OUT), Image.LANCZOS)


# ---------------------------------------------------------------- output
def filename(slug):
    return "OA_Node_%s.png" % slug


def gray_filename(slug):
    return "OA_Node_%s_Gray.png" % slug


def grayed(im):
    """The icon of a node that is not open yet: grey and darker, the same shape (the game cannot desaturate)."""
    from PIL import ImageOps
    alpha = im.getchannel("A")
    luma = ImageOps.grayscale(im.convert("RGB")).point(lambda v: int(v * 0.62))
    out = Image.merge("RGBA", (luma, luma, luma, alpha))
    return out


def write_txt():
    lines = ["# board\tnode (Korean)\ticon file (media/textures); generated by tools/node_icons.py"]
    for (board, name, slug, _fn, _fl) in ICONS:
        lines.append("%s\t%s\t%s" % (board, name, filename(slug)))
    with open(TXT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def make_preview(icons):
    cols = 8
    cw, ch = 132, 104
    rows = (len(icons) + cols - 1) // cols
    strip_rows = 3
    sw = 36
    height = rows * ch + 20 + strip_rows * (sw + 6) + 24
    sheet = Image.new("RGBA", (cols * cw, height), (58, 60, 52, 255))
    font = ImageFont.load_default()
    d = ImageDraw.Draw(sheet)
    for i, (spec, im) in enumerate(icons):
        board, name, slug, _fn, _fl = spec
        x = (i % cols) * cw + 8
        y = (i // cols) * ch + 6
        sheet.alpha_composite(im.resize((64, 64), Image.LANCZOS), (x, y))
        sheet.alpha_composite(im.resize((32, 32), Image.LANCZOS), (x + 74, y + 16))
        d.text((x, y + 70), slug, fill=(235, 235, 220, 255), font=font)
        d.text((x, y + 83), BOARD_ASCII[board], fill=(160, 170, 150, 255), font=font)
    y0 = rows * ch + 12
    d.text((8, y0 - 4), "all at 32px", fill=(200, 200, 190, 255), font=font)
    per = (len(icons) + strip_rows - 1) // strip_rows
    for i, (spec, im) in enumerate(icons):
        x = 8 + (i % per) * (sw + 4)
        y = y0 + 10 + (i // per) * (sw + 6)
        sheet.alpha_composite(im.resize((32, 32), Image.LANCZOS), (x, y))
    sheet.convert("RGB").save(PREVIEW_PATH)


def main(argv):
    os.makedirs(OUT_DIR, exist_ok=True)
    slugs = [s[2] for s in ICONS]
    assert len(set(slugs)) == len(slugs), "duplicate slug"
    rendered = []
    for spec in ICONS:
        board, name, slug, fn, flags = spec
        im = render_icon(board, fn, flags)
        im.save(os.path.join(OUT_DIR, filename(slug)))
        grayed(im).save(os.path.join(OUT_DIR, gray_filename(slug)))
        rendered.append((spec, im))
    write_txt()
    if "--preview" in argv:
        make_preview(rendered)
    print("wrote %d icons to %s" % (len(rendered), OUT_DIR))


if __name__ == "__main__":
    main(sys.argv[1:])
