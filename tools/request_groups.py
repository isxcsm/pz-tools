"""The weekly request list's table (NUMBERS 2): what the team asks for, grouped one level above the item type, and how
easy each group is to come by, worked out from the game's own files. Writes
OperationAcorn/42/media/lua/shared/OperationAcorn/Economy/RequestGroups.lua (the mod loads it; do not edit it by hand)
and, with --report, a plain text summary next to it in the scratch folder given (the counts, the groups, what was left out).

    py -X utf8 tools/request_groups.py                  writes the Lua table
    py -X utf8 tools/request_groups.py --report DIR     also writes DIR/request-groups.txt

What it reads (B42, the installed game):
- the item scripts (media/scripts/**.txt): display category, item type, weight, tags;
- the item names (Translate/EN and KO ItemName.json): variants are the names whose words before ' [' are the same,
  in Korean, or in English when the kinds are of one display category and their Korean names are near each other;
- the loot tables (media/lua/server/Items: Distributions.lua, ProceduralDistributions.lua and the tables they name)
  and how many rooms of each name the maps have (media/maps/*/*.lotheader), for how often a thing is found;
- craftRecipe (inputs, outputs, SkillRequired, NeedToBeLearn), the foraging categories, the farm crops, the animal
  parts, fishing and trapping, and the parts vehicles are built from: the other ways to come by a thing;
- the mod's own Categories.lua: what the delivery boxes take (the request candidates are taken things only).

The rules (written out in mockups/terminal/request-groups-report.md):
- Candidates: the kinds the house rooms' loot hands out and the boxes take (not cash), less the left-out kinds (keys,
  maps, specimens, containers posing as items, personal papers, newspapers, bulk cartons, trash: EXCLUDE below). A
  group may also take kinds no house hands out (the kiln's charcoal).
- A group is, in this order: a family decided by hand (FAMILIES: the four book families), a narrow tag the recipes use
  for "any of these" (base:charcoal; TAG_MAX kinds at most, of one display category, not a BROAD_TAGS property), the
  variants (union-find: the Korean name before ' [' is the same, spaces and stray brackets aside; or the English name
  is the same, of one display category, the Korean names being near: the words of one inside the other), and a few
  groups by hand (MANUAL: one appliance of several brands). Everything else is a group of its own. Groups the list
  would show under the same Korean name are then one group, so a week never shows a name twice.
  The ids of the name groups ('n:...') continue the previous table (this file, as the last run wrote it): a group
  keeps the id of the old group most of its kinds came from, and an old id that goes away is kept in the row that
  took over (`was`), so a saved list is moved to the new group (Requests.keyOf).
- How easy a group is: the loot score (how many of its members the whole map's containers hand out, weighted by how
  many rooms of each kind the maps have and how likely each container picks each list), over the median of all the
  candidate groups. Another way to get any member raises the score to a floor: a recipe of easy inputs (nature, loot
  at or above the median kind, farm crops, easy foraging, or the output of such a recipe) with skill 3 or less and
  no recipe to learn, a farm crop, or wild foraging of tier chance 10 or more to common (1); a recipe of skill 6 or
  less from obtainable inputs, rarer wild foraging, hunting, butchering, fishing, trapping and vehicle parts to
  normal (0.3). Work stations (a kiln, a forge) are not counted against a recipe. The bands are those of
  Requests.lua: 1 and more common, 0.3 to 1 normal, below rare.
"""
import glob
import json
import os
import re
import struct
import sys
import zlib
from collections import Counter, defaultdict

GAME = r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid'
MEDIA = os.path.join(GAME, 'media')
HERE = os.path.dirname(os.path.abspath(__file__))
MOD_LUA = os.path.join(HERE, '..', 'OperationAcorn', '42', 'media', 'lua')
OUT = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'RequestGroups.lua')
CATEGORIES = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'Categories.lua')
REQUESTS = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'Requests.lua')
VALUE = os.path.join(MOD_LUA, 'shared', 'OperationAcorn', 'Economy', 'Value.lua')

COMMON, NORMAL = 1.0, 0.3          # Requests.COMMON_FROM, Requests.NORMAL_FROM

# The book families (decided with the user): DisplayCategory or tags -> family id. A family takes every member the
# rule names, whatever its other tags; HollowBook is a container and newspapers are left out (EXCLUDE). The books are
# the hardcovers, the softcovers and the leather-bound (base:fancybook) ones.
FAMILIES = [
    ('skillbook', lambda it: it['dc'] == 'SkillBook'),
    ('recipemag', lambda it: it['dc'] == 'RecipeResource'),
    ('books', lambda it: it['dc'] == 'Literature' and ({'base:hardcover', 'base:softcover', 'base:fancybook'}
                                                        & it['tags'])),
    ('reading', lambda it: it['dc'] == 'Literature' and ({'base:magazine', 'base:picturebook'} & it['tags'])),
]
FAMILY_NAMES = {
    'skillbook': 'IGUI_OA_ReqGroup_skillbook', 'recipemag': 'IGUI_OA_ReqGroup_recipemag',
    'books': 'IGUI_OA_ReqGroup_books', 'reading': 'IGUI_OA_ReqGroup_reading',
}
# A family's picture (the member whose icon stands for it).
FAMILY_ICONS = {'skillbook': 'Base.BookCarpentry1', 'recipemag': 'Base.CookingMag1', 'books': 'Base.Book',
                'reading': 'Base.Magazine'}

# A tag groups only when it is narrow: at most this many taken kinds, all of one display category.
TAG_MAX = 12
# Tags that name a property, not a thing (a recipe may still ask for them): never a group.
BROAD_TAGS = {
    'base:isfirefuel', 'base:hasmetal', 'base:ignorezombiedensity', 'base:morewhennozombies', 'base:ismemento',
    'base:fitskeyring', 'base:smeltableironsmall', 'base:smeltableironmedium', 'base:smeltableironlarge',
    'base:smeltablesteelsmall', 'base:smeltablesteelmedium', 'base:smeltablesteellarge',
    'base:makewoodcharcoalsmall', 'base:makewoodcharcoalmedium', 'base:makewoodcharcoallarge',
}

# Groups made by hand for what the rules above leave apart: id -> (name key, members). Few on purpose: the same
# appliance under different brands (the names differ by the brand, so neither the tags nor the names join them).
MANUAL = {
    'tv': ('IGUI_OA_ReqGroup_tv', ['Base.TvBlack', 'Base.TvWideScreen', 'Base.TvAntique']),
    'radio': ('IGUI_OA_ReqGroup_radio', ['Base.RadioBlack', 'Base.RadioRed', 'Base.RadioMakeShift', 'Base.Radio']),
    'walkietalkie': ('IGUI_OA_ReqGroup_walkietalkie', ['Base.WalkieTalkie1', 'Base.WalkieTalkie2',
                     'Base.WalkieTalkie3', 'Base.WalkieTalkie4', 'Base.WalkieTalkie5', 'Base.WalkieTalkieMakeShift']),
    'hamradio': ('IGUI_OA_ReqGroup_hamradio', ['Base.HamRadio1', 'Base.HamRadio2', 'Base.HamRadioMakeShift']),
}
# The groups that show a text of their own: the families and the groups by hand.
NAMED = dict(FAMILY_NAMES, **{gid: key for gid, (key, _) in MANUAL.items()})

# Left out, by rule, in this order. Each rule: (name, test(item) -> bool). The report lists every kind by rule.
def _id(it):
    return it['name']


EXCLUDE = [
    # Keys and key rings: a key opens one door of one house (padlocks are hardware and stay).
    ('key', lambda it: (it['itype'] == 'base:key' and 'base:lock' not in it['tags'])
     or re.match(r'^(Key\d|CarKey|KeyRing)', _id(it))),
    # Maps: one of each place.
    ('map', lambda it: it['itype'] == 'base:map' or it['dc'] == 'Cartography'),
    # Specimen jars: a few in labs and schools.
    ('specimen', lambda it: _id(it).startswith('Specimen')),
    # A container that does not look like one: a hollow book (a book outside, a stash inside).
    ('container posing as an item', lambda it: it['itype'] == 'base:container' and (
        it['dc'] == 'Literature' or 'base:hollowbook' in it['tags'])),
    # Someone's own papers and pictures: IDs, dog tags, tickets, diaries, photos, doodles, fliers.
    ('personal', lambda it: {'base:applyownername', 'base:picture'} & it['tags'] or _id(it).endswith('Pic')),
    # Newspapers, and paper the game itself calls uninteresting: mail, receipts, paperwork.
    ('newspaper or uninteresting paper', lambda it: {'base:uninteresting', 'base:newspaper'} & it['tags']),
    # A carton of boxes (nails, screws, cigarettes): a store's stock, not a thing a house has.
    ('bulk carton', lambda it: _id(it).endswith('Carton') and it['dc'] != 'Food'),
    # Trash: the junk the bins hand out, empties, wrappers and broken bits.
    ('trash', lambda it: it['trash']),
]

ROOMS_HOUSE = None   # read from Requests.lua (Requests.HOUSE_ROOMS)


# --- Lua literals --------------------------------------------------------------------------------------------------

TOKEN = re.compile(r'''
    (?P<ws>\s+) | (?P<comment>--\[\[.*?\]\]|--[^\n]*) |
    (?P<str>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*') |
    (?P<num>-?\d+\.?\d*(?:[eE][-+]?\d+)?|-?\.\d+) |
    (?P<name>[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*) |
    (?P<op>[{}\[\]=,;])
''', re.X | re.S)


class Ref:
    """A name in a table (ClutterTables.BinJunk): resolved against what the files assigned."""
    def __init__(self, name):
        self.name = name


def tokens(text, at):
    pos = at
    n = len(text)
    while pos < n:
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError('cannot read Lua at %d: %r' % (pos, text[pos:pos + 40]))
        pos = m.end()
        kind = m.lastgroup
        if kind in ('ws', 'comment'):
            continue
        yield kind, m.group(kind), pos


def parse_table(text, at):
    """The table literal starting at text[at] == '{': (value, end)."""
    it = tokens(text, at)
    stack = []

    def value(tok):
        kind, v, _ = tok
        if kind == 'str':
            return bytes(v[1:-1], 'utf-8').decode('unicode_escape') if '\\' in v else v[1:-1]
        if kind == 'num':
            return float(v)
        if kind == 'name':
            if v == 'true':
                return True
            if v == 'false':
                return False
            if v == 'nil':
                return None
            return Ref(v)
        if v == '{':
            return table()
        raise ValueError('unexpected %r' % v)

    def table():
        arr, dic = [], {}
        while True:
            tok = next(it)
            kind, v, _ = tok
            if v == '}':
                return {'arr': arr, 'dic': dic}
            if v in (',', ';'):
                continue
            if v == '[':
                key = value(next(it))
                assert next(it)[1] == ']'
                assert next(it)[1] == '='
                dic[key] = value(next(it))
                continue
            if kind == 'name' and '.' not in v:
                nxt = next(it)
                if nxt[1] == '=':
                    dic[v] = value(next(it))
                    continue
                arr.append(value(tok))
                if nxt[1] == '}':
                    return {'arr': arr, 'dic': dic}
                continue
            arr.append(value(tok))

    first = next(it)
    assert first[1] == '{'
    result = table()
    return result


def lua_assignments(path, names):
    """The tables the file assigns to the given names (a regex of the left side): { left side: table }."""
    text = open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for m in re.finditer(r'^\s*(?:local\s+)?(%s)\s*=\s*\{' % names, text, re.M):
        out[m.group(1)] = parse_table(text, m.end() - 1)
    return out


def resolve(v, env, depth=0):
    if isinstance(v, Ref):
        return env.get(v.name)
    return v


# --- the game's data -----------------------------------------------------------------------------------------------

def read_items():
    items = {}
    for path in glob.glob(os.path.join(MEDIA, 'scripts', '**', '*.txt'), recursive=True):
        text = open(path, encoding='utf-8', errors='replace').read()
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        module = None
        for m in re.finditer(r'^\s*module\s+(\w+)|^\s*item\s+([\w.]+)\s*\{(.*?)\n\s*\}', text, re.M | re.S):
            if m.group(1):
                module = m.group(1)
                continue
            if not module:
                continue
            name, body = m.group(2), m.group(3)
            fields = {}
            for line in body.split('\n'):
                line = line.strip().rstrip(',')
                if '=' in line and not line.startswith('//'):
                    k, _, v = line.partition('=')
                    fields[k.strip().lower()] = v.strip()
            full = module + '.' + name
            tags = {t.strip().lower() for t in fields.get('tags', '').split(';') if t.strip()}
            items[full] = {
                'full': full, 'module': module, 'name': name, 'dc': fields.get('displaycategory', ''),
                'itype': fields.get('itemtype', '').lower(), 'weight': float(re.match(r'[-\d.]*', fields.get('weight', '1')).group(0) or 1),
                'tags': tags, 'icon': fields.get('icon'), 'trash': False, 'oneoff': False,
                'obsolete': fields.get('obsolete', '').lower() == 'true',
            }
    return items


def read_names(lang):
    path = os.path.join(MEDIA, 'lua', 'shared', 'Translate', lang, 'ItemName.json')
    return json.load(open(path, encoding='utf-8'))


def room_counts():
    """How many rooms of each name the maps have (as base-utilities' room_names.py reads the headers)."""
    result = Counter()
    for path in glob.glob(os.path.join(MEDIA, 'maps', '*', '*.lotheader')):
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
        integer(), integer()
        if version == 0:
            integer()
        else:
            integer(), integer()
        for _ in range(integer()):
            name = line()
            integer()
            rects = integer()
            at += 16 * rects
            objects = integer()
            at += 12 * objects
            result[name] += 1
    return result


def read_loot():
    """distribution table, procedural lists, the side tables (ClutterTables.*, BagsAndContainers.*)."""
    folder = os.path.join(MEDIA, 'lua', 'server', 'Items')
    env = {}
    for path in glob.glob(os.path.join(folder, 'Distribution_*.lua')):
        env.update(lua_assignments(path, r'(?:ClutterTables|BagsAndContainers)\.\w+'))
    dist = lua_assignments(os.path.join(folder, 'Distributions.lua'), 'distributionTable')['distributionTable']
    proc = lua_assignments(os.path.join(folder, 'ProceduralDistributions.lua'), r'ProceduralDistributions\.list')
    proc = proc['ProceduralDistributions.list']
    return dist, proc, env


def list_items(lst, env):
    """[(name, weight)] of a loot list table ({ rolls, items, junk }), its junk apart: (rolls, items, junk table)."""
    lst = resolve(lst, env)
    if not isinstance(lst, dict):
        return 0, [], None
    d = lst['dic']
    rolls = d.get('rolls', 1) or 1
    items = resolve(d.get('items'), env)
    pairs = []
    if isinstance(items, dict):
        arr = items['arr']
        for i in range(0, len(arr) - 1, 2):
            if isinstance(arr[i], str) and isinstance(arr[i + 1], float):
                pairs.append((arr[i], arr[i + 1]))
    return rolls, pairs, resolve(d.get('junk'), env)


def expected(lst, env, into, mult):
    """Adds the expected count of each item one fill of the list gives (rolls x chance, a chance capped at 1)."""
    rolls, pairs, junk = list_items(lst, env)
    for name, w in pairs:
        into[name] += mult * rolls * min(1.0, w / 100.0)
    if junk is not None:
        expected(junk, env, into, mult)


def sum_weights(lst, env, into, mult):
    """The old score: the plain sum of the weights, junk included (Requests.weights)."""
    rolls, pairs, junk = list_items(lst, env)
    for name, w in pairs:
        into[name] += w * mult
    if junk is not None:
        sum_weights(junk, env, into, mult)


def proc_shares(container):
    """How likely a procedural container takes each of its lists: weightChance (1 when not set) over the sum. A list
    the game forces for some tiles, rooms, zones or items gets the container's average share (no map data says
    where those are)."""
    plist = container['dic'].get('procList')
    if not isinstance(plist, dict):
        return []
    entries = [e['dic'] for e in plist['arr'] if isinstance(e, dict)]
    plain = [e for e in entries if not any(k in e for k in ('forceForTiles', 'forceForRooms', 'forceForZones', 'forceForItems'))]
    weights = [max(1.0, e.get('weightChance', 0) or 0) for e in plain]
    total = sum(weights) or 1.0
    out = [(e.get('name'), w / total) for e, w in zip(plain, weights)]
    forced = [e for e in entries if e not in plain]
    if forced:
        avg = 1.0 / max(1, len(entries))
        out += [(e.get('name'), avg) for e in forced]
    return out


SPECIAL_ROOM = re.compile(r'^(all|Bag_|Outfit_|AmmoStrap_)')


def loot_scores(dist, proc, env, rooms):
    """Expected count of each item name over the whole map: per room name (times how many the maps have), per
    container (counted once a room), per list (its share). Then what bags and item containers found that way hold."""
    found = Counter()
    total_rooms = sum(rooms.values())
    containers_seen = Counter()
    for room, conts in dist['dic'].items():
        if not isinstance(conts, dict) or SPECIAL_ROOM.match(room):
            continue
        n = rooms.get(room, 0)
        if n == 0:
            continue
        for cname, cont in conts['dic'].items():
            cont = resolve(cont, env)
            if not isinstance(cont, dict) or cname in ('isShop', 'dontSpawnAmmo'):
                continue
            containers_seen[cname] += n
            fill_container(cont, proc, env, found, n)
    # 'all': the containers of any room that has no list of its own for them. Weighed as a twentieth of the rooms
    # (no map data says how many such containers there are); the dead's pockets once per room.
    alld = dist['dic'].get('all')
    if isinstance(alld, dict):
        for cname, cont in alld['dic'].items():
            cont = resolve(cont, env)
            if not isinstance(cont, dict):
                continue
            mult = total_rooms if cname in ('inventorymale', 'inventoryfemale') else total_rooms / 20.0
            fill_container(cont, proc, env, found, mult)
    # What bags and boxes found so far hold: one level down.
    inner = Counter()
    for key, cont in dist['dic'].items():
        cont = resolve(cont, env)
        if not isinstance(cont, dict) or key in rooms or key == 'all' or key.startswith('Outfit_'):
            continue
        holder = found.get(key, 0)
        if holder <= 0:
            continue
        fill_container(cont, proc, env, inner, holder)
    found.update(inner)
    return found


def fill_container(cont, proc, env, into, mult):
    d = cont['dic']
    if d.get('procedural'):
        for name, share in proc_shares(cont):
            lst = proc['dic'].get(name)
            if lst is not None:
                expected(lst, env, into, mult * share)
    else:
        expected(cont, env, into, mult)


def old_weights(dist, proc, env):
    """Requests.weights as the mod does it today: the house rooms, the weights summed, a list once per container."""
    sums = Counter()
    refs = Counter()
    for room in ROOMS_HOUSE:
        conts = dist['dic'].get(room)
        if not isinstance(conts, dict):
            continue
        for cont in conts['dic'].values():
            cont = resolve(cont, env)
            if not isinstance(cont, dict):
                continue
            sum_weights(cont, env, sums, 1)
            plist = cont['dic'].get('procList')
            if isinstance(plist, dict):
                for e in plist['arr']:
                    if isinstance(e, dict) and e['dic'].get('name'):
                        refs[e['dic']['name']] += 1
    for name, count in refs.items():
        lst = proc['dic'].get(name)
        if lst is not None:
            sum_weights(lst, env, sums, count)
    return sums


def house_names(dist, proc, env):
    """Every item name the house rooms' loot can hand out (the candidates' pool)."""
    out = Counter()
    for room in ROOMS_HOUSE:
        conts = dist['dic'].get(room)
        if not isinstance(conts, dict):
            continue
        for cont in conts['dic'].values():
            cont = resolve(cont, env)
            if isinstance(cont, dict):
                fill_container(cont, proc, env, out, 1)
                sum_weights(cont, env, out, 0)
    return out


# --- other ways to come by a thing ---------------------------------------------------------------------------------

def read_recipes(items):
    """craftRecipe blocks: { name, inputs: [ [types...] consumed ], tools: [ [types...] ], outputs: [types], skill,
    learn }. Tag inputs are expanded to the items with the tag."""
    by_tag = defaultdict(list)
    for full, it in items.items():
        for t in it['tags']:
            by_tag[t].append(full)
    recipes = []
    for path in glob.glob(os.path.join(MEDIA, 'scripts', '**', '*.txt'), recursive=True):
        text = open(path, encoding='utf-8', errors='replace').read()
        if 'craftRecipe' not in text:
            continue
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        for m in re.finditer(r'craftRecipe\s+(\w+)\s*\{', text):
            depth, at = 1, m.end()
            while depth and at < len(text):
                c = text[at]
                depth += c == '{'
                depth -= c == '}'
                at += 1
            body = text[m.end():at - 1]
            rec = {'name': m.group(1), 'inputs': [], 'tools': [], 'outputs': [], 'skill': 0, 'learn': False,
                   'tags_used': set()}
            sk = re.search(r'SkillRequired\s*=\s*([^,\n]+)', body)
            if sk:
                levels = [int(x) for x in re.findall(r':(\d+)', sk.group(1))]
                rec['skill'] = max(levels) if levels else 0
            rec['learn'] = bool(re.search(r'NeedToBeLearn\s*=\s*true', body, re.I))
            part = re.search(r'\binputs\s*\{(.*?)\n\s*\}', body, re.S)
            outp = re.search(r'\boutputs\s*\{(.*?)\n\s*\}', body, re.S)
            for line in (part.group(1).split('\n') if part else []):
                line = line.strip()
                if not line.startswith('item '):
                    continue
                types = []
                lst = re.search(r'\[([^\]]*)\]', line)
                tg = re.search(r'tags\[([^\]]*)\]', line)
                if tg:
                    for t in tg.group(1).split(';'):
                        t = t.strip().lower()
                        rec['tags_used'].add(t)
                        types += by_tag.get(t, [])
                elif lst:
                    for t in lst.group(1).split(';'):
                        t = re.sub(r'^\d+:', '', t.strip())
                        if t == '*':
                            continue
                        types.append(t if '.' in t else 'Base.' + t)
                keep = 'mode:keep' in line or 'flags[Prop1' in line or 'flags[Prop2' in line or 'mode:use' in line
                (rec['tools'] if keep else rec['inputs']).append(types)
            for line in (outp.group(1).split('\n') if outp else []):
                om = re.match(r'\s*item\s+\d+\s+([\w.]+)', line)
                if om:
                    t = om.group(1)
                    rec['outputs'].append(t if '.' in t else 'Base.' + t)
            recipes.append(rec)
    return recipes


def forage_items():
    """Item types the foraging categories of the wild give, with the tier's chance: { type: best chance }. The town
    scavenging categories (junk, trash, clothing, ammo, medical...) are left out: the loot score counts those things."""
    wild = {'Berries', 'Bones', 'CraftingMaterials', 'Firewood', 'Fruits', 'Herbs', 'Insects', 'MedicinalPlants',
            'Mushrooms', 'Stones', 'Vegetables', 'WildPlants', 'Animals', 'DeadAnimals'}
    out = {}
    for path in glob.glob(os.path.join(MEDIA, 'lua', 'shared', 'Foraging', 'Categories', '*.lua')):
        cat = os.path.splitext(os.path.basename(path))[0]
        if cat not in wild:
            continue
        chance = 10.0
        for line in open(path, encoding='utf-8', errors='replace'):
            cm = re.search(r'\bchance\s*=\s*([\d.]+)', line)
            if cm:
                chance = float(cm.group(1))
            for t in re.findall(r'"(Base\.\w+)"', line):
                out[t] = max(out.get(t, 0), chance)
    return out


def farm_items():
    out = set()
    for path in glob.glob(os.path.join(MEDIA, 'lua', 'server', 'Farming', 'farming_vegetableconf*.lua')):
        text = open(path, encoding='utf-8', errors='replace').read()
        for t in re.findall(r'(?:vegetableName|seedName)\s*=\s*"([\w.]+)"', text):
            out.add(t)
    return out


def animal_items():
    """What hunting, butchering, keeping animals, fishing and trapping give."""
    out = set()
    pats = [os.path.join(MEDIA, 'lua', 'shared', 'Definitions', 'animal', '*.lua'),
            os.path.join(MEDIA, 'lua', '*', 'Fishing', '**', '*.lua'),
            os.path.join(MEDIA, 'lua', '*', 'Trapping', '**', '*.lua'),
            os.path.join(MEDIA, 'lua', '*', 'Definitions', 'Fishing*.lua')]
    for pat in pats:
        for path in glob.glob(pat, recursive=True):
            text = open(path, encoding='utf-8', errors='replace').read()
            out.update(re.findall(r'"(Base\.\w+)"', text))
    return out


def vehicle_parts():
    """The parts a vehicle is taken apart into: the part's itemType, with the car type's number the game adds (OldTire
    -> OldTire1, OldTire2, OldTire3)."""
    out = set()
    for path in glob.glob(os.path.join(MEDIA, 'scripts', '**', 'vehicles', '**', '*.txt'), recursive=True):
        text = open(path, encoding='utf-8', errors='replace').read()
        for v in re.findall(r'^\s*itemType\s*=\s*([\w.;]+)', text, re.M):
            for t in v.split(';'):
                t = t if '.' in t else 'Base.' + t
                out.add(t)
                out.update(t + str(k) for k in (1, 2, 3))
    return out


# --- the mod's rules -----------------------------------------------------------------------------------------------

def read_categories():
    text = open(CATEGORIES, encoding='utf-8').read()
    by_display = {}
    for m in re.finditer(r'fill\(D,\s*"(\w)",((?:\s*\.\.\s*|\s*)"[^"]*"(?:\s*\.\.\s*"[^"]*")*)\)', text):
        names = ''.join(re.findall(r'"([^"]*)"', m.group(2)))
        for n in names.split(','):
            by_display[n] = m.group(1)
    reject_display = dict(re.findall(r'(\w+)\s*=\s*"(\w+)"', re.search(r'REJECT_DISPLAY = \{(.*?)\n\}', text, re.S).group(1)))
    reject_id = dict(re.findall(r'(\w+)\s*=\s*"(\w+)"', re.search(r'REJECT_ID = \{(.*?)\n\}', text, re.S).group(1)))
    prefixes = re.findall(r'\{\s*"(\w+)",\s*"(\w+)"\s*\}', re.search(r'REJECT_PREFIX = \{(.*?)\n\}', text, re.S).group(1))
    units = dict((k, float(v)) for k, v in re.findall(r'(\w) = (\d+)', re.search(r'UNIT = \{(.*?)\}', text, re.S).group(1)))
    return by_display, reject_display, reject_id, prefixes, units


def read_cash():
    """Value.CASH: cash has its own value and is never a request."""
    text = open(VALUE, encoding='utf-8').read()
    return set(re.findall(r'\["([\w.]+)"\]', re.search(r'Value\.CASH = \{(.*?)\}', text).group(1)))


def read_house_rooms():
    text = open(REQUESTS, encoding='utf-8').read()
    body = re.search(r'HOUSE_ROOMS = \{(.*?)\}', text, re.S).group(1)
    return re.findall(r'"(\w+)"', body)


def make_category(by_display, reject_display, reject_id, prefixes):
    def category(it):
        """Categories.of for a script item (no cash, no own goods: vanilla only)."""
        if it['module'] == 'Base':
            if it['name'] in reject_id:
                return None
            for p, _ in prefixes:
                if it['name'].startswith(p):
                    return None
        if it['itype'] == 'base:moveable':
            return None
        dc = it['dc']
        if dc:
            if dc in reject_display:
                return None
            return by_display.get(dc, 'E')
        return 'E'
    return category


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return 1.0
    m = s[(n - 1) // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2
    return m if m > 0 else 1.0


def band(score):
    return 'common' if score >= COMMON else ('normal' if score >= NORMAL else 'rare')


def clean(name):
    """A name less its stray brackets (a ']' with no '[' before it, a '[' never closed: vanilla's Korean names have a
    few, "끈 없는 브라]") and with single spaces. Requests.clean does the same at run time."""
    out = []
    opens = []
    for c in name:
        if c == '[':
            opens.append(len(out))
            out.append(c)
        elif c == ']':
            if opens:
                opens.pop()
                out.append(c)
        else:
            out.append(c)
    for at in reversed(opens):
        del out[at]
    return ' '.join(''.join(out).split())


def strip_variant(name):
    """The words before the trailing ' [...]' of a name, stray brackets gone (Requests.plain)."""
    return re.sub(r'\s*\[[^\]]*\]\s*$', '', clean(name)).strip()


def inside(small, big):
    """Whether the words of `small` are in `big` in the same order (a name inside a longer one)."""
    at = 0
    for w in small:
        while at < len(big) and big[at] != w:
            at += 1
        if at == len(big):
            return False
        at += 1
    return True


def display_name(names):
    """The name the list shows for a group, as Requests.nameOf makes it at run time. `names`: one per member kind
    (the game-language names, a kind each). In this order: the shortest of the members' names (its words before
    ' [', stray brackets gone) that all the other names have inside them in order ("끈 없는 브라" for "끈 없는 프릴
    브라"); else the words all the members' names start with (less a trailing ' -' or an open bracket); else the
    words they all end with (less a leading ' -'); else the first member's name without its ' [...]'."""
    plain = [strip_variant(n) for n in names]
    if len(names) > 1:
        split = [p.split(' ') for p in plain]
        fits = [i for i, w in enumerate(split) if w != [''] and all(inside(w, o) for o in split)]
        if fits:
            return plain[min(fits, key=lambda i: (len(split[i]), len(plain[i]), i))]
    words = [clean(n).split(' ') for n in names]
    common = []
    for col in zip(*words):
        if len(set(col)) != 1:
            break
        common.append(col[0])
    while common and re.match(r'^[-:(\[]|.*[\[(]', common[-1]):
        common.pop()
    if len(names) > 1 and common:
        return ' '.join(common)
    if len(names) > 1:
        tail = []
        for col in zip(*[p.split(' ')[::-1] for p in plain]):
            if len(set(col)) != 1:
                break
            tail.append(col[0])
        while tail and re.match(r'^[-:)\]]|.*[)\]]', tail[-1]):
            tail.pop()
        if tail:
            return ' '.join(tail[::-1])
    return plain[0]


def near(a, b):
    """Whether two Korean names are of one thing: the words of one are inside the other, in order, or they are the
    same less their spaces ("공구상자", "공구 상자"). An English name two kinds share joins them only when their Korean
    names are near (vanilla's English names have typos too: "Rice" for a mashed sugar beet)."""
    a, b = strip_variant(a), strip_variant(b)
    wa, wb = a.split(' '), b.split(' ')
    if inside(wa, wb) or inside(wb, wa):
        return True
    return ''.join(a.split()) == ''.join(b.split())


def read_previous():
    """The table as the last run wrote it (it is the repository's): [(id, [was ids], [item types])]. A save keeps a
    group's id, so a group that moves must keep the id of the group most of its kinds came from, and an id that goes
    away is remembered in the row that took over (`was`)."""
    try:
        text = open(OUT, encoding='utf-8').read()
    except OSError:
        return []
    rows = []
    for line in text.split(chr(10)):
        ident = re.match(r'\s*\{ id = "([^"]*)",', line)
        body = re.search(r' items = \{ (.*) \} \},?$', line)
        if ident and body:
            was = re.search(r' was = \{ (.*?) \}', line)
            rows.append((ident.group(1), re.findall(r'"([^"]+)"', was.group(1)) if was else [],
                         re.findall(r'"([^"]+)"', body.group(1))))
    return rows


def keep_ids(groups, previous, items):
    """Names the groups of names (the 'n:' ones) after the previous table where they continue it, and gives every
    group the old ids it replaces (`was`: ids a save may still hold, that no group has now)."""
    old_of = {}
    for oid, _, ms in previous:
        for t in ms:
            old_of[t] = oid
    old_ids = {oid for oid, _, _ in previous}
    old_size = {oid: len(ms) for oid, _, ms in previous}
    named = [g for g in groups.values() if g['how'] == 'name']
    claims = []
    for g in named:
        count = Counter(old_of[t] for t in g['items'] if old_of.get(t, '').startswith('n:'))
        for oid, n in count.items():
            claims.append((-n, oid != g['id'], -old_size[oid], oid, g['id']))
    taken, gave = {}, {}
    for _, _, _, oid, gid in sorted(claims):
        if oid not in taken and gid not in gave:
            taken[oid], gave[gid] = gid, oid
    final = {}
    for g in named:
        final[g['id']] = gave.get(g['id'])
    used = set(gave.values())
    for g in sorted(named, key=lambda g: g['id']):
        if final[g['id']]:
            continue
        gid = g['id']
        while gid in used or gid in old_ids or any(o.get('id') == gid for o in groups.values() if o is not g):
            gid += '_'
        final[g['id']] = gid
        used.add(gid)
    for g in named:
        g['id'] = final[g['id']]
    # `was`: every old id that no group has now goes to the group most of its kinds went to.
    where = {t: g for g in groups.values() for t in g['items']}
    ids = {g['id'] for g in groups.values()}
    for g in groups.values():
        g['was'] = set()
    for oid, was, ms in previous:
        count = Counter(id(where[t]) for t in ms if t in where)
        if not count:
            continue
        top = count.most_common(1)[0][0]
        target = next(g for g in groups.values() if id(g) == top)
        for old in [oid] + was:
            if old not in ids and old not in items:
                target['was'].add(old)


# --- the whole thing -----------------------------------------------------------------------------------------------

def main():
    global ROOMS_HOUSE
    report_dir = None
    if '--report' in sys.argv:
        report_dir = sys.argv[sys.argv.index('--report') + 1]
    ROOMS_HOUSE = read_house_rooms()
    items = read_items()
    names_en, names_ko = read_names('EN'), read_names('KO')
    by_display, reject_display, reject_id, prefixes, units = read_categories()
    category = make_category(by_display, reject_display, reject_id, prefixes)
    dist, proc, env = read_loot()
    rooms = room_counts()

    def full_of(name):
        return name if '.' in name else 'Base.' + name

    # Trash: the junk on the bins' and dumpsters' own lists, empties, wrappers and broken bits of junk.
    trash_names = set()
    alld = dist['dic'].get('all')
    for cname in ('bin', 'dumpster'):
        cont = alld['dic'].get(cname) if alld else None
        if isinstance(cont, dict):
            trash_names |= {n for n, _ in list_items(cont, env)[1]}   # the bin's own list, not its random junk
    for full, it in items.items():
        if it['name'] in trash_names and it['dc'] in ('Junk', ''):
            it['trash'] = True
        if re.search(r'(Empty$|_Broken$|^Broken|^Smashed|Wrapper|DryerLint)', it['name']) and it['dc'] in ('Junk', ''):
            it['trash'] = True

    # The candidates' pool: what the house rooms hand out and the boxes take.
    house = house_names(dist, proc, env)
    old = old_weights(dist, proc, env)

    cash = read_cash()

    def taken(full):
        it = items.get(full)
        return it is not None and not it['obsolete'] and full not in cash and category(it) is not None

    # Before: the mod's scan as it is (each type a candidate, scored by the plain sum over the median).
    before = {full_of(n): w for n, w in old.items() if taken(full_of(n))}
    med_before = median(before.values())
    bands_before = Counter(band(w / med_before) for w in before.values())

    # Loot over the whole map.
    loot = Counter()
    for n, v in loot_scores(dist, proc, env, rooms).items():
        loot[full_of(n)] += v

    # Left out, by rule.
    excluded = defaultdict(list)

    def exclusion(it):
        for rule, test in EXCLUDE:
            if test(it):
                return rule
        return None

    pool = sorted({full_of(n) for n in house if taken(full_of(n))})
    candidates = []
    for full in pool:
        rule = exclusion(items[full])
        if rule:
            excluded[rule].append(full)
        else:
            candidates.append(full)

    # Every taken, not left out item can be a member (a crafted twin of a looted thing: CharcoalCrafted).
    members_ok = {f for f, it in items.items() if taken(f) and not exclusion(it)}

    # --- groups ---
    group_of = {}
    groups = {}

    def add(gid, full, how):
        group_of[full] = gid
        g = groups.setdefault(gid, {'id': gid, 'how': how, 'items': []})
        g['items'].append(full)

    # 0. the families decided by hand.
    for full in sorted(members_ok):
        for fid, test in FAMILIES:
            if test(items[full]):
                add(fid, full, 'family')
                break
    # 1. narrow tags the recipes ask for.
    recipes = read_recipes(items)
    recipe_tags = set()
    for r in recipes:
        recipe_tags |= r['tags_used']
    tag_members = defaultdict(set)
    for full in members_ok:
        for t in items[full]['tags']:
            if t in recipe_tags and t not in BROAD_TAGS:
                tag_members[t].add(full)
    narrow = {}
    for t, ms in tag_members.items():
        dcs = {items[f]['dc'] for f in ms}
        if 2 <= len(ms) <= TAG_MAX and len(dcs) == 1 and any(f in candidates for f in ms):
            narrow[t] = ms
    for full in sorted(members_ok):
        if full in group_of:
            continue
        best = None
        for t in items[full]['tags']:
            if t in narrow:
                left = [f for f in narrow[t] if f not in group_of or group_of[f] == t]
                if len(left) >= 2 and (best is None or (len(narrow[t]), t) < (len(narrow[best]), best)):
                    best = t
        if best:
            for f in sorted(narrow[best]):
                if f not in group_of:
                    add(best, f, 'tag')
    # 2. variants: the same name before ' [' in Korean or in English (stray brackets gone), of one display category.
    #    Vanilla's Korean names have typos ("끈 없는 브라]") and say the same thing in different words ("끈 없는 프릴
    #    브라" for the English "Bra - Strapless"), so either language joins two kinds (union-find over both).
    loose = [f for f in sorted(members_ok) if f not in group_of and (names_ko.get(f) or names_en.get(f))]
    parent = {f: f for f in loose}

    def find(f):
        while parent[f] != f:
            parent[f] = parent[parent[f]]
            f = parent[f]
        return f

    seen_key = defaultdict(list)
    for f in loose:
        keys = []
        ko_prefix = ''.join(strip_variant(names_ko.get(f, '')).casefold().split())      # "공구상자" and "공구 상자"
        if ko_prefix:
            keys.append(('ko', ko_prefix))
        en_prefix = strip_variant(names_en.get(f, '')).casefold()
        if en_prefix:
            keys.append(('en', items[f]['dc'], en_prefix))
        for k in keys:
            for other in seen_key[k]:
                # An English match joins two kinds only when their Korean names are near each other too.
                if k[0] == 'ko' or not (names_ko.get(f) and names_ko.get(other)) or near(names_ko[f], names_ko[other]):
                    parent[find(f)] = find(other)
            seen_key[k].append(f)
    clusters = defaultdict(list)
    for f in loose:
        clusters[find(f)].append(f)
    for ms in sorted(clusters.values(), key=lambda m: m[0]):
        if len(ms) >= 2 and any(f in candidates for f in ms):
            # The id: the English words the members' names start with (a save keeps it), else the first member's.
            words = [clean(names_en.get(f, '')).split() for f in ms]
            common = []
            for col in zip(*words):
                if len(set(col)) != 1:
                    break
                common.append(col[0])
            stem = re.sub(r'\W+', '_', ' '.join(common)).strip('_') or items[ms[0]]['name']
            gid = 'n:' + stem
            while gid in groups:
                gid = gid + '_'
            for f in ms:
                add(gid, f, 'name')
    # 3. by hand.
    for gid, (key, ms) in MANUAL.items():
        for f in ms:
            if f in members_ok and f not in group_of:
                add(gid, f, 'manual')
    # The rest: on their own.
    for full in candidates:
        if full not in group_of:
            add(full, full, 'single')

    # Only groups with a candidate member are on the list.
    cand_set = set(candidates)
    groups = {gid: g for gid, g in groups.items() if any(f in cand_set for f in g['items'])}
    # Groups the list would show under the same Korean name are one group (a week never shows a name twice).
    rank = {'family': 0, 'tag': 1, 'manual': 2, 'name': 3, 'single': 4}
    shown = {}
    for gid in sorted(groups, key=lambda g: (rank[groups[g]['how']], -len(groups[g]['items']), g)):
        g = groups[gid]
        if gid in NAMED:
            continue
        label = display_name([names_ko.get(f) or names_en.get(f) or f for f in g['items']])
        if label in shown:
            into = groups[shown[label]]
            into['items'] += g['items']
            into['merged'] = into.get('merged', []) + [gid]
            del groups[gid]
        else:
            shown[label] = gid

    # --- how easy ---
    forage = forage_items()
    farm = farm_items()
    animal = animal_items()
    vehicle = vehicle_parts()
    nature = {'Base.' + n for n, why in reject_id.items() if why == 'Nature'} | {'Base.Log', 'Base.LargeBranch',
              'Base.TreeBranch2', 'Base.Twigs', 'Base.Stone', 'Base.SharpedStone', 'Base.FlatStone', 'Base.Plank',
              'Base.Sapling', 'Base.Rock'}
    # Water, fluids and the like are no item: a recipe that asks for a fluid is judged by its items.
    med_loot_items = median([loot[f] for f in members_ok if loot[f] > 0])
    easy = set(nature)
    easy |= {f for f in items if loot[f] >= med_loot_items}           # loot at or above the median kind
    easy |= farm
    easy |= {f for f, c in forage.items() if c >= 10}
    moderate = set(easy) | {f for f in items if loot[f] > 0} | set(forage) | animal | vehicle
    crafted_easy, crafted_moderate = {}, {}
    changed = True
    while changed:
        changed = False
        for r in recipes:
            if not r['outputs']:
                continue
            ins_easy = all(any(t in easy for t in alts) for alts in r['inputs'] if alts)
            tools_ok = all(any(t in moderate for t in alts) for alts in r['tools'] if alts)
            ins_mod = all(any(t in moderate for t in alts) for alts in r['inputs'] if alts)
            if ins_easy and tools_ok and r['skill'] <= 3 and not r['learn']:
                for o in r['outputs']:
                    if o not in easy:
                        easy.add(o)
                        crafted_easy[o] = r['name']
                        changed = True
            if ins_mod and tools_ok and r['skill'] <= 6:
                for o in r['outputs']:
                    if o not in moderate:
                        moderate.add(o)
                        crafted_moderate[o] = r['name']
                        changed = True

    def paths(full):
        p = []
        if loot[full] > 0:
            p.append('loot')
        if full in crafted_easy:
            p.append('craft-easy:' + crafted_easy[full])
        elif full in crafted_moderate:
            p.append('craft:' + crafted_moderate[full])
        if full in farm:
            p.append('farm')
        if full in forage:
            p.append('forage%d' % forage[full])
        if full in animal:
            p.append('animal')
        if full in vehicle:
            p.append('vehicle')
        return p

    def floor_of(full):
        if full in farm or (full in forage and forage[full] >= 10) or full in crafted_easy:
            return COMMON
        if full in forage or full in animal or full in vehicle or full in crafted_moderate:
            return NORMAL
        return 0.0

    for g in groups.values():
        g['loot'] = sum(loot[f] for f in g['items'])
    med_groups = median([g['loot'] for g in groups.values()])
    for g in groups.values():
        g['lootScore'] = g['loot'] / med_groups
        g['floor'] = max(floor_of(f) for f in g['items'])
        g['score'] = round(max(g['lootScore'], g['floor']), 3)
        g['items'].sort(key=lambda f: (-loot[f], f))
        heavy = max(g['items'], key=lambda f: items[f]['weight'] * units.get(category(items[f]) or 'E', 0))
        g['wt'] = items[heavy]['weight']
        g['dc'] = items[heavy]['dc']
        if g['id'] in FAMILY_ICONS and FAMILY_ICONS[g['id']] in g['items']:
            g['icon'] = FAMILY_ICONS[g['id']]
        else:
            g['icon'] = g['items'][0]

    bands_after = Counter(band(g['score']) for g in groups.values())

    keep_ids(groups, read_previous(), items)
    write_lua(groups)
    if report_dir:
        write_report(report_dir, groups, excluded, before, med_before, bands_before, bands_after, items, names_ko,
                     names_en, loot, paths, med_groups, candidates)
    print('candidates before: %d types (%s)' % (len(before), dict(bands_before)))
    print('groups after: %d (%s), from %d kinds' % (len(groups), dict(bands_after), len(candidates)))
    print('left out:', {k: len(v) for k, v in excluded.items()})
    return 0


def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def write_lua(groups):
    rows = sorted(groups.values(), key=lambda g: g['id'])
    body = []
    for g in rows:
        parts = ['id = ' + lua_str(g['id']), 'score = %g' % g['score'], 'wt = %g' % g['wt'], 'dc = ' + lua_str(g['dc'])]
        if g['id'] in NAMED:
            parts.append('name = ' + lua_str(NAMED[g['id']]))
        if g['was']:
            parts.append('was = { %s }' % ', '.join(lua_str(w) for w in sorted(g['was'])))
        if g['icon'] != g['items'][0]:
            parts.append('icon = ' + lua_str(g['icon']))
        items = ', '.join(lua_str(f) for f in g['items'])
        body.append('    { %s, items = { %s } },' % (', '.join(parts), items))
    # The stamp tells the world save which table it was made from (Requests.data makes the saved one again when it differs).
    stamp = '%08x' % zlib.crc32('\n'.join(body).encode('utf-8'))
    out = [
        "-- The request groups (NUMBERS 2): made by tools/request_groups.py from the game's files. Do not edit by hand:",
        '-- change the tool and run it again. A row: { id, score, wt, dc, items = { fullType ... }, name, was, icon }. id is',
        "-- the group's key in a save (a member's fullType for a group of one), score how easy it is to come by (1 and",
        '-- more common, 0.3 to 1 normal, below rare), wt and dc the weight and display category of its dearest member',
        "-- (the request price never pays less than that member's value), items the kinds it takes, the most found first;",
        '-- name (a translation key) only for the families named by hand, was the ids the group had before a save may',
        '-- still hold (a group that was joined to this one), icon only when it is not the first item.',
        'require "OperationAcorn/Core"',
        '',
        'OperationAcorn.RequestGroupsStamp = "%s"' % stamp,
        'OperationAcorn.RequestGroups = {',
    ] + body + ['}']
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')


def write_report(folder, groups, excluded, before, med_before, bands_before, bands_after, items, names_ko, names_en,
                 loot, paths, med_groups, candidates):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, 'request-groups.txt')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('before: %d types %s (median %.3f)\n' % (len(before), dict(bands_before), med_before))
        f.write('after: %d groups %s from %d kinds (median loot %.4f)\n\n' % (len(groups), dict(bands_after),
                len(candidates), med_groups))
        for rule, ms in excluded.items():
            f.write('LEFT OUT (%s): %d\n' % (rule, len(ms)))
            for m in ms:
                f.write('    %s  %s\n' % (m, names_ko.get(m, '')))
        f.write('\nGROUPS (more than one kind)\n')
        for g in sorted(groups.values(), key=lambda g: (-len(g['items']), g['id'])):
            if len(g['items']) < 2:
                continue
            f.write('%s [%s] %s score %.3f (loot %.3f) %s\n' % (g['id'], g['how'], band(g['score']), g['score'],
                    g['lootScore'], names_ko.get(g['items'][0], '')))
            for m in g['items']:
                f.write('    %s %s  %s  %s\n' % (m, names_ko.get(m, ''), items[m]['dc'], ','.join(paths(m))))
        f.write('\nALL GROUPS BY SCORE\n')
        for g in sorted(groups.values(), key=lambda g: (-g['score'], g['id'])):
            old = max((before.get(m, 0) / med_before for m in g['items']), default=0)
            f.write('%-8s %7.3f old %7.3f  %-40s %s  %s\n' % (band(g['score']), g['score'], old, g['id'],
                    names_ko.get(g['items'][0], ''), ','.join(sorted({p.split(':')[0] for m in g['items'] for p in paths(m)}))))
    print('report:', path)


if __name__ == '__main__':
    sys.exit(main())
