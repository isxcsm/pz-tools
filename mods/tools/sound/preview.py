"""Sounds as the game would play them, to listen to outside the game (SOUND-SYSTEM.md S5), into report/preview_<name>.wav:

    python -X utf8 preview.py KIT_Key_1 [--cps 14] [--gap 40] [--chars 24] [--lines 3]
        one sound in a run: its built clips picked at random, one every 1/cps seconds (a little uneven, as typed),
        none closer than the gap, a pause between lines
    python -X utf8 preview.py --keyboard [--text "..."] [--cps 14] [--erase 10] [--erase-cps 10] [--gap 40]
        the kit's keyboard typing a text as PZUIKit.Sound does (Sound.keyOf: a letter key by the character's code,
        the space bar, the return for a new line), then its erasing key taking the last `erase` characters away at
        an even pace (the comms' erase)

The keyboard's keys are named as in PZUIKit/Sound.lua (KEYBOARD below; keep the two the same).
"""
import argparse
import glob
import os

import numpy as np
import soundfile as sf

from report import MODS, OUT, RATE, decode

KEYBOARD = {'letters': ['KIT_Key_%d' % i for i in range(1, 9)], 'space': 'KIT_KeySpace', 'enter': 'KIT_KeyEnter',
            'back': 'KIT_KeyBack'}
TEXT = '현장 승인 권한 밖의 사안입니다. 이상.\nCopy that, moving out.'


def clips(name):
    found = sorted(glob.glob(os.path.join(MODS, '*', '*', '42', 'media', 'sound', name + '_*.ogg')))
    if not found:
        raise SystemExit('no built clips of %s (python build.py first)' % name)
    return [decode(path) for path in found]


def key_of(char, erase=False):
    if erase:
        return KEYBOARD['back']
    if char == ' ':
        return KEYBOARD['space']
    if char == '\n':
        return KEYBOARD['enter']
    letters = KEYBOARD['letters']
    spread = ord(char) * 0.6180339887
    return letters[int((spread - int(spread)) * len(letters))]


def mix(plays, length):
    out = np.zeros(int((length + 0.5) * RATE), dtype=np.float32)
    rng = np.random.default_rng(7)
    cache = {}
    for at, name in plays:
        options = cache.setdefault(name, clips(name))
        clip = options[rng.integers(len(options))]
        i = int(at * RATE)
        out[i:i + len(clip)] += clip[:len(out) - i]
    return np.clip(out, -1, 1)


def write(name, data, plays, length):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'preview_%s.wav' % name)
    sf.write(path, data, RATE)
    print('%d plays over %.1f s -> %s' % (plays, length, path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('name', nargs='?')
    ap.add_argument('--keyboard', action='store_true')
    ap.add_argument('--text', default=TEXT)
    ap.add_argument('--cps', type=float, default=14.0)
    ap.add_argument('--gap', type=float, default=40.0, help='ms')
    ap.add_argument('--chars', type=int, default=24)
    ap.add_argument('--lines', type=int, default=3)
    ap.add_argument('--erase', type=int, default=10)
    ap.add_argument('--erase-cps', type=float, default=10.0)
    a = ap.parse_args()
    rng = np.random.default_rng(7)
    plays, t, last = [], 0.3, None
    if a.keyboard:
        for char in a.text:
            if last is None or (t - last) * 1000 >= a.gap:
                plays.append((t, key_of(char)))
                last = t
            t += 1 / a.cps * rng.uniform(0.75, 1.3) + (0.25 if char == '\n' else 0)
        t += 0.8
        for _ in range(a.erase):
            plays.append((t, key_of(None, erase=True)))
            t += 1 / a.erase_cps
        write('keyboard', mix(plays, t), len(plays), t)
        return
    if not a.name:
        raise SystemExit('a sound name, or --keyboard')
    for _ in range(a.lines):
        last = None
        for _ in range(a.chars):
            if last is None or (t - last) * 1000 >= a.gap:
                plays.append((t, a.name))
                last = t
            t += 1 / a.cps * rng.uniform(0.75, 1.3)
        t += 0.8
    write(a.name, mix(plays, t), len(plays), t)


if __name__ == '__main__':
    main()
