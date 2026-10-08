"""Draws Operation Acorn's own tiles and writes them as its two tile sheets, with the .tiles definitions, the texture
packs, and the item icons that are drawn from the tiles. Taken from Building Utilities' tools/tile_art.py: the objects are
a few solids in a tile's space, projected the way the game draws a square, shaded by a light from above and the viewer's
left, drawn four times larger with a depth buffer and scaled down (see tile_engine.py).

The sheets (8 tiles a row; the code names a tile by its place: see Sprites.lua):

    oa_trade_01     the communication terminal (off, on; S E N W each), the delivery box, the supply crate, the
                    parachute crate, the scorched ground, the meteor rocks, the drop-site stake (16 tiles)
    oa_machines_01  the shred bench, bulk shredder, cutter, propane refiner, oil refiner and wood saw (stopped and
                    running, S E N W each), the research storage (S E N W), the big rain storage, the lure (51 tiles)

Saves name the tiles by their place in the sheet: a new tile goes in a free place or a new row, never in a used one,
and the sheet keeps its eight columns.

    python tools/tile_art.py            writes OperationAcorn/42/media/oa_trade.tiles, oa_machines.tiles and
                                        texturepacks/OperationAcornTrade.pack, OperationAcornMachines.pack
    python tools/tile_art.py --preview  also writes tools/tile_art_preview_trade.png and ..._machines.png (the tiles on a
                                        floor, for a look)
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

from PIL import Image, ImageDraw  # noqa: E402

import tile_engine as E  # noqa: E402
import tile_objects as O  # noqa: E402
import tile_trade as T  # noqa: E402
import tile_machines as M  # noqa: E402
import tile_machines2 as M2  # noqa: E402

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
BENCH = props('Shred Bench', **SOLID)
SHREDDER = props('Bulk Shredder', **SOLID)
CUTTER = props('Cutter', **SOLID)
PROPANE = props('Propane Refiner', **SOLID)
OIL = props('Oil Refiner', **SOLID)
SAW = props('Wood Saw', **SOLID)
STORAGE = props('Research Storage', container='locker', ContainerCapacity='100', **SOLID)
RAIN = props('Big Rain Storage', IsLow='', IsWaterCollector='', **SOLID)
LURE = props('Lure', IsLow='', BlocksPlacement='')


def facings(draw, base):
    """Four tiles (S, E, N, W) of one object: draw(turns) -> image."""
    return [(lambda t=t: draw(t), dict(base, Facing=f)) for f, t in FACINGS]


def facings2(draw, base, look):
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

MACHINES = (
    # 0-3: the shred bench
    facings(M.shred_bench, BENCH)
    # 4-7, 8-11: the bulk shredder, stopped and running; 12-19 the cutter; 20-27 propane; 28-35 oil; 36-43 saw
    + facings2(M.bulk_shredder, SHREDDER, False) + facings2(M.bulk_shredder, SHREDDER, True)
    + facings2(M.cutter, CUTTER, False) + facings2(M.cutter, CUTTER, True)
    + facings2(M.propane_refiner, PROPANE, False) + facings2(M.propane_refiner, PROPANE, True)
    + facings2(M.oil_refiner, OIL, False) + facings2(M.oil_refiner, OIL, True)
    + facings2(M2.wood_saw, SAW, False) + facings2(M2.wood_saw, SAW, True)
    # 44-47: the research storage
    + facings(M2.research_storage, STORAGE)
    # 48: the big rain storage; 49: the lure on; 50: the lure off
    + [(M2.rain_storage, RAIN), (lambda: M2.lure(True), LURE), (lambda: M2.lure(False), LURE)]
)

SHEETS = {
    'trade': dict(sheet='oa_trade_01', file='oa_trade.tiles', pack='OperationAcornTrade', tiles=TRADE, rows=2),
    'machines': dict(sheet='oa_machines_01', file='oa_machines.tiles', pack='OperationAcornMachines', tiles=MACHINES, rows=7),
}


def write_tiles(path, sheet, tiles, rows):
    out = io.BytesIO()
    out.write(b'tdef')
    out.write(struct.pack('<ii', 1, 1))
    out.write((sheet + '\n').encode('latin1'))
    out.write((sheet + '.png\n').encode('latin1'))
    out.write(struct.pack('<iiii', COLS, rows, 1, COLS * rows))
    for index in range(COLS * rows):
        p = tiles[index][1] if index < len(tiles) and tiles[index] else {}
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


def build(name):
    spec = SHEETS[name]
    images = [entry[0]() if entry else None for entry in spec['tiles']]
    write_tiles(os.path.join(ROOT, spec['file']), spec['sheet'], spec['tiles'], spec['rows'])
    os.makedirs(os.path.join(ROOT, 'texturepacks'), exist_ok=True)
    write_pack(os.path.join(ROOT, 'texturepacks', spec['pack'] + '.pack'), spec['sheet'],
               [('%s_%d' % (spec['sheet'], index), image) for index, image in enumerate(images) if image is not None])
    return images


def main():
    only = sys.argv[sys.argv.index('--only') + 1] if '--only' in sys.argv else None
    here = os.path.dirname(os.path.abspath(__file__))
    for name in SHEETS:
        if only and name != only:
            continue
        images = build(name)
        if '--preview' in sys.argv:
            preview(images, os.path.join(here, 'tile_art_preview_%s.png' % name))
        print('wrote', name, sum(1 for image in images if image is not None), 'tiles')


if __name__ == '__main__':
    main()
