"""Writes PZExtDev's translation files from the table below (EN, KO). Run: python -X utf8 dev/tools/strings.py"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1] / 'PZExtDev' / '42' / 'media' / 'lua' / 'shared' / 'Translate'

S = {
    # the window
    'Title': ('PZ Extension API Dev', 'PZ Extension API 개발자 창'),
    'Button': ('Dev', 'Dev'),
    'OptionsTitle': ('PZ Extension API Dev', 'PZ Extension API 개발자 도구'),
    'OpenKey': ('Open the dev window', '개발자 창 열기'),
    'Failed': ('Failed:', '실패:'),
    'Section_Api': ('API', 'API'),
    'Tab_Env': ('Environment', '환경'),
    # environment
    'Env_StateTime': ('%1  speed x%2  %3 C %4  rain %5  snow %6  light %7',
                      '%1  속도 x%2  기온 %3도 %4  비 %5  적설 %6  햇빛 %7'),
    'Env_StatePlace': ('at %1, %2, %3  zombies within 30: %4', '위치 %1, %2, %3  30칸 안 좀비 %4'),
    'Env_Held': ('(held)', '(고정)'),
    'Env_Time': ('Time of day', '하루 중 시각'),
    'Env_Freeze': ('Hold the clock', '시간 고정'),
    'Env_Noon': ('Noon', '정오'),
    'Env_Dusk': ('19:00', '19시'),
    'Env_TwoAm': ('2:00', '새벽 2시'),
    'Env_Dawn': ('6:00', '아침 6시'),
    'Env_Weather': ('Weather', '날씨'),
    'Env_Clear': ('Clear', '맑음'),
    'Env_Rain': ('Rain', '비'),
    'Env_Storm': ('Storm', '폭풍'),
    'Env_Snow': ('Snow', '눈'),
    'Env_Temperature': ('Temperature', '기온 고정'),
    'Env_TemperatureGame': ("The game's", '게임 기온'),
    'Env_Character': ('Character', '캐릭터'),
    'Env_God': ('God mode', '갓 모드'),
    'Env_Invisible': ('Invisible', '투명'),
    'Env_NoClip': ('No clip', '노클립'),
    'Env_Heal': ('Heal', '회복'),
    'Env_Needs': ('Hunger, thirst, tiredness off', '배고픔·갈증·피로 없애기'),
    'Env_Zombies': ('Zombies', '좀비'),
    'Env_Count': ('Count', '수량'),
    'Env_AnyOutfit': ('Any outfit', '아무 복장'),
    'Env_Harmless': ('Harmless, still', '무해하고 제자리'),
    'Env_Spawn': ('Spawn near me', '내 주변에 생성'),
    'Env_Clear30': ('Clear within 30', '30칸 안 정리'),
    'Env_ClearAll': ('Clear all loaded', '불러온 좀비 모두 정리'),
    'Env_Sound': ('Loud sound here', '여기서 큰 소리'),
    # the API's pages
    'NoApi': ('PZ Extension API is not in this game.', '이 게임에는 PZ Extension API가 없습니다.'),
    'On': ('on', '켜짐'),
    'Off': ('off', '꺼짐'),
    'Tab_Status': ('Status', '상태'),
    'Tab_Points': ('Points', '포인트'),
    'Tab_Buildings': ('Buildings, networks', '건물·망'),
    'Tab_Text': ('Text', '텍스트'),
    'Tab_Moodles': ('Moodles', '무들'),
    'Tab_Systems': ('Systems', '시스템'),
    'St_Version': ('API version %1', 'API 버전 %1'),
    'St_Hooks': ('Hooks: %1 in, %2 waiting for their class, %3 failed', '훅: 적용 %1, 클래스 대기 %2, 실패 %3'),
    'St_Points': ('Points: %1, not applied %2', '포인트 %1개, 미적용 %2개'),
    'St_Text': ('Text drawing hook: %1', '텍스트 그리기 훅: %1'),
    'St_Networks': ('Networks defined: %1', '정의된 망 %1개'),
    'St_Log': ('Every hook to the log', '훅 전체를 로그로'),
    'St_Logged': ('Written to console.txt.', 'console.txt에 적었습니다.'),
    'Pt_Set': ('Declare %1', '%1 선언'),
    'Pt_Declared': ('%1 = %2 declared', '%1 = %2 선언함'),
    'Pt_Clear': ('Take back', '선언 취소'),
    'Pt_ClearAll': ('Take back all of this window', '이 창의 선언 전부 취소'),
    'Pt_Status': ('Hooks: %1', '훅 상태: %1'),
    'Pt_Combined': ('All mods together: %1', '모든 모드 합산: %1'),
    'Pt_Mine': ('This window declared: %1', '이 창이 선언한 값: %1'),
    'Pt_Tunings': ('Night sight tuning', '야간 시야 조정값'),
    'Pt_Floor': ('nightSight.floor %1 (default %2)', 'nightSight.floor %1 (기본 %2)'),
    'Pt_Night': ('level %1  lift %2  programs %3  problem %4', '단계 %1  밝기 상승 %2  셰이더 %3  문제 %4'),
    'Pt_Default': ('Default', '기본값'),
    'Bd_Key': ('Building %1  player-built %2', '건물 %1  플레이어 건축 %2'),
    'Bd_Room': ('Room %1 (%2)', '방 %1 (%2)'),
    'Bd_Box': ('%1,%2 to %3,%4  floors %5 to %6', '%1,%2 ~ %3,%4  층 %5 ~ %6'),
    'Bd_Version': ('Buildings version %1', '건물 정보 버전 %1'),
    'Bd_None': ('Not in a building.', '건물 안이 아닙니다.'),
    'Bd_Objects': ("Count this building's objects", '이 건물의 기기 세기'),
    'Bd_Counts': ('Power objects %1, water objects %2, all loaded %3', '전력 기기 %1, 물 기기 %2, 전부 불러옴 %3'),
    'Bd_Attached': ('Rooms built onto it: %1', '증축한 방 %1개'),
    'Bd_Networks': ('Networks', '망'),
    'Bd_Reload': ('Read the list', '목록 읽기'),
    'Bd_NoNetwork': ('That network is gone.', '그 망은 없어졌습니다.'),
    'Bd_Net': ('%1  %2 %3  supply %4  on %5  parent %6', '%1  %2 %3  공급 %4  켜짐 %5  상위 %6'),
    'Bd_Power': ('load %1 (own %2) x%3  fuel %4/h  hours left %5', '부하 %1 (자체 %2) x%3  연료 %4/시간  남은 시간 %5'),
    'Bd_Water': ('%1 of %2 L  purify %3', '%1 / %2 L  정수 %3'),
    'Bd_Producer': ('In use %1  producers %2  all loaded %3', '사용 중 %1  공급원 %2개  전부 불러옴 %3'),
    'Tx_Korean': ('Korean sample', '한국어 예문'),
    'Tx_English': ('English sample', '영어 예문'),
    'Tx_Dust': ('Leave as dust', '재로 흩어지며 퇴장'),
    'Tx_Title': ('Show the title', '타이틀 표시'),
    'Tx_Typed': ('Typed text', '타자 효과 텍스트'),
    'Tx_Hide': ('Hide now', '바로 숨기기'),
    'Tx_Shown': ('Last one on screen: %1', '마지막 텍스트 표시 중: %1'),
    'Tx_Title_Ko': ('새로운 길이 열렸다', '새로운 길이 열렸다'),
    'Tx_Sub_Ko': ('지도를 확인하라', '지도를 확인하라'),
    'Tx_Title_En': ('A New Path Opens', 'A New Path Opens'),
    'Tx_Sub_En': ('Check your map', 'Check your map'),
    'Tx_TypedText': ('Signal found. Decoding...', '신호를 잡았다. 해독 중...'),
    'Md_Good': ('Good', '좋음'),
    'Md_Bad': ('Bad', '나쁨'),
    'Md_Neutral': ('Neutral', '중립'),
    'Md_Define': ('Define the test moodle', '테스트 무들 정의'),
    'Md_Defined': ('Defined. Set a level to show it.', '정의했습니다. 단계를 정하면 보입니다.'),
    'Md_Level': ('Level %1', '%1단계'),
    'Md_Now': ('Test moodle at level %1', '테스트 무들 %1단계'),
    'Md_NotDefined': ('The test moodle is not defined yet.', '테스트 무들이 아직 정의되지 않았습니다.'),
    'Sy_HeliNow': ('Helicopter: %1  flying to a player %2', '헬기: %1  플레이어에게 오는 중 %2'),
    'Sy_Near': ('Zombies within 30 on this floor: %1', '이 층 30칸 안 좀비 %1'),
    'Sy_TimerNow': ('1-second timer %1, %2 calls', '1초 타이머 %1, %2회 호출'),
    'Sy_ChunksNow': ('Chunk watch %1, %2 loads', '청크 감시 %1, 로드 %2회'),
    'Sy_Listen': ('Zombie sounds within 30', '30칸 안 좀비 소리'),
    'Sy_Hits': ('Hits on zombies', '좀비 타격'),
    'Sy_Timer': ('Timer on/off', '타이머 켜기/끄기'),
    'Sy_Chunks': ('Chunk watch on/off', '청크 감시 켜기/끄기'),
    'Sy_Held': ('Held item: count and weight', '든 물건 개수·무게'),
    'Sy_NoItem': ('Hold an item first.', '먼저 물건을 손에 드세요.'),
    'Sy_Count': ('%1: %2 carried, weighs %3, factor %4', '%1: %2개 소지, 무게 %3, 배율 %4'),
    'Sy_Sound': ('sound %1 at %2,%3 loudness %4', '소리 %1 위치 %2,%3 크기 %4'),
    'Sy_Hit': ('hit %1 damage %2 killed %3', '타격 %1 피해 %2 사망 %3'),
    'Sy_Heli': ('helicopter %1', '헬기 %1'),
}

# The test moodle's text (the moodle is PZExtDev:Test).
MOODLES = {
    'Moodles_PZExtDev:Test_lvl1': ('Test 1', '테스트 1'),
    'Moodles_PZExtDev:Test_desc_lvl1': ('The dev window set this.', '개발자 창에서 켠 무들입니다.'),
    'Moodles_PZExtDev:Test_lvl2': ('Test 2', '테스트 2'),
    'Moodles_PZExtDev:Test_desc_lvl2': ('The dev window set this.', '개발자 창에서 켠 무들입니다.'),
    'Moodles_PZExtDev:Test_lvl3': ('Test 3', '테스트 3'),
    'Moodles_PZExtDev:Test_desc_lvl3': ('The dev window set this.', '개발자 창에서 켠 무들입니다.'),
    'Moodles_PZExtDev:Test_lvl4': ('Test 4', '테스트 4'),
    'Moodles_PZExtDev:Test_desc_lvl4': ('The dev window set this.', '개발자 창에서 켠 무들입니다.'),
}


def write(lang, index):
    folder = ROOT / lang
    folder.mkdir(parents=True, exist_ok=True)
    table = {'IGUI_PZExtDev_' + k: v[index] for k, v in S.items()}
    text = json.dumps(table, ensure_ascii=False, indent=4) + '\n'
    (folder / 'IG_UI.json').write_bytes(text.encode('utf-8'))
    moodles = {k: v[index] for k, v in MOODLES.items()}
    (folder / 'Moodles.json').write_bytes((json.dumps(moodles, ensure_ascii=False, indent=4) + '\n').encode('utf-8'))


write('EN', 0)
write('KO', 1)
print(len(S), 'strings')
