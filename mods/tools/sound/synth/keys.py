"""Our own sounds made from numbers (SOUND-SYSTEM.md S5): a terminal's key (a short plastic click over a knock of unpitched
low-mid noise, the key bottoming out a moment after), its backspace (the same, a little duller).
Variants differ a little in pitch, timing and loudness, so a run of them does not sound like one sample.
Written as 32-bit float WAV into ../sources/synth/; the build trims and levels them.

    python -X utf8 synth/keys.py
"""
import os

import numpy as np
import soundfile as sf

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'sources', 'synth')


def noise(rng, n):
    return rng.standard_normal(n).astype(np.float64)


def highpass(x, hz):
    # one-pole high-pass
    a = np.exp(-2 * np.pi * hz / RATE)
    y = np.zeros_like(x)
    prev_x = prev_y = 0.0
    for i, v in enumerate(x):
        prev_y = a * (prev_y + v - prev_x)
        prev_x = v
        y[i] = prev_y
    return y


def lowpass(x, hz):
    a = np.exp(-2 * np.pi * hz / RATE)
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def env(n, attack_s, decay_s):
    t = np.arange(n) / RATE
    up = np.clip(t / max(attack_s, 1e-6), 0, 1)
    return up * np.exp(-np.maximum(t - attack_s, 0) / decay_s)


def click(rng, length_s, bright_hz, decay_s, gain, top_hz=6500):
    # a band of noise: a plastic click is bright but not a hiss (little above top_hz)
    n = int(length_s * RATE)
    return lowpass(lowpass(highpass(noise(rng, n), bright_hz), top_hz), top_hz) * env(n, 0.0004, decay_s) * gain


def body(rng, length_s, low_hz, high_hz, decay_s, gain):
    # the plastic's knock: a short burst of low-mid noise, no pitch (a sine there rang like a tapped drum)
    n = int(length_s * RATE)
    return lowpass(lowpass(highpass(noise(rng, n), low_hz), high_hz), high_hz) * env(n, 0.0005, decay_s) * gain


def key(rng, dull=False):
    """A key: the press's click over the cap's short knock, the bottom-out tick 12 to 22 ms later."""
    length = 0.06
    n = int(length * RATE)
    out = np.zeros(n)
    bright = rng.uniform(1800, 2600) * (0.7 if dull else 1)
    out[:int(0.03 * RATE)] += click(rng, 0.03, bright, rng.uniform(0.002, 0.0035), 1.0)
    knock = body(rng, 0.03, rng.uniform(300, 450), rng.uniform(1100, 1500) * (0.8 if dull else 1),
                 rng.uniform(0.004, 0.006), 0.6)
    out[:len(knock)] += knock
    at = int(rng.uniform(0.012, 0.022) * RATE)
    tick = click(rng, 0.015, bright * 1.3, rng.uniform(0.001, 0.002), rng.uniform(0.3, 0.4))
    out[at:at + len(tick)] += tick[:max(0, n - at)]
    if dull:
        out = lowpass(out, 4500)
    return out * rng.uniform(0.85, 1.0)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(347)
    made = []
    for kind, fn, count in (('key', lambda r: key(r), 6), ('erase', lambda r: key(r, dull=True), 4)):
        for i in range(1, count + 1):
            data = fn(rng)
            data = data / max(1e-9, np.max(np.abs(data))) * 0.8
            path = os.path.join(OUT, '%s_%d.wav' % (kind, i))
            sf.write(path, data.astype(np.float32), RATE, subtype='FLOAT')
            made.append(os.path.relpath(path, os.path.dirname(OUT)))
    print('\n'.join(made))


if __name__ == '__main__':
    main()
