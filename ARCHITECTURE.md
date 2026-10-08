# 도토리 작전 코드 구조 (ARCHITECTURE)

[설계 문서](DESIGN.md)를 코드로 나누는 법이다. 여러 작업 묶음이 동시에 만들어지므로, 묶음 사이의 약속(파일, 함수, 저장 데이터,
번역 키, 아이템 이름)을 여기 적는다. 약속을 바꾸면 이 문서를 먼저 고친다.

## 1. 저장소

```text
OperationAcorn/            모드 폴더 (Zomboid\mods에 정션으로 잇는다)
  common/mod.info
  42/mod.info
  42/media/lua/shared/OperationAcorn/   양쪽에서 도는 것: 기반, 순수 로직(경제), 데이터 정의
  42/media/lua/server/OperationAcorn/   서버(혼자 할 때도 돈다): 헬기 정산, 임무 생성, 기계 처리
  42/media/lua/client/OperationAcorn/   화면, 우클릭 메뉴, 툴팁
  42/media/lua/shared/Translate/EN|KO/  번역 (EN, KO 둘 다 늘 같은 키)
  42/media/scripts/OA_<묶음>.txt        아이템, 레시피 (묶음마다 파일 하나, module OperationAcorn)
  42/media/sandbox-options.txt          샌드박스 옵션 (이름과 기본값은 NUMBERS.md)
tests/unit/                게임 밖 단위 테스트 (tools/LuaTest.java)
tests/ingame/              게임 안 확인 스크립트 (마지막 통합 확인 때 콘솔에서 돌린다)
tools/                     LuaTest.java, LuaCheck.java, check_translations.py, tile_art.py(에셋 묶음)
```

## 2. 검사

모든 묶음은 커밋 전에 셋을 돌린다. 게임은 켜지 않는다 (게임 안 확인은 마지막에 한 번 모아서 한다).

```text
JAVA="C:\git\pz-workspace\pz-tools\artifacts\toolchains\jdk-25.0.4.1+1\bin\java.exe"
JAR="C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\projectzomboid.jar"
"$JAVA" -cp "$JAR" tools/LuaTest.java [파일 이름 일부]     # tests/unit/*_test.lua, 저장소 루트에서
"$JAVA" -cp "$JAR" tools/LuaCheck.java <바꾼 .lua 파일들>  # 게임의 Kahlua 컴파일러로 문법 검사
python tools/check_translations.py                          # 번역 키, 샌드박스, 아이템 이름
```

- **단위 테스트:** 게임 객체를 만지지 않는 로직(값 매기기, 시세, 신뢰도, 상점 한도, 분해 산출, 트리 규칙, 임무 장소 고르기,
  기계 따라잡기)은 순수 함수로 쓰고 `tests/unit/<이름>_test.lua`로 시험한다. 하네스(`tests/unit/harness.lua`)가
  `SandboxVars`(sandbox-options.txt의 기본값), `ModData`, `getGameTime`, `ZombRand`, `Events`, `getText`를 흉내 낸다.
  테스트 하나마다 모드와 저장이 새로 시작한다. 게임 객체가 필요한 부분은 얇은 어댑터 함수로 떼어 내고 로직에는 표만 넘긴다.
- **Kahlua 주의:** `%`는 음수와 큰 수(`getTimestampMs`)에서 틀린다 (`OA.remainder`). 정수 나눗셈 연산자, `goto`, 비트 연산이
  없다. `string.format("%d")`에 소수를 넘기지 않는다.

## 3. 공용 기반 (이미 있음)

| 파일 | 하는 일 |
| --- | --- |
| `shared/OperationAcorn/Core.lua` | `OperationAcorn`(=`OA`) 이름공간, `OA.log`, `OA.api()`/`OA.handle()`(확장 API), `OA.option(name)`(샌드박스), `OA.hours()`(세계 나이, 시간), `OA.day()`(00시에 바뀌는 날 번호), `OA.week()`, `OA.random(a, b)`(둘 다 포함), `OA.randomFloat`, `OA.round`, `OA.clamp`, `OA.remainder` |
| `shared/OperationAcorn/Store.lua` | 저장 데이터. 전역 ModData `OA_World` 하나에 모두 둔다. `Store.world(section)`, `Store.player(id)`, `Store.section(record, section)`, `Store.players()`, `Store.ensure(id, name)`(기록과 네 자리 채집점 번호를 만든다), `Store.idOf(character)`(캐릭터 modData `OA_Id`) |
| `shared/OperationAcorn/Sync.lua` | 바뀐 것 알리기. `Sync.changed(what, playerId, detail)`, `Sync.notice(playerId, key, args)`, `Sync.send(character, command, args)`(클라이언트 → 서버, `args.id`를 붙인다), `Sync.listen(what, fn)`(클라이언트 쪽) |
| `shared/OperationAcorn/Chunks.lua` | 칸이 불러질 때 할 일의 대기 표 (`LoadChunk`, 청크 키). `Chunks.handle(kind, fn)`, `Chunks.add(entry)`, `Chunks.remove(predicate)`, `Chunks.list(kind)`. `LoadGridsquare`는 쓰지 않는다 |
| `shared/OperationAcorn/Sprites.lua` | 이 모드 타일 이름 (`Sprites.terminal(dir, on)`, `Sprites.machine(kind, dir, running)` ...). 시트 자리는 바꾸지 않는다 |
| `server/OperationAcorn/Server.lua` | 클라이언트 명령 받기: `OA.Server.on(name, function(character, record, args) ... end)`. `LoadChunk`를 `Chunks`에 잇는다 |
| `client/OperationAcorn/Client.lua` | 서버가 보낸 것을 `Sync` 듣는 쪽으로. `OA.Client.record(character)`(이 클라이언트가 보는 내 기록), 첫 접속 때 `hello` |

- **변경은 서버에서만 한다.** 화면은 `OA.Sync.send`로 서버에 부탁하고, 서버 핸들러가 기록을 고친 뒤 `OA.Sync.changed`를 부른다.
  혼자 할 때는 같은 과정이 즉시 돈다. 멀티플레이는 검증하지 않지만 막지도 않는다 (이 구조만 지킨다).
- **기록은 캐릭터마다 하나다.** 연구팀은 그 생존자와 거래한다. 캐릭터가 죽고 새로 시작하면 새 채집점 번호와 새 기록이다.
  강화, 신뢰도, 크레딧 모두 새로 시작한다. 이전 캐릭터의 상자와 기록은 세계에 남는다.
- **매 틱·매 프레임 처리 금지** (DESIGN 12장 성능 규칙). 시각 비교는 `EveryTenMinutes`, 날 바뀜은 `EveryDays`, 칸 일은 `Chunks`.

## 4. 저장 데이터와 주인

플레이어 기록(`Store.player(id)`)의 섹션:

| 섹션 | 주인 | 내용 |
| --- | --- | --- |
| `trade` | 거래(P2), 경제(P1)가 함께 쓴다 | `credits`(정수, 빚이면 음수), `trust`(소수까지), `stage`(0~5), `milestones`(지난 이정표 수), `bonus`(다음 정산 때 들어올 보너스 크레딧), `sharedSerums`(다음 보급에 실을 공용 혈청 수). P1의 `Trust.add`, `Codex` 함수가 이 칸을 고친다. 나머지 칸은 P2 |
| `codex` | P1 | 도감, 털이, 처치 기록 |
| `shop` | P1 | 품목별 구매 시각, 주간 구매 수, 키트 대상별 사용 수 |
| `shred` | P1 | 종류별 최근 분해 수(날마다 ×0.9), 처음 분해한 종류 |
| `boxes`, `heli`, `orders`, `ledger`, `radio` | P2 | 상자, 헬기, 주문, 납품 장부, 무전 기록 |
| `upgrades` | P3 | 트리 점, 노드, 캡스톤, 2차 판, 산 혈청 수 |
| `missions`, `story` | P4 | 임무, 이야기 진행, 문서철 |

세계 섹션(`Store.world(name)`): `market`, `requests`(P1), `sites`(P4, 운석 낙하지), `machines`(P5), `pending`(Chunks).

아이템과 오브젝트 modData 키는 모두 `OA_`로 시작한다: `OA_Bought`(상점에서 산 물건, 납품 거부), `OA_Cell`(나온 셀,
새 지역 웃돈), `OA_Mission`(임무 ID), `OA_Box`(상자 ID), `OA_Issued`(혈청 발급 시각), `OA_Owner`(발급받은 기록 ID).

## 5. 작업 묶음

| 묶음 | 맡는 것 | 파일 |
| --- | --- | --- |
| P1 경제 | 계열, 값 매기기, 시세, 요청 품목, 신뢰도와 단계 보상, 도감·털이·처치 보너스, 상점 목록과 한도와 가격, 분해 산출. 순수 로직 + 단위 테스트, 게임 어댑터는 얇게 | `shared/OperationAcorn/Economy/*.lua` |
| P2 거래 | 통신 단말(설치물, 전기, 창과 탭), 납품 상자(설치, 허용 규칙, 밀봉, 파괴, 재발급과 빚), 헬기(호출, 도착, 정산, 보급 상자, 영수증, 명세서), 첫 보급, 한꺼번에 담기, 감정가 툴팁과 견적 창, 새 지역 표시, 주문과 결제, 무전 기록 | `*/OperationAcorn/Trade/*.lua`, `scripts/OA_trade.txt` |
| P3 강화와 몸 | 트리 셋과 2차 판의 데이터, 점과 혈청, 연구 승인, 캡스톤, 초기화, 트리 화면, Lua로 되는 노드 효과, API 노드의 선언(API가 있을 때만), 치료 혈청·지연제(유통 기한, 본인만) | `*/OperationAcorn/Upgrades/*.lua`, `scripts/OA_upgrades.txt` |
| P4 임무와 이야기 | 임무(장소 고르기, 아이템 넣기, 지도 원, 기한), 이야기 임무와 데드 드롭, 문서철, 무전 문구, 명세서 비고, 환각, 전용 주파수, 운석 낙하지(정하기, 실물 놓기, 파편), 이관 | `*/OperationAcorn/Story/*.lua`, `scripts/OA_story.txt` |
| P5 아지트 기계 | 분해대, 대량 분해기, 재단기, 프로판·오일 정제기, 목재 절단기, 연구팀 보관함, 대형 빗물 저장소, 설치형 미끼, 기계 부품(달고 떼기, 닳기), 따라잡기 처리, 시료 묶음 | `*/OperationAcorn/Machines/*.lua`, `scripts/OA_machines.txt` |
| P6 장비와 키트 | 연구팀 배낭, 개조 키트 넷, 개량 장비(Mk) | `*/OperationAcorn/Gear/*.lua`, `scripts/OA_gear.txt` (2차) |
| P7 확장 API | pz-tools 쪽 훅 (FEASIBILITY 4장) | pz-tools 저장소 |
| P8 에셋 | 타일 두 장, 아이템 아이콘, 배낭 메시 | `tools/tile_art.py`, `42/media/texturepacks`, `*.tiles`, `textures/` |

### P1이 내놓는 함수 (다른 묶음은 이 이름으로만 부른다)

`info`는 아이템을 표로 옮긴 것이다: `{ fullType, baseType(색 변형을 뺀 이름), weight, displayCategory, moveable, condition(0~1
또는 nil), food(nil 또는 "fresh"|"stale"|"rotten"), cash(달러, 현금이 아니면 nil), bought, cell, mission, own(이 모드 물건
종류 또는 nil), filled(안에 물건이 든 용기면 true) }`. `OA.Value.info(item)`이 게임 아이템에서 만든다.

| 함수 | 반환 |
| --- | --- |
| `OA.Categories.of(info)` | 계열 `"A"`~`"K"` 또는 nil, 받지 않는 이유 |
| `OA.Value.info(item)` | 위 `info` |
| `OA.Value.accepts(info)` | 납품 상자에 넣을 수 있는지, 아니면 이유 키 |
| `OA.Value.context(record)` | 지금 값 매기기에 쓰는 표(계열 시세, 요청 목록, 단계 보상). 하루에 한 번 만들어 둔다 |
| `OA.Value.appraise(info, ctx)` | `{ credits, trust, category, marks = { request, newRegion, high, low, refused } }` (반올림 전) |
| `OA.Value.settle(record, entries)` | 한 편의 정산: `entries`는 밀봉 기록(`{ info, count }` 목록). 시세 하락(`Market.ship`)과 요청 수 차감을 하고 `{ credits(한 번 반올림한 정수), trust, lines, cashTrust }`. 크레딧·신뢰도를 기록에 더하지는 않는다 (P2가 빚 상환과 함께 더한다) |
| `OA.Trust.add(record, amount)` | 신뢰도를 더하고 오른 단계·이정표 목록을 돌려준다 (공용 혈청, 새 품목 알림은 P2가 받아 처리) |
| `OA.Trust.rewards(record)` | 지금 단계의 합계 보상 표: `boxCapacity, callInterval(일), arrival = {min, max}(시간), nightDrop, rate, requestBonus, requestCount, discount, trustAccel, cureInterval, cureCount, delayInterval, delayCount, softerSupply, terminalGraph, marketForecast`, 열린 품목 단계 |
| `OA.Market.index(category)`, `OA.Market.update(day)`, `OA.Market.ship(category, weight, record)`, `OA.Market.refused(category)`, `OA.Market.history(category)` | 시세 |
| `OA.Requests.list(record)`, `OA.Requests.bonusFor(record, fullType)` | 이번 주 요청 |
| `OA.Codex.acquire(record, info)`, `OA.Codex.buildingSearched(record, buildingKey, containers)`, `OA.Codex.kill(record)` | 보너스를 `trade.bonus`에 쌓고, 공용 혈청은 `trade.sharedSerums`에 |
| `OA.Shop.catalog()`, `OA.Shop.price(entry, record)`, `OA.Shop.available(entry, record)`, `OA.Shop.bought(entry, record, count)`, `OA.Shop.serumPrice(tree, record)`, `OA.Shop.kitPrice(kind, target, record)` | 상점 |
| `OA.Shred.yield(info, record, extras)` | 기대 산출 개수(소수), 첫 분해 보너스. 실제 개수는 부른 쪽이 `OA.Shred.roll(expected)`로 굴린다 |

### P2가 내놓는 것

- `OA.Terminal.addTab(id, titleKey, factory, visible)`: 통신 단말 창에 탭을 단다. P4(문서철, 임무)와 P3(연구 계획서 열기)가 쓴다.
- `OA.Trade.radio(record, key, args)`(서버): 무전 기록에 한 줄. P4의 이야기 문구가 이리로 간다.
- `OA.Trade.addToDrop(record, items)`(서버): 다음 보급 상자에 넣을 물건(이야기 문서, 부속 아이템, 공용 혈청).
- 이벤트(서버 쪽 Lua 함수 목록): `OA.Trade.onSealed(fn(record, boxId, entries))`, `OA.Trade.onSettled(fn(record, result))`.
  P4는 밀봉 때 임무 아이템 기한을 판정한다.

### P3, P4, P5가 내놓는 것

- P3: `OA.Upgrades.rank(record, nodeId)`(찍은 단계), `OA.Upgrades.open()`(트리 화면). 눈썰미는 P1의 `extras`와 P4의 파편 굴림이 읽는다.
- P4: `OA.Story.onStage(record, stage)`(P2가 단계가 오르면 부른다), 운석 파편 아이템 `OperationAcorn.MeteorFragment`.
- P5: 시료 묶음 아이템 `OperationAcorn.SampleBundle`, 분해는 P1 `OA.Shred`를 쓴다.

다른 묶음의 함수가 아직 없을 수 있다 (동시에 만든다). 부를 때는 있는지 보고(`if OA.Story and OA.Story.onStage then`), 없으면
건너뛴다. 단위 테스트에서는 테스트 안에 가짜를 둔다.

## 6. 이름 약속

- **아이템:** `module OperationAcorn`, 이름은 파스칼 표기. 묶음마다 자기 스크립트 파일에만 쓴다. 묶음을 넘는 이름:
  `SampleBundle`(P5), `MeteorFragment`(P4), `UpgradeSerumScout`, `UpgradeSerumLoad`, `UpgradeSerumSurvival`,
  `UpgradeSerumShared`, `CureSerum`, `DelayDrug`(P3), `CommTerminal`, `DeliveryBox`, `SupplyCrate`, `TerminalManual`,
  `SupplyManifest`(P2).
- **번역 키:** 묶음마다 접두어. `IGUI_OA_Trade_`, `IGUI_OA_Econ_`, `IGUI_OA_Tree_`, `IGUI_OA_Story_`, `IGUI_OA_Machine_`,
  `IGUI_OA_Gear_`. 우클릭 메뉴는 `ContextMenu_OA_<묶음>_`, 툴팁은 `Tooltip_OA_<묶음>_`. 파일은 게임의 정해진 이름
  (`IG_UI.json`, `ContextMenu.json`, `Tooltip.json`, `ItemName.json`, `Recipes.json`)이고, 합칠 때 키를 모은다.
- **한국어 용어:** 물 저장소(탱크 아님), 강화(특성 아님), 납품 상자, 보급 상자, 통신 단말, 채집점 번호, 연구 승인. 설정집의 이름을 따른다.
- **샌드박스 옵션:** `sandbox-options.txt`의 25개가 전부다. 새 옵션이 필요하면 이 문서와 NUMBERS를 같이 고친다.

## 7. 합치기

- 묶음마다 git 워크트리 하나, 브랜치 `pkg/<묶음>`. 로컬 커밋만 한다 (푸시 없음). `git stash`는 쓰지 않는다 (워크트리끼리 공유된다).
- 번역 JSON은 여러 묶음이 같은 파일에 키를 더한다. 합칠 때 충돌은 키를 모두 모아 푼다.
- 게임 안 확인 스크립트는 `tests/ingame/<묶음>_*.lua`로 남기고, 마지막 통합 확인에서 한 번에 돌린다.

## 8. 타일 속성과 에셋 이름 (P8)

### 타일 속성

타일은 `tools/tile_art.py`가 그린다 (바닐라 타일을 빌리지 않는다). 시트 둘, 한 줄 8칸, 자리는 `Sprites.lua`와 같다.
시트 이름과 tiledef 번호는 이 모드 것이다 (바닐라 최대 460, Building Utilities 5432·5433, 설치된 워크숍 모드의 tiledef 번호와 겹치지 않는 6601·6602).

| 시트 | tiledef (`mod.info`) | 정의 파일 | 텍스처 팩 | 칸 |
| --- | --- | --- | --- | --- |
| `oa_trade_01` | `oa_trade 6601` | `media/oa_trade.tiles` | `texturepacks/OperationAcornTrade.pack` (`pack=OperationAcornTrade`) | 0~15 |
| `oa_machines_01` | `oa_machines 6602` | `media/oa_machines.tiles` | `texturepacks/OperationAcornMachines.pack` (`pack=OperationAcornMachines`) | 0~50 |

`mod.info`(`42/`과 `common/` 둘 다)의 `pack=`, `tiledef=` 줄은 위 표와 같다. 타일 이름은 `<시트>_<번호>` (예: `oa_machines_01_48`).
방향이 있는 것은 남, 동, 북, 서 순서 네 칸이고 타일의 `Facing` 값이 `S`, `E`, `N`, `W`다 (앞면이 보는 쪽).

모든 타일이 공통으로 갖는 값: `CustomName`(영어 이름, 우클릭 메뉴 제목). 번역은 모드 번역 키로 한다.

| 타일 | 속성 |
| --- | --- |
| 통신 단말 0~7 | `BlocksPlacement`, `solidtrans`, `Facing` |
| 납품 상자 8·9 | `container=crate`, `ContainerCapacity=50`, `IsLow`, `BlocksPlacement`, `solidtrans` |
| 보급 상자 10·11 | `container=militarycrate`, `ContainerCapacity=100`, `IsLow`, `BlocksPlacement`, `solidtrans` |
| 낙하산 상자 12 | `BlocksPlacement`, `solidtrans` |
| 그을린 땅 13 | 없음 (바닥에 얹는 그림) |
| 운석 바위 14 | `IsLow`, `BlocksPlacement` (걸어 지나갈 수 있다) |
| 낙하지 말뚝 15 | `IsLow` |
| 분해대·대량 분해기·재단기·프로판 정제기·오일 정제기·목재 절단기 | `BlocksPlacement`, `solidtrans`, `Facing` |
| 연구팀 보관함 44~47 | `container=locker`, `ContainerCapacity=100`, `BlocksPlacement`, `solidtrans`, `Facing` |
| 대형 빗물 저장소 48 | `IsWaterCollector`, `IsLow`, `BlocksPlacement`, `solidtrans` |
| 설치형 미끼 49·50 | `IsLow`, `BlocksPlacement` (걸어 지나갈 수 있다) |

- **`IsMoveAble`은 어느 타일에도 없다.** 바닐라 집기/놓기는 오브젝트를 일반 `Moveable` 아이템으로 바꿔서 이 모드의 `modData`(상자 ID, 기계 상태, 마모)를
  잃는다. 설치와 회수는 각 묶음의 자체 동작이 한다 (Building Utilities와 같은 방식). 그래서 `PickUpWeight`, `PickUpTool`, `CustomItem`도 없다.
  바닐라 우클릭 '옮기기'를 막는 일(BU의 `Moveables.lua`처럼 `ISMoveableSpriteProps.fromObject`에서 `isMoveable=false`)은 이 묶음이 아니라 설치 코드가 한다.
- **컨테이너:** `IsoObject.new(cell, square, sprite)`로 만들면 바닐라가 `container`와 `ContainerCapacity`로 컨테이너를 만든다. 용량은 코드가 `ItemContainer:setCapacity`로 헬기 단계에 맞춰 다시 정한다
  (연구팀 보관함 300은 확장 API가 상한 100을 걷는다). 밀봉된 납품 상자(9)·봉인된 보급 상자(10)는 컨테이너 값을 그대로 두고, 못 열게 하는 일은 코드가 한다.
- **빗물 저장소:** 타일에는 `IsWaterCollector`만 둔다. B42의 비 모으기는 엔티티의 `FluidContainer` 컴포넌트가 한다 (`entity_raincollector.txt`). P5는 스크립트에
  `entity` 하나를 쓴다: `component FluidContainer { ContainerName = Collector, Capacity = 용량, RainFactor = 0.4 }`와
  `component SpriteConfig { face S { layer { row = oa_machines_01_48 } } }`. 바닐라 `waterMaxAmount`/`waterAmount` 타일 속성은 쓰지 않는다.
- **켜짐/꺼짐, 멈춤/도는 중:** 속성이 아니라 그림만 다르다. 상태가 바뀌면 코드가 `Sprites.machine(kind, dir, running)`의 이름으로 `setSprite`를 한다.
- 그을린 땅(13)은 바닥 위의 투명 그림이다. 바닥 타일을 바꾸지 말고 `IsoObject.new(cell, square, "oa_trade_01_13")`로 칸에 얹는다.

타일을 바꾸려면 `python tools/tile_art.py --preview`를 돌린다 (`tools/tile_art_preview_trade.png`, `..._machines.png`에서 모양을 본다). 저장은 시트 자리로 타일을 가리키므로,
쓴 자리는 바꾸지 않고 새 타일은 빈 자리나 새 줄에 넣는다.

### 에셋 이름

**아이템 아이콘:** `Icon = OA_<아이템 이름>` → `media/textures/Item_OA_<아이템 이름>.png` (32×32). 목록은 `tools/icons.txt`가 하나뿐인 원본이다.
아이템 이름이 바뀌면 거기 첫 열을 고치고 `python tools/icon_art.py`를 다시 돌린다 (옛 PNG는 지워진다). 지금 이름:
`CommTerminal`, `DeliveryBox`, `SupplyCrate`, `TerminalManual`, `SupplyManifest`, `SampleBundle`, `MeteorFragment`, `UpgradeSerumScout`, `UpgradeSerumLoad`,
`UpgradeSerumSurvival`, `UpgradeSerumShared`, `CureSerum`, `DelayDrug`, `ShredBench`, `BulkShredder`, `Cutter`, `PropaneRefiner`, `OilRefiner`, `WoodSaw`,
`ResearchStorage`, `RainStorage`, `Lure`, `BagCapacityKit`, `BagWeightKit`, `TrunkKit`, `EngineTuningKit`, `ResearchBackpack`, `FuelCanMk1`~`3`, `WeldingTorchMk1`~`3`,
`MissionItem`, `DocumentItem`. 기계 부품 `Motor`, `ShredderBlade`, `CuttingBlade`, `SawBlade`, `Catalyst`, `SoundproofCover`는 등급을 색으로 구분한 세 그림이 있다:
`<부품>Old`(녹슨 갈색), `<부품>Normal`(강철 회색), `<부품>Modern`(아노다이징 파랑). 등급 접미사 없는 `<부품>`은 보통 등급 그림이다.
강화 혈청은 트리 색(정찰 청록, 하중 호박, 생존 초록, 공용 보라)이다.

**트리 노드 아이콘:** `media/textures/OA_Node_<Slug>.png` (64×64), 한국어 노드 이름과 파일의 대응은 `tools/node_icons.txt`
(`판<TAB>노드 이름<TAB>파일`). 노드 ID가 정해지면 트리 데이터가 이 표의 파일을 가리키게 한다. 2차 연구판은 이름 앞에 `B2`가 붙는다.

**연구팀 배낭** (아이템 스크립트는 P6이 쓴다. 필요한 줄):

```text
ClothingItem = OA_Bag_ResearchPack,
ReplaceInPrimaryHand = OA_Bag_ResearchPack_RHand holdingbagright,
ReplaceInSecondHand = OA_Bag_ResearchPack_LHand holdingbagleft,
WorldStaticModel = OA_ResearchPack_Ground,      (이름을 못 찾으면 OperationAcorn.OA_ResearchPack_Ground)
AttachmentsProvided = WebbingLeft;WebbingRight,
AttachmentReplacement = Bag,
```

| 이름 | 파일 |
| --- | --- |
| 옷 항목 `OA_Bag_ResearchPack`, `_LHand`, `_RHand` | `media/clothing/clothingItems/OA_Bag_ResearchPack*.xml` (GUID는 `media/fileGuidTable.xml`에 등록. 새 옷 XML을 더하는 묶음은 이 표에도 더한다) |
| 멘 모습(남·녀) | `models_X/Skinned/BackPacks/OA_ResearchPack_M.x`, `OA_ResearchPack_F.x` (모든 꼭짓점이 `Bip01_BackPack`에 100%) |
| 손에 든 모습 | `OA_ResearchPack_LHand.x` (`Bip01_Prop2`), `OA_ResearchPack_RHand.x` (`Bip01_Prop1`) |
| 바닥 모델 `OA_ResearchPack_Ground` | `models_X/WorldItems/Clothing/OA_ResearchPack_Ground.fbx`, 정의는 `scripts/OA_backpack_models.txt` |
| 텍스처 | `textures/Clothes/Bag/OA_ResearchPack.png` (256×256) |

수통 걸이 자리(`WebbingLeft/Right`)는 캐릭터의 `ISHotbarAttachDefinition`이 정하므로 배낭 모델의 양옆 웨빙 띠는 모양일 뿐이다. 생성기는 `python tools/backpack_mesh.py`
(`--check`는 다시 읽어 검사만, 게임 폴더는 환경 변수 `PZ_DIR`).
