"""Title sound candidates made by Stable Audio 3 Small-SFX (SOUND-SYSTEM.md S7), for the user to hear in the title lab and pick.

A title's sound is chosen by what the moment means in play, not by what the picture shows: a stamp title comes with an
achievement or a grade, so it gets an achievement's sting, not a stamp's thud. Each style's role, how often it comes, and so
how big its sound is, are in SOUND-SYSTEM.md S7. All of them are one family (restrained, cinematic, warm, clean), and they
meet the picture only on its big beats: the sting's peak lands on the moment the title is fully in (`at`); a leave gets at
most a quiet tail.

Each cue gets CANDIDATES sounds: its prompts at several seeds. The model's output is only cut (leading silence off), moved
so that its loudest moment lands on `at`, cut to its length with a fade at the end, made mono at 44.1 kHz and set to one
peak. Nothing is layered or bent.

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

# What every prompt is not (the model hears it only with cfg_scale > 1).
NEGATIVE = 'voices, people talking, crowd, song, vocals, background noise, hiss, distortion, low quality, cartoon, comedic'

# Said of every sound, so that the styles are one family.
FAMILY = 'restrained cinematic game UI sound, warm, clean, high quality, short natural reverb tail'

# style:cue -> (seconds made, seconds kept, at, prompts). The sound starts at its moment in the title (enter: as it begins to
# come in; land: the stamp's impact; leave: as it begins to go); `at` is when, from there, its loudest moment should come (the
# title fully in, the torch opening), None to leave it where the model put it.
CUES = {
    # achievement, a grade, a sealed delivery: official recognition
    'stamp:land': (4.0, 2.5, 0.0, [
        'Achievement sting: a deep warm low impact with a resonant shimmering tail',
        'Satisfying confirmation hit for an achievement, solid low boom and a soft bright ring that fades',
        'Seal of approval sound, a heavy confident thump followed by a warm resonant tone',
    ]),
    # a stage, an unlock, a reward paid: progress
    'dust:enter': (4.0, 3.0, 1.0, [
        'Reward unlocked sting, a soft rising swell that resolves into a warm glowing chime',
        'Level up sound, a gentle airy rise blooming into a bright warm resolve',
        'Progress reward, a smooth swelling whoosh opening into a soft warm shimmer',
    ]),
    'dust:leave': (4.0, 3.0, None, [
        'Very quiet soft airy shimmer fading away, gentle dissolve',
        'Faint warm breathy whoosh slowly fading out, very soft',
    ]),
    # a call, a drop, a mission begun, a deadline: work information, often
    'notice:enter': (2.0, 1.2, 0.05, [
        'Short subtle incoming transmission alert, soft two-tone electronic blip, military radio interface',
        'Brief quiet radio message received tone, muted electronic chirp',
        'Soft message received ping with a faint analog warmth, short and unobtrusive',
    ]),
    # a site found, a town searched through, a nest cleared, a mission secured, an easter egg: discovery
    'discovery:enter': (4.0, 3.0, 1.9, [
        'Discovery sting, a mysterious soft swell that opens into a warm revealing tone',
        'Something important found, a gentle rising whoosh blooming into a curious resonant chime',
        'Reveal sound, a low airy build releasing into a warm glowing tone',
    ]),
    'discovery:leave': (4.0, 3.0, None, [
        'Very quiet warm tone slowly fading away, soft dissolve',
        'Faint low airy swell receding into silence, very soft',
    ]),
    # the first supply, arrival on the scene, a line opened: a new chapter
    'unveil:enter': (5.0, 4.5, 3.0, [
        'Opening swell, a slow deep airy rise like a wide space opening up, warm low drone resolving',
        'A new chapter begins, soft atmospheric whoosh building into a wide warm pad',
    ]),
    'unveil:leave': (4.0, 3.0, None, [
        'Soft wide atmospheric pad slowly fading out, quiet',
        'Gentle airy whoosh drawing away into silence, very soft',
    ]),
    # a mission failed, written off, lost; a drug lost: loss
    'sink:enter': (4.0, 3.5, 0.25, [
        'Mission failed sting, a low somber descending tone with a muffled dull impact',
        'Loss notification, a deep soft downward whoosh into a dark low hum fading out',
        'Somber low boom with a falling muted tone, quiet and sad',
    ]),
    # a serum's reversal, a negative test, a bite's delay over: the body, tension then relief
    'pulse:enter': (4.0, 3.0, 0.5, [
        'Medical relief sting, a tense low pulse that softens and resolves into a calm warm tone',
        'Body status turning to relief, a soft low thump followed by a gentle calm swell',
    ]),
    # an infection confirmed: dread
    'bleed:enter': (5.0, 4.0, 0.3, [
        'Ominous dread sting, a deep dark low impact with an unsettling dissonant swell, horror',
        'Grim confirmation, a heavy muffled low hit and a creeping dark drone that fades',
    ]),
    # a kit fitted, a search bonus, a kill count: small and frequent feedback
    'brief:enter': (1.5, 0.6, 0.02, [
        'Tiny subtle UI tick, a soft short click, very quiet',
        'Minimal short soft notification blip, quick and unobtrusive',
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


def loudest_at(x):
    """Seconds into x of its loudest moment (its level over 50 ms windows)."""
    w = int(0.05 * RATE)
    level = np.convolve(x * x, np.ones(w, dtype=np.float32) / w, mode='same')
    return float(np.argmax(level)) / RATE


def place(x, at):
    """x moved so that its loudest moment comes `at` seconds in: silence put before it, or its start cut (with a short
    fade in) when the peak came later."""
    shift = at - loudest_at(x)
    n = int(round(abs(shift) * RATE))
    if shift >= 0:
        return np.concatenate([np.zeros(n, dtype=np.float32), x])
    return fade(x[n:], 0.03, 0.0)


def fade(x, fade_in, fade_out):
    y = x.copy()
    a, b = int(fade_in * RATE), int(fade_out * RATE)
    if a:
        y[:a] *= np.linspace(0, 1, a, dtype=np.float32)
    if b:
        y[-b:] *= np.linspace(1, 0, b, dtype=np.float32) ** 2
    return y


def peak_to(x, db):
    p = float(np.max(np.abs(x))) or 1.0
    return (x * (10 ** (db / 20) / p)).astype(np.float32)


def shape(x, kept, at):
    x = lead_trim(x)
    if at is not None:
        x = place(x, at)
    x = x[:int(kept * RATE)]
    return peak_to(fade(x, 0.002, min(0.6, kept * 0.25)), PEAK_DB)


def write_manifest_js(manifest):
    """The lab's list of the candidates, as a script (the lab opened from a file cannot fetch a json)."""
    with open(os.path.join(OUT, 'manifest.js'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('window.TITLE_SOUND_CANDIDATES = ' + json.dumps(manifest, indent=1) + ';\n')


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
    # (only the cues there are now)
    manifest = {k: v for k, v in manifest.items() if k in CUES}
    told = json.load(open(prompts_path, encoding='utf-8')) if os.path.exists(prompts_path) else {}
    for key in only:
        made, kept, at, prompts = CUES[key]
        files = []
        for i in range(count):
            prompt, seed = prompts[i % len(prompts)] + ', ' + FAMILY, 1000 + i
            torch.manual_seed(seed)
            audio = model.generate(prompt=prompt, negative_prompt=NEGATIVE, duration=made, seed=seed)
            y = shape(decode_model_audio(audio, sr), kept, at)
            name = '%s_%02d.ogg' % (key.replace(':', '_'), i + 1)
            build.encode(y, os.path.join(OUT, name))
            files.append(name)
            told[name] = {'prompt': prompt, 'seed': seed, 'made': made, 'kept': kept, 'at': at}
            print(key, name, '%.2fs' % (len(y) / RATE), flush=True)
        manifest[key] = files
        json.dump(manifest, open(manifest_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        json.dump(told, open(prompts_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        write_manifest_js(manifest)


if __name__ == '__main__':
    main(sys.argv[1:])
