#!/usr/bin/env python3
"""The approval seal of the research tab (Upgrades/Window.lua: the stamp after a research approval): a round red ink
stamp the size of a real moment, its centre word in each language, the ink splatter of its impact and the shade laid
under it, as textures the game draws scaled (a UI draw cannot rotate, so the stamp's tilt is baked in).

    py tools/seal_art.py      writes OperationAcorn/42/media/textures/OA_Seal_<256|512>.png (the rings, the text
                              ORDWAY / TEAM 2 round the band, the rules), OA_SealWord_<KO|EN>_<256|512>.png (the
                              centre word on the same canvas, so the two are drawn with one rectangle),
                              OA_SealInk_<256|512>.png (the splatter ring), OA_SealShade.png (a soft dark disc),
                              and tools/seal_preview.png (the stamp on the tree's panel at 1x and 2x, in both
                              languages, and over a mock of the tree area at the size the game draws it).

How it reads as ink and not as a drawing: every line is a polygon whose radius wanders (a few slow waves and a little
jitter), the thick outer ring is several such passes slightly off one another (a rough, doubled edge); the ink is
heavier on the lower left (pressed at a slight angle) and blotchy, it thins out into gaps on the upper right, it has
grain, small holes and a few hairline scratches knocked out of it, and it soaks a little into the paper. It is drawn at
4x and taken down, so its edges are crisp. Seeded: the same files come out every time.

The centre word is the translation of IGUI_OA_Tree_SealWord (read from the Translate files), one texture a language;
a language without one gets the word as text (Window.lua). Fonts: Windows' Bahnschrift and Malgun Gothic.
"""
import json
import math
import os
import random

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
MEDIA = os.path.join(ROOT, 'OperationAcorn', '42', 'media')
TEXTURES = os.path.join(MEDIA, 'textures')
TRANSLATE = os.path.join(MEDIA, 'lua', 'shared', 'Translate')
PREVIEW = os.path.join(HERE, 'seal_preview.png')

N = 512                 # the large copy's side
SS = 4                  # drawn at 4x, taken down
M = N * SS
H = M / 2               # the half side at the drawing size: radii below are shares of it
TILT = 10               # degrees, counter-clockwise (rising to the right, as a hand presses a stamp)
INK = (196, 35, 28)     # #c4231c
INK_DARK = (158, 22, 18)
INK_LIGHT = (212, 58, 46)

FONTS = 'C:/Windows/Fonts/'
WORD_FONTS = {'KO': ('malgunbd.ttf', None), 'EN': ('bahnschrift.ttf', b'Bold Condensed')}
RING_FONT = ('bahnschrift.ttf', b'Bold')

# the rings and the band, as shares of the half side
R_OUT, R_OUT_W = 0.935, 0.085       # the thick outer ring: its outer radius and width
R_IN, R_IN_W = 0.655, 0.022         # the thin inner ring
R_TEXT = 0.765                      # the middle of the band's letters
CAP = 0.115                         # the band's letters' height
RULE_Y, RULE_W = 0.30, 0.016        # the two rules over and under the word
WORD_H = 0.44                       # the word's height at most (between the rules)


def font(spec, size):
    name, variation = spec
    f = ImageFont.truetype(FONTS + name, size)
    if variation:
        f.set_variation_by_name(variation)
    return f


def waves(rnd, n, amp):
    """A wandering radius: a few slow waves of random phase (amplitudes falling with their frequency) and jitter."""
    parts = [(k, rnd.uniform(0, 2 * math.pi), amp / (k ** 0.8)) for k in rnd.sample(range(2, 28), 7)]

    def at(i):
        t = 2 * math.pi * i / n
        return sum(a * math.sin(k * t + p) for k, p, a in parts) + rnd.uniform(-amp, amp) * 0.35
    return [at(i) for i in range(n)]


def ring_poly(rnd, r, amp, cx=0.0, cy=0.0, n=900):
    w = waves(rnd, n, amp)
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        rr = (r + w[i]) * H
        pts.append((H + cx * H + rr * math.cos(t), H + cy * H + rr * math.sin(t)))
    return pts


def ring(rnd, r_outer, width, amp, passes, spread):
    """A rough ring as coverage (0..1, float): several passes slightly off one another, their union worn at the
    edges where only some of them cover."""
    acc = np.ones((M, M), np.float32)
    for _ in range(passes):
        img = Image.new('L', (M, M), 0)
        d = ImageDraw.Draw(img)
        cx, cy = rnd.uniform(-spread, spread), rnd.uniform(-spread, spread)
        dr = rnd.uniform(-spread, spread)
        d.polygon(ring_poly(rnd, r_outer + dr, amp, cx, cy), fill=255)
        d.polygon(ring_poly(rnd, r_outer - width + dr, amp, cx, cy), fill=0)
        acc *= 1 - 0.62 * (np.asarray(img, np.float32) / 255)
    cover = 1 - acc
    return np.clip((cover - 0.25) / 0.55, 0, 1)


def glyph(ch, f):
    """A letter as a square L image, its cap centred."""
    size = int(f.size * 2.2)
    img = Image.new('L', (size, size), 0)
    cap = f.getbbox('H', anchor='ls')
    cap_h = cap[3] - cap[1]
    ImageDraw.Draw(img).text((size / 2, size / 2 + cap_h / 2), ch, font=f, fill=255, anchor='ms')
    return img


def star(cx, cy, r, turn):
    pts = []
    for i in range(10):
        a = turn + math.pi * i / 5 - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.42
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


def band_text(rnd):
    """ORDWAY over the top, TEAM 2 under the bottom (upright, read left to right), a star at either side."""
    img = Image.new('L', (M, M), 0)
    f = font(RING_FONT, 40)
    cap = f.getbbox('H', anchor='ls')
    f = font(RING_FONT, int(40 * CAP * H / (cap[3] - cap[1])))
    r = R_TEXT * H
    track = 0.035 * H

    def place(text, top):
        widths = [f.getlength(ch) + track for ch in text]
        span = sum(widths) - track
        a = -span / 2
        for ch, w in zip(text, widths):
            mid = a + (w - track) / 2
            a += w
            phi = mid / r if top else math.pi - mid / r
            g = glyph(ch, f)
            turn = math.degrees(phi) if top else math.degrees(phi) - 180
            g = g.rotate(-turn, resample=Image.BICUBIC)
            jitter = rnd.uniform(-0.004, 0.004) * H
            x = H + (r + jitter) * math.sin(phi) - g.width / 2
            y = H - (r + jitter) * math.cos(phi) - g.height / 2
            img.paste(255, (int(x), int(y)), g)
    place('ORDWAY', True)
    place('TEAM 2', False)
    d = ImageDraw.Draw(img)
    for phi in (math.pi / 2, 3 * math.pi / 2):
        x, y = H + r * math.sin(phi), H - r * math.cos(phi)
        d.polygon(star(x, y, CAP * H * 0.62, phi), fill=255)
    return np.asarray(img, np.float32) / 255


def rules(rnd):
    img = Image.new('L', (M, M), 0)
    d = ImageDraw.Draw(img)
    for sign in (-1, 1):
        y = H + sign * RULE_Y * H
        half = math.sqrt((R_IN * H) ** 2 - (RULE_Y * H) ** 2) - 0.07 * H
        top, bottom = [], []
        steps = 40
        for i in range(steps + 1):
            x = H - half + 2 * half * i / steps
            top.append((x, y - RULE_W * H / 2 + rnd.uniform(-0.002, 0.002) * H))
            bottom.append((x, y + RULE_W * H / 2 + rnd.uniform(-0.002, 0.002) * H))
        d.polygon(top + bottom[::-1], fill=255)
    return np.asarray(img, np.float32) / 255


def word_cover(lang, word):
    """The centre word, as large as fits between the rules and inside the inner ring."""
    max_h = WORD_H * H
    max_w = 2 * (math.sqrt((R_IN * H) ** 2 - (RULE_Y * H) ** 2) - 0.09 * H)
    size = 400
    while True:
        f = font(WORD_FONTS[lang], size)
        box = f.getbbox(word, anchor='mm')
        if box[2] - box[0] <= max_w and box[3] - box[1] <= max_h:
            break
        size -= 4
    img = Image.new('L', (M, M), 0)
    box = f.getbbox(word, anchor='mm')
    ImageDraw.Draw(img).text((H - (box[0] + box[2]) / 2, H - (box[1] + box[3]) / 2), word, font=f, fill=255,
                             anchor='mm')
    # a hand-cut stamp's letters are not perfectly sharp: a hair of blur, then crisp again
    img = img.filter(ImageFilter.GaussianBlur(SS * 0.6)).point(lambda v: 255 if v > 118 else int(v * 255 / 118 * 0.8))
    return np.asarray(img, np.float32) / 255


def tilt(cover):
    img = Image.fromarray((cover * 255).astype(np.uint8), 'L')
    img = img.rotate(TILT, resample=Image.BICUBIC, center=(H, H))
    return img


def down(img, n):
    return np.asarray(img.resize((n, n), Image.LANCZOS), np.float32) / 255


def smooth_noise(rnd, cells, n):
    small = Image.fromarray(np.array([[rnd.randrange(256) for _ in range(cells)] for _ in range(cells)], np.uint8),
                            'L')
    return np.asarray(small.resize((n, n), Image.BICUBIC), np.float32) / 255


def press(n, seed):
    """The press at side n: how much ink each place takes (density, heavier on the lower left and blotchy, thin and
    gappy on the upper right) and what wear knocks out of it (grain, holes, scratches). Screen space: after the tilt."""
    rnd = random.Random(seed)
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    c = n / 2
    proj = ((c - xs) + (ys - c)) / (math.sqrt(2) * c)          # -1 upper right .. 1 lower left
    t = np.clip((proj + 1) / 2, 0, 1)
    density = 0.55 + 0.50 * (t * t * (3 - 2 * t))
    density += (smooth_noise(rnd, 9, n) - 0.5) * 0.24
    # ink starving on the light side: patches that took little, fading in and out (no seam)
    starve = smooth_noise(rnd, 22, n)
    g = np.clip((starve - 0.55) / 0.2, 0, 1) * np.clip((-proj - 0.05) / 0.45, 0, 1)
    density *= 1 - 0.6 * g * g * (3 - 2 * g)
    wear = np.ones((n, n), np.float32)
    np_rng = np.random.default_rng(seed)
    wear *= 0.80 + 0.20 * np_rng.random((n, n), np.float32)
    holes = Image.new('L', (n, n), 255)
    d = ImageDraw.Draw(holes)
    k = n / 512
    for _ in range(int(2600 * k * k)):
        x, y = rnd.uniform(0, n), rnd.uniform(0, n)
        p = ((c - x) + (y - c)) / (math.sqrt(2) * c)
        if rnd.random() < 0.45 + 0.35 * (-p):
            r = (0.5 + rnd.random() ** 3 * 2.2) * k
            d.ellipse((x - r, y - r, x + r, y + r), fill=rnd.randint(0, 90))
    for _ in range(7):
        x, y = rnd.uniform(0.1, 0.9) * n, rnd.uniform(0.1, 0.9) * n
        a = rnd.uniform(0, math.pi)
        length = rnd.uniform(0.08, 0.25) * n
        d.line((x, y, x + length * math.cos(a), y + length * math.sin(a)), fill=110, width=max(1, int(k)))
    holes = holes.filter(ImageFilter.GaussianBlur(0.45 * k))
    wear *= np.asarray(holes, np.float32) / 255
    return np.clip(density, 0, 1.15), wear


def ink_image(cover, density, wear, bleed=True):
    """Coverage to the ink's RGBA: its strength from the press, its colour darker where it is heavy, a little soaked
    into the paper around it."""
    # a rubber stamp leaves its strokes' rims a little heavier than their middles
    blur = np.asarray(Image.fromarray((cover * 255).astype(np.uint8), 'L').filter(
        ImageFilter.GaussianBlur(cover.shape[0] / 220)), np.float32) / 255
    rim = np.clip(cover - blur, 0, 1)
    density = density + rim * 0.5
    a = np.clip(cover * density * wear * 1.08, 0, 1)
    a = np.clip((a - 0.06) / 0.86, 0, 1)
    if bleed:
        soak = np.asarray(Image.fromarray((cover * 255).astype(np.uint8), 'L').filter(
            ImageFilter.GaussianBlur(cover.shape[0] / 300)), np.float32) / 255
        a = np.maximum(a, soak * density * 0.13)
    heavy = np.clip((density - 0.75) / 0.4, 0, 1)[..., None]
    rgb = np.array(INK_LIGHT, np.float32) * (1 - heavy) + np.array(INK_DARK, np.float32) * heavy
    rgb = rgb * 0.5 + np.array(INK, np.float32) * 0.5
    out = np.dstack([rgb, a[..., None] * 255]).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def splatter(seed):
    """The impact's ink: droplets in a ring round the stamp's edge (most small, a few large, some drawn out along
    their way), satellites further out; the middle clear."""
    rnd = random.Random(seed)
    img = Image.new('L', (M, M), 0)
    d = ImageDraw.Draw(img)
    for _ in range(260):
        a = rnd.uniform(0, 2 * math.pi)
        r = (0.80 + 0.16 * rnd.random() ** 0.7) * H
        s = (0.003 + 0.010 * rnd.random() ** 2.5) * H
        if rnd.random() < 0.06:
            s *= 2.2
        x, y = H + r * math.cos(a), H + r * math.sin(a)
        d.ellipse((x - s, y - s, x + s, y + s), fill=rnd.randint(170, 255))
    for _ in range(36):
        a = rnd.uniform(0, 2 * math.pi)
        r = rnd.uniform(0.83, 0.95) * H
        length, width = rnd.uniform(0.025, 0.06) * H, rnd.uniform(0.004, 0.009) * H
        pts = []
        for i in range(16):
            t = 2 * math.pi * i / 16
            u, v = length * math.cos(t), width * math.sin(t) * (1 - 0.5 * math.cos(t))
            pts.append((H + (r + u) * math.cos(a) - v * math.sin(a), H + (r + u) * math.sin(a) + v * math.cos(a)))
        d.polygon(pts, fill=rnd.randint(150, 230))
    for _ in range(140):
        a = rnd.uniform(0, 2 * math.pi)
        r = rnd.uniform(0.92, 0.995) * H
        s = rnd.uniform(0.0015, 0.004) * H
        x, y = H + r * math.cos(a), H + r * math.sin(a)
        d.ellipse((x - s, y - s, x + s, y + s), fill=rnd.randint(120, 220))
    cover = np.asarray(img.filter(ImageFilter.GaussianBlur(SS * 0.4)), np.float32) / 255
    return cover


def shade(n=256):
    """A soft dark disc laid under the stamp, so that its ink reads over the nodes under it."""
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    r = np.hypot(xs - n / 2 + 0.5, ys - n / 2 + 0.5) / (n / 2)
    t = np.clip((r - 0.35) / 0.65, 0, 1)
    a = (1 - t * t * (3 - 2 * t)) * 0.5 * 255
    out = np.zeros((n, n, 4), np.uint8)
    out[..., 0], out[..., 1], out[..., 2] = 9, 9, 7
    out[..., 3] = a.astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def words():
    out = {}
    for lang in WORD_FONTS:
        with open(os.path.join(TRANSLATE, lang, 'IG_UI.json'), encoding='utf-8') as f:
            out[lang] = json.load(f)['IGUI_OA_Tree_SealWord']
    return out


def build():
    rnd = random.Random(2042)
    rings = np.maximum(ring(rnd, R_OUT, R_OUT_W, 0.0065, 5, 0.005), ring(rnd, R_IN, R_IN_W, 0.003, 3, 0.0022))
    seal = np.maximum(np.maximum(rings, band_text(rnd)), rules(rnd))
    seal_t = tilt(seal)
    word_t = {lang: tilt(word_cover(lang, w)) for lang, w in words().items()}
    ink_t = tilt(splatter(77))
    out = {}
    for n in (512, 256):
        density, wear = press(n, 9001 + n)
        out[('Seal', n)] = ink_image(down(seal_t, n), density, wear)
        for lang, img in word_t.items():
            out[('SealWord_' + lang, n)] = ink_image(down(img, n), density, wear)
        density_i, wear_i = press(n, 4243 + n)
        out[('SealInk', n)] = ink_image(down(ink_t, n), density_i * 0.95, np.maximum(wear_i, 0.6), bleed=False)
    return out


# ---- the preview ---------------------------------------------------------------------------------------------------
# The palette of the research tab (Trade/UI.lua's field palette, Window.lua's tree colours), the game's scale (UI.S at
# 1080p is about 1.6) and the seal's design size (Window.SEAL_SIZE), to show it as the game will.
BG = (0.10, 0.11, 0.08)
INSET = (0.06, 0.065, 0.045)
BORDER = (0.42, 0.45, 0.30)
TREES = [(0.25, 0.66, 0.70), (0.86, 0.55, 0.22), (0.46, 0.74, 0.32)]
S = 1.6
SEAL_SIZE = 260
COL_W, COL_GAP, PAD, STRIP, GRID_H, TOP = 194, 6, 8, 58, 274, 28


def rgb(c, k=1.0):
    return tuple(int(round(v * 255 * k)) for v in c)


def tree_body(c):
    return tuple(INSET[i] * 0.88 + c[i] * 0.12 for i in range(3))


def tree_strip(c):
    return tuple(BG[i] * 0.74 + c[i] * 0.26 for i in range(3))


def mock_trees(word_img, seal_img, shade_img):
    """The tree area at the game's scale with the seal over the middle, as the stamp shows it when it holds."""
    w = int((2 * PAD + 3 * COL_W + 2 * COL_GAP) * S)
    top = int((PAD + TOP + 8) * S)
    h = top + int((STRIP + GRID_H + 8) * S)
    img = Image.new('RGB', (w, h), rgb(BG))
    d = ImageDraw.Draw(img)
    rnd = random.Random(5)
    for i, c in enumerate(TREES):
        x0 = int((PAD + i * (COL_W + COL_GAP)) * S)
        x1 = x0 + int(COL_W * S)
        d.rectangle((x0, top, x1, top + int((STRIP + GRID_H) * S)), fill=rgb(tree_body(c)))
        d.rectangle((x0, top, x1, top + int(STRIP * S)), fill=rgb(tree_strip(c)))
        d.rectangle((x0, top, x1, top + int(2 * S)), fill=rgb(c))
        d.rectangle((x0, top, x1, top + int((STRIP + GRID_H) * S)), outline=rgb(BORDER))
        for row in range(5):
            for col in range(4):
                if rnd.random() < 0.3:
                    continue
                s = (40 if row == 4 else 32) * S
                nx = x0 + int((12 + col * 46) * S)
                ny = top + int((STRIP + 12 + row * 52) * S)
                lit = rnd.random() < 0.5
                d.rectangle((nx, ny, nx + s, ny + s), fill=rgb(c, 0.55 if lit else 0.25))
                d.rectangle((nx - 3, ny - 3, nx + s + 3, ny + s + 3), outline=rgb(c if lit else BORDER, 0.9))
                if row < 4:
                    lx = nx + int(s / 2)
                    d.line((lx, ny + s + int(10 * S), lx, ny + int(52 * S)), fill=rgb(c if lit else BORDER, 0.8),
                           width=max(2, int(1.5 * S)))
    cx, cy = w / 2, top + (STRIP + GRID_H) * S / 2
    size = int(SEAL_SIZE * S)
    img = img.convert('RGBA')
    for layer, k in ((shade_img, 1.08), (seal_img, 1.0), (word_img, 1.0)):
        s = int(size * k)
        img.alpha_composite(layer.resize((s, s), Image.BICUBIC), (int(cx - s / 2), int(cy - s / 2)))
    return img.convert('RGB')


def preview(tex, shade_img):
    panel = rgb(tree_body(TREES[1]))
    label = ImageFont.truetype(FONTS + 'bahnschrift.ttf', 22)
    pad = 24
    cells = []
    for n in (256, 512):
        for lang in ('KO', 'EN'):
            cell = Image.new('RGBA', (n + 2 * pad, 512 + 2 * pad + 30), panel + (255,))
            for layer in (shade_img.resize((int(n * 1.08),) * 2, Image.BICUBIC),):
                cell.alpha_composite(layer, (pad - int(n * 0.04), pad - int(n * 0.04)))
            cell.alpha_composite(tex[('Seal', n)], (pad, pad))
            cell.alpha_composite(tex[('SealWord_' + lang, n)], (pad, pad))
            ImageDraw.Draw(cell).text((pad, 512 + pad + 4), '%s  %dx (%d px)' % (lang, n // 256, n), font=label,
                                      fill=(200, 196, 180))
            cells.append(cell.convert('RGB'))
    big = 512
    splat = Image.new('RGBA', (big + 2 * pad, big + 2 * pad + 30), panel + (255,))
    ink = tex[('SealInk', 512)].resize((int(big * 1.25),) * 2, Image.BICUBIC)
    splat.alpha_composite(ink.crop((int(big * 0.125), int(big * 0.125), int(big * 1.125), int(big * 1.125))),
                          (pad, pad))
    faint = tex[('Seal', 512)].copy()
    faint.putalpha(faint.getchannel('A').point(lambda v: v // 4))
    splat.alpha_composite(faint, (pad, pad))
    ImageDraw.Draw(splat).text((pad, big + pad + 4), 'impact splatter (spreading, over a faint seal)', font=label,
                               fill=(200, 196, 180))
    mocks = [mock_trees(tex[('SealWord_' + lang, 512)], tex[('Seal', 512)], shade_img) for lang in ('KO', 'EN')]
    width = max(sum(c.width for c in cells[:2]) + cells[2].width + cells[3].width, sum(m.width for m in mocks)) + pad
    height = max(c.height for c in cells) + max(m.height for m in mocks) + 3 * pad + 40
    out = Image.new('RGB', (width, height + splat.height + pad), (24, 24, 22))
    d = ImageDraw.Draw(out)
    x = 0
    for c in cells:
        out.paste(c, (x, 0))
        x += c.width
    y = max(c.height for c in cells) + pad
    d.text((pad, y), 'In the tab at the game scale (UI.S %.1f, seal %d design units): the stamp holding over the trees'
           % (S, SEAL_SIZE), font=label, fill=(220, 216, 200))
    y += 36
    x = 0
    for m in mocks:
        out.paste(m, (x, y))
        x += m.width + pad
    out.paste(splat.convert('RGB'), (0, y + max(m.height for m in mocks) + pad))
    return out


def main():
    tex = build()
    for (name, n), img in tex.items():
        path = os.path.join(TEXTURES, 'OA_%s_%d.png' % (name, n))
        img.save(path)
        print('wrote', os.path.relpath(path, ROOT))
    shade_img = shade()
    path = os.path.join(TEXTURES, 'OA_SealShade.png')
    shade_img.save(path)
    print('wrote', os.path.relpath(path, ROOT))
    preview(tex, shade_img).save(PREVIEW)
    print('wrote', os.path.relpath(PREVIEW, ROOT))


if __name__ == '__main__':
    main()
