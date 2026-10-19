"""The terminal sounds the user picked, into the game (SOUND-SYSTEM.md S8).

ai_terminal.py makes candidates into gen/term (outside git); the user hears them in the terminal lab (lab/terminal.html) and
picks. Picks given on the command line (tier:cue=file) are kept in terminal_picks.json; then for each pick this takes the
file from gen/term, brings its peak to its cue's level (LEVELS below) and fades its ends 5 ms (install_title_picks.leveled:
not trimmed again), and writes it as OA's media/sound/OA_Term_<Tier>_<Cue>.ogg; then the delimited blocks of OA's sound
script (oa_sounds.txt: `sound OA_Term_...`, category UI, a loop for a bed or a spell; build.py keeps the block) and of OA's
cue table (OperationAcorn/Sounds.lua: every terminal cue, `oa.term.<tier>.<cue>`, the picked ones with their sound, the
others silent). A pick taken away ("tier:cue=none") loses its file. A rerun with the same picks and levels writes no sound.

    python -X utf8 install_terminal_picks.py [tier:cue=file ...] [--gen PATH] [--dry]
"""
import argparse
import json
import os
import re
import sys

import numpy as np

import build
import install_title_picks as titles

HERE = os.path.dirname(os.path.abspath(__file__))
OA = os.path.join(build.MODS, 'operation-acorn', 'OperationAcorn', '42')
SOUND_DIR = os.path.join(OA, 'media', 'sound')
SCRIPT = os.path.join(OA, 'media', 'scripts', 'oa_sounds.txt')
CUES = os.path.join(OA, 'media', 'lua', 'shared', 'OperationAcorn', 'Sounds.lua')
PICKS = os.path.join(HERE, 'terminal_picks.json')
DEFAULT_GEN = os.path.join(HERE, 'gen', 'term')

# Each cue's level (dBFS), by its role: a beat's loudest 20 ms, a loop's mean (RMS; its loudest 20 ms at most
# LOOP_OVER above: a crackle's spikes at a mean level sounded over the click). Not the peak: a candidate whose
# peak is one click's spike sounded 20 dB under another of the same peak in the game (2026-10-19, each alone against the
# kit's click, whose loudest 20 ms is -26 there; a beat's loudest 20 ms here comes out 6 to 9 dB lower in the game). The
# boot plays on every open of a terminal: its switch about 7 dB under the click, the welcome and the switch-off under
# it, a line's tick well under; the beds are a quiet floor (their volume follows the picture as well: the console's is
# 1 / 2.2 of the opening's); a weak signal spell comes every 14 s while the window is open, under the beats. The lab
# (lab/terminal.html) plays them at these levels, measured the same way.
LEVELS = {
    'field:power': -26.0, 'field:hum': -40.0, 'field:line': -36.0, 'field:ready': -29.0, 'field:off': -31.0,
    'crude:power': -25.0, 'crude:hum': -38.0, 'crude:jolt': -30.0, 'crude:line': -36.0, 'crude:ready': -29.0,
    'crude:off': -30.0, 'crude:spell': -34.0,
}
LOOPS = {'field:hum', 'crude:hum', 'crude:spell'}
# Whatever the level, the peak is kept under this.
PEAK_CAP = -1.0
LOOP_OVER = 6.0


def loudest20(data):
    """The level (linear) of the loudest 20 ms of data."""
    n = int(0.02 * build.RATE)
    if len(data) <= n:
        return float(np.sqrt(np.mean(data * data))) or 1e-9
    c = np.concatenate([[0.0], np.cumsum(data.astype(np.float64) ** 2)])
    return float(np.sqrt(np.max(c[n:] - c[:-n]) / n)) or 1e-9


def leveled(data, key):
    """The candidate at its cue's level: a loop by its mean (not faded: its end runs into its start), a beat by its
    loudest 20 ms, its ends faded 5 ms; the peak kept under PEAK_CAP."""
    level = LEVELS[key]
    if key in LOOPS:
        gain = min(10 ** (level / 20) / (float(np.sqrt(np.mean(data * data))) or 1e-9),
                   10 ** ((level + LOOP_OVER) / 20) / loudest20(data))
    else:
        data = titles.leveled(data, -3.0)
        gain = 10 ** (level / 20) / loudest20(data)
    gain = min(gain, 10 ** (PEAK_CAP / 20) / (float(np.max(np.abs(data))) or 1.0))
    return np.clip(data * gain, -1, 1)


BEGIN_CUES = '    -- terminal picks begin'
END_CUES = '    -- terminal picks end'
NAME = re.compile(r'^OA_Term_[A-Z][a-z]+_[A-Z][a-z]+$')


def sound_name(key):
    tier, cue = key.split(':')
    return 'OA_Term_%s_%s' % (tier.capitalize(), cue.capitalize())


def installed_block(text):
    start = text.find(build.TERMINAL_BEGIN)
    end = text.find(build.TERMINAL_END)
    if start < 0 or end < start:
        return {}
    return {m[0]: (m[1], m[2], float(m[3])) for m in titles.FINGERPRINT.findall(text[start:end])}


def script_block(entries):
    lines = [build.TERMINAL_BEGIN]
    for key, name, file, digest, level in entries:
        lines += ['', '    /* %s: %s %s %g dB */' % (name, file, digest, level), '    sound %s' % name, '    {',
                  '        category = UI,']
        if key in LOOPS:
            lines.append('        loop = true,')
        lines += ['        clip', '        {', '            file = media/sound/%s.ogg,' % name, '        }', '    }']
    lines += ['', build.TERMINAL_END]
    return '\n'.join(lines)


def put_script_block(text, block):
    start = text.find(build.TERMINAL_BEGIN)
    if start >= 0:
        end = text.find(build.TERMINAL_END, start)
        if end < 0:
            raise ValueError('oa_sounds.txt: a terminal picks begin without its end')
        return text[:start] + block + text[end + len(build.TERMINAL_END):]
    close = text.rstrip().rfind('}')
    if close < 0:
        raise ValueError('oa_sounds.txt: no module to put the block in')
    return text[:close] + block + '\n\n' + text[close:]


def cue_block(picked):
    lines = [BEGIN_CUES + ' (written by tools/sound/install_terminal_picks.py from terminal_picks.json: edit that, not this)']
    for key in LEVELS:
        tier, cue = key.split(':')
        sound = ' sound = "%s" ' % sound_name(key) if key in picked else ''
        lines.append('    ["oa.term.%s.%s"] = {%s},' % (tier, cue, sound))
    lines.append(END_CUES)
    return '\n'.join(lines) + '\n'


def put_cue_block(text, block):
    start = text.find(BEGIN_CUES)
    end = text.find(END_CUES)
    if start < 0 or end < start:
        raise ValueError('Sounds.lua: no "%s" ... "%s" lines to put the picks between' % (BEGIN_CUES.strip(), END_CUES.strip()))
    end += len(END_CUES)
    if text[end:end + 1] == '\n':
        end += 1
    return text[:start] + block + text[end:]


def main(args):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('picks', nargs='*', help='tier:cue=file (none: no sound)')
    parser.add_argument('--gen', default=DEFAULT_GEN)
    parser.add_argument('--dry', action='store_true')
    opts = parser.parse_args(args)

    picks = json.load(open(PICKS, encoding='utf-8')) if os.path.exists(PICKS) else {}
    for arg in opts.picks:
        key, _, file = arg.partition('=')
        if key not in LEVELS:
            raise SystemExit('%s: not a terminal cue (%s)' % (key, ', '.join(LEVELS)))
        if file in ('', 'none'):
            picks.pop(key, None)
        else:
            if not os.path.exists(os.path.join(opts.gen, file)):
                raise SystemExit('%s: %s is not in %s' % (key, file, opts.gen))
            picks[key] = {'file': file}
    if not opts.dry:
        with open(PICKS, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(dict(sorted(picks.items())), f, ensure_ascii=False, indent=1)
            f.write('\n')

    before = installed_block(titles.read(SCRIPT))
    present = {n[:-4] for n in os.listdir(SOUND_DIR) if n.endswith('.ogg') and NAME.match(n[:-4])}
    entries, problems = [], []
    for key in LEVELS:
        if key not in picks:
            continue
        name, file, level = sound_name(key), picks[key]['file'], LEVELS[key]
        source = os.path.join(opts.gen, file)
        if not os.path.exists(source):
            if name in present and name in before:
                problems.append('%s: %s is not in %s: kept as installed' % (key, file, opts.gen))
                entries.append((key, name) + before[name])
            else:
                problems.append('%s: %s is not in %s: skipped' % (key, file, opts.gen))
            continue
        entries.append((key, name, file, titles.fingerprint_of(source, level), level))

    wanted = {e[1] for e in entries}
    for name in sorted(present - wanted):
        print('%s: no pick any more: %s' % (name, 'would be removed' if opts.dry else 'removed'))
        if not opts.dry:
            os.remove(os.path.join(SOUND_DIR, name + '.ogg'))
    for key, name, file, digest, level in entries:
        if before.get(name) == (file, digest, level) and name in present:
            print('%s: unchanged (%s, %g dB)' % (name, file, level))
            continue
        print('%s: %s at %g dB %s' % (name, file, level, 'would be written' if opts.dry else 'written'))
        source = os.path.join(opts.gen, file)
        if not opts.dry and os.path.exists(source):
            build.encode(leveled(build.decode(source), key), os.path.join(SOUND_DIR, name + '.ogg'))
    if not opts.dry:
        titles.write(SCRIPT, put_script_block(titles.read(SCRIPT), script_block(entries)))
        titles.write(CUES, put_cue_block(titles.read(CUES), cue_block({e[0] for e in entries})))
        print('%d terminal sounds installed' % len(entries))
    for line in problems:
        print('problem: ' + line)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
