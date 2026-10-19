"""The title sounds the user picked, into the game (SOUND-SYSTEM.md S7).

ai_titles.py makes candidates into a gen folder (outside git); the user hears them in the title lab and picks, and the lab's
picks are title_picks.json: { "style:moment": { "file": "<name>.ogg", ... } }. For each pick this

    takes the file from the gen folder (--gen, else tools/sound/gen), brings its peak to the level of its style's role
    (LEVELS below; a leave is a quiet tail) the way build.py brings a clip to its sound's peak, fades its ends 5 ms (the
    candidate is already cut and shaped by ai_titles.py: not trimmed again, so a swell's lead-in and its peak keep the
    time the title lab showed), and writes it as Ogg Vorbis (build.encode) to the kit's
    media/sound/KIT_T_<Style>_<Moment>.ogg (KIT_T_Stamp_Land);

then writes a delimited block in each of two files, so a rerun replaces it and nothing else is touched:
    the kit's sound script (media/scripts/kit_sounds.txt): a `sound KIT_T_...` for each pick, category UI, a loop for a hold;
        build.py keeps this block when it rewrites the script;
    the kit's cue table (PZUIKit/Sound.lua): `kit.title.<style>.<moment>` -> that sound.
A pick that is gone from title_picks.json loses its file and its entries; a style:moment with no pick has no sound (the
subtitle line has none at all: one sound a title). A rerun with the same picks, files and levels writes nothing
(each sound's source file, a hash of it and its level are in the script's block).

    python -X utf8 install_title_picks.py [--gen PATH] [--dry]

A pick whose file is not in the gen folder is said and skipped (kept as it is if it was installed before); the rest go on.
"""
import argparse
import hashlib
import json
import os
import re
import sys

import numpy as np

import build

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = build.MODS
KIT = os.path.join(MODS, 'pz-ui-kit', 'PZUIKit', '42')
SOUND_DIR = os.path.join(KIT, 'media', 'sound')
SCRIPT = os.path.join(KIT, 'media', 'scripts', 'kit_sounds.txt')
CUES = os.path.join(KIT, 'media', 'lua', 'shared', 'PZUIKit', 'Sound.lua')
PICKS = os.path.join(HERE, 'title_picks.json')
DEFAULT_GEN = os.path.join(HERE, 'gen')

STYLES = ['stamp', 'dust', 'notice', 'discovery', 'unveil', 'sink', 'pulse', 'bleed', 'brief', 'type']
MOMENTS = ['enter', 'land', 'hold', 'leave']

# Each style's peak (dBFS) for its enter, land and hold sounds, by its role. The reference is the game's own UI click
# (S6, recorded from the game): peak -9 to -11 dB, its loudest 20 ms -28 dB. A title sound is 1 to 4.5 s of sound and not
# one click: at a peak the click's, a title sounded 7 to 11 dB louder than the click in the game (its loudest 20 ms; the
# recording of 2026-10-19, tests/ingame/sound_listen.lua part b, each title alone). So the peaks sit under the click's, set
# from that recording so that each title's loudest 20 ms lands where its role puts it against the click's -28 (calls
# counted in S7):
LEVELS = {
    'stamp': -13.0,     # a grade, a seal, 100 acorns: a milestone met a few times a game; the one that should be felt (-23)
    'bleed': -12.0,     # a positive infection, once: dread is the heaviest moment the mods have (-23)
    'unveil': -12.0,    # a new phase (3 calls), a slow wide swell: rare and large (-24)
    'sink': -13.0,      # a loss (5): felt, but a failure should not shout (-25)
    'discovery': -13.0, # a find (8): an event, a little under the milestones (-25)
    'pulse': -17.0,     # relief (5): the click's own level; relief is gentle (-28)
    'dust': -16.0,      # progress and unlocks (10): frequent, a little under the click (-30)
    'notice': -18.0,    # work information (9, many in a row at a dispatch): a signal, not an event (-31)
    'brief': -23.0,     # tiny feedback (3, one per kit fitted or kill logged): well under the click, a tick (-34)
    'type': -10.0,      # a document issued: its keys are the keyboard's, at the click's level; this is for a pick of it
}
# A leave is a tail, not an event: this much under its style's level.
LEAVE_DB = -8.0
FADE_S = build.FADE_S

NAME = re.compile(r'^KIT_T_[A-Z][a-z]+_[A-Z][a-z]+$')
BEGIN_CUES = '-- title picks begin'
END_CUES = '-- title picks end'
FINGERPRINT = re.compile(r'/\* (KIT_T_[A-Za-z_]+): (\S+) ([0-9a-f]{8}) (-?[0-9.]+) dB \*/')


def sound_name(style, moment):
    return 'KIT_T_%s_%s' % (style.capitalize(), moment.capitalize())


def level_of(style, moment):
    return LEVELS[style] + (LEAVE_DB if moment == 'leave' else 0.0)


def read(path):
    with open(path, encoding='utf-8', newline='') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def fingerprint_of(path, level):
    with open(path, 'rb') as f:
        return hashlib.sha1(f.read() + ('%.1f' % level).encode()).hexdigest()[:8]


def leveled(data, level):
    """The candidate at its peak `level` (dBFS), its ends faded 5 ms (build.shape's gain and fade, without its trimming)."""
    if len(data) == 0 or float(np.max(np.abs(data))) <= 0:
        raise ValueError('the file is silent')
    data = data.copy()
    fade = min(int(FADE_S * build.RATE), len(data) // 4)
    if fade > 0:
        ramp = np.linspace(0, 1, fade, dtype=np.float32)
        data[:fade] *= ramp
        data[-fade:] *= ramp[::-1]
    gain = 10 ** (level / 20) / float(np.max(np.abs(data)))
    return np.clip(data * gain, -1, 1)


def installed_block(text):
    """The fingerprints of the script's block: { sound name: (file, hash, level) }."""
    start = text.find(build.TITLE_BEGIN)
    end = text.find(build.TITLE_END)
    if start < 0 or end < start:
        return {}
    return {m[0]: (m[1], m[2], float(m[3])) for m in FINGERPRINT.findall(text[start:end])}


def script_block(entries):
    """The script's block (entries: [(name, moment, file, hash, level)] in order)."""
    lines = [build.TITLE_BEGIN]
    for name, moment, file, digest, level in entries:
        lines += ['', '    /* %s: %s %s %g dB */' % (name, file, digest, level), '    sound %s' % name, '    {',
                  '        category = UI,']
        if moment == 'hold':
            lines.append('        loop = true,')
        lines += ['        clip', '        {', '            file = media/sound/%s.ogg,' % name, '        }', '    }']
    lines += ['', build.TITLE_END]
    return '\n'.join(lines) + '\n'


def put_script_block(text, block):
    start = text.find(build.TITLE_BEGIN)
    if start >= 0:
        end = text.find(build.TITLE_END, start)
        if end < 0:
            raise ValueError('kit_sounds.txt: a title picks begin without its end')
        end += len(build.TITLE_END)
        if text[end:end + 1] == '\n':
            end += 1
        return text[:start] + block + text[end:]
    close = text.rstrip().rfind('}')
    if close < 0:
        raise ValueError('kit_sounds.txt: no module to put the block in')
    return text[:close] + block + '\n' + text[close:]


def cue_block(entries):
    lines = [BEGIN_CUES + ' (written by tools/sound/install_title_picks.py from title_picks.json: edit that, not this)',
             'Sound.defineAll({']
    for name, moment, style in entries:
        lines.append('    ["kit.title.%s.%s"] = { sound = "%s" },' % (style, moment, name))
    lines += ['})', END_CUES]
    return '\n'.join(lines) + '\n'


def put_cue_block(text, block):
    start = text.find(BEGIN_CUES)
    end = text.find(END_CUES)
    if start < 0 or end < start:
        raise ValueError('Sound.lua: no "%s" ... "%s" lines to put the picks between' % (BEGIN_CUES, END_CUES))
    end += len(END_CUES)
    if text[end:end + 1] == '\n':
        end += 1
    return text[:start] + block + text[end:]


def main(args):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--gen', default=DEFAULT_GEN, help='the folder of the candidates (default: tools/sound/gen)')
    parser.add_argument('--dry', action='store_true', help='say what would be done, change nothing')
    opts = parser.parse_args(args)

    with open(PICKS, encoding='utf-8') as f:
        picks = json.load(f)
    before = installed_block(read(SCRIPT)) if os.path.exists(SCRIPT) else {}
    present = {name[:-4] for name in os.listdir(SOUND_DIR) if NAME.match(name[:-4]) and name.endswith('.ogg')}

    entries = []   # (name, moment, file, hash, level, style) of the sounds the game is to have
    problems = []
    for key in sorted(picks, key=lambda k: (STYLES.index(k.split(':')[0]) if k.split(':')[0] in STYLES else 99, k)):
        style, _, moment = key.partition(':')
        pick = picks[key]
        if style not in STYLES or moment not in MOMENTS:
            problems.append('%s: not a style:moment (styles %s; moments %s): skipped' % (key, ', '.join(STYLES), ', '.join(MOMENTS)))
            continue
        name = sound_name(style, moment)
        source = os.path.join(opts.gen, pick['file'])
        level = level_of(style, moment)
        if not os.path.exists(source):
            if name in present and name in before:
                old = before[name]
                problems.append('%s: %s is not in %s: kept as installed (%s)' % (key, pick['file'], opts.gen, old[0]))
                entries.append((name, moment, old[0], old[1], old[2], style))
            else:
                problems.append('%s: %s is not in %s: skipped' % (key, pick['file'], opts.gen))
            continue
        entries.append((name, moment, pick['file'], fingerprint_of(source, level), level, style))

    wanted = {e[0] for e in entries}
    for name in sorted(present - wanted):
        print('%s: %s.ogg has no pick any more: %s' % (name, name, 'would be removed' if opts.dry else 'removed'))
        if not opts.dry:
            os.remove(os.path.join(SOUND_DIR, name + '.ogg'))

    for name, moment, file, digest, level, style in entries:
        out = os.path.join(SOUND_DIR, name + '.ogg')
        if before.get(name) == (file, digest, level) and name in present:
            print('%s: unchanged (%s, %g dB)' % (name, file, level))
            continue
        print('%s: %s at %g dB %s' % (name, file, level, 'would be written' if opts.dry else 'written'))
        if opts.dry:
            continue
        source = os.path.join(opts.gen, file)
        if not os.path.exists(source):   # kept as installed, but its hash is not the file's: nothing to redo
            continue
        build.encode(leveled(build.decode(source), level), out)

    if opts.dry:
        print('(dry: %d sounds, no file written)' % len(entries))
    else:
        write(SCRIPT, put_script_block(read(SCRIPT), script_block([e[:5] for e in entries])))
        write(CUES, put_cue_block(read(CUES), cue_block([(e[0], e[1], e[5]) for e in entries])))
        print('%d title sounds installed' % len(entries))
    for line in problems:
        print('problem: ' + line)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
