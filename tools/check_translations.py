"""Checks the mod's texts (every translation file, EN and KO) against the Lua code, the sandbox options and the scripts.

Reports:
- keys one language has and the other lacks, in any file;
- UI keys (IG_UI and ContextMenu) the code names that no language has, and UI keys no code names (directly, or by a
  prefix the code builds keys from, as getText("IGUI_OA_Reason_" .. reason), or a quoted stem ending in _);
- sandbox pages and options (media/sandbox-options.txt) without a name, options without a tooltip, and sandbox texts
  no page or option has;
- items and craft recipes (media/scripts) without a name, and names no item or recipe has;
- texts with a bare percent sign (not %%), which breaks the game's String.format, and texts whose %1, %2 ... differ between
  the languages;
- letters past ASCII inside a string in the Lua code: the game reads mod Lua so that they come out as U+FFFD (write
  them as string.char(code) or take them from a translation);
- a UI element's anchor written as a field (view.anchorRight = true): the game hands anchors to the Java side only
  when the element is made, so a field written after that does nothing and the element keeps its size when the
  window is resized (use view:setAnchorRight(true), which works before and after);
- an option added to the bottom of the game's own menu: a client `context:addOption(` (the options of this mod go on top
  of the world and inventory menus: addOptionOnTop; a menu of this mod's own, or an option that is meant to be at the
  bottom, carries the comment `-- oa-menu: bottom` on its line or the line above);
- a search of the whole inventory or of a container (a *Recurse call, a loop over getItems()) in a function that runs
  while a right-click menu is built, every tick or frame, or at every refresh: see inventory_scans() for how they are
  found and what it cannot see. A search that is meant to be there (made once for a changed signature, or when the
  player has acted) carries `-- oa-scan: ok (why)` on its line or within the two lines above;
- a game widget that draws its text in the game's font (ISRichTextPanel, ISButton:new, ISComboBox, ISModalDialog,
  ISLabel:new) in the client files of the mod's windows (Trade/, Story/, Machines/ and the research tab
  Upgrades/Window.lua, less the files that draw on the game's own windows and menus: WIDGET_EXCLUDED): the windows' texts are drawn in faces (Trade/UI.lua), so their
  widgets are the mod's own (Trade/Button, RichText, Combo, Confirm). One that is meant to be there carries
  `-- oa-widget: ok (why)` on its line or the line above.
Exit code 1 when anything is found.

Texts too long or too many for code (the radio log, documents, receipt notes) may live in other Translate files
(OA_*.json); this only checks that each language has the same keys there.

    py tools/check_translations.py
"""
import json
import os
import re
import sys

MEDIA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'OperationAcorn', '42', 'media')
ROOT = os.path.join(MEDIA, 'lua')
# The developer sub-mod (Operation Acorn Dev): its own texts (IGUI_OADev_*) and Lua, checked by dev_problems().
DEV_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'OperationAcornDev', '42', 'media', 'lua')
UI_FILES = ['IG_UI.json', 'ContextMenu.json', 'Tooltip.json']
FILES = UI_FILES + ['Sandbox.json', 'ItemName.json', 'Recipes.json', 'Moveables.json', 'Moodles.json', 'Fluids.json']
LANGS = ['EN', 'KO']
KEY = re.compile(r'["\']((?:IGUI|ContextMenu|Tooltip)_OA_\w*|IGUI_ContainerTitle_OA\w*)["\'](?!\s*\.\.)')
PREFIX = re.compile(r'["\']((?:IGUI|ContextMenu|Tooltip)_OA_\w+)["\']\s*\.\.')
# Keys built in ways the patterns above cannot see (the game names a container's title itself,
# IGUI_ContainerTitle_<type>). Add them here with where they are built.
BUILT = set()


def load(lang, names):
    keys = {}
    for name in names:
        path = os.path.join(ROOT, 'shared', 'Translate', lang, name)
        with open(path, encoding='utf-8') as f:
            keys.update(json.load(f))
    return keys


def code():
    texts = []
    for folder, _, files in os.walk(ROOT):
        if 'Translate' in folder:
            continue
        for name in files:
            if name.endswith('.lua'):
                with open(os.path.join(folder, name), encoding='utf-8') as f:
                    texts.append(f.read())
    return '\n'.join(texts)


LUA_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')


def non_ascii_strings(root=ROOT):
    """(file, line, string) for each string in the Lua code (comments left out) with a letter past ASCII."""
    found = []
    for folder, _, files in os.walk(root):
        if 'Translate' in folder:
            continue
        for name in files:
            if not name.endswith('.lua'):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding='utf-8') as f:
                for n, line in enumerate(f, 1):
                    pos = 0
                    for m in LUA_STRING.finditer(line):
                        if '--' in line[pos:m.start()]:
                            break
                        if any(ord(c) > 127 for c in m.group(0)):
                            found.append((os.path.relpath(path, root), n, m.group(0)))
                        pos = m.end()
    return found


ANCHOR_FIELD = re.compile(r'^\s*[\w.]+\.anchor(?:Right|Bottom|Left|Top)\s*=')


def anchor_fields(root=ROOT):
    """(file, line) for each anchor written as a field in the Lua code."""
    found = []
    for folder, _, files in os.walk(root):
        for name in files:
            if name.endswith('.lua'):
                path = os.path.join(folder, name)
                with open(path, encoding='utf-8') as f:
                    for n, line in enumerate(f, 1):
                        if ANCHOR_FIELD.match(line):
                            found.append((os.path.relpath(path, root), n))
    return found


CONTEXT_ADD = re.compile(r'\bcontext:addOption\(')
BOTTOM_OK = re.compile(r'--\s*oa-menu:\s*bottom')


def lua_files(*parts):
    """(path relative to the Lua root, lines) for each Lua file under the given folders of the Lua root."""
    found = []
    for folder, _, files in os.walk(os.path.join(ROOT, *parts)):
        if 'Translate' in folder:
            continue
        for name in sorted(files):
            if name.endswith('.lua'):
                path = os.path.join(folder, name)
                with open(path, encoding='utf-8') as f:
                    found.append((os.path.relpath(path, ROOT), f.read().split('\n')))
    return found


def bottom_options():
    """(file, line) for each `context:addOption(` in the client code that is not marked as meant for the bottom."""
    found = []
    for path, lines in lua_files('client'):
        for n, line in enumerate(lines):
            code = line.split('--')[0]
            if CONTEXT_ADD.search(code):
                if not BOTTOM_OK.search(line) and not (n > 0 and BOTTOM_OK.search(lines[n - 1])):
                    found.append((path, n + 1))
    return found


# What counts as a search of the inventory or of a container: the game's *Recurse calls (getFirstTypeRecurse,
# getAllEvalRecurse, containsRecursive, getItemWithIDRecursiv ...) and a walk over getItems() (its size or isEmpty is
# one call and no search).
SCAN = re.compile(r'\w*Recurs\w*\(|\bgetItems\(\)(?!\s*:\s*(?:size|isEmpty)\()')
SCAN_OK = re.compile(r'--\s*oa-scan:\s*ok')
# The events whose handlers run while a menu is built, every tick or frame, or at a refresh of the screen.
HOT_EVENTS = ('OnFillWorldObjectContextMenu', 'OnFillInventoryObjectContextMenu', 'OnTick', 'OnTickEvenPaused',
              'OnPlayerUpdate', 'OnRenderTick', 'OnRefreshInventoryWindowContainers')
# The methods that run every frame or tick whatever registers them (a window's, a pane's, a cursor's, a timed action's;
# written with a colon, as the game's classes are: a function of a module that happens to be called update is not one).
HOT_METHODS = ('render', 'prerender', 'update', 'renderdetails', 'isValid')
FUNCTION = re.compile(r'^(\s*)(?:local\s+)?function\s+([\w.:]+)\s*\(|^(\s*)(?:local\s+)?([\w.]+)\s*=\s*function\s*\(')
ONE_LINER = re.compile(r'\bend\s*\)*\s*[,;]?\s*(?:--.*)?$')
HANDLER = re.compile(r'Events\.(\w+)\.Add\(\s*([\w.]+)\s*\)')
INLINE_HANDLER = re.compile(r'^(\s*)Events\.(\w+)\.Add\(\s*function\b')
CALL = re.compile(r'(?:\b(\w+)[.:])?\b(\w+)\s*\(')


def lua_functions(path, lines):
    """The functions of a file by their indentation: [{ name, short, file, first, last, scans, calls }]. A function runs
    from its `function` line to the next `end` at the same indentation (a one-line function is the line)."""
    found = []
    for n, line in enumerate(lines):
        m = FUNCTION.match(line)
        if not m:
            continue
        indent = m.group(1) if m.group(2) else m.group(3)
        name = m.group(2) or m.group(4)
        last = n
        if not ONE_LINER.search(line.split('function', 1)[1]):
            for k in range(n + 1, len(lines)):
                if re.match(r'^' + re.escape(indent) + r'end\b', lines[k]):
                    last = k
                    break
        found.append({'name': name, 'short': re.split(r'[.:]', name)[-1], 'file': path, 'first': n, 'last': last})
    return found


def marked_ok(lines, n):
    """Whether line n carries the mark of a search that belongs, or one of the two lines above it does."""
    return any(SCAN_OK.search(lines[k]) for k in range(max(0, n - 2), n + 1))


def scan_lines(lines, first, last):
    """(line number, call) for each unmarked search in the lines from first to last."""
    found = []
    for n in range(first, last + 1):
        code = lines[n].split('--')[0]
        m = SCAN.search(code)
        if m and not marked_ok(lines, n):
            found.append((n + 1, m.group(0).rstrip('(')))
    return found


def function_calls(lines, first, last):
    """The calls inside lines first+1 .. last (comments and marked lines left out) as (receiver, name): `a.b.f(` is
    ('b', 'f'), `self:f(` is ('self', 'f'), a plain `f(` is (None, 'f')."""
    calls = set()
    for n in range(first + 1, last + 1):
        if marked_ok(lines, n):
            continue
        code = lines[n].split('--')[0]
        for m in CALL.finditer(code):
            calls.add((m.group(1), m.group(2)))
    return calls


def inventory_scans():
    """(file, line, kind, function, (file, line, call, functions it goes through)) for each search of an inventory or
    container in code that runs while a menu is built, every tick or frame, or at a refresh. A heuristic on the text,
    which sees:
      - a search written in a function that is registered with one of HOT_EVENTS (by name, or inline) or is one of
        HOT_METHODS (render, update ... written with a colon);
      - one in a function that such a function calls, and so on: a plain call or self:f( finds a function of the same
        file, Table.f( or Table:f( finds the function the mod defines as Table.f (or Table:f) in any file.
    It does not see: a function that is passed or stored and called later (a callback, a button's handler: that runs when
    the player acts, which is where a search belongs); a call through a variable or an alias that is not the table's
    name (view:refresh()); a function the game's classes and the mod's share a name of, on a receiver of that name; the
    cost of a loop that is not over getItems(); a search made once for a changed signature or at the player's act, unless
    it carries `-- oa-scan: ok (why)` on its line or within the two lines above (a marked line is no search and no call
    for this check). A function found only by the indentation of its end: a file indented some other way is misread."""
    files = lua_files('client') + lua_files('shared') + lua_files('server')
    by_file = {path: lines for path, lines in files}
    functions = []
    for path, lines in files:
        functions.extend(lua_functions(path, lines))
    names = {}
    for f in functions:
        f['table'] = re.split(r'[.:]', f['name'])[-2] if re.search(r'[.:]', f['name']) else None
        names.setdefault(f['short'], []).append(f)
        f['scans'] = scan_lines(by_file[f['file']], f['first'], f['last'])
        f['calls'] = function_calls(by_file[f['file']], f['first'], f['last'])

    def callees(f):
        """The functions of the mod a function calls."""
        for receiver, name in f['calls']:
            for g in names.get(name, []):
                if g is f:
                    continue
                same_file = g['file'] == f['file']
                if (receiver is None and same_file) or (receiver == 'self' and same_file) or \
                        (receiver is not None and receiver == g['table']):
                    yield g

    def witness(f, seen=()):
        """The first search a function reaches: (file, line, call, the functions it goes through), or None."""
        if f['scans']:
            line, call = f['scans'][0]
            return f['file'], line, call, [f['name']]
        for g in callees(f):
            if id(g) in seen:
                continue
            hit = witness(g, seen + (id(f),))
            if hit:
                return hit[0], hit[1], hit[2], [f['name']] + hit[3]
        return None

    roots = []
    registered = set()
    for path, lines in files:
        for n, line in enumerate(lines):
            code = line.split('--')[0]
            for m in HANDLER.finditer(code):
                if m.group(1) in HOT_EVENTS:
                    registered.add((path, m.group(2).split('.')[-1], m.group(1)))
            m = INLINE_HANDLER.match(code)
            if m and m.group(2) in HOT_EVENTS:
                last = n
                for k in range(n + 1, len(lines)):
                    if re.match(r'^' + re.escape(m.group(1)) + r'end\b', lines[k]):
                        last = k
                        break
                roots.append(('event ' + m.group(2), {
                    'name': 'handler of ' + m.group(2), 'short': 'handler', 'file': path, 'first': n, 'last': last,
                    'scans': scan_lines(lines, n + 1, last), 'calls': function_calls(lines, n, last), 'table': None}))
    for f in functions:
        for path, short, event in registered:
            if f['file'] == path and f['short'] == short:
                roots.append(('event ' + event, f))
        if f['short'] in HOT_METHODS and ':' in f['name']:
            roots.append(('method ' + f['short'], f))
    found = []
    seen = set()
    for kind, f in roots:
        hit = witness(f)
        if hit and (f['file'], f['first']) not in seen:
            seen.add((f['file'], f['first']))
            found.append((f['file'], f['first'] + 1, kind, f['name'], hit))
    return found


# The game's widgets that draw their text in the game's font, the folders of the mod's windows, and the files there that
# draw on the game's own windows and menus (the item tooltip, the loot window's estimate and controls, the menus).
WIDGET = re.compile(r'\bISRichTextPanel\b|\bISButton:new\b|\bISComboBox\b|\bISModalDialog\b|\bISLabel:new\b')
WIDGET_OK = re.compile(r'--\s*oa-widget:\s*ok')
WIDGET_FOLDERS = ('Trade', 'Story', 'Machines')
# Windows of the mod in other folders.
WIDGET_FILES = ('Upgrades/Window.lua',)
WIDGET_EXCLUDED = ('Trade/ItemTip.lua', 'Trade/Appraisal.lua', 'Trade/ContextMenu.lua', 'Story/Menus.lua',
                   'Machines/Menu.lua', 'Machines/LootControls.lua', 'Machines/Lure.lua')


def game_widgets(files):
    """(file, line, widget) for each game text widget named in the code (not a comment) of the (path, lines) given,
    the excluded files and the marked lines left out."""
    found = []
    for path, lines in files:
        if path.replace(os.sep, '/').endswith(WIDGET_EXCLUDED):
            continue
        for n, line in enumerate(lines):
            m = WIDGET.search(line.split('--')[0])
            if m and not WIDGET_OK.search(line) and not (n > 0 and WIDGET_OK.search(lines[n - 1])):
                found.append((path, n + 1, m.group(0)))
    return found


def window_files():
    """The client files of the mod's windows."""
    files = []
    for folder in WIDGET_FOLDERS:
        files += lua_files('client', 'OperationAcorn', folder)
    for name in WIDGET_FILES:
        path = os.path.join(ROOT, 'client', 'OperationAcorn', *name.split('/'))
        with open(path, encoding='utf-8') as f:
            files.append((os.path.relpath(path, ROOT), f.read().split('\n')))
    return files


def sandbox_keys():
    """The texts the sandbox options need: each page's name, and each option's name and tooltip."""
    with open(os.path.join(MEDIA, 'sandbox-options.txt'), encoding='utf-8') as f:
        text = f.read()
    names = re.findall(r'translation\s*=\s*(\w+)', text)
    keys = {'Sandbox_' + page for page in re.findall(r'page\s*=\s*(\w+)', text)}
    for name in names:
        keys |= {'Sandbox_' + name, 'Sandbox_' + name + '_tooltip'}
    return keys


def script_keys():
    """The names the scripts need: "<module>.<item>" for each item, the recipe's name for each craft recipe."""
    items, recipes = set(), set()
    for folder, _, files in os.walk(os.path.join(MEDIA, 'scripts')):
        for name in files:
            if not name.endswith('.txt'):
                continue
            with open(os.path.join(folder, name), encoding='utf-8') as f:
                text = f.read()
            found = re.search(r'^\s*module\s+(\w+)', text, re.M)
            if not found:
                continue
            module = found.group(1)
            items |= {module + '.' + item for item in re.findall(r'^\s*item\s+(\w+)\s*$', text, re.M)}
            recipes |= set(re.findall(r'^\s*craftRecipe\s+(\w+)', text, re.M))
    return items, recipes


DEV_PREFIX = 'IGUI_OADev_'
DEV_KEY = re.compile(r'\bT\("(\w+)"\)')
DEV_STEM = re.compile(r'\bT\("(\w+_)"\s*\.\.')


def dev_problems():
    """Problems of the developer sub-mod: its EN and KO texts (same keys, same %1 ...), every T("Key") of its Lua has a
    text and every text is used (a T("Stem_" .. x) uses the keys that start with the stem), no letters past ASCII in
    its Lua strings, no anchor written as a field."""
    problems = []
    folder = os.path.join(DEV_ROOT, 'shared', 'Translate')
    if not os.path.isdir(folder):
        return problems
    texts = {}
    for lang in LANGS:
        path = os.path.join(folder, lang, 'IG_UI.json')
        with open(path, encoding='utf-8') as f:
            texts[lang] = json.load(f)
    for lang in LANGS:
        for other in LANGS:
            if other != lang:
                for key in sorted(set(texts[other]) - set(texts[lang])):
                    problems.append('dev: %s lacks %s' % (lang, key))
        for key, text in texts[lang].items():
            if not key.startswith(DEV_PREFIX):
                problems.append('dev: %s is not named %s*' % (key, DEV_PREFIX))
            if re.search(r'%(?!\d)', text.replace('%%', '')):
                problems.append('dev: bare %% in %s %s' % (lang, key))
    for key in sorted(set(texts['EN']) & set(texts['KO'])):
        if sorted(set(re.findall(r'%\d', texts['EN'][key]))) != sorted(set(re.findall(r'%\d', texts['KO'][key]))):
            problems.append('dev: %s takes different arguments in EN and KO' % key)
    lua = []
    for root, _, files in os.walk(DEV_ROOT):
        if 'Translate' in root:
            continue
        for name in files:
            if name.endswith('.lua'):
                with open(os.path.join(root, name), encoding='utf-8') as f:
                    lua.append(f.read())
    lua = '\n'.join(lua)
    named = set(DEV_PREFIX + k for k in DEV_KEY.findall(lua))
    stems = set(DEV_PREFIX + k for k in DEV_STEM.findall(lua))
    every = set(texts['EN'])
    for key in sorted(named - every):
        problems.append('dev: no text for %s' % key)
    for key in sorted(every - named):
        if not any(key.startswith(stem) for stem in stems):
            problems.append('dev: unused %s' % key)
    for path, n, text in non_ascii_strings(DEV_ROOT):
        problems.append('dev: letters past ASCII in Lua code %s:%d %s' % (path, n, text))
    for path, n in anchor_fields(DEV_ROOT):
        problems.append('dev: anchor written as a field (use setAnchor...) %s:%d' % (path, n))
    return problems


def main():
    problems = []
    for name in FILES:
        texts = {lang: load(lang, [name]) for lang in LANGS}
        for lang in LANGS:
            for other in LANGS:
                if other != lang:
                    for key in sorted(set(texts[other]) - set(texts[lang])):
                        problems.append('%s lacks %s (%s)' % (lang, key, name))
        for key in sorted(texts['EN']):
            params = {lang: sorted(set(re.findall(r'%\d', texts[lang].get(key, '')))) for lang in LANGS}
            if key in texts['KO'] and params['EN'] != params['KO']:
                problems.append('%s takes %s in EN, %s in KO' % (key, ' '.join(params['EN']) or 'nothing',
                                                               ' '.join(params['KO']) or 'nothing'))
        for lang in LANGS:
            for key, text in texts[lang].items():
                # '%%' is the escaped sign (the game's own texts write 10%%)
                if re.search(r'%(?!\d)', text.replace('%%', '')):
                    problems.append('bare %% in %s %s' % (lang, key))

    extra = sorted(n for n in os.listdir(os.path.join(ROOT, 'shared', 'Translate', 'EN')) if n.startswith('OA_'))
    for name in extra:
        texts = {lang: load(lang, [name]) for lang in LANGS}
        for lang in LANGS:
            for other in LANGS:
                if other != lang:
                    for key in sorted(set(texts[other]) - set(texts[lang])):
                        problems.append('%s lacks %s (%s)' % (lang, key, name))

    langs = {lang: load(lang, UI_FILES) for lang in LANGS}
    lua = code()
    named = set(KEY.findall(lua))
    # a quoted stem ending in _ (a bundle's prefix = "IGUI_OA_..._") is a prefix too: no key ends in _
    stems = {k for k in named if k.endswith('_')}
    named -= stems
    # an item script's Tooltip = <key> uses its key too
    for folder, _, files in os.walk(os.path.join(MEDIA, 'scripts')):
        for f in files:
            if f.endswith('.txt'):
                with open(os.path.join(folder, f), encoding='utf-8') as fh:
                    named |= set(re.findall(r'\bTooltip\s*=\s*(Tooltip_OA_\w+)', fh.read()))
    prefixes = (set(PREFIX.findall(lua)) | stems) - {'IGUI_OA_'}
    every = set().union(*langs.values())
    for key in sorted(named - every):
        problems.append('no text for %s' % key)
    for key in sorted(every - named - BUILT):
        if not any(key.startswith(p) for p in prefixes):
            problems.append('unused %s' % key)

    sandbox = set().union(*(load(lang, ['Sandbox.json']) for lang in LANGS))
    needed = sandbox_keys()
    for key in sorted(needed - sandbox):
        problems.append('no sandbox text %s' % key)
    for key in sorted(sandbox - needed):
        problems.append('sandbox text for no option %s' % key)

    items, recipes = script_keys()
    for name, needed in (('ItemName.json', items), ('Recipes.json', recipes)):
        have = set().union(*(load(lang, [name]) for lang in LANGS))
        for key in sorted(needed - have):
            problems.append('no text for %s (%s)' % (key, name))
        for key in sorted(have - needed):
            problems.append('%s names nothing in the scripts (%s)' % (key, name))

    for path, n, text in non_ascii_strings():
        problems.append('letters past ASCII in Lua code %s:%d %s' % (path, n, text))
    for path, n in anchor_fields():
        problems.append('anchor written as a field (use setAnchor...) %s:%d' % (path, n))
    for path, n in bottom_options():
        problems.append("option added to the bottom of a menu (use addOptionOnTop, or mark it -- oa-menu: bottom) %s:%d"
                        % (path, n))
    for path, n, kind, name, (where, line, call, chain) in inventory_scans():
        problems.append('%s %s (%s:%d) searches the inventory or a container: %s at %s:%d, through %s (cache it under a '
                        'signature or do it when the player acts; mark a search that belongs -- oa-scan: ok)'
                        % (kind, name, path, n, call, where, line, ' > '.join(chain)))

    for path, n, widget in game_widgets(window_files()):
        problems.append("the game's %s in a window of the mod %s:%d (it draws in the game's font: use the mod's widget, "
                        'or mark it -- oa-widget: ok)' % (widget, path, n))

    problems.extend(dev_problems())

    for line in problems:
        print(line)
    print('%d UI keys, %d sandbox, %d items, %d recipes; %d problems' % (len(every), len(sandbox), len(items),
                                                                        len(recipes), len(problems)))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
