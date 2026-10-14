#!/usr/bin/env python3
"""The team's versions of vanilla gear, drawn from the game's own pictures: the welding mask (the vanilla mask's
texture in the team's olive, its amber lens a dark green auto-darkening one) and the field tools (the vanilla icon with
the team's olive on its coloured parts, and the team's mark; their textures are tools/field_tools.py's). Vanilla files are read from the game install (PZ_DIR, default the Steam folder) and never copied
as they are: what is written is always changed.

    python tools/vanilla_art.py           writes the welding mask's texture and clothing item (and registers it)

The item icons come through tools/icon_art.py, which calls team_icon() here.

What it writes (under OperationAcorn/42/media):
    textures/Clothes/Hat/OA_TeamWelderMask.png         the vanilla WelderMask.png recoloured
    clothing/clothingItems/OA_Hat_TeamWelderMask.xml   the vanilla mask's models with that texture
    fileGuidTable.xml                                  registers the clothing item (tools/backpack_mesh.merge_guid_table)
"""
import io
import os
import re
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
MEDIA = os.path.join(HERE, '..', 'OperationAcorn', '42', 'media')
PZ_DIR = os.environ.get('PZ_DIR', r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid')
PZ_MEDIA = os.path.join(PZ_DIR, 'media')
PACKS = [os.path.join(PZ_MEDIA, 'texturepacks', 'UI2.pack'), os.path.join(PZ_MEDIA, 'texturepacks', 'UI.pack')]

# The team's olive (tools/tile_objects.py OD_DARK .. OD_LIGHT), the ramp a grey is mapped onto by its lightness.
OLIVE_DARK, OLIVE, OLIVE_LIGHT = (58, 64, 44), (104, 114, 78), (150, 160, 116)
LENS = (40, 96, 74)          # an auto-darkening lens: dark green glass

MASK_TEXTURE = os.path.join(MEDIA, 'textures', 'Clothes', 'Hat', 'OA_TeamWelderMask.png')
MASK_ITEM = 'OA_Hat_TeamWelderMask'
MASK_GUID = '3c6f1d0e-8a57-4b2e-9f31-6d2a7c40b915'


# ---- the game's pictures --------------------------------------------------------------------------------------

def _rint(f):
    return struct.unpack('<i', f.read(4))[0]


def _rstr(f):
    return f.read(_rint(f)).decode('latin-1')


def _pages(path):
    """The pages of a texture pack (PZPK v1): (entries, png bytes); an entry is (name, x y w h ox oy fw fh)."""
    data = open(path, 'rb').read()
    f = io.BytesIO(data)
    if f.read(4) == b'PZPK':
        _rint(f)
    else:
        f.seek(0)
    for _ in range(_rint(f)):
        _rstr(f)
        n = _rint(f)
        _rint(f)
        entries = [(_rstr(f), struct.unpack('<8i', f.read(32))) for _ in range(n)]
        pos = f.tell()
        if data[pos:pos + 8].startswith(b'\x89PNG'):
            end = data.index(b'IEND', pos) + 8
            png = data[pos:end]
            f.seek(end + 4 if data[end:end + 4] == b'\xef\xbe\xad\xde' else end)
        else:
            png = f.read(_rint(f))
        yield entries, png


_icon_names = None
_icons = {}


def _item_icon_names():
    """Each vanilla item's icon name, from its script (Icon, or the first of IconsForTexture)."""
    global _icon_names
    if _icon_names is None:
        _icon_names = {}
        for root, _, files in os.walk(os.path.join(PZ_MEDIA, 'scripts')):
            for fn in files:
                if not fn.endswith('.txt'):
                    continue
                text = open(os.path.join(root, fn), encoding='utf-8', errors='replace').read()
                for m in re.finditer(r'^\s*item (\w+)\s*\n\s*\{(.*?)\n\s*\}', text, re.S | re.M):
                    icon = re.search(r'^\s*Icon(?:sForTexture)?\s*=\s*([^,;\s]+)', m.group(2), re.M)
                    if icon:
                        _icon_names.setdefault(m.group(1), icon.group(1))
    return _icon_names


def vanilla_icon(item_type):
    """A vanilla item's inventory icon (32 px, RGBA), by the item's type name (Base.<type>)."""
    if item_type in _icons:
        return _icons[item_type].copy()
    want = 'Item_' + _item_icon_names()[item_type]
    for pack in PACKS:
        for entries, png in _pages(pack):
            for name, (x, y, w, h, ox, oy, fw, fh) in entries:
                if name == want:
                    sheet = Image.open(io.BytesIO(png)).convert('RGBA')
                    img = Image.new('RGBA', (max(fw, w + ox), max(fh, h + oy)), (0, 0, 0, 0))
                    img.paste(sheet.crop((x, y, x + w, y + h)), (ox, oy))
                    _icons[item_type] = img
                    return img.copy()
    raise SystemExit('no icon %s for %s in the texture packs' % (want, item_type))


# ---- the team's changes ---------------------------------------------------------------------------------------

def _hsl(img):
    a = np.asarray(img.convert('RGBA')).astype(np.float64) / 255.0
    rgb = a[..., :3]
    mx, mn = rgb.max(-1), rgb.min(-1)
    light = (mx + mn) / 2
    sat = np.where(mx > mn, (mx - mn) / (1 - np.abs(mx + mn - 1) + 1e-9), 0)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    span = np.where(mx > mn, mx - mn, 1)
    hue = np.where(mx == r, ((g - b) / span) % 6, np.where(mx == g, (b - r) / span + 2, (r - g) / span + 4)) / 6
    return a, light, sat, hue


def _olive(out, where, light):
    """The pixels `where` in the team's olive, at their own lightness (dark below 0.3, the olive at 0.5, light above)."""
    ramp_x = np.array([0.0, 0.3, 0.5, 0.75, 1.0])
    ramp = np.array([[20, 22, 16], OLIVE_DARK, OLIVE, OLIVE_LIGHT, [214, 220, 190]]) / 255.0
    for c in range(3):
        out[..., c] = np.where(where, np.interp(light, ramp_x, ramp[:, c]), out[..., c])


def _image(a, out):
    res = np.concatenate([out, a[..., 3:]], -1)
    return Image.fromarray((res * 255).round().astype(np.uint8), 'RGBA')


def team_recolour(img):
    """The welding mask in the team's colours: its greys the olive at their own lightness, the amber of its lens dark
    green glass; black stays."""
    a, light, sat, hue = _hsl(img)
    out = a[..., :3].copy()
    _olive(out, (sat < 0.18) & (light > 0.12), light)
    amber = (sat > 0.25) & (hue > 0.02) & (hue < 0.17) & (light > 0.15)
    shade = np.clip(light / 0.55, 0.35, 1.6)[..., None]
    out = np.where(amber[..., None], np.clip(np.array(LENS) / 255.0 * shade, 0, 1), out)
    return _image(a, out)


def team_paint(img, flatten=1.0):
    """A tool in the team's colours: its painted or wooden parts (the coloured ones: a handle, a saw's frame, a
    crowbar) the olive at their own lightness; the bare metal and black stay. `flatten` below 1 draws the lightness of
    those parts that much nearer their mean: the paint over a wooden handle hides most of its grain (a model's texture;
    an icon keeps its drawn shading)."""
    a, light, sat, hue = _hsl(img)
    out = a[..., :3].copy()
    where = (sat > 0.22) & (light > 0.08) & (light < 0.92)
    seen = where & (a[..., 3] > 0.5)
    if flatten != 1.0 and seen.any():
        mean = light[seen].mean()
        light = np.where(where, mean + (light - mean) * flatten, light)
    _olive(out, where, light)
    return _image(a, out)


BADGE = 11      # the corner the mark takes on a 32 px icon


def emptiest_corner(img):
    """The icon's corner where least is drawn, (right, bottom) as 0/1: where the mark goes."""
    a = np.asarray(img.getchannel('A')).astype(np.float64)
    n = BADGE
    corners = {(0, 1): a[-n:, :n], (1, 1): a[-n:, -n:], (0, 0): a[:n, :n], (1, 0): a[:n, -n:]}
    return min(corners, key=lambda c: (corners[c].sum(), c != (0, 1)))


def team_badge(img, corner=(0, 1)):
    """The team's mark on an icon of any size, in a corner: a small olive disc, edged dark, with a pale acorn."""
    from tile_engine import acorn_mark
    img = img.copy()
    k = img.width / 32.0
    d = ImageDraw.Draw(img)
    r = 3.9 * k
    cx = img.width - 4.6 * k if corner[0] else 4.6 * k
    cy = img.height - 4.6 * k if corner[1] else 4.6 * k
    d.ellipse([cx - r - k, cy - r - k, cx + r + k, cy + r + k], fill=(22, 24, 18, 235))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=OLIVE + (255,))
    mark = acorn_mark(max(5, round(6 * k)), colour=(232, 226, 196))
    img.alpha_composite(mark, (round(cx - mark.width / 2), round(cy - mark.height / 2)))
    return img


def team_icon(item_type, mask=False, paint=True):
    """The 32 px team icon of a vanilla item and its 64 px copy (the vanilla icon doubled pixel for pixel, the mark
    drawn at 64): (icon, {64: copy}). The item is in the team's colours (team_paint, or not when its model keeps the
    vanilla look; the welding mask team_recolour) and marked in its emptiest corner."""
    base = vanilla_icon(item_type)
    if mask:
        base = team_recolour(base)
    elif paint:
        base = team_paint(base)
    corner = emptiest_corner(base)
    return team_badge(base, corner), {64: team_badge(base.resize((64, 64), Image.NEAREST), corner)}


# ---- the welding mask -----------------------------------------------------------------------------------------

def write_mask():
    src = os.path.join(PZ_MEDIA, 'textures', 'Clothes', 'Hat', 'WelderMask.png')
    os.makedirs(os.path.dirname(MASK_TEXTURE), exist_ok=True)
    team_recolour(Image.open(src)).convert('RGB').save(MASK_TEXTURE)
    vanilla = open(os.path.join(PZ_MEDIA, 'clothing', 'clothingItems', 'Hat_WeldersMask.xml'), encoding='utf-8-sig').read()
    xml = re.sub(r'<m_GUID>[^<]*</m_GUID>', '<m_GUID>%s</m_GUID>' % MASK_GUID, vanilla)
    xml = re.sub(r'<textureChoices>[^<]*</textureChoices>', r'<textureChoices>clothes\\hat\\OA_TeamWelderMask</textureChoices>', xml)
    assert MASK_GUID in xml and 'OA_TeamWelderMask' in xml
    path = os.path.join(MEDIA, 'clothing', 'clothingItems', MASK_ITEM + '.xml')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(xml.replace('\r\n', '\n'))
    sys.path.insert(0, HERE)
    import backpack_mesh
    backpack_mesh.merge_guid_table(os.path.join(MEDIA, 'fileGuidTable.xml'), {MASK_ITEM: MASK_GUID})
    print('wrote', os.path.relpath(MASK_TEXTURE, HERE), os.path.relpath(path, HERE))


if __name__ == '__main__':
    sys.path.insert(0, HERE)
    write_mask()
