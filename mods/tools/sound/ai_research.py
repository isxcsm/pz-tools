"""The research tab's sounds made by Stable Audio 3: the body taking an applied selection (Plan's take, SOUND-SYSTEM.md S9).

The take is the payoff of the player's own choice, a few times an hour: heard, not a title. Its two big beats, one sound
each, of the titles' family (ai_titles.FAMILY):
- take: the scan starts, the first node bursts. A single soft deep pulse blooming into a short warm tone; the scan's
  other nodes are its flickers (no sound);
- glow: the light runs round the columns that took points and they light softly behind it (Plan.takeGlow). Its run is
  the beat: it leaves fast and slows more and more (an ease out, cubic) so that the two ways meet gently at the bottom,
  the columns' light fading after. A warm swell up as the light leaves, dying with its speed (a first target that swelled
  to the meeting, with the columns' brightness, asked what the model would not make: of 64 tries the swells peaked
  within the first second, a reversed one cut off dead). Made first; the take is made from its settled part (audio to
  audio), so that the two are one sound's beats.

Each is made for its moment as the terminal's are (ai_terminal.py: its target curve from the picture's numbers, the try
whose level follows it best kept). The kept sound goes to sources/ai/oa_research_<cue>.ogg (its prompt and seed in
gen/research/made.json and sources/LICENSES.csv) and build.py makes the game's OA_Research_<Cue> from it at its loudness
(sounds.json `lufs`).

Run with the Python of the Stable Audio 3 checkout, the game closed (the model needs the GPU's memory):

    ../../../../sa3/.venv/Scripts/python.exe ai_research.py [cue ...] [--tries N]
"""
import json
import os
import subprocess
import sys

import ai_terminal as A
import ai_titles as T
import build

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen', 'research')
TRIES_DIR = os.path.join(OUT, 'tries')
SOURCES = os.path.join(HERE, 'sources', 'ai')
RATE = build.RATE

# Plan's numbers (s): the glow's whole and the share of it the light runs round.
GLOW, TRACE = 2.0, 0.86
# the light's speed round the frame (Plan.takeGlow: along = 1 - (1 - p)^3, p = t / (GLOW * TRACE)), in dB under its
# start: 3 (1 - p)^2 falls 12 dB by half way, 29 by 0.81


def speed_db(t):
    import math
    p = min(1.0, t / (GLOW * TRACE))
    return 40 * math.log10(max(1e-3, 1 - p))

CUES = {
    'glow': dict(made=3.0, end=GLOW + 0.4, fade=0.4, tonal=True,
                 target=[(0.0, -14), (0.35, 0), (0.86, speed_db(0.86)), (1.4, speed_db(1.4)), (GLOW * TRACE, -32),
                         (GLOW, -36), (GLOW + 0.4, -45)], prompt=
        'a warm airy shimmering tone slowly swelling up over nearly two seconds, then softly fading out with a short '
        'lingering tail'),
    'take': dict(made=1.2, end=0.9, fade=0.3, tonal=True, src='glow', cut=(1.0, 2.2), noise=0.9,
                 target=[(0.0, -2), (0.04, 0), (0.3, -14), (0.9, -40)], prompt=
        'a single soft deep pulse, a muted low impact blooming into a short warm glowing tone that fades within a second'),
}
ORDER = ['glow', 'take']


def main(argv):
    tries = A.TRIES
    if '--tries' in argv:
        i = argv.index('--tries')
        tries = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    only = [a for a in argv if not a.startswith('-')] or ORDER
    os.makedirs(TRIES_DIR, exist_ok=True)
    os.makedirs(SOURCES, exist_ok=True)
    made_path = os.path.join(OUT, 'made.json')
    made = json.load(open(made_path, encoding='utf-8')) if os.path.exists(made_path) else {}
    maker = T.Maker('medium')
    for key in [k for k in ORDER if k in only]:
        c = CUES[key]
        prompt = c['prompt'] + ', ' + T.FAMILY
        results = []
        if c.get('src'):
            src = build.decode(os.path.join(SOURCES, 'oa_research_%s.ogg' % c['src']))
            src = src[int(c['cut'][0] * RATE):int(c['cut'][1] * RATE)]
            # (one batch: 8 from a sound took 34 s, one at a time 12 s each, the model swapped for its decoder each time)
            for i, x in enumerate(maker.make([prompt] * tries, 1000, c['made'], start=src, noise=c['noise'])):
                results.append((x, 'batch 1000 item %d' % i))
        else:
            for i, x in enumerate(maker.make([prompt] * tries, 1000, c['made'])):
                results.append((x, 'batch 1000 item %d' % i))
        scored = []
        for n, (x, seed) in enumerate(results):
            y, score = A.shape(x, c)
            score += A.timbre(y, c)
            name = 'research_%s_try%d.ogg' % (key, n + 1)
            build.encode(y, os.path.join(TRIES_DIR, name))
            scored.append((score, y, seed, name))
            print('  %-6s try %d  %.3f' % (key, n + 1, score), flush=True)
        scored.sort(key=lambda r: -r[0])
        score, y, seed, name = scored[0]
        build.encode(y, os.path.join(SOURCES, 'oa_research_%s.ogg' % key))
        made[key] = dict(prompt=prompt, seed=seed, made=c['made'], src=c.get('src'), noise=c.get('noise'),
                         fit=round(score, 3), tried=len(scored), kept=name)
        json.dump(made, open(made_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print('%s: kept %s (%.3f; the others %s)' % (key, name, score, ', '.join('%.2f' % r[0] for r in scored[1:])),
              flush=True)
    subprocess.run([sys.executable, '-X', 'utf8', os.path.join(HERE, 'build.py'), 'OA_Research_Take', 'OA_Research_Glow'],
                   check=True, stdin=subprocess.DEVNULL)


if __name__ == '__main__':
    main(sys.argv[1:])
