# Dynamic Traits(DTEM)와 SOTO 조사

[IDEAS.md](../IDEAS.md)의 '겹칠 수 있는 다른 모드' 조사 중 두 모드 몫. 2026-10-08 기준.

- 두 모드는 **서로 비호환**이다. DTEM 설명에 SOTO가 비호환으로 적혀 있다. 그래서 우리는 각각과만 같이 돌면 된다.
- 둘 다 바닐라 특성의 수치를 바꾸고, 특성을 플레이 중에 얻고 잃게 만든다. 우리 강화가 특성을 읽을 때는 **매번 지금 상태를 읽어야** 한다 (캐시 금지).

## 1. 기본 정보

| | Dynamic Traits and Expanded Moodles (DTEM) | SOTO (Simple Overhaul: Traits and Occupations) |
| --- | --- | --- |
| Workshop | [2459400130](https://steamcommunity.com/sharedfiles/filedetails/?id=2459400130) | [2840805724](https://steamcommunity.com/sharedfiles/filedetails/?id=2840805724) |
| Mod ID | `DynamicTraits` | `SimpleOverhaulTraitsAndOccupations` |
| 구독자 | 약 39.8만 | 약 74.7만 |
| B42 버전 | DTEM 2.2.1, B42.20~42.21+. SP, MP 호스트, 전용 서버 지원 | 2.1.0.4 (2026-03-09, 42.15 대응). 42.12/42.13/42.14용 폴더 따로 유지. **B42 MP는 쓰지 말라고 공지** |
| 필수 모드 | [Moodle Framework](https://steamcommunity.com/workshop/filedetails/?id=3396446795) (DTEM보다 먼저 로드) | 없음 |
| 제작 | PepperCat 원작, B42 유지보수 Afyrmo | Hea (전신은 [More Simple Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=2792245343)) |
| 문서 | [B42 High Level Guide (구글 시트)](https://docs.google.com/spreadsheets/d/1RtE2lDJrWvPKiyCmgaGv_E8gXGsb0Hkl), [B41 가이드](https://docs.google.com/spreadsheets/d/14dMghH3nbw58-DEIbczaYq9zOdWX0JF4EYOqn7tvjV8/edit?usp=sharing), [B42 Quick Guide 스레드](https://steamcommunity.com/workshop/filedetails/discussion/2459400130/500617242799623461/) | 공개 문서 없음. [변경 기록](https://steamcommunity.com/sharedfiles/filedetails/changelog/2840805724)과 [토론](https://steamcommunity.com/sharedfiles/filedetails/discussions/2840805724)이 사실상 문서. 게임 안 설명에 수치가 있다고 함 |
| 비호환 (명시) | Evolving Traits World, SOTO, Dynamic Traits - Sauce Edition | "어떤 특성 모드와도 안 맞을 수 있음" |
| 호환 (명시) | Fitness & Workout Overhaul, Snake's ModPack (B41/B42) | B41 시절 SOMW, Braven's/Pie's First Aid Overhaul, Woodcutting Skill, Tidy Up Meister 등 |
| GitHub | 못 찾음 | 못 찾음 |

DTEM은 세이브 중간 추가는 되지만, B42에서 **빼면 세이브가 안 열릴 수 있다**고 한다. SOTO도 새 세이브 전용을 권한다.

## 2. DTEM 기능

DTEM 가이드 시트 기준. 특성 142개(고를 수 있는 것 101), 직업 25개 재조정, 동적 조건 시스템 17개.

### 2.1 특성을 얻고 잃는 방식

| 방식 | 내용 | 예 |
| --- | --- | --- |
| 기술 레벨 | 기술 하나 또는 여럿이 기준에 닿으면 얻음. 직업 시작 보너스는 기준을 최대 2 낮춤 | Baseball Player는 Blunt 6, Handy는 Carving·Maintenance·Masonry·Woodwork 각 7, Eagle Eyed는 Aiming 7, Inconspicuous는 Sneak 10, Graceful은 Lightfoot 10 |
| 기술 합계 | 여러 기술 레벨의 합 카운터 | 전투·은신·감각 기술 합 33이면 Hard of Hearing 제거, 55면 Keen Hearing 획득 (Deaf면 막힘). 제작·생존 합 55면 Slow Learner 제거, 91이면 Fast Learner |
| 무들 수준 | 지금 무들 수준으로 바로 붙고 떨어짐 | 지루함 2+면 Sleepyhead, 스트레스 3+면 Nightmares, 지루·불행·스트레스·배고픔이 모두 0이면 Wakeful |
| 몸 상태 | 체중·Fitness·Strength 상태로 부가 특성이 붙음 | 저체중이면 Flimsy, Prone to Illness, Slow Healer. 과체중이면 Flabby, Hearty Appetite, High Thirst |
| 처치 수와 생존 시간 | 생존 720시간 뒤부터 굴림. 처치 수·생존 시간이 많을수록 유리 | Cowardly 제거 → Brave → Desensitized → Bloodlust |
| 누적 카운터 | 행동을 할수록 쌓이는 값 | 아래 표 |

| 카운터 | 쌓이는 방법 | 기준 |
| --- | --- | --- |
| 인벤토리 옮기기 | 끝난 옮기기 동작의 아이템 실제 무게 | All Thumbs 제거 -75,000, Dextrous 획득 200,000 |
| 인벤토리 정리 | 옮긴 무게 × 직업·몸 상태 배율 | Disorganized 제거 -100,000, Organized 300,000 |
| 바깥 적응 | 차 밖 야외 시간. 비·눈·바람·안개·천둥 가중 | Outdoorsy 500,000 |
| 어둠 적응 | 빛 0.5 이하에서 깨어 있는 시간. 밝으면 감소 | Cat's Eyes 100,000 |
| 비 적응 | 비 맞은 시간 | Pluviophobia 제거 0, Pluviophile 40,000 |
| 활동 | 달리기 +1, 전력질주 +2, 운동 1회 +10, 전투. 걷기는 안 셈 | Sedentary -20,000, Physically Active 40,000 |
| 공포증 | 두려운 환경에 노출 | Agoraphobic·Claustrophobic 제거 175,000 |
| 니코틴·술·카페인 | 끊은 시간과 섭취량 | Smoker 제거 1,080. Alcoholic ±44,640. 카페인 중독 ±20,160 |
| 식사·체중 | 체중, 스트레스, 먹는 행동 | Anorexia -720 획득, 720 제거 |

### 2.2 새 특성과 생존 시스템 (수치 있는 것)

| 기능 | 효과 |
| --- | --- |
| Thick Blood / Thin Blood | 출혈 체력 손실 약 ×0.5 / ×2. `OnPlayerGetDamage`의 BLEEDING 피해를 **사후 환불**하거나 한 번 더 깎는 방식. 상처 자체는 안 건드림 |
| Iron Gut (재정의) | 알레르기 ×0.9, 과다복용 ×0.7, DTEM 일반 식중독 ×0.8 |
| Prone to Illness / Resilient | 바닐라 CatchACold 누적 ×1.70 / ×0.45 (바닐라 값). 걸린 뒤 회복 ×0.5 / ×1.5 |
| 젖음 감기 | 젖음 1~4단계에서 10분마다 +1~+4 누적. 3·4단계는 1/(500-누적), 1/(300-누적) 확률로 감기 |
| 감기 심화 | 감기 3·4단계에서 두통·피로·지구력 감소, 식중독 누적. 실시간 25초 창, 날짜 길이와 무관 |
| 상처 스트레스·감염 식중독 | 열린 상처마다 10분에 1/5 확률로 스트레스 +0.10~0.15. 감염된 상처는 식중독을 만들어 죽을 수도 있음 |
| Heavy Load 골절 | 과적 무들 4단계, 차 밖. 1분마다 기본 1/15,000. 약함·Frail은 위험 증가, Strong·Stout·Lucky는 감소. 걷기·달리기·전력질주는 더 위험. 골절 시간 30~49 |
| 극심한 피로 기절 | 피로 4단계, 패닉 0, 깨어 있음. 누적 125 + 약 8분 가만히 있으면 강제 수면 |
| 과다복용 | 진통제·수면제·항우울제·베타차단제 +12, 비타민 +10. 50/70/85에서 스트레스·젖음, 피로, 식중독 |
| 알레르기 | 약 알레르기 +30/알약, 야생 식물 알레르기. 20/40/60/80에서 재채기 → 팔·다리 통증 → 체력 감소·식중독 |
| Bloodlust | 마지막 처치 후 12/24/48/72시간마다 스트레스·지루·불행·분노 증가. 처치하면 초기화 |
| 무들 연쇄 | 분노 → 스트레스·불행, 패닉·스트레스 → 젖음 (1분마다 확률) |
| Prodigy | 달리기 Fitness XP +3, 전력질주 +5, 운동 xpMod×3 |
| 몸 상태 XP 빚 | Flimsy·Frail은 Strength XP, Flabby·Brittle Knees는 Fitness XP를 1~2레벨치 빼고, 상태가 풀리면 돌려줌 |
| 감정 관리 책 20권 | 무게 0.1. Bloodlust 금단을 늦춤. 서점·거실 선반 등에 0.01 가중치로 분포 |
| 직업 | 25개 비용·기술·특성 재조정. 바닐라 정의에서 **차이만 더하는** 방식 (예: Firefighter 0 → -6, Ax-pert 부여) |

Lucky/Unlucky는 DTEM 굴림에만 쓰이고 **B42 루팅에는 효과가 없다**고 명시한다.

### 2.3 DTEM이 건드리는 바닐라 지점 (우리 쪽 위험)

| 지점 | 내용 | 우리에게 닿는 곳 |
| --- | --- | --- |
| 인벤토리 옮기기 동작 | 끝난 동작의 `getActualWeight()`로 카운터를 올림 | 뒤지기·옮기기·줍기 속도. 속도만 바꾸면 카운터는 영향 없음 |
| `ISFitnessAction:exeLooped` | 운동 보너스 | 없음 |
| 마시기 동작, 음식 `OnEat` | 버섯, 베리, 커피, 뜨거운 음료, 껌, 조리 음식 30여 개의 `OnEat`을 자기 함수로 교체 | '같은 음식에서 더 회복'을 `OnEat`로 구현하면 충돌. 스탯 변화 시점에 배율로 걸어야 함 |
| 아이템 값 | 비타민 FatigueChange -4 → -10, UseDelta 0.2 → 0.1 | 없음 |
| 스탯 직접 변경 | 스트레스, 불행, 지루, 분노, 젖음, 피로, 지구력, 식중독을 1분·10분마다 더함 | 생존 스탯 노드. 우리 배율이 DTEM 증가분까지 줄이는지 정해야 함 |
| BLEEDING 피해 | 사후 환불 | 출혈 감소 노드와 같은 축 |
| CatchACold, 젖음 | 별도 감기 굴림 | 체온·젖음, 감기 저항 노드 |
| Heavy Load 4단계 | 골절 굴림의 입력 | 운반 한도·과적 노드. 한도를 올리면 무들이 내려가서 골절도 줄어듦 (자연스러운 연동) |
| ForceSleep | 기절 | 선잠, 피로 노드 |
| 직업·특성 정의 | 비용·기술·특성 변경, 바닐라 특성 비용 변경 | 없음 (우리는 특성을 만들지 않음) |
| Moodle Framework | 커스텀 무들 | 우리가 무들을 띄우면(육감 등) 같은 프레임워크 쓸지 확인 |

## 3. SOTO 기능

공개 목록이 없어서 변경 기록 9쪽과 토론에서 모았다. B42 최신 수치는 일부만 확인됨.

### 3.1 직업

26개 추가: Tailor, Deliveryman, Loader, Truck Driver, Soldier, Botanist, Grave Digger, Dancer, Priest, Weightlifting Instructor, Detective, School Teacher, Cleaner(Janitor), Stuntman, Gas Station Operator, Camp Counselor, Drag Racer, Junkyard Worker, Lifeguard, Demolition Worker, Butcher, Paparazzi, Miner, Store Employee, Criminal, Animal Control Officer. B42에서 Huntsman, Veterinarian 추가.

| 직업 | 눈에 띄는 것 |
| --- | --- |
| Weightlifting Instructor | Strength +3, Strong Back, Nutritionist |
| Construction Worker | Strong Back |
| Gas Station Operator | Experienced Refueler: 옮기기·주유·기름 빼기 시간 -25%. Dextrous와 같이 쓰면 -60% (B41) |
| Grave Digger | Accustomed to the Dead / Used to Smell: 시체 냄새 구역질 관련 |
| Priest | 기도문 쓰기, 기도로 스트레스·지루·불행 감소 (B42에서 Priestly Spirituality 특성은 삭제) |
| Miner | Cat's Eyes, Miner's Endurance: 곡괭이 휘두르기 지구력 ×0.67 |
| Lumberjack | Heavy Axe My Beloved: 무거운 도끼 지구력 배율 |
| Demolition Worker | Strong Grip: 무거운 긴 둔기 지구력 배율 |
| Butcher | 칼·도끼 주손 사용 시 XP +20% |
| Firefighter | Break-In Technique (B42 추가, 내용 미확인. 이름상 문 침입 계열이라 '빠루 따기'와 겹칠 수 있음) |
| Lifeguard | Breathing Technique |
| 수색 강한 직업 | Park Ranger, Botanist, Detective, Junkyard Worker, Camp Counselor는 Search Mode(채집) 보너스 큼 |

### 3.2 특성 (확인된 것)

| 특성 | 효과 (수치는 마지막으로 확인된 값) |
| --- | --- |
| Strong Back / Weak Back | 최대 운반 무게를 Strength 레벨당 1~2 늘림 / 줄임. Weak Back은 과적 3·4단계에서 목 통증. B42에서는 토르소 근육 긴장도 줄임. **B42에서 다시 불러오면 보너스가 사라지는 버그 보고**, MP 미작동 |
| Dextrous / All Thumbs | 옮기기 시간 -50% / +100% (바닐라는 +300%). `SOTOISInventoryTransferAction.lua`로 바닐라 옮기기 동작을 덮음 |
| Disorganized, All Thumbs 제거 | 옮긴 무게가 쌓이면 제거 |
| Calm-minded (B42) | 스트레스 최대 50%, 스트레스·패닉이 빨리 내려감 |
| Breathing Technique | 멈춰 있으면 지구력 회복 증가, 앉으면 2배 (앉기 +300%). 차에 앉아도 앉은 것으로 침 |
| Marathon Runner | 달리는 중 지구력 회복 |
| Tireless (구 Relentless) | 휘두르기 지구력의 절반을 20% 확률로 돌려받음. 팔 근육 긴장 감소 |
| Thick Blood / Liquid Blood | 출혈 피해 감소 / 증가 |
| Low Sweating / Excessive Sweating | 젖음·갈증 증감 |
| Hearty Appetite, Light Eater | 배고픔 +50% / -25% |
| High Thirst, Low Thirst | 갈증 +100% / -50% |
| Wakeful / Sleepyhead | 피로 증감 ±30%. 모든 캐릭터는 Fitness 레벨당 피로 -2% |
| 지구력 기본 규칙 | 회복 배율 Fitness에 따라 70~160%, 소모 90~43%. 과체중·비만은 회복 -30/-60% |
| Weak Stomach / Iron Gut | 식중독 ±30% |
| Allergic | 재채기가 좀비를 부름. 실외 50칸, 실내 25칸, 휴지로 막으면 5칸 |
| Smoker | 기침 반경 20~30칸 (실내 절반). 금연하면 특성 제거 (28~32일) |
| Snorer | 코골이 30칸 (실내 15칸) |
| Alcoholic | 24/48/96시간 금단. 술을 끊으면 제거 |
| Chronic Migraine, Depressive, Panic Attacks | 주기적 두통, 우울 단계, 공황 발작 |
| Lark / Owl | 시간대별 피로 증감 |
| Optimist | 지루함 -50%, 일정 시간 불행 상한 50% |
| Sensitive Digestion | 과식 시 통증·구역질 |
| Nyctophobic | 빛 없으면 패닉·스트레스 (B42에서 남아 있는지 미확인) |
| 기술 +1 특성들 | Woodworker, Smasher, Spearer, Fencer, Potter, Glassblower, Tracker 등. 기술 6레벨에 얻음 (샌드박스로 범주별 켜고 끔) |
| Commercial Driver | 운전 중 졸음 덜 쌓임 |

### 3.3 얻고 잃는 방식

- 샌드박스로 켜고 끔: Cowardly·Pacifist 제거, Brave·Desensitized 획득, Smoker·Alcoholic·All Thumbs·Disorganized·Sunday Driver·Clumsy·Conspicuous 제거, Graceful·Inconspicuous 획득.
- Brave·Desensitized는 생존 일수와 처치 수 범위 (예: Brave 21~35일, 3,000~4,500 처치. Desensitized 49~63일, 6,000~9,000 처치. B41 값).
- 기술 레벨 6에서 '+1 기술' 특성을 얻음. 게임 중 얻은 특성은 XP 배율을 주지 않음.
- 모든 캐릭터는 달리면 Fitness XP를 추가로 얻음 (오래 달릴수록 증가).

### 3.4 SOTO가 건드리는 바닐라 지점 (우리 쪽 위험)

| 지점 | 내용 | 우리에게 닿는 곳 |
| --- | --- | --- |
| `ISInventoryTransferAction` | 자기 파일로 `update`/`perform`를 덮음. 토론에 nil 오류, MP 거래 오류 보고 다수 | **뒤지기·옮기기·줍기 속도 노드와 같은 함수.** 덮지 말고 감싸야 하고, 로드 순서에 상관없이 배율이 곱해지게 해야 함 |
| 최대 운반 무게 | Strong Back/Weak Back이 값을 바꿈. 재접속 시 사라지는 버그로 보아 한 번 설정하는 방식으로 추정 | **운반 한도 노드.** 둘 다 `setMaxWeightBase`류를 쓰면 마지막 쓴 쪽이 이김. 우리는 계산 시점 보정이 필요 |
| 지구력·피로·배고픔·갈증·젖음 | 증감에 배율을 곱함 | 생존 스탯 노드. 같은 델타에 곱하면 겹쳐 곱해짐 (의도대로) |
| 스트레스 상한 | Calm-minded가 50%로 자름 | 패닉·스트레스 노드. 충돌은 없음 |
| 소리 | 재채기·기침·코골이로 좀비 부르기 | 함성 반경 기준값 참고. 조용한 손과는 다른 소리 |
| 체중 | 시작 체중 버그 수정, 칼로리 소모 | 없음 |
| 무기별 지구력 | 곡괭이·무거운 도끼·무거운 둔기 | 없음 |
| Search Mode 보너스 | 직업·특성별 채집 확률·시야 | 우리 수색은 용기 루팅이라 직접 충돌 없음 |
| 바닐라 특성 | Motion Sickness, Mason, Artisan 제거. 이름 변경 다수 | 특성 ID에 기대는 코드는 없는 경우를 견뎌야 함 |

### 3.5 제작자 성향 (참고)

- 제작자는 컨테이너 루팅 보너스에 부정적이다. "같은 용기를 뒤지면 누구나 같은 걸 찾아야 한다"는 입장 ([제안 스레드](https://steamcommunity.com/workshop/filedetails/discussion/2840805724/3459345750023446214/)). 우리 '운 좋은 손'은 SOTO 코드와는 안 부딪히지만, SOTO 사용자층 취향과는 반대일 수 있다.
- B41 More Simple Traits는 More Traits와 같이 쓸 때 Strong Back, Weak Back을 꺼서 겹침을 피했다. 운반 무게는 특성 모드끼리도 서로 피하는 영역이다.

## 4. 겹침 판정 요약

| 우리 후보 (IDEAS.md) | DTEM | SOTO | 판정 |
| --- | --- | --- | --- |
| 운반 한도 | 간접 (과적 골절) | **Strong Back/Weak Back** | 겹침. 더하기로 얹고, 덮어쓰기 금지 |
| 과적 완화·과적 체력 | Heavy Load 골절 | Weak Back 목 통증 | 부분 겹침. 무들 단계 자체는 바꾸지 말 것 |
| 뒤지기·옮기기·줍기 | 옮기기 카운터 (읽기만) | **옮기기 동작 덮음, Dextrous 값 변경** | 기술적 충돌 위험 큼 |
| 밤눈 | Cat's Eyes 동적 획득 | Miner에 Cat's Eyes | 바닐라 특성 위에 곱하기면 괜찮음 |
| 소리 사다리 (청각 연동) | Keen Hearing·Hard of Hearing 동적 | 없음 | 특성을 매번 읽으면 괜찮음 |
| 패닉·스트레스 | 스트레스 연쇄 | Calm-minded | 부분 겹침 |
| 지구력 | Physically Active | Breathing Technique, Marathon Runner, Tireless, Fitness 배율 | 겹침. 낮은 배율로 |
| 피로·수면, 선잠 | 기절, Wakeful 등 동적 | Wakeful ±30%, Lark/Owl | 부분 겹침 |
| 배고픔·갈증 | 동적 식욕 특성 | 배율 특성 | 부분 겹침 |
| 체온·젖음, 감기 저항 | **젖음 감기 굴림** | Sweating 특성 | 겹침 |
| 상처 (출혈) | **Thick Blood** | **Thick Blood** | 강하게 겹침 |
| 질병 (식중독) | Iron Gut 재정의, 감염 식중독 | Iron Gut ±30% | 겹침 |
| 감염 (좀비 감염 확률) | 없음 | 없음 | 안전 |
| 육감, 소리 방향, 기척 펄스, 루팅, 빠루, 알아채기 | 없음 | Break-In Technique만 미확인 | 대체로 안전 |
| 함성·페로몬·위장 냄새 | 없음 | 소리 내는 부정 특성 (반대 방향) | 안전 |

## 5. 강화로 만들 만한 아이디어

⚠ = 두 모드의 영역과 겹침. ⚠⚠ = 강하게 겹침 (빼거나 약하게).

### 수색

| 아이디어 | 효과 | 참고 | 겹침 |
| --- | --- | --- | --- |
| 어둠 적응 | 밤눈의 변형. 어두운 곳에 오래 있을수록 보정이 점점 커지고, 밝은 곳에 나가면 줄어듦 | DTEM Cat's Eyes 카운터 | ⚠ (Cat's Eyes 위에 곱하기면 됨) |
| 시체 비위 | 시체를 뒤지거나 옆에 있을 때 구역질·스트레스가 덜 쌓임 | SOTO Grave Digger | ⚠ |
| 숨죽이기 (능동) | 몇 초간 내 소음 반경(걸음, 문, 기침, 재채기)이 크게 줄어듦. 대기시간 김 | SOTO 재채기·기침 반경 | ⚠ (부정 특성의 대가를 지움) |
| 손에 익음 | 뒤지기 속도 노드가 실제로 옮긴 무게만큼 조금씩 더 자람. 상한 있음 | DTEM 옮기기 카운터 | 구조만 빌림 |

### 운반

| 아이디어 | 효과 | 참고 | 겹침 |
| --- | --- | --- | --- |
| 젖 먹던 힘 (능동) | 몇 초~수십 초간 운반 한도가 크게 오름. 끝나면 피로·근육 긴장 | Strong Back의 능동판 | ⚠ 낮음 (일시적) |
| 따르기 손 | 연료·물 붓기, 주유, 기름 빼기 속도 증가 | SOTO Experienced Refueler | ⚠ |
| 허리 버팀 | 무거운 짐을 오래 들어도 등·목 근육 긴장이 덜 쌓임 | SOTO Strong Back, Weak Back | ⚠ |
| 과적 다리 | 과적 4단계에서 넘어지거나 다칠 위험 감소 (바닐라 B42 판정 확인 필요) | DTEM Heavy Load 골절 | ⚠ (DTEM 굴림은 건드리지 말고 우리 쪽 효과만) |
| 빠른 내려놓기 (능동) | 멘 가방이나 든 무거운 물건을 즉시 내려놓고 바로 뜀 | 없음 | 안전 |

### 생존

| 아이디어 | 효과 | 참고 | 겹침 |
| --- | --- | --- | --- |
| 호흡 조절 | 멈춰 있거나 앉아 있을 때 지구력 회복 증가 | SOTO Breathing Technique | ⚠ |
| 침착 | 스트레스·패닉이 빨리 가라앉음 (상한은 두지 않음) | SOTO Calm-minded | ⚠ |
| 버티기 | 극심한 피로에서 잠들거나 쓰러지기까지 시간이 늘어남 | DTEM 기절 | ⚠ |
| 근육 회복 | 근육 긴장(근육통)이 빨리 풀림 | SOTO Tireless, Strong Back | ⚠ |
| 날씨 둔감 | 비·눈·추위 속 기분 저하 감소 | DTEM Pluviophobia | ⚠ 낮음 |
| 마음 다잡기 (능동) | 누르면 패닉이 즉시 크게 내려감. 대기시간 김 | SOTO Panic Attacks, DTEM 공포 경로 | ⚠ |
| 심호흡 (능동) | 몇 초간 서서 지구력을 빠르게 회복. 움직이면 끊김 | Breathing Technique의 능동판 | ⚠ 낮음 |
| 지혈 | 출혈 피해 감소 | 양쪽 Thick Blood | ⚠⚠ (빼는 쪽 권장) |
| 금단 완화 | 담배·술·카페인 금단 증상 감소 | 양쪽 중독 시스템 | ⚠⚠ (부정 특성 무력화. 빼는 쪽 권장) |

### 설계 참고

- **환불 방식**: DTEM Thick Blood는 바닐라 피해가 들어간 뒤 일부를 되돌려 준다. 바닐라 값을 덮지 않고 배율을 얹는 우리 원칙과 같은 방식이다. 스탯 노드 구현에 쓸 만하다.
- **함성 반경 기준**: SOTO 재채기 실외 50칸 / 실내 25칸, 코골이 30칸 / 15칸, 기침 20~30칸. 실내는 절반으로 줄이는 규칙. 함성은 이보다 훨씬 커야 존재감이 있다.
- **특성 상태는 매번 읽기**: 두 모드 모두 Keen Hearing, Cat's Eyes, Dextrous 같은 바닐라 특성을 플레이 중에 붙였다 뗀다.
- **XP는 건드리지 않기**: 두 모드 모두 XP 배율·XP 빚을 크게 쓴다. 우리 강화가 XP를 건드리면 바로 겹친다.

## 출처

- DTEM Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=2459400130
- DTEM B42 High Level Guide: https://docs.google.com/spreadsheets/d/1RtE2lDJrWvPKiyCmgaGv_E8gXGsb0Hkl
- DTEM B41 High Level Guide: https://docs.google.com/spreadsheets/d/14dMghH3nbw58-DEIbczaYq9zOdWX0JF4EYOqn7tvjV8/edit?usp=sharing
- DTEM B42 Quick Guide: https://steamcommunity.com/workshop/filedetails/discussion/2459400130/500617242799623461/
- SOTO Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=2840805724
- SOTO 변경 기록: https://steamcommunity.com/sharedfiles/filedetails/changelog/2840805724
- SOTO 토론 (B42 버그 보고, 밸런스, 제안): https://steamcommunity.com/sharedfiles/filedetails/discussions/2840805724
- SOTO Strong Back 버그 스레드: https://steamcommunity.com/workshop/filedetails/discussion/2840805724/694249895115368060/
- More Simple Traits (SOTO 전신): https://steamcommunity.com/sharedfiles/filedetails/?id=2792245343

## 남은 확인

- SOTO B42 특성 전체 목록과 최신 수치. 게임 안 설명이나 모드 파일을 봐야 한다 (공개 문서 없음).
- SOTO Strong Back이 최대 무게를 어떤 함수로 바꾸는지.
- SOTO Break-In Technique의 실제 효과.
- 바닐라 B42에서 과적이 넘어짐·부상을 일으키는지.
