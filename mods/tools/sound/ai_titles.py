"""Title sound candidates made by Stable Audio 3 Small-SFX (SOUND-SYSTEM.md S7), for the user to hear in the title lab and pick.

A title's sound is chosen by what the moment means in play, not by what the picture shows: a stamp title comes with an
achievement or a grade, so it gets an achievement's sting, not a stamp's thud. Each style's role, how often it comes, and so
how big its sound is, are in SOUND-SYSTEM.md S7. All of them are one family (restrained, cinematic, warm, clean), and they
meet the picture only on its big beats: the sting's peak lands on the moment the title is fully in (`at`); a leave gets at
most a quiet tail.

Three kinds of cue:
- new: its prompts at several seeds;
- from another cue (a leave's tail from its enter): the n-th candidate made from the other cue's n-th (or from its pick),
  the model asked for the tail with that sound as its start (audio to audio), so that the two are one sound;
- a picked cue (title_picks.json, what the user chose): the pick, and versions of it refined by the model (audio to audio at
  a low noise, the pick's own prompt) or moved and softened as the user asked.

The model is asked for the sound's whole length and shapes its sound to end within it; its output is not cut: only its
leading and trailing silence go, it is moved so that its loudest moment lands on `at` (its start shortened by a quarter
second at most), cleaned (clean), made mono at 44.1 kHz and set to a peak. A refinement may also be darkened (a gentle low pass), lowered, or
given a longer room (a reverb tail): what the user asked of that pick.

The model is Stable Audio 3 Medium (Small-SFX scattered short broadband clicks through its sounds, heard as a scratch;
`--small` uses it still). Medium runs on the GTX 1080 without Flash Attention, in fp32, in parts (Maker), at about 5 to 8 s a sound.

Run with the Python of the Stable Audio 3 checkout (C:/git/pz-workspace/sa3, its .venv), the model's licence accepted and
`hf auth login` done once:

    ../../../../sa3/.venv/Scripts/python.exe ai_titles.py [cue ...] [--count N] [--small]

It writes gen/<style>_<cue>_<nn>.ogg (a pick's refinements <pick>_r<n>.ogg), gen/manifest.json and manifest.js
({"style:cue": [files]}, what the lab's sound panel lists, a pick first), and gen/prompts.json (each file's prompt, seed and
how it was made, to make a picked one again). `--manifest` only writes manifest.js again from manifest.json.
"""
import json
import os
import sys

import numpy as np

import build

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'gen')
PICKS = os.path.join(HERE, 'title_picks.json')
RATE = build.RATE
PEAK_DB = -3.0
TAIL_DB = -9.0
CANDIDATES = 6

# Said of every sound, so that the styles are one family.
FAMILY = 'restrained cinematic game UI sound, warm, clean, high quality, short natural reverb tail'

# style:cue -> dict(made, at, prompts[, peak][, parent, noise]). `made` is the sound's whole length: the model is asked for it
# and shapes its sound to end within it, so nothing it makes is cut afterwards (a cut ending is heard). The sound starts at its
# moment in the title (enter: as it begins to come in; land: the stamp's impact; leave: as it begins to go); `at` is when,
# from there, its loudest moment should come (the title fully in, the torch opening), None to leave it where the model put it.
# A cue with a parent is made from it.
CUES = {
    # a stage, an unlock, a tree or a board opened, a reward paid: something done, a page turned; quiet, not a game's level up
    'dust:enter': dict(made=4.0, at=1.0, prompts=[
        'Quiet reflective swell, a soft warm low pad rising gently and settling, understated, a chapter quietly closing',
        'Soft warm breath of air swelling into a calm low tone, subtle and reflective, understated',
        'Gentle muted rise into a warm hollow resonance, calm, understated, quietly meaningful',
    ]),
    'dust:leave': dict(made=5.0, at=None, peak=TAIL_DB, parent='dust:enter', noise=0.8, prompts=[
        'The same warm tone very softly fading away for a long time, faint, gentle, airy',
    ]),
    # a kit fitted, a search bonus, a kill count: dust's small sibling, frequent
    'brief:enter': dict(made=1.5, at=0.25, prompts=[
        'Tiny soft warm swell, a brief quiet glint, subtle and small, understated',
        'Very short soft warm rise into a faint calm tone, minimal, quiet',
    ]),
    'brief:leave': dict(made=2.5, at=None, peak=TAIL_DB, parent='brief:enter', noise=0.8, prompts=[
        'The same small warm tone softly fading out, faint and short',
    ]),
    # a call ending: the transmission's own tone, going
    'notice:leave': dict(made=2.5, at=None, peak=TAIL_DB, parent='notice:enter', noise=0.75, prompts=[
        'Transmission ends, the same soft electronic tone gently stepping down and fading, short',
        'End of message, the same blip softly closing, quiet and brief',
    ]),
    # the discovery's tail: its warm tone lingering as the torch dies down
    'discovery:leave': dict(made=4.5, at=None, peak=TAIL_DB, parent='discovery:enter', noise=0.8, prompts=[
        'The same warm glowing tone lingering very softly and slowly fading out, faint',
        'A faint soft resonance left from the same sound, gently dying away',
    ]),
    # a guide sent, a call sign given: an official document issued
    'type:enter': dict(made=3.0, at=0.3, prompts=[
        'Official document issued, a short soft muted mechanical cue settling into a calm low tone',
        'Briefing received, a subtle quiet clack and a warm low confirming tone, restrained',
        'Classified file delivered, soft muted mechanism and a calm warm resolve',
    ]),
    'type:leave': dict(made=3.5, at=None, peak=TAIL_DB, parent='type:enter', noise=0.8, prompts=[
        'The same calm tone softly fading away, faint',
    ]),
}

# What the user asked of a pick, as its refinements: each (how, settings). "a2a": the model again from the pick, at a noise,
# its prompt (and what is added to it); "move": the pick itself moved so that its loudest moment comes at `at`, lowered by
# `db` and darkened by a low pass at `lp` Hz; "room": the pick with a reverb tail of rt60 seconds, kept `kept` long.
REFINE = {
    'stamp:land': [('a2a', dict(noise=n)) for n in (0.35, 0.5, 0.65)],
    'discovery:enter': [('a2a', dict(noise=n)) for n in (0.35, 0.5, 0.65)],
    'notice:enter': [('a2a', dict(noise=n)) for n in (0.35, 0.5, 0.65)],
    'bleed:enter': [('a2a', dict(noise=n)) for n in (0.35, 0.5, 0.65)],
    'pulse:enter': [('a2a', dict(noise=n)) for n in (0.35, 0.5, 0.65)],
    'sink:enter': [('a2a', dict(noise=n)) for n in (0.35, 0.5, 0.65)],
    # (a longer tail)
    'unveil:enter': [('room', dict(rt60=3.0, kept=7.0)), ('room', dict(rt60=5.0, kept=8.5)),
                     ('a2a', dict(noise=0.45, made=8.0, add='with a long lingering tail slowly fading')),
                     ('a2a', dict(noise=0.6, made=8.0, add='with a long lingering tail slowly fading'))],
    # (it came too early and too strong: later, quieter, darker)
    'unveil:leave': [('move', dict(at=2.0, db=-5, lp=3000)), ('move', dict(at=2.8, db=-5, lp=3000)),
                     ('move', dict(at=2.0, db=-9, lp=2000)), ('move', dict(at=2.8, db=-9, lp=2000)),
                     ('a2a', dict(noise=0.5, at=2.4, peak=TAIL_DB, add='very soft, gentle and quiet'))],
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


# The most a sound's start may be shortened to bring its loudest moment earlier: more would cut into its opening.
SHORTEN_MOST = 0.25


def place(x, at):
    """x moved so that its loudest moment comes `at` seconds in: silence put before it; when the peak came later, its start
    shortened (with a short fade in) by SHORTEN_MOST at most, the rest left late."""
    shift = at - loudest_at(x)
    n = int(round(abs(shift) * RATE))
    if shift >= 0:
        return np.concatenate([np.zeros(n, dtype=np.float32), x])
    n = min(n, int(SHORTEN_MOST * RATE))
    return fade(x[n:], 0.03, 0.0)


def tail_trim(x, floor_db=-60.0):
    """x without the silence after it (below floor_db under its peak), with a short fade on what is left."""
    peak = float(np.max(np.abs(x))) or 1.0
    above = np.nonzero(np.abs(x) > peak * 10 ** (floor_db / 20))[0]
    if len(above):
        x = x[:int(above[-1]) + int(0.01 * RATE)]
    return fade(x, 0.0, 0.03)


def fade(x, fade_in, fade_out):
    y = x.copy()
    a, b = min(int(fade_in * RATE), len(y)), min(int(fade_out * RATE), len(y))
    if a:
        y[:a] *= np.linspace(0, 1, a, dtype=np.float32)
    if b:
        y[-b:] *= np.linspace(1, 0, b, dtype=np.float32) ** 2
    return y


def peak_to(x, db):
    p = float(np.max(np.abs(x))) or 1.0
    return (x * (10 ** (db / 20) / p)).astype(np.float32)


def lowpass(x, hz):
    """A gentle low pass (two one-pole stages, 12 dB an octave)."""
    a = float(np.exp(-2 * np.pi * hz / RATE))
    y = x.astype(np.float64)
    for _ in range(2):
        out = np.empty_like(y)
        s = 0.0
        for i, v in enumerate(y):
            s = (1 - a) * v + a * s
            out[i] = s
        y = out
    return y.astype(np.float32)


def room(x, rt60, kept, wet=0.35, seed=7):
    """x with a reverb tail of rt60 seconds (a dark decaying noise response), let ring to `kept` seconds."""
    rng = np.random.default_rng(seed)
    n = int(rt60 * RATE)
    t = np.arange(n) / RATE
    ir = rng.standard_normal(n).astype(np.float32) * np.exp(-6.9 * t / rt60).astype(np.float32)
    ir = lowpass(ir, 2500)
    ir /= np.sqrt(np.sum(ir ** 2)) or 1.0
    total = int(kept * RATE)
    dry = np.concatenate([x, np.zeros(max(0, total - len(x)), dtype=np.float32)])[:total]
    size = 1 << int(np.ceil(np.log2(len(dry) + n)))
    tail = np.fft.irfft(np.fft.rfft(dry, size) * np.fft.rfft(ir, size), size)[:total].astype(np.float32)
    tail *= np.max(np.abs(dry)) / (np.max(np.abs(tail)) or 1.0)
    return dry + wet * tail


def clean(x):
    """The model's faults taken out, nothing of the sound itself: the rumble under hearing (below 35 Hz, which only shakes
    a speaker), the short broadband clicks it scatters in a sound (heard as a scratch: where the band above 2.5 kHz jumps
    to more than four times its level around for a moment, that band is brought back down to its level around), and the
    grain at the very top (a gentle low pass at 9 kHz)."""
    from scipy import ndimage, signal
    x = signal.sosfiltfilt(signal.butter(2, 35, 'highpass', fs=RATE, output='sos'), x)
    lo = signal.sosfiltfilt(signal.butter(4, 2500, 'lowpass', fs=RATE, output='sos'), x)
    hi = x - lo
    # the high band's level, a millisecond at a time, against its median over the 60 ms around
    ms = int(RATE / 1000)
    n = len(hi) // ms
    if n > 80:
        level = np.sqrt(np.mean(hi[:n * ms].reshape(n, ms) ** 2, axis=1)) + 1e-9
        around = ndimage.median_filter(level, size=61, mode='nearest')
        floor = (np.sqrt(np.mean(x ** 2)) or 1.0) * 10 ** (-40 / 20)
        gain = np.where((level > 4 * around) & (level > floor), np.minimum(1.0, 1.5 * around / level), 1.0)
        # (a click's edges too, and no step in the gain)
        gain = ndimage.minimum_filter1d(gain, size=3)
        gain = ndimage.uniform_filter1d(gain, size=3)
        g = np.repeat(gain, ms)
        g = np.concatenate([g, np.ones(len(hi) - len(g))])
        hi = hi * g
    x = signal.sosfiltfilt(signal.butter(2, 9000, 'lowpass', fs=RATE, output='sos'), lo + hi)
    return x.astype(np.float32)


def shape(x, at, peak=PEAK_DB):
    """The model's sound cleaned, its leading silence off, moved to `at`, and set to `peak`; it is not cut: only the silence
    after it goes."""
    x = clean(lead_trim(x))
    if at is not None:
        x = place(x, at)
    return peak_to(tail_trim(x), peak)


def write_manifest_js(manifest):
    """The lab's list of the candidates, as a script (the lab opened from a file cannot fetch a json)."""
    with open(os.path.join(OUT, 'manifest.js'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('window.TITLE_SOUND_CANDIDATES = ' + json.dumps(manifest, indent=1) + ';\n')


class Maker:
    """The model, in parts that fit the GTX 1080's 8 GB (Medium is 9.3 GB with its decoder; what does not fit spills to shared
    memory and runs ten times slower): the text encoder stays in RAM (it reads a prompt once), the generator is on the GPU for
    the diffusion, and is swapped out for the decoder to decode (2 s a swap). Several prompts at once are one batch."""

    def __init__(self, name='medium'):
        # (the compile that fails here without triton, tried again for every new length, is skipped)
        os.environ.setdefault('TORCHDYNAMO_DISABLE', '1')
        import torch
        from stable_audio_3 import StableAudioModel
        self.torch, self.SAM = torch, StableAudioModel
        # (fp32: a GTX 1080 has no fast half precision)
        self.model = StableAudioModel.from_pretrained(name, device='cpu', model_half=False)
        self.parts = self.model.model
        self.model.device = 'cuda'
        self.sr = self.parts.sample_rate
        # an init sound is encoded in RAM (the decoder's encoder is not on the GPU then) and handed over
        encode = self.model._encode_audio_input

        def encode_in_ram(audio_input, size, mask=None):
            self.model.device = 'cpu'
            try:
                latents, mask = encode(audio_input, size, mask)
            finally:
                self.model.device = 'cuda'
            return latents.to('cuda'), (mask.to('cuda') if mask is not None else None)
        self.model._encode_audio_input = encode_in_ram

    def _on(self, gpu, ram):
        gpu.to('cuda')
        ram.to('cpu')
        self.torch.cuda.empty_cache()

    def make(self, prompts, seed, made, start=None, noise=1.0):
        """The model's sounds for the prompts (a list: one batch; from `start`, a sound at RATE, at that noise, when given),
        each mono at RATE, `made` seconds long."""
        torch = self.torch
        n = len(prompts)
        self._on(self.parts.model, self.parts.pretransform)
        cond, _ = self.SAM._build_conditioning_dicts(prompts, None, [made] * n, n)
        with torch.inference_mode():
            told = self.parts.conditioner(cond, 'cpu')
        on_gpu = lambda v: v.to('cuda') if torch.is_tensor(v) else v
        told = {k: tuple(on_gpu(x) for x in v) if isinstance(v, (list, tuple)) else on_gpu(v) for k, v in told.items()}
        kw = {}
        if start is not None:
            kw = dict(init_audio=(RATE, torch.from_numpy(np.ascontiguousarray(start))[None, :]), init_noise_level=noise)
        torch.manual_seed(seed)
        latents = self.model.generate(conditioning=cond, conditioning_tensors=told, duration=[made] * n, seed=seed,
                                      batch_size=n, duration_padding_sec=1.0, return_latents=True, **kw)
        self._on(self.parts.pretransform, self.parts.model)
        with torch.inference_mode():
            audio = self.parts.pretransform.decode(latents).float().clamp(-1, 1)
        audio = audio[:, :, :int(made * self.sr)]
        return [decode_model_audio(audio[i], self.sr) for i in range(n)]


def main(argv):
    if '--manifest' in argv:
        write_manifest_js(json.load(open(os.path.join(OUT, 'manifest.json'), encoding='utf-8')))
        return
    count = CANDIDATES
    if '--count' in argv:
        i = argv.index('--count')
        count = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    picks = json.load(open(PICKS, encoding='utf-8')) if os.path.exists(PICKS) else {}
    only = [a for a in argv if not a.startswith('-')] or list(CUES) + [k for k in REFINE if k in picks]
    maker = Maker('small-sfx' if '--small' in argv else 'medium')
    os.makedirs(OUT, exist_ok=True)
    manifest_path, prompts_path = os.path.join(OUT, 'manifest.json'), os.path.join(OUT, 'prompts.json')
    manifest = json.load(open(manifest_path, encoding='utf-8')) if os.path.exists(manifest_path) else {}
    told = json.load(open(prompts_path, encoding='utf-8')) if os.path.exists(prompts_path) else {}

    def save(key, files):
        manifest[key] = files
        json.dump(manifest, open(manifest_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        json.dump(told, open(prompts_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        write_manifest_js(manifest)

    def write(name, y, how):
        build.encode(y, os.path.join(OUT, name))
        told[name] = how
        print(name, '%.2fs' % (len(y) / RATE), flush=True)

    for key in only:
        if key in picks and key in REFINE:
            pick = picks[key]
            base = build.decode(os.path.join(OUT, pick['file']))
            files = [pick['file']]
            stem = pick['file'][:-4]
            for n, (how, s) in enumerate(REFINE[key], 1):
                name = '%s_r%d.ogg' % (stem, n)
                at = s.get('at', pick['at'])
                if how == 'a2a':
                    prompt = pick['prompt'] + (', ' + s['add'] if s.get('add') else '')
                    made = s.get('made', pick['made'])
                    x = maker.make([prompt], pick['seed'] + 100 * n, made, start=base, noise=s['noise'])[0]
                    y = shape(x, at, s.get('peak', PEAK_DB))
                    write(name, y, dict(from_pick=pick['file'], prompt=prompt, seed=pick['seed'] + 100 * n, noise=s['noise'],
                                        made=made, at=at))
                elif how == 'move':
                    y = place(clean(lead_trim(base)), s['at'])
                    y = peak_to(tail_trim(lowpass(y, s['lp'])), PEAK_DB + s['db'])
                    write(name, y, dict(from_pick=pick['file'], at=s['at'], db=s['db'], lp=s['lp']))
                elif how == 'room':
                    y = peak_to(fade(room(clean(base), s['rt60'], s['kept']), 0.0, 1.0), PEAK_DB)
                    write(name, y, dict(from_pick=pick['file'], rt60=s['rt60'], kept=s['kept']))
                files.append(name)
            save(key, files)
            continue
        c = CUES[key]
        parents = None
        if c.get('parent'):
            parent = c['parent']
            parents = [picks[parent]['file']] * count if parent in picks else manifest.get(parent, [])
            if not parents:
                print('no candidates of', parent, 'to make', key, 'from; skipped')
                continue
        files = []
        prompts = [c['prompts'][i % len(c['prompts'])] + ', ' + FAMILY for i in range(count)]
        if parents:
            # (each from its own sound: one at a time)
            made = []
            for i in range(count):
                src = parents[i % len(parents)]
                x = maker.make([prompts[i]], 1000 + i, c['made'], start=build.decode(os.path.join(OUT, src)), noise=c['noise'])[0]
                made.append((x, dict(prompt=prompts[i], seed=1000 + i, from_sound=src, noise=c['noise'])))
        else:
            # (all at once: item i of a batch of `count` at seed 1000)
            made = [(x, dict(prompt=prompts[i], seed=1000, batch=count, item=i))
                    for i, x in enumerate(maker.make(prompts, 1000, c['made']))]
        for i, (x, how) in enumerate(made):
            y = shape(x, c['at'], c.get('peak', PEAK_DB))
            name = '%s_%02d.ogg' % (key.replace(':', '_'), i + 1)
            write(name, y, dict(how, made=c['made'], at=c['at']))
            files.append(name)
        save(key, files)


if __name__ == '__main__':
    main(sys.argv[1:])
