# TaS와 인기 특성·숙련 모드 조사

[강화 후보](../IDEAS.md)의 '겹칠 수 있는 다른 모드' 조사 중 하나. ETW, MT, DT, SOTO는 따로 조사하므로 여기서는 짧게만
언급한다. 구독자 수와 날짜는 Steam API(2026-10-08 조회) 기준이다.

## 1. TaS = Traits As Skills

[Traits As Skills](https://steamcommunity.com/sharedfiles/filedetails/?id=3784847437) (작성자 GersonRess, Mod ID
`traitsAsSkills`). 설명문 제목에 "Traits As Skills (TaS)"로 줄여 쓴다.

| 항목 | 내용 |
| --- | --- |
| 빌드 | B42 전용 (애드온은 42.20 이상). WIP 표시 |
| 구독 | 약 9만 1천 (누적 10만 9천). 2026-08-17 공개, 2026-09-22 갱신 |
| 멀티 | 싱글·멀티 모두. 서버가 특성을 바꾸고 클라이언트는 보여 주기만 함 |
| 화면 | 캐릭터 정보 창에 **특성 탭**을 새로 붙인다. 기술 탭처럼 특성마다 XP 막대, 레벨, 단계가 보임 |

### 동작

- 특성 축 하나를 **스펙트럼**이라 부른다. 레벨 0~10. 레벨 구간(**밴드**)마다 특성 하나가 붙는다.
  예: 낮은 구간은 부정 특성, 가운데는 빈 구간(중립), 높은 구간은 긍정 특성.
- 스펙트럼 종류는 셋이다.
  - 기술 연동형: 바닐라 기술 레벨을 그대로 읽는다 (예: 이동, 둔기, 농사). 모드가 XP를 주지 않음.
  - 특성 기술형: 모드가 자체 XP를 쌓는다 (예: 독서, 용기, 수면). 기본 시작점은 중립 레벨 5.
  - 동적형: 체중, 체력, 근력. 게임이 관리하므로 모드는 손대지 않는다.
- XP는 행동에서 나온다. 예: 좀비 처치 시 용기 +5. 내장 행동 목록: 먹기, 상한 음식, 담배, 붕대, 소독, 봉합,
  다침, 잠, 사격, 좀비 처치, 창문 깨기, 문 부수기, 아이템 옮기기, 아무 행동, 운전, 기술 XP, 책 페이지.
  지속 효과: 체중, 배고픔, 갈증, 체력, 더러운 붕대, 수면, 졸음 버티기, 금연, 생존 시간.
- 레벨 XP 예시 표: 500, 800, 1000, 1600, 2500, 4000, 6000, 8000, 9000, 10000. 스펙트럼마다 바꿀 수 있다.
- 특성은 **레벨이 오를 때만** 붙는다. 처음부터 높게 시작해도 공짜로 주지 않는다. 부정 특성은 레벨이 올라갈
  때만 지워지고, 긍정 특성은 레벨이 내려갈 때만 빠진다. 10레벨에서는 부정 특성이 모두 지워진다.
- 플레이 중 얻은 특성은 캐릭터 생성 때 주는 기술 +1 보너스를 주지 않는다.
- 청각 스펙트럼: 시끄러운 원거리 무기를 쏘면 청각이 떨어진다. 커뮤니티 패치
  [Silent Weapons Compat](https://steamcommunity.com/sharedfiles/filedetails/?id=3790588736)가 무기 소음 반경으로
  판정을 바꾼다 (기본 문턱 40, 예전 65).

### 바닐라에서 건드리는 것

- **바닐라 수치는 직접 바꾸지 않는다.** 하는 일은 캐릭터의 특성(`CharacterTrait`)을 붙이고 떼는 것이다. 효과는
  그 특성의 바닐라 효과 그대로다.
- 바닐라 스펙트럼 이름 (More Traits 애드온이 밴드를 얹는 대상으로 확인됨): 이동, 탐지(은신), 민첩, 달리기, 둔기,
  사냥, 건축, 요리, 채집, 수리, 정비, 몸, 지구력, 건강, 용기, 중독, 운전, 손, 위장, 수면, 도끼, 의료, 학습,
  체력·근력·체중. 문서에 독서, 농사도 나온다. 청각은 호환 패치 설명에서 확인.
- 각 스펙트럼에 어떤 바닐라 특성이 붙는지 전체 목록은 공개 문서에 없다. 설명문에 나온 것은 겁쟁이 극복,
  광장공포증 치료, 청각 저하 정도다. 나머지 짝(서투름↔우아함, 눈에 띔↔눈에 안 띔, 손재주 등)은 이름으로 본
  **추정**이다.
- 댓글 불만: 긴 둔기 XP가 9997에서 멈춰 레벨이 오르내림, 운전 특성이 과하게 쌓임, 둔감 특성이 밤에 자주 깨움.

### 확장 API (모드 연동용)

- [TAS_Docs](https://github.com/GersonRess/TAS_Docs) 공개. `TAS.Spectrum.register`, `TAS.Spectrum.addBand`,
  `TAS.XP.actions`, `TAS.XP.registerPassive`, 서버 `TASSpectrumSystem.addXP(player, id, xp)`.
- 다른 모드 특성은 `"ToadTraits:gordanite"`처럼 이름공간 붙은 등록 이름으로 참조한다.
- 같은 레벨에 두 스펙트럼의 특성이 겹치면 아이콘이 약 1.5초마다 번갈아 깜빡인다.
- 애드온: [Traits As Skills - More Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3786253696)
  (구독 1만 6천). More Traits Definitive Edition 특성을 스펙트럼에 넣는 예제. 새 스펙트럼: 민첩, 창, 둔기 숙련,
  날붙이 숙련, 원거리 숙련, 생존력(면역), 정신 건강. 무기 종류별 처치 수를 센다. "More Traits - Dynamic"과 충돌.
- [This Is Me](https://steamcommunity.com/sharedfiles/filedetails/?id=3806020504)도 TaS 연동 애드온을 따로 낸다.
  TaS가 특성 진행 모드들의 공통 틀이 되어 가는 중이다.

### 우리 모드에 주는 뜻

- 특성이 **게임 도중에 바뀐다.** 청각 특성(예민한 청각, 난청, 귀머거리)에 따라 소리 계열 반경을 바꾸는 계획은
  특성을 캐시하지 말고 쓸 때마다 읽어야 한다. TaS뿐 아니라 ETW, DT, Adaptive Traits, Gyde's Trait Magazines,
  Traits Purchase System이 모두 도중에 특성을 바꾼다.
- 우리 강화는 특성을 붙이거나 떼지 않는다. 특성은 이 모드들의 영역이다. 강화 효과는 우리 상태값으로만 둔다.
- 화면: TaS는 캐릭터 정보 창에 '특성' 탭을 단다. 우리 강화 창은 이름이 겹치지 않게 하고, 같은 창에 탭을 단다면
  탭 이름을 '강화'로 분명히 한다.
- 원하면 나중에 TaS 애드온을 만들어 '강화 숙련' 같은 스펙트럼을 보여 줄 수는 있다. 필수는 아니다.

## 2. 다른 인기 B42 특성·직업·숙련 모드

ETW, MT(Legacy/Definitive), DT, SOTO는 다른 조사에서 다룬다. 아래는 그 밖의 모드다.

| 모드 | B42 | 구독 | 한 줄 |
| --- | --- | --- | --- |
| [Skill Recovery Journal](https://steamcommunity.com/sharedfiles/filedetails/?id=2503622437) | O | 282만 | 일지에 기술 XP를 적어 두고 다음 캐릭터가 되찾음 |
| [Fitness & Workout Overhaul](https://steamcommunity.com/sharedfiles/filedetails/?id=2940354599) | O (42.20) | 84만 | 체력·근력 XP 개편, 러닝머신·벤치프레스 |
| [Gyde's Trait Magazines](https://steamcommunity.com/sharedfiles/filedetails/?id=3342191739) | O (42.20) | 50만 | 잡지를 읽어 바닐라 특성을 얻거나 부정 특성을 지움 |
| [Become Desensitized B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3388017161) | 낡음 표시 | 17만 | 처치 수로 둔감 특성 획득 |
| [Somewhat Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3498347699) | O | 11만 | 긍정 16, 부정 16, 바닐라 14개 확장 |
| [Efficiency Skill Mod 2](https://steamcommunity.com/sharedfiles/filedetails/?id=3374408921) | O | 9만 6천 | 모든 시간 행동 속도를 올리는 새 기술 |
| [Toughness Skill](https://steamcommunity.com/sharedfiles/filedetails/?id=3545533939) | O | 9만 5천 | 처치로 오르는 정신력 기술. 패닉·통증·불편 감소 |
| [Traits Purchase System](https://steamcommunity.com/sharedfiles/filedetails/?id=3211693903) | O | 9만 2천 | 포인트로 특성을 사거나 부정 특성을 지움 |
| [Combat Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3427091746) | O | 6만 6천 | 무기 계열별 공격 간격 절반 특성 13개 |
| [Adaptive Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3622328997) | O (42.13+) | 5만 9천 | 시간·처치 수로 바닐라 특성 30개 획득·상실 |
| [Hephas Occupations and Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3256482412) | O | 5만 6천 | 균형형 직업·특성, 동적 획득 옵션 |
| [This Is Me](https://steamcommunity.com/sharedfiles/filedetails/?id=3806020504) | O (42.20) | 3만 7천 | 행동에 반응하는 특성 66개 |
| [Scavenger Skill B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3407792640) | O | 3만 3천 | 용기를 뒤질수록 오르는 기술. 추가 드롭 |
| [Legendary Professions and Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3669469283) | O (42.21) | 3만 2천 | 직업 13개, 3단 특성 줄 17개 |
| [Combat Mastering Skill](https://steamcommunity.com/sharedfiles/filedetails/?id=3435985650) | O | 2만 2천 | 공격 속도·피해 배율 기술 |
| [RPGSkillTree SP](https://steamcommunity.com/sharedfiles/filedetails/?id=3621388762) / [MP](https://steamcommunity.com/sharedfiles/filedetails/?id=3628753926) | O | 2만 / 1만 | 처치 XP로 레벨, 스킬 포인트로 트리 113개 |
| [Mastered Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=3423601261) | O (42.20) | 1만 9천 | 기술을 10으로 시작하는 특성 35개 |
| [Even More Traits 42.20](https://steamcommunity.com/sharedfiles/filedetails/?id=3777663603) | O | 1만 6천 | Lazolo 모드 이식. 특성 30여 개 |
| [Pro Mover Trait](https://steamcommunity.com/sharedfiles/filedetails/?id=3637951074) | O | 7천 | 가구를 기술·도구 없이 빠르게 옮김 |
| [Psionic Awakening](https://steamcommunity.com/sharedfiles/filedetails/?id=3749671906) | 일부 | 2천 5백 | 초능력 트리. 능동 기술이 많음 |
| [Skill Mastery Perks](https://steamcommunity.com/sharedfiles/filedetails/?id=3778564096) | O | 소수 | 기술 10 달성 시 보너스 |

### 모드별 요약

**Skill Recovery Journal** — 일지를 만들어 기술 XP와 레시피를 기록한다. 캐릭터가 죽으면 새 캐릭터가 읽어서 되찾는다.
재미: 죽음의 손실을 줄이는 '유산' 장치. 우리 강화와 겹치지 않음 (강화 포인트를 유산으로 넘기는 건 신뢰도·연구팀 쪽 설계 문제).

**Fitness & Workout Overhaul** — 체력·근력 XP를 규칙성, 휴식, 레벨로 보정한다. 러닝머신(전기 필요), 벤치프레스를 추가한다.
**무게의 50% 이상을 지고 다니면 근력 XP 보너스**(대신 빨리 지침). 가방을 멘 채 운동 가능. 체력·근력 XP 배율을
건드리는 다른 모드와 충돌할 수 있다고 적혀 있다.

**Gyde's Trait Magazines** — 바닐라 특성 잡지 13종: 영양사, 아웃도어맨, 손재주 좋음(Handy), 도끼 달인, 강도,
스피드광, 정리 정돈, 빠른 학습, 빠른 독서, 눈에 안 띔, 우아함, 손재주(Dexterous), 예민한 청각. 부정 짝이 있으면 먼저
부정 특성만 지운다. 귀머거리는 예민한 청각 잡지로 안 바뀐다. 기술 XP는 주지 않는다. 동적 특성 모드와 같이 쓰면
나중에 되돌려질 수 있다고 스스로 적음.

**Become Desensitized** — 처치 500부터 매일 자정에 둔감 획득 확률, 2000이면 확정. 겁쟁이·광장공포·폐소공포·혈액공포를
지운다. 직업·특성이 확률을 바꾼다. B42판은 2024-12 이후 갱신이 없고 'OUTDATED' 표시.

**Somewhat Traits** — 하드코어 멀티 서버용. 긍정 특성은 아주 약하고 부정 특성은 세다. 손재주 특성은 해당 시간 행동을
2배 빠르게 한다. 많이 취해서 달리면 넘어질 확률. 통계는 서버가 관리하고 부하를 시간에 나눠 처리한다.

**Efficiency Skill Mod 2** — 새 기술 '효율'. 시간 행동을 끝낼 때마다 XP. 레벨별 시간 배율: 0레벨 2.0, 2레벨 1.4,
3레벨 1.0, 5레벨 0.8, 10레벨 0.3. 구현은 `ISBaseTimedAction:adjustMaxTime`을 덮어쓰고 원래 함수를 이어 부른다
(로컬 설치본으로 확인). 결과는 원래 시간의 0.15~4배로 묶는다. **뒤지기·옮기기·줍기 속도 강화와 바로 겹친다.**

**Toughness Skill** — 처치로 오르는 '강인함' 기술. 레벨당 패닉 -10%, 통증 -5%, 불편 -5%, 불편 무시 문턱 +10%.
1배 XP로 만렙까지 약 4450 처치. Become Desensitized의 점진형 대안이라고 소개. **생존 '패닉·통증' 후보와 겹친다.**

**Traits Purchase System** — 전용 'Traits' 기술. 처치당 XP 기본 1, 기술 레벨당 XP 기본 10. 30레벨, 레벨당 90 XP.
얻은 포인트로 직업 특성(도끼 달인, 강도, 요리사, 둔감, 명사수, 정비, 올빼미 등)을 사거나 부정 특성을 지운다.
체형 특성(비만, 운동선수, 힘셈)은 살 수 없다. '포인트로 산다'는 구조가 우리 강화와 가장 닮았다. 다만 대상이 특성이다.

**Combat Traits** — 무기 계열별로 공격 사이 지연을 절반으로 하는 특성 13개. 힘이 높을 때 무거운 무기 지연 0, 지구력
소모 절반인 Powerlifter. `meleeDelay`를 바꾸는 모드와 충돌. 전투 영역이라 우리와 거리가 멂.

**Adaptive Traits** — 게임 시간이나 처치 수로 바닐라 특성 30개를 얻거나 잃는다. 알림 표시, 문턱은 샌드박스.
대상에 고양이 눈, 정리 정돈, 손재주, 서투름, 우아함, 눈에 띔, 빠른 회복, 올빼미, 하이커 등이 있다.

**Hephas Occupations and Traits** — '종말 몇 년 뒤' 테마. 직업마다 전문 기술, 고유 아이템. 특성을 동적으로 얻는 옵션이
많다. 둔감·용감 획득, 겁쟁이 상실이 들어 있어 Become Desensitized를 대체한다고 스스로 적음. SOTO, More Traits와
같이 켜면 돌아는 가지만 균형이 깨진다고 명시.

**This Is Me** — 66개. 우리와 겹치는 것만 뽑음:
- 고무 다리: 낙하 피해 -50% / 스파게티 다리: +20%
- 좋은 바느질: 옷과 장비 수명 2배 / 나쁜 바느질: 절반
- 신체 단련: 근육통 없음 / 몸 상태 나쁨: 2배
- 맨발 선호: 맨발이어도 발 보호 80% 유지
- 비위 약함·후각 생존자: 악취 영향 2배 / 무시
- 밤의 군주: 22~04시 불행·지루함 25% 아래 유지
- 야수: 밀치기 20~80% 강화
- 책 애호가, 할머니(요리 10% 더) 등 생활 특성. 멀티용 사회 특성(멘토: 주변 XP +20%)도 있음.

**Scavenger Skill B42** — 용기를 뒤질수록 오르는 '수색' 기술. 레벨 0~10 추가 드롭 확률 5%→50%, 추가량 0%→100%.
XP 표 0/75/150/300/750/1500/3000/4500/6000/7500/9000. 같은 작성자의 Driving Skill B42는 브레이크 +40%,
엔진 소음 -30%, 최고 속도 +30%, 충돌 피해 -50%까지. **우리 '운 좋은 손'과 정면으로 겹친다.**

**Legendary Professions and Traits** — 직업 13개와 3단 특성 줄 17개(견습 +1, 숙련 +2, 달인 +3). 비용 전부 샌드박스.
캐릭터 생성 때만 고른다. 기술 시작 레벨만 올리므로 우리와 겹치지 않음.

**Combat Mastering Skill** — 새 기술. 공격 속도 배율 0레벨 0.4 → 10레벨 2.0, 피해 배율 0.2 → 3.0. 레벨에 따라 특성을
얻고 잃는다. 작성자 스스로 너무 쉽다고 인정. 전투 영역.

**RPGSkillTree** — 한국인 제작(설명에 한국어 포함). [L] 또는 [K] 키로 트리 창. 좀비 처치 XP로 레벨업, 레벨당 1포인트,
XP가 쌓이면 초기화 포인트. 스킬 113개(SP판 76개). 처치 시 랜덤 박스(일반 2%, 희귀 0.1%, 전설 0.01%), 장신구
아티팩트, 무기 주입, 사망 시 XP를 되돌리는 '메모리 스톤'. 대부분 AI로 만들었다고 밝힘. 노드별 효과 목록은
설명에 없다. **포인트로 트리를 찍는 구조가 우리와 가장 가깝다.** 같이 켜는 사람이 있을 수 있으니 단축키 [L]/[K]는 피한다.

**Mastered Traits** — 기술을 10으로 시작하는 특성 35개. 비용 15/20/25 중 선택. Traits Purchase System과 같이 쓰라고 권함.

**Even More Traits 42.20** — Lazolo 원작 이식. 저거너트, 광전사, 주인공 보정, 세컨드 윈드, 밤 걷는 자 등. B42가 특성
모드를 한 번에 등록하다 하나가 깨지면 뒤의 특성 모드가 다 깨진다는 문제를 피하려고 자체 등록한다고 설명.
(우리가 특성을 안 만드는 이유가 하나 더 생김.)

**Pro Mover Trait** — 비용 1. 가구를 기술·도구 없이 들고 놓음, 절대 안 깨짐, 가방이 차도 무거운 가구를 들 수 있음,
내용물은 바닥에 자동으로 쏟음, 들기·놓기 75% 빠름. **운반 '무거운 짐', 캡스톤 '끌기'와 영역이 닿는다.**

**Psionic Awakening** — '텔레파시' 특성(8점)을 고르면 초능력 버튼과 트리가 생긴다. 능동 기술이 풍부하다:
원거리 두개골 분쇄, 감지(어둠·벽 너머, 최대 30칸, 표식은 고정된 메아리라 따라가지 않음), 본능(뒤에서 공격하려는
좀비 자동 처치), 물건 찾기(근처 용기·바닥을 금색 표시), 부수기, 충격(넘어뜨리기), 마음 표식, 끌어당기기(바닥 물건을
가방으로), 방어 봉쇄(근처 문·창문을 닫고 내구 최대 2배 보강), 원격 손(문·창문·전등·용기 조작), 좀비 꼭두각시,
명상(사이 회복, 스트레스 감소). 자원은 '사이'. 모자라도 강행할 수 있지만 모자란 만큼 '부하'가 쌓이고 부하가 차면
피로·스트레스·패닉·악몽, 최대치에서 폭주. 원형 메뉴를 열면 싱글에서는 게임이 멈춘다. B42는 문구 누락이 있다고 함.
작성자가 유지보수 중단.

**Skill Mastery Perks** — 기술 10 보너스: 근력 10 운반 +5, 체력 10 아이템 옮기기 거의 즉시, 정비 10 부품 탈착 빠름.
작은 모드지만 운반 한도·옮기기 속도와 겹친다.

**Survivor's Path** ([3778739730](https://steamcommunity.com/sharedfiles/filedetails/?id=3778739730), 소수) — 기술 XP와
처치로 생존자 레벨 100, 포인트 100, 10구역 원형 트리 100개. 선행·배타 조건 검사, 구매 확인 창, '지금 적용 중인 효과'
표시. UI 참고용.

## 3. 우리 후보와 겹치는 곳

| 우리 후보 (IDEAS.md) | 겹치는 모드와 내용 | 대응 |
| --- | --- | --- |
| 청각 연동 (소리 사다리) | TaS 청각 스펙트럼, Gyde 예민한 청각 잡지, ETW/DT 동적 청각 | 특성을 쓸 때마다 읽기 |
| 밤눈 | 바닐라 고양이 눈 + DT(Wwin12)·Adaptive Traits가 도중에 부여 | 고양이 눈 위에 더하기로 얹기 |
| 뒤지기, 옮기기, 줍기, 정리 | Efficiency Skill(모든 행동 0.3~2.0배), 바닐라·Somewhat 손재주, Skill Mastery Perks(체력 10 즉시 옮기기) | `adjustMaxTime` 체인에 곱하기로 얹고, 원래 함수를 반드시 이어 부름 |
| 운 좋은 손 | Scavenger Skill(추가 드롭 최대 50%·100%) | '처음 연 용기만'과 상한을 지키고, 같이 켜면 효과를 줄이는 옵션 검토 |
| 패닉·스트레스, 통증 | Toughness Skill(패닉 최대 -100%), Become Desensitized, TaS 용기, Hephas | 가장 붐비는 영역. 빼거나 '회복 속도'처럼 다른 축으로 |
| 낙하 | This Is Me 고무 다리(-50%) | 곱하기로 얹기 |
| 장비 내구 | This Is Me 좋은 바느질(2배) | 곱하기로 얹기 또는 뺌 |
| 무거운 짐, 끌기 | Pro Mover(가구 기술·도구 요구 제거, 75% 빠름) | 우리는 '든 채로 걷기'만. 들기 조건은 안 건드림 |
| 운반 한도 | Skill Mastery Perks(+5), MT의 짐꾼 계열 | 더하기로 얹기 |
| 찾는 물건 표시 | Psionic 물건 찾기 | 같이 켤 사람이 적음. 그대로 둠 |
| 벽 너머 윤곽, 기척 펄스 | Psionic 감지 | 같이 켤 사람이 적음. 그대로 둠 |
| 지구력 | Combat Traits Powerlifter(무거운 무기 지구력 절반), TaS 지구력 | 무기 쪽은 건드리지 않음 |

## 4. 강화로 가져올 만한 재미있는 아이디어

`겹침`은 위 모드와 영역이 닿는 것. 표시가 없으면 조사한 모드 중 같은 것이 없거나 B42 인기 모드에는 없다.

### 수색

| 아이디어 | 효과 | 출처·겹침 |
| --- | --- | --- |
| 등 뒤 경고 | 뒤에서 좀비가 공격 거리 안으로 들어오면 화면 가장자리가 번쩍이고 짧은 소리. 찍을수록 미리 알려 주는 거리 증가. 처치는 하지 않음 | Psionic '본능'을 감지만 남긴 것 |
| 고정 메아리 | 벽 너머 윤곽의 하위 단계. 좀비를 따라가지 않고 그 순간 위치에 잠깐 남는 표식 | Psionic 감지 표식 방식 |
| 표식 남기기 (능동) | 보고 있는 곳에 깜빡이는 핀을 남김. 지도에도 표시되고 일정 시간 뒤 사라짐. 찍을수록 개수와 지속시간 | Psionic '마음 표식' |
| 긴 손 | 1~3칸 떨어진 문, 창문, 전등 스위치, 용기를 조작. 찍을수록 거리 | Psionic '원격 손' |
| 손에 익음 | 강화한 손기술을 실제로 쓸수록 그 노드 효과가 조금 더 커짐 (상한 있음). 포인트 위에 얹는 숙련 | TaS·Scavenger의 '써서 오르는' 방식 |
| 첫 손 보너스 | 처음 여는 용기에서만 추가 물건 확률. 이미 '운 좋은 손'에 있음. Scavenger와 같이 켤 때 합산 상한 | 겹침: Scavenger Skill |

### 운반

| 아이디어 | 효과 | 출처·겹침 |
| --- | --- | --- |
| 긴 팔 | 바닥 물건을 줍는 거리 증가 (몇 칸 떨어진 물건을 걷지 않고 줍기) | Psionic '끌어당기기' |
| 짐 지고 단련 | 운반 한도의 일정 비율 이상을 지고 걸으면 근력 XP 조금 | 겹침: Fitness & Workout Overhaul '무게 훈련' |
| 가구 다루기 | 가구를 든 채 걷는 속도와 놓는 속도. 들 수 있는지 판정(기술·도구)은 바닐라 그대로 | 겹침: Pro Mover |
| 숙련된 짐꾼 | 운반 중 넘어짐·지구력 페널티를 줄이는 노드를 '근력 레벨에 비례'로 키움 | Skill Mastery Perks의 기술 10 보너스를 일반화 |

### 생존

| 아이디어 | 효과 | 출처·겹침 |
| --- | --- | --- |
| 불편 무시 문턱 | 옷 불편함이 일정 값 아래면 무시 | 겹침: Toughness Skill |
| 빠른 진정 | 패닉 '쌓이는 양'이 아니라 '가라앉는 속도'만 올림. 패닉 감소 모드와 축을 나눔 | Toughness·Desensitized와 축 분리 |
| 고무 다리 | 낙하 피해 감소. 곱하기로 얹음 | 겹침: This Is Me |
| 맨발 적응 | 맨발일 때 발 부상 확률 감소 | 겹침: This Is Me '맨발 선호' |
| 악취 둔감 | 시체 냄새로 인한 불행·스트레스 감소 | 겹침: This Is Me '후각 생존자' |
| 밤 체질 | 밤에 지루함·불행이 덜 쌓임 | 겹침: This Is Me '밤의 군주' |

### 능동

| 아이디어 | 효과 | 출처·겹침 |
| --- | --- | --- |
| 급히 막기 | 반경 안 열린 문·창문을 한 번에 닫고 잠깐 내구를 올림. 대기시간 김 | Psionic '방어 봉쇄' |
| 숨 고르기 | 앉아서 몇 초 동안 스트레스·패닉·지루함을 내림. 그동안 무방비 | Psionic '명상' |
| 집중력 게이지 | 능동 기술 공통 자원. 대기시간 대신 또는 함께. 모자라면 강행 가능, 대신 피로·스트레스 대가 | Psionic '사이·부하' |
| 강행 폭주 | 집중력 부하가 끝까지 차면 큰 소리가 나서 무리가 몰려옴. 함성의 '실수 버전' | Psionic '사이오닉 비명' |
| 원형 메뉴 | 능동 기술을 원형 메뉴로. 싱글에서는 메뉴가 열린 동안 멈춤 | Psionic 인터페이스 |

### 화면·체계

- 노드 툴팁에 '지금 적용 중인 효과' 합계를 보여 준다 (Survivor's Path).
- 트리 창 단축키는 [L], [K]를 피한다 (RPGSkillTree가 씀).
- 선행·배타 조건을 구매 전에 검사하고 확인 창을 띄운다 (Survivor's Path).

## 5. 호환 원칙 정리

1. 특성을 만들거나 붙이고 떼지 않는다. 특성은 TaS, ETW, DT, Gyde, Traits Purchase System, Adaptive Traits의 영역이다.
   B42는 특성 모드 하나가 깨지면 뒤의 특성 모드가 같이 깨진다는 보고도 있다 (Even More Traits 설명).
2. 특성은 캐시하지 않고 쓸 때마다 읽는다. 도중에 바뀐다.
3. 시간 행동 속도는 `adjustMaxTime` 체인에 곱하기로 얹고, 원래 함수를 이어 부른다. Efficiency Skill Mod 2도 같은
   함수를 덮는다.
4. 패닉·통증은 가장 붐빈다 (Toughness, Desensitized, TaS 용기, Hephas). 넣는다면 '회복 속도'처럼 다른 축으로.
5. 기술 시작 레벨이나 XP 배율은 건드리지 않는다 (Legendary, Mastered Traits, Fitness Overhaul 영역).

## 출처

- Traits As Skills: https://steamcommunity.com/sharedfiles/filedetails/?id=3784847437
- TAS 프레임워크 문서: https://github.com/GersonRess/TAS_Docs (FRAMEWORK-EN.md)
- TaS More Traits 애드온: https://steamcommunity.com/sharedfiles/filedetails/?id=3786253696
- TaS Silent Weapons Compat: https://steamcommunity.com/sharedfiles/filedetails/?id=3790588736
- 그 밖의 모드: 2장 표의 링크
- 구독 수·날짜: Steam `ISteamRemoteStorage/GetPublishedFileDetails` API
- Efficiency Skill Mod 2 구현: 로컬 설치본 `steamapps/workshop/content/108600/3374408921`
