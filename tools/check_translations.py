"""Checks the mod's texts (every translation file, EN and KO) against the Lua code, the sandbox options and the scripts.

Reports:
- keys one language has and the other lacks, in any file;
- UI keys (IG_UI and ContextMenu) the code names that no language has, and UI keys no code names (directly, or by a
  prefix the code builds keys from, as getText("IGUI_OA_Reason_" .. reason));
- sandbox pages and options (media/sandbox-options.txt) without a name, options without a tooltip, and sandbox texts
  no page or option has;
- items and craft recipes (media/scripts) without a name, and names no item or recipe has;
- texts with a bare percent sign, which breaks the game's String.format, and texts whose %1, %2 ... differ between
  the languages.
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
UI_FILES = ['IG_UI.json', 'ContextMenu.json', 'Tooltip.json']
FILES = UI_FILES + ['Sandbox.json', 'ItemName.json', 'Recipes.json', 'Moveables.json']
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
                if re.search(r'%(?!\d)', text):
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
    prefixes = set(PREFIX.findall(lua)) - {'IGUI_OA_'}
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

    for line in problems:
        print(line)
    print('%d UI keys, %d sandbox, %d items, %d recipes; %d problems' % (len(every), len(sandbox), len(items),
                                                                        len(recipes), len(problems)))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
