"""The prose review packets: the mod's Korean text, grouped and laid out for another model to read and revise.

PLAN.md stage 6: the whole prose goes once through a model with a better ear for spoken Korean. Each packet stands
alone: what the mod is, who speaks and how, what must stay, what is wanted, and how to answer; then its lines, each
with its key. The comms scenes are laid out as scripts with their speakers and the pauses written out; the rest as
key and text. The answer is every line again, revised (the judging is ours, not the other model's): `compare` lists
the lines it changed beside the game's, to be judged one by one; `apply` puts the lines of a file into the game (the
answer as judged, or a file of the lines kept).

    python -X utf8 tools/prose_packets.py export <folder>
    python -X utf8 tools/prose_packets.py compare <answer.txt> <review.md>
    python -X utf8 tools/prose_packets.py apply <lines.txt>     (the KO translations; prints what it changed)
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
KO = os.path.join(MOD, 'OperationAcorn', '42', 'media', 'lua', 'shared', 'Translate', 'KO')
COMMS = os.path.join(MOD, 'OperationAcorn', '42', 'media', 'lua', 'shared', 'OperationAcorn', 'Story', 'CommsData.lua')
SCENES = os.path.join(MOD, 'SCENES.md')

PREAMBLE = """\
# Operation Acorn 문구 검토 {n}/{total}: {title}

## 이 모드

- 좀비 생존 게임 Project Zomboid의 모드다. 배경은 1993년 켄터키, 좀비 사태 직후다.
- 주인공(플레이어)은 고립된 생존자다. 단말로 육군 시료 분석 파견대 '2반'(무전 호출부호 참나무)과 거래한다. 주인공이 시료를 모아 상자로 보내면 헬기가 보급 상자를 떨어뜨린다.
- 2반은 구조대가 아니고 주인공을 데려가지 않는다. 이야기는 이 사실을 두고 흘러간다. 단계가 오를수록 2반의 인사가 깎이고, 바깥도 무너지고 있다는 것이 드러난다.
- 8단계에서 담당이 새 부서 '관리 7'로 넘어간다(이관). 관리 7은 버릇 없이 건조하다.

## 말하는 사람

| 사람 | 말투 |
| --- | --- |
| 브랜스컴 (참나무, 무전) | 짧고 온전한 합쇼체. 무전 관용구("이상", "정정합니다"). 반말은 5단계 헬기 앞 한 줄과 8단계 작별에서만 샌다 |
| 주인공 | 2반에게 해요체 구어. 반말은 감정이 넘치는 순간과 썼다 지우는 말에만. 성별, 나이, 직업, 가족이 드러나는 말은 하지 않는다 |
| 관리 7 | 늘 긴 인사("여기는 관리 7. 정시 교신입니다."). 끊김, 침묵, 정정 같은 버릇이 없다 |
| 키슬링 | 보급 명세서 비고를 쓰는 실무자. 짧은 메모 |
| 더니건 박사 | 2반에서 생각을 글로 적는 유일한 사람 |
| 애시다운 | 관찰 기록체. 온도는 화씨 |
| 2반 문서 | 군 공문 개조식. 명사형으로 끝맺는다 |
{extra_people}
## 부탁

모든 줄을 네가 생각하는 스타일대로 새로 써 줘. 원문은 초안일 뿐이니 지키려 하지 않아도 된다. 어느 쪽을 쓸지는 이쪽에서 원문과 나란히 놓고 고르니, 과감하게 써도 잃을 것이 없다.

## 게임 때문에 지켜야 하는 것

- 맨 앞의 키(`...`)는 그대로 둔다.
- [호출부호]와 %2 같은 자리표시자는 그대로 둔다. 바로 뒤에 조사를 붙이지 않는다 (숫자로 바뀌어 받침이 정해지지 않는다).
- [쉼 N초], [침묵 N초], [신호 끊김 N초]는 화면에서 흐르는 시간이다. 옮기거나 빼거나 더해도 되지만 이 꼴로 쓴다.
- [줄바꿈]은 화면에서 줄이 바뀌는 자리다. 이 꼴로 쓴다.
- 장면의 줄 수와 화자 순서는 바꾸지 않는다.
{extra_keep}
## 돌려주는 형식

줄은 빠짐없이, 이 문서의 순서대로, 한 줄에 하나씩 적는다. 장면 줄은 화자를 붙인 꼴로 쓴다. 제목, 설명, 까닭은 적지 않는다.

`키` 문장
`키` 화자: 문장

"""

KEEP_CALLBACKS = """\
- 앞 장면을 되받는 줄이라 글자 그대로 둔다: `S5F_3`의 "투하조는 착륙하지 않습니다", `S8_6`의 "처음에 헬기 자리 있냐고 물었지", `K4_2`의 지운 말.
"""

SPEAKER = {'oak': '참나무', 'admin': '관리 7', 'me': '주인공'}
# The other translation files the packets carry, after IG_UI.json; and the most lines a packet asks back at once (a
# longer answer is cut short).
OTHER_FILES = ['ItemName.json', 'Tooltip.json', 'ContextMenu.json', 'Moodles.json', 'Moveables.json', 'Sandbox.json']
CHUNK = 250


def load(name):
    with open(os.path.join(KO, name), encoding='utf-8') as f:
        return json.load(f)


def readable(text):
    """The game's marks written out for a reader."""
    text = re.sub(r'\{p:([\d.]+)\}', r'[쉼 \1초]', text)
    text = re.sub(r'\{cut:([\d.]+)\}', r'[신호 끊김 \1초]', text)
    text = re.sub(r'\{mute:([\d.]+)\}', r'[침묵 \1초]', text)
    text = text.replace('%1', '[호출부호]')
    return text.replace('\n', '[줄바꿈]')


def marked(text):
    """A reader's notes back into the game's marks."""
    text = re.sub(r'\[쉼 ([\d.]+)초\]', r'{p:\1}', text)
    text = re.sub(r'\[신호 끊김 ([\d.]+)초\]', r'{cut:\1}', text)
    text = re.sub(r'\[침묵 ([\d.]+)초\]', r'{mute:\1}', text)
    text = text.replace('[호출부호]', '%1')
    return text.replace('[줄바꿈]', '\n')


def entries():
    """CommsData's entries in order: { id, kind, sign, greet, lines: [(speaker, n, erase, late, secs)] }."""
    src = open(COMMS, encoding='utf-8').read()
    body = src[src.index('Data.ENTRIES = {'):]
    out = []
    for m in re.finditer(r'\{ id = "([^"]+)", kind = "(\w+)"(.*?)(?=\n    \{ id = |\n\}\n)', body, re.S):
        eid, kind, rest = m.group(1), m.group(2), m.group(3)
        sign = re.search(r'sign = "(\w+)"', rest)
        e = {'id': eid, 'kind': kind, 'sign': sign.group(1) if sign else None,
             'greet': 'greet = true' in rest, 'lines': []}
        lines = re.search(r'lines = \{(.*)\}', rest, re.S)
        if lines:
            for n, l in enumerate(re.findall(r'\{ "(\w+)"([^}]*)\}', lines.group(1)), 1):
                secs = re.search(r's = ([\d.]+)', l[1])
                e['lines'].append((l[0], n, 'erase = true' in l[1], 'late = true' in l[1], secs.group(1) if secs else None))
        out.append(e)
    return out


def scene_table():
    """SCENES.md 3's rows: id -> (name, trigger, feeling)."""
    rows = {}
    for line in open(SCENES, encoding='utf-8'):
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) == 7 and re.match(r'^(S\d+\w*|K\d\w*|K1~K4)$', cells[0]):
            rows[cells[0]] = (cells[2], cells[3], cells[6])
    return rows


def scene_block(e, ui, table, used):
    name = table.get(e['id']) or table.get('K1~K4' if e['id'].startswith('K') else '')
    out = ['### %s%s' % (e['id'], (' ' + name[0]) if name else '')]
    if name:
        out.append('')
        out.append('- 언제: %s' % name[1])
        out.append('- 감정: %s' % name[2])
        if e['kind'] == 'field':
            out.append('- 현장 교신: 게임이 멈추지 않는 가운데 화면 아래에 자막처럼 뜬다. 헬기가 다가오고 좀비가 모인다.')
    if e['greet']:
        out.append('- 첫 줄 앞에는 그 단계의 인사가 붙는다 (예: "여기는 참나무, 정시 교신입니다.").')
    out.append('')
    sign = SPEAKER['admin'] if e['sign'] == 'admin' else SPEAKER['oak']
    for who, n, erase, late, secs in e['lines']:
        if who == 'noise':
            out.append('(잡음 %s초)' % secs)
            continue
        if who == 'mute':
            out.append('(무음 %s초)' % secs)
            continue
        speaker = sign if who == 'oak' else SPEAKER['me']
        key = 'IGUI_OA_Comms_%s_%d' % (e['id'], n)
        if erase:
            xk = key + '_x'
            used.add(xk)
            out.append('`%s_%d_x` %s (썼다 지운 말): %s' % (e['id'], n, speaker, readable(ui.get(xk, ''))))
        used.add(key)
        tag = ''
        if e['greet'] and n == 1:
            # the greeting goes before it; a line that is the greeting alone stays empty
            tag = ' (인사만 나오는 줄, 비워 둔다)' if ui.get(key, '') == '' else ' (앞에 인사가 붙는 줄)'
        out.append('`%s_%d` %s%s: %s' % (e['id'], n, speaker, tag, readable(ui.get(key, ''))))
        if late:
            lk = key + '_late'
            used.add(lk)
            out.append('`%s_%d_late` %s (첫 상자가 늦게 온 세계에서 대신 나오는 줄): %s' % (e['id'], n, speaker,
                                                                         readable(ui.get(lk, ''))))
    out.append('')
    return out


def keyed(prefix, keys, ui, used, note=None):
    out = []
    if note:
        out += [note, '']
    for k in keys:
        used.add(k)
        out.append('`%s` %s' % (k[len(prefix):] if prefix and k.startswith(prefix) else k, readable(ui[k])))
    out.append('')
    return out


def export(folder):
    os.makedirs(folder, exist_ok=True)
    ui = load('IG_UI.json')
    table = scene_table()
    es = entries()
    used = set()
    packets = []

    def scenes(title, ids, extra=''):
        body = ['## 장면', '', '각 줄은 `키` 화자: 문장 꼴이다. 돌려줄 때는 키와 문장만 적는다.', '']
        for e in es:
            if e['id'] in ids:
                body += scene_block(e, ui, table, used)
        packets.append((title, body, extra))

    first = [e['id'] for e in es if e['kind'] in ('scene', 'field') and re.match(r'^S[0-4]', e['id'])]
    later = [e['id'] for e in es if e['kind'] in ('scene', 'field') and e['id'] not in first]
    scenes('교신 장면 (시작~4단계)', first)
    scenes('교신 장면 (5단계~이관 뒤)', later)

    # short calls and the field monologues
    body = ['## 짧은 교신', '', '2반이 단말로 보내는 한 줄짜리 교신이다. 첫머리에 그 단계의 인사가 붙는다.', '']
    for e in es:
        if e['kind'] == 'short':
            k = 'IGUI_OA_Comms_' + e['id']
            used.add(k)
            body.append('`%s` 참나무: %s' % (e['id'], readable(ui.get(k, ''))))
    body += ['', '## 현장 혼잣말', '',
             '이야기 임무 현장에서 주인공 머리 위에 뜨는 혼잣말이다. 원에 처음 들어설 때는 바깥에서 보이는 것만 말한다.', '']
    for e in es:
        if e['kind'] == 'say':
            k = 'IGUI_OA_Comms_' + e['id']
            used.add(k)
            body.append('`%s` %s' % (e['id'], readable(ui.get(k, ''))))
    body.append('')
    greet = sorted(k for k in ui if k.startswith('IGUI_OA_Story_Greeting_') or k.startswith('IGUI_OA_Story_CallSign_'))
    body += ['## 인사와 호출부호', ''] + keyed('IGUI_OA_Story_', greet, ui, used)
    packets.append(('짧은 교신과 현장 혼잣말', body, ''))

    def group(title, prefixes, note, extra=''):
        keys = [k for k in ui if k not in used and any(k.startswith('IGUI_OA_' + p) for p in prefixes)]
        if keys:
            packets.append((title, ['## 문구', ''] + keyed('IGUI_OA_', keys, ui, used, note), extra))

    group('2반 문서', ['Story_Doc', 'Story_Request', 'Story_FacilityNote', 'Story_StakeDate', 'Story_Facility'],
          '단말 수신함에 쌓이는 2반의 서류다 (회신서, 별첨, 미해결 사항 목록, 현장 문서, 요청서 사본). 공문 개조식이고, 사람마다 버릇이 있다. ` / `는 줄바꿈이다.')
    group('보급 명세서 비고', ['Story_Note', 'Story_Fill'],
          '보급 상자마다 붙는 명세서의 비고 칸이다. 키슬링이 쓴다. 이관 뒤(after) 비고는 관리 7 쪽 담당자가 쓰고, 먼 단계일수록 짧아진다.')
    group('임무 글', ['Story_Title', 'Story_Brief', 'Story_RegTitle', 'Story_RegBrief', 'Story_ConTitle',
                    'Story_ConBrief', 'Story_SpecialTitle', 'Story_Meta', 'Story_HarvestFail'],
          '단말 임무 탭에 뜨는 임무 이름과 설명이다. 2반이 쓴 지시문이다.')
    group('일상 혼잣말', ['Say_'],
          '이야기와 상관없이 주인공 머리 위에 뜨는 혼잣말이다 (현장 도착, 첫 효과 등). 짧은 감탄, 의문, 다음 행동.')
    rest = [k for k in ui if k not in used]
    note = ('단말 창의 탭, 버튼, 상태 표시, 기술 나무, 기계 같은 화면 문구다. 게이머가 실제로 쓰는 말로 짧게 쓴다 ("점" 대신 '
            '"포인트"). 제목 카드는 게임의 알림이라 명사나 개조식으로 끝낸다.')
    parts = [rest[i:i + CHUNK] for i in range(0, len(rest), CHUNK)]
    for i, keys in enumerate(parts, 1):
        packets.append(('화면 문구 (단말과 시스템) %d/%d' % (i, len(parts)),
                        ['## 문구', ''] + keyed('IGUI_OA_', keys, ui, used, note), ''))
    others = [(k, v) for name in OTHER_FILES for k, v in load(name).items()]
    parts = [others[i:i + CHUNK] for i in range(0, len(others), CHUNK)]
    for i, part in enumerate(parts, 1):
        body = ['## 문구', '', '아이템 이름, 툴팁, 우클릭 메뉴, 무들, 설치물, 서버 설정 문구다.', '']
        body += ['`%s` %s' % (k, readable(v)) for k, v in part] + ['']
        packets.append(('아이템, 툴팁, 메뉴, 설정 %d/%d' % (i, len(parts)), body, ''))

    for i, (title, body, extra) in enumerate(packets, 1):
        head = PREAMBLE.format(n=i, total=len(packets), title=title, extra_people='',
                               extra_keep=KEEP_CALLBACKS if '교신 장면' in title else '')
        path = os.path.join(folder, '%02d.md' % i)
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(head + '\n'.join(body).rstrip() + '\n')
        print(path, len('\n'.join(body)), 'chars')


SPOKEN = re.compile(r'^(참나무|관리 7|주인공)(?: \([^)]*\))?:\s*')


def short_keys(ui):
    """The keys as the packets write them, short -> the key: whole, and without IGUI_OA_Comms_, IGUI_OA_Story_ or
    IGUI_OA_ (a whole key first, then the shorter forms that are not another key's). The first packets cut eight
    characters off a key of IG_UI that has no IGUI_OA_ (IGUI_ContainerTitle_X written tainerTitle_X): read too."""
    out = {k: k for k in ui}
    for prefix in ('IGUI_OA_Comms_', 'IGUI_OA_Story_', 'IGUI_OA_'):
        for k in ui:
            if k.startswith(prefix):
                out.setdefault(k[len(prefix):], k)
    for k in ui:
        if k.startswith('IGUI_') and not k.startswith('IGUI_OA_'):
            out.setdefault(k[len('IGUI_OA_'):], k)
    return out


def answered(answer, ui):
    """The lines of an answer: (key in the game, its text in the game's marks), in order. A pasted answer may have lost
    its line breaks and backticks: a word that is a key (in backticks or not) starts a line. A scene line's speaker is
    taken off, the (noise) and (silence) notes and a `— why` after a line are dropped."""
    keys = short_keys(ui)
    text = open(answer, encoding='utf-8').read()
    text = re.sub(r'\((?:잡음|무음) [\d.]+초\)', ' ', text)
    out, key, words = [], None, []

    def close():
        if key is not None:
            body = re.sub(r'\s+—\s+.*$', '', ' '.join(words)).strip()
            out.append((key, marked(SPOKEN.sub('', body).strip())))

    for word in text.split():
        bare = word.strip('`').lstrip('-*')
        if bare in keys and (word.startswith('`') or bare not in ('', '-')):
            close()
            key, words = keys[bare], []
        elif key is not None:
            words.append(word)
    close()
    return out


def texts():
    """Every translation the packets carry: key -> (file, text)."""
    out = {}
    for name in ['IG_UI.json'] + OTHER_FILES:
        for k, v in load(name).items():
            out[k] = (name, v)
    return out


def compare(answer, review):
    """The lines an answer changed, beside the game's, to be judged."""
    ui = {k: v for k, (_, v) in texts().items()}
    lines = answered(answer, ui)
    out = ['# 교정 대조', '']
    changed = 0
    for key, text in lines:
        if ui[key] != text:
            changed += 1
            out += ['`%s`' % key, '- 원문: %s' % readable(ui[key]), '- 교정: %s' % readable(text), '']
    out.append('%d줄 중 %d줄 바뀜' % (len(lines), changed))
    with open(review, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    print(len(lines), 'lines,', changed, 'changed ->', review)


def apply(answer):
    """Puts the lines of a file into the KO translations: `key` text, one a line (a scene's with its speaker)."""
    every = texts()
    files = {}
    changed = 0
    for key, text in answered(answer, {k: v for k, (_, v) in every.items()}):
        name, old = every[key]
        if old != text:
            print('%s: %s -> %s' % (key, old, text))
            files.setdefault(name, load(name))[key] = text
            changed += 1
    for name, data in files.items():
        with open(os.path.join(KO, name), 'w', encoding='utf-8', newline='\n') as f:
            json.dump(data, f, ensure_ascii=False, indent=4)
            f.write('\n')
    print(changed, 'changed')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'export':
        export(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == 'compare':
        compare(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == 'apply':
        apply(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
