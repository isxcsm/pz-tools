"""Writes BuildingUtilitiesDev's translation files from the table below (EN, KO). Run: python -X utf8 tools/dev_strings.py"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1] / 'BuildingUtilitiesDev' / '42' / 'media' / 'lua' / 'shared' / 'Translate'

S = {
    'Section': ('Building Utilities', 'Building Utilities'),
    'Tab_Give': ('Give', '지급'),
    'Tab_Panel': ('Panel', '제어반'),
    'Tab_Power': ('Power', '전력'),
    'Tab_Solar': ('Solar, batteries', '태양광·배터리'),
    'Tab_Water': ('Water', '물'),
    'Tab_Devices': ('Devices', '기기'),
    'Tab_Options': ('Options', '옵션'),
    'Panel': ('Panel: %1', '제어반: %1'),
    'NoPanel': ('No panel within %1 squares: install one, or choose one on the panel tab.',
                '%1칸 안에 제어반이 없습니다. 설치하거나 제어반 탭에서 고르세요.'),
    'Yes': ('yes', '예'),
    'No': ('no', '아니오'),
    # give
    'Gv_Units': ('Panel and units', '제어반·설비'),
    'Gv_Batteries': ('Batteries', '배터리'),
    'Gv_Worn': ('Worn battery', '낡은 배터리'),
    'Gv_Lines': ('Lines and filter media', '전선·배관·필터 재료'),
    'Gv_Tools': ('Tools and generator', '공구·발전기'),
    'Gv_Free': ('Lines cost nothing', '연결 비용 없음'),
    # the panel
    'Pn_Read': ('Read the list', '목록 읽기'),
    'Pn_Choose': ('Use this one', '이 제어반 쓰기'),
    'Pn_Nearest': ('Use the nearest', '가장 가까운 것 쓰기'),
    'Pn_IsNearest': ('(nearest)', '(가장 가까움)'),
    'Pn_Tier': ('Tier', '단계'),
    'Pn_TierN': ('Tier %1', '%1단계'),
    'Pn_Breaker': ('Breaker and main switch', '차단기·메인 스위치'),
    'Pn_Trip': ('Trip', '차단기 내리기'),
    'Pn_Reset': ('Reset', '차단기 올리기'),
    'Pn_SwitchOff': ('Main switch off', '메인 스위치 끄기'),
    'Pn_SwitchOn': ('Main switch on', '메인 스위치 켜기'),
    'Pn_Overload': ('Overload', '과부하 걸기'),
    'Pn_OverloadOff': ('Take the overload off', '과부하 풀기'),
    'Pn_LogSample': ('Log samples', '기록 예시 넣기'),
    'Pn_LogClear': ('Clear the log', '기록 비우기'),
    'Pn_Window': ('Open its window', '제어반 창 열기'),
    'Pn_GoTo': ('Go to it', '제어반으로 이동'),
    'Pn_State': ('Tier %1  tripped %2  switched off %3  overloaded %4',
                 '%1단계  차단 %2  스위치 꺼짐 %3  과부하 %4'),
    'Pn_More': ('Main panel %1  zone %2  log lines %3', '주 제어반 %1  구역 %2  기록 %3줄'),
    'Pn_ZoneRooms': ('some rooms', '일부 방'),
    'Pn_ZoneWhole': ('whole building', '건물 전체'),
    'Pn_At': ('At %1, %2, %3', '위치 %1, %2, %3'),
    # power
    'Pw_Generators': ('Generators', '발전기'),
    'Pw_SpawnFull': ('Generator here, full', '발전기 놓기 (연료 가득)'),
    'Pw_SpawnLow': ('Generator here, nearly empty', '발전기 놓기 (연료 거의 없음)'),
    'Pw_Fuel': ('Fuel %1%', '연료 %1%'),
    'Pw_FuelHint': ('Fuel: every generator within 20 squares on this floor.', '연료: 이 층 20칸 안의 발전기 전부'),
    'Pw_Grid': ('Grid power', '전력망'),
    'Pw_GridOff': ('Cut the grid', '전력망 끊기'),
    'Pw_GridOn': ('Grid back on', '전력망 복구'),
    'Pw_GridNow': ('Grid power on: %1', '전력망 전기: %1'),
    'Pw_Load': ('Load %1 of %2  loss per wire %3  supplied %4', '부하 %1 / %2  전선당 손실 %3  공급 %4'),
    'Pw_FuelNow': ('Fuel %1 L/h  hours left %2  producers %3', '연료 %1 L/시간  남은 시간 %2  공급원 %3개'),
    'Pw_NoNetwork': ('No power network (power off, or no PZ Extension API).', '전력망 없음 (전기 꺼짐, 또는 PZ Extension API 없음)'),
    # solar and batteries
    'So_Noon': ('Noon', '정오'),
    'So_TwoAm': ('2:00', '새벽 2시'),
    'So_Snow': ('Snow %1%', '눈 %1%'),
    'So_SnowClear': ('Clear the snow', '눈 치우기'),
    'So_Bank': ('Batteries in the racks', '랙 배터리'),
    'So_Charge': ('Charge %1%', '충전 %1%'),
    'So_Condition': ('Condition %1', '상태 %1'),
    'So_Cold': ('Hold -10 C', '영하 10도 고정'),
    'So_ColdOff': ("The game's temperature", '게임 기온으로'),
    'So_Graphs': ('Fill the graphs', '그래프 채우기'),
    'So_Sun': ('Sunlight %1  temperature %2 C', '햇빛 %1  기온 %2도'),
    'So_Panels': ('Solar panels %1  output %2  snow %3%', '태양광 패널 %1개  출력 %2  눈 %3%'),
    'So_BankNow': ('Bank %1%  holds %2  usable %3  cold %4%  weak %5  flow %6/h',
                   '배터리 %1%  용량 %2  사용 가능 %3  추위 잠김 %4%  약함 %5개  흐름 %6/시간'),
    'So_NoBank': ('No battery bank (tier 2 and a rack with batteries).', '배터리 뱅크 없음 (2단계 이상, 배터리 든 랙 필요)'),
    # water
    'Wt_Fill': ('Water storage %1%', '물 저장소 %1%'),
    'Wt_Group': ('Add a water group', '물 그룹 추가'),
    'Wt_Spray': ('Sprinklers spray', '스프링클러 분사'),
    'Wt_MediaOut': ('Filter media used up', '필터 재료 소진'),
    'Wt_MediaNew': ('Filter media new', '필터 재료 새로'),
    'Wt_Freeze': ('Freeze the pipes', '배관 얼리기'),
    'Wt_Thaw': ('Thaw the pipes', '배관 녹이기'),
    'Wt_GridOff': ('Cut the water mains', '수도 끊기'),
    'Wt_GridOn': ('Water mains back on', '수도 복구'),
    'Wt_Hint': ('Freezing and unpurified water need their risk options on (options tab).',
                '동파와 정수 안 됨은 옵션 탭에서 위험 옵션을 켜야 합니다.'),
    'Wt_State': ('Water %1 of %2 L  groups %3  frozen %4  supplied %5', '물 %1 / %2 L  그룹 %3개  동파 %4  공급 %5'),
    'Wt_None': ('No water network (water off, or no plumbing hooks).', '물 공급망 없음 (물 꺼짐, 또는 배관 훅 없음)'),
    'Wt_Risks': ('Pipes freeze %1  pipes do not purify %2  water only from above %3',
                 '배관 동파 %1  배관 정수 안 됨 %2  위층 물만 %3'),
    'Wt_NoUnits': ('No pumps, filters or sprinklers on this panel.', '이 제어반에 펌프·필터·스프링클러가 없습니다.'),
    # devices
    'Dv_Power': ('Power', '전기'),
    'Dv_Water': ('Water', '물'),
    'Dv_Read': ('Read the devices', '기기 읽기'),
    'Dv_ConnectAll': ('Connect all', '모두 연결'),
    'Dv_DisconnectAll': ('Disconnect all', '모두 해제'),
    'Dv_Sync': ('Take in built-on rooms', '증축 방 반영'),
    'Dv_Night': ('All on the night timer', '모두 밤 타이머'),
    'Dv_Day': ('All on the day timer', '모두 낮 타이머'),
    'Dv_Always': ('All always on', '모두 항상 켜짐'),
    'Dv_Essential': ('All essential', '모두 필수'),
    'Dv_NotEssential': ('None essential', '필수 모두 해제'),
    'Dv_None': ('No devices.', '기기가 없습니다.'),
    'Dv_More': ('... and %1 more', '... 외 %1개'),
    'Dv_Incomplete': ('Some squares are not loaded: the list may be short.', '불러오지 않은 칸이 있어 목록이 덜 나왔을 수 있습니다.'),
    # options
    'Op_Now': ('Battery wear x%1  loss per wire %2', '배터리 마모 x%1  전선당 손실 %2'),
    'Op_Hint': ('Changed here, the world follows at once.', '여기서 바꾸면 바로 적용됩니다.'),
}


def write(lang, index):
    folder = ROOT / lang
    folder.mkdir(parents=True, exist_ok=True)
    table = {'IGUI_BUDev_' + k: v[index] for k, v in S.items()}
    (folder / 'IG_UI.json').write_bytes((json.dumps(table, ensure_ascii=False, indent=4) + '\n').encode('utf-8'))


write('EN', 0)
write('KO', 1)
print(len(S), 'strings')
