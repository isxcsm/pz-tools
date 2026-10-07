"""The room names of the game's maps, against the room names the mod translates (IGUI_BU_Room_<name>).

A map's rooms are named in its .lotheader files ("kitchen", "gasstore"); the game has no words for them, so the mod
gives them its own (BU.roomName, which shows a name without one capitalised). Reads the headers as the game does
(IsoMetaGrid: "LOTH", version, the tiles used, the chunk size and levels, then each room: its name, level, rectangles
and objects) and lists the names no translation file has, the most rooms first, then the translated names no map
has (texts no room shows). Exit code 1 when there are either.

    py tools/room_names.py           the names without a translation, with how many rooms have them
    py tools/room_names.py --all     every name, with its count
"""
import glob
import json
import os
import struct
import sys
from collections import Counter

GAME = r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid'
TRANSLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'BuildingUtilities', '42', 'media', 'lua',
                         'shared', 'Translate')
PREFIX = 'IGUI_BU_Room_'


def rooms(path):
    data = open(path, 'rb').read()
    at = 0

    def integer():
        nonlocal at
        value = struct.unpack_from('<i', data, at)[0]
        at += 4
        return value

    def line():
        nonlocal at
        end = data.index(b'\n', at)
        value = data[at:end].decode('latin1').rstrip('\r')
        at = end + 1
        return value

    if data[:4] == b'LOTH':
        at = 4
    version = integer()
    for _ in range(integer()):
        line()
    if version == 0:
        at += 1
    integer(), integer()  # the chunk's width and height
    if version == 0:
        integer()
    else:
        integer(), integer()
    for _ in range(integer()):
        name = line()
        integer()  # level
        rects = integer()
        at += 16 * rects
        objects = integer()
        at += 12 * objects
        yield name


def counts():
    result = Counter()
    for path in glob.glob(os.path.join(GAME, 'media', 'maps', '*', '*.lotheader')):
        result.update(rooms(path))
    return result


def translated():
    keys = set()
    for path in glob.glob(os.path.join(TRANSLATE, '*', 'IG_UI.json')):
        keys |= {key[len(PREFIX):] for key in json.load(open(path, encoding='utf-8')) if key.startswith(PREFIX)}
    return keys


def main():
    found = counts()
    have = translated()
    names = found if '--all' in sys.argv else {name: count for name, count in found.items() if name and name not in have}
    for name, count in sorted(names.items(), key=lambda item: (-item[1], item[0])):
        print(count, name)
    unused = sorted(have - set(found))
    for name in unused:
        print('no map has', name)
    missing = len([n for n in found if n and n not in have])
    print('%d names, %d without a translation, %d translations no map has' % (len(found), missing, len(unused)),
          file=sys.stderr)
    return 1 if missing or unused else 0


if __name__ == '__main__':
    sys.exit(main())
