"""The terminal window's sounds made by Stable Audio 3 (SOUND-SYSTEM.md S8): one sound a cue, made for its moment.

The two terminals are two pieces of equipment, and sound like it. The field terminal (정식 단말) is the team's issued set: a solid
switch, a clean tube, a proper beep. The crude terminal (조립 단말) is put together from salvaged parts on a weak signal: a
loose toggle, a crackling surge, a buzzing transformer, a cheap speaker, and now and then the signal breaks up (the window's
weak signal spells). Each cue is one big beat of the picture (Trade/BootSeq), never its flickers.

Each sound is made for its moment, not picked from a spread:
- its prompt says that moment alone, the length asked is the picture's (BootSeq's times: the switch's dark beat 0.1 s, the
  raster opening 0.35 s, the static settling by 1 s; the switch-off's collapse 0.28 s; a jolt's 0.24 s);
- its target is a level curve over time (dB, points it passes through) set by the picture's beats: where the sound is
  loudest and how it dies with the picture (a first draft that followed the screen's brightness literally asked a 0.35 s
  plateau that no switch-on sounds like: a switch-on is a burst and a settling tail); of the model's tries (seeds) the one
  whose level (each 20 ms, against its loudest) is nearest to it is kept, less a second event after its first beat (the
  model often ends a sound with one more click);
- one terminal is one machine: its switch-off is made from its switch-on (the model from that sound, audio to audio), its
  bed from the settled whine of its switch-on, the crude one's jolt from its surge and its weak signal from its bed;
- a bed is made long and its steadiest stretch kept (a bed that swells or stops is heard as an event), its end laid over
  its start so that it loops without a seam;
- the shaping is the least: the leading silence off, a fade where the picture ends; a noise cue (static, crackle) is not
  cleaned of clicks (they are its sound).

Run with the Python of the Stable Audio 3 checkout, the game closed (the model needs the GPU's memory):

    ../../../../sa3/.venv/Scripts/python.exe ai_terminal.py [tier:cue ...] [--tries N]

It writes gen/term/<tier>_<cue>.ogg (the sound kept), gen/term/tries/ (every try, for a look), gen/term/made.json (each
kept sound's prompt, seed, source and fit) and installs the kept sounds (install_terminal_picks.py). A cue named alone is
made again from the sounds of its terminal already there.
"""
import json
import os
import subprocess
import sys

import numpy as np

import ai_titles as T
import build

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen', 'term')
TRIES_DIR = os.path.join(OUT, 'tries')
RATE = build.RATE
TRIES = 16
STEP = 0.01   # the targets' step (s)

# Said of every sound of a terminal, so that its cues are one machine.
MACHINE = {
    'field': 'military field computer terminal from the 1980s in a solid metal case, CRT monitor, close-miked, dry room, '
             'high quality recording',
    'crude': 'improvised computer terminal built from salvaged parts, old CRT monitor, loose cheap wiring, close-miked, dry '
             'room, high quality recording',
}

# BootSeq's numbers (s).
CLICK, OPEN, POWER = 0.10, 0.35, 1.0
COLLAPSE, SPLIT = 0.28, 0.6
SHAKE = 0.24


# The targets: (seconds, dB under the loudest) the level passes through, straight between.
# the switch-on: its beat is the switch (the screen opens on it), then the tube's settling under it to the bed (the
# picture's loud static is the picture's: the sound does not copy it, SOUND-SYSTEM.md S7's rule)
TARGET_POWER = [(0.0, -3), (0.05, 0), (0.2, -18), (POWER, -35), (1.3, -45)]
TARGET_OFF = [(0.0, 0), (COLLAPSE * SPLIT, -10), (COLLAPSE, -20), (0.6, -45)]  # the picture falling, the line, the dot out
TARGET_JOLT = [(0.0, 0), (SHAKE / 2, -6), (SHAKE, -20), (0.32, -45)]           # the shake dying out
# the welcome: two notes rising, the second held a moment (the boot's end, the one beat that answers the player)
TARGET_READY = [(0.0, -1), (0.12, -2), (0.14, 0), (0.36, -2), (0.5, -20), (0.6, -45)]
# a check line's work while its cursor blinks (WAIT_MS): the machine busy at once, at work all along, stopping as the
# result comes
WAIT = 0.9
TARGET_WORK = [(0.0, -4), (0.08, 0), (WAIT - 0.15, -2), (WAIT - 0.05, -18), (WAIT, -45)]
TARGET_LINE = [(0.0, 0), (0.08, -30), (0.15, -45)]                             # a tick


def target_db(points, t):
    for (t0, d0), (t1, d1) in zip(points, points[1:]):
        if t <= t1:
            return d0 + (d1 - d0) * (t - t0) / (t1 - t0)
    return points[-1][1]


# tier:cue -> how it is made. made: seconds asked; target: its curve (one-shots; busy: its events are its sound, not
# counted against it); end: where the picture is done with it
# (cut there after a fade of `fade` s, 0.05 by default: a switch-on's tube whine hands over to the bed over 0.3 s); loop: a bed (made long, its steadiest `keep` seconds kept); src: the cue it is made from, with `cut`
# (the part of it, seconds) and `noise`; tonal / noisy: its timbre (spectral flatness held against it, or for it).
CUES = {
    'field:power': dict(made=1.3, target=TARGET_POWER, end=1.3, fade=0.3, tonal=True, prompt=
        'a CRT monitor powering on: a soft switch thump, then a swelling rush of electrostatic charge and a bright rising '
        'tube whine that peaks after half a second and settles to quiet within one second'),
    'field:off': dict(made=0.7, target=TARGET_OFF, end=0.6, src='field:power', cut=(0.0, 0.7), noise=0.8, prompt=
        'the same CRT monitor switched off: a soft electric thump and a quick falling whine collapsing to silence'),
    'field:hum': dict(made=8.0, loop=True, keep=4.0, src='field:power', cut=(0.45, 1.0), noise=0.85, tonal=True, prompt=
        'the same CRT monitor running: a steady quiet high pitched whine and soft transformer hum, constant level, no clicks'),
    'field:ready': dict(made=0.7, target=TARGET_READY, end=0.6, tonal=True, rising=True, prompt=
        'a short bright two note rising confirmation chime from the terminal\'s internal speaker, clean square wave, the '
        'second note higher and held a moment, access granted'),
    'field:work': dict(made=1.0, target=TARGET_WORK, end=WAIT, busy=True, prompt=
        'the terminal\'s disk drive working for under one second: a fast run of soft mechanical head seeks and tiny '
        'relay clicks, busy and steady, then it stops'),
    'field:line': dict(made=0.3, target=TARGET_LINE, end=0.15, prompt=
        'a single very short soft relay tick inside the terminal'),
    'crude:power': dict(made=1.4, target=TARGET_POWER, end=1.3, fade=0.3, noisy=True, noise_cue=True, prompt=
        'an old CRT monitor powering on through loose wiring: a toggle snap, then a loud swelling burst of crackling static '
        'and electrical buzz that peaks after half a second and settles to a faint hiss within one second'),
    'crude:off': dict(made=0.7, target=TARGET_OFF, end=0.6, src='crude:power', cut=(0.0, 0.7), noise=0.8, noise_cue=True,
        prompt='the same old CRT monitor switching off with a crackling electric pop and a short falling whine'),
    'crude:hum': dict(made=8.0, loop=True, keep=4.0, src='crude:power', cut=(0.45, 1.1), noise=0.85, noisy=True,
        noise_cue=True, prompt='the same badly shielded old monitor running: a constant faint static hiss with sparse '
        'small crackles and a low mains buzz, steady level'),
    'crude:jolt': dict(made=0.4, target=TARGET_JOLT, end=0.32, src='crude:power', cut=(0.1, 0.5), noise=0.85, noisy=True,
        noise_cue=True, prompt='a single short burst of electrical crackle from a loose wire contact in the same machine'),
    'crude:ready': dict(made=0.7, target=TARGET_READY, end=0.5, rising=True, src='field:ready', cut=(0.0, 0.7),
        noise=0.5, prompt='the same two note rising beep played through a small cheap rattling speaker, slightly '
        'distorted, the second note higher and held a moment'),
    'crude:work': dict(made=1.0, target=TARGET_WORK, end=WAIT, busy=True, noise_cue=True, prompt=
        'an old worn tape drive chattering for under one second: rough mechanical clicks and whirring with small '
        'electrical crackles, busy and steady, then it stops'),
    'crude:line': dict(made=0.3, target=TARGET_LINE, end=0.15, noise_cue=True, prompt=
        'a single tiny dry electrical tick with a little crackle'),
    'crude:spell': dict(made=6.0, loop=True, keep=3.0, src='crude:hum', cut=None, noise=0.85, noisy=True, noise_cue=True,
        prompt='the same monitor\'s signal breaking up: rushing static with fluttering dropouts and radio interference'),
}
# The order a terminal's sounds are made in (each from the ones before it).
ORDER = ['field:power', 'field:off', 'field:hum', 'field:ready', 'field:line', 'field:work',
         'crude:power', 'crude:off', 'crude:hum', 'crude:jolt', 'crude:ready', 'crude:line', 'crude:work', 'crude:spell']

LOOP_XFADE = 0.25


def clean_noise(x):
    """A noise cue's cleaning: only the rumble under hearing and the grain at the very top; its clicks stay."""
    from scipy import signal
    x = signal.sosfiltfilt(signal.butter(2, 35, 'highpass', fs=RATE, output='sos'), x)
    x = signal.sosfiltfilt(signal.butter(2, 12000, 'lowpass', fs=RATE, output='sos'), x)
    return x.astype(np.float32)


def envelope(x, step=STEP):
    n = int(step * RATE)
    k = max(1, len(x) // n)
    return np.sqrt(np.mean(np.pad(x, (0, max(0, k * n - len(x))))[:k * n].reshape(k, n) ** 2, axis=1))


FIT_STEP, FLOOR = 0.02, -50.0


def fit(x, c):
    """How near x's level (each 20 ms, dB under its loudest, nothing under FLOOR) is to its target: minus the mean distance
    (per 10 dB), less half a point for each second event after its first 0.15 s (a rise of 12 dB over the lowest of the
    100 ms before)."""
    target = np.array([target_db(c['target'], i * FIT_STEP) for i in range(int(c['end'] / FIT_STEP) + 1)])
    env = envelope(x, FIT_STEP)
    db = np.maximum(FLOOR, 20 * np.log10(env / (env.max() or 1.0) + 1e-9))
    db = np.pad(db, (0, max(0, len(target) - len(db))), constant_values=FLOOR)[:len(target)]
    distance = float(np.mean(np.abs(db - np.maximum(FLOOR, target)))) / 10
    if c.get('busy'):
        return -distance
    events = sum(1 for i in range(int(0.15 / FIT_STEP), len(db)) if db[i] - db[max(0, i - 5):i].min() > 12)
    return -distance - 0.5 * events


def flatness(x):
    seg = x[:min(len(x), RATE)]
    if len(seg) < 1024:
        seg = np.pad(seg, (0, 1024 - len(seg)))
    f = np.fft.rfftfreq(len(seg), 1 / RATE)
    spec = (np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) + 1e-9)[(f > 100) & (f < 8000)]
    return float(np.exp(np.mean(np.log(spec))) / np.mean(spec))


def timbre(x, c):
    if c.get('tonal'):
        return -0.5 * flatness(x)
    if c.get('noisy'):
        return 0.5 * flatness(x)
    return 0.0


def pitch(x):
    """The strongest frequency (300 Hz to 6 kHz) of x."""
    if len(x) < 2048:
        return 0.0
    f = np.fft.rfftfreq(len(x), 1 / RATE)
    m = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    band = (f > 300) & (f < 6000)
    return float(f[band][np.argmax(m[band])])


def contour(x, c):
    """A rising cue's two notes (the first in 0.02 to 0.12 s, the second in 0.2 to 0.38 s, TARGET_READY's): nothing when
    the second is higher (by a tenth or more) and both sound, else two points off (the model often turned a rising pair
    the other way, or let its second note die)."""
    if not c.get('rising'):
        return 0.0
    a, b = x[int(0.02 * RATE):int(0.12 * RATE)], x[int(0.2 * RATE):int(0.38 * RATE)]
    rms = lambda v: float(np.sqrt(np.mean(v * v))) + 1e-9
    heard = 20 * np.log10(min(rms(a), rms(b)) / max(rms(a), rms(b))) > -12
    return 0.0 if heard and pitch(b) > 1.1 * pitch(a) else -2.0


def steadiest(x, keep, frame):
    """The stretch of x `keep` seconds long whose level (each `frame` s) varies least; its spread (dB)."""
    n = int(keep * RATE)
    best = None
    for start in range(int(0.3 * RATE), max(int(0.3 * RATE) + 1, len(x) - n - int(LOOP_XFADE * RATE)), int(0.25 * RATE)):
        seg = x[start:start + n + int(LOOP_XFADE * RATE)]
        if len(seg) < n:
            break
        spread = float(np.std(20 * np.log10(envelope(seg[:n], frame) + 1e-9)))
        if best is None or spread < best[0]:
            best = (spread, seg)
    return best


def looped(x, seconds):
    n, k = int(seconds * RATE), int(LOOP_XFADE * RATE)
    x = np.pad(x, (0, max(0, n + k - len(x))))
    body, over = x[:n].copy(), x[n:n + k]
    t = np.linspace(0, 1, k, dtype=np.float32)
    body[:k] = body[:k] * np.sin(t * np.pi / 2) + over * np.cos(t * np.pi / 2)
    return body


def tile(x, seconds):
    """x repeated (each join laid over the last) to `seconds`: a source for a long sound made from a short one."""
    out = x.copy()
    k = min(int(0.05 * RATE), len(x) // 4)
    while len(out) < seconds * RATE:
        t = np.linspace(0, 1, k, dtype=np.float32)
        out = np.concatenate([out[:-k], out[-k:] * (1 - t) + x[:k] * t, x[k:]])
    return out[:int(seconds * RATE)]


def shape(x, c):
    """The least shaping: cleaned, a one-shot from its first sound with a fade where the picture ends; a bed's steadiest
    stretch, looped."""
    x = (clean_noise if c.get('noise_cue') else T.clean)(x)
    if c.get('loop'):
        spread, seg = steadiest(x, c['keep'], 0.25 if c.get('noisy') else 0.1)
        return T.peak_to(looped(seg, c['keep']), T.PEAK_DB), -spread
    x = T.lead_trim(x)
    n, f = int(c['end'] * RATE), int(c.get('fade', 0.05) * RATE)
    x = x[:n].copy()
    f = min(f, len(x))
    x[len(x) - f:] *= np.linspace(1, 0, f, dtype=np.float32) ** 2
    return T.peak_to(x, T.PEAK_DB), fit(x, c)


def main(argv):
    tries = TRIES
    if '--tries' in argv:
        i = argv.index('--tries')
        tries = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    only = [a for a in argv if not a.startswith('-')] or ORDER
    os.makedirs(TRIES_DIR, exist_ok=True)
    made_path = os.path.join(OUT, 'made.json')
    made = json.load(open(made_path, encoding='utf-8')) if os.path.exists(made_path) else {}
    maker = T.Maker('medium')
    for key in [k for k in ORDER if k in only]:
        c = CUES[key]
        tier = key.split(':')[0]
        prompt = c['prompt'] + ', ' + MACHINE[tier]
        stem = key.replace(':', '_')
        results = []
        if c.get('src'):
            src = build.decode(os.path.join(OUT, c['src'].replace(':', '_') + '.ogg'))
            if c.get('cut'):
                src = src[int(c['cut'][0] * RATE):int(c['cut'][1] * RATE)]
            start = tile(src, c['made']) if c.get('loop') or len(src) < c['made'] * RATE else src[:int(c['made'] * RATE)]
            for i in range(tries):
                x = maker.make([prompt], 1000 + i, c['made'], start=start, noise=c['noise'])[0]
                results.append((x, 1000 + i))
        else:
            for i, x in enumerate(maker.make([prompt] * tries, 1000, c['made'])):
                results.append((x, 'batch 1000 item %d' % i))
        scored = []
        for n, (x, seed) in enumerate(results):
            y, score = shape(x, c)
            score += timbre(y, c) + contour(y, c)
            name = '%s_try%d.ogg' % (stem, n + 1)
            build.encode(y, os.path.join(TRIES_DIR, name))
            scored.append((score, y, seed, name))
            print('  %-12s try %d  %.3f' % (key, n + 1, score), flush=True)
        scored.sort(key=lambda r: -r[0])
        score, y, seed, name = scored[0]
        build.encode(y, os.path.join(OUT, stem + '.ogg'))
        made[key] = dict(prompt=prompt, seed=seed, made=c['made'], src=c.get('src'), noise=c.get('noise'), fit=round(score, 3),
                         tried=len(scored), kept=name)
        json.dump(made, open(made_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print('%s: kept %s (%.3f; the others %s)' % (key, name, score, ', '.join('%.2f' % r[0] for r in scored[1:])), flush=True)
    picks = ['%s=%s.ogg' % (k, k.replace(':', '_')) for k in ORDER if os.path.exists(os.path.join(OUT, k.replace(':', '_') + '.ogg'))]
    subprocess.run([sys.executable, '-X', 'utf8', os.path.join(HERE, 'install_terminal_picks.py')] + picks, check=True,
                   stdin=subprocess.DEVNULL)


if __name__ == '__main__':
    main(sys.argv[1:])
