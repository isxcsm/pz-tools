#!/usr/bin/env python3
"""The soft light of the research tab's prerequisite lines (Upgrades/Window.lua: the light that runs down a met
prerequisite's line, Motion.comet): a round white glow the game tints in the tree's light colour and draws at the
light's head (a wide faint one and a small bright core), and at a node it arrives at.

    py tools/glow_art.py      writes OperationAcorn/42/media/textures/OA_Glow.png (64 px, white, its alpha falling
                              smoothly from the middle to nothing at the edge) and tools/glow_preview.png (a pass of
                              the light down a line, frame by frame, drawn as the game draws it: the tapered tail,
                              the afterglow behind it and the arrival at the node).

The preview mirrors Motion.lua's numbers (kept in step by hand: COMET below) at the game's scale (UI.S about 1.6),
enlarged twice so the steps can be seen.
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
TEXTURES = os.path.join(ROOT, 'OperationAcorn', '42', 'media', 'textures')
PREVIEW = os.path.join(HERE, 'glow_preview.png')
SIZE = 64


def glow(n=SIZE):
    """White, alpha a soft bell: full in the middle, nothing at the edge (no ring where it is cut)."""
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    r = np.hypot(xs - n / 2 + 0.5, ys - n / 2 + 0.5) / (n / 2)
    bell = np.exp(-(r * 1.6) ** 2)
    edge = np.clip((1 - r) / 0.25, 0, 1)
    a = bell * edge * edge * (3 - 2 * edge)
    out = np.zeros((n, n, 4), np.uint8)
    out[..., :3] = 255
    out[..., 3] = (a / a.max() * 255).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


# ---- the preview: Motion.comet and Window's drawLine("comet") as the game runs them ---------------------------------
COMET = dict(speed=60, min_ms=450, alpha=0.9, tail=22, steps=6, after_ms=300, arrive_ms=250, head=6.0, core=2.5,
             arrive=10.0)
S = 1.6
TREE = (0.25, 0.66, 0.70)
LIGHT = (0.62, 0.90, 0.95)
BODY = (0.06 * 0.88 + 0.25 * 0.12, 0.065 * 0.88 + 0.66 * 0.12, 0.045 * 0.88 + 0.70 * 0.12)
ZOOM = 3


def col(c, a=1.0):
    return tuple(int(v * 255) for v in c) + (int(a * 255),)


def mix(c, over, a):
    return tuple(c[i] * (1 - a) + over[i] * a for i in range(3))


def comet(phase, length):
    """Motion.comet for one pass: head (design units), its strength, the tail's and the afterglow's lengths, the
    arrival's strength."""
    travel = max(COMET['min_ms'], length * 1000 / COMET['speed'])
    u = phase / travel
    head = length * u
    a = COMET['alpha'] * min(1, u / 0.12)
    after = min(length, length * COMET['after_ms'] / travel)
    tail = min(COMET['tail'], length * 0.6)
    v = phase - travel
    arrive = 0.0
    if v >= 0:
        w = v / COMET['arrive_ms']
        arrive = 0.0 if w >= 1 else min(1, w * 6) * (1 - w) ** 2
    return head, a, tail, after, arrive, travel


def frame(phase, length, glow_img, locked=False):
    """One frame of a straight line (from y 0 down to `length`) into a node."""
    w, h = int(70 * S), int((length + 60) * S)
    img = Image.new('RGBA', (w, h), col(BODY))
    d = ImageDraw.Draw(img)
    x = w // 2
    y0 = int(14 * S)
    lw = max(2, int(1.5 * S + 0.5))
    k = max(3, int(3 * S + 0.5))
    tip = k / S
    end = length - tip
    d.rectangle((x - lw // 2, y0, x - lw // 2 + lw - 1, y0 + int(end * S)), fill=col(TREE, 0.95))
    top = y0 + int(length * S) - k
    for i in range(k):
        ww = 2 * (k - i) - 1
        d.rectangle((x - ww // 2, top + i, x - ww // 2 + ww - 1, top + i), fill=col(TREE, 0.95))
    node_y = y0 + int(length * S)
    s = int(32 * S)
    d.rectangle((x - s // 2, node_y, x + s // 2, node_y + s), fill=col(mix(BODY, TREE, 0.35 if not locked else 0.12)))
    d.rectangle((x - s // 2 - 3, node_y - 3, x + s // 2 + 3, node_y + s + 3),
                outline=col(TREE if not locked else (0.42, 0.45, 0.30), 0.6))
    head, a, tail, after, arrive, _ = comet(phase, length)
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)

    def piece(s0, s1, width, alpha):
        s0, s1 = max(0, s0), min(end, s1)
        if s1 <= s0 or alpha <= 0:
            return
        ld.rectangle((x - width // 2, y0 + int(s0 * S), x - width // 2 + width - 1, y0 + int(s1 * S)),
                     fill=col(LIGHT, alpha))
    # the afterglow: the line brightened faintly where the head has passed
    for i in range(3):
        b0 = head - after * (i + 1) / 3
        piece(b0, head - after * i / 3, lw, 0.22 * (1 - i / 3) * (a if head <= length else 1))
    # the tail: the line lit behind the head, fading, with soft lights along it getting smaller and fainter
    n = COMET['steps']

    def sprite(at, size, alpha, tint):
        if at < 0 or at > end or alpha <= 0:
            return
        px = max(2, int(lw * size))
        g = glow_img.resize((px, px), Image.BICUBIC)
        g = Image.composite(Image.new('RGBA', g.size, col(tint, 1)), Image.new('RGBA', g.size, (0, 0, 0, 0)), g)
        g.putalpha(g.getchannel('A').point(lambda v: int(v * min(1, alpha))))
        layer.alpha_composite(g, (x - px // 2, y0 + int(at * S) - px // 2))
    for i in range(n):
        f = 1 - i / n
        piece(head - tail * (i + 1) / n, head - tail * i / n, lw, a * f * f * 0.7)
    for i in range(1, n + 1):
        f = 1 - i / (n + 1)
        sprite(head - tail * i / n, COMET['head'] * (0.35 + 0.55 * f), a * f * f * 0.55, LIGHT)
    if head <= length:
        sprite(min(head, end), COMET['head'], a * 0.85, LIGHT)
        sprite(min(head, end), COMET['core'], a, mix(LIGHT, (1, 1, 1), 0.6))
    if arrive > 0:
        strength = arrive * (0.35 if locked else 1)
        px = int(lw * COMET['arrive'])
        g = glow_img.resize((px, px), Image.BICUBIC)
        g = Image.composite(Image.new('RGBA', g.size, col(LIGHT, 1)), Image.new('RGBA', g.size, (0, 0, 0, 0)), g)
        g.putalpha(g.getchannel('A').point(lambda v: int(v * 0.7 * strength)))
        layer.alpha_composite(g, (x - px // 2, node_y - px // 2))
        ld.rectangle((x - s // 2 - 3, node_y - 3, x + s // 2 + 3, node_y + s + 3), outline=col(LIGHT, 0.8 * strength),
                     width=2)
    img.alpha_composite(layer)
    return img.resize((img.width * ZOOM, img.height * ZOOM), Image.NEAREST)


def preview(glow_img):
    length = 90
    _, _, _, _, _, travel = comet(0, length)
    phases = [travel * f for f in (0.05, 0.25, 0.5, 0.75, 0.95)] + [travel + 60, travel + 140, travel + 260]
    frames = [frame(p, length, glow_img) for p in phases]
    locked = frame(travel + 60, length, glow_img, locked=True)
    label = ImageFont.truetype('C:/Windows/Fonts/bahnschrift.ttf', 20)
    gap = 16
    w = sum(f.width for f in frames) + locked.width + gap * (len(frames) + 2)
    h = frames[0].height + 70
    out = Image.new('RGB', (w, h), (24, 24, 22))
    d = ImageDraw.Draw(out)
    x = gap
    for f, p in zip(frames + [locked], phases + [travel + 60]):
        out.paste(f.convert('RGB'), (x, 10))
        d.text((x, f.height + 18), '%d ms' % p, font=label, fill=(210, 206, 190))
        x += f.width + gap
    d.text((x - locked.width - gap, locked.height + 40), 'into a locked node', font=label, fill=(210, 206, 190))
    d.text((gap, h - 26), 'light on a lit line, %d du, UI.S %.1f, shown at %dx' % (length, S, ZOOM), font=label,
           fill=(160, 156, 140))
    return out


def main():
    img = glow()
    path = os.path.join(TEXTURES, 'OA_Glow.png')
    img.save(path)
    print('wrote', os.path.relpath(path, ROOT))
    preview(img).save(PREVIEW)
    print('wrote', os.path.relpath(PREVIEW, ROOT))


if __name__ == '__main__':
    main()
