# 생존·능력 계열 워크숍 모드 조사

[IDEAS.md](../IDEAS.md)의 생존 트리와 능동 기술 브레인스토밍용. 2026-10-08에 Steam 워크숍 검색과 Steam API의 모드 설명으로 조사했다.

- 모드 94개를 정리했다 (같은 모드의 멀티판 링크 제외). 아이디어 118개를 뽑았다.
- B42 표시: `B42` B42 페이지가 있음, `B41` B41만, `B41/42` 둘 다. 구독자 수는 조사 시점 값이다.
- 거르지 않고 모았다. 바닐라 특성이나 신뢰도 보상과 겹치는 것도 넣고 표시만 했다.

## 1. 모드 목록

### 1-1. 성장 체계 (스킬 트리, 특성 성장)

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [RPGSkillTree](https://steamcommunity.com/sharedfiles/filedetails/?id=3621388762) (MP판 [3628753926](https://steamcommunity.com/sharedfiles/filedetails/?id=3628753926)) | B42 | 좀비 처치 XP로 레벨업, 레벨마다 스킬 포인트 1. 고유 스킬 76개. 다 찍으면 XP로 랜덤 상자 구매. 초기화 포인트 따로. 한국어 지원, 2만 구독 | 처치가 곧 성장. 트리를 다 찍은 뒤에도 XP 쓸 곳(랜덤 상자)을 남겼다 |
| [Traits Purchase System](https://steamcommunity.com/sharedfiles/filedetails/?id=3211693903) | B41/42 | 처치·스킬 레벨업으로 특성 XP. 90 XP마다 레벨, 최대 30. 좋은 특성 사거나 나쁜 특성 제거. 9만 구독 | 나쁜 특성을 돈 주고 지우는 재미. 후반 목표가 생긴다 |
| [Evolving Traits World (ETW)](https://steamcommunity.com/sharedfiles/filedetails/?id=2914075159) | B42 | 특성 85개. 행동으로 특성을 얻고 잃음. 지연 특성(시간마다 확률 굴림), 친화도(시작 특성 유지), 처치로 차는 혈기 게이지(최대 300%). More Traits 후속. 24만 구독 | 내가 한 행동이 몸에 남는다. 게이지가 보인다 |
| [Dynamic Traits and Expanded Moodles](https://steamcommunity.com/sharedfiles/filedetails/?id=2459400130) | B41/42 | 특성 동적 변화, 중독, 알레르기 무들, 극도 피로 4단계에서 기절, 심한 과적 골절, 상처·감기 병. 40만 구독 | 무들이 실제 결과를 낸다. 겁주는 대신 결과로 가르친다 |
| [Traits As Skills](https://steamcommunity.com/sharedfiles/filedetails/?id=3784847437) | B42 | 특성을 XP 바가 있는 스킬처럼. 좀비 처치마다 용기 +5 XP 등. 겁쟁이 → 보통 → 용감 순으로 오름 | "퇴보 없이 성장만" 원칙. 바가 보여서 진행이 느껴진다 |
| [Toughness Skill](https://steamcommunity.com/sharedfiles/filedetails/?id=3545533939) | B41/42 | 새 생존 스킬 '강인함'. 레벨마다 패닉 -10%, 통증 -5%, 불편 -5%, 불편 무시 기준 +10%. 처치로 XP(약 4450킬에 만렙). 9.5만 구독 | 레벨당 수치가 표로 정확하다. 찍을 때마다 커지는 노드의 좋은 본보기 |
| [Efficiency Skill Mod 2](https://steamcommunity.com/sharedfiles/filedetails/?id=3374408921) | B42 | '효율' 스킬. 레벨마다 시간 걸리는 동작이 빨라짐. 9.5만 구독 | 모든 동작 속도라는 넓은 축 하나 |
| [Combat Mastering Skill](https://steamcommunity.com/sharedfiles/filedetails/?id=3435985650) | B42 | 전투 숙련 스킬. 공격 속도 0.4~2.0배, 피해 0.2~3.0배. 만렙이면 피로에도 계속 싸움 | 레벨 차이가 눈에 확 보인다 (전투라 참고만) |
| [Character Evolution](https://steamcommunity.com/sharedfiles/filedetails/?id=3780794906) | B42 | 조건을 채우면 특성 변화를 "제안". 수락, 보류, 거절 가능. 금연, 보청기 등 | 강해지는 것도 플레이어가 고른다 |
| [Become Desensitized (B42.20 비공식)](https://steamcommunity.com/sharedfiles/filedetails/?id=3738669352) | B42 | 500킬부터 둔감 특성 확률, 2000킬이면 확정. 자정에 굴림. 9.6만 구독 | 오래 살아남은 보상 |
| [Dynamic Panic](https://steamcommunity.com/sharedfiles/filedetails/?id=3749784911) | B42 | 킬 수로 겁쟁이 제거 → 용감 → 둔감 사다리 | 단계형 사다리 |
| [Genetic Mutation](https://steamcommunity.com/sharedfiles/filedetails/?id=3246387988) | B41 | 7일 살아남으면 무작위 좋은 유전자 1개 + 나쁜 것 0~2개 | 복권 같은 한 방 |
| [Mutation Survivor](https://steamcommunity.com/sharedfiles/filedetails/?id=3791757322) | B42 | 변이 특성 14개. 흡혈귀(시체 피로 배고픔·갈증·피로·패닉 회복+1시간 혈광), 곰 힘(30킬마다 광폭), 바퀴벌레 몸(식중독 면역), 개미왕(운반 +100%), 벌꿀오소리(공포·통증 면역), 늑대인간(20~6시 강화), 유리뼈, 빛 공포 등 | 강한 힘에 분명한 약점이 붙는다 |
| [X-Virus](https://steamcommunity.com/sharedfiles/filedetails/?id=3673979113) | B42 | 주사하면 감염되지만 변이: 넓은 시야, 용감, 빠른 독서 등 | 감염을 대가로 힘을 산다 |

### 1-2. 초능력·능동 기술

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [Psionic Awakening](https://steamcommunity.com/sharedfiles/filedetails/?id=3749671906) | B41/42 | 사이 포인트로 쓰는 능력들. 원거리 머리 부수기, 감지(벽 너머 30칸, 고정 표식), 본능(뒤에서 오는 좀비 자동 처치), 물건 찾기(금색 표시), 창문→문→벽 부수기, 넘어뜨리기 충격, 위치 표식, 바닥 물건 끌어오기, 문·창문 닫고 보강, 원격 손, 좀비 꼭두각시, 명상, 감염 정화. 사이가 모자라도 억지로 쓸 수 있고 모자란 만큼 '긴장'이 쌓임. 긴장이 차면 피로·스트레스·환청·악몽, 최대면 비명(주변 문 깨짐, 좀비 사망, 큰 소음, 기절 또는 사망). 단축키와 원형 메뉴 | 이번 조사에서 가장 쓸 게 많다. 대기시간 대신 "무리해서 쓰기"라는 선택이 있다 |
| [Z'Ware Telekinesis](https://steamcommunity.com/sharedfiles/filedetails/?id=3777815698) | B42 | 밀기, 내려찍기, 당기기, 던지기, 원뿔, 고정, 충격파, 일괄 압살. 숙련 5단계에 사거리 6→25칸. 대가로 음식·물 요구량 +30%, 숙련할수록 +5%까지 줄어듦. 시전마다 지구력·배고픔·갈증 소모 | 대기시간 없이 **신진대사**로 값을 치른다 |
| [Z'Ware Pyrokinesis](https://steamcommunity.com/sharedfiles/filedetails/?id=3777803804) | B42 | 불꽃 능력 8개. F7은 가장 가까운 좀비에 자동 조준, F8은 대상 고정, F9는 능력 순환. 사거리 5→25칸 | 전투 중에 클릭 조준이 어렵다는 문제를 키 세 개로 풀었다 |
| [Z'Ware Dead Frequency](https://steamcommunity.com/sharedfiles/filedetails/?id=3777124729) | B42 | 능력을 켜 두면 **바닐라 함성 키(Q)**가 주변 좀비를 죽이는 목소리가 된다 | 새 키 없이 바닐라 동작을 강화한다 |
| [Z'Ware Meteorfall](https://steamcommunity.com/sharedfiles/filedetails/?id=3783065820) | B42 | 운석 소환. 이 능력으로 죽인 수만큼 숙련. 사거리, 개수(1→5), 반경, 대기시간(9초부터)이 단계별로 좋아짐. 신진대사 추가 소모 +30% | 숙련 단계별 수치표가 분명하다 |
| [Monkey's Electromancer Trait](https://steamcommunity.com/sharedfiles/filedetails/?id=2988892511) | B41 | 번개 연쇄. 초급/숙련 특성. 숙련은 '은신' 능력으로 무리를 밀고 지나감. 지구력 소모 | 연쇄 확률이라는 손맛. 무리가 크면 CPU 부담 경고 |
| [EXO Modular Upgrade](https://steamcommunity.com/sharedfiles/filedetails/?id=3707680432) | B42 | 외골격 3갈래: 전투(점프·회피, 화염), 중장(동작 속도 Lv3, 대량 운반 Lv3, 큰 배터리, 방패, 충격 일격), 정찰 | 장비지만 갈래 구조가 트리와 같다 |
| [Project Parkour](https://steamcommunity.com/sharedfiles/filedetails/?id=3783989538) | B42 | 파쿠르 스킬. 창문 다이빙, 방향 회피, 자유 점프(서서 2칸, 뛰며 3칸, 질주 4칸). 모두 지구력 소모, 숙련으로 해금. 1.7만 구독 | 이동 자체가 능력이 된다 |
| [Strike From Above](https://steamcommunity.com/sharedfiles/filedetails/?id=3391928681) | B42 | 높은 곳에서 웅크린 채 아래 좀비에게 뛰어내려 처치. 주변 좀비는 넘어지거나 나를 알아챔. 자기 피해 가능 | 낙하를 무기로 바꾼다 |
| [Flying Kick](https://steamcommunity.com/sharedfiles/filedetails/?id=3800912022) | B42 | 날아차기. 넘어뜨림, 지구력 소모, 대기시간 | 짧은 대기시간 능동기의 표본 |
| [BackOff!](https://steamcommunity.com/sharedfiles/filedetails/?id=3647810515) | B42 | 힘 6 이상이면 밀치기가 여러 좀비를 넘어뜨림. 맨손이 가장 잘 됨 | 질주 좀비 대응 |
| [Better Push](https://steamcommunity.com/sharedfiles/filedetails/?id=3715137752) | B42 | 밀치기가 도미노처럼 뒤 좀비들까지 차례로 넘어뜨림. 힘에 따라 확률·개수 증가. 4.7만 구독 | 0.6초 간격으로 넘어지는 연출 |

### 1-3. 위장·냄새·유인

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [Zombie Camouflage - Build 42](https://steamcommunity.com/sharedfiles/filedetails/?id=3742518185) | B42 | 시체 피를 바름. 4단계(무들 색: 호박→노랑→라임→초록), 단계마다 들키는 거리 약 3.5→2.6→1.8→1.1칸. 피 묻은 옷을 벗으면 한 단계 내려감. 씻기·비로 사라짐. 소음 낸 뒤 좀비가 빨리 관심을 잃음. B42 새 은신 시스템을 꺼야 한다고 안내 | 단계가 색으로 보이고, 단계마다 거리가 분명하다 |
| [Braven's Camouflage Reworked](https://steamcommunity.com/sharedfiles/filedetails/?id=3739612285) | B42 | 시체 내장 바르기. 너무 가까이 오래 있으면 좀비의 **의심**이 쌓임. 닿으면 들킴. 좀비 걸음 토글 | 의심 게이지가 긴장을 만든다 |
| [Zombie Camouflage - Playing Dead](https://steamcommunity.com/sharedfiles/filedetails/?id=3785104069) | B42 | 시체 잔해로 만든 약을 마시면 1시간 위장. 끝나면 패닉·스트레스. 24시간에 3번 넘게 마시면 병. 싸우면 즉시 풀림 | 반복 사용 벌칙이 분명하다 |
| [Invisible to the Herd](https://steamcommunity.com/sharedfiles/filedetails/?id=3810203255) | B42 | 월드워Z처럼 병든 몸은 무시당함. 병원체 주사로 18시간 위장, 대신 체력 25%·지구력 거의 0. 두 번 맞으면 비명 후 좀비화. 질주 좀비는 항상 냄새로 찾음 | 위장 강도와 몸 상태를 맞바꾼다 |
| [Sense of Smell](https://steamcommunity.com/sharedfiles/filedetails/?id=3018798678) | B41/42 | 좀비가 냄새를 맡는다. 숨, 땀, 상처, 먹고 마시기. 지나간 자리에 냄새 흔적 노드가 남아 소리 없는 신호를 냄. 차와 건물이 냄새를 가림, 비·눈이 지움. 냄새 측정기 | 냄새가 눈에 보이는 수치가 된다 |
| [ROT — Zombie Scent System](https://steamcommunity.com/sharedfiles/filedetails/?id=3783804220) | B42 | 시체, 썩은 고기, 피가 냄새를 내 좀비를 끈다. 썩은 햄을 던져 미끼로. 출혈 중이면 핏자국 냄새 길을 좀비가 따라옴 | 쓰레기가 미끼가 된다. 페로몬 아이디어와 바로 이어진다 |
| [Enhanced Noise Maker](https://steamcommunity.com/sharedfiles/filedetails/?id=3787102653) / [Advanced Noise Makers](https://steamcommunity.com/sharedfiles/filedetails/?id=3793689832) | B42 | 소음기 범위 17→150칸, 지속 2일 / 확성기 붙인 소음기 52칸 | 바닐라 유인 수치의 기준점 |
| [Zombies Hear Your Microphone](https://steamcommunity.com/sharedfiles/filedetails/?id=3004111200) | B41/42 | 마이크 음성을 좀비가 들음. 9만 구독 | 내 목소리가 소음이 된다 (함성의 극단) |

### 1-4. 감염·치료·좀비 설정

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [The Only Cure](https://steamcommunity.com/sharedfiles/filedetails/?id=3580276809) | B42 | 감염된 팔을 톱으로 자름. 붕대·지혈대로 생존률 증가. 아문 뒤 의수. 25만 구독 | 끔찍한 선택지가 희망이 된다 |
| [They Knew \[B42\]](https://steamcommunity.com/sharedfiles/filedetails/?id=3387110070) | B42 | 정화 흡입제(감염 제거), 예방약(24시간 감염 무시), 리셋약(감염 진행 초기화). 21만 구독 | 예방·지연·치료가 다른 약이다 |
| [Zombie Virus vaccine](https://steamcommunity.com/sharedfiles/filedetails/?id=2685680439) | B41 | 실험실 장비(분광계, 원심분리기, 현미경, 크로마토그래프)를 만들고 피를 분석해 백신 제작. 27만 구독 | 치료제 연구 자체가 장기 목표 |
| [Antiserum Hardcore](https://steamcommunity.com/sharedfiles/filedetails/?id=2685311348) | B41 | 좀비 피 시료(1일 내 사용). 약한/보통/치료 혈청, 쓸 수 있는 감염 상한이 다름. 감염이 %가 아닌 단계로 보임 | 언제까지 쓸 수 있나라는 시간 압박 |
| [zRe Vaccine 2.0](https://steamcommunity.com/sharedfiles/filedetails/?id=3215662377) | B41 (목록에서 내려감) | 백신 4~5단계. 30% 미만에서 늦춤, 65~75%에서 알부민으로 되돌림, 85% 넘으면 끝. 면역 항체 특성 | 감염 구간별 다른 대응 |
| [Immunity](https://steamcommunity.com/sharedfiles/filedetails/?id=3396429342) | B41/42 | 기본 면역 확률. 감염 안 된 긁힘마다 면역 조금 오름, 오래 노출 없으면 내려감. 면역이어도 가짜 증상(열, 메스꺼움)이 나서 끝까지 모름 | 불확실성이 긴장을 만든다 |
| [AT's Partial Immunity](https://steamcommunity.com/sharedfiles/filedetails/?id=3777546966) | B42 | 감염되면 2~3일 심하게 앓지만 쉬고 치료하면 산다 | 즉사 대신 버티는 시간 |
| [New Infection System](https://steamcommunity.com/sharedfiles/filedetails/?id=3400051090) | B42 | 부분 면역(체력 5%까지 떨어지고 생존), 완전 면역, 약한 면역, 접촉 감염 | 면역의 여러 강도 |
| [PhunCure 2](https://steamcommunity.com/sharedfiles/filedetails/?id=3676251425) | B42 | 좀비가 치료제를 떨굼. 냉장 안 하면 상함 | 치료제에 유통기한 |
| [ZombieCureSyringe](https://steamcommunity.com/sharedfiles/filedetails/?id=3777949201) | B42 | 1/1000 의사 좀비가 치료 주사를 가짐. 감염만 치료, 상처는 그대로 | 희귀 표적 사냥 |
| [Infection Immunity Serum](https://steamcommunity.com/sharedfiles/filedetails/?id=3761578622) | B42 | 24시간 새 감염 무시. 이미 걸린 건 못 고침 | 예방과 치료의 구분 |
| [Experimental Vaccine](https://steamcommunity.com/sharedfiles/filedetails/?id=3569989271) | B42 | 시작할 때 1회용 치료제 1개 | 저장마다 한 번의 기회 |
| [The Cure](https://steamcommunity.com/sharedfiles/filedetails/?id=3424854399) | B41 | 빈 병, 효소 추출기로 좀비 피 10병을 모아 정제 | 수집형 치료 제작 |
| [Infected Player](https://steamcommunity.com/sharedfiles/filedetails/?id=2991010328) / [Be a zombie](https://steamcommunity.com/sharedfiles/filedetails/?id=3408312073) | B41 / B41·42 | 좀비가 된 뒤에도 플레이(물기 공격, 좀비 동작) | 죽음 이후 |

### 1-5. 상처·질병·음식

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [Wounds Overhaul](https://steamcommunity.com/sharedfiles/filedetails/?id=3775026731) | B42 | 부위를 눌러 실제로 살펴봄(응급처치 따라 3~12초). 숙련이 높으면 수치, 패혈증 게이지, **크녹스 감염 단계**까지 보임. 손으로 바늘을 끌어 봉합. 항생제는 3회 연속 복용. 2.2만 구독 | 기술이 높을수록 몸이 더 잘 보인다 |
| [Proper Infected Wounds](https://steamcommunity.com/sharedfiles/filedetails/?id=3410729454) | B42 | 더러운 붕대가 심한 감염을 부름 | 붕대 교체의 이유 |
| [Realistic Injury Healing](https://steamcommunity.com/sharedfiles/filedetails/?id=3352389981) | B41/42 | 몸 상태가 상처·골절 회복 속도에 영향 | 영양·수면이 회복과 이어짐 |
| [Self-Healing Factor](https://steamcommunity.com/sharedfiles/filedetails/?id=3774548887) | B42 | 일반 피해로 죽지 않고 중상으로 남음. 긁힘 1분, 찢김 5분, 물림 30분, 골절 120분, 크녹스 240분에 회복. 회복 중 시간당 60~240칼로리 소모. 휴식 1.5배, 칼로리 바닥이면 0.1배 | 치유가 **칼로리를 먹는다** |
| [Healing Factor](https://steamcommunity.com/sharedfiles/filedetails/?id=3790121622) | B42 | 팔다리, 상처 재생, 어느 정도 부활. 칼로리 소모 | 같은 패턴 |
| [Realistic Disease Mod](https://steamcommunity.com/sharedfiles/filedetails/?id=3629659534) | B42 | 감기→폐렴, 상처 감염, 파상풍, 광견병. 추위·젖음·위생·시체·스트레스·영양이 위험 요인 | 원인이 이해되는 병 |
| [Snake Eater Trait](https://steamcommunity.com/sharedfiles/filedetails/?id=3361593276) | B41 | 날것·썩은·탄 음식, 독, 오염수, 표백제 중독 면역 | 뭐든 먹는다 |
| [Useful Vitamins](https://steamcommunity.com/sharedfiles/filedetails/?id=3097287873) | B41 | 비타민이 감기·식중독을 줄임 | 버려지던 아이템에 쓸모 |
| [Heal From Food](https://steamcommunity.com/sharedfiles/filedetails/?id=2775441244) | B41 | 음식이 체력을 조금 회복 | 단순 |
| [HungerToStamina](https://steamcommunity.com/sharedfiles/filedetails/?id=3491726990) | B41 | 배고픔이 줄어든 만큼 지구력 회복 | 먹는 것이 전투 준비 |
| [Ozempus](https://steamcommunity.com/sharedfiles/filedetails/?id=3454541040) | B41 | 배고픔 1~2단계 페널티 제거, 회복 +20%, 굶주림 체력 손실 차단. 5~7번 쓰면 영구 영양실조 | 편리함의 누적 대가 |
| [FocusOnFight](https://steamcommunity.com/sharedfiles/filedetails/?id=2942511220) | — | 배고픔·갈증·체온·젖음·피로·지루함 중 골라서 면역 | 축별 면역 목록 |

### 1-6. 수면·휴식·지구력·운동·체온

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [Comfy Sleeping](https://steamcommunity.com/sharedfiles/filedetails/?id=2998737588) | B41/42 | 옷, 가방, 정신 상태, 청결로 잠의 질 6단계. 나쁘면 일찍 깨고 덜 회복, 목 통증. 7만 구독 | 잠자리 준비가 의미 있다 |
| [Sleep On It](https://steamcommunity.com/sharedfiles/filedetails/?id=3741561003) | B42 | 자면 지루함·불행 감소. 1.7만 구독 | 잠이 마음을 회복 |
| [BetterResting](https://steamcommunity.com/sharedfiles/filedetails/?id=3627718041) | B42 | 의자·차·침대에서 쉬면 지구력 회복 빠름. 다 쉬면 '잘 쉼' 버프(지구력 소모 감소). 침대는 상처·근육통·체력도 회복 | 쉬는 장소가 중요 |
| [Sleep & Heal Overhaul](https://steamcommunity.com/sharedfiles/filedetails/?id=3782641271) | B42 | 자는 동안 골절·병 회복 +40% (상처가 감염 안 됐을 때) | 조건부 회복 |
| [StaminaPlus](https://steamcommunity.com/sharedfiles/filedetails/?id=3460449821) | B41/42 | 지구력 95% 이상이면 0.5초마다 10%를 비축, 75% 아래로 떨어지면 비축분을 꺼내 채움 | 바닐라 상한을 안 건드리고 지구력을 늘린다 |
| [Kentucky Superman](https://steamcommunity.com/sharedfiles/filedetails/?id=3640598866) | B42 | 추가 지구력 바 | 두 번째 바 |
| [MoreEndurance](https://steamcommunity.com/sharedfiles/filedetails/?id=3387065293) | B42 | 지구력 +50 | B41처럼 싸우기 |
| [Sprint and Die](https://steamcommunity.com/sharedfiles/filedetails/?id=3544789880) | B41 | 지구력이 0이 돼도 체력을 깎으며 계속 질주 | 목숨을 연료로 |
| [Adrenaline Rush](https://steamcommunity.com/sharedfiles/filedetails/?id=3599181101) | B41 | 패닉 최고·직전 단계에서 피로·탈진 무시. 끝나면 피로 조금 증가 | 위기에서 버티는 힘, 끝난 뒤 반동 |
| [Adrenaline Shot](https://steamcommunity.com/sharedfiles/filedetails/?id=3791221767) | B42 | 주사 후 약 10분간 피로 무시, 지구력 100%. 직후 스트레스, 끝나면 갈증과 원래 피로. 3번째부터 메스꺼움, 5번째 치명 | 반복 사용 벌칙의 사다리 |
| [Ducks' No Pain? Yes, Gain!](https://steamcommunity.com/sharedfiles/filedetails/?id=2942815535) | B41 | 운동 근육통 대신 '운동 체력'. 하루 쉬면 다시 참 | 기다림 제거 |
| [IcyHot](https://steamcommunity.com/sharedfiles/filedetails/?id=3267216370) | B41 | 연고로 근육통 완화 | — |
| [Exercise With Corpses](https://steamcommunity.com/sharedfiles/filedetails/?id=3404074048) | B42 | 시체를 끌면 한 칸마다 근력·체력 XP. 7.7만 구독 | 일상 동작이 운동 |
| [Meditation](https://steamcommunity.com/sharedfiles/filedetails/?id=2891623922) / [Lifestyle: Hobbies](https://steamcommunity.com/sharedfiles/filedetails/?id=2997342681) | B41 | 명상·요가·춤으로 스트레스·지루함 관리. Lifestyle 56만 구독 | 마음 관리 동작 |
| [Warm Up](https://steamcommunity.com/sharedfiles/filedetails/?id=3012122638) | B41 | 저체온 무들일 때 걷거나 앉아서도 몸을 데우는 동작. 18만 구독 | 단순한 능동 동작이 인기 |
| [Realistic Temperature Mod](https://steamcommunity.com/sharedfiles/filedetails/?id=3600401184) | B42 | 실내 온도를 방마다 시뮬레이션. 문·창문 틈으로 열이 빠짐. 6만 구독 | 체온이 진짜 문제가 된다 (체온 노드와 같이 켤 가능성 큼) |

### 1-7. 낙하·넘어짐·이동

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [ParkourZ – Fall Damage Rework](https://steamcommunity.com/sharedfiles/filedetails/?id=3689744930) | B42 | 낙하 피해 0~200%. 안전 구간, 완만 구간, 급증 구간을 따로 조절 | 낙하를 구간으로 나눠 생각한다 |
| [Trip 'n' Fall](https://steamcommunity.com/sharedfiles/filedetails/?id=3013901070) | B41 | 바닥의 좀비·시체에 걸려 넘어짐. 조준 걷기면 안전. 넘어지면 모자·안경·손의 물건이 떨어짐 | 처치가 함정을 만든다 |
| [Get Up Quick](https://steamcommunity.com/sharedfiles/filedetails/?id=3444943638) | B42 | 일어나기를 항상 빠른 동작으로. 3.7만 구독 | 넘어진 뒤 시간이 생사 |
| [Swim Skill](https://steamcommunity.com/sharedfiles/filedetails/?id=3654513156) | B41/42 | 수영 스킬. 체력 높으면 지구력 덜 씀, 과적이면 더 씀 | — |
| [Down But Not Out](https://steamcommunity.com/sharedfiles/filedetails/?id=3774055538) | B42 (멀티 전용) | 치명상에 쓰러져 기어다님, 출혈 타이머 | 즉사 대신 마지막 기회 |

### 1-8. 동물 (B42)

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [Zen Animals](https://steamcommunity.com/sharedfiles/filedetails/?id=3729942997) | B42 | 가축 스트레스 제거. 황소 넘어뜨리기 공격과 가축의 찢는 상처 없앰 | 황소 문제를 그대로 겨냥한다 |
| [Tame-able Wolves](https://steamcommunity.com/sharedfiles/filedetails/?id=3581134738) | B42 | 고기로 늑대 길들이기(최대 3마리). 늑대마다 인벤토리, 따라오기 명령 | 동행 + 짐꾼 |
| [Tame Deer](https://steamcommunity.com/sharedfiles/filedetails/?id=3783636903) | B42 | 새끼는 들어서, 어른은 밧줄로 길들임 | 야생 동물 길들이기 |
| [Animal Tracking Overhaul](https://steamcommunity.com/sharedfiles/filedetails/?id=3800487942) | B42 | 채집 중 야생 동물 똥을 찾으면 냄새로 방향을 알려 줌 | 흔적 → 방향 |
| [Animal Tracker](https://steamcommunity.com/sharedfiles/filedetails/?id=3706760910) | B42 | 주변 동물 지도 표시, 3일간 마지막 위치 기억 | 정보형 |
| [Zombies Target Animals](https://steamcommunity.com/sharedfiles/filedetails/?id=3774007514) | B42 | 좀비가 동물을 쫓아 먹음. 먹은 좀비는 앉아 쉬며 몇 시간 둔해짐 | 동물을 미끼로 쓸 수 있다 |

### 1-9. 내구도·힘쓰기

| 모드 | 빌드 | 기능 | 재미 포인트 |
| --- | --- | --- | --- |
| [Enhanced Durability](https://steamcommunity.com/sharedfiles/filedetails/?id=3390349943) | B42 | 계열별 최대 내구 배율(근접, 원거리, 도구) | 계열별 배율 |
| [Durability Overhaul](https://steamcommunity.com/sharedfiles/filedetails/?id=2843189389) | B42 | 쇠막대, 빠루처럼 안 깨질 물건의 내구 증가 | — |
| [Furniture Push & Pull](https://steamcommunity.com/sharedfiles/filedetails/?id=3781319724) | B42 | 힘으로 가구를 한 칸씩 밀고 당김. 6.3만 구독 | 운반 캡스톤 '끌기'와 같은 기능 |
| [Push Vehicle](https://steamcommunity.com/sharedfiles/filedetails/?id=3780639614) | B42 | 힘으로 서 있는 차를 밀고 돌림. 지구력, 대기시간, 최대 무게 설정. 14만 구독 | 힘을 쓰는 새 동작이 인기 |

## 2. 재미 포인트에서 뽑은 설계 패턴

| 패턴 | 예 | 우리 모드에 쓰는 법 |
| --- | --- | --- |
| 값을 신진대사로 치른다 | Telekinesis(음식·물 +30%, 숙련할수록 줄어듦), Self-Healing Factor(칼로리), Meteorfall | 능동 기술 대가로 배고픔·갈증·지구력을 쓴다. 대기시간과 같이 쓰거나 대신 쓴다. 강화를 찍으면 대가가 준다 |
| 무리해서 쓰기 | Psionic Awakening(모자란 사이를 긴장으로) | 대기시간 중에도 쓸 수 있게 하고, 대신 스트레스·피로·통증을 크게 받는다. 너무 쌓이면 기절 |
| 끝난 뒤 반동 | Adrenaline Rush, Adrenaline Shot | 버프가 끝나면 피로·갈증이 돌아온다. 찍을수록 반동이 준다 |
| 반복 사용 벌칙 사다리 | Adrenaline Shot(3회 메스꺼움, 5회 치명), Playing Dead(24시간 3회면 병), Ozempus | 짧은 시간에 여러 번 쓰면 부작용이 커진다 |
| 단계를 색으로 | Zombie Camouflage B42(호박→초록) | 무들 색으로 강도를 보여 준다. 단계마다 효과 거리를 분명하게 |
| 의심 게이지 | Braven's Camouflage | 위장 중 가까이 오래 있으면 들킨다 |
| 불확실성 | Immunity(가짜 증상) | 정보 노드의 가치가 생긴다 ("자가 진단") |
| 기술이 높을수록 더 보인다 | Wounds Overhaul(숙련 시 감염 단계 표시) | 정보 노드를 찍을수록 정확해지는 사다리 (육감과 같은 구조) |
| 바닐라 동작 강화 | Dead Frequency(바닐라 함성 키) | 함성 노드는 바닐라 Q 함성을 키운다. 새 키를 줄인다 |
| 전투 중 조준 UX | Pyrokinesis(F7 가장 가까운 대상 자동), Psionic(원형 메뉴, 열면 일시정지) | 능동 기술 단축키는 자동 조준을 기본으로. 원형 메뉴로 고르기 |
| 수락·보류 | Character Evolution | 성격이 바뀌는 강화(둔감 등)는 플레이어가 켜고 끄게 |
| 레벨당 수치표 | Toughness Skill, Combat Mastering, Meteorfall | 노드 툴팁에 점마다 수치를 표로 |

## 3. 강화 아이디어

형태: **패시브**(찍을 때마다 수치), **능동**(누르면 발동, 대기시간), **캡스톤**(새 동작), **정보**(무들·표시).
트리 칸의 '능동'은 지금 생존 아래에 모아 둔 능동 기술 묶음이다.
겹침: (바닐라) 바닐라 특성과 같은 축, (보상) 신뢰도 보상과 겹침, (혈청) 치료 혈청과 겹침.

### 3-1. 배고픔·갈증·음식

| # | 이름 | 트리 | 형태 | 효과 (찍을 때마다) | 출처 |
| --- | --- | --- | --- | --- | --- |
| 1 | 느린 신진대사 | 생존 | 패시브 | 배고픔·갈증 증가 속도 감소 (바닐라: 소식가) | FocusOnFight, Mutation Survivor 반대 |
| 2 | 알뜰 소화 | 생존 | 패시브 | 같은 음식에서 배고픔 회복·칼로리 증가 | Mutation Survivor(Insatiable 반대) |
| 3 | 먹으면 힘 | 생존 | 패시브 | 먹고 마신 만큼 지구력 일부 회복 | HungerToStamina |
| 4 | 먹으면 낫는다 | 생존 | 패시브 | 식사 때 체력 소량 회복, 상처 회복 잠깐 증가 | Heal From Food, Realistic Injury Healing |
| 5 | 강철 위장 | 생존 | 패시브 | 날것·상한 음식, 오염수 식중독 확률·세기 감소. 마지막 점에서 면역 | Snake Eater, Cockroach Body |
| 6 | 굶주림 버팀 | 생존 | 패시브 | 굶주림 단계 체력 손실 시작을 늦춤 | Ozempus |
| 7 | 물 아껴 마시기 | 생존 | 패시브 | 더위·운동 중 갈증 증가 감소 | Adrenaline Shot 부작용 반대 |
| 8 | 칼로리 저장 | 생존 | 패시브 | 칼로리 상한·하한 범위 확장, 몸무게 변화 완화 | Realistic Nutrition |

### 3-2. 피로·수면·휴식

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 9 | 깊은 잠 | 생존 | 패시브 | 자는 시간당 피로 회복 증가 (바닐라: 적게 잠) | Comfy Sleeping |
| 10 | 어디서나 잠 | 생존 | 패시브 | 나쁜 잠자리·불편한 옷의 잠 품질 페널티 감소, 목 통증 확률 감소 | Comfy Sleeping |
| 11 | 자며 낫기 | 생존 | 패시브 | 자는 동안 상처·골절·병 회복 증가 | Sleep & Heal, BetterResting |
| 12 | 잠이 위로 | 생존 | 패시브 | 자고 나면 지루함·불행·스트레스 감소 | Sleep On It |
| 13 | 잘 쉼 | 생존 | 패시브 | 앉아 쉴 때 지구력 회복 증가. 다 쉬면 짧은 '잘 쉼' 버프(지구력 소모 감소) | BetterResting |
| 14 | 기절 저항 | 생존 | 패시브 | 극도 피로에서 쓰러질 확률 감소 (DTEM 기절과 같이 켤 때) | DTEM |
| 15 | 선잠 | 생존 | 패시브 | 자는 중 좀비가 다가오면 깸 (IDEAS에 있음). 찍을수록 감지 반경 | — |
| 16 | 쪽잠 | 생존 | 능동 | 앉은 자리에서 짧게 자고 피로 일부 회복. 대기시간 길다 | BetterResting |

### 3-3. 지구력·운동

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 17 | 비축 지구력 | 생존 | 패시브 | 지구력이 꽉 차 있을 때 넘치는 양을 비축하고, 떨어지면 꺼내 씀. 찍을수록 비축 한도. 바닐라 상한을 덮어쓰지 않는다 | StaminaPlus |
| 18 | 지구력 소모 감소 | 생존 | 패시브 | 휘두르기·달리기 지구력 소모 감소 | Mutation Survivor(Half-Orc) |
| 19 | 지구력 회복 | 생존 | 패시브 | 회복 속도 증가 | MoreEndurance |
| 20 | 근육통 완화 | 생존 | 패시브 | 운동 근육통이 덜 쌓이고 빨리 풀림 | Ducks', IcyHot |
| 21 | 숨 고르기 | 생존 | 능동 | 멈춰 서서 몇 초간 숨 고르면 지구력 빠르게 회복. 움직이면 끊김 | BetterResting |
| 22 | 한계 돌파 | 능동 | 능동(토글) | 지구력 0에서도 체력을 깎아 계속 질주. 찍을수록 체력 대비 효율 | Sprint and Die |
| 23 | 일하며 단련 | 운반 | 패시브 | 시체 끌기, 무거운 짐 들고 걷기에 근력·체력 XP | Exercise With Corpses |
| 24 | 밤의 몸 | 생존 | 패시브 | 밤 시간(20~6시) 지구력 소모 감소 | Mutation Survivor(Werewolf) |

### 3-4. 체온·젖음

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 25 | 추위 내성 | 생존 | 패시브 | 추울 때 체온 떨어지는 속도 감소 | Realistic Temperature, Cryogenic Winter |
| 26 | 더위 내성 | 생존 | 패시브 | 더울 때 체온 오르는 속도·땀 감소 | Realistic Temperature |
| 27 | 몸 데우기 | 능동 | 능동 | 저체온일 때 걷거나 앉아서 몸 데우는 동작. 찍을수록 효율 | Warm Up |
| 28 | 빨리 마름 | 생존 | 패시브 | 젖은 몸·옷이 빨리 마름 | — |
| 29 | 비에 강함 | 생존 | 패시브 | 젖음·추위로 인한 감기 확률 감소 | Realistic Disease |
| 30 | 체온 감 | 생존 | 정보 | 체온이 위험해지기 전에 미리 알려 줌, 몇 분 남았는지 | Cabin Temp Display |

### 3-5. 패닉·스트레스·지루함·통증

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 31 | 단련된 마음 | 생존 | 패시브 | 점마다 패닉 -10%, 통증 -5%, 불편 -5% 같은 정확한 수치 | Toughness Skill |
| 32 | 빨리 가라앉음 | 생존 | 패시브 | 패닉·스트레스가 빨리 줄어듦 | — |
| 33 | 익숙해짐 | 생존 | 패시브 | 좀비 처치 수에 따라 패닉 감소가 조금씩 커짐 (상한) | Become Desensitized, Dynamic Panic |
| 34 | 위기 집중 | 생존 | 패시브 | 패닉 최고 단계에서 피로 무시, 끝나면 피로 조금 | Adrenaline Rush |
| 35 | 명상 | 능동 | 능동 | 앉아서 명상하면 스트레스·불행·지루함이 빠르게 줄어듦. 좀비가 오면 끊김 | Meditation, Psionic |
| 36 | 작은 즐거움 | 생존 | 패시브 | 먹기·읽기·담배 같은 기분 회복 효과 증가 | MBTI Roles |
| 37 | 지루함 둔감 | 생존 | 패시브 | 지루함·우울이 천천히 쌓임 | Sleep On It |
| 38 | 통증 둔감 | 생존 | 패시브 | 통증 무들의 페널티(조준, 속도) 감소 | Toughness, Honey Badger |
| 39 | 불편 무시 | 생존 | 패시브 | 무거운 옷·갑옷의 불편 무들 기준선 상승 | Toughness Skill |

### 3-6. 상처·질병·감염

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 40 | 빠른 지혈 | 생존 | 패시브 | 출혈 속도 감소 | — |
| 41 | 빠른 회복 | 생존 | 패시브 | 상처·골절 회복 속도 증가 | Realistic Injury Healing |
| 42 | 재생 (칼로리) | 생존 | 패시브 | 상처 회복이 빨라지지만 그만큼 칼로리를 씀. 찍을수록 빠르고 덜 씀 | Self-Healing Factor |
| 43 | 깨끗한 몸 | 생존 | 패시브 | 더러운 붕대·상처 감염 확률 감소 | Proper Infected Wounds |
| 44 | 능숙한 손 | 생존 | 패시브 | 자기 치료(붕대, 소독, 봉합, 부목) 속도 증가 | Physiks(느리게 한 것의 반대) |
| 45 | 몸 읽기 | 생존 | 정보 | 상처 상세 정보. 찍을수록 감염 위험, 회복 남은 시간 | Wounds Overhaul |
| 46 | 자가 진단 | 생존 | 정보 | 긁힘·찢김이 크녹스 감염인지 알려 줌. 1단계 "의심", 끝 단계 "확실 + 진행도". 감염을 고치진 않아서 혈청과 안 겹친다 | Wounds Overhaul, Immunity |
| 47 | 감기 저항 | 생존 | 패시브 | 감기 확률·지속 감소 | Realistic Disease, Useful Vitamins |
| 48 | 감염 저항 | 생존 | 패시브 | 긁힘·찢김 감염 확률 감소 (물림 제외). 상한 둔다 | Immunity |
| 49 | 면역 훈련 | 생존 | 패시브 | 감염 안 된 긁힘을 겪을 때마다 감염 저항이 조금 오름 (상한) | Immunity |
| 50 | 감염 지연 | 생존 | 패시브 | 감염 진행 속도 감소, 감염 지연제 지속 증가 | They Knew(Zomboxolone) |
| 51 | 버티는 몸 (혈청) | 생존 | 캡스톤 | 감염돼도 바로 죽지 않고 크게 앓다가 버틸 기회. 치료 혈청과 겹쳐서 뺄 후보 | AT's Partial Immunity |
| 52 | 절단 숙련 | 생존 | 패시브 | The Only Cure와 같이 켤 때 절단 생존률·회복 증가 | The Only Cure |
| 53 | 냄새 덜 나는 상처 | 생존 | 패시브 | 출혈 중 좀비가 냄새로 쫓는 정도 감소 (냄새 모드와 같이 켤 때 의미) | ROT, Sense of Smell |

### 3-7. 넘어짐·낙하·이동

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 54 | 굳건한 발 | 생존 | 패시브 | 좀비에게 밀려 넘어질 확률 감소 | — |
| 55 | 발밑 조심 | 생존 | 패시브 | 시체·쓰러진 좀비 위를 지날 때 비틀거림 감소 | Trip 'n' Fall |
| 56 | 빠른 기상 | 생존 | 패시브 | 넘어진 뒤 일어나는 속도 증가 | Get Up Quick |
| 57 | 낙법 | 생존 | 패시브 | 낙하 '안전 구간' 높이가 늘고 '급증 구간'이 늦게 옴 | ParkourZ |
| 58 | 굴러 떨어지기 | 생존 | 패시브 | 낙하 때 골절 대신 타박상 확률 증가 | ParkourZ, Glass Bones 반대 |
| 59 | 회피 구르기 | 능동 | 능동 | 방향 회피. 지구력 소모, 짧은 대기시간 | Project Parkour |
| 60 | 도약 | 능동 | 능동 | 2~4칸 점프 (울타리·도랑). 찍을수록 거리 | Project Parkour |
| 61 | 창문 다이빙 | 수색 | 캡스톤 | 질주해서 창문을 깨지 않고 바로 뛰어 넘음 (넘나들기의 끝) | Project Parkour |
| 62 | 공중 습격 | 능동 | 캡스톤 | 높은 곳에서 아래 좀비 하나에게 뛰어내려 처치. 주변은 넘어짐. 낙법 점수만큼 자기 피해 감소 | Strike From Above |
| 63 | 마지막 기어가기 | 생존 | 캡스톤 | 체력 0이 되는 피해를 한 번 버티고 쓰러져 기어감. 긴 대기시간 | Down But Not Out |

### 3-8. 동물

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 64 | 동물 진정 | 생존 | 패시브 | 가까이 있는 가축의 스트레스 증가 감소 | Zen Animals |
| 65 | 황소 다루기 | 생존 | 패시브 | 황소·돼지 넘어뜨리기 공격 확률 감소, 마지막 점에서 면역 | Zen Animals |
| 66 | 다치지 않는 손 | 생존 | 패시브 | 가축이 내는 찢는 상처 감소 | Zen Animals |
| 67 | 동물 길들이기 | 생존 | 캡스톤 | 야생 동물(사슴 등)을 먹이로 길들임 | Tame Deer |
| 68 | 동물 흔적 | 수색 | 정보 | 채집 중 흔적을 찾으면 동물 방향 표시 | Animal Tracking Overhaul |
| 69 | 동물 기억 | 수색 | 정보 | 본 동물의 마지막 위치를 지도에 며칠 남김 | Animal Tracker |
| 70 | 짐 나르는 동물 | 운반 | 캡스톤 | 길들인 동물이 짐을 듦 | Tame-able Wolves |
| 71 | 동물 미끼 | 능동 | 패시브 | 좀비가 동물을 노릴 때 나를 덜 노림 | Zombies Target Animals |

### 3-9. 장비 내구도

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 72 | 무기 아끼기 | 생존 | 패시브 | 근접 무기 내구 깎일 확률 감소 | Enhanced Durability |
| 73 | 옷 아끼기 | 생존 | 패시브 | 입은 옷·장비가 찢어지거나 구멍 나는 확률 감소 | — |
| 74 | 손질 | 생존 | 패시브 | 수리할 때 회복하는 내구가 늘고 수리 횟수 페널티가 줄어듦 | Durability Overhaul |
| 75 | 도구 아끼기 | 수색 | 패시브 | 빠루·톱 같은 도구 내구 소모 감소 (IDEAS '아껴 쓰기') | Durability Overhaul |

### 3-10. 능동 기술 (유인·위장·몸 다루기)

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 76 | 함성 강화 | 능동 | 능동 | 바닐라 함성 키(Q)를 강화. 찍을수록 반경·지속 증가. 새 키 없음 | Dead Frequency |
| 77 | 썩은 미끼 | 능동 | 능동 | 썩은 고기·시체 조각을 던져 그 자리로 좀비를 오래 모음 (페로몬의 구체안) | ROT |
| 78 | 핏자국 길 | 능동 | 능동 | 지나가는 길에 냄새 흔적을 남겨 좀비가 그 길을 따라가게 함. 무리를 다른 곳으로 끌고 감 | Sense of Smell, ROT |
| 79 | 냄새 지우기 | 생존 | 패시브 | 내 냄새가 덜 퍼짐 (냄새 모드와 같이 켤 때) | Sense of Smell |
| 80 | 위장 단계 | 능동 | 능동 | 위장 냄새를 단계로. 찍을수록 들키는 거리 감소 (예: 3.5칸 → 1.1칸) | Zombie Camouflage B42 |
| 81 | 의심 늦추기 | 능동 | 패시브 | 위장 중 좀비 의심이 천천히 쌓임 | Braven's |
| 82 | 오래 가는 위장 | 능동 | 패시브 | 위장이 비·시간에 덜 씻김 | Zombie Camouflage B42 |
| 83 | 시체 걸음 | 능동 | 패시브 | 위장 중 좀비처럼 걸으면 들키는 거리 추가 감소. 대신 느림 | Braven's |
| 84 | 죽은 척 | 능동 | 능동 | 바닥에 누워 시체 흉내. 그동안 좀비가 무시. 움직이면 풀림 | Playing Dead |
| 85 | 병든 냄새 | 능동 | 캡스톤 | 긴 시간 위장. 대신 체력·지구력이 크게 떨어진 상태로만 움직임 | Invisible to the Herd |
| 86 | 꼭두각시 | 능동 | 캡스톤 | 좀비 하나를 잠시 조종해 소리를 내게 해서 무리를 끔. 그동안 내 몸은 무방비 | Psionic(Mind Puppet) |
| 87 | 넘어뜨리기 파동 | 능동 | 능동 | 주변 좀비를 넘어뜨려 도망칠 틈. 긴 대기시간 | Psionic Impact, Telekinesis Push |
| 88 | 밀치기 연쇄 | 생존 | 패시브 | 밀치기가 뒤 좀비까지 도미노로. 찍을수록 확률·개수 (전투 인접) | Better Push, BackOff! |
| 89 | 아드레날린 주입 | 능동 | 능동 | 약 10분간 피로 무시, 지구력 가득. 끝나면 갈증·피로 복귀. 대기시간 중 또 쓰면 메스꺼움 | Adrenaline Shot |
| 90 | 아드레날린 (IDEAS 캡스톤) | 능동 | 캡스톤 | 체력이 낮을 때 잠깐 지구력 무한·빠른 이동. 끝나면 반동 | Adrenaline Rush |
| 91 | 최후의 비명 | 능동 | 캡스톤 | 죽기 직전 비명. 주변 좀비가 넘어지고 문·창문이 깨지고 큰 소리. 그 뒤 오래 기절 | Psionic Scream |
| 92 | 농성 | 능동 | 능동 | 주변 열린 문·창문을 한 번에 닫음 | Psionic Seal Defenses |
| 93 | 원격 손 | 수색 | 캡스톤 | 멀리서 문·창문·전등·용기 열고 닫기 | Psionic Hand |
| 94 | 물건 끌어오기 | 운반 | 능동 | 주변 바닥 물건을 바로 인벤토리로. 찍을수록 반경·개수 | Psionic Distant Pull |
| 95 | 표식 | 수색 | 능동 | 지금 보는 위치(무리, 위험 지역)에 깜빡이는 표식을 남김 | Psionic Mind Mark |
| 96 | 흡혈 | 능동 | 능동 | 갓 죽인 시체에서 배고픔·갈증·피로 조금 회복. 감염 위험 조금. 대기시간 | Mutation Survivor(Vampire) |
| 97 | 연속 처치 투지 | 생존 | 패시브 | 짧은 시간에 여러 좀비를 죽이면 패닉 감소·지구력 조금 회복 | ETW 혈기, Mutation Survivor 광폭 |

### 3-11. 운반 쪽

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 98 | 가구 밀기 | 운반 | 캡스톤 | 가구를 들지 않고 한 칸씩 밀고 당김 (IDEAS '끌기') | Furniture Push & Pull |
| 99 | 차 밀기 | 운반 | 캡스톤 | 시동 안 걸리는 차를 밀어서 길을 엶. 힘·지구력 사용 | Push Vehicle |
| 100 | 과적 골절 저항 | 운반 | 패시브 | 심한 과적에서 다치는 확률 감소 (IDEAS '과적 체력'의 구체안) | DTEM |
| 101 | 짐 진 수영 | 운반 | 패시브 | 과적 상태 수영 지구력 페널티 감소 (수영 모드와 같이 켤 때) | Swim Skill |
| 102 | 중장 모드 | 운반 | 능동 | 잠깐 운반 한도 크게 증가, 대신 느리고 지구력 소모 큼 | EXO Heavy |

### 3-12. 수색 쪽

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 103 | 넓은 시야 | 수색 | 패시브 | 시야 원뿔 각도 증가 (바닐라: 독수리 눈) | X-Virus |
| 104 | 본능 | 수색 | 패시브 | 뒤에서 공격하려는 좀비를 알림(소리·화면). 끝 단계에서 자동 밀치기 | Psionic Instinct |
| 105 | 고정 메아리 | 수색 | 능동 | 벽 너머 좀비를 잠깐 고정 표식으로 표시 (움직임은 안 따라감). 기척 펄스의 싼 1단계 | Psionic Sense |
| 106 | 냄새 측정 | 수색 | 정보 | 내 냄새·소음 수준을 수치로 보여 줌 | Sense of Smell 측정기 |
| 107 | 배부른 좀비 감 | 수색 | 정보 | 먹고 쉬는 둔한 좀비를 다른 색으로 표시 | Zombies Target Animals |
| 108 | 의사 좀비 감 | 수색 | 정보 | 특별한 물건을 가진 좀비(의사, 군인)를 희미하게 표시 | ZombieCureSyringe, X-Virus |

### 3-13. 큰 틀 (트리 구조·2차 연구판)

| # | 이름 | 트리 | 형태 | 효과 | 출처 |
| --- | --- | --- | --- | --- | --- |
| 109 | 신진대사 대가 | 공통 | 규칙 | 능동 기술마다 배고픔·갈증 소모. 해당 갈래를 찍을수록 소모 감소 | Telekinesis |
| 110 | 무리해서 쓰기 | 공통 | 규칙 | 대기시간 중에도 발동 가능, 대신 스트레스·피로·통증 큰 대가 | Psionic |
| 111 | 반복 벌칙 | 공통 | 규칙 | 같은 능동 기술을 짧은 시간에 여러 번 쓰면 부작용이 단계적으로 | Adrenaline Shot |
| 112 | 숙련 보너스 | 공통 | 규칙 | 능동 기술을 쓸수록 소폭 숙련 (포인트와 별개, 상한) | Meteorfall, Psionic |
| 113 | 수치표 툴팁 | 공통 | UI | 노드 툴팁에 1~N점 수치를 표로 | Toughness Skill |
| 114 | 자동 조준 키 | 공통 | UI | 능동 기술은 가장 가까운 대상에 자동. 원형 메뉴로 고르기, 메뉴 열면 일시정지(SP) | Pyrokinesis, Psionic |
| 115 | 수락형 변화 | 공통 | 규칙 | 성격이 바뀌는 효과는 켜고 끌 수 있게 | Character Evolution |
| 116 | 변이 복권 | 2차 연구판 | 무한 | 일정 포인트마다 작은 무작위 이점 하나 (중복 시 감소) | Genetic Mutation |
| 117 | 생존일 보상 | 2차 연구판 | 무한 | 오래 살아남을수록 생존 수치 소폭 증가 | Genetic Mutation, Become Desensitized |
| 118 | 다 찍은 뒤 쓸 곳 | 2차 연구판 | 무한 | 트리를 다 찍은 뒤 남는 포인트의 사용처 | RPGSkillTree 랜덤 상자 |

## 4. 같이 켰을 때 겹치는 모드

바닐라 값을 덮어쓰지 않고 배율·더하기로 얹는다는 원칙([IDEAS.md](../IDEAS.md))에 비춰 볼 곳.

| 모드 | 겹치는 노드 | 메모 |
| --- | --- | --- |
| Toughness Skill | 단련된 마음, 통증 둔감, 불편 무시 | 같은 패닉·통증 축. 둘 다 배율이면 곱해져 0에 가까워질 수 있다. 상한 필요 |
| DTEM, ETW, More Traits | 특성 축 노드 전부 | 특성을 더하고 빼는 모드. 우리는 특성 대신 수치만 건드리는 편이 안전 |
| Zombie Camouflage B42, Braven's, Playing Dead | 위장 냄새 | 둘 다 좀비 인식을 바꾼다. Zombie Camouflage B42는 B42 새 은신 시스템을 끄라고 안내함 (확인) |
| Sense of Smell, ROT | 썩은 미끼, 핏자국 길, 냄새 지우기 | 냄새를 이미 소리 신호로 흉내 낸다. 우리 페로몬도 같은 방식이면 같이 켰을 때 두 배로 끌 수 있음 |
| Comfy Sleeping, BetterResting, Sleep On It | 수면 노드 | 잠 품질 계산을 바꾼다. 우리 노드는 결과에 배율만 |
| Realistic Temperature | 체온 노드 | 실내 온도 자체를 바꿈. 체온 변화 속도 배율이면 충돌 없음 |
| The Only Cure, They Knew, 각종 면역 모드 | 감염 노드 | 감염 상태를 직접 바꾸는 모드가 많다. 확률·속도 배율만 다루고, 치료는 혈청 몫으로 둔다 |
| Wounds Overhaul | 몸 읽기, 자가 진단, 능숙한 손 | 의료 동작을 크게 바꿈. 자가 진단 표시는 겹칠 수 있음 |
| Project Parkour, ParkourZ | 도약, 회피, 창문 다이빙, 낙법 | 이미 인기 있는 이동 모드. 같은 동작을 다시 만들기보다 낙하 피해 배율만 얹는 쪽 |
| BackOff!, Better Push | 밀치기 연쇄 | 둘 다 밀치기를 바꿈. 같은 이벤트에 걸면 두 번 넘어뜨릴 수 있음 |
| Zen Animals | 동물 진정, 황소 다루기 | 아예 없애는 모드. 우리 쪽은 확률 감소로 |
| Furniture Push & Pull, Push Vehicle | 가구 밀기, 차 밀기 | 인기 높음(6만, 14만). 캡스톤으로 따로 만들 가치가 있는지 다시 볼 것 |

## 5. 확인할 바닐라 사실 (이번 조사에서 새로 나온 것)

- B42 좀비 '새 은신 시스템' 샌드박스 옵션이 무엇을 바꾸는지 (위장 냄새가 기대는 곳)
- 바닐라 함성(Q)의 소리 반경과 이것을 키우는 지점
- 넘어진 뒤 일어나기: 달리기 키를 누르면 빨라지는 동작 (Get Up Quick이 기대는 곳)
- 황소·돼지의 넘어뜨리기 공격과 가축 스트레스 계산
- 근육통(stiffness) 계산, 휴식 중 지구력 회복 계산
- 좀비가 시체·동물을 먹는 동작이 바닐라에 있는지 (Zombies Target Animals는 직접 만든 것으로 보임)

## 6. 고른다면 (상위 10)

1. **비축 지구력** (#17): 바닐라 상한을 안 건드리고 지구력을 늘린다. 찍을수록 비축 한도.
2. **단련된 마음** (#31): 점마다 패닉·통증·불편 %가 분명하다.
3. **재생 (칼로리)** (#42): 빨리 낫지만 먹어야 한다. 배고픔 노드와 엮인다.
4. **위장 단계 + 의심 게이지** (#80, #81): 단계마다 들키는 거리가 분명하고 색으로 보인다.
5. **썩은 미끼** (#77): 페로몬을 손에 잡히는 행동으로. 쓰레기가 자원이 된다.
6. **꼭두각시** (#86): 함성·페로몬 위의 유인 캡스톤. 내 몸이 무방비라는 대가가 있다.
7. **아드레날린 주입** (#89): 끝난 뒤 반동과 반복 벌칙이 있어 아껴 쓰게 된다.
8. **낙법** (#57): 낙하를 안전·완만·급증 구간으로 나눠, 찍을수록 구간이 밀린다.
9. **황소 다루기** (#65): B42 가축의 실제 불편을 바로 푼다.
10. **신진대사 대가** (#109): 능동 기술 전체의 대가 규칙. 대기시간과 같이 써서 시간과 자원 둘 다로 균형을 잡는다.

다음 후보: 자가 진단(#46), 함성 강화(바닐라 Q, #76), 명상(#35), 빠른 기상(#56), 가구 밀기(#98).
