"""Writes Operation Acorn's quick landing nodes: each vanilla landing node (with its extends resolved) once for each
rank that lands quicker, behind the character variable OALandRank. Gentle landings are cut early (a shallower crouch)
and blend out still rising; hard landings only play faster."""
import os, re
import xml.etree.ElementTree as ET

VANILLA = r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\AnimSets\player\falling'
OUT = r'C:\git\pz-workspace\operation-acorn\OperationAcorn\42\media\AnimSets\player\falling'
VARIABLE = 'OALandRank'
# rank: (speed times the game's, cut of a gentle landing in its clip, blend in, blend out of a gentle landing)
# Bob_FallLanding_Heavy (1.47 s) takes the pelvis from 0.545 down to 0.177 by 0.35 s and back by 1.2 s. The landing
# plays its own crouch and rise at the speed and is cut on the way up, the clip going on rising as it blends out (a
# cut at the crouch, its pose frozen and blended out, read as a twitch). Rank 2 is cut stood up (1.2 s of the clip, in
# 0.65 s) and blended out in 0.2 s: some 0.8 s in all. Rank 3 is cut half way up (0.9 s, in 0.12 s) and blended out in
# 0.1 s: some 0.2 s; its blend in is longer than its way down, so the crouch shows some 70% deep.
RANKS = {2: (2.3, 0.818, 0.10, 0.20), 3: (9.4, 0.61, 0.06, 0.10)}
# A hard landing (two floors and more) throws the character down and is played whole, only faster.
HARD_SPEED = {2: 2.0, 3: 4.0}
GENTLE = ['land_gentle', 'land_gentle_2H', 'land_gentle_2Hheavy', 'land_gentle_Rifle', 'land_gentle_heavytorchleft',
          'land_gentle_hgun', 'land_gentle_spear']
HARD = ['land_heavy', 'land_heavy2']


def load(name):
    root = ET.parse(os.path.join(VANILLA, name + '.xml')).getroot()
    parent = root.get('x_extends')
    if not parent:
        return root
    base = load(parent[:-4])
    # the child's elements replace the parent's of the same tag (scalars) or the same x_name (lists); bone weights add
    for child in list(root):
        xname = child.get('x_name')
        if xname:
            for old in base.findall(child.tag):
                if old.get('x_name') == xname:
                    base.remove(old)
        elif child.tag not in ('m_SubStateBoneWeights',):
            for old in base.findall(child.tag):
                base.remove(old)
        base.append(child)
    return base


def text(parent, tag, value):
    for old in parent.findall(tag):
        parent.remove(old)
    e = ET.SubElement(parent, tag)
    e.text = value
    return e


def node(name, rank, gentle):
    speed, cut, blend_in, blend_out = RANKS[rank]
    if not gentle:
        speed = HARD_SPEED[rank]
    root = load(name)
    root.attrib.pop('x_extends', None)
    text(root, 'm_Name', 'oa_%s_r%d' % (name, rank))
    text(root, 'm_SpeedScale', '%.2f' % (float(root.findtext('m_SpeedScale') or '1') * speed))
    # above all of the game's nodes, and all of them alike: the game plays every node that passes of the best kind
    # (a weapon's, a held torch's with the plain one), and the same of these do
    text(root, 'm_ConditionPriority', '1')
    condition = ET.SubElement(root, 'm_Conditions', {'x_name': 'oa-land-rank'})
    ET.SubElement(condition, 'm_Name').text = VARIABLE
    ET.SubElement(condition, 'm_Type').text = 'STRING'
    ET.SubElement(condition, 'm_Value').text = str(rank)
    if gentle:
        text(root, 'm_BlendTime', '%.2f' % blend_in)
        text(root, 'm_BlendOutTime', '%.2f' % blend_out)
        text(root, 'm_StopAnimOnExit', 'false')
        text(root, 'm_EarlyTransitionOut', 'false')
        event = ET.SubElement(root, 'm_Events', {'x_name': 'oa-land-cut'})
        ET.SubElement(event, 'm_EventName').text = 'SetVariable'
        ET.SubElement(event, 'm_TimePc').text = '%.3f' % cut
        ET.SubElement(event, 'm_ParameterValue').text = 'bLandAnimFinished=true'
    order = ['m_Name', 'm_AnimName', 'm_Looped', 'm_ConditionPriority', 'm_BlendTime', 'm_BlendOutTime',
             'm_StopAnimOnExit', 'm_EarlyTransitionOut', 'm_SpeedScale', 'm_Conditions', 'm_Events', 'm_Transitions',
             'm_SubStateBoneWeights']
    children = sorted(list(root), key=lambda e: order.index(e.tag) if e.tag in order else len(order))
    for c in list(root):
        root.remove(c)
    for c in children:
        root.append(c)
    ET.indent(root, '\t')
    path = os.path.join(OUT, 'oa_%s_r%d.xml' % (name, rank))
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding='unicode') + '\n')
    return path


os.makedirs(OUT, exist_ok=True)
for rank in RANKS:
    for name in GENTLE:
        print(node(name, rank, True))
    for name in HARD:
        print(node(name, rank, False))
