# 감지·시야·은신·유인·탈출 모드 조사

[강화 후보](../IDEAS.md)의 수색(보기, 느끼기·듣기, 알아채기)과 생존(능동 기술)에 넣을 재료를 모은다. 거르지 않고
모았다. 빌드 표시와 갱신일은 Steam API(2026-10-08 조회)의 태그와 `time_updated` 기준이다. B42 표시가 있어도 최신
42.21에서 도는지는 따로 확인하지 않았다.

IDEAS.md에 이미 있는 SixthSense, Visual Sounds B42, Sound Direction Indicator B42, Common Sense, Zombie Visibility
Fix는 다시 적지 않는다.

- 링크는 모두 `https://steamcommunity.com/sharedfiles/filedetails/?id=<ID>` 꼴이다. 표에는 ID에 링크를 걸었다.
- "B42"는 B42 태그가 있거나 설명에 B42 지원을 적은 것. "B41"은 B41 태그만 있는 것.
- ZB = ZombieBuddy(Java 모드 로더)가 필요한 모드.

## 1. 모드 목록 (71개)

### 1.1 좀비 감지·레이더·지도

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| RadarZ | [3436681654](https://steamcommunity.com/sharedfiles/filedetails/?id=3436681654) | B42 | 라스트 스탠드 전용 좀비 레이더를 모든 모드에서 화면에 띄운다. 크기 조절 | 바닐라에 이미 있는 레이더 UI를 재사용. 항상 켜져 있어 쉬움 |
| Zombie Radar (ZomboTrak) | [3681923667](https://steamcommunity.com/sharedfiles/filedetails/?id=3681923667) | B41·B42 | 손에 든 배터리 아이템. 미니맵과 지도에 좀비 점. 레이더 원뿔의 거리·각도 조절, "움직이는 좀비만" 옵션, 동물도 추적 | 원뿔 각도·움직이는 것만 같은 **제한 옵션**이 단계 성장에 딱 맞음 |
| ZedScope | [3693709854](https://steamcommunity.com/sharedfiles/filedetails/?id=3693709854) | B42 | 위협 정도별 색 블립, 회전하는 스윕 바늘, 거리 조절. 아이소메트릭 보정 | 영화 같은 모션 트래커 느낌 |
| MinimapZ | [3413418219](https://steamcommunity.com/sharedfiles/filedetails/?id=3413418219) | B42 | 미니맵에 근처 좀비 위치와 **높이(층)** 표시. 지도 심볼로 그려서 많으면 느림 | 층 정보까지 미니맵에 |
| Zombies On Map | [3764035961](https://steamcommunity.com/sharedfiles/filedetails/?id=3764035961) | B42 | 로드된 좀비 전부를 지도·미니맵에 실시간 점으로. 점 색 바꾸기, 켜고 끄는 버튼 | 무리 위치를 지도로 계획 |
| Spring Cleaning | [3432061209](https://steamcommunity.com/sharedfiles/filedetails/?id=3432061209) | B41·B42 | 약 5초마다 주변 좀비를 세서 100x100 칸 셀별 **수와 밀도 색**을 지도에 남긴다. 파일로 저장 | "이 동네 얼마나 치웠나"가 지도에 쌓임. 기록형 정보 |
| Project Viewpoint / PZ3D Minimap | [3810179295](https://steamcommunity.com/sharedfiles/filedetails/?id=3810179295) | B42 (ZB 선택) | 캐릭터와 같이 도는 미니맵, 층 평면도, 지정 지점에 3D 표시 빔, **화면 밖 경보** | 화면 밖에서 오는 위협을 가장자리에 알림 |
| Silent Hill Radio REDUX | [2846989295](https://steamcommunity.com/sharedfiles/filedetails/?id=2846989295) | B41 (내려감) | 개조 무전기가 근처 좀비에 따라 **잡음**을 냄. 층 차이를 고려해 다른 층은 약하게 | 정보를 소리 세기로만 줌. 공포 분위기 |
| Sixth Sense Trait - Zombie Detector | [2847585559](https://steamcommunity.com/sharedfiles/filedetails/?id=2847585559) | B41 | -6 특성. UI 버튼으로 켜면 좀비가 가까울수록 **심장 박동**이 들림. 다른 층이면 약하게 | 화면 표시 없이 소리로 긴장감 |
| Danger Awareness | [3170356924](https://steamcommunity.com/sharedfiles/filedetails/?id=3170356924) | B41·B42 | 좀비가 보이거나 쫓아오거나 아주 가까우면 **빨리감기를 끄고** 정상 속도로. 캐릭터가 머리 위 말로 위험을 말함 | 빨리감기 중 물리는 사고 방지. 정보를 캐릭터 혼잣말로 전달 |
| Stairs Alert | [3044807092](https://steamcommunity.com/sharedfiles/filedetails/?id=3044807092) | B41·B42 | 계단을 오르며 E를 누르면 위층 좀비가 있는지 확인. 서 있는 위치에 따라 보이는 정도가 다름. 정확한 수를 말하게 하는 옵션 | 계단 위 매복을 미리 앎 |
| Check Around | [3300688173](https://steamcommunity.com/sharedfiles/filedetails/?id=3300688173) | B41·B42 | 계단에서 위층·아래층 확인(수 표시), 창문·문 너머 확인. 닫힌 문을 엿보면 **삐걱 소리**로 옆방 좀비를 깨울 위험 | 정보에 대가(소리)가 붙음. 구독 12만 |
| Barricade Peek | [3591292061](https://steamcommunity.com/sharedfiles/filedetails/?id=3591292061) | B42 | 바리케이드 친 창문·문 뒤에서 E로 **귀 기울이기**. 조용함부터 큰 무리까지 7단계 대사 | 문 열기 전 "저 너머 몇이냐"를 대사로 |
| Peek Through Doors & Curtains | [3813954495](https://steamcommunity.com/sharedfiles/filedetails/?id=3813954495) | B42 | 문·커튼을 들키지 않고 엿보기. 엿볼 때 좀비 강조, 보이는 칸(원뿔), 지속 시간 설정 | 강조·원뿔·지속이 그대로 단계 수치 |
| Instinctive Hearing | [3789584579](https://steamcommunity.com/sharedfiles/filedetails/?id=3789584579) | B42 | 웅크려 멈춘 채 ALT를 누르고 있으면 **듣기 모드**. 반경 안 좀비를 강조. 기본 20칸·근거리 6칸·최대 8마리, 예민한 청각 25칸·10마리, 난청 12칸·4마리, 귀머거리 불가. 현실 모드에선 멀리 멈춘 좀비는 펄스로만, 빠르게 움직일수록 잘 잡힘 | 라스트 오브 어스 듣기 모드. 멈춰야 쓰는 대가 |
| Alarm Check Mod | [2456156326](https://steamcommunity.com/sharedfiles/filedetails/?id=2456156326) | B41 (2021) | "경보 확인법" 잡지를 읽으면 집과 차에 **도난 경보가 있는지** 확인 가능 | 바닐라엔 경보 유무를 알 방법이 없음. 큰 사고를 막는 정보 |
| Horde Night | [2714850307](https://steamcommunity.com/sharedfiles/filedetails/?id=2714850307) | B41 (B42 대응 갱신) | 정해진 날 밤마다 무리가 몰려옴. 그날이면 화면 오른쪽 위 **아이콘** 표시 옵션 | 다가오는 위험 예고 |
| Wandering Hordes | [3759920384](https://steamcommunity.com/sharedfiles/filedetails/?id=3759920384) | B42 | 녹스 카운티 전체 좀비 무리 이동 시뮬. **HUD 경고 없음**이 원칙 | 경고가 없으니 "무리 예감" 강화의 가치가 커짐 |

### 1.2 시야·밤눈

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| Peek a View | [3710281407](https://steamcommunity.com/sharedfiles/filedetails/?id=3710281407) | B42 (ZB) | 게임이 '보인다'고 치지만 숨겨 두는 것을 그림. 벽이 더 멀리서 잘려 보이고, 문·모퉁이가 다가가면 열림. 나무 투명화. 계단을 오르는 동안 위층 방이 그려짐 | 벽핵이 아님(시야선은 그대로). 시야 보정 강화와 같은 결 |
| Staircast | [3684713089](https://steamcommunity.com/sharedfiles/filedetails/?id=3684713089) | B41·B42 (ZB) | 계단에서 위층을 자연스럽게 보여 줌. 구독 14만 | 계단 정보를 '보기'로 해결 |
| Cone Vision Outline | [3659137034](https://steamcommunity.com/sharedfiles/filedetails/?id=3659137034) | B42 | 조준(RMB) 중 시야 원뿔 안 좀비·동물에 흰 외곽선, 근접 타격 대상은 녹색. 근시 특성 반영 | 어두워도 원뿔 안 적이 또렷함 |
| Fog of War Restored | [3778210254](https://steamcommunity.com/sharedfiles/filedetails/?id=3778210254) | B42 | B41식 전장의 안개 복원. 시야선이 막힌 곳과 안 본 방을 어둡게 | 반대 방향(어렵게). 강화로 "방 훑기"를 주면 대비가 큼 |
| Night Vision Chucked | [2842179206](https://steamcommunity.com/sharedfiles/filedetails/?id=2842179206) | B41 계열 | eris 밤눈 모드의 후속 프레임워크·API. 자체 고글 없음. 구독 85만 | 밤 밝기 보정 방식 참고 |
| Fred's Night Vision Goggles | [3303590197](https://steamcommunity.com/sharedfiles/filedetails/?id=3303590197) | B41·B42 | 마운트에 다는 야시경 4종. N으로 켜고 끔, 올리고 내림. 배터리 소모, 켜 둔 동안 내구 소모. B42 조명 보정 | 켜고 끄는 자원 관리 |
| [B42] RealNightVision | [3389195832](https://steamcommunity.com/sharedfiles/filedetails/?id=3389195832) | B42 | 야시경 2종. N으로 켬. 켜면 **좀비 마커** 기본 표시 | 밤 + 표시를 묶음 |
| Night Vision [B.41/B.42] | [3383603346](https://steamcommunity.com/sharedfiles/filedetails/?id=3383603346) | B41·B42 | 아이템 없이 밤눈 모드. 밝기 6단계. 켜면 **지구력 소모** | 몸으로 쓰는 밤눈. 능동 토글형 |
| Darker Map & Satellite View | [3571222611](https://steamcommunity.com/sharedfiles/filedetails/?id=3571222611) | B42 | 지도를 어둡게. **소리 반경 오버레이**: 발전기, 헬기, 경보, 경적, 함성, 휘파람 반경을 지도에 원으로. 좀비 청력 설정과 날씨 반영 | 소리 계획을 지도에서 |

### 1.3 은신·잠행·숨기

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| Yes' Improved Stealth v2 | [3053929034](https://steamcommunity.com/sharedfiles/filedetails/?id=3053929034) | B41·B42 | 웅크리고 **어두운 타일**(또는 안개)에 있으면 발각 반경이 줄어듦. 잠행 레벨마다 더 줄어듦. 가로등 밑은 오히려 잘 보임. 타일 밝기를 보여 주는 **빛 무들** | 밤이 아니어도 창고 불을 끄면 숨을 수 있음. 구독 12만 |
| Under Cover of Darkness | [2954422590](https://steamcommunity.com/sharedfiles/filedetails/?id=2954422590) | B41 | 밤(해진 뒤 2시간~해뜨기 전 2시간)과 안개에 좀비 시력을 '나쁨'으로. 계절 반영 | 단순한데 구독 53만. 밤이 기회가 됨 |
| Lethal Stealth | [3531611692](https://steamcommunity.com/sharedfiles/filedetails/?id=3531611692) | B42 | 웅크리기·엎드리기 자세(조준 보너스), 포복, **차 밑 통과**, 달리기+일어나기로 빨리 일어남 | 구독 25만. 자세가 전술이 됨 |
| True Crawl - Stealth Mode | [3434364211](https://steamcommunity.com/sharedfiles/filedetails/?id=3434364211) | B42 | 기어가는 중이면 아주 가까이 오지 않는 한 좀비가 감지 못 함. 감지 반경 설정 | 포복 = 은신 |
| Crawl B41 | [2995230593](https://steamcommunity.com/sharedfiles/filedetails/?id=2995230593) | B41 | 차·폐차 옆에서 E를 누르면 차 밑으로 기어 지나감 | 차 사이로 빠지는 탈출로 |
| Stealth Attack | [3786073264](https://steamcommunity.com/sharedfiles/filedetails/?id=3786073264) | B42 | 날 모르는 좀비 뒤에서 웅크려 근접 공격하면 잠행 레벨별 **즉사 확률** (0레벨 14% ~ 7레벨 100%) | 잠행 기술에 쓸모를 줌 |
| Melee Ragdolls | [3779997883](https://steamcommunity.com/sharedfiles/filedetails/?id=3779997883) | B42 | 근접 래그돌 + 모르는 좀비에게 **은신 처형** 옵션 | 처형 연출 |
| Thief Expansion | [2596620950](https://steamcommunity.com/sharedfiles/filedetails/?id=2596620950) | B41·B42 (SP) | 도둑 직업에 능동 기술 둘. **은신**: 시야를 끊거나 거리를 벌리면 숨은 채 이동, 지속 한도, 대기 10초, 레벨이 오르면 쉽게 숨고 오래가고 대기 감소, 8레벨부터 숨은 채 공격. **훔치기**: 좀비에게 붙어 소지품을 훔침, 무게 한도, 실패·대실패 | **우리 구조(찍을수록 지속↑·대기↓)와 가장 비슷한 선례**. 좀비 주머니 털기는 루팅과도 연결 |
| Sneak Invisible V2 | [3564585524](https://steamcommunity.com/sharedfiles/filedetails/?id=3564585524) | B42 | 웅크리면 투명. 뛰기, 공격, 조준, 행동 시작 시 해제 | 극단적 버전. 캡스톤 '그림자' 참고 |
| Stealth Camo | [2762398967](https://steamcommunity.com/sharedfiles/filedetails/?id=2762398967) | B41·B42 (SP) | 광학 위장 장치 4등급. 배터리, 충격·총소리에 잠깐 풀림, 켜 두면 **작은 소음** | 강한 효과에 대가(소음, 배터리) |
| QP Vehicle Stealth | [3758275097](https://steamcommunity.com/sharedfiles/filedetails/?id=3758275097) | B41·B42 | 정차한 차 안에 가만히 있으면 지연 후 숨음. 엔진 끔 조건, 근처 좀비 확인, 부서진 부품은 효과 감소, HIDING/HIDDEN/EXPOSED 표시 | 차가 은신처가 됨 |
| Mattnetic's Hide Anywhere | [3797779872](https://steamcommunity.com/sharedfiles/filedetails/?id=3797779872) | B42 | 사물함·옷장·쓰레기통·냉동고·침대에 숨기. 들키지 않고 들어가야 함, **숨 참기**(무리하면 헐떡임), 잠깐 엿보기, 좀비가 은신처를 두들겨 부숨, 장소별 불편(냉동고는 추움). 잠행 XP | 공포 게임식 숨기. 장소마다 대가 |
| Simple Hiding | [3805734699](https://steamcommunity.com/sharedfiles/filedetails/?id=3805734699) | B42 (SP) | 가벼운 숨기. 기침·함성은 위치를 드러냄. 좀비는 놓친 자리 주변을 계속 찾음 | 좀비 길찾기를 건드리지 않아 다른 모드와 잘 맞음 |
| Stealth Alert | [3784469100](https://steamcommunity.com/sharedfiles/filedetails/?id=3784469100) | B42 | 들켰을 때 머리 위 '!' UI와 메탈기어 효과음 | 들킨 순간을 확실히 알림 |

### 1.4 위장 (좀비 피·내장)

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| Braven's Camouflage | [2981216690](https://steamcommunity.com/sharedfiles/filedetails/?id=2981216690) | B41 | 시체 우클릭으로 위장, 약 60분. 좀비가 헷갈려 따라오지만 너무 가까이 가지 않으면 공격 안 함. 피로·메스꺼움 | 구독 37만. '완전히 속이지 않음'이 긴장 |
| Braven's Camouflage Reworked | [3739612285](https://steamcommunity.com/sharedfiles/filedetails/?id=3739612285) | B42 | 위의 B42판. 내장을 바르고 좀비 걸음. 너무 가깝거나 오래 있거나 닿으면 금방 들킴 | 거리와 시간이 핵심 변수 |
| Zombie Camouflage - Build 42 | [3742518185](https://steamcommunity.com/sharedfiles/filedetails/?id=3742518185) | B42 | **위장 레벨**이 높을수록 좀비가 더 가까이 와야 알아봄. 무들 색이 4단계로 바뀜. 피 묻은 옷을 벗으면 단계가 내려감. 좀비는 굳지 않고 자연스럽게 배회 | 단계형 위장 |
| Zombie Camouflage - Edited | [2900823283](https://steamcommunity.com/sharedfiles/filedetails/?id=2900823283) | B41 | 위의 B41판. 뛰기, 사격, 시동 같은 눈에 띄는 행동만 좀비를 깨움. 비에 씻김, 30~45분 | |
| Walker Camouflage | [3783800300](https://steamcommunity.com/sharedfiles/filedetails/?id=3783800300) | B42 | 좀비 피를 옷에 1/3~3/3까지 바름. 인식 거리 약 6칸 → 3칸 → 1.1칸. **시각만**, 청각은 그대로. 도축 레벨이 시체 하나에서 얻는 횟수를 정함(1~6회) | 수치가 단계로 깔끔함. 그대로 노드로 옮기기 좋음 |
| Among The Rot | [3806364888](https://steamcommunity.com/sharedfiles/filedetails/?id=3806364888) | B42 | 칼로 시체를 갈라 내장을 바름. 위장 중 근처 좀비가 추적을 완전히 멈춤. 시체당 1회. 좀비가 보는 데서 뛰거나 휘두르면, 함성, 차 타기, 비, 씻기, 타이머(기본 실시간 2분)로 해제. 안 보이는 곳에선 뛰고 죽여도 됨 | 해제 조건이 명확. 짧고 강함 |
| They Think You're Dead | [3787358549](https://steamcommunity.com/sharedfiles/filedetails/?id=3787358549) | B42 (ZB) | 위장하면 좀비의 시각 표적 지정을 막음. Ctrl로 **좀비 걸음** 토글. 위장 중 발소리가 좀비를 끌지 않음. 피가 묻어 있는 동안 시체병, 마스크로 90% 감소. 비는 5단계로 씻어 냄 | 대가(시체병)와 대응(마스크)이 있음 |
| Camouflage TWD Expanded | [3427533514](https://steamcommunity.com/sharedfiles/filedetails/?id=3427533514) | B42 | 시체 피로 위장. 악취, 스트레스, 시체병. 몸 **15부위 이상 피투성이면 싸우다 묻은 피로도 자동 위장**. 특성·기술·장비가 효과와 부작용에 영향 | 전투 결과가 은신으로 이어짐 |
| Blood, Guts, No Glory | [Nexus 374](https://www.nexusmods.com/projectzomboid/mods/374) | B42 | 사람 시체로 피·내장 위장. 지속시간, 불편·메스꺼움·스트레스·우울·패닉, 근처 좀비가 있으면 바를 수 없음, 비에 씻기는 속도를 설정 | 바르는 순간의 위험(근처 좀비 제한) |
| Slow Burn: Infected Survivor | [3536881320](https://steamcommunity.com/sharedfiles/filedetails/?id=3536881320) | B42 | 감염됐지만 변하지 않은 생존자. **의심 게이지** 0~100, 다섯 단계(숨음·의심·노출·추적·발각). 좀비 걸음 모드, 웅크리기·조용히·실내면 빨리 식음. Z로 시체 먹기(의심 초기화, 열 상승), 내장 바르기, **속삭여 한 마리 빼오기(PSST)**, 끙끙거려 의심 조금 낮추기. 1% '똑똑한 좀비'는 위장을 꿰뚫음 | 은신을 게이지로 관리. 능동 기술 재료가 많음 |
| The Whisperer Mod | [2885751402](https://steamcommunity.com/sharedfiles/filedetails/?id=2885751402) | B41 (내려감) | 좀비 가죽 가면 + 좀비 걸음 반복. 겨누거나 뛰거나 죽이면 들킴. 들키면 시야를 끊고 기다리면 잊음 | "시야를 끊고 기다리면 잊는다" 규칙 |

### 1.5 냄새·흔적

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| Sense of Smell | [3018798678](https://steamcommunity.com/sharedfiles/filedetails/?id=3018798678) | B41·B42 | 숨, 땀, 상처, 먹고 마시기로 **냄새 흔적**을 남기고 좀비가 따라옴. 비·눈이 덮어 줌. 마스크, 장갑, 향수, 밀폐된 차로 줄임. 냄새 미터 옵션 | 소리 말고 두 번째 감지 축 |
| The Scent of Blood | [2789145726](https://steamcommunity.com/sharedfiles/filedetails/?id=2789145726) | B41·B42 | 붕대 안 한 상처가 좀비를 끔. 깊은 상처일수록 멀리서. 더러운 붕대도 약하게 | 치료가 은신이 됨. 구독 27만 |
| Starving Zombies | [3396867685](https://steamcommunity.com/sharedfiles/filedetails/?id=3396867685) | B42 | 시체(동물 포함) 냄새로 좀비가 몰려가 먹음. 플레이어·몸의 피·가방 속 물건 냄새. **바람 방향과 세기**로 거리 결정 | 바람을 읽는 은신. 시체를 미끼로 |

### 1.6 유인·소음

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| Braven's Throwables | [2856589908](https://steamcommunity.com/sharedfiles/filedetails/?id=2856589908) | B41 | 병, 캔, 머그, 접시, 돌, 공, 다트, 벽돌, 폭죽을 던짐. 유인, 창문 깨기, 공격. 피해는 무게·재질 | 구독 31만. 잡동사니가 도구가 됨 |
| ThrowableDistractionsB42 | [3758942913](https://steamcommunity.com/sharedfiles/filedetails/?id=3758942913) | B42 | 조준하면 **예상 착탄점** 표시, G로 던짐, 최대 18칸. 돌, 빈 캔·병, 접시, 그릇, 수저, 썩은 달걀 | 착탄점 미리보기가 단계 노드감 |
| K12's Distractions | [3702954931](https://steamcommunity.com/sharedfiles/filedetails/?id=3702954931) | 미확인 | 병, 깡통, 돌을 던져 유인 | |
| Throwable Stone | [2712056154](https://steamcommunity.com/sharedfiles/filedetails/?id=2712056154) | B41 | 돌을 최대 50칸 던짐, 떨어진 곳 8칸 안 좀비를 끔 | 멀리 던지는 손맛 |
| Big Noise Generator | [2629676638](https://steamcommunity.com/sharedfiles/filedetails/?id=2629676638) | B41 | 차 배터리로 도는 원격 소음기. 반경 250(사이렌·경보와 같음) | 바닐라 소음기(약 15~17칸)가 너무 약하다는 불만 |
| House Alarm Mod | [2939648494](https://steamcommunity.com/sharedfiles/filedetails/?id=2939648494) | B41·B42 | 만들어 쓰는 도난 경보기 5종. 멀리 있는 무리를 한곳에 모음 | 무리 미끼 |
| Key Fobs | [3748935486](https://steamcommunity.com/sharedfiles/filedetails/?id=3748935486) | B41·B42 | 차 열쇠가 리모컨이 됨. 30칸에서 잠금·해제, **패닉 버튼으로 차 경보** | 멀리서 차를 미끼로 |
| Better Reactions | [3812650654](https://steamcommunity.com/sharedfiles/filedetails/?id=3812650654) | B42 | 함성, 속삭임, 경적을 들은 좀비가 **지연 없이 바로** 반응. 거리와 청력은 그대로 | 함성이 믿을 만한 도구가 됨 |
| Gamer Shouts | [3755000037](https://steamcommunity.com/sharedfiles/filedetails/?id=3755000037) | B42 | G로 Q보다 약 2배 큰 함성. 웅크리면 절반 | 큰 함성 키 |
| Subsonic Sirens | [3169040805](https://steamcommunity.com/sharedfiles/filedetails/?id=3169040805) | 미확인 | 사이렌 소리만 줄이고 좀비는 원래대로 들음 | 사이렌 미끼를 오래 켜 둘 수 있게 |
| Zombies Fear The Sun | [2182855819](https://steamcommunity.com/sharedfiles/filedetails/?id=2182855819) | B41 | 낮엔 좀비가 실내로 들어가 잠듦. 잠행 중 깨울 확률, 발소리로 깨울 확률, 하나 깨면 건물 전체가 깰 확률 | 자는 좀비 옆을 지나가는 긴장 |
| Signal Smoke | [3811010882](https://steamcommunity.com/sharedfiles/filedetails/?id=3811010882) | B42 | 색 연막탄, 도로 조명탄(약 1시간), 화학등, 즉석 연막 | 연막·표시 도구 |

### 1.7 탈출·청각 보조

| 모드 | ID | 빌드 | 동작 | 재미 포인트 |
| --- | --- | --- | --- | --- |
| DZP Escape Ropes | [3807969034](https://steamcommunity.com/sharedfiles/filedetails/?id=3807969034) | B42 | 갈고리를 만들어 창문·난간·턱에 탈출 로프를 걸고 위에서 회수 | 위층으로 도망칠 길 |
| Adrenaline Rush | [3599181101](https://steamcommunity.com/sharedfiles/filedetails/?id=3599181101) | B41 | 패닉이 최대 근처면 피로·지침이 사라짐. 끝나면 피로가 조금 더 옴 | 캡스톤 '아드레날린'의 선례 |
| Hearing Aid | [2931424725](https://steamcommunity.com/sharedfiles/filedetails/?id=2931424725) | B41 (B42 포크 [3697034338](https://steamcommunity.com/sharedfiles/filedetails/?id=3697034338)) | 4단계 보청기. 고치고 개량할수록 난청 해소 → 귀머거리 완화 → 예민한 청각 | 나쁜 청각 특성에서 벗어나는 성장 |
| Adaptive Traits | [3622328997](https://steamcommunity.com/sharedfiles/filedetails/?id=3622328997) | B42 | 행동으로 특성을 얻고 잃음. 고양이 눈, 눈에 띔·안 띔 포함 | 감각 특성을 바꾸는 모드라 겹침 확인 대상 |

## 2. 강화 후보로 뽑은 아이디어 (68개)

- 트리: 수색 = 감각·정보·손기술, 생존 = 몸·은신·위장 패시브, 능동 = 누르면 발동(대기시간). IDEAS.md는 능동을 생존
  아래에 두므로 능동은 생존 트리 안의 능동 갈래로 본다.
- "(확장)"은 IDEAS.md의 기존 후보를 키우는 안이다.
- 단계 효과는 "찍을 때마다 커지는 것"만 적었다.

### 2.1 수색: 듣기·느끼기

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 1 | 듣기 모드 | 웅크려 멈추고 키를 누르고 있는 동안 반경 안 좀비를 강조. 반경(12→25칸), 최대 수, 상위는 멈춘 좀비도 펄스로 잡음 | 능동(홀드, 대기 없음, 멈춤 조건) | Instinctive Hearing |
| 2 | 문 너머 듣기 | 닫힌 문·창문·바리케이드에 귀를 대면 너머 규모를 말함. 단계(있다/없다 → 몇 → 정확한 수 → 위치 강조) | 능동(짧은 행동) | Barricade Peek |
| 3 | 계단 확인 | 계단에서 위·아래층 좀비 수. 반경, 정확도, 상위는 계단에 서기만 해도 자동 | 패시브/능동 | Stairs Alert, Check Around |
| 4 | 심장 박동 | 육감을 소리로도 전달. 가까울수록 빠른 박동, 다른 층이면 약하게 | 패시브 (육감 확장) | Sixth Sense Trait |
| 5 | 잡음 감 | 육감 정보를 무전 잡음처럼. 화면 표시를 끈 하드코어용 옵션 | 패시브 (육감 확장) | Silent Hill Radio |
| 6 | 위험 멈춤 | 빨리감기·긴 행동 중 좀비가 보이거나 쫓아오면 속도를 되돌리고 행동을 멈춤. 반경, 다른 층 포함 | 패시브 (하위, 싸게) | Danger Awareness |
| 7 | 쫓는 좀비 표시 | 나를 노리는 좀비 머리 위에 '!'. 단계(수만 → 표시 → 화면 밖이면 가장자리 화살표) | 패시브 (추적 감 확장) | Stealth Alert, Project Viewpoint |
| 8 | 화면 밖 경보 | 화면 밖에서 다가오는 좀비를 가장자리 화살표로. 반경, 동시 표시 수 | 패시브 | Project Viewpoint |
| 9 | 레이더 블립 | 화면 구석 레이더에 좀비 점. 반경, 원뿔 각도(앞쪽 → 360도), 움직이는 것만 → 멈춘 것도, 높이 표시 | 패시브 (상위) | RadarZ, ZomboTrak, ZedScope, MinimapZ |
| 10 | 미니맵 좀비 점 | 미니맵·지도에 근처 좀비 점. 반경, 갱신 주기, 층 | 패시브 | Zombies On Map, MinimapZ |
| 11 | 자는 좀비 감 | 누워 있거나 잠든 좀비를 구분 표시. 근처에서 깨울 확률도 알려 줌 | 패시브 | Zombies Fear The Sun |
| 12 | 바람 읽기 | 화면에 바람 방향 표시. 냄새 모드가 있을 때 "바람 아래로 가라" 정보 | 패시브 (하위) | Starving Zombies |

### 2.2 수색: 보기

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 13 | 엿보기 | 문·커튼·창문 너머를 들키지 않고 잠깐 봄. 시야 폭, 지속, 삐걱 소리 확률 감소, 좀비 강조 | 능동(짧은 대기) | Peek Through, Check Around |
| 14 | 계단 시야 | 계단을 오르는 동안 위층 방이 그려짐. 상위는 아래층도 | 패시브 | Staircast, Peek a View |
| 15 | 벽 너머 여유 | 벽이 더 멀리서 잘려 보이고 문·모퉁이가 일찍 열림. 거리 | 패시브 (시야 보정 확장) | Peek a View |
| 16 | 나무 투명 | 주변과 보는 쪽 나무를 투명하게. 반경 | 패시브 | Peek a View |
| 17 | 조준 외곽선 | 조준하면 원뿔 안 좀비에 외곽선. 상위는 조준 없이도, 거리 증가 | 패시브 | Cone Vision Outline |
| 18 | 넓은 시야 | 시야 원뿔 각도 증가. 등 뒤 근거리 감지 반경 증가 | 패시브 | 360도 시야 모드들 |
| 19 | 방 훑기 | 문을 열거나 방에 들어서면 그 방 좀비가 잠깐 다 드러남. 지속, 이웃 방까지 | 패시브 | Fog of War Restored의 반대 |
| 20 | 밤눈 모드 | 누르면 밤 화면이 밝아지고 지구력을 씀. 밝기, 소모 감소. 패시브 '밤눈'과 따로 | 능동(토글) | Night Vision [B.41/B.42], Fred's NVG |
| 21 | 밤의 표적 | 밤에 가까운 좀비에 작은 마커. 반경 | 패시브 (밤눈 확장) | RealNightVision |
| 22 | 빛 무들 | 지금 서 있는 타일이 은신에 충분히 어두운지 표시. 은신 노드의 기본 제공 정보 | 패시브 (하위) | Yes' Improved Stealth |
| 23 | 내 소음 미터 | 지금 내가 내는 소리 크기와 닿는 반경을 보여 줌 | 패시브 (하위) | 빛 무들 + 소리 오버레이에서 착안 |
| 24 | 소리 반경 미리보기 | 함성·발전기·경적 같은 행동의 반경을 화면·지도에 원으로. 상위는 날씨·좀비 청력 반영 | 패시브 | Darker Map & Satellite View |

### 2.3 수색: 알아채기·지도·루팅

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 25 | 경보 감지 | 집·차에 도난 경보가 있는지 앎. 단계(가까이서 확인 → 지나가며 자동 → 지도 표시) | 패시브 | Alarm Check Mod |
| 26 | 밀도 기록 | 지나간 지역의 좀비 수·밀도를 셀 단위로 지도에 남김. 기록 반경, 갱신, 수 표시 | 패시브 (무리 방향 확장) | Spring Cleaning |
| 27 | 무리 이동 예감 | 큰 무리가 움직이면 방향·대략 거리. 상위는 지도에 경로 | 패시브 (무리 방향 확장) | Wandering Hordes(경고 없음), Horde Night |
| 28 | 습격 예감 | 무리 사건(호드 나이트류)이 오는 날을 미리 앎. 며칠 전부터 | 패시브 | Horde Night indicator |
| 29 | 위험 구역 기록 | 쫓기거나 물린 곳을 지도에 자동 표시 | 패시브 | Where did I die?, 지도 기록 모드들 |
| 30 | 표시 빔 | 지정한 지점(차, 거점)에 하늘로 빔. 개수 | 패시브 | Project Viewpoint |
| 31 | 좀비 주머니 털기 | 서 있는 좀비 몸에서 물건을 훔침. 성공률, 무게 한도, 실패 시 소란 감소 | 능동(대기) | Thief Expansion |
| 32 | 썩은 냄새 추적 | 근처 시체 더미 방향을 느낌 (시체 뒤지기와 연결) | 패시브 | Starving Zombies |

### 2.4 생존: 은신 패시브

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 33 | 그림자 숨기 | 어두운 타일에서 웅크리면 발각 거리 감소. 감소율 | 패시브 | Yes' Improved Stealth |
| 34 | 밤·안개 은신 | 밤·안개·비에 좀비가 나를 보는 거리 감소 | 패시브 | Under Cover of Darkness |
| 35 | 포복 은신 | 기어갈 때 감지 반경 크게 감소 (포복 동작이 있어야 함. B42 포복 상태 확인) | 패시브 | True Crawl, Lethal Stealth |
| 36 | 시야 끊기 | 좀비 시야에서 벗어나면 나를 더 빨리 잊음. 잊는 시간 | 패시브 (탈출) | Whisperer, Simple Hiding |
| 37 | 자는 좀비 지나가기 | 누운·잠든 좀비 옆에서 깨울 확률 감소 | 패시브 | Zombies Fear The Sun |
| 38 | 차 안 숨기 | 정차·엔진 끈 차 안에서 가만히 있으면 숨음. 숨는 지연 감소, 부서진 차 페널티 감소 | 패시브 | QP Vehicle Stealth |
| 39 | 숨 참기 | 숨어 있는 동안 숨 참기 게이지. 길이, 헐떡임 확률 감소 | 패시브 (숨기 보조) | Hide Anywhere |
| 40 | 조용한 상처 | 피 흘리는 상처·더러운 붕대가 좀비를 덜 끔 | 패시브 (냄새 모드와 함께일 때 의미) | The Scent of Blood |
| 41 | 냄새 줄이기 | 숨·땀 냄새 흔적 감소 | 패시브 | Sense of Smell |
| 42 | 기습 처치 | 날 모르는 좀비 뒤 근접 공격의 즉사 확률 | 패시브 (전투, '정할 것' 대상) | Stealth Attack, Melee Ragdolls |
| 43 | 빠르게 일어나기 | 엎드림·넘어짐에서 빨리 일어남 | 패시브 | Lethal Stealth |

### 2.5 생존: 위장

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 44 | 내장 위장 | 시체에서 위장. 인식 거리(약 6 → 3 → 1칸), 지속, 비에 덜 씻김, 메스꺼움 감소 | 능동(대기) (위장 냄새 확장) | Walker Camouflage, Among The Rot, Braven's |
| 45 | 알뜰한 도축 | 시체 하나로 위장을 여러 번 | 패시브 | Walker Camouflage |
| 46 | 좀비 걸음 | 위장 중 좀비처럼 걸으면 의심이 덜 쌓임. 느려지는 정도 감소 | 능동(토글) | They Think You're Dead, Slow Burn |
| 47 | 의심 게이지 | 위장 중 행동마다 의심이 쌓이는 5단계 게이지. 쌓임 감소, 식는 속도 | 패시브 (위장 보조) | Slow Burn |
| 48 | 끙끙 소리 | 좀비 소리를 내 의심을 조금 낮춤 | 능동(짧은 대기) | Slow Burn |
| 49 | 피투성이 위장 | 싸우다 몸이 피로 덮이면 약한 위장이 자동으로 | 패시브 | Camouflage TWD Expanded |
| 50 | 위장 내성 | 위장 중 시체병·스트레스·악취 페널티 감소 | 패시브 | They Think You're Dead, Blood Guts No Glory |
| 51 | 들키지 않는 발소리 | 위장 중 발소리가 좀비를 끌지 않음 | 패시브 (위장 상위) | They Think You're Dead |
| 52 | 급히 바르기 | 근처에 좀비가 있어도 위장을 바를 수 있음. 바르는 시간 감소 | 패시브 | Blood Guts No Glory |

### 2.6 능동: 유인

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 53 | 속삭여 빼오기 | 무리에서 한 마리만 끔. 대상 수(1 → 3), 거리, 대기 감소 | 능동 | Slow Burn PSST |
| 54 | 던져서 유인 | 병·캔·돌 던지기 강화. 사거리, 착탄점 미리보기, 소리 반경 | 능동/패시브 | Throwables 계열 |
| 55 | 소리 던지기 | 지정한 지점에서 소리가 나게 함 (복화술). 거리, 반경 | 능동 | 함성 + 던지기에서 착안 |
| 56 | 원격 차 경보 | 근처 차의 경보를 멀리서 울림. 거리, 상위는 열쇠 없이 | 능동 | Key Fobs |
| 57 | 즉석 소음기 | 지점에 일정 시간 소음 장치를 놓음. 지속, 반경 | 능동 | Big Noise Generator, House Alarm |
| 58 | 즉각 함성 | 함성을 들은 좀비가 지연 없이 반응, 반경 증가 | 패시브 (함성 확장) | Better Reactions, Gamer Shouts |
| 59 | 시체 미끼 | 시체에 표시하면 주변 좀비가 몰려가 먹음. 지속, 반경 (페로몬의 시체 버전) | 능동 | Starving Zombies |
| 60 | 연막 | 연막 구름으로 좀비 시야를 끊음. 지속, 크기 | 능동 | Signal Smoke |

### 2.7 능동: 숨기·탈출

| # | 아이디어 | 단계 효과 | 형태 | 출처 |
| --- | --- | --- | --- | --- |
| 61 | 가구 숨기 | 옷장·사물함·쓰레기통·냉동고·침대 밑에 숨음. 들어가는 소리 감소, 좀비가 포기하는 시간 감소 | 능동 | Hide Anywhere, Simple Hiding |
| 62 | 숨은 채 엿보기 | 숨은 곳에서 밖을 봄. 들킬 확률 감소 | 능동 (가구 숨기 보조) | Hide Anywhere |
| 63 | 은신 | 시야를 끊으면 한동안 숨은 채 움직임. 지속↑, 대기↓, 최상위는 숨은 채 공격 1회 | 능동 (캡스톤 '그림자'와 합칠 수 있음) | Thief Expansion, Sneak Invisible |
| 64 | 차 밑 빠지기 | 차 밑으로 기어 반대편으로 빠져나감. 속도 | 능동 | Crawl B41, Lethal Stealth |
| 65 | 갈고리 로프 | 창문·난간에 탈출 로프를 빠르게 걸고 회수. 설치 속도, 재료 절약 | 능동 | DZP Escape Ropes |
| 66 | 아드레날린 | 패닉이 높을 때 피로·지침 무시, 끝나면 반동. 지속, 반동 감소 (캡스톤 확장) | 능동/자동 | Adrenaline Rush |
| 67 | 청각 회복 | 난청 → 보통 → 예민 쪽으로 청각을 단계적으로 끌어올림 (바닐라 특성 축이라 '정할 것') | 패시브 | Hearing Aid |
| 68 | 비상 탈출 경로 | 근처 출구(열린 창문, 뒷문)를 잠깐 강조 | 능동 | 엿보기·표시 빔에서 착안 |

## 3. 눈에 띈 점

- **정보에 대가를 붙이는 모드가 재미있다.** 듣기 모드는 웅크려 멈춰야 하고, Check Around는 엿보다 삐걱거리고,
  야시경은 배터리를 쓰고, Stealth Camo는 소음을 낸다. 강화도 단계가 낮을 때 대가를 크게 두고 찍을수록 줄이면
  성장이 잘 느껴진다.
- **정보를 캐릭터 말로 전하는 방식**(Danger Awareness, Barricade Peek, Stairs Alert)은 UI 없이도 몰입이 좋다.
  낮은 단계는 대사, 높은 단계는 정확한 수·표시로 올리는 사다리가 자연스럽다.
- Thief Expansion은 능동 기술에 "기술 레벨이 오르면 지속 증가, 대기 감소, 최상위에서 새 능력"을 이미 쓴다. 우리
  구조와 가장 비슷한 선례다.
- 위장 모드는 B42에서 많다(최소 8개). 위장 강화를 넣으면 같이 켰을 때 두 위장이 겹치거나 서로 끈다. 겹침 조사
  대상에 위장 모드를 넣어야 한다. They Think You're Dead와 Peek a View, Staircast는 ZombieBuddy Java 모드라 바닐라
  판정 자체를 바꾼다.
- 레이더·지도 점 모드는 정보를 한 번에 다 준다. 강화로 옮길 때는 원뿔 각도, 움직이는 것만, 반경처럼 **제한을
  하나씩 푸는 단계**가 맞다 (ZomboTrak의 옵션이 그대로 사다리가 됨).
- 냄새 모드(Sense of Smell, Scent of Blood, Starving Zombies)는 바닐라에 없는 감지 축이다. 우리 강화가 냄새를
  다루려면 이 모드들이 켜져 있을 때만 의미가 있거나, 우리가 냄새를 직접 만들어야 한다.

## 출처

- 각 모드 페이지 (표의 ID 링크). 설명과 태그는 Steam `GetPublishedFileDetails` API로 읽었다.
- [Blood, Guts, No Glory (Nexus)](https://www.nexusmods.com/projectzomboid/mods/374)
- 검색: Steam Workshop 검색(appid 108600) "stealth", "camouflage", "zombie disguise", "night vision", "minimap",
  "radar", "zombie detector", "awareness", "lure", "distraction", "shout", "peek", "horde", "hearing", "sneak",
  "smell", "staircast", "flare", "zombie map", "listen"
