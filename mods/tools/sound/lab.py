"""The sound lab's data (SOUND-SYSTEM.md S5): every cue the mods' Lua defines, read from the code, written to lab/manifest.js
for lab/index.html to play the way the game does.

    python -X utf8 lab.py [--listen DIR] [--out lab/manifest.js]

Nothing is kept by hand; run it again and the page is current. It reads
  - the cue tables in the Lua: Sound.defineAll({...}) (an inline table, or a named one like Sounds.CUES), Sound.define,
    Sound.defineKeyboard, and Sound.timed(class, during, done) with the cues it plays (kit.title.* cues are the title
    lab's: counted, not listed);
  - where else the code asks for each cue (any string equal to a defined cue, outside the tables);
  - the mods' sound scripts (media/scripts/*.txt): a sound defined there is ours (its clips, volume, loop), any other is
    the game's own and cannot be played outside the game;
  - sounds.json (peak, sources), SOUND-SYSTEM.md S6's tables (the event each cue is);
  - candidates/<cue or sound name>/*.ogg (a folder of folders: a candidate that is a set of variants);
  - with --listen DIR (default report/listen when it exists): the game recording a.wav with a_events.txt (ms, kind name,
    length per line): the `ref` events (the game's UI sounds, for loudness) and the act/done ones of the game's sounds our
    cues use are cut into lab/ref/<name>.wav.
Whatever it could not read is listed (on the page and here).
"""
import argparse
import bisect
import json
import os
import re
import sys
import time
import urllib.parse

try:
    import numpy as np
    import soundfile as sf
except ImportError:  # the page works without the level numbers and the recordings
    np = sf = None

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = os.path.dirname(os.path.dirname(HERE))
LAB = os.path.join(HERE, 'lab')
MOD_DIRS = {  # folder in mods/ -> (name shown, game folder)
    'pz-ui-kit': ('PZUIKit', 'pz-ui-kit/PZUIKit/42'),
    'operation-acorn': ('OA', 'operation-acorn/OperationAcorn/42'),
    'building-utilities': ('BU', 'building-utilities/BuildingUtilities/42'),
}
AUDIO = ('.ogg', '.wav', '.mp3', '.flac')
CUE_ID = re.compile(r'^(?:oa|bu|kit)\.[A-Za-z0-9_.]+$')
CALL = re.compile(r'(?<![\w.])(?:[A-Za-z_]\w*\.)*Sound\.(defineAll|defineKeyboard|define|timed)\s*\(')
USES = [('Sound.ui(', 'ui'), ('Sound.at(', 'at'), ('Sound.on(', 'on'), ('Sound.loop(', 'loop'), ('Sound.name(', 'name'),
        ('Sync.sound(', 'sync'), ('Sound.typed(', 'typed'), ('Sound.timed(', 'timed')]
MAX_USES = 8
COMMS_WORDS = {'comms', 'paper', 'manual'}


# ---------------------------------------------------------------------------------------------------------------------
# Lua: just enough to read table literals and call arguments (no evaluation).

class Raw(str):
    """An expression that is not a literal."""


class Table:
    def __init__(self, start):
        self.start = start
        self.named = {}   # key -> (value, offset of the key)
        self.items = []   # [(value, offset)]

    def get(self, key, default=None):
        entry = self.named.get(key)
        return entry[0] if entry else default

    def scalars(self):
        return {k: v for k, (v, _) in self.named.items() if not isinstance(v, (Table, Raw))}


def skip_ws(t, i):
    while i < len(t):
        if t[i] in ' \t\r\n':
            i += 1
        elif t.startswith('--', i):
            if t.startswith('--[[', i):
                j = t.find(']]', i + 4)
                i = len(t) if j < 0 else j + 2
            else:
                j = t.find('\n', i)
                i = len(t) if j < 0 else j
        else:
            break
    return i


def read_string(t, i):
    q = t[i]
    j, out = i + 1, []
    while j < len(t) and t[j] != q:
        if t[j] == '\\' and j + 1 < len(t):
            out.append({'n': '\n', 't': '\t'}.get(t[j + 1], t[j + 1]))
            j += 2
        else:
            out.append(t[j])
            j += 1
    return ''.join(out), j + 1


def scan_expr(t, i, stops, until_end=False):
    """The end of the expression starting at i: the first char of `stops` outside brackets, strings and function bodies."""
    depth = kw = 0
    n = len(t)
    while i < n:
        c = t[i]
        if t.startswith('--', i):
            i = skip_ws(t, i)
            continue
        if c in '"\'':
            i = read_string(t, i)[1]
            continue
        if c.isalpha() or c == '_':
            j = i
            while j < n and (t[j].isalnum() or t[j] == '_'):
                j += 1
            word = t[i:j]
            if word in ('function', 'if', 'do'):
                kw += 1
            elif word == 'end':
                kw -= 1
                if kw == 0 and until_end:
                    return j
            i = j
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0 and kw <= 0 and c in stops:
                return i
            depth -= 1
        elif c in stops and depth == 0 and kw <= 0:
            return i
        i += 1
    return n


def parse_value(t, i):
    i = skip_ws(t, i)
    if t[i] == '{':
        return parse_table(t, i)
    if t[i] in '"\'':
        return read_string(t, i)
    end = scan_expr(t, i, ',;})')
    raw = t[i:end].strip()
    if raw == 'true':
        return True, end
    if raw == 'false':
        return False, end
    if raw == 'nil':
        return None, end
    if re.fullmatch(r'-?\d+(\.\d+)?', raw):
        return (float(raw) if '.' in raw else int(raw)), end
    return Raw(raw), end


def parse_table(t, i):
    table = Table(i)
    i += 1
    while True:
        i = skip_ws(t, i)
        if i >= len(t):
            return table, i
        if t[i] == '}':
            return table, i + 1
        key, at = None, i
        if t[i] == '[':
            j = skip_ws(t, i + 1)
            if t[j] in '"\'':
                key, j = read_string(t, j)
                j = skip_ws(t, j)
                if t[j] == ']':
                    k = skip_ws(t, j + 1)
                    if t[k] == '=' and t[k + 1:k + 2] != '=':
                        i = k + 1
                    else:
                        key = None
        else:
            m = re.compile(r'([A-Za-z_]\w*)\s*=(?!=)').match(t, i)
            if m:
                key, i = m.group(1), m.end()
        value, i = parse_value(t, i)
        if key is None:
            table.items.append((value, at))
        else:
            table.named[key] = (value, at)
        i = skip_ws(t, i)
        if i < len(t) and t[i] in ',;':
            i += 1


def split_args(t, i):
    """The arguments of the call whose '(' is at i: [(source text, offset)], and the end."""
    args = []
    i += 1
    while True:
        i = skip_ws(t, i)
        if i >= len(t):
            return args, i
        if t[i] == ')':
            return args, i + 1
        end = scan_expr(t, i, ',)')
        args.append((t[i:end].strip(), i))
        i = end
        if i < len(t) and t[i] == ',':
            i += 1


# ---------------------------------------------------------------------------------------------------------------------

class Source:
    def __init__(self, path):
        self.path = path
        self.rel = os.path.relpath(path, MODS).replace('\\', '/')
        with open(path, encoding='utf-8', errors='replace') as f:
            self.text = f.read()
        self.starts = [0] + [m.end() for m in re.finditer(r'\n', self.text)]

    def line(self, offset):
        return bisect.bisect_right(self.starts, offset)

    def comment_above(self, offset):
        """The `--` comment lines directly above the line holding offset."""
        n = self.line(offset)
        lines = self.text.split('\n')
        out = []
        k = n - 2
        while k >= 0 and lines[k].strip().startswith('--'):
            out.append(lines[k].strip().lstrip('-').strip())
            k -= 1
        return ' '.join(reversed(out))


def lua_files():
    for folder in MOD_DIRS:
        for root, dirs, files in os.walk(os.path.join(MODS, folder)):
            dirs[:] = [d for d in dirs if d not in ('tests', 'node_modules')]
            for name in files:
                if name.endswith('.lua'):
                    yield os.path.join(root, name), MOD_DIRS[folder][0]


def cues_in(value):
    """Cue ids of the string literals in an expression (a function's, or a plain string)."""
    if isinstance(value, str) and not isinstance(value, Raw):
        return [value] if CUE_ID.match(value) else []
    return [s for s in re.findall(r'"([^"]+)"', value) if CUE_ID.match(s)]


def resolve_cues(src, arg):
    """(cues, conditional) of a Sound.timed argument: a string, nil, a function, or the name of a local function."""
    text = arg.strip()
    if text in ('nil', ''):
        return [], False
    if text[0] in '"\'':
        return cues_in(read_string(text, 0)[0]), False
    if text.startswith('function'):
        return cues_in(Raw(text)), True
    if re.fullmatch(r'[A-Za-z_]\w*', text):
        m = re.search(r'(?:local\s+function\s+%s\s*\(|%s\s*=\s*function\s*\()' % (text, text), src.text)
        if m:
            end = scan_expr(src.text, m.start(), '\x00', until_end=True)   # to the end of the function body
            return cues_in(Raw(src.text[m.start():end])), True
    return None, False


def read_lua():
    cues, boards, timed, problems = {}, {}, [], []
    sources = []
    for path, mod in sorted(lua_files()):
        src = Source(path)
        sources.append((src, mod))
        for m in CALL.finditer(src.text):
            what = m.group(1)
            before = src.text[max(0, m.start() - 9):m.start()]
            if before.endswith('function '):
                continue
            args, _ = split_args(src.text, m.end() - 1)
            where = '%s:%d' % (src.rel, src.line(m.start()))
            try:
                if what == 'defineAll':
                    table = None
                    if args and args[0][0].startswith('{'):
                        table = parse_table(src.text, args[0][1])[0]
                    elif args and re.fullmatch(r'[\w.]+', args[0][0]):
                        d = re.search(r'%s\s*=\s*\{' % re.escape(args[0][0]), src.text)
                        if d:
                            table = parse_table(src.text, d.end() - 1)[0]
                    if table is None:
                        problems.append('%s: Sound.defineAll(%s) is not a table I can read' % (where, args[0][0] if args else ''))
                        continue
                    for cue, (value, off) in table.named.items():
                        add_cue(cues, src, mod, cue, value, off, problems)
                elif what == 'define':
                    if args and args[0][0][:1] in '"\'' and len(args) > 1:
                        cue = read_string(args[0][0], 0)[0]
                        value = parse_value(src.text, args[1][1])[0]
                        add_cue(cues, src, mod, cue, value, args[0][1], problems)
                    elif args and args[0][0].startswith('"kit.title.'):
                        pass   # the kit's title cues, made by style and moment: the title lab's
                    else:
                        problems.append('%s: Sound.define(%s) has no cue name I can read' % (where, args[0][0] if args else ''))
                elif what == 'defineKeyboard':
                    name = read_string(args[0][0], 0)[0]
                    board = parse_value(src.text, args[1][1])[0]
                    names = [v for v, _ in board.get('letters').items] if isinstance(board.get('letters'), Table) else []
                    boards[name] = {'id': name, 'letters': names, 'space': board.get('space'), 'enter': board.get('enter'),
                                    'back': board.get('back'), 'where': where}
                elif what == 'timed':
                    cls = args[0][0]
                    during, cond1 = resolve_cues(src, args[1][0]) if len(args) > 1 else ([], False)
                    done, cond2 = resolve_cues(src, args[2][0]) if len(args) > 2 else ([], False)
                    if during is None or done is None:
                        problems.append('%s: Sound.timed(%s, ...) plays something I cannot resolve: %s' % (where, cls, ', '.join(a for a, _ in args[1:])))
                        during, done = during or [], done or []
                    for cue in during:
                        timed.append({'cls': cls, 'cue': cue, 'mode': 'during', 'cond': cond1, 'where': where})
                    for cue in done:
                        timed.append({'cls': cls, 'cue': cue, 'mode': 'done', 'cond': cond2, 'where': where})
            except Exception as e:  # a call in a shape I did not expect: say so, go on
                problems.append('%s: Sound.%s(...) unreadable (%s)' % (where, what, e))
    return cues, boards, timed, sources, problems


def add_cue(cues, src, mod, cue, value, offset, problems):
    if cue.startswith('kit.title.'):
        return
    if not isinstance(value, Table):
        problems.append('%s:%d: cue %s is not a table' % (src.rel, src.line(offset), cue))
        return
    fields = value.scalars()
    cues[cue] = {'id': cue, 'mod': mod, 'sound': fields.pop('sound', None), 'keyboard': fields.pop('keyboard', None),
                 'erase': bool(fields.pop('erase', False)), 'gap': fields.pop('gap', None), 'extra': fields,
                 'file': src.rel, 'line': src.line(offset), 'comment': src.comment_above(offset), 'uses': [],
                 'nUses': 0, 'timed': []}


def find_uses(cues, sources):
    ids = set(cues)
    quoted = re.compile(r'"((?:oa|bu|kit)\.[A-Za-z0-9_.]+)"')
    for src, _ in sources:
        for n, line in enumerate(src.text.split('\n'), 1):
            for cue in quoted.findall(line):
                c = cues.get(cue)
                if not c or (c['file'] == src.rel and c['line'] == n):
                    continue
                if line.lstrip().startswith('--'):
                    continue
                how = next((tag for key, tag in USES if key in line), 'ref')
                c['nUses'] += 1
                if len(c['uses']) < MAX_USES:
                    c['uses'].append({'where': '%s:%d' % (src.rel, n), 'how': how})


# ---------------------------------------------------------------------------------------------------------------------
# What the game knows of our sounds, the table they came from, the events S6 describes.

def read_scripts():
    sounds = {}
    for folder, (_, game) in MOD_DIRS.items():
        scripts = os.path.join(MODS, game, 'media', 'scripts')
        if not os.path.isdir(scripts):
            continue
        for name in sorted(os.listdir(scripts)):
            if not name.endswith('.txt'):
                continue
            with open(os.path.join(scripts, name), encoding='utf-8', errors='replace') as f:
                text = re.sub(r'/\*.*?\*/', '', f.read(), flags=re.S)
            for m in re.finditer(r'\bsound\s+([A-Za-z0-9_]+)\s*\{', text):
                depth, i = 1, m.end()
                while i < len(text) and depth:
                    depth += {'{': 1, '}': -1}.get(text[i], 0)
                    i += 1
                body = text[m.end():i - 1]
                clips, rest = [], body
                for c in re.finditer(r'\bclip\s*\{([^}]*)\}', body):
                    clips.append(dict(re.findall(r'(\w+)\s*=\s*([^,\n]+)', c.group(1))))
                    rest = rest.replace(c.group(0), '')
                head = dict(re.findall(r'(\w+)\s*=\s*([^,\n]+)', rest))
                sound = {'name': m.group(1), 'category': head.get('category', 'UI').strip(), 'master': head.get('master', 'Primary').strip(),
                         'loop': head.get('loop', '').strip() == 'true', 'volume': float(head.get('volume', 1)),
                         'script': '%s/%s' % (game, 'media/scripts/' + name), 'clips': []}
                for c in clips:
                    path = c.get('file', '').strip()
                    sound['clips'].append({'file': path, 'volume': float(c.get('volume', 1)), 'pitch': float(c.get('pitch', 1)),
                                           'distanceMax': float(c['distanceMax']) if 'distanceMax' in c else None,
                                           'game': game})
                sounds[m.group(1)] = sound
    return sounds


def read_table():
    path = os.path.join(HERE, 'sounds.json')
    if not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    return {k: dict(v, _peak=data.get('peak', -3.0)) for k, v in data.get('sounds', {}).items()}


def read_s6():
    """Event text per cue from SOUND-SYSTEM.md's tables: ({cue: (event, memo)} from the cue table, {cue: action text})."""
    events, actions = {}, {}
    path = os.path.join(MODS, 'SOUND-SYSTEM.md')
    if not os.path.exists(path):
        return events, actions
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    mode = None
    for line in lines:
        if not line.startswith('|'):
            mode = None if line.strip() else mode
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) >= 3 and cells[1] == '큐':
            mode = 'cue' if cells[0] == '사건' else 'action' if cells[0] == '액션' else None
            continue
        if mode is None or set(cells[0]) <= set('- '):
            continue
        tokens = re.findall(r'`([^`]+)`', cells[1])
        ids, last = [], None
        for tok in tokens:
            if '.' in tok:
                last = tok
                ids.append(tok)
            elif last:
                ids.append(last.rsplit('.', 1)[0] + '.' + tok)
        if mode == 'cue':
            parts = [p.strip() for p in cells[0].split(' / ')]
            for k, cue in enumerate(ids):
                event = parts[k] if len(parts) == len(ids) else cells[0]
                events[cue] = (event, cells[3] if len(cells) > 3 else '')
        else:
            for cue in ids:
                actions[cue] = (actions[cue] + '; ' if cue in actions else '') + cells[0]
    return events, actions


# ---------------------------------------------------------------------------------------------------------------------
# Audio: level numbers, the recording, candidates.

def url(path):
    """A URL from the lab folder to a file (relative; each part quoted)."""
    rel = os.path.relpath(path, LAB).replace('\\', '/')
    return '/'.join(urllib.parse.quote(p) if p not in ('..', '.') else p for p in rel.split('/'))


def levels(data):
    """(peak dBFS, loudest 50 ms RMS dBFS) of samples."""
    if np is None or len(data) == 0:
        return None
    if data.ndim > 1:
        data = data.mean(axis=1)
    peak = float(np.max(np.abs(data)))
    return levels_of(data, peak)


def levels_of(data, peak):
    db = lambda x: round(20 * np.log10(max(float(x), 1e-9)), 1)
    win = 2205   # 50 ms at 44.1 kHz; a shorter sound is one window
    sq = data.astype(np.float64) ** 2
    if len(sq) > win:
        sums = np.concatenate(([0.0], np.cumsum(sq)))
        rms = np.sqrt((sums[win:] - sums[:-win]).max() / win)
    else:
        rms = np.sqrt(sq.mean())
    return {'peak': db(peak), 'loud50': db(rms)}


def file_info(path):
    """{'dur', 'peak', 'loud50'} of an audio file, or {} when it cannot be read."""
    if sf is None:
        return {}
    try:
        data, rate = sf.read(path, dtype='float32')
    except Exception:
        return {}
    info = {'dur': round(len(data) / rate, 3)}
    info.update(levels(data) or {})
    return info


def audio_files(folder):
    return sorted((f for f in os.listdir(folder) if f.lower().endswith(AUDIO)), key=natural)


def natural(s):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r'(\d+)', s)]


def read_candidates():
    """{folder name: [candidate]}; a candidate is a file, or a subfolder of files (a set of variants)."""
    root = os.path.join(HERE, 'candidates')
    found = {}
    if not os.path.isdir(root):
        return found
    for name in sorted(os.listdir(root), key=natural):
        folder = os.path.join(root, name)
        if not os.path.isdir(folder):
            continue
        items = []
        for entry in sorted(os.listdir(folder), key=natural):
            path = os.path.join(folder, entry)
            if os.path.isfile(path) and entry.lower().endswith(AUDIO):
                items.append({'id': '%s/%s' % (name, entry), 'label': entry, 'clips': [dict(url=url(path), **file_info(path))]})
            elif os.path.isdir(path) and audio_files(path):
                items.append({'id': '%s/%s/' % (name, entry), 'label': entry + '/ (%d)' % len(audio_files(path)),
                              'clips': [dict(url=url(os.path.join(path, f)), **file_info(os.path.join(path, f))) for f in audio_files(path)]})
        if items:
            found[name] = items
    return found


def read_events(listen):
    """[(ms, kind, name, length ms)] of a_events.txt, and the path of a.wav; ([], None) without them."""
    events_path, wav = os.path.join(listen, 'a_events.txt'), os.path.join(listen, 'a.wav')
    if not (os.path.exists(events_path) and os.path.exists(wav)):
        return [], None
    events = []
    with open(events_path, encoding='utf-8') as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 4 and parts[0].isdigit() and parts[3].isdigit():
                events.append((int(parts[0]), parts[1], parts[2], int(parts[3])))
    return events, wav


def cut_recordings(listen, vanilla_names, problems):
    """Cuts the game recording's events into lab/ref/: every `ref`, and the act/done ones of a sound our cues use."""
    out = []
    events, wav = read_events(listen) if listen else ([], None)
    if not events:
        if listen:
            problems.append('--listen %s: no a.wav with a_events.txt there' % listen)
        return out
    if sf is None:
        problems.append('numpy and soundfile are needed to cut the recording')
        return out
    folder = os.path.join(LAB, 'ref')
    os.makedirs(folder, exist_ok=True)
    for old in os.listdir(folder):
        if old.endswith('.wav'):
            os.remove(os.path.join(folder, old))
    data, rate = sf.read(wav, dtype='float32')
    for ms, kind, name, length in events:
        if kind != 'ref' and not (kind in ('act', 'done') and name in vanilla_names):
            continue
        a = int(ms / 1000 * rate)
        piece = data[a:a + int(length / 1000 * rate)]
        if len(piece) == 0:
            continue
        path = os.path.join(folder, '%s.wav' % name if kind == 'ref' else '%s_%s.wav' % (name, kind))
        sf.write(path, piece, rate, subtype='PCM_16')
        out.append(dict(name=name, kind=kind, url=url(path), ms=ms, length=length, **(levels(piece) or {})))
    return out


# ---------------------------------------------------------------------------------------------------------------------

def group_of(cue):
    if cue['timed']:
        return 'actions'
    if COMMS_WORDS & set(cue['id'].split('.')):
        return 'comms'
    if cue['id'].startswith('kit.') or (cue['uses'] and all(u['how'] == 'ui' for u in cue['uses'])):
        return 'ui'
    return 'world'


def only_items(text, classes):
    """The comma-separated items of an S6 action cell that name one of the classes (a cell can hold a mod's and another's)."""
    items = re.split(r'(?<=\)),\s*', text)   # an item ends with its parenthesis (the classes)
    keep = [i for i in items if any('`%s`' % c in i for c in classes)]
    return ', '.join(keep) if keep else text


def build(listen):
    problems = []
    cues, boards, timed, sources, lua_problems = read_lua()
    problems += lua_problems
    find_uses(cues, sources)
    for t in timed:
        if t['cue'] in cues:
            if not any(x['cls'] == t['cls'] and x['mode'] == t['mode'] for x in cues[t['cue']]['timed']):
                cues[t['cue']]['timed'].append(t)
        elif not t['cue'].startswith('kit.title.'):
            problems.append('%s: Sound.timed(%s) plays %s, a cue no table defines' % (t['where'], t['cls'], t['cue']))
    scripts = read_scripts()
    table = read_table()
    events, action_text = read_s6()
    candidates = read_candidates()
    used_folders = set()

    sounds = {}
    for name, s in scripts.items():
        clips = []
        for c in s['clips']:
            path = os.path.join(MODS, c['game'], c['file'])
            exists = os.path.exists(path)
            clip = {'file': c['file'], 'volume': c['volume'] * s['volume'], 'pitch': c['pitch'], 'exists': exists}
            if exists:
                clip['url'] = url(path)
                clip.update(file_info(path))
            else:
                problems.append('sound %s: clip %s is not on disk' % (name, c['file']))
            clips.append(clip)
        meta = table.get(name, {})
        sounds[name] = {'name': name, 'category': s['category'], 'master': s['master'], 'loop': s['loop'], 'script': s['script'],
                        'clips': clips, 'peakTarget': meta.get('peak', meta.get('_peak')) if meta else None,
                        'length': meta.get('length'), 'sources': sorted({c['src'].split('/')[-1] for c in meta.get('clips', [])})}

    for board in boards.values():
        for key in ('letters', 'space', 'enter', 'back'):
            for name in (board[key] if isinstance(board[key], list) else [board[key]]):
                if name and name not in scripts:
                    problems.append('keyboard %s: key sound %s is not one of ours' % (board['id'], name))

    out_cues = []
    for cue in cues.values():
        desc, src = '', ''
        if cue['id'] in events:
            desc, src = events[cue['id']][0], 'S6'
            cue['memo'] = events[cue['id']][1]
        elif cue['id'] in action_text:
            desc, src = action_text[cue['id']], 'S6'
        if src == 'S6' and cue['id'] in action_text and cue['id'] not in events:
            desc = only_items(desc, {t['cls'] for t in cue['timed']})
        cue['desc'], cue['descSrc'] = desc.replace('`', ''), src
        cue['group'] = group_of(cue)
        cue['ours'] = bool(cue['sound'] and cue['sound'] in scripts) or bool(cue['keyboard'] in boards)
        if cue['keyboard'] and cue['keyboard'] not in boards:
            problems.append('%s:%d: cue %s names the keyboard %s, which is not defined' % (cue['file'], cue['line'], cue['id'], cue['keyboard']))
        picks = []
        for folder in (cue['id'], cue['sound'], cue['keyboard']):
            if folder and folder in candidates and folder not in used_folders:
                used_folders.add(folder)
                picks.append(folder)
            elif folder and folder in candidates:
                picks.append(folder)
        cue['candidates'] = [dict(c, folder=f) for f in dict.fromkeys(picks) for c in candidates[f]]
        out_cues.append(cue)

    extra = [{'folder': f, 'candidates': [dict(c, folder=f) for c in cs]} for f, cs in candidates.items() if f not in used_folders]

    vanilla_names = {c['sound'] for c in out_cues if c['sound'] and c['sound'] not in scripts}
    refs = cut_recordings(listen, vanilla_names, problems)
    by_name = {}
    for r in refs:
        by_name.setdefault(r['name'], r)
    for c in out_cues:
        r = by_name.get(c['sound']) if c['sound'] and c['sound'] not in scripts else None
        c['recording'] = r['url'] if r else None
        c['recordingKind'] = r['kind'] if r else None

    return {'cues': out_cues, 'keyboards': list(boards.values()), 'sounds': sounds, 'refs': [r for r in refs if r['kind'] == 'ref'],
            'recordings': [r for r in refs if r['kind'] != 'ref'], 'extraCandidates': extra, 'problems': problems,
            'mods': [m for m, _ in MOD_DIRS.values()], 'titleLab': '../../../../extension-api/tools/title-lab/title-lab.html',
            'generated': time.strftime('%Y-%m-%d %H:%M')}


def title_cue_count():
    n = 0
    for path, _ in lua_files():
        with open(path, encoding='utf-8', errors='replace') as f:
            n += len(set(re.findall(r'"(kit\.title\.[A-Za-z0-9_.]+)"', f.read())))
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--listen', help='folder with a.wav and a_events.txt (a game recording)')
    ap.add_argument('--out', default=os.path.join(LAB, 'manifest.js'))
    a = ap.parse_args()
    listen = a.listen
    if not listen and os.path.isdir(os.path.join(HERE, 'report', 'listen')):
        listen = os.path.join(HERE, 'report', 'listen')
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    data = build(listen)
    data['titleCues'] = title_cue_count()
    with open(a.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('/* Made by pz-tools/mods/tools/sound/lab.py: run it again, do not edit. */\nwindow.SOUNDLAB = ')
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write(';\n')
    cues = data['cues']
    ours = sum(1 for c in cues if c['ours'])
    print('%d cues (%d ours, %d vanilla, %d silent), %d keyboards, %d sounds of ours, %d level references, %d recordings, '
          '%d candidate sets (+%d folders with no cue); %d title cues left to the title lab' % (
              len(cues), ours, sum(1 for c in cues if c['sound'] and not c['ours']), sum(1 for c in cues if not c['sound'] and not c['keyboard']),
              len(data['keyboards']), len(data['sounds']), len(data['refs']), len(data['recordings']),
              sum(1 for c in cues if c['candidates']), len(data['extraCandidates']), data['titleCues']))
    for p in data['problems']:
        print('problem: ' + p)
    print('->', a.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
