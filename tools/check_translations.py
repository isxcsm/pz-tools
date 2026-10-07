"""Checks the mod's UI texts (IG_UI and ContextMenu, EN and KO) against the Lua code.

Reports keys one language has and the other lacks, keys the code names that no language has, keys no code names
(directly, or by a prefix the code builds keys from, as getText("IGUI_BU_Reason_" .. reason)), and texts with a bare
percent sign, which breaks the game's String.format. Exit code 1 when anything is found.

    py tools/check_translations.py
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'BuildingUtilities', '42', 'media', 'lua')
FILES = ['IG_UI.json', 'ContextMenu.json']
LANGS = ['EN', 'KO']
KEY = re.compile(r'"((?:IGUI|ContextMenu|Tooltip)_BU_\w*|IGUI_ContainerTitle_BuildingUtilities\w*)"(?!\s*\.\.)')
PREFIX = re.compile(r'"((?:IGUI|ContextMenu|Tooltip)_BU_\w+)"\s*\.\.')
# Keys built in ways the patterns above cannot see: the game names a container's title itself
# (IGUI_ContainerTitle_<type>); the list's row buttons are "IGUI_BU_" .. name (PanelList.lua, BUTTONS).
BUILT = {'IGUI_ContainerTitle_BuildingUtilitiesRack', 'IGUI_BU_Up', 'IGUI_BU_Down', 'IGUI_BU_Remove'}


def load(lang):
    keys = {}
    for name in FILES:
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


def main():
    langs = {lang: load(lang) for lang in LANGS}
    lua = code()
    named = set(KEY.findall(lua))
    prefixes = set(PREFIX.findall(lua)) - {'IGUI_BU_'}
    problems = []
    for lang in LANGS:
        for other in LANGS:
            if other != lang:
                for key in sorted(set(langs[other]) - set(langs[lang])):
                    problems.append('%s lacks %s' % (lang, key))
    every = set().union(*langs.values())
    for key in sorted(named - every):
        problems.append('no text for %s' % key)
    for key in sorted(every - named - BUILT):
        if not any(key.startswith(p) for p in prefixes):
            problems.append('unused %s' % key)
    for lang in LANGS:
        for key, text in langs[lang].items():
            if re.search(r'%(?!\d)', text):
                problems.append('bare %% in %s %s' % (lang, key))
    for line in problems:
        print(line)
    print('%d keys, %d problems' % (len(every), len(problems)))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
