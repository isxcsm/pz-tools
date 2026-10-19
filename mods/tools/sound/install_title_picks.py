"""The title sounds the user picked, into the game (SOUND-SYSTEM.md S7).

ai_titles.py makes candidates into a gen folder (outside git); the user hears them in the title lab and picks, and the lab's
picks are title_picks.json: { "style:moment": { "file": "<name>.ogg", ... } }. For each pick this

    takes the file from the gen folder (--gen, else tools/sound/gen), brings it to the loudness of its style's role
    (LOUD below; a leave is a quiet tail), fades its ends 5 ms (the
    candidate is already cut and shaped by ai_titles.py: not trimmed again, so a swell's lead-in and its peak keep the
    time the title lab showed), and writes it as Ogg Vorbis (build.encode) to the kit's
    media/sound/KIT_T_<Style>_<Moment>.ogg (KIT_T_Stamp_Land);

then writes a delimited block in each of two files, so a rerun replaces it and nothing else is touched:
    the kit's sound script (media/scripts/kit_sounds.txt): a `sound KIT_T_...` for each pick, category UI, a loop for a hold;
        build.py keeps this block when it rewrites the script;
    the kit's cue table (PZUIKit/Sound.lua): `kit.title.<style>.<moment>` -> that sound.
A pick that is gone from title_picks.json loses its file and its entries; a style:moment with no pick has no sound (a
title's line has none but where its style strikes it as a thing of its own: "seal:line.land", the cue kit.title.seal.line.land,
KIT_T_Seal_LineLand). A rerun with the same picks, files and levels writes nothing
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

STYLES = ['stamp', 'seal', 'dust', 'notice', 'discovery', 'unveil', 'sink', 'pulse', 'bleed', 'brief', 'type']
MOMENTS = ['enter', 'land', 'hold', 'leave']
# A title's line sounds only where its style's line is struck as a thing of its own (the seal's tag): line.<moment>.
MOMENTS += ['line.' + m for m in MOMENTS]

# Each style's loudness (LUFS: its loudest 400 ms, build.loudness) for its enter, land and hold sounds, by its role. Not
# the peak: these are a hit over a swell, or a swell, 1 to 9 s long, and at a peak level they read quiet (2026-10-20: set
# by their peaks from the recording of 2026-10-19 they were -24 to -38 LUFS, the notice and the brief under the click,
# and the user, after the terminal's boot was made heard, heard the titles' sounds "거의 안들리긴하네"). The ladder, by
# how big and how rare the moment is, against the game's click (about -31 here) and the terminal's boot (its switch -22,
# its welcome -19, a line -28: install_terminal_picks.py); calls counted in S7:
LOUD = {
    'seal': -17.0,      # the operation named, 100 acorns: once a game each, the biggest moment the mods have
    'bleed': -19.0,     # a positive infection, once: dread, the heaviest moment after it
    'unveil': -20.0,    # a new phase (3 calls), a slow wide swell: rare and large
    'stamp': -20.0,     # a grade, a box sealed: a milestone met a few times a game
    'sink': -21.0,      # a loss (5): felt, but a failure should not shout
    'discovery': -21.0, # a find (8): an event, a little under the milestones
    'pulse': -23.0,     # relief (5): gentle
    'dust': -23.0,      # progress and unlocks (10): frequent
    'notice': -25.0,    # work information (9, many in a row at a dispatch): a signal, not an event
    'brief': -27.0,     # tiny feedback (one per kit fitted or kill logged): a tick, a terminal line's level
    'type': -22.0,      # a document issued: its keys are the keyboard's; this is for a pick of it
}
# A title's line's own sound (the seal's tag's thump) this much under its title's, as the two picks stood in the lab.
LINE_LOUD_DB = -3.0
# A leave is a tail, not an event: this much under its style's level.
LEAVE_DB = -8.0
FADE_S = build.FADE_S

NAME = re.compile(r'^KIT_T_[A-Z][a-z]+_(Line)?[A-Z][a-z]+$')
BEGIN_CUES = '-- title picks begin'
END_CUES = '-- title picks end'
FINGERPRINT = re.compile(r'/\* (KIT_T_[A-Za-z_]+): (\S+) ([0-9a-f]{8}) (-?[0-9.]+) dB \*/')


def sound_name(style, moment):
    return 'KIT_T_%s_%s' % (style.capitalize(), ''.join(part.capitalize() for part in moment.split('.')))


def level_of(style, moment):
    return LOUD[style] + (LINE_LOUD_DB if moment.startswith('line.') else 0.0) + (LEAVE_DB if moment.endswith('leave') else 0.0)


def leveled_as(data, style, level):
    """The candidate at its loudness `level`, its ends faded 5 ms (leveled at -3 dBFS first), the peak kept under -1 dBFS."""
    data = leveled(data, -3.0)
    gain = min(10 ** ((level - build.loudness(data)) / 20), 10 ** (-1.0 / 20) / float(np.max(np.abs(data))))
    return np.clip(data * gain, -1, 1)


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
        if style not in STYLES or style not in LOUD or moment not in MOMENTS:
            problems.append('%s: not a style:moment (styles %s; moments %s): skipped' % (key, ', '.join(STYLES), ', '.join(MOMENTS)))
            continue
        name = sound_name(style, moment)
        source = os.path.join(opts.gen, pick['file'])
        level = level_of(style, moment)
        if not os.path.exists(source):
            if name in present and name in before:
                old = before[name]
                # (its source gone from the gen folder: a new level is put on the installed sound itself)
                if old[2] != level:
                    problems.append('%s: %s is not in %s: the installed sound levelled again' % (key, pick['file'], opts.gen))
                entries.append((name, moment, old[0], old[1], level, style))
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
        if not os.path.exists(source):
            # its source gone: the installed sound (decoded whole before it is written over) at the new level
            source = out
        build.encode(leveled_as(build.decode(source), style, level), out)

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
