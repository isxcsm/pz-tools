# ETW + More Traits 조사

조사일 2026-10-08. 근거는 워크숍 페이지, 로컬에 받아 둔 ETW 14.5.0 / UCWF 2.1.1 파일, More Traits GitHub 저장소(보관됨).

## 한눈에

- **"ETW+MT"는 이제 사실상 ETW 하나다.** ETW(14.x, B42.19 이상)가 More Traits(MT)를 흡수했다. 워크숍 제목도
  "Evolving Traits World (ETW) + More Traits Continuation"이다.
- MT 워크숍 항목은 "Legacy"로 바뀌었다. B42.20용 MT에는 특성 로직이 없다. 남은 것은 `MTtoETWMigration.lua` 하나다.
  옛 MT 특성을 ETW 특성으로 바꿔 주고, 대응이 없는 특성은 그냥 지운다.
- 그래서 **MT의 일부 특성은 B42에서 사라졌다** (Scrounger, Grave Robber, Vagabond, Second Wind, Restful Sleeper,
  Evasive, Quick Worker, Battering Ram, Expert Driver 등). 이 자리는 지금 비어 있다. 우리가 강화로 가져가기 좋다.
- ETW와 MT 둘 다 **Unified Carry Weight Framework(UCWF)** 를 필수로 쓴다. 운반 한도는 이 프레임워크로 모인다.
  우리 운반 한도 강화도 UCWF가 켜져 있으면 여기에 등록해야 한다.
- ETW의 아이템 계열 특성(Well-Fitted, Lead Foot, 무기 숙련)은 **아이템 필드를 직접 덮어쓴다** (원래 값을 modData에
  저장하고 `setActualWeight`, `setStompPower` 등으로 곱한 값을 씀). 우리가 같은 필드를 쓰면 서로 원래 값을 잘못
  기억한다. 우리는 아이템 필드를 쓰지 말고 계산 시점에 보정해야 한다.

## 1. 모드 정보

| 모드 | 워크숍 | 버전 | 만든 이 | 비고 |
| --- | --- | --- | --- | --- |
| Evolving Traits World (ETW) | [2914075159](https://steamcommunity.com/sharedfiles/filedetails/?id=2914075159) | 14.5.0, `versionMin=42.19` | MusicManiac | 필수: KillCount, Moodle Framework, UCWF. 비호환: Dynamic Traits |
| ETW - Trait Sandbox (같은 항목 안의 하위 모드) | 위와 같음 | 42.19 | MusicManiac | 특성을 하나씩 끄는 샌드박스 옵션 |
| More Traits [Legacy] | [1299328280](https://steamcommunity.com/sharedfiles/filedetails/?id=1299328280) | B42.20 폴더는 이전용 껍데기 | HypnoToadTrance, Fajdek (동적 하위 모드는 MusicManiac) | "더 이상 지원, 버그 수정, 업데이트 없음". 활성 버전은 ETW |
| Unified Carry Weight Framework | [3682045254](https://steamcommunity.com/sharedfiles/filedetails/?id=3682045254) | 2.1.1, 42.19 | MusicManiac | 여러 모드의 운반 한도 보정을 한곳에 모음 |
| KillCount | [2553809727](https://steamcommunity.com/sharedfiles/filedetails/?id=2553809727) | 42.0 | - | ETW가 처치 수 판정에 씀 |
| Moodle Framework | [3396446795](https://steamcommunity.com/sharedfiles/filedetails/?id=3396446795) | 42.0 | - | ETW 무들 표시 |

문서와 소스:

- MT GitHub (2026-09 보관, 읽기 전용): <https://github.com/hypnotoadtrance/MoreTraits>
- MT 동적 특성 표 (옛 B41 시절): <https://docs.google.com/spreadsheets/d/1YM0g4fTXrDiDYuvFvNkmqEjFIaTIK4_Bb0dQvmLnIvA/edit?usp=sharing>
- ETW는 GitHub, Discord, Weblate 번역(13개 언어)을 워크숍 페이지에서 안내한다. ETW 저장소 주소는 검색으로 찾지 못했다.
- 로컬 파일: `C:\Program Files (x86)\Steam\steamapps\workshop\content\108600\2914075159` (ETW),
  `...\3682045254` (UCWF).

## 2. ETW와 MT의 관계

| 시기 | 상태 |
| --- | --- |
| B41 ~ B42 초기 | MT가 특성을 추가하고, ETW가 바닐라 특성을 동적으로 만들었다. ETW에는 MT 특성을 동적으로 표시하는 연동이 있었다 (MT 워크숍 설명). 둘을 같이 켜는 것이 "ETW+MT" 조합이었다 |
| B42.13 ~ 42.19 | MT B42판이 따로 돌았다 (멀티 동기화 수정 등) |
| B42.19 이후 (ETW 14.x) | ETW가 MT 특성 대부분을 자기 `ETW:` 특성으로 다시 구현했다. MT 42.20은 `MTtoETWMigration.lua`만 남고, ETW가 켜져 있으면 옛 특성을 ETW 특성으로 바꿔 준다 |

MT → ETW 대응 (이전 파일 기준, 43개): actionhero→Action Hero, albino→Sun Sensitivity, anemic, antigun, ascetic,
badteeth, bladetwirl→Practiced Swordsman, blissful, blunttwirl→Thuggish, bouncer, butterfingers, depressive,
fitted→Well-Fitted, glassbody→Made of Glass, gordanite→Gordonite, gourmand, gunspecialist→바닐라 Target Shooter,
gymgoer→Gym Rat, hardy, idealweight, immunocompromised, indefatigable, leadfoot, mundane, natural→Natural Eater,
noodlelegs, olympian, packmouse, packmule, paranoia, problade/problunt/progun/prospear→Prowess 넷, quickrest, quiet,
scrapper, selfdestructive, superimmune, tavernbrawler, terminator, thickblood→Thick Blooded, unwavering.

**대응 없이 지워지는 MT 특성** (B42 현재 아무 모드도 안 맡음):

| MT 특성 | 옛 효과와 수치 (MT 샌드박스 기본값) | 우리와의 관계 |
| --- | --- | --- |
| Scrounger | 처음 연 용기마다 1회 판정. 20% 확률로 그 용기가 걸리면, 물건마다 10%(음식 +10, 소모품 +10, 무기 +5) 확률로 더 나옴. 여러 개 있는 물건은 수량 ×1.3 (5개 이상은 ×2.6). 용기 modData에 굴렸다는 표시를 남김 | 우리 '운 좋은 손'과 같은 축. 빈 자리 |
| Incomprehensive | Scrounger의 반대. 10% 확률로 물건이 덜 나옴 | - |
| Grave Robber | 좀비 시체에 추가 물건 (확률 1%, 보장 1개) | 빈 자리 |
| Vagabond | 쓰레기통에서 음식 추가 (33%, 보장 1개) | 빈 자리 |
| Antique Collector | 산업용 용기에서 희귀 변형 아이템 (1/1500) | 희귀품 감과 비슷한 분위기 |
| Lucky / Unlucky | 위 루팅 확률들에 ±5씩 보정 | - |
| Evasive | 공격 33% 회피, 맞는 동작 없음 | 전투. 빈 자리지만 강함 |
| Martial Artist | 맨손 공격 피해, 짧은 둔기 기술에 비례 | 전투 |
| Second Wind | 지쳤을 때 좀비 3마리 이상 근처면 지구력·피로 회복. 대기 14일 | 능동 기술 후보 |
| Restful Sleeper | 잠잘 때 기력 빨리 회복, 나쁜 침대·바닥 페널티 없음, 다 자면 자동 기상 | 생존 수면 갈래와 같은 축. 빈 자리 |
| Quick Worker / Slow Worker | 모든 시간 행동 빠름 / 느림 (배율 옵션) | 우리 손기술 속도 노드와 같은 축 |
| Battering Ram | 전력질주 중 앞의 좀비를 넘어뜨림, 한 마리마다 지구력 소모 (체력 레벨 반영) | 능동 기술 후보 |
| Fast / Slowpoke | 이동 속도 ±15% | - |
| Expert Driver / Student Driver | 차량 속도·소음·조작 | 범위 밖 |
| Motion Sickness | 운전 중 멀미 | 범위 밖 |
| Fearful | 패닉 시 비명 | - |
| Ingenuitive, Generator Knowledge, Wildsman 등 | 레시피 해금 | 범위 밖 |
| Prepared: 음식/탄약/의료/목공/캠핑/가방/차/지도/무기 | 시작 아이템 | 범위 밖 |
| Specialization 6종 | 한 계열 +2~+8, 나머지 경험치 25% | 범위 밖 |
| Hobby/Student 6종 | 경험치 배율 없이 시작 레벨만 | 범위 밖 |
| Swift, Flexible, Grunt Worker, Tinkerer 등 | 시작 레벨 +1 | 범위 밖 |
| Amputee, Light/Heavy Drinker, Brooding 등 | 기타 | - |

## 3. ETW: 특성을 얻는 방식

- 특성은 **캐릭터 생성 때 고를 수도 있고, 플레이로 얻거나 잃을 수도 있다.** 동적을 끄면 고정 특성 모드로 쓴다.
- 대부분 **샌드박스로 조절**된다. 특성마다 켜고 끄기, 얻는 속도, 잃는 속도.
- 얻는 길은 네 종류다.
  - 기술 레벨 합: 예) Inconspicuous = 은신 7, Low Profile = 은신 4, Light Step = 가벼운 발 4, Quiet = 은신+가벼운 발 12,
    Burglar = 기계+전기+민첩 7 (기계·전기 각 2 이상), Graceful = 민첩+은신+가벼운 발, Gymnast, Hiker, Scrapper 등.
  - 처치 수 (KillCount): Eagle Eyed = 20칸 이상 거리 처치 200, Gordonite = 빠루 처치 800, Brawler, Hunter,
    용기 체계(Bravery: Cowardly 잃음 → Fear of Blood 잃음 → Pacifist 잃음 → Adrenaline Junkie → Brave →
    Desensitized 순서. 최대 진행의 10/20/30/40/60/100%).
  - 누적 카운터 "시스템": 수면(Wakeful/Sleepyhead), 치유(Fast/Slow Healer), 면역(Prone to Illness → Resilient →
    Super-Immune), 식사·갈증(31일 평균), 식중독(Iron Gut/Weak Stomach), 청각(민첩+전투 레벨로 Keen Hearing),
    **Cat Eyes**(어두운 칸을 본 양으로 바닐라 Night Vision), **운반 무게**(분마다 들고 있는 무게/최대 무게를 더함.
    33%에서 Pack Mouse 잃음, 66%에서 Hoarder, 100%에서 Pack Mule), **인벤토리 옮기기**(옮긴 무게와 개수로
    Disorganized/Organized, All Thumbs/Dextrous, Butterfingers), 장소 공포(Agoraphobic/Claustrophobic),
    정신 상태(Blissful/Depressive), Outdoorsman(날씨 노출), Asthmatic(추운 날 달리기), Smoker, Pain Tolerance(통증 누적),
    Olympian(달리기 분 2880), 체중(Ideal Weight).
  - 행동 횟수: Herbalist(약초 채집), Natural Eater(날음식 먹기), 수리(Restoration Expert), 차 수리, 가구 등.
- **지연 특성 체계**: 조건을 채워도 바로 붙지 않는다. 기본 336시간 안에서 매시간 1/남은시간 확률로 붙는다.
- **친화 체계**: 시작할 때 고른 특성은 얻기 쉽고 잃기 어렵다 (배율 옵션).
- ETW 전용 캐릭터 정보 탭(단축키)에서 각 카운터를 막대로 보여 준다.
- 바닐라 특성 약 70개를 동적으로 다룬다 (위 시스템들). 우리와 겹치는 바닐라 축: Night Vision, Keen Hearing /
  Hard of Hearing, Eagle Eyed, Organized/Disorganized, Dextrous/All Thumbs, Inconspicuous/Conspicuous, Graceful/Clumsy,
  Burglar, Fast/Slow Healer, Resilient/Prone to Illness, Thick/Thin Skinned, 식사·수면·갈증 특성, Outdoorsman.

## 4. ETW 특성 전체 (85개)

비용 양수는 장점, 음수는 단점. 수치는 샌드박스 기본값.

### 운반·무게·손

| 특성 | 비용 | 효과 | 건드리는 곳 |
| --- | --- | --- | --- |
| Pack Mule | 7 | 최대 운반 한도 ×1.5 | UCWF max 배율 |
| Hoarder | 4 | 힘 1당 운반 한도 +0.5 | UCWF max 더하기 |
| Pack Mouse | -7 | 힘 1당 운반 한도 -0.5 | UCWF max 더하기 |
| Well-Fitted | 4 | 입은 옷 무게 50% 감소, 옷의 달리기·전투 속도 페널티 75% 제거 | 입은 옷마다 `setActualWeight`, `setRunSpeedModifier`, `setCombatSpeedModifier`를 직접 씀 (원래 값을 modData에 저장, 벗으면 되돌림) |
| Butterfingers | -12 | 들고 이동하면 손의 물건을 떨어뜨림 (무게·달리기에 비례). 옮긴 물건마다 5% 확률로 바닥에 떨어뜨림 | `ISInventoryTransferAction:playTransferCompleteSound` 감쌈 |
| Deprived | -6 | 속옷·티·운동화·쓰레기봉투·열쇠고리로 시작. 운반 한도의 50% 넘게 들면 불행 증가 | 시작 아이템, 불행 |

### 체력·지구력·상처·질병

| 특성 | 비용 | 효과 |
| --- | --- | --- |
| Hardy | 6 | 지구력 99% 넘으면 숨은 예비분(최대 25%)에 쌓고, 85% 밑이면 꺼내 씀 |
| Quick Rest | 3 | 앉거나 가구에서 쉴 때 지구력 회복 ×2 |
| Olympian | 5 | 달리기·체력 +1 (Jogger, Unfit와 배타) |
| Indefatigable | 10 | 체력이 낮아지거나 1.5칸 안에 좀비 4마리면 체력·지구력 회복, 피로 제거, 2.5칸 안 좀비 넘어뜨림. 2분(실시간) 통증·상처 이동 페널티 무시. 횟수 기본 무제한, 대기일 옵션 |
| Unwavering | 6 | 낮은 지구력·피로·통증으로 인한 무기 피해 감소가 훨씬 적음. 상처로 인한 이동 페널티 감소 |
| Thick Blooded | 4 | 지혈 안 된 출혈 부위마다 분당 체력 0.15 회복 (머리·목 2배) |
| Anemic | -4 | 출혈로 체력이 더 빨리 깎임 |
| Strong Bones | 4 | 골절이 덜 심하고 빨리 나음 (골절 시간 ×0.5) |
| Brittle Bones | -4 | 골절 시간 ×2 |
| Made of Glass | -10 | 체력 손실 증폭, 큰 충격에 무작위 부위 긁힘·골절 |
| Pain Tolerance | 2 | 통증이 60% 넘게 오르지 않음 |
| Super-Immune | 16 | Knox 감염, 상처 감염, 감기, 질병 면역 |
| Immunocompromised | -10 | 상처 감염이 빨리 악화, 좀비 상처마다 Knox 감염 확률 (전파 꺼도) |
| Injured | -3 | 중간 상처로 시작. 그 부위 상처가 한 단계씩 더 심해짐 |
| Broken Leg | -4 | 부목 댄 다리 골절로 시작 |
| Burn Ward Patient | -6 | 온몸 화상으로 시작, 이후 화상 2배 오래 감 |
| Noodle Legs | -6 | 달리기·전력질주 중 넘어짐. 달리기·민첩 레벨로 확률 감소 |
| Sun Sensitivity | -5 | 낮에 밖에 있으면 두통. 우산으로 줄어듦 |
| Ideal Weight | 4 | 체중이 78~82kg 쪽으로 끌림 (칼로리 배율) |
| Self-Destructive | -4 | 불행이 크면 체력이 떨어짐 |

### 정신·기분·날씨

| 특성 | 비용 | 효과 |
| --- | --- | --- |
| Blissful | 3 | 불행·지루함이 빨리 사라짐 |
| Depressive | -4 | 가끔 큰 불행 발작 |
| Paranoia | -6 | 움직일 때 가짜 좀비 공포. 패닉·스트레스 급증, 25% 확률로 비명 → **50칸 안 좀비를 끎** (`addSound`) |
| Bloodlust | 4 | 좀비 처치 시 행복, 스트레스·패닉 감소 (게이지 최대 300%) |
| Pet Therapy | 3 | 동물 쓰다듬으면 기분 5% 회복 (5분 대기) |
| Pluviophile / Pluviophobia | 2 / -2 | 비 맞으면 기분 좋아짐 / 나빠짐 (우산이면 절반) |
| Homichlophile / Homichlophobia | 1 / -1 | 안개 속에서 차분 / 불안 (상한 50%) |
| Cold-Loving / Cold-Averse | 2 / -2 | 체온 36.5℃ 밑에서 스트레스·불편 감소 / 증가 |
| Heat-Loving / Heat-Averse | 2 / -2 | 체온 37.5℃ 위에서 같은 방식 |
| Heavy Dresser / Light Dresser | 1 / -1 | 옷을 많이/적게 입으면 기분 좋음 |
| Pyromania / Pyrophobia | 2 / -2 | 12칸 안 불이 패닉·불행을 낮춤 / 높임 |
| TV Junkie | -4 | 하루에 TV를 못 보면 지루함·불행 증가 |
| Ascetic | -6 | 단순한 음식·딱딱한 잠자리를 좋아하고 TV·만화가 소용없음, 지루함·불행이 천천히 줄어듦 |
| Alcoholic (Mild/Moderate/Severe) | -2/-4/-8 | 금단 증상 (스트레스, 메스꺼움, 두통, 손떨림으로 물건 떨어뜨림 등) |

### 음식

| 특성 | 비용 | 효과 |
| --- | --- | --- |
| Gourmand | 4 | 요리 빨리 되고 덜 탐, 직접 만든 음식 효과 증가 |
| Natural Eater | 4 | 가공 안 된 자연 음식이 정신 스탯 회복 (최대 5%) |
| Fast Eater / Slow Eater | 1 / -1 | 먹는 시간 감소 / 증가 (% 옵션) |
| Bad Teeth | -3 | 먹을 때 두통 |
| Home Cook | 2 | 요리 +1 |

### 전투 (우리 범위 밖, 참고용)

| 특성 | 비용 | 효과 |
| --- | --- | --- |
| Action Hero | 8 | 주변 좀비 없으면 피해 절반, 10칸 안 좀비 수와 거리에 따라 피해·치명 증가 |
| Bouncer | 5 | 1.75칸 안에 좀비 3마리 이상이면 틱마다 5% 확률로 가장 가까운 좀비 비틀거리게 함 |
| Lead Foot | 2 | 밟기 위력 = 신발 밟기 위력 ×2 + 1 (신발에 `setStompPower` 직접 씀) |
| Gordonite | 6 | 빠루 피해·속도·치명 증가 (장둔기·힘 레벨당) |
| Prowess Blade / Blunt / Spear | 9 / 7 / 7 | 해당 무기 피해 +20%, 내구 소모 감소, 기술 레벨로 치명 증가 |
| Prowess Guns | 7 | 총 내구 소모 감소 |
| Terminator | 14 | 총 피해·조준·사거리 증가, 걸림 감소, 조준 중 패닉·스트레스 감소 |
| Tavern Brawler | 3 | 임시 무기 피해 증가, 내구 소모 감소 |
| Mundane | -9 | 치명타 없음 |
| Anti-Gun Activist | -6 | 총 조준 느리고 사거리 짧음, 기분 나빠짐, 경험치 -25% |
| Practiced Swordsman, Thuggish, Blade Enthusiast, Knife Fighter, Stick Fighter, Polearm Fighter, Axe Thrower, Gun Enthusiast | 3~6 | 해당 무기 시작 레벨 +1~2 |

### 기술·경험치 (범위 밖)

Quiet(은신+가벼운 발 +1), Light Step(가벼운 발 +1), Low Profile(은신 +1), Scrapper(용접·정비·대장장이 +1),
Restoration Expert(수리 횟수 페널티를 확률로 면제), Body Work Enthusiast, Furniture Assembler, AV Club, Gym Rat /
Gym Hater / Couch Potato(운동 경험치 ×2 / ×0.5).

## 5. 바닐라 시스템별 겹침 (우리 쪽 호환 위험)

| 시스템 | ETW가 하는 일 | 우리 강화 | 위험 | 대응 |
| --- | --- | --- | --- | --- |
| 최대 운반 한도 | UCWF가 `setMaxWeightBase`(8 + 더하기)와 `setMaxWeightDelta`(배율)를 직접 씀. 매시간·생성 시 다시 계산. **기본으로 50 상한** (`CapWeight=true`) | 운반 한도 | 높음. 우리가 delta나 base를 직접 쓰면 UCWF가 다음 계산에 덮어쓰거나, 우리 값을 "원래 값"으로 보고 다시 곱함 | UCWF가 있으면 `UnifiedCarryWeightFramework.registerMaxModifier{ id, resolve=function(ctx) return {add=..} end }`로 등록하고 노드 변경 시 `recomputeAll(player)` 호출. 없으면 우리가 직접. 50 상한이 우리 강화를 잘라 먹을 수 있음을 툴팁에 알림 |
| ETW 운반 무게 시스템 | 분마다 (들고 있는 무게 / 최대 한도)를 카운터에 더해 Hoarder·Pack Mule을 줌 | 운반 한도 | 낮음. 우리 한도가 늘면 비율이 줄어 ETW 진행이 느려짐 | 알고만 있으면 됨 |
| 입은 옷 무게 | Well-Fitted가 입은 옷 `ActualWeight`를 원래 값 ×0.5로 덮어씀 | 입은 것 | 높음. 같은 축. 우리가 필드를 쓰면 원래 값이 꼬임 | 노드를 빼거나, 필드를 쓰지 않고 무게 계산 시점에만 곱하기 |
| 옮기기 행동 | Butterfingers가 옮기기 완료 함수를 감쌈. 인벤토리 옮기기 시스템이 옮긴 무게·개수를 셈 | 줍기·옮기기 속도, 자동 담기, 한꺼번에 털기 | 중간 | 자동 담기도 바닐라 `ISInventoryTransferAction`으로 처리해서 ETW 카운터와 Butterfingers가 그대로 돌게 함. 속도는 시간에 배율만 |
| 밟기 | Lead Foot이 신발 `StompPower`를 덮어씀 | 밟기 | 높음 | 우리 밟기는 신발 필드를 쓰지 말고 피해 이벤트에서 배율 |
| 골절 | Strong/Brittle Bones가 골절이 생길 때 `setFractureTime`에 배율 | 골절 회복 | 중간. 둘 다 곱하면 겹쳐 곱해짐(의도라면 괜찮음), 같은 틱에 쓰면 순서 문제 | 시작 시점 곱하기 대신 시간마다 조금씩 줄이는 방식 |
| 출혈 | Thick Blooded는 분당 체력 되돌림, Anemic은 더 깎음 | 출혈 감소 | 낮음 (방식이 다름) | 배율로 쌓기 |
| 통증 | Pain Tolerance가 통증을 60%에서 자름 | 통증 | 낮음 | 상한 말고 페널티 배율로 |
| 감염·질병 | Super-Immune 완전 면역, 면역 체계 | 감염 확률, 감기 저항 | 중간. 영역이 겹침 | 확률 감소는 작게, "면역"은 만들지 않기 |
| 지구력 | Hardy 예비분, Quick Rest 앉아서 ×2, Indefatigable 회복 | 지구력 소모·회복, 아드레날린 | 중간 | 예비분 방식과 앉기 배율은 피하고 소모 감소·서 있을 때 회복 위주 |
| 포위 대응 | Bouncer 자동 밀치기, Indefatigable 포위 시 넘어뜨리기 | 넘어짐 저항, 아드레날린 | 중간 | 우리 쪽은 "넘어지지 않음"만, 밀치기는 넣지 않기 |
| 감각 | Cat Eyes(Night Vision), 청각 시스템(Keen Hearing), Eagle Eyed를 동적으로 줌 | 밤눈, 소리 사다리, 시야 보정 | 낮음. 바닐라 특성 축 위에 얹는 방식이면 문제없음 | 배율로 쌓기 |
| 좀비 끌기 | Paranoia가 서버에서 `addSound(player, x, y, z, 50, 50)`으로 비명 (반경 50, 볼륨 50) | 함성 | 없음 (오히려 구현 근거) | 같은 바닐라 함수 사용 가능 |
| 패닉·스트레스 | 많은 특성이 `stats:set(PANIC/STRESS, 현재 + 값)` | 패닉·스트레스 | 낮음 | 우리도 현재 값 기준 증감만 |
| 식사 | Fast Eater가 먹는 시간 감소 | (후보 없음) | - | 먹는 속도 노드는 만들지 않기 |
| 수면 | 수면 시스템(Wakeful/Sleepyhead), Ascetic의 침대 품질 뒤집기(`getBedQuality` 감쌈) | 피로·수면 | 낮음 | 침대 품질 함수는 건드리지 않기 |

## 6. 강화 아이디어

표시: **●** 겹침 큼 (빼거나 크게 바꿀 것), **◐** 같은 축 (배율로 쌓으면 됨), **○** 빈 자리.

### 수색

| 아이디어 | 효과 (찍을수록) | 겹침 |
| --- | --- | --- |
| 첫 손길 | 처음 연 용기에서 물건이 더 나옴. 확률과 수량 배율이 커짐. 옛 MT Scrounger 방식(용기 1회 판정, modData 표시)이 참고가 됨. IDEAS의 '운 좋은 손'과 합칠 수 있음 | ○ (MT 삭제로 빈 자리) |
| 시체 털이 | 좀비 시체에서 추가 물건이 나올 확률. 상위 단계는 1개 보장 | ○ (MT Grave Robber 삭제) |
| 쓰레기통 감각 | 쓰레기통·쓰레기 더미에서 먹을 것이 더 나옴 | ○ (MT Vagabond 삭제) |
| 골동품 눈 | 아주 낮은 확률로 상태 좋은 희귀 변형 물건 (무기 내구 높음 등) | ○ |
| 빠른 손 | 분해·따기·뒤지기 같은 수색 행동 시간 감소. 모든 행동이 아니라 수색 행동만 | ○ (MT Quick Worker 삭제. 범위를 좁혀 안전) |
| 어둠 적응 | 밤눈 보정 | ◐ ETW Cat Eyes가 바닐라 Night Vision을 줌 |
| 소리 사다리 | 소리 방향·거리 표시 | ◐ ETW 청각 시스템 (Keen Hearing) |
| 먼 눈 | 시야 보정 거리 | ◐ ETW Eagle Eyed |
| 빠루 따기 | 빠루로 문 따기 (비전투) | ○ ETW Gordonite는 빠루 전투뿐. 빠루 피해 보너스는 넣지 말 것 |

### 운반

| 아이디어 | 효과 | 겹침 |
| --- | --- | --- |
| 운반 한도 | 최대 운반 무게 증가 | ● Pack Mule ×1.5 / Hoarder / Pack Mouse. UCWF로 등록하면 같이 쌓임. UCWF 50 상한 주의 |
| 입은 것 | 입은 옷 무게 감소 | ● Well-Fitted 50% (필드 덮어쓰기). 빼거나 "매단 것"만 남기기 |
| 단단한 손 | 맞거나 넘어질 때 손의 물건을 놓치지 않음. 놓친 물건을 자동으로 다시 집는 확률 | ◐ Butterfingers의 반대 축. ETW 내부 확률은 못 건드리니 "다시 집기"로 만들면 안전 |
| 정리 솜씨 | 옮기기 속도 증가 | ◐ 바닐라 Organized·Dextrous (ETW가 옮기기 양으로 동적으로 줌). 시간 배율로 쌓기 |
| 짐꾼 걸음 | 과적일 때 이동·지구력 페널티 감소 | ○ (ETW Deprived는 기분만, Made of Glass 옛 MT판은 과적 피해) |
| 차 짐 싣기 | 트렁크 싣고 내리기 속도 | ○ |

### 생존

| 아이디어 | 효과 | 겹침 |
| --- | --- | --- |
| 단잠 | 나쁜 침대·바닥 페널티 감소, 잠 회복 빠름, 다 자면 자동으로 깸 | ○ (MT Restful Sleeper 삭제). ETW Ascetic의 침대 뒤집기와 함수 겹침 없게 |
| 숨 고르기 | 서서 멈춰 있을 때 지구력 회복 증가 | ◐ Quick Rest는 앉을 때 ×2. 우리는 서 있을 때로 갈라 놓기 |
| 지혈 | 출혈 속도 감소 | ◐ Thick Blooded / Anemic |
| 뼈 다지기 | 골절 회복 빨라짐 | ◐ Strong/Brittle Bones. 시간마다 줄이는 방식으로 |
| 참을성 | 통증 페널티 감소 | ◐ Pain Tolerance (상한 방식과 다르게) |
| 감염 저항 | 상처 감염 확률 감소 | ● Super-Immune, 면역 시스템. 작게만 |
| 버티기 | 좀비에게 밀려 넘어질 확률 감소 | ◐ Bouncer와 다름 (우리는 밀치지 않음) |
| 밟기 | 쓰러진 좀비 밟기 피해 | ● Lead Foot. 신발 필드 쓰지 말 것 |
| 마음 다잡기 | 패닉·스트레스가 빨리 가라앉음 | ◐ Blissful, 날씨 특성들 |

### 능동 기술

| 아이디어 | 효과 | 겹침 |
| --- | --- | --- |
| 함성 | 큰 소리로 넓은 범위 좀비를 끎 | ○ ETW Paranoia가 바닐라 `addSound`로 50칸 비명을 냄. 구현 근거로 씀 |
| 두 번째 숨 | 누르면 지구력과 피로 일부를 즉시 회복. 대기시간 김 (옛 MT는 14일). 찍을수록 회복량 증가, 대기 감소 | ○ (MT Second Wind 삭제). ETW Indefatigable(자동 발동)과는 수동·자동으로 갈림 |
| 돌파 질주 | 몇 초간 전력질주하며 앞의 좀비를 넘어뜨림. 넘어뜨릴 때마다 지구력 소모 | ○ (MT Battering Ram 삭제). 전투에 가까움 |
| 숨죽이기 | 잠깐 발소리와 행동 소음이 거의 0 | ◐ ETW Quiet·Light Step은 기술 레벨만 줌. 겹침 작음 |
| 마지막 버팀 | 누르면 몇 초간 통증·상처 이동 페널티 무시 | ● Indefatigable의 2분 효과와 같음. 넣는다면 짧고 대기 길게 |

## 7. 만들 때 지킬 것 (이 조사에서 나온 규칙)

1. 운반 한도는 UCWF가 있으면 UCWF에 등록한다. 직접 `setMaxWeightDelta`/`setMaxWeightBase`를 쓰지 않는다.
2. 아이템 필드(`ActualWeight`, `StompPower`, 무기 피해·속도)를 쓰지 않는다. ETW가 같은 필드에 원래 값 저장·복원
   방식을 쓰고 있다.
3. 자동 담기, 한꺼번에 털기는 바닐라 옮기기 행동으로 처리한다. 그래야 ETW 옮기기 카운터와 Butterfingers가 맞게 돈다.
4. 스탯은 현재 값에 더하거나 곱한다. 고정값으로 덮어쓰지 않는다.
5. 바닐라 특성 축(Night Vision, Keen Hearing, Organized, Dextrous 등)은 ETW가 동적으로 붙였다 뗐다 한다. 우리 효과가
   특성 유무를 가정하면 안 된다. 매번 현재 특성을 보고 그 위에 배율을 얹는다.

## 출처

- ETW 워크숍: <https://steamcommunity.com/sharedfiles/filedetails/?id=2914075159>
- ETW 변경 기록: <https://steamcommunity.com/sharedfiles/filedetails/changelog/2914075159> (이번엔 429로 못 읽음)
- More Traits [Legacy] 워크숍: <https://steamcommunity.com/sharedfiles/filedetails/?id=1299328280>
- More Traits GitHub: <https://github.com/hypnotoadtrance/MoreTraits> (`Contents/mods/More Traits/42.20/media/lua/shared/MTtoETWMigration.lua`,
  `media/lua/client/MoreTraits.lua`, `media/sandbox-options.txt`, `media/lua/shared/Translate/EN/UI_EN.txt`)
- UCWF 워크숍: <https://steamcommunity.com/sharedfiles/filedetails/?id=3682045254>
- 로컬 ETW 14.5.0: `media/registries.lua`, `media/scripts/ETW_Traits.txt`, `media/sandbox-options.txt`,
  `common/media/lua/shared/Translate/EN/UI.json`, `Sandbox.json`, `lua/server/ETW_UCWF.lua`,
  `lua/shared/TraitsLogic/ETW_ItemTraits.lua`, `lua/client/TimedActions/ETW_ISInventoryTransferActionOverrideClient.lua`,
  `lua/server/TraitsLogic/ETW_MentalTraits.lua`
- 로컬 UCWF 2.1.1: `media/lua/shared/UnifiedCarryWeightFramework.lua`, `media/sandbox-options.txt`
