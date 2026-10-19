"""The terminal window's sound candidates made by Stable Audio 3 (SOUND-SYSTEM.md S8), for the user to hear in the terminal lab
(lab/terminal.html) and pick.

The two terminals are two pieces of equipment, and sound like it. The field terminal (정식 단말) is the team's issued set: a solid
switch, a clean tube, a proper beep. The crude terminal (조립 단말) is put together from salvaged parts on a weak signal: a
clunky toggle, a crackling surge, a buzzing transformer, a cheap speaker, and now and then the signal drops (the window's weak
signal spells, Trade/BootSeq.weakSignal). Each cue is one big beat of the picture (Trade/BootSeq: the screen coming on, the
welcome, the switch-off; the crude one's jolts and spells), never its flickers; a bed loops under the boot and follows the
static's loudness. The boot plays on every open, so all of it is short and quiet.

A cue is new (its prompts at several seeds, one batch) and is shaped as ai_titles does (its leading silence off, its loudest
moment moved to `at`, its tail's silence off, a peak) with two differences: a noise cue (static, crackle) is not cleaned of
clicks (they are the sound), and a loop (`loop`) is made `made` long and its end laid over its start, so that it repeats
without a seam.

Run with the Python of the Stable Audio 3 checkout, the game closed (the model needs the GPU's memory):

    ../../../../sa3/.venv/Scripts/python.exe ai_terminal.py [cue ...] [--count N]

It writes gen/term/<tier>_<cue>_<nn>.ogg, gen/term/manifest.js ({"tier:cue": [files]}, what the terminal lab lists, a pick
first) and gen/term/prompts.json (each file's prompt and seed). Picks go to terminal_picks.json (pick_terminal.py); a picked cue
keeps its pick when made again.
"""
import json
import os
import sys

import numpy as np

import ai_titles as T
import build

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen', 'term')
PICKS = os.path.join(HERE, 'terminal_picks.json')
RATE = build.RATE
CANDIDATES = 6

# Said of every sound of a tier, so that its cues are one machine.
FAMILY = {
    'field': 'military field computer terminal from the 1980s, CRT monitor, close-miked, dry room, high quality recording',
    'crude': 'improvised computer terminal built from salvaged parts, old CRT monitor, cheap wiring, close-miked, dry room, '
             'high quality recording',
}

# tier:cue -> dict(made, at, prompts[, loop][, noise]). made: seconds asked of the model (a loop: its length); at: when its
# loudest moment comes (None: where the model put it); noise: static or crackle, not cleaned of clicks.
CUES = {
    'field:power': dict(made=1.6, at=0.12, prompts=[
        'a solid power switch clicks on, then a cathode ray tube warms up with a short soft rising whine that settles',
        'heavy relay clunk, CRT monitor powering on, brief degauss hum fading to quiet',
    ]),
    'field:hum': dict(made=4.0, at=None, loop=True, prompts=[
        'steady quiet high pitched CRT monitor whine and soft electrical hum, constant, no changes',
        'faint constant hum of a running computer terminal, gentle tube whine, steady',
    ]),
    'field:ready': dict(made=1.0, at=0.0, prompts=[
        'one short clean electronic beep from a computer terminal speaker, system ready',
        'short two tone confirmation beep, computer terminal, clean',
    ]),
    'field:off': dict(made=0.9, at=0.15, prompts=[
        'CRT monitor switching off, a soft thump and a short falling whine',
        'old television screen turning off, quick soft electric pop collapsing to silence',
    ]),
    'field:line': dict(made=0.35, at=0.0, prompts=[
        'a tiny soft electronic tick, computer terminal, very short',
        'very short quiet relay tick',
    ]),
    'crude:power': dict(made=1.8, at=0.12, noise=True, prompts=[
        'a clunky toggle switch flipped on, then a surge of crackling static and a buzzing transformer that settles down',
        'loose power switch snaps on, electrical buzz and loud static burst from an old CRT, fading to a crackling hiss',
    ]),
    'crude:hum': dict(made=4.0, at=None, loop=True, noise=True, prompts=[
        'steady soft static hiss with occasional small crackles and a low mains buzz, constant',
        'constant faint electrical hiss and crackle of a badly shielded old monitor, low buzz underneath',
    ]),
    'crude:jolt': dict(made=0.45, at=0.0, noise=True, prompts=[
        'short sharp electrical crackle from a loose connection',
        'brief burst of static and a small electric zap, bad contact',
    ]),
    'crude:ready': dict(made=1.0, at=0.0, prompts=[
        'one short electronic beep through a cheap rattling speaker, slightly distorted',
        'short buzzy beep from a small cheap speaker, a little off pitch',
    ]),
    'crude:off': dict(made=0.9, at=0.15, noise=True, prompts=[
        'old CRT monitor switching off with a crackling pop and a short falling whine',
        'television turning off, electric snap and a burst of static collapsing to silence',
    ]),
    'crude:line': dict(made=0.35, at=0.0, noise=True, prompts=[
        'a tiny dry electrical tick with a little crackle, very short',
        'very short click of a cheap relay',
    ]),
    'crude:spell': dict(made=3.0, at=None, loop=True, noise=True, prompts=[
        'radio signal breaking up, rushing static with fluttering dropouts and interference',
        'weak signal interference, white noise swelling and stuttering, analog dropout',
    ]),
}

# How long the end of a loop is laid over its start.
LOOP_XFADE = 0.25


def clean_noise(x):
    """A noise cue's cleaning: only the rumble under hearing (below 35 Hz) and the grain at the very top (above 12 kHz); its
    clicks and crackle stay."""
    from scipy import signal
    x = signal.sosfiltfilt(signal.butter(2, 35, 'highpass', fs=RATE, output='sos'), x)
    x = signal.sosfiltfilt(signal.butter(2, 12000, 'lowpass', fs=RATE, output='sos'), x)
    return x.astype(np.float32)


def looped(x, seconds):
    """x as a loop `seconds` long: its first LOOP_XFADE laid under its end's last (equal power), so that the end runs into
    the start."""
    n, k = int(seconds * RATE), int(LOOP_XFADE * RATE)
    x = np.pad(x, (0, max(0, n + k - len(x))))
    body, over = x[:n].copy(), x[n:n + k]
    t = np.linspace(0, 1, k, dtype=np.float32)
    body[:k] = body[:k] * np.sin(t * np.pi / 2) + over * np.cos(t * np.pi / 2)
    return body


def shape(c, x):
    clean = clean_noise if c.get('noise') else T.clean
    if c.get('loop'):
        # (from 0.3 s in: past whatever the model starts with)
        y = clean(x)[int(0.3 * RATE):]
        return T.peak_to(looped(y, c['made']), T.PEAK_DB)
    y = clean(T.lead_trim(x))
    if c['at'] is not None:
        y = T.place(y, c['at'])
    return T.peak_to(T.tail_trim(y), T.PEAK_DB)


def main(argv):
    count = CANDIDATES
    if '--count' in argv:
        i = argv.index('--count')
        count = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    only = [a for a in argv if not a.startswith('-')] or list(CUES)
    os.makedirs(OUT, exist_ok=True)
    picks = json.load(open(PICKS, encoding='utf-8')) if os.path.exists(PICKS) else {}
    manifest_path, prompts_path = os.path.join(OUT, 'manifest.json'), os.path.join(OUT, 'prompts.json')
    manifest = json.load(open(manifest_path, encoding='utf-8')) if os.path.exists(manifest_path) else {}
    told = json.load(open(prompts_path, encoding='utf-8')) if os.path.exists(prompts_path) else {}

    def save():
        json.dump(manifest, open(manifest_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        json.dump(told, open(prompts_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        with open(os.path.join(OUT, 'manifest.js'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('window.TERMINAL_SOUND_CANDIDATES = ' + json.dumps(manifest, indent=1) + ';\n')
            f.write('window.TERMINAL_SOUND_PICKS = ' + json.dumps({k: v['file'] for k, v in picks.items()}, indent=1) + ';\n')

    maker = T.Maker('medium')
    for key in only:
        c = CUES[key]
        tier = key.split(':')[0]
        pick = picks.get(key)
        keep = [pick['file']] if pick else []
        for f in manifest.get(key, []):
            if f not in keep and os.path.exists(os.path.join(OUT, f)):
                os.remove(os.path.join(OUT, f))
                told.pop(f, None)
        stem = key.replace(':', '_')
        names = [n for n in ('%s_%02d.ogg' % (stem, i) for i in range(1, 100)) if n not in keep][:count]
        prompts = [c['prompts'][i % len(c['prompts'])] + ', ' + FAMILY[tier] for i in range(count)]
        # (a loop is asked for a little more than its length: the part laid over its start, and the start skipped)
        made = c['made'] + (LOOP_XFADE + 0.5 if c.get('loop') else 0)
        files = list(keep)
        for i, x in enumerate(maker.make(prompts, 1000, made)):
            y = shape(c, x)
            build.encode(y, os.path.join(OUT, names[i]))
            told[names[i]] = dict(prompt=prompts[i], seed=1000, batch=count, item=i, made=made, at=c['at'],
                                  loop=bool(c.get('loop')), noise=bool(c.get('noise')))
            files.append(names[i])
            print(names[i], '%.2fs' % (len(y) / RATE), flush=True)
        manifest[key] = files
        save()


if __name__ == '__main__':
    main(sys.argv[1:])
