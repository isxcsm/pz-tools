"""Writes Operation Acorn's landing nodes for 낙법: each vanilla landing node (with its extends resolved) once for each
rank, behind the character variable OALandRank. 낙법 counts a fall as a share of its height, which can take a real fall
below the height the game lands lightly from (and plays no landing for, bare-handed): every gentle node here lands
whatever the light landing's damage, so a fall always shows at least the light landing. From rank 2 the gentle
landing plays faster and is cut on the way up; hard landings play faster."""
import os, re
import xml.etree.ElementTree as ET

VANILLA = r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\AnimSets\player\falling'
OUT = r'C:\git\pz-workspace\operation-acorn\OperationAcorn\42\media\AnimSets\player\falling'
VARIABLE = 'OALandRank'
# rank: (speed times the game's, cut of a gentle landing in its clip, blend in, blend out), None for the game's own.
# Bob_FallLanding_Heavy (1.47 s) takes the pelvis from 0.545 down to 0.177 by 0.35 s and back by 1.2 s. The landing
# plays its own crouch and rise at the speed and is cut stood up (1.2 s of the clip), the clip going on as it blends
# out (a cut at the crouch, its pose frozen and blended out, read as a twitch): rank 2 in 0.85 s and 0.15 s out, some
# 1.0 s in all; rank 3 in 0.45 s and 0.15 s out, some 0.6 s.
RANKS = {1: None, 2: (1.76, 0.818, 0.10, 0.15), 3: (3.33, 0.818, 0.10, 0.15)}
# A hard landing throws the character down and is played whole, only faster; rank 1's is the game's.
HARD_SPEED = {2: 2.0, 3: 4.0}
# The condition of the plain gentle landing that it does damage (bLandLight); a weapon's node has its own in its place.
LAND_LIGHT = 'aba1d435-d51e-461e-9c29-7ddea2483c13'
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
    timing = RANKS[rank] if gentle else None
    speed = timing[0] if timing else HARD_SPEED.get(rank, 1.0)
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
        # whatever its damage: the rank again in place of bLandLight, so that the nodes are chosen among themselves
        # as the game's are (as many conditions each)
        for old in root.findall('m_Conditions'):
            if old.get('x_name') == LAND_LIGHT and old.findtext('m_Name') == 'bLandLight':
                old.find('m_Name').text = VARIABLE
                old.find('m_Type').text = 'STRING'
                old.find('m_Value').text = str(rank)
    if timing:
        speed, cut, blend_in, blend_out = timing
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
        if rank in HARD_SPEED:
            print(node(name, rank, False))
