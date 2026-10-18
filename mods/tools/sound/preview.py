"""A sound as the game would play it in a run, to listen to outside the game (SOUND-SYSTEM.md S5): its built clips picked
at random, one every 1/cps seconds (a little uneven, as typed), none closer than the cue's gap, over a line's length; a
pause between lines. Written to report/preview_<name>.wav.

    python -X utf8 preview.py KIT_Key [--cps 14] [--gap 40] [--chars 24] [--lines 3]
"""
import argparse
import glob
import os

import numpy as np
import soundfile as sf

from report import MODS, OUT, RATE, decode


def clips(name):
    found = sorted(glob.glob(os.path.join(MODS, '*', '*', '42', 'media', 'sound', name + '_*.ogg')))
    if not found:
        raise SystemExit('no built clips of %s (python build.py first)' % name)
    return [decode(path) for path in found]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('name')
    ap.add_argument('--cps', type=float, default=14.0)
    ap.add_argument('--gap', type=float, default=40.0, help='ms')
    ap.add_argument('--chars', type=int, default=24)
    ap.add_argument('--lines', type=int, default=3)
    a = ap.parse_args()
    sounds = clips(a.name)
    rng = np.random.default_rng(7)
    starts, t = [], 0.3
    for _ in range(a.lines):
        last = None
        for _ in range(a.chars):
            if last is None or (t - last) * 1000 >= a.gap:
                starts.append(t)
                last = t
            t += 1 / a.cps * rng.uniform(0.75, 1.3)
        t += 0.8
    out = np.zeros(int((t + 0.5) * RATE), dtype=np.float32)
    for at in starts:
        clip = sounds[rng.integers(len(sounds))]
        i = int(at * RATE)
        out[i:i + len(clip)] += clip[:len(out) - i]
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'preview_%s.wav' % a.name)
    sf.write(path, np.clip(out, -1, 1), RATE)
    print('%d plays over %.1f s -> %s' % (len(starts), t, path))


if __name__ == '__main__':
    main()
