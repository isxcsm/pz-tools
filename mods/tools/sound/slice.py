"""The single strokes in a recording of many (SOUND-SYSTEM.md S5): a keyboard typed on, a printer's lines. Finds each
stroke (librosa's onsets, each moved to its hit: the first sample within HIT_DB of the stroke's own peak) and prints one
row a stroke: when it hits, how clear it is (the time to the next hit), its peak, and the frequency its first 30 ms
centre on; writes a picture of the whole recording with the hits numbered, report/slice_<name>.png. sounds.json then
takes a stroke by its start and end in the recording (clip `start`, `end`), so the source stays whole: a start a little
before the hit (PRE_S) and an end before the next.

    python -X utf8 slice.py sources/commons/Typing_-_Model_M_1986.ogg [--delta 0.07] [--from 0] [--to 12] [--clear 0.06]

--clear lists only the strokes with at least that much time before the next (fast typing runs a press into its key's
release and the next key). A spacebar is lower than a letter; a return rings longest.
"""
import argparse
import os

import librosa
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from report import OUT, RATE, db, decode  # noqa: E402

HIT_DB = -10.0
LOOK_S = 0.08


def hits(data, delta):
    onsets = librosa.onset.onset_detect(y=data, sr=RATE, units='samples', backtrack=True, delta=delta,
                                        pre_max=3, post_max=3, wait=int(0.03 * RATE / 512))
    found = []
    for at in onsets:
        window = np.abs(data[int(at):int(at) + int(LOOK_S * RATE)])
        if len(window) < 64:
            continue
        peak = float(window.max())
        hit = int(at) + int(np.nonzero(window >= peak * 10 ** (HIT_DB / 20))[0][0])
        if not found or hit - found[-1] > int(0.01 * RATE):
            found.append(hit)
    return found


def rows(data, delta):
    found = hits(data, delta)
    out = []
    for i, hit in enumerate(found):
        nxt = found[i + 1] if i + 1 < len(found) else len(data)
        head = data[hit:min(nxt, hit + int(0.03 * RATE))]
        if len(head) < 32:
            continue
        spectrum = np.abs(np.fft.rfft(head * np.hanning(len(head))))
        freqs = np.fft.rfftfreq(len(head), 1 / RATE)
        out.append({'hit': hit / RATE, 'clear': (nxt - hit) / RATE, 'peak': db(np.abs(data[hit:nxt]).max()),
                    'centre': float((freqs * spectrum).sum() / max(spectrum.sum(), 1e-9))})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    ap.add_argument('--delta', type=float, default=0.07)
    ap.add_argument('--from', dest='first', type=float, default=0.0)
    ap.add_argument('--to', type=float, default=None)
    ap.add_argument('--clear', type=float, default=0.0)
    a = ap.parse_args()
    data = decode(a.path)
    end = int(a.to * RATE) if a.to else len(data)
    data = data[int(a.first * RATE):end]
    table = rows(data, a.delta)
    print('%4s %8s %7s %7s %8s' % ('n', 'hit', 'clear', 'peak', 'centre'))
    for n, r in enumerate(table, 1):
        if r['clear'] >= a.clear:
            print('%4d %8.3f %7.3f %7.1f %8.0f' % (n, r['hit'] + a.first, r['clear'], r['peak'], r['centre']))
    os.makedirs(OUT, exist_ok=True)
    name = os.path.splitext(os.path.basename(a.path))[0]
    fig, ax = plt.subplots(figsize=(max(9, len(data) / RATE * 1.2), 3))
    ax.plot(np.arange(len(data)) / RATE + a.first, data, linewidth=0.4, color='#335')
    for n, r in enumerate(table, 1):
        ax.axvline(r['hit'] + a.first, color='#c33', linewidth=0.5)
        ax.text(r['hit'] + a.first, 0.9, str(n), fontsize=6, color='#c33')
    ax.set_ylim(-1, 1)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, 'slice_%s.png' % name), dpi=90)
    plt.close(fig)
    print('%d strokes -> %s' % (len(table), os.path.join(os.path.relpath(OUT), 'slice_%s.png' % name)))


if __name__ == '__main__':
    main()
