"""The mods' own sounds, from their sources to the game (SOUND-SYSTEM.md S5).

sounds.json names each sound the game is to know (OA_..., BU_..., KIT_...): the mod it goes into, its category and master
volume, whether it loops, and its clips (one is picked at random each time it plays). A clip is a source file (under
sources/: a library's recording, or one of our own) with what to take of it. For each clip this

    decodes it (ffmpeg: any format), takes its stretch (start, end in seconds), makes it mono at 44.1 kHz,
    cuts the quiet before and after it (from 2 ms before it first comes within 30 dB of its peak, to its last moment
    within 50 dB), keeps its first `length` seconds (the clip's, else the
    sound's: a key's press without its release), fades its ends (5 ms, so it does not click),
    brings its peak to the sound's `peak` (dBFS; -3 by default) and adds the clip's `gain` (dB),
    and writes it as Ogg Vorbis (quality 5) into <mod>/42/media/sound/<name>_<n>.ogg;

then writes each mod's sound script (<mod>/42/media/scripts/<prefix>_sounds.txt, module Base) from the table, so that the
game plays Sound.name's answer: a cue of the mods' tables (OA.Sounds, BU.Sounds, the kit's) names one of these.

    python -X utf8 build.py [name ...]      every sound, or the ones named
    python -X utf8 build.py --check         the table, its sources and the mods' cues only (a cue naming a sound the
                                            game has not, vanilla or ours, is a problem: it plays nothing, silently)

A sound's files of an earlier build that it no longer has (fewer clips) are removed; nothing else in media/sound is
touched. The sources' licences are in sources/LICENSES.csv (one row a file): a source without a row is refused.
"""
import csv
import json
import os
import re
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = os.path.dirname(os.path.dirname(HERE))
RATE = 44100
# A clip starts where it first comes within ONSET_DB of its own peak (less PRE_S, its attack's lead-in) and ends where it
# last comes within TAIL_DB of it: below the peak, not full scale, so a quiet recording's room noise is not taken for
# the sound.
ONSET_DB = -30.0
TAIL_DB = -50.0
PRE_S = 0.002
FADE_S = 0.005

# Where each mod's game folder is, and the prefix of its sound script and its sounds.
MOD_FOLDERS = {
    'pz-ui-kit': ('pz-ui-kit/PZUIKit/42', 'kit'),
    'operation-acorn': ('operation-acorn/OperationAcorn/42', 'oa'),
    'building-utilities': ('building-utilities/BuildingUtilities/42', 'bu'),
}
CATEGORIES = {'UI', 'Object', 'Item', 'Player', 'World'}
MASTERS = {'Primary', 'Ambient', 'Music', 'VehicleEngine'}
MADE = '/* Made by'
GAME_DIR = os.environ.get('PZDEV_GAME', r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid')
# The mods' cue tables: each cue's sound is to be one the game knows (a vanilla one or one of sounds.json's).
CUE_TABLES = [
    'pz-ui-kit/PZUIKit/42/media/lua/shared/PZUIKit/Sound.lua',
    'operation-acorn/OperationAcorn/42/media/lua/shared/OperationAcorn/Sounds.lua',
    'building-utilities/BuildingUtilities/42/media/lua/shared/BuildingUtilities/Sounds.lua',
]
CUE = re.compile(r'\["([A-Za-z0-9_.]+)"\]\s*=\s*\{[^}]*?\bsound\s*=\s*"([A-Za-z0-9_]+)"')


def load_table():
    with open(os.path.join(HERE, 'sounds.json'), encoding='utf-8') as f:
        return json.load(f)


def licensed():
    path = os.path.join(HERE, 'sources', 'LICENSES.csv')
    if not os.path.exists(path):
        return set()
    with open(path, encoding='utf-8', newline='') as f:
        return {row['file'].replace('\\', '/') for row in csv.DictReader(f)}


def check(table):
    """The table's mistakes (a list of lines; empty when there are none)."""
    problems = []
    known = licensed()
    for name, sound in table['sounds'].items():
        if sound.get('mod') not in MOD_FOLDERS:
            problems.append('%s: mod must be one of %s' % (name, ', '.join(MOD_FOLDERS)))
            continue
        prefix = MOD_FOLDERS[sound['mod']][1].upper() + '_'
        if not name.startswith(prefix):
            problems.append('%s: a %s sound is named %s...' % (name, sound['mod'], prefix))
        if sound.get('category', 'UI') not in CATEGORIES:
            problems.append('%s: category must be one of %s' % (name, ', '.join(sorted(CATEGORIES))))
        if sound.get('master', 'Primary') not in MASTERS:
            problems.append('%s: master must be one of %s' % (name, ', '.join(sorted(MASTERS))))
        if not sound.get('clips'):
            problems.append('%s: no clips' % name)
        for clip in sound.get('clips', []):
            src = clip.get('src', '').replace('\\', '/')
            if not os.path.exists(os.path.join(HERE, 'sources', src)):
                problems.append('%s: no source sources/%s' % (name, src))
            elif src not in known:
                problems.append('%s: sources/%s has no licence row in sources/LICENSES.csv' % (name, src))
    return problems


def game_sounds():
    """The names of the game's own sounds (its media/scripts' sound blocks); None without the game."""
    scripts = os.path.join(GAME_DIR, 'media', 'scripts')
    if not os.path.isdir(scripts):
        return None
    names = set()
    block = re.compile(r'^\s*sound\s+([A-Za-z0-9_]+)\s*$', re.M)
    for root, _, files in os.walk(scripts):
        for name in files:
            if name.lower().endswith('.txt'):
                with open(os.path.join(root, name), encoding='utf-8', errors='replace') as f:
                    names.update(block.findall(f.read()))
    return names


def check_cues(table):
    """The cues of the mods' tables whose sound the game would not know (a list of lines)."""
    vanilla = game_sounds()
    if vanilla is None:
        return []
    known = vanilla | set(table['sounds'])
    problems = []
    for rel in CUE_TABLES:
        with open(os.path.join(MODS, rel), encoding='utf-8') as f:
            for cue, sound in CUE.findall(f.read()):
                if sound not in known:
                    problems.append('%s: cue %s names %s, a sound neither the game nor sounds.json has' % (rel, cue, sound))
    return problems


def decode(path):
    """The file's samples, mono float32 at RATE (ffmpeg decodes and resamples)."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, 'in.wav')
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', path, '-ac', '1', '-ar', str(RATE),
                        '-c:a', 'pcm_f32le', wav], check=True, stdin=subprocess.DEVNULL)
        data, _ = sf.read(wav, dtype='float32')
    return data


def trim(data):
    """Without the quiet before and after it (ONSET_DB, TAIL_DB under its peak)."""
    level = np.abs(data)
    peak = float(level.max()) if len(level) else 0.0
    if peak <= 0:
        return data[:0]
    onset = np.nonzero(level > peak * 10 ** (ONSET_DB / 20))[0][0]
    tail = np.nonzero(level > peak * 10 ** (TAIL_DB / 20))[0][-1]
    return data[max(0, onset - int(PRE_S * RATE)):tail + 1]


def shape(data, clip, peak_db, length=None):
    start, end = clip.get('start'), clip.get('end')
    if start is not None or end is not None:
        a = int(round((start or 0) * RATE))
        b = int(round(end * RATE)) if end is not None else len(data)
        data = data[a:b]
    data = trim(data)
    if length:
        data = data[:int(round(length * RATE))]
    if len(data) == 0:
        raise ValueError('the clip is silent')
    fade = min(int(FADE_S * RATE), len(data) // 4)
    if fade > 0:
        ramp = np.linspace(0, 1, fade, dtype=np.float32)
        data = data.copy()
        data[:fade] *= ramp
        data[-fade:] *= ramp[::-1]
    peak = float(np.max(np.abs(data)))
    gain = 10 ** ((peak_db + clip.get('gain', 0.0)) / 20) / peak
    return np.clip(data * gain, -1, 1)


def encode(data, path):
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, 'out.wav')
        sf.write(wav, data, RATE, subtype='FLOAT')
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', wav, '-c:a', 'libvorbis', '-q:a', '5', path],
                       check=True, stdin=subprocess.DEVNULL)


def script(mod, sounds):
    """The sound script of a mod's sounds (module Base: the game finds a sound by its name alone)."""
    # (a /* */ comment: the game's script parser drops a file that has a // one, silently)
    lines = [MADE + ' pz-tools/mods/tools/sound/build.py from sounds.json: edit that, not this. */', 'module Base', '{']
    for name in sorted(sounds):
        sound = sounds[name]
        lines += ['    sound %s' % name, '    {', '        category = %s,' % sound.get('category', 'UI')]
        if sound.get('master', 'Primary') != 'Primary':
            lines.append('        master = %s,' % sound['master'])
        if sound.get('loop'):
            lines.append('        loop = true,')
        for n, clip in enumerate(sound['clips'], 1):
            lines += ['        clip', '        {', '            file = media/sound/%s_%d.ogg,' % (name, n)]
            if clip.get('volume', 1.0) != 1.0:
                lines.append('            volume = %g,' % clip['volume'])
            if clip.get('pitch', 1.0) != 1.0:
                lines.append('            pitch = %g,' % clip['pitch'])
            if sound.get('distanceMax'):
                lines.append('            distanceMax = %g,' % sound['distanceMax'])
            lines += ['        }']
        lines += ['    }', '']
    lines += ['}', '']
    return '\n'.join(lines)


def build(table, only):
    by_mod = {}
    for name, sound in table['sounds'].items():
        by_mod.setdefault(sound['mod'], {})[name] = sound
    # a mod with no sound left: its made script goes (one written by hand is left alone)
    for mod, (folder, prefix) in MOD_FOLDERS.items():
        made = os.path.join(MODS, folder, 'media', 'scripts', '%s_sounds.txt' % prefix)
        if mod not in by_mod and os.path.exists(made):
            with open(made, encoding='utf-8') as f:
                ours = f.readline().startswith(MADE)
            if ours:
                os.remove(made)
    for mod, sounds in sorted(by_mod.items()):
        folder, prefix = MOD_FOLDERS[mod]
        out = os.path.join(MODS, folder, 'media', 'sound')
        os.makedirs(out, exist_ok=True)
        for name, sound in sorted(sounds.items()):
            if only and name not in only:
                continue
            peak = sound.get('peak', table.get('peak', -3.0))
            for n, clip in enumerate(sound['clips'], 1):
                data = shape(decode(os.path.join(HERE, 'sources', clip['src'])), clip, peak,
                             clip.get('length', sound.get('length')))
                encode(data, os.path.join(out, '%s_%d.ogg' % (name, n)))
            # an earlier build's clips past this one's
            n = len(sound['clips']) + 1
            while os.path.exists(os.path.join(out, '%s_%d.ogg' % (name, n))):
                os.remove(os.path.join(out, '%s_%d.ogg' % (name, n)))
                n += 1
            print('built %s (%d clips) -> %s' % (name, len(sound['clips']), os.path.relpath(out, MODS)))
        scripts = os.path.join(MODS, folder, 'media', 'scripts')
        os.makedirs(scripts, exist_ok=True)
        with open(os.path.join(scripts, '%s_sounds.txt' % prefix), 'w', encoding='utf-8', newline='\n') as f:
            f.write(script(mod, sounds))


def main(args):
    table = load_table()
    problems = check(table) + check_cues(table)
    for line in problems:
        print('problem: ' + line)
    if problems:
        return 1
    if args[:1] == ['--check']:
        print('%d sounds, table, sources and cues ok' % len(table['sounds']))
        return 0
    build(table, set(args))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
