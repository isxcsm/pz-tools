# 루팅·운반 모드 조사

[IDEAS.md](../IDEAS.md)의 수색·운반 트리를 채우려고 Steam 창작마당 모드를 넓게 훑었다. 모드 이름, 링크, B42 여부, 기능, 인기 이유를 적고,
바닐라 한도와 강화 후보로 뽑을 만한 아이디어를 정리한다. 거르지 않고 모은다.

- 구독 수는 2026-10 기준 Steam API(`GetPublishedFileDetails`)에서 읽은 현재 구독 수다.
- B42 표시는 창작마당 태그와 설명 기준이다. 실제로 지금 B42에서 도는지는 확인하지 않았다.
- (확인)은 게임 코드나 실제 게임으로 다시 봐야 하는 것이다.

## 1. 바닐라 한도와 수치

게임 파일(`media/lua`, `media/scripts`)과 예전 디컴파일 자료(`_old-artifacts-20261007/recovery-research/decompiled`)에서 직접 본 것과
커뮤니티에서 말하는 것을 나눠 적는다.

### 게임 파일에서 직접 확인

| 항목 | 값 | 출처 |
| --- | --- | --- |
| 열쇠 무게 | 0.05 (`Key1`) | `media/scripts/generated/items/key.txt` |
| 열쇠고리 | 무게 0.05, 용량 1, 무게 감소 85% | `media/scripts/generated/items/container.txt` |
| 바닐라 가방 용량 최대값 | 스크립트상 가장 큰 Capacity가 35 | 같은 파일 |
| 옮기기 기본 시간 | 내 가방끼리 120, 월드 용기와 나 사이 50 | `ISInventoryTransferAction.lua` 789~805행 |
| 옮기기 무게 배율 | 시간 × min(물건 무게, 3). 무게 3 이상은 다 같음 | 같은 파일 814~816행 |
| 가방 찬 정도 | 내 가방에 넣을 때 × (가방 찬 비율, 최소 0.4) | 같은 파일 796~811행 |
| 바닥에 내려놓기 | 내 인벤토리 → 바닥 × 0.1, 월드 용기 → 바닥 × 0.2 | 같은 파일 823~831행 |
| 손재주 특성 | Dextrous × 0.5, All Thumbs·둔한 장갑 × 2.0 | 같은 파일 833~838행 |
| 걸으면서 옮기기 | 움직이는 중이면 × 1.5. 월드 용기가 끼면 걸을 때 멈춤 | 같은 파일 271~273행, 783행 |
| 즐겨찾기 | 즐겨찾기 아이템은 내 인벤토리 밖으로 옮겨지지 않음 | 같은 파일 850행 |
| 시체 벗기기 | 둔감하지 않은 캐릭터는 시체에서 물건을 벗기면 약간 불행해짐 | 같은 파일 130행 |
| 힘 경험치 | 짐이 최대 무게의 50%를 넘은 채 걸으면 가끔 힘 XP 2 | `server/XpSystem/XpUpdate.lua` 33행 |
| 근력 특성 배율 | `maxWeightDelta`: Strong 1.5, Stout 1.25, Feeble 0.9, Weak 0.75 | 디컴파일 `IsoPlayer.java` 596~599, 886~893행 |
| 기본 최대 무게 필드 | `maxWeightBase = 8` (실제 계산식은 다른 클래스) (확인) | 디컴파일 `IsoGameCharacter.java` 981~982행 |
| 낙하 피해와 짐 | 낙하 피해 × (짐 무게 / 최대 무게), 이 배율 상한 1.8 | `IsoGameCharacter.java` 2444~2446행 |
| 낙하 골절과 짐 | 여유가 2 미만이면 골절 확률에 (짐 비율 × 20)을 더함 | `IsoGameCharacter.java` 2494~2496행 |
| 무거운 물건 | `isForceDropHeavyItem`: 양손 무거운 물건은 다른 손 물건을 내려놓게 함 | `ISEquippedItem.lua`, `ISHotbar.lua` |
| 시체 끌기 | B42 바닐라에 `BodyDragging`이 있음 | `media/lua/shared/BodyDragging` |

### 커뮤니티에서 말하는 것

| 항목 | 내용 | 출처 |
| --- | --- | --- |
| 캐릭터 인벤토리 한도 50 | 근력이나 가방과 상관없이 캐릭터 인벤토리는 50을 못 넘는다. 엔진 하드코딩이라고 함. 무게 0 아이템이나 음수 무게 꼼수(Weight Void)도 B42에서는 50을 못 넘음 (확인) | [Weight Void 댓글](https://steamcommunity.com/sharedfiles/filedetails/comments/2287977869), [Steam 토론](https://steamcommunity.com/app/108600/discussions/0/3422194223909816608) |
| Pack Mule 한도 | More Traits의 Pack Mule도 "엔진 한도 때문에 50 상한"이라고 적음. 42.12 이후 이런 무게 특성이 잘 안 먹는다는 보고 | [More Traits 댓글](https://steamcommunity.com/sharedfiles/filedetails/comments/1299328280) |
| B42 용기 용량 한도 | 손수레 모드는 "B42는 39 한도", Customizable Containers는 "B42 하드코딩 용량 우회(수동 설치)"를 내세움. 가방·용기 용량에도 엔진 상한이 있다는 뜻 (확인) | [Wheelbarrow](https://steamcommunity.com/sharedfiles/filedetails/?id=2926995676), [Customizable Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2719850086) |
| 과적 단계 | 100% 초과 Fairly Heavy, 125% Heavy, 150% Very Heavy, 175% Extremely Heavy. 150% 이상은 지구력 회복이 멈추고 이동 중 줄며 체력이 서서히 깎임 | [projectzomboid.wiki 과적 안내](https://projectzomboid.wiki/guides/encumbrance/), [pzwiki](https://pzwiki.net/wiki/Encumbered) |
| 과적 체력 손실 | 과적으로 깎이는 체력은 최대 30%까지, 짐을 내리면 돌아옴 | [Steam 토론](https://steamcommunity.com/app/108600/discussions/0/3198119742674166784) |
| 운반 한도를 줄이는 것 | 배고픔, 목마름, 병, 출혈, 부상 | [projectzomboid.wiki](https://projectzomboid.wiki/guides/encumbrance/) |
| 근력 비례 | 근력 1단계당 약 8이라는 안내와, 근력 5에서 10, 1당 +2라는 옛 안내가 섞여 있음 (확인) | 위 두 위키, [gamerempire](https://gamerempire.net/project-zomboid-how-to-increase-carry-weight/) |
| 열쇠 무게 불만 | 열쇠가 6kg까지 쌓였다는 보고. 무게 0 열쇠 모드가 따로 있음 | [Steam 토론](https://steamcommunity.com/app/108600/discussions/0/510695796907217606) |
| 행운 특성 | B42에서 Lucky·Unlucky 특성이 빠졌다는 말이 있음 (확인) | [Steam 토론](https://steamcommunity.com/app/108600/discussions/0/3824159062928781101) |
| 빠루 따기 | 바닐라 B42.19에는 빠루 따기·자물쇠 따기가 없음. 문은 열쇠, 분해(망치+드라이버), 부수기로만 | [pzfans B42 문 해체](https://pzfans.com/B42DoorSalvageDisassemblePrySmashYourWayInsideInProjectZomboid/) |
| 금고 | 바닐라 금고는 장식이라 열 수 없음 | [Steam 토론](https://steamcommunity.com/app/108600/discussions/0/3372657330751036720) |
| 발전기 | 양손 무거운 물건, 무게 약 30~40. 들면 다른 무거운 물건을 자동으로 내려놓음 | [pzfans 발전기](https://pzfans.com/generator_woes_in_build_42_finding_power_without_losing_your_mind/) |
| 통나무 묶기 | 로프로 통나무 2~4개를 묶음. 묶어도 무게는 합 그대로(2개 6, 4개 12) | [50% Wood Weight](https://steamcommunity.com/sharedfiles/filedetails/?id=2377867605) |
| 카테고리 옮기기 | B42.12에서 개발진이 Easy Drop'n'Loot 같은 기능을 바닐라에 넣었음 | [Easy Drop'n'Loot](https://steamcommunity.com/sharedfiles/filedetails/?id=2871469707) |
| 시체 뒤지기 시간 | Inventory Tetris의 "시체 즉시 뒤지기" 부속 모드가 "B42에선 필요 없음"이라고 적음. B42는 시체 뒤지기 대기가 없거나 짧음 (확인) | [Inventory Tetris - All the Mods](https://steamcommunity.com/sharedfiles/filedetails/?id=3044609444) |

## 2. 모드 목록

모두 70개. 링크는 창작마당 페이지다 (Steam에 없는 두 개는 Nexus·소개 페이지).

### 2.1 루팅·자동 담기·필터

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Auto Loot B41](https://steamcommunity.com/sharedfiles/filedetails/?id=2577903374) | B41 (작가가 B42판을 따로 안내함, ID 못 찾음) | 28.8만 | 아이템별 허용 목록. 용기나 시체를 열면 목록 물건을 자동으로 담음. 가방 우선순위·가방별 필터. 'Store All'은 들고 있는 물건을 같은 물건이 이미 든 근처 용기로 흩어 넣음. 가구·차량 단위로 자동 담기 금지 | 시체 300구 뒤지기를 없애 줌. 한 번 설정하면 끝 |
| [Proximity Inventory](https://steamcommunity.com/sharedfiles/filedetails/?id=2847184718) | B42.20+ | 219만 | 가까운 모든 용기와 시체의 내용을 한 페이지에 모아 보이고 바로 꺼냄. 좀비 전용 모드, 불러온 용기 하이라이트 | 창고 30번째 상자에서 망치 찾기를 없앰. 베이스에서도 유용 |
| [Easy Drop'n'Loot](https://steamcommunity.com/sharedfiles/filedetails/?id=2871469707) | B41/B42 | 8.8만 | 같은 카테고리 일괄 옮기기. '같은 종류가 이미 있는 곳으로만' 옮기기. 카테고리째 바닥에 버리기. 단축키 | 손 정리와 완전 자동 사이의 중간. 바닐라가 비슷한 기능을 따라 넣음 |
| [Pick Up All](https://steamcommunity.com/sharedfiles/filedetails/?id=3660401764) | B42.20 | 1.2만 | 구역을 고르면 캐릭터가 돌아다니며 바닥 물건을 다 주움. 가방이 다 차면 멈춤 | 전투 뒤 바닥 정리, 흩어진 자원 줍기 |
| [More Filter](https://steamcommunity.com/sharedfiles/filedetails/?id=2698410682) | B41 | 374 | 지금 용기에 카테고리 필터를 걸고 Loot All | 작은 모드지만 필터 루팅이라는 발상 |
| [Loot Luck Equalizer](https://steamcommunity.com/sharedfiles/filedetails/?id=2936635985) | B41/B42 | 3천 | 용기에 물건이 3개 이하로 채워지면 65% 확률로 채우기를 한 번 더 돌림. Lucky는 75%, Unlucky는 55% | 운이 아니라 실력으로. 바닐라 함수를 한 번 더 부르는 가벼운 방식 |
| [MaD's Awesome Zombie Loot](https://steamcommunity.com/sharedfiles/filedetails/?id=2892563252) | B41 | 19만 | 좀비가 기본 물자를 떨어뜨림. 드롭 조정 | 다른 생존 게임처럼 잡으면 뭔가 나옴 |
| [Obvious Collecting](https://steamcommunity.com/sharedfiles/filedetails/?id=3056538624) | B41 | 44만 | 바닥의 돌, 나뭇가지, 쓰레기봉투처럼 눈앞에 있는 것을 주움 | 상식. Common Sense 작가 |

### 2.2 찾기·알아보기

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Search Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2946364542) | B41/B42 | 12.8만 | 용기에 검색창. 마지막 검색어가 새 용기에도 자동 적용 | 큰 창고에서 한 물건 찾기 |
| [Item Searcher](https://steamcommunity.com/sharedfiles/filedetails/?id=2789003239) | B41 | 3.7천 | 물건을 지정하면 캐릭터가 근처 용기를 뒤져 찾음 | "찾아와" 명령 |
| [Immersive Looting: Search Mode](https://steamcommunity.com/sharedfiles/filedetails/?id=3086502143) | B41 | 2.8천 | 용기를 '수색'해야 내용이 보임. 로딩 범위를 벗어나면 수색 기록이 사라짐. `OnContainerSearched` 이벤트 제공 | 하드코어. 뒤지는 데 시간을 씀 |
| [Infinite Search Mode](https://steamcommunity.com/sharedfiles/filedetails/?id=2708978082) | B41/B42 | 4.6천 | 채집 수색 모드가 싸우거나 뛰거나 차에 타도 안 꺼짐. 화면 효과 제거 | 상시 수색. 특성판도 있음 |
| [Open All Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=3465040406) | B41/B42 | 43.8만 | 들여다본 용기는 문이 열린 모양이 됨. E로 열고 닫기, 자동 닫기 | 어디를 뒤졌는지 눈으로 보임 |
| [Show Key Origin](https://steamcommunity.com/sharedfiles/filedetails/?id=3501701205) | B42 | 2.9천 | 열쇠 툴팁에 주인 건물·차까지 거리와 방향. 월드에 방향 선. 나침반 필요 옵션 | 열쇠 더미 정리, 차 키 주인 찾기 |
| [Quick Item Action](https://steamcommunity.com/sharedfiles/filedetails/?id=2642486124) | B41/B42 | 8.3만 | 더블클릭 동작: 열쇠를 열쇠고리로, 상자 풀기·묶기, 캔 따기 등 | 클릭 수 줄이기 |

### 2.3 정리·보관 (다람쥐 베이스)

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Manage Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2650547917) | B41/B42 | 105만 | 용기마다 받을 카테고리를 지정. Shift+Transfer All이면 지정한 용기로 알아서 나눔. Alt+Shift는 모든 인벤토리에서. 즐겨찾기는 안 옮김 | 큰 수확 뒤 베이스에서 한 번에 내리기 |
| Zomboid Stash ([smods 소개](https://catalogue.smods.ru/archives/179906)) | 미상 | - | Manage Containers 부속. 최대 8칸 떨어진 지정 용기에 바로 넣음 | 걸어가지 않고 정리 |
| [Smarter Storage](https://steamcommunity.com/sharedfiles/filedetails/?id=3290232938) | B41/B42 | 74만 | 용기 버튼의 이름, 아이콘, 색을 바꿈. 프리셋 | 창고 방이 한눈에 |
| [Everything Has a Name](https://steamcommunity.com/sharedfiles/filedetails/?id=2867163008) | B41/B42 | 19만 | 용기, 아이템, 차 이름 붙이기 | 정리와 애착 |
| [Rename Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2880687295) | B41 | 49만 | 용기 이름 바꾸기 | 위와 같음 |
| [Better Sorting](https://steamcommunity.com/sharedfiles/filedetails/?id=2313387159) | B41/B42 | 331만 | 아이템 카테고리를 전부 다시 나눔 | 카테고리 정리의 기본. 다른 정리 모드와 같이 씀 |
| LootSense: Storage / QuickStack ([Nexus 333](https://www.nexusmods.com/projectzomboid/mods/333), [334](https://www.nexusmods.com/projectzomboid/mods/334)) | B42 | - | 용기 라벨, 아이템 태그, 색 테두리. QuickStack은 '근처에 알아서 내리기'(같은 아이템 → 태그 → 라벨 → 카테고리 순으로 보낼 곳을 고름) | 바닐라 균형은 두고 '기억' 부분만 도와줌 |
| [Reorder Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2901962885) | B41/B42 (중단) | 140만 | 용기·가방 아이콘 순서를 끌어서 바꿈 | 자주 쓰는 가방을 위로 |
| [Customizable Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2719850086) | B41/B42.20 | 26.5만 | 가방·차량 부품의 용량, 무게 감소율, 무게를 샌드박스로. 용기 50 한도 우회 옵션, B42 하드코딩 용량 우회(수동 설치), 월드 용기 업그레이드 키트, 라벨 | 용량 불만을 한 번에 해결. 바닐라 한도를 드러냄 |
| [Storage-O-Matic 3000](https://steamcommunity.com/sharedfiles/filedetails/?id=3000072530) | B41 | 1.1만 | 용량이 큰 보관함 하나 | "저장 문제 해결" |
| [Containers!](https://steamcommunity.com/sharedfiles/filedetails/?id=2625625421) | B41/B42 | 173만 | 월드에 ISO 컨테이너, 연료 탱크 | 무거운 물건, 부품, 남는 가구 보관 |

### 2.4 인벤토리 화면

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Equipment UI](https://steamcommunity.com/sharedfiles/filedetails/?id=2950902979) | B41/B42 (중단) | 182만 | 종이 인형 장비 칸 | 타르코프풍 |
| [Inventory Tetris](https://steamcommunity.com/sharedfiles/filedetails/?id=3397561666) | B42 (중단) | 12만 | 격자 인벤토리. 물건마다 크기. 입은 것은 칸을 안 먹음. 옷 주머니 | 무게만이 아니라 공간 퍼즐 |
| [Inventory ReInvented](https://steamcommunity.com/sharedfiles/filedetails/?id=3408629510) | B42 | 1.4만 | 아이콘 위주 작은 인벤토리 | 빠르고 깔끔 |
| [Nested Containers](https://steamcommunity.com/sharedfiles/filedetails/?id=2946221823) | B41 | 19.8만 | 가방 안 가방 내용을 보여 줌 | 가방 젠가 해결 |

### 2.5 옮기기 속도

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Instant Item Transfer](https://steamcommunity.com/sharedfiles/filedetails/?id=3418662022) | B42 | 1.1천 | 아이템 옮기기만 즉시. 다른 동작은 그대로. 통나무 같은 것은 여전히 느리다는 댓글 | 옮기기 대기만 없앰 |
| [Rushed Transfer](https://steamcommunity.com/sharedfiles/filedetails/?id=2691346300) | B41/B42 | 2.2천 | 단축키(O)로 한 물건을 바로 옮기는 대신 대가: 무게에 따라 소음 5~20칸, 지구력 소모(프로판 탱크면 보통 2.5%, Fitness 10이면 1.25%), 물건이나 몸이 다칠 위험. State of Decay에서 따옴 | 빠름과 위험을 맞바꿈 |
| [Faster Construct And Transfer](https://steamcommunity.com/sharedfiles/filedetails/?id=2900386490) | B41 | 2.7만 | 가구 짓기·줍기·분해·옮기기 속도를 샌드박스로 | 손이 느린 게임 템포 조절 |

### 2.6 따기·침입

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Common Sense](https://steamcommunity.com/sharedfiles/filedetails/?id=2875848298) | B41/B42 | 355만 | 빠루로 문·창문·차량 따기, 바닥 재료 줍기, 손전등 벨트에 달기 등 상식 QoL 묶음 | "당연히 될 것 같은 것"을 되게 함 |
| [Better lockpicking](https://steamcommunity.com/sharedfiles/filedetails/?id=2368058459) | B41 | 71만 | 머리핀·빠루로 문·창문·차 따기 미니게임. 와이어로 시동 걸기 미니게임. 집·차 알람 확인. 자물쇠 따기 기술, 잡지로 해금. 급하면 강제 열기(낮은 확률) | 열쇠 대신 실력. 알람 확인이 특히 좋음 |
| [zRe Better Lockpicking](https://steamcommunity.com/sharedfiles/filedetails/?id=2929123989) / [B42.13+판](https://steamcommunity.com/sharedfiles/filedetails/?id=3623784989) | B41 / B42 | 18.5만 / 2만 | 위 모드의 독립 재작성판 | 원본이 멈춘 뒤 이어받음 |
| [The Best Lockpicking](https://steamcommunity.com/sharedfiles/filedetails/?id=3440867775) | B42.21 | 4.3만 | 락픽+드라이버 미니게임, 빠루 강행(자물쇠 영구 파손 위험), 차 탈취, 알람 확인, Lockpicker 특성. 픽 부러짐 0~60%, 자물쇠 파손 0~40%, 강제 개방 0~20%가 기술·근력으로 줄어듦 ([smods 소개](https://catalogue.smods.ru/archives/345443)) | 실패 위험이 긴장을 만듦 |
| [Lockpicking! Just. Lockpicking.](https://steamcommunity.com/sharedfiles/filedetails/?id=2056238799) | B41 | 23만 | 진짜 락픽 아이템, 클립이나 철사+칼로 제작, 기술 판정 | 단순하고 현실적 |
| [FBI Open Up Door](https://steamcommunity.com/sharedfiles/filedetails/?id=2732513069) | B41/B42 | 1.5만 | 달리면서 문에 닿으면 발로 차서 엶. 지구력 소모, Fitness XP. B42에서는 문 뒤 좀비를 밀쳐 넘어뜨리기 옵션. 잠긴 문은 못 엶 | 멈추지 않는 진입 |
| [Immersive Safes](https://steamcommunity.com/sharedfiles/filedetails/?id=3212103710) | B41 | 3.2만 | 다른 모드에 금고를 넣는 도구 | 금고라는 목표물 |

### 2.7 무게

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Weight Void](https://steamcommunity.com/sharedfiles/filedetails/?id=2287977869) | B41/B42 | 8.3천 | 인벤토리에 음수 무게 '빈자리'를 넣어 사실상 무한 운반. B42에서는 50 한도를 못 넘는다는 댓글 | 무거운 짐 꼼수 |
| [No Weight](https://steamcommunity.com/sharedfiles/filedetails/?id=2606989930) | B41/B42 | 1만 | 모든 아이템 무게 0 | 치트 |
| [50% Wood Weight](https://steamcommunity.com/sharedfiles/filedetails/?id=2377867605) | B40~B42 | 130만 | 통나무, 판자, 통나무 묶음 무게 절반 | 건축 재료 운반이 제일 고통스러움 |
| [50% metal weight](https://steamcommunity.com/sharedfiles/filedetails/?id=2829657632) | B41/B42 | 49만 | 판금, 쇠막대, 드럼통, 파이프, 고철, 와이어 등 무게 절반 | 위와 같음. 계열별 무게 감소의 근거 |
| Material Weight Reducer ([itemlevel 소개](https://itemlevel.net/10-best-mods-for-project-zomboid-build-42/)) | B42 | - | 건축 재료·기본 재료·도구 무게를 약 20%로. 열쇠는 0 | 재료 운반 |
| [B42] weightless keys ([토론에서 링크](https://steamcommunity.com/sharedfiles/filedetails/?id=3408222483)) | B42 (지금 비공개로 보임) | - | 열쇠 무게 0 | 열쇠 무게 불만 |
| [Hidden Carry](https://steamcommunity.com/sharedfiles/filedetails/?id=3407480442) | B42 | 5천 | 구급상자, 도시락, 종이봉투, 권총 케이스 같은 작은 가방을 열쇠고리처럼 보이지 않게 맴. 무게 0.1, 용량 2배 | 옷 칸을 안 먹는 숨은 주머니 |
| [Item Weight Rebalance](https://steamcommunity.com/sharedfiles/filedetails/?id=2717963127) | B41 | 2.2만 | 화장품, 장신구, 봉합 도구 같은 작은 필수품 무게 크게 줄임 | 잡동사니 무게가 비현실적 |
| [Realistic Inventory](https://steamcommunity.com/sharedfiles/filedetails/?id=1920135086) | B41 | 4.5천 | 가방 밖 맨몸으로는 작은 물건 0.5~1.5kg(주머니 수에 따라) + 중간 물건 3개 또는 큰 물건 1개만. 넘으면 걷다가 떨어뜨림 | 하드코어. 반대로 하면 '주머니' 강화 아이디어 |
| [SOTO](https://steamcommunity.com/sharedfiles/filedetails/?id=2840805724) | B41/B42 SP | 75만 | 특성·직업 개편. 운반 관련 특성 포함 | 대형 특성 모드. 겹침 확인 대상 |
| [More Traits](https://steamcommunity.com/sharedfiles/filedetails/?id=1299328280) | B41/B42 (지원 끝) | 194만 | Pack Mule(운반량 증가) 등. 50 엔진 한도 명시 | 대형 특성 모드 |
| [Stackable Planks](https://steamcommunity.com/sharedfiles/filedetails/?id=2771356513) → [B42판](https://steamcommunity.com/sharedfiles/filedetails/?id=3403092842) | B41 / B42 | 1.2만 | 판자를 로프로 묶어 쌓음 | 통나무 묶기의 판자판 |

### 2.8 수레·무거운 물건·가구

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Wheelbarrow from Hydrocraft](https://steamcommunity.com/sharedfiles/filedetails/?id=2926995676) | B41/B42 | 5.6만 | 양손으로 미는 손수레. 최대 180까지 담음(B42 39 한도를 우회). 통나무·목재 운반 | 통나무 나르기 |
| [ZuperCarts](https://steamcommunity.com/sharedfiles/filedetails/?id=3433203442) | B42 (작동 중단) | 5.9만 | 카트·트롤리. 48 무게. G로 장착 | 무거운 짐 운반 |
| [ForkLift](https://steamcommunity.com/sharedfiles/filedetails/?id=3096848722) | B41/B42 | 4.9만 | 지게차. 팔레트, 물 저장소, 연료 드럼, 발전기 칸 | 베이스 건설용 대형 운반 |
| [Trailers!](https://steamcommunity.com/sharedfiles/filedetails/?id=3330403100) | B41/B42 | 162만 | 화물 트레일러 6종 | 차량 적재량 확장 |
| [Skizot's Carryable Everything](https://steamcommunity.com/sharedfiles/filedetails/?id=2921029369) | B41 | 59만 | TV, 쓰레기통, 상자 같은 것을 들고 옮김. 냉장고류는 핸드트럭을 꺼내는 모습 | "들 수 있어야 할 것"을 들게 함 |
| [Rebalanced Prop Moving](https://steamcommunity.com/sharedfiles/filedetails/?id=2699828474) | B40~B42 | 44만 | 가구·가전은 도구·기술 없이 듦. 붙박이(찬장·선반)는 그대로지만 파손 확률이 기술 0에서 30%, 1에서 20%, 2에서 10%, 3 이상 0% | "소파 옮기는 데 망치가 왜 필요해" |
| [Collapsible Ladder](https://steamcommunity.com/sharedfiles/filedetails/?id=3438123707) | B41/B42 | 5.4만 | 사다리를 접어 벨트에 닮 | 지붕 루팅·은신 |
| [Fancy Lanterns](https://steamcommunity.com/sharedfiles/filedetails/?id=3267733558) | B41/B42 | 2.1만 | 가방·벨트에 다는 충전식 등 | 밤 루팅 손 비우기 |

### 2.9 시체

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Easy Corpse Move](https://steamcommunity.com/sharedfiles/filedetails/?id=2813064350) | B41 | 10.7만 | 시체 줍기·버리기 칸을 녹색으로 표시. 캐릭터가 자동으로 걸어감. 무덤 위에 놓으면 자동 매장 | 풀숲 시체 찾기, 왕복 줄이기 |
| [Auto Move Corpses](https://steamcommunity.com/sharedfiles/filedetails/?id=3415416226) | B42.20 | 3.4만 | 버릴 곳과 구역을 고르면 구역 안 시체를 전부 옮김. 빨리 감기 대응. 좀비 무시 안전 토글. 창밖으로 던지기 준비 중 | 대규모 전투 뒤 청소 |
| [Weightless Corpses](https://steamcommunity.com/sharedfiles/filedetails/?id=2844566602) | B41 | 2.7만 | 시체 무게 0 | 베이스 시체 청소 |
| [bikinitools](https://steamcommunity.com/sharedfiles/filedetails/?id=2634426926) | B41/B42.12+ | 28.6만 | 자동화 모음: 구역 시체 모아 쌓기, 흙·모래·자갈 자동 퍼담기, 가구 속 물건 바닥에 쏟기, 벌목 등 | 반복 노동 자동화 |
| [Cremation](https://steamcommunity.com/sharedfiles/filedetails/?id=1907165735) | B41 | 2.5만 | 캠프파이어에 시체를 태움 | 시체 더미 처리 |
| [Garbage Truck](https://steamcommunity.com/sharedfiles/filedetails/?id=2783580134) | B41 | 6.7만 | 쓰레기 수거 트럭 | 거리 청소 |

### 2.10 차량 적재

| 모드 | B42 | 구독 | 기능 | 인기 이유 |
| --- | --- | --- | --- | --- |
| [Eggon's Worthwhile Cars 2.0](https://steamcommunity.com/sharedfiles/filedetails/?id=2841030649) | B41 | 10만 | 트렁크가 손상되면 용량이 주는 정도를 조절(기본은 안 줄게). 트렁크 용량 재조정 | 망가진 차 트렁크가 쓸모없어지는 불만 |
| [Tsar's Common Library B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3402491515) | B42 | 105만 | 차량 모드 공용 라이브러리. 부품 싣기·내리기와 내용물 보존 수정 | 차량 모드 기반 |
| [Bicycle!](https://steamcommunity.com/sharedfiles/filedetails/?id=3461415167) | B42.20+ | 27만 | 자전거. KI5 차량 트렁크로 옮기기 지원 | 연료 없는 이동 루팅 |

## 3. 강화 아이디어

모드에서 뽑은 것과 바닐라 수치에서 떠오른 것을 다 적는다. "출처"는 영감을 준 모드나 바닐라 사실이다. 이미 IDEAS.md에 있는 것은 (있음)으로
표시하고, 모드를 보고 구체적인 수치나 단계를 덧붙였다.

- 수동: 찍을 때마다 커지는 패시브
- 능동: 누르면 발동, 재사용 대기시간

### 3.1 수색

#### 루팅

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 손 닿는 범위 | 근처 용기를 한 화면에 모아 보고 꺼냄. 1점은 같은 칸 주변 1칸, 찍을수록 반경 2~3칸, 상위는 위아래 층 | Proximity Inventory |
| 시체 한눈에 | 위의 시체판. 근처 시체 전부를 한 목록으로. 하위 노드로 따로 둘 수 있음 | Proximity Inventory 좀비 전용 모드 |
| 자동 담기 (있음) | 찍을수록 허용 목록 칸 수가 늘고, 상위는 가방 우선순위·가방별 필터 | Auto Loot |
| 카테고리 손 | 같은 카테고리 일괄 줍기·버리기. 상위는 '이미 가진 종류만 줍기' | Easy Drop'n'Loot |
| 운 좋은 손 (있음) 구체안 | 처음 연 용기에 물건이 3개 이하면 채우기를 한 번 더 굴림. 찍을수록 확률 20%→65%. 처음 연 용기만이라 도감 경제와 맞음 | Loot Luck Equalizer |
| 좀비 주머니 | 좀비 시체에서 기본 물자가 조금 더 나옴. 찍을수록 확률 증가 | MaD's Awesome Zombie Loot |
| 눈앞의 것 | 바닥의 돌, 나뭇가지, 쓰레기봉투처럼 줍지 못하던 것을 주움 | Obvious Collecting |
| 바닥 쓸기 (능동) | 구역을 고르면 캐릭터가 돌며 바닥 물건을 주움. 찍을수록 구역 크기, 줍는 속도. 허용 목록과 연동 가능 | Pick Up All |
| 자석 손 | 손 닿는 거리 밖 바닥 물건을 걷지 않고 주움. 찍을수록 거리 1→3칸 | Zomboid Stash의 원격 거리, Pick Up All |

#### 찾기·알아채기

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 찾는 물건 표시 (있음) 구체안 | 검색어를 정하면 그 물건이 든 근처 용기가 빛남. 찍을수록 반경과 동시에 찾는 물건 수 | Search Containers, Item Searcher |
| 찾아와 (능동) | 물건 이름을 고르면 캐릭터가 근처 용기를 돌며 찾아 담음 | Item Searcher |
| 뒤진 자리 표시 | 한 번 연 용기는 문이 열린 모양이나 표시가 남음. 찍을수록 표시가 오래 가고, 상위는 건물 단위로 '다 뒤짐'을 알려 줌 (남은 용기 감, 뒤진 건물 기록과 연결) | Open All Containers, Immersive Looting |
| 열쇠 출처 감 | 열쇠 툴팁에 주인 건물·차 정보. 1점은 방향만, 2점은 거리, 3점은 월드에 선. 바닐라 열쇠 감과 합칠 수 있음 | Show Key Origin |
| 알람 감 | 집·차에 알람이 있는지 문에 손대기 전에 앎. 찍을수록 거리 증가, 상위는 알람 끄기 확률 | Better lockpicking 알람 확인 |
| 창고 기억 | 한 번 연 용기는 떨어져서도 내용을 툴팁으로 봄. 찍을수록 기억하는 용기 수와 거리 | Proximity, LootSense 툴팁 |
| 다람쥐 장부 | 베이스 근처 모든 용기에 든 아이템 수를 합쳐 보여 줌. "통조림 214개". 찍을수록 범위 | 정리 모드들. 모으는 재미를 숫자로 보여 줌 |

#### 손기술·따기

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 빠루 따기 (있음) | 바닐라 B42.19에 없음이 확인됨. 문·창문·차고 문. 성공률은 근력과 기술 | Common Sense |
| 빠루 솜씨 (있음) 구체안 | 실패 시 자물쇠 영구 파손 확률을 줄임(40%→0%), 소음 반경 감소 | The Best Lockpicking |
| 자물쇠 따기 | 머리핀·클립으로 조용히 땀. 빠루보다 느리지만 조용함. 찍을수록 픽 부러짐 확률 감소(60%→0%), 속도 증가 | Better lockpicking, Lockpicking! Just. Lockpicking. |
| 강제 열기 (능동) | 급할 때 한 번에 비틀어 엶. 큰 소음, 자물쇠 파손. 찍을수록 성공률 | Better lockpicking 강제 열기 |
| 차량 따기 (있음) + 시동 걸기 | 차 문·트렁크에 더해 와이어로 시동 걸기 속도·성공률 | Better lockpicking 시동 미니게임 |
| 금고 따기 (있음) | 바닐라 금고는 장식이라 못 엶. 열 수 있는 금고는 다른 모드에 의존하거나 새 용기를 만들어야 함 | Immersive Safes |
| 문 박차기 (능동 또는 수동) | 뛰면서 잠기지 않은 문을 발로 차 엶. 상위는 문 뒤 좀비를 밀쳐 넘어뜨림. 지구력 소모 | FBI Open Up Door |
| 무덤덤한 손 | 시체를 벗길 때 생기는 불행이 없음. 시체 뒤지기와 짝 | 바닐라 `ISInventoryTransferAction` 130행 |
| 장갑 낀 손 | 둔한 장갑을 껴도 옮기기 시간 2배 페널티가 사라짐 | 바닐라 둔한 장갑 × 2.0 |
| 뒤지기 (있음) 구체안 | 월드 용기 ↔ 나 옮기기 기본 50, 시간에 배율. 찍을수록 × 0.9, 0.8, 0.7. Dextrous(× 0.5)와 곱해서 쌓임 | 바닐라 옮기기 공식 |
| 걸으며 뒤지기 | 월드 용기에서 옮기는 중 걸어도 멈추지 않음, 걸을 때 × 1.5도 줄어듦 | 바닐라 `stopOnWalk`, 이동 × 1.5 |
| 즉시 털기 (능동) | 몇 초간 옮기기가 즉시. 대가로 무게 비례 소음(5~20칸)과 지구력. 찍을수록 지속시간, 소음 감소 | Rushed Transfer |
| 사다리 손 | 사다리를 접어 몸에 지님. 지붕·2층 창문 루팅 | Collapsible Ladder. 아이템이라 경계선 |

### 3.2 운반

#### 몸

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 운반 한도 (있음) | 바닐라 `maxWeightDelta`와 같은 축의 배율을 얹음. 특성 배율과 곱해 쌓기 | 디컴파일 IsoPlayer |
| 캐릭터 용량 (있음) | 50 한도를 올리는 노드. 엔진 하드코딩이라 확장 API가 필요할 것 (확인) | Weight Void, Pack Mule, Customizable Containers |
| 과적 완화 (있음) | 과적 단계 기준선을 늦춤. 100%→110%처럼 단계 시작점을 밀어냄 | 과적 단계 100/125/150/175% |
| 과적 체력 (있음) 구체안 | 과적 체력 손실 상한 30%를 줄임. 찍을수록 30→20→10% | 커뮤니티 30% |
| 짐 진 착지 | 과적일 때 낙하 피해 배율(짐 비율, 상한 1.8)과 골절 가산을 줄임. 상위는 짐 때문에 늘어나는 피해 0 | 바닐라 낙하 코드 |
| 짐 훈련 | 짐이 최대의 50%를 넘을 때 얻는 힘 XP를 늘림. 운반이 근력을 키우는 순환 | 바닐라 `XpUpdate` |
| 주머니 여유 | 가방 밖 작은 물건(0.1 이하 등) 무게를 일정량까지 무시. 찍을수록 0.5→1.5. 열쇠, 약, 탄약 낱개 | Realistic Inventory의 반대, Item Weight Rebalance |
| 숨은 주머니 | 작은 주머니 하나를 옷 칸을 안 쓰고 지님. 캐릭터 능력으로 둘지 신뢰도 보상으로 둘지 경계 | Hidden Carry |
| 무거운 짐 (있음) | 양손 무거운 물건(발전기 30~40, 가구) 들고 걷기 속도 | 발전기 무게 |
| 짐 든 채로 (있음) | 무거운 물건을 든 채 문 열기, 계단. 바닐라는 무거운 물건을 들면 다른 손 물건을 강제로 내려놓음 | `isForceDropHeavyItem` |
| 짐꾼 (캡스톤 있음) | 무거운 물건 둘 | 같음 |
| 수레꾼 | 손수레·카트·쇼핑카트를 밀 때 이동 속도 증가, 수레 짐 무게 감소. 수레 자체는 아이템 | Wheelbarrow, ZuperCarts |
| 괴력 (능동) | 몇 초~몇 분 동안 운반 한도 크게 증가. 끝나면 지구력·피로 대가 | 무게 꼼수 모드들을 능동으로 |
| 가방 던지기 (능동) | 과적일 때 메고 있는 가방을 순식간에 벗어 던지고 뛰기. 위험할 때 탈출용 | 과적 단계의 질주 불가 |

#### 무게

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 계열별 무게 감소 (있음) | 목재, 금속, 돌·자루, 액체. 각 계열 최대 50%까지. 인기 모드 둘이 정확히 이 형태 | 50% Wood Weight(130만), 50% metal weight(49만) |
| 건축 재료 | 못·나사 상자, 판금, 벽돌 같은 건축 재료 묶음 | Material Weight Reducer |
| 열쇠고리 (있음) | 바닐라 열쇠 0.05, 열쇠고리 감소 85%라 이미 가벼움. 열쇠고리 밖 열쇠까지 0으로, 상위는 주운 열쇠가 자동으로 열쇠고리로 | 바닐라 수치, Quick Item Action |
| 시체 무게 | 시체를 들거나 끌 때 무게 감소 | Weightless Corpses |
| 묶음 요령 | 통나무·판자 묶음 최대 개수 증가, 로프 대신 끈이나 천으로 묶기. 묶으면 무게 조금 감소 | 바닐라 통나무 묶기, Stackable Planks |
| 입은 것·매단 것·가방 다루기 (있음) | 변화 없음 | |

#### 속도

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 옮기기 (있음) 구체안 | 내 가방끼리 기본 120. 가방이 찰수록 느려지는 배율(찬 비율, 최소 0.4)을 줄임 | 바닐라 `destCapacityDelta` |
| 무거운 물건 옮기기 | 무게 3 이상 물건은 시간 × 3. 이 상한을 낮춤(3→2). 통나무·판금이 빨라짐. Instant Item Transfer가 통나무에서 안 먹는다는 불만이 있음 | 바닐라 `min(w, 3)` |
| 내려놓기 | 바닥에 내려놓기 즉시(바닐라 × 0.1, × 0.2) | 바닐라 |
| 한꺼번에 옮기기 | 같은 종류를 여러 개 옮기면 두 번째부터 개당 시간 감소 | Easy Drop'n'Loot |
| 정리 (있음) 구체안 | '같은 물건이 있는 근처 용기로 나눠 넣기'. 찍을수록 반경 2→8칸 | Auto Loot Store All, LootSense QuickStack, Zomboid Stash 8칸 |
| 지정 창고 보내기 | 용기마다 카테고리를 정해 두면 한 번에 그쪽으로. 정리의 상위 | Manage Containers |
| 차 짐 싣기 (있음) | 트렁크 싣고 내리기 속도 | |
| 운전석 트렁크 | 차에 탄 채로 트렁크·뒷좌석에 넣고 꺼냄 | 차량 적재 모드 |
| 꽉 채우기 | 차 트렁크나 월드 용기에 넣을 때 물건이 덜 무겁게 계산됨(테트리스 적재). 상위는 손상된 트렁크 용량 감소를 줄임 | Eggon's Worthwhile Cars, Inventory Tetris. 용기 강화라 경계선 |

#### 가구·시체

| 아이디어 | 효과와 단계 | 출처 |
| --- | --- | --- |
| 가구 다루기 | 가구 들기·놓기 파손 확률 감소. 찍을수록 30→0%. 상위는 도구·기술 없이 가구·가전을 듦 | Rebalanced Prop Moving |
| 가구 손 | 가구 줍기·분해 속도 증가 | Faster Construct And Transfer |
| 무엇이든 든다 | TV, 쓰레기통, 큰 상자처럼 바닐라가 못 드는 것을 듦 | Skizot's Carryable Everything |
| 끌기 (캡스톤 있음) | 무거운 가구를 끌어서 옮김. 핸드트럭 모습 | Skizot, Hydrocraft 핸드트럭 |
| 시체 나르기 (있음) 구체안 | B42 바닐라 시체 끌기 속도. 상위는 시체 둘 | 바닐라 BodyDragging |
| 시체 치우기 (능동) | 구역과 버릴 곳을 고르면 자동으로 시체를 옮겨 쌓음. 찍을수록 구역 크기, 속도 | Auto Move Corpses, bikinitools 시체 쌓기 |
| 무덤 파는 손 | 시체를 무덤 칸에 놓으면 자동 매장. 삽 없이 | Easy Corpse Move |
| 창밖으로 | 시체를 창밖으로 던짐 | Auto Move Corpses 계획 |

### 3.3 다람쥐 보상 (수집과 연결)

모드의 '모으는 재미'에 맞춰, 수집을 직접 보상하는 쪽. 어느 트리에 둘지는 미정.

| 아이디어 | 효과 | 출처 |
| --- | --- | --- |
| 다람쥐 장부 | 베이스 재고를 숫자로. 위 찾기 항목과 같음 | |
| 모으는 기쁨 | 베이스 용기에 정리된 물건이 많을수록(종류 수 기준) 베이스 안에서 지루함·스트레스가 천천히 쌓임. 생존 트리 연결 | 기획 |
| 집으로 | 베이스 근처에서만 옮기기·정리 속도 추가 보너스 | 기획 |
| 첫 수확 | 처음 연 건물에서 처음 담는 물건은 옮기기가 즉시 | 운 좋은 손과 같은 '처음' 경제 |

### 3.4 능동 기술 모음

| 능동 | 트리 | 대가 | 출처 |
| --- | --- | --- | --- |
| 즉시 털기 | 수색 | 무게 비례 소음, 지구력 | Rushed Transfer |
| 찾아와 | 수색 | 대기시간 | Item Searcher |
| 강제 열기 | 수색 | 큰 소음, 자물쇠 파손 | Better lockpicking |
| 문 박차기 | 수색 | 지구력 | FBI Open Up Door |
| 단숨에 털기 (있음) | 수색 | 대기시간 | |
| 바닥 쓸기 | 운반 | 시간 | Pick Up All |
| 시체 치우기 | 운반 | 시간 | Auto Move Corpses |
| 한 번에 정리 | 운반 | 대기시간 | Store All, QuickStack |
| 괴력 | 운반 | 끝나고 지구력·피로 | 무게 꼼수 모드 |
| 가방 던지기 | 운반 | 가방을 버림 | 과적 단계 |

## 4. 겹침과 호환 메모

- **많이 쓰는 모드**: Proximity Inventory(219만), Manage Containers(105만), Better Sorting(331만), Common Sense(355만), Smarter Storage(74만),
  50% Wood Weight(130만). 우리 노드가 이 모드들과 같이 켜져도 돌아야 한다. 특히 인벤토리 화면을 덮어쓰는 모드(Inventory Tetris,
  Equipment UI, Proximity)는 옮기기 시간 계산 지점을 같이 건드릴 수 있다.
- **옮기기 시간**: Instant Item Transfer, Faster Construct And Transfer는 `ISInventoryTransferAction` 시간을 고친다. 우리는 배율로 얹어야
  같이 쌓인다.
- **무게**: 50% 무게 모드들은 아이템 스크립트 무게를 바꾼다. 우리는 원본을 바꾸지 않고 계산 시점에 배율을 얹기로 했으니, 두 개가 같이
  켜지면 곱해진다. 상한을 둘지 정해야 한다.
- **빠루·자물쇠**: Common Sense와 Better lockpicking 계열이 같은 문·차에 메뉴를 단다. 같이 켜면 메뉴가 둘이 될 수 있다.
- **특성 모드**: SOTO, More Traits는 운반 특성(Pack Mule 등)을 넣고, 42.12 이후 이런 무게 특성이 깨졌다는 보고가 있다. 운반 한도를 어디서
  얹어야 다시 덮어써지지 않는지 확인해야 한다 (확인).
- **자동 담기 복제 버그**: Auto Loot 댓글에 멀티에서 가방 안 가방을 자동으로 털면 아이템이 복제된다는 보고가 있다. 자동 담기·한꺼번에 털기
  구현 때 중첩 용기를 조심한다.

## 5. 확인할 것

- 캐릭터 인벤토리 50 한도가 어느 Java 코드에 있는지, 확장 API로 올릴 수 있는지
- 실제 최대 운반 무게 계산식(`maxWeightBase` 8과 근력·특성 배율이 어떻게 합쳐지는지)
- B42 용기 용량 상한(39 또는 다른 값)이 어디 있는지
- B42 시체 뒤지기 대기시간이 있는지
- B42에서 Lucky·Unlucky 특성이 정말 빠졌는지, 루트 굴림에 행운 보정이 남아 있는지
- 과적 체력 손실 30% 상한의 정확한 코드
