"""Draws Operation Acorn's own tiles and writes them as its two tile sheets, with the .tiles definitions, the texture
packs, and the previews. Taken from Building Utilities' tools/tile_art.py: the objects are a few solids in a tile's space,
projected the way the game draws a square, shaded by a light from above and the viewer's left, drawn four times larger
with a depth buffer and scaled down (see tile_engine.py). The big machines are drawn whole and split into the tiles of
their footprint (tile_big1/2/3.py).

The sheets (8 tiles a row; the code names a tile by its place: see Sprites.lua):

    oa_trade_01     the communication terminal (off, on; S E N W each), the delivery box, the supply crate, the
                    parachute crate, the scorched ground, the meteor rocks, the drop-site stake (16 tiles)
    oa_machines_01  the shred bench, bulk shredder, cutter, wood saw, research storage (2x1), the propane and oil
                    refiners (2x2), the big rain storage (2x2, four water levels: full 128-131, the lure 132-133, then empty,
                    a quarter, a half at 134-145), the lure (1x1): 146 tiles. A machine takes
                    states x facings x tiles places, in this order: state (stopped, running), facing (S E N W), then the
                    tiles of that facing's footprint row by row (y outer, x inner). Its base place and footprint are in KINDS.

Saves name the tiles by their place in the sheet: a new tile goes in a free place or a new row, never in a used one,
and the sheet keeps its eight columns.

    python tools/tile_art.py            writes OperationAcorn/42/media/oa_trade.tiles, oa_machines.tiles and
                                        texturepacks/OperationAcornTrade.pack, OperationAcornMachines.pack
    python tools/tile_art.py --preview  also writes tools/tile_art_preview_trade.png, ..._machines.png (every machine
                                        assembled as it stands in the world, each look and facing) and
                                        ..._machines_tiles.png (the loose tiles on a floor, eight to a row)
    python tools/tile_art.py --only trade|machines   one sheet only

The items' icons are drawn by tools/icon_art.py, the tree icons by tools/node_icons.py, the backpack by
tools/backpack_mesh.py.

Needs Pillow and numpy (python -m pip install --user pillow numpy).
"""
import io
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

import tile_engine as E  # noqa: E402
import tile_objects as O  # noqa: E402
import tile_trade as T  # noqa: E402
import tile_machines2 as M2  # noqa: E402
import tile_big1 as B1  # noqa: E402
import tile_big2 as B2  # noqa: E402
import tile_big3 as B3  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'OperationAcorn', '42', 'media')
COLS = 8
W, H = E.W, E.H

# Facings in the order of the sheet (south, east, north, west) and the quarter turns that draw them.
FACINGS = (('S', 0), ('E', 3), ('N', 2), ('W', 1))

# The tile properties each kind of object gets (see ARCHITECTURE.md 'tile properties'). Vanilla meanings:
#   BlocksPlacement  nothing else can be placed on the square;  solidtrans  blocks walking, not sight;
#   IsLow            a low object (seen over, fenced hip height);  container / ContainerCapacity  a container created
#   with the object;  IsWaterCollector  the rain collector flag;  Facing  where its front looks.
SOLID = {'BlocksPlacement': '', 'solidtrans': ''}


def props(name, **more):
    out = {'CustomName': name}
    out.update(more)
    return out


TERMINAL = props('Communication Terminal', **SOLID)
DELIVERY = props('Delivery Box', IsLow='', container='crate', ContainerCapacity='50', **SOLID)
SUPPLY = props('Supply Crate', IsLow='', container='militarycrate', ContainerCapacity='100', **SOLID)
PARACHUTE = props('Parachute Crate', **SOLID)
DECAL = {}
ROCKS = props('Meteorite', IsLow='', BlocksPlacement='')
STAKE = props('Site Stake', IsLow='')
LURE = props('Lure', IsLow='', BlocksPlacement='')


def facings2(draw, base, look):
    """Four tiles (S, E, N, W) of one object: draw(turns, look) -> image."""
    return [(lambda t=t: draw(t, look), dict(base, Facing=f)) for f, t in FACINGS]


TRADE = (
    # 0-3, 4-7: the terminal, off and on
    facings2(O.terminal, TERMINAL, False) + facings2(O.terminal, TERMINAL, True)
    # 8, 9: the delivery box, open and sealed; 10, 11: the supply crate, sealed and opened
    + [(lambda: T.delivery_box(False), DELIVERY), (lambda: T.delivery_box(True), DELIVERY),
       (lambda: T.supply_crate(False), SUPPLY), (lambda: T.supply_crate(True), SUPPLY)]
    # 12: the crate on its parachute; 13: the scorched ground; 14: the meteor rocks; 15: the stake
    + [(T.parachute_crate, PARACHUTE), (T.scorched_ground, DECAL), (T.meteor_rocks, ROCKS), (T.site_stake, STAKE)]
)

# The big machines. foot = (w along x, h along y) facing south; the east and west facings swap them. states: 1, or 2
# (stopped, running). facings: 4 (S E N W), or 1 for the rain storage (it looks the same from every side).
# props go on every tile of the machine; anchor_props on the anchor tile only (the footprint's min-x, min-y square,
# grid position 0,0), the way vanilla puts a container on one square of a piece of multi-tile furniture.
KINDS = (
    dict(key='shredBench', name='Shred Bench', foot=(2, 1), states=1, facings=4, props=dict(SOLID), anchor_props={},
         draw=lambda t, st: B1.shred_bench(t)),
    dict(key='bulkShredder', name='Bulk Shredder', foot=(2, 1), states=2, facings=4, props=dict(SOLID), anchor_props={},
         draw=lambda t, st: B1.bulk_shredder(t, st)),
    dict(key='cutter', name='Cutter', foot=(2, 1), states=2, facings=4, props=dict(SOLID), anchor_props={},
         draw=lambda t, st: B1.cutter(t, st)),
    dict(key='woodSaw', name='Wood Saw', foot=(2, 1), states=2, facings=4, props=dict(SOLID), anchor_props={},
         draw=lambda t, st: B2.wood_saw(t, st)),
    dict(key='researchStorage', name='Research Storage', foot=(2, 1), states=1, facings=4, props=dict(SOLID),
         anchor_props=dict(container='locker', ContainerCapacity='100'),
         draw=lambda t, st: B2.research_storage(t)),
    dict(key='propaneRefiner', name='Propane Refiner', foot=(2, 2), states=2, facings=4, props=dict(SOLID),
         anchor_props={}, draw=lambda t, st: B3.propane_refiner(t, st)),
    dict(key='oilRefiner', name='Oil Refiner', foot=(2, 2), states=2, facings=4, props=dict(SOLID), anchor_props={},
         draw=lambda t, st: B3.oil_refiner(t, st)),
    # four water levels are drawn (0 empty .. 3 full). The EMPTY tank is the object (134-137, what is placed, what the
    # entity's SpriteConfig names, with IsWaterCollector on the anchor); the full tank stays at 128-131 (the item
    # icon); levels 1-3 are overlay tiles at 146-157 (see rain_overlays). Places 138-145 are not used.
    dict(key='rainStorage', name='Big Rain Storage', foot=(2, 2), states=4, facings=1, props=dict(IsLow='', **SOLID),
         anchor_props=dict(IsWaterCollector=''), draw=lambda t, st: B2.rain_storage(st),
         state_bases={0: 134, 3: 128}),
)


def _layout():
    base = 0
    for kind in KINDS:
        kind['base'] = base
        kind['tiles'] = kind['foot'][0] * kind['foot'][1]
        if 'state_bases' in kind:
            assert base == kind['state_bases'][3]
            base += kind['tiles']
        else:
            base += kind['states'] * kind['facings'] * kind['tiles']
    return base


LURE_ON = _layout()          # 132
LURE_OFF = LURE_ON + 1       # 133
RAIN_OVERLAY = 146           # the rain storage's overlays of levels 1, 2, 3: 4 tiles each, 146-157
MACHINE_TILES = RAIN_OVERLAY + 12
MACHINE_ROWS = (MACHINE_TILES + COLS - 1) // COLS


def facing_list(kind):
    return FACINGS if kind['facings'] == 4 else (('', 0),)


def foot_of(kind, turns):
    w, h = kind['foot']
    return (h, w) if turns % 2 else (w, h)


_RENDERED = {}


def render(key, state, facing):
    """One look of one machine: {(i, j): tile image}, cached."""
    kind = next(k for k in KINDS if k['key'] == key)
    turns = dict(FACINGS).get(facing, 0)
    token = (key, state, facing)
    if token not in _RENDERED:
        done = kind['draw'](turns, state if 'state_bases' in kind else bool(state))
        _RENDERED[token] = done if isinstance(done, dict) else {(0, 0): done}
    return _RENDERED[token]


def rain_overlays():
    """The overlay tiles of the rain storage's levels 1-3: {level: {(i, j): image}}. An overlay tile has the pixels of that
    level's tile that differ from the empty tank's tile, transparent elsewhere; the empty tile with the overlay drawn
    over it (alpha compositing) is exactly the level's tile (asserted for all twelve)."""
    empty = render('rainStorage', 0, '')
    out = {}
    for level in (1, 2, 3):
        full = render('rainStorage', level, '')
        out[level] = {}
        for pos in sorted(empty, key=lambda q: (q[1], q[0])):
            a = np.asarray(empty[pos]).astype(np.int16)
            b = np.asarray(full[pos]).astype(np.int16)
            differs = (a != b).any(axis=2)
            overlay = np.where(differs[..., None], b, 0).astype(np.uint8)
            tile = Image.fromarray(overlay, 'RGBA')
            joined = np.asarray(Image.alpha_composite(empty[pos], tile))
            assert (joined == np.asarray(full[pos])).all(), ('rain overlay level', level, pos,
                                                           'pixels off: %d' % int((joined != np.asarray(full[pos])).any(axis=2).sum()))
            out[level][pos] = tile
    return out


def assembled(key, state=0, facing='S', floor=False, background=(0, 0, 0, 0), tiles=None):
    """A machine as it stands in the world: its tiles placed at their squares on one canvas."""
    tiles = tiles or render(key, state, facing)
    fw = max(i for i, j in tiles) + 1
    fh = max(j for i, j in tiles) + 1
    out = Image.new('RGBA', ((fw + fh) * 64 + 128, (fw + fh) * 32 + 256), background)
    dx = fh * 64
    if floor:
        d = ImageDraw.Draw(out)
        for j in range(fh):
            for i in range(fw):
                ox, oy = dx + (i - j) * 64, (i + j) * 32
                d.polygon([(ox + 64, oy + 192), (ox + 128, oy + 224), (ox + 64, oy + 256), (ox, oy + 224)],
                          fill=(96, 110, 80, 255))
    for j in range(fh):
        for i in range(fw):
            out.alpha_composite(tiles[(i, j)], (dx + (i - j) * 64, (i + j) * 32))
    return out


def machine_entries():
    """(image, props) for every place of the machines sheet (None where it is empty)."""
    entries = [None] * (MACHINE_ROWS * COLS)
    for kind in KINDS:
        n = kind['tiles']
        nf = kind['facings']
        for st in range(kind['states']):
            if 'state_bases' in kind and st not in kind['state_bases']:
                continue
            for fi, (facing, turns) in enumerate(facing_list(kind)):
                tiles = render(kind['key'], st, facing)
                fw, fh = foot_of(kind, turns)
                assert set(tiles) == {(i, j) for j in range(fh) for i in range(fw)}, (kind['key'], facing)
                for (i, j), image in tiles.items():
                    p = props(kind['name'], GroupName='OA_' + kind['key'], SpriteGridPos='%d,%d' % (i, j))
                    p.update(kind['props'])
                    if (i, j) == (0, 0):
                        p.update(kind['anchor_props'])
                    if facing:
                        p['Facing'] = facing
                    first = kind['state_bases'][st] if 'state_bases' in kind else kind['base'] + st * nf * n
                    place = first + (fi * n if 'state_bases' not in kind else 0) + j * fw + i
                    assert entries[place] is None, (kind['key'], place)
                    entries[place] = (image, p)
    entries[LURE_ON] = (M2.lure(True), LURE)
    entries[LURE_OFF] = (M2.lure(False), LURE)
    # the overlays: decoration only, no properties
    overlays = rain_overlays()
    for level in (1, 2, 3):
        for (i, j), image in overlays[level].items():
            place = RAIN_OVERLAY + (level - 1) * 4 + j * 2 + i
            assert entries[place] is None, place
            entries[place] = (image, {})
    return entries


def trade_entries():
    return [(entry[0](), entry[1]) for entry in TRADE]


SHEETS = {
    'trade': dict(sheet='oa_trade_01', file='oa_trade.tiles', pack='OperationAcornTrade', make=trade_entries, rows=2),
    'machines': dict(sheet='oa_machines_01', file='oa_machines.tiles', pack='OperationAcornMachines',
                     make=machine_entries, rows=MACHINE_ROWS),
}


def write_tiles(path, sheet, entries, rows):
    out = io.BytesIO()
    out.write(b'tdef')
    out.write(struct.pack('<ii', 1, 1))
    out.write((sheet + '\n').encode('latin1'))
    out.write((sheet + '.png\n').encode('latin1'))
    out.write(struct.pack('<iiii', COLS, rows, 1, COLS * rows))
    for index in range(COLS * rows):
        p = entries[index][1] if index < len(entries) and entries[index] else {}
        out.write(struct.pack('<i', len(p)))
        for key, value in p.items():
            out.write((key + '\n' + value + '\n').encode('latin1'))
    with open(path, 'wb') as f:
        f.write(out.getvalue())


def trim(image):
    box = image.getbbox() or (0, 0, 1, 1)
    return image.crop(box), box[0], box[1]


def write_pack(path, sheet, images):
    """The header-less pack the game reads for mods: one page, an entry per sprite (its place in the page and its
    offset in the full tile), the page as PNG, the end mark."""
    pieces = [(name, *trim(image)) for name, image in images]
    x = y = row = 0
    placed = []
    for name, crop, ox, oy in pieces:
        if x + crop.width > 1024:
            x, y, row = 0, y + row + 2, 0
        placed.append((name, crop, x, y, ox, oy))
        x += crop.width + 2
        row = max(row, crop.height)
    page = Image.new('RGBA', (1024, y + row), (0, 0, 0, 0))
    for name, crop, px, py, ox, oy in placed:
        page.alpha_composite(crop, (px, py))
    png = io.BytesIO()
    page.save(png, 'PNG')
    out = io.BytesIO()

    def string(text):
        data = text.encode('latin1')
        out.write(struct.pack('<i', len(data)) + data)
    out.write(struct.pack('<i', 1))
    string(sheet + '0')
    out.write(struct.pack('<ii', len(placed), 1))
    for name, crop, px, py, ox, oy in placed:
        string(name)
        out.write(struct.pack('<8i', px, py, crop.width, crop.height, ox, oy, W, H))
    out.write(png.getvalue())
    out.write(b'\xef\xbe\xad\xde')
    with open(path, 'wb') as f:
        f.write(out.getvalue())


def preview(images, path):
    """Each tile on a floor square, eight to a row as in the sheet, at twice the size, its number in the corner."""
    present = [im for im in images if im is not None]
    top = min((im.getbbox() or (0, H, 0, H))[1] for im in present)
    top = max(0, top - 8)
    rows = (len(images) + COLS - 1) // COLS
    sheet = Image.new('RGBA', (W * COLS, (H - top) * rows), (52, 58, 52, 255))
    floor = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(floor).polygon([(64, 192), (128, 224), (64, 256), (0, 224)], fill=(96, 110, 80, 255))
    for index, image in enumerate(images):
        if image is None:
            continue
        tile = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        tile.alpha_composite(floor)
        tile.alpha_composite(image)
        cell = tile.crop((0, top, W, H))
        ImageDraw.Draw(cell).text((3, 2), str(index), fill=(255, 255, 255, 200))
        sheet.alpha_composite(cell, ((index % COLS) * W, (index // COLS) * (H - top)))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(path)


def machines_preview(path):
    """Every machine as it stands in the world on its floor squares: a row a look (stopped, running), a column a facing
    (S E N W), then the rain storage and the lure."""
    rows = []
    for kind in KINDS:
        for st in range(kind['states']):
            if 'state_bases' in kind:
                if st == 0:   # one row for the four water levels, empty to full: the empty tank with the overlay over it
                    overlays = rain_overlays()
                    row = []
                    for level in range(kind['states']):
                        tiles = render(kind['key'], 0, '')
                        if level:
                            tiles = {pos: Image.alpha_composite(tiles[pos], overlays[level][pos]) for pos in tiles}
                        row.append(assembled(kind['key'], floor=True, background=(52, 58, 52, 255), tiles=tiles))
                    rows.append(row)
                continue
            row = [assembled(kind['key'], st, f, floor=True, background=(52, 58, 52, 255)) for f, t in facing_list(kind)]
            rows.append(row)
    cell_w = 4 * 64 + 128
    height = sum(max(im.height for im in row) for row in rows) + 256
    sheet = Image.new('RGBA', (cell_w * 4, height), (52, 58, 52, 255))
    y = 0
    for row in rows:
        for column, image in enumerate(row):
            sheet.alpha_composite(image, (column * cell_w + (cell_w - image.width) // 2, y))
        y += max(im.height for im in row)
    for column, on in enumerate((True, False)):
        tile = Image.new('RGBA', (W, H), (52, 58, 52, 255))
        ImageDraw.Draw(tile).polygon([(64, 192), (128, 224), (64, 256), (0, 224)], fill=(96, 110, 80, 255))
        tile.alpha_composite(M2.lure(on))
        sheet.alpha_composite(tile, (column * cell_w + (cell_w - W) // 2, y))
    sheet.save(path)


def build(name):
    spec = SHEETS[name]
    entries = spec['make']()
    write_tiles(os.path.join(ROOT, spec['file']), spec['sheet'], entries, spec['rows'])
    os.makedirs(os.path.join(ROOT, 'texturepacks'), exist_ok=True)
    write_pack(os.path.join(ROOT, 'texturepacks', spec['pack'] + '.pack'), spec['sheet'],
               [('%s_%d' % (spec['sheet'], index), entry[0]) for index, entry in enumerate(entries) if entry])
    return [entry[0] if entry else None for entry in entries]


def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    here = os.path.dirname(os.path.abspath(__file__))
    for name in SHEETS:
        if only and name != only:
            continue
        images = build(name)
        if '--preview' in sys.argv:
            if name == 'machines':
                machines_preview(os.path.join(here, 'tile_art_preview_machines.png'))
                preview(images, os.path.join(here, 'tile_art_preview_machines_tiles.png'))
            else:
                preview(images, os.path.join(here, 'tile_art_preview_%s.png' % name))
        print('wrote', name, sum(1 for image in images if image is not None), 'tiles')
        if name == 'machines':
            print('rain overlays: 12 tiles, each overlaid on the empty tile equals its level tile (pixel-equal)')


if __name__ == '__main__':
    main()
