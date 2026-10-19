"""Title sound candidates made by Stable Audio 3 Small-SFX (SOUND-SYSTEM.md S7), for the user to hear in the title lab and pick.

Each cue of a title style gets CANDIDATES sounds: its prompts (two or three wordings of the same sound) at several seeds. The
model's output is only cut to the cue's length (leading silence off, a short fade at the end), made mono at 44.1 kHz and set to
one peak; a hold is made a seamless loop by a crossfade of its end into its start. Nothing is layered or bent: what is heard is
what the model made.

Run with the Python of the Stable Audio 3 checkout (C:/git/pz-workspace/sa3, its .venv), the model's licence accepted and
`hf auth login` done once:

    ../../../../sa3/.venv/Scripts/python.exe ai_titles.py [cue ...] [--count N]

It writes gen/<style>_<cue>_<nn>.ogg, gen/manifest.json and manifest.js ({"style:cue": [files]}, what the lab's sound panel
lists), and gen/prompts.json (each file's prompt and seed, to make a picked one again). `--manifest` only writes manifest.js
again from manifest.json.
"""
import json
import os
import sys

import numpy as np

import build

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen')
RATE = build.RATE
PEAK_DB = -3.0
CANDIDATES = 8

# What every prompt is not: the model hears these as things to keep out (only with cfg_scale > 1).
NEGATIVE = 'voices, people talking, crowd, music, melody, background ambience, room noise, hiss, distortion, low quality'

# The cues: style:cue -> (seconds made, seconds kept, loop, prompts). A cue's sound starts at its moment in the title (SOUND-SYSTEM.md
# S7's table: enter, land, hold, leave); "kept" is the visual's own length there.
CUES = {
    'stamp:land': (1.5, 1.0, False, [
        'A single rubber stamp pressed hard onto a sheet of paper on a wooden desk, close-up, dry, sharp thud with a low body',
        'Official document stamp hitting paper on a heavy desk, one firm impact, close microphone, clean studio recording',
        'Hand stamp slammed down on paper, one punchy dull thump, short and clean, foley',
    ]),
    'stamp:land_line': (1.0, 0.6, False, [
        'A small rubber stamp tapped onto paper, one light dry thud, close-up, clean foley',
        'Light stamp press on a sheet of paper, single soft impact, studio recording',
    ]),
    'notice:enter': (1.5, 1.0, False, [
        'An old CRT television switching on, a rising high-pitched electrical whine, short, clean',
        'Radio signal locking in, a rising electronic hum with a faint interference sweep, sci-fi interface, clean',
        'A high-frequency transformer hum swelling up quickly, electric tone, clean recording',
    ]),
    'notice:hold': (8.0, 4.0, True, [
        'Steady high-pitched CRT television whine, constant electrical hum, quiet, clean, no clicks',
        'Constant quiet high-frequency electronic drone with a slow gentle beating, transformer hum, clean',
    ]),
    'notice:leave': (5.0, 4.5, False, [
        'An old CRT television switching off, electrical whine dropping and fading out with brief signal interference',
        'Electronic signal lost, a high hum wavering with interference then dying away, clean',
        'Power down of an electrical device, a high-pitched hum falling in pitch and fading to silence',
    ]),
    'dust:leave': (11.0, 10.0, False, [
        'A sheet of paper catching fire and burning, crackling flames, close-up, then the fire dies and embers fade',
        'Paper burning slowly with soft crackles and rustling, flames dying down to faint embers, clean foley, no voices',
        'Match lit, paper ignites and burns with crackling, fire slowly burns out, quiet ending',
    ]),
    'discovery:enter': (3.0, 2.2, False, [
        'A match struck and a torch catching fire with a whoosh, flame roaring up, close-up',
        'Torch ignition, a strike and a soft fiery whoosh as the flame grows, clean foley',
        'Lighter flick and a flame bursting alight with a warm whoosh',
    ]),
    'discovery:hold': (8.0, 6.0, True, [
        'Small torch flame burning steadily, soft crackling fire, close-up, constant, clean, no wind',
        'Gentle steady fire crackle of a small flame, continuous, quiet, clean foley',
    ]),
    'discovery:leave': (5.0, 4.5, False, [
        'A torch flame dying down, the fire sputtering and fading out to silence',
        'Small fire burning out, crackles thinning and the flame going out softly',
    ]),
    'unveil:enter': (4.5, 3.6, False, [
        'A soft rising airy whoosh, gentle wind swelling up slowly, cinematic, smooth, clean',
        'Slow breathy air swell building up, misty atmospheric whoosh, no music',
    ]),
    'unveil:leave': (6.0, 5.0, False, [
        'A soft airy whoosh receding, gentle wind fading away slowly, cinematic, smooth, clean',
        'Breathy air swell drawing away into silence, misty atmospheric wind fade out',
    ]),
    'sink:leave': (10.0, 9.0, False, [
        'Something slowly sinking into water, gentle splash then muffled underwater sound with rising bubbles',
        'Object submerging, water closing over it, deep muffled underwater ambience and bubbles fading',
        'Slow underwater descent, soft water movement and bubbles, muffled, calm, fading out',
    ]),
    'pulse:hold': (8.0, 6.0, True, [
        'Slow deep muffled heartbeat, low thumping, steady rhythm, close, clean, no music',
        'Low heavy heartbeat heard from inside the body, steady slow pulse, muffled',
    ]),
    'pulse:leave': (12.0, 10.7, False, [
        'A slow muffled heartbeat getting slower and slower and stopping, then a long soft exhale',
        'Deep heartbeat slowing down, last few beats fading, silence, quiet breath out',
    ]),
    'bleed:enter': (2.5, 1.9, False, [
        'Wet ink drops falling onto paper and soaking in, soft liquid drips, close-up, clean foley',
        'Thick liquid dripping and spreading on paper, small wet splats, quiet, close microphone',
        'Ink dripping onto a page, few soft wet drops and a gentle seep, foley',
    ]),
    'brief:enter': (1.0, 0.45, False, [
        'A sheet of paper sliding quickly across a desk, short swish, close-up, clean foley',
        'Quick paper slide, a dry soft swoosh of a document pushed across a table',
    ]),
    'brief:leave': (5.0, 4.5, False, [
        'A small piece of paper catching fire and burning quickly, crackling, then the flame goes out',
        'Small paper flame flaring up and burning out, soft crackles, close-up, clean foley',
    ]),
}


def decode_model_audio(audio, sr):
    """The model's tensor ([channels, samples] at sr) as mono float32 at RATE."""
    x = audio.float().cpu().numpy()
    if x.ndim == 3:
        x = x[0]
    x = x.mean(axis=0) if x.ndim == 2 else x
    if sr != RATE:
        n = int(round(len(x) * RATE / sr))
        x = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)
    return x.astype(np.float32)


def lead_trim(x, floor_db=-40.0):
    """The sound from a few milliseconds before it first rises above floor_db under its peak."""
    peak = float(np.max(np.abs(x))) or 1.0
    above = np.nonzero(np.abs(x) > peak * 10 ** (floor_db / 20))[0]
    if not len(above):
        return x
    start = max(0, int(above[0]) - int(0.005 * RATE))
    return x[start:]


def fade(x, fade_in, fade_out):
    y = x.copy()
    a, b = int(fade_in * RATE), int(fade_out * RATE)
    if a:
        y[:a] *= np.linspace(0, 1, a, dtype=np.float32)
    if b:
        y[-b:] *= np.linspace(1, 0, b, dtype=np.float32) ** 2
    return y


def loop_of(x, seconds, xfade=0.5):
    """A seamless loop of `seconds`: the stretch after it is crossfaded (equal power) into its start."""
    n, f = int(seconds * RATE), int(xfade * RATE)
    if len(x) < n + f:
        n = len(x) - f
    body = x[:n].copy()
    t = np.linspace(0, np.pi / 2, f, dtype=np.float32)
    body[:f] = body[:f] * np.sin(t) + x[n:n + f] * np.cos(t)
    return body


def peak_to(x, db):
    p = float(np.max(np.abs(x))) or 1.0
    return (x * (10 ** (db / 20) / p)).astype(np.float32)


def shape(x, kept, loop):
    if loop:
        return peak_to(loop_of(x, kept), PEAK_DB)
    x = lead_trim(x)[:int(kept * RATE)]
    return peak_to(fade(x, 0.002, min(0.3, kept * 0.15)), PEAK_DB)


def main(argv):
    if '--manifest' in argv:
        write_manifest_js(json.load(open(os.path.join(OUT, 'manifest.json'), encoding='utf-8')))
        return
    count = CANDIDATES
    if '--count' in argv:
        i = argv.index('--count')
        count = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    only = [a for a in argv if not a.startswith('-')] or list(CUES)
    import torch
    from stable_audio_3 import StableAudioModel
    # (fp32: a GTX 1080 has no fast half precision)
    model = StableAudioModel.from_pretrained('small-sfx', model_half=False)
    sr = model.model.sample_rate
    os.makedirs(OUT, exist_ok=True)
    manifest_path, prompts_path = os.path.join(OUT, 'manifest.json'), os.path.join(OUT, 'prompts.json')
    manifest = json.load(open(manifest_path, encoding='utf-8')) if os.path.exists(manifest_path) else {}
    told = json.load(open(prompts_path, encoding='utf-8')) if os.path.exists(prompts_path) else {}
    for key in only:
        made, kept, loop, prompts = CUES[key]
        files = []
        for i in range(count):
            prompt, seed = prompts[i % len(prompts)], 1000 + i
            torch.manual_seed(seed)
            audio = model.generate(prompt=prompt, negative_prompt=NEGATIVE, duration=made, seed=seed)
            y = shape(decode_model_audio(audio, sr), kept, loop)
            name = '%s_%02d.ogg' % (key.replace(':', '_'), i + 1)
            build.encode(y, os.path.join(OUT, name))
            files.append(name)
            told[name] = {'prompt': prompt, 'seed': seed, 'made': made, 'kept': kept, 'loop': loop}
            print(key, name, '%.2fs' % (len(y) / RATE), flush=True)
        manifest[key] = files
        json.dump(manifest, open(manifest_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        json.dump(told, open(prompts_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        write_manifest_js(manifest)


def write_manifest_js(manifest):
    """The lab's list of the candidates, as a script (the lab opened from a file cannot fetch a json)."""
    with open(os.path.join(OUT, 'manifest.js'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('window.TITLE_SOUND_CANDIDATES = ' + json.dumps(manifest, indent=1) + ';\n')


if __name__ == '__main__':
    main(sys.argv[1:])
