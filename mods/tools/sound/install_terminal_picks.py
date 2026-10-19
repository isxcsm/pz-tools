"""The terminal sounds chosen, into the game (SOUND-SYSTEM.md S8).

ai_terminal.py makes candidates into gen/term (outside git); pick_terminal.py chooses one a cue by what can be measured and
hands it here (tier:cue=file on the command line), kept in terminal_picks.json; then for each pick this takes the
file from gen/term, brings it to its cue's loudness (LEVELS below) and fades its ends 5 ms (install_title_picks.leveled:
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

# Each cue's level, by its role, as loudness (LUFS: K-weighted, BS.1770, mono): a beat's loudest 400 ms (momentary
# loudness), a loop's mean. Not the peak, nor the loudest 20 ms: a short spike reads loud there and is not heard so
# (2026-10-20: set by the loudest 20 ms to the click's level, the boot's lines, work and bed were -38 to -41 LUFS in the
# game's output, the click -31: the user heard them "배경에 미세하게 깔리는"). The titles' enters, the moments the user
# hears as presentation, are -24 to -29 LUFS (KIT_T_*), the printer's rows -28, a key -35. The boot is a presentation:
# its switch and welcome at the titles' loudest, each line's work and result at the printer's rows, the bed at the
# titles' level as the screen opens (the console plays it at 1 / 2.2 of that, -7 dB). The weak signal spell was right:
# kept at its old level (dBFS, its mean), the one cue in KEPT_DBFS.
LEVELS = {
    'field:power': -22.0, 'field:hum': -24.0, 'field:line': -28.0, 'field:ready': -19.0, 'field:off': -25.0,
    'field:work': -27.0,
    'crude:power': -22.0, 'crude:hum': -24.0, 'crude:jolt': -24.0, 'crude:line': -28.0, 'crude:ready': -19.0,
    'crude:off': -25.0, 'crude:work': -27.0, 'crude:spell': -34.0,
}
KEPT_DBFS = {'crude:spell'}
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


def _biquad(kind, fc, gain_db, q):
    w = 2 * np.pi * fc / build.RATE
    cos, alpha, a = np.cos(w), np.sin(w) / (2 * q), 10 ** (gain_db / 40)
    if kind == 'shelf':
        r = 2 * np.sqrt(a) * alpha
        b = [a * ((a + 1) + (a - 1) * cos + r), -2 * a * ((a - 1) + (a + 1) * cos), a * ((a + 1) + (a - 1) * cos - r)]
        d = [(a + 1) - (a - 1) * cos + r, 2 * ((a - 1) - (a + 1) * cos), (a + 1) - (a - 1) * cos - r]
    else:
        b = [(1 + cos) / 2, -(1 + cos), (1 + cos) / 2]
        d = [1 + alpha, -2 * cos, 1 - alpha]
    return np.array(b) / d[0], np.array(d) / d[0]


def k_weighted(data):
    """data through BS.1770's K filter (its high shelf, then its high pass)."""
    from scipy.signal import lfilter
    for kind, fc, g, q in (('shelf', 1681.97, 4.0, 0.7072), ('pass', 38.14, 0.0, 0.5003)):
        b, a = _biquad(kind, fc, g, q)
        data = lfilter(b, a, data)
    return data


def loudness(data, loop=False):
    """LUFS: a loop's mean, else the loudest 400 ms (100 ms steps; a shorter sound counted over 400 ms with silence)."""
    k = k_weighted(np.concatenate([data.astype(np.float64), np.zeros(int(0.4 * build.RATE))]))
    if loop:
        k = k[:len(data)]
        return -0.691 + 10 * np.log10(np.mean(k * k) + 1e-12)
    n, hop = int(0.4 * build.RATE), int(0.1 * build.RATE)
    c = np.concatenate([[0.0], np.cumsum(k * k)])
    sums = [c[i + n] - c[i] for i in range(0, len(k) - n + 1, hop)]
    return -0.691 + 10 * np.log10(max(sums) / n + 1e-12)


def leveled(data, key):
    """The candidate at its cue's level: a loop by its mean (not faded: its end runs into its start), a beat by its
    loudest 400 ms, its ends faded 5 ms; the peak kept under PEAK_CAP. A KEPT_DBFS cue by its old measure (a loop's
    mean RMS, its loudest 20 ms at most LOOP_OVER above)."""
    level = LEVELS[key]
    if key in KEPT_DBFS:
        gain = min(10 ** (level / 20) / (float(np.sqrt(np.mean(data * data))) or 1e-9),
                   10 ** ((level + LOOP_OVER) / 20) / loudest20(data))
    else:
        if key not in LOOPS:
            data = titles.leveled(data, -3.0)
        gain = 10 ** ((level - loudness(data, key in LOOPS)) / 20)
    gain = min(gain, 10 ** (PEAK_CAP / 20) / (float(np.max(np.abs(data))) or 1.0))
    return np.clip(data * gain, -1, 1)


BEGIN_CUES = '    -- terminal picks begin'
END_CUES = '    -- terminal picks end'
NAME = re.compile(r'^OA_Term_[A-Z][a-z]+_[A-Z][a-z]+$')
# A sound's line in the script block (the titles' FINGERPRINT, for the terminal's names: with the titles' one no sound was
# known as installed, and every run wrote every sound again).
FINGERPRINT = re.compile(r'/\* (OA_Term_[A-Za-z_]+): (\S+) ([0-9a-f]{8}) (-?[0-9.]+) dB \*/')


def sound_name(key):
    tier, cue = key.split(':')
    return 'OA_Term_%s_%s' % (tier.capitalize(), cue.capitalize())


def installed_block(text):
    start = text.find(build.TERMINAL_BEGIN)
    end = text.find(build.TERMINAL_END)
    if start < 0 or end < start:
        return {}
    return {m[0]: (m[1], m[2], float(m[3])) for m in FINGERPRINT.findall(text[start:end])}


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
