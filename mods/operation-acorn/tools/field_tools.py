#!/usr/bin/env python3
"""The research team's field tools ('야전 X', 'Field X'): each a vanilla tool the team issues, a little lighter and longer
lasting, and the kits make more of it (Gear/Gear.lua). Made from the game's own scripts and textures, so every property
the vanilla tool has (its tags, what it does in a fight, what it breaks into) stays as it is:

    python tools/field_tools.py           writes the scripts and the textures below
    python tools/field_tools.py --check   checks they are what the vanilla scripts make now (no writing)

What changes from the vanilla tool:
  * Weight x WEIGHT (0.85) and ConditionMax x CONDITION (1.2; 10, the game's default, when the script has none). A tool
    with a head (HeadCondition) gets the head at the same new most: the game holds a head to the item's ConditionMax.
  * One look: a tool the game draws one of several ways (IconsForTexture, WeaponSpritesByIndex ...) is the first, the
    manufactured one.
  * The team's olive on the coloured parts of its model (a plastic grip, a painted shaft, a wooden handle), as
    vanilla_art.team_paint paints its icon: a texture of our own and a copy of the vanilla model blocks that use it. An
    all-metal tool, and one whose wood is the tool (PLAIN), keeps the vanilla model and texture.

What it writes (under OperationAcorn/42/media):
    scripts/OA_field_tools.txt           the items and the model blocks
    textures/OA_FieldTools/<name>.png    the vanilla textures in the team's olive
The icons come through tools/icon_art.py (vanilla_art.team_icon); the shop's list is Shop.FIELD_TOOLS, which must name
the same tools (tests/unit/economy_shop_test.lua checks the two agree through the script).
"""
import argparse
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vanilla_art as V  # noqa: E402

MEDIA = V.MEDIA
PZ_MEDIA = V.PZ_MEDIA
SCRIPT = os.path.join(MEDIA, 'scripts', 'OA_field_tools.txt')
TEX_DIR = os.path.join(MEDIA, 'textures', 'OA_FieldTools')

WEIGHT = 0.85
CONDITION = 1.2
# The vanilla tools, in the order the shop shows them: carpentry, metalworking, masonry, mechanics, demolition, the
# outdoors, then the small hand tools. Left out: the car jack and the tyre pump (the game asks for them by their exact
# type), the needle (it weighs nothing to lighten), and the forged and stone tools (made, not issued).
TOOLS = [
    'Hammer', 'BallPeenHammer', 'ClubHammer', 'WoodenMallet', 'Saw', 'GardenSaw', 'SmallSaw', 'CarpentryChisel',
    'HandDrill',
    'SmithingHammer', 'Tongs', 'MetalworkingPliers', 'MetalworkingPunch', 'MetalworkingChisel', 'File', 'SmallFileSet',
    'SheetMetalSnips', 'ViseGrips', 'HeadingTool', 'SmallPunchSet',
    'MasonsTrowel', 'MasonsChisel', 'PlasterTrowel',
    'Screwdriver', 'Wrench', 'Ratchet', 'PipeWrench', 'LugWrench', 'Pliers',
    'Crowbar', 'BoltCutters', 'Sledgehammer',
    'WoodAxe', 'Axe', 'HandAxe', 'Shovel', 'HandShovel', 'PickAxe', 'GardenHoe', 'GardenFork', 'Scythe', 'HandScythe',
    'Scissors', 'Awl', 'Whetstone',
]
# Tools whose colour is their material, not paint: they keep the vanilla look (the icon gets the mark only).
PLAIN = {'WoodenMallet'}
# A texture counts as painted when at least this share of its drawn pixels takes the olive.
PAINT_SHARE = 0.03
# How much of a painted part's grain shows through the paint (vanilla_art.team_paint).
FLATTEN = 0.55
MODEL_KEYS = ('WeaponSprite', 'StaticModel', 'WorldStaticModel')
BY_INDEX = {'WeaponSpritesByIndex': 'WeaponSprite', 'StaticModelsByIndex': 'StaticModel',
            'WorldStaticModelsByIndex': 'WorldStaticModel'}


def item_name(tool):
    return 'Field' + tool


# ---- the vanilla scripts --------------------------------------------------------------------------------------

def _blocks(kind):
    """{name: (header line, body lines)} of every `item` or `model` block in the vanilla scripts, braces matched."""
    found = {}
    head = re.compile(r'^\s*' + kind + r'\s+(\w+)\s*$')
    for root, _, files in os.walk(os.path.join(PZ_MEDIA, 'scripts')):
        for fn in sorted(files):
            if not fn.endswith('.txt'):
                continue
            lines = open(os.path.join(root, fn), encoding='utf-8', errors='replace').read().split('\n')
            i = 0
            while i < len(lines):
                m = head.match(lines[i])
                if m and i + 1 < len(lines) and lines[i + 1].strip() == '{':
                    depth, j, body = 0, i + 1, []
                    while j < len(lines):
                        depth += lines[j].count('{') - lines[j].count('}')
                        body.append(lines[j].rstrip('\r'))
                        if depth == 0:
                            break
                        j += 1
                    found.setdefault(m.group(1), body)
                    i = j
                i += 1
    return found


_items = _models = None


def vanilla_items():
    global _items
    if _items is None:
        _items = _blocks('item')
    return _items


def vanilla_models():
    global _models
    if _models is None:
        _models = _blocks('model')
    return _models


def prop(body, key):
    for line in body:
        m = re.match(r'^\s*' + key + r'\s*=\s*(.*?),?\s*$', line)
        if m:
            return m.group(1)
    return None


def fmt(x):
    t = ('%.3f' % x).rstrip('0')
    return t + '0' if t.endswith('.') else t


# ---- textures -------------------------------------------------------------------------------------------------

_textures = None


def texture_files():
    global _textures
    if _textures is None:
        _textures = {}
        base = os.path.join(PZ_MEDIA, 'textures')
        for root, _, files in os.walk(base):
            for fn in files:
                if fn.lower().endswith('.png'):
                    rel = os.path.relpath(os.path.join(root, fn), base).replace('\\', '/')[:-4]
                    _textures.setdefault(rel.lower(), os.path.join(root, fn))
    return _textures


def model_texture(model):
    """A vanilla model block's texture (media/textures path without .png) and its file: the block's `texture`, or, as
    the game does without one, its mesh's path."""
    body = vanilla_models()[model]
    tex = prop(body, 'texture') or prop(body, 'mesh')
    path = texture_files().get(tex.replace('\\', '/').lower())
    if not path:
        raise SystemExit('no texture %s for model %s' % (tex, model))
    return tex, path


def painted(path):
    """The vanilla texture in the team's olive, and the share of its drawn pixels that changed."""
    img = Image.open(path).convert('RGBA')
    out = V.team_paint(img, FLATTEN)
    a = np.asarray(img).astype(int)
    b = np.asarray(out).astype(int)
    drawn = a[..., 3] > 127
    changed = (np.abs(a[..., :3] - b[..., :3]).sum(-1) > 24) & drawn
    return out, changed.sum() / max(1, drawn.sum())


# ---- the field tools ------------------------------------------------------------------------------------------

def tool_models(body):
    """The models a vanilla tool is drawn with: [(key, model name)], the first of a by-index list."""
    out = []
    for line in body:
        m = re.match(r'^\s*(\w+)\s*=\s*(.*?),?\s*$', line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        if key in BY_INDEX:
            key, value = BY_INDEX[key], value.split(';')[0]
        if key in MODEL_KEYS:
            out.append((key, value.replace('Base.', '')))
    return out


def plan():
    """What is made: (items {tool: lines}, models {model: lines}, textures {name: (image, vanilla path)})."""
    items, models, textures = {}, {}, {}
    vi = vanilla_items()
    for tool in TOOLS:
        body = vi.get(tool)
        if body is None:
            raise SystemExit('no vanilla item ' + tool)
        used = tool_models(body)
        if not used:
            raise SystemExit('no model for ' + tool)
        names = {}
        repaint = []
        for _, model in used:
            tex, path = model_texture(model)
            if tool in PLAIN:
                continue
            img, share = painted(path)
            if share >= PAINT_SHARE:
                repaint.append((model, tex, path, img))
        if repaint:
            # all the tool's models take our olive once one does, so the hand and the floor agree
            for _, model in used:
                tex, path = model_texture(model)
                img, _ = painted(path)
                name = 'OA_Field_' + os.path.basename(tex)
                textures[name] = (img, path)
                models['OA_Field' + model] = (model, name)
                names[model] = 'OperationAcorn.OA_Field' + model
        else:
            for _, model in used:
                names[model] = 'Base.' + model
        items[tool] = item_lines(tool, body, names)
    return items, models, textures


def item_lines(tool, body, names):
    weight = float(prop(body, 'Weight'))
    cmax = int(prop(body, 'ConditionMax') or 10)
    out = []
    done = set()
    for line in body:
        m = re.match(r'^(\s*)(\w+)\s*=\s*(.*?),?\s*$', line)
        if not m:
            out.append(line)
            continue
        ind, key, value = m.groups()
        if key in ('Icon', 'IconsForTexture'):
            if 'Icon' not in done:
                out.append('%sIcon = OA_%s,' % (ind, item_name(tool)))
                done.add('Icon')
            continue
        if key in BY_INDEX:
            key, value = BY_INDEX[key], value.split(';')[0]
        if key in MODEL_KEYS:
            out.append('%s%s = %s,' % (ind, key, names[value.replace('Base.', '')]))
            continue
        if key == 'Weight':
            out.append('%sWeight = %s,' % (ind, fmt(round(weight * WEIGHT, 2))))
            continue
        if key == 'ConditionMax':
            out.append('%sConditionMax = %d,' % (ind, round(cmax * CONDITION)))
            done.add('ConditionMax')
            continue
        if key == 'HeadCondition':
            out.append('%sHeadCondition = %d,' % (ind, round(cmax * CONDITION)))
            continue
        out.append(line)
    if 'ConditionMax' not in done:
        # after the weight, where the vanilla scripts put it
        at = next(i for i, l in enumerate(out) if re.match(r'^\s*Weight\s*=', l))
        ind = re.match(r'^(\s*)', out[at]).group(1)
        out.insert(at + 1, '%sConditionMax = %d,' % (ind, round(cmax * CONDITION)))
    return out


def model_lines(name, model, texture):
    body = vanilla_models()[model]
    out = []
    has_tex = False
    for line in body:
        m = re.match(r'^(\s*)texture\s*=', line)
        if m:
            out.append('%stexture = OA_FieldTools/%s,' % (m.group(1), texture))
            has_tex = True
        else:
            out.append(line)
    if not has_tex:
        at = next(i for i, l in enumerate(out) if re.match(r'^\s*mesh\s*=', l))
        ind = re.match(r'^(\s*)', out[at]).group(1)
        out.insert(at + 1, '%stexture = OA_FieldTools/%s,' % (ind, texture))
    return ['    model %s' % name] + out


HEADER = '''/* Operation Acorn: the research team's field tools. Written by tools/field_tools.py from the vanilla scripts: do not
   edit; change the tool there and run it again.
   Each is the vanilla tool of its name (media/scripts/generated/items) at %s of its weight and %s of its ConditionMax,
   drawn the manufactured way; the tools with coloured parts in the team's olive (the OA_Field models below, the vanilla
   model blocks with our texture). Every other property is the vanilla tool's: the tags are what the game's uses look
   for, so each does the vanilla tool's work. The kits make more of them (media/lua/shared/OperationAcorn/Gear). */
module OperationAcorn
{
    imports
    {
        Base
    }
''' % (fmt(WEIGHT), fmt(CONDITION))


def script_text(items, models):
    lines = [HEADER.rstrip('\n')]
    for tool in TOOLS:
        lines.append('')
        lines.append('    item %s' % item_name(tool))
        lines.extend(items[tool])
    for name in sorted(models):
        model, texture = models[name]
        lines.append('')
        lines.extend(model_lines(name, model, texture))
    lines.append('}')
    return '\n'.join(lines) + '\n'


def build(check=False):
    items, models, textures = plan()
    text = script_text(items, models)
    if check:
        have = open(SCRIPT, encoding='utf-8').read()
        assert have == text, 'scripts/OA_field_tools.txt is not what the vanilla scripts make: run tools/field_tools.py'
        for name in textures:
            assert os.path.exists(os.path.join(TEX_DIR, name + '.png')), name
        assert sorted(f[:-4] for f in os.listdir(TEX_DIR)) == sorted(textures), 'stray textures in ' + TEX_DIR
        print('ok: %d tools, %d models, %d textures' % (len(items), len(models), len(textures)))
        return
    with open(SCRIPT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    os.makedirs(TEX_DIR, exist_ok=True)
    for fn in os.listdir(TEX_DIR):
        if fn[:-4] not in textures:
            os.remove(os.path.join(TEX_DIR, fn))
    for name, (img, _) in textures.items():
        img.save(os.path.join(TEX_DIR, name + '.png'), optimize=True)
    print('wrote %d tools, %d models, %d textures' % (len(items), len(models), len(textures)))


def painted_tools():
    """The tools drawn in the olive (their icon is painted too); the rest get the mark only."""
    _, models, _ = plan()
    return models


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    build(ap.parse_args().check)
