"""The prose review packets: the mod's Korean text, grouped and laid out for another model to read and revise.

As Operation Acorn's (its tools/prose_packets.py): the whole prose goes once through a model with a better ear for
Korean. Each packet stands alone: what the mod is, how each kind of text speaks, what must stay, what is wanted, and how
to answer; then its lines, each with its key. The answer is every line again, revised (the judging is ours, not the
other model's): `compare` lists the lines it changed beside the game's, to be judged one by one; `apply` puts the lines
of a file into the game (the answer as judged, or a file of the lines kept). `export` also makes the answers folder
with an empty file for each packet, to paste the answers into.

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
KO = os.path.join(MOD, 'BuildingUtilities', '42', 'media', 'lua', 'shared', 'Translate', 'KO')
PREFIX = 'IGUI_BU_'

PREAMBLE = """\
# Building Utilities 문구 검토 {n}/{total}: {title}

## 이 모드

- 좀비 생존 게임 Project Zomboid(빌드 42)의 모드다.
- 건물 안에 '설비 제어반'을 설치하면 바깥에 둔 발전기, 물 저장소(빗물받이 통 같은 물 통), 태양광 패널, 배터리 랙에서 건물 전체나 정한 방들에 전기와 물을 댄다.
- 물은 색으로 나뉜 배관(최대 8개)을 따라 흐르고, 가압 펌프가 높은 층으로 올린다. 전신주와 야외 수전으로 다른 건물까지 선을 잇는다.
- 제어반은 1~4단계다. 단계가 오를수록 정격 부하가 커지고 기기별 스위치, 타이머, 기록, 그래프가 생긴다.
- 이야기나 등장인물은 없다. 글은 제어반 창(탭, 목록, 상태 표시, 평면도 범례), 알림, 우클릭 메뉴, 사용 설명서, 서버 설정이다.

## 말투

| 어디 | 말투 |
| --- | --- |
| 제어반 창, 메뉴, 범례, 상태 표시 | 게이머가 실제로 쓰는 짧은 말. 버튼, 탭, 머리는 명사로 끝낸다 |
| 알림, 안 되는 까닭 | 무슨 일이 났는지, 왜 안 되는지 한눈에 들어오게. 한 문장으로 |
| 사용 설명서 | 제조사가 제어반 문 안쪽에 붙인 설명판. 개조식 지시문 ("~할 것", "~함", 명사로 끝맺음) |
| 타이틀 | 화면 가운데 뜨는 게임 알림. 명사나 개조식으로 끝낸다 |
| 서버 설정 | 설정 이름은 짧은 명사, 설명(_tooltip)은 무엇이 바뀌는지 |

## 부탁

모든 줄을 네가 생각하는 스타일대로 새로 써 줘. 원문은 초안일 뿐이니 지키려 하지 않아도 된다. 어느 쪽을 쓸지는 이쪽에서 원문과 나란히 놓고 고르니, 과감하게 써도 잃을 것이 없다. 번역한 티가 나는 말, 게임에서 안 쓰는 딱딱한 말을 특히 봐 줘.

## 게임 때문에 지켜야 하는 것

- 맨 앞의 키(`...`)는 그대로 둔다.
- %1, %2 같은 자리표시자는 그대로 둔다. 숫자나 이름으로 바뀌므로 바로 뒤에 조사를 새로 붙이지 않는다 (받침이 정해지지 않는다).
- [줄바꿈]은 화면에서 줄이 바뀌는 자리다. 이 꼴로 쓴다. 사용 설명서의 "## 제목" 줄과 "·" 목록도 이 꼴로 쓴다.
- 용어는 바꾸지 않는다: 물 저장소 ("물탱크"라고 하지 않는다), 설비 제어반, 태양광 패널, 배터리 랙, 양수 펌프, 정수 필터, 가압 펌프, 스프링클러, 화재 스프링클러, 분기함, 야외 수전, 전신주, 배관, 구역, 중계, 정격 부하, 차단기. 게임에 원래 있는 물건은 게임의 이름 그대로 쓴다 (발전기, 빗물받이 통).
- 효과를 말하는 숫자는 남긴다.

## 돌려주는 형식

줄은 빠짐없이, 이 문서의 순서대로, 한 줄에 하나씩 적는다. 제목, 설명, 까닭은 적지 않는다.

`키` 문장

"""

# The other translation files the packets carry, after IG_UI.json; and the most lines a packet asks back at once (a
# longer answer is cut short).
OTHER_FILES = ['ItemName.json', 'Recipes.json', 'ContextMenu.json', 'Sandbox.json']
CHUNK = 250


def load(name):
    with open(os.path.join(KO, name), encoding='utf-8') as f:
        return json.load(f)


def readable(text):
    """The game's line breaks written out for a reader."""
    return text.replace('\n', '[줄바꿈]')


def marked(text):
    """A reader's line breaks back into the game's."""
    return text.replace('[줄바꿈]', '\n')


def keyed(keys, ui, used, note=None):
    out = []
    if note:
        out += [note, '']
    for k in keys:
        used.add(k)
        out.append('`%s` %s' % (k[len(PREFIX):] if k.startswith(PREFIX) else k, readable(ui[k])))
    out.append('')
    return out


def export(folder):
    os.makedirs(folder, exist_ok=True)
    ui = load('IG_UI.json')
    used = set()
    packets = []

    def group(title, prefixes, note):
        keys = [k for k in ui if k not in used and any(k.startswith(PREFIX + p) for p in prefixes)]
        parts = [keys[i:i + CHUNK] for i in range(0, len(keys), CHUNK)]
        for i, part in enumerate(parts, 1):
            name = title if len(parts) == 1 else '%s %d/%d' % (title, i, len(parts))
            packets.append((name, ['## 문구', ''] + keyed(part, ui, used, note)))

    group('사용 설명서', ['Manual'],
          '제어반 창 마지막 탭의 사용 설명서다. 제조사가 제어반 문 안쪽에 붙인 설명판이다. 이름 줄은 장 목록에 뜨는 장 이름, '
          'Text로 끝나는 줄이 그 장의 본문이다.')
    group('알림, 까닭, 타이틀', ['Notice', 'Reason', 'Why', 'LineCut', 'Missing', 'HangsOn', 'Title'],
          'Notice는 제어반 기록과 화면에 뜨는 알림, Reason과 Why는 기기가 안 돌거나 연결이 안 되는 까닭, LineCut은 선이 끊긴 '
          '까닭, Title은 화면 가운데 뜨는 타이틀이다. %1은 대개 제어반이나 기기의 이름이다.')
    group('방 이름', ['Room_'],
          '평면도와 구역 목록에 뜨는 방 이름이다. 게임 지도의 방 종류(키 뒤쪽 영어)를 한국어로 부른 것이다. ww_는 서부 마을 '
          '(웨스턴 테마 마을) 건물의 방이다. 짧은 명사로 쓴다.')
    rest = [k for k in ui if k not in used]
    note = ('제어반 창의 탭, 버튼, 목록, 상태 표시, 평면도 범례, 툴팁(Tip으로 끝나는 키) 같은 화면 문구다. 게이머가 실제로 '
            '쓰는 말로 짧게 쓴다.')
    parts = [rest[i:i + CHUNK] for i in range(0, len(rest), CHUNK)]
    for i, keys in enumerate(parts, 1):
        packets.append(('화면 문구 %d/%d' % (i, len(parts)), ['## 문구', ''] + keyed(keys, ui, used, note)))
    others = [(k, v) for name in OTHER_FILES for k, v in load(name).items()]
    parts = [others[i:i + CHUNK] for i in range(0, len(others), CHUNK)]
    for i, part in enumerate(parts, 1):
        body = ['## 문구', '', '아이템 이름, 제작법 이름, 우클릭 메뉴, 서버 설정(이름과 _tooltip 설명) 문구다.', '']
        body += ['`%s` %s' % (k, readable(v)) for k, v in part] + ['']
        name = '아이템, 메뉴, 설정' if len(parts) == 1 else '아이템, 메뉴, 설정 %d/%d' % (i, len(parts))
        packets.append((name, body))

    answers = os.path.join(folder, 'answers')
    os.makedirs(answers, exist_ok=True)
    os.makedirs(os.path.join(folder, 'reviews'), exist_ok=True)
    for i, (title, body) in enumerate(packets, 1):
        head = PREAMBLE.format(n=i, total=len(packets), title=title)
        path = os.path.join(folder, '%02d.md' % i)
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(head + '\n'.join(body).rstrip() + '\n')
        answer = os.path.join(answers, '%02d.md' % i)
        if not os.path.exists(answer):
            open(answer, 'w', encoding='utf-8').close()
        print(path, len('\n'.join(body)), 'chars')


def short_keys(ui):
    """The keys as the packets write them, short -> the key: whole, and without IGUI_BU_ (not another key's)."""
    out = {k: k for k in ui}
    for k in ui:
        if k.startswith(PREFIX):
            out.setdefault(k[len(PREFIX):], k)
    return out


def answered(answer, ui):
    """The lines of an answer: (key in the game, its text), in order. A pasted answer may have lost its line breaks and
    backticks: a word that is a key (in backticks or not) starts a line. A `— why` after a line is dropped."""
    keys = short_keys(ui)
    text = open(answer, encoding='utf-8').read()
    out, key, words = [], None, []

    def close():
        if key is not None:
            body = re.sub(r'\s+—\s+.*$', '', ' '.join(words)).strip()
            out.append((key, marked(body)))

    for word in text.split():
        bare = word.strip('`').lstrip('-*')
        if bare in keys and (word.startswith('`') or bare not in ('', '-')):
            close()
            key, words = keys[bare], []
        elif key is not None:
            words.append(word)
    close()
    return out


def same(old, new):
    """Whether a line came back as it was but for its spaces: a pasted answer runs the double spaces that set a row's
    columns apart into one."""
    return old.split() == new.split() and old.count('\n') == new.count('\n')


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
        if not same(ui[key], text):
            changed += 1
            out += ['`%s`' % key, '- 원문: %s' % readable(ui[key]), '- 교정: %s' % readable(text), '']
    out.append('%d줄 중 %d줄 바뀜' % (len(lines), changed))
    with open(review, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    print(len(lines), 'lines,', changed, 'changed ->', review)


def apply(answer):
    """Puts the lines of a file into the KO translations: `key` text, one a line."""
    every = texts()
    files = {}
    changed = 0
    for key, text in answered(answer, {k: v for k, (_, v) in every.items()}):
        name, old = every[key]
        if not same(old, text):
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
