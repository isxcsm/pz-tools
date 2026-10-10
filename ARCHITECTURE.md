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
  `SandboxVars`(sandbox-options.txt의 기본값), `ModData`, `getGameTime`, `ZombRand`, `Events`, `getText`, `getTimestampMs`(부를 때마다 한 시간씩 가서
  간격 제한이 막지 않는다. 제한을 시험할 때는 테스트가 바꾼다)를 흉내 낸다.
  테스트 하나마다 모드와 저장이 새로 시작한다. 게임 객체가 필요한 부분은 얇은 어댑터 함수로 떼어 내고 로직에는 표만 넘긴다.
- **Kahlua 주의:** `%`는 음수와 큰 수(`getTimestampMs`)에서 틀린다 (`OA.remainder`). 정수 나눗셈 연산자, `goto`, 비트 연산이
  없다. `string.format("%d")`에 소수를 넘기지 않는다.

## 3. 공용 기반 (이미 있음)

| 파일 | 하는 일 |
| --- | --- |
| `shared/OperationAcorn/Core.lua` | `OperationAcorn`(=`OA`) 이름공간, `OA.log`, `OA.api()`/`OA.handle()`(확장 API), `OA.option(name)`(샌드박스), `OA.hours()`(세계 나이, 시간), `OA.day()`(00시에 바뀌는 날 번호), `OA.week()`, `OA.random(a, b)`(둘 다 포함), `OA.randomFloat`, `OA.round`, `OA.clamp`, `OA.remainder`, `OA.due(last, key, now, ms)`(실제 시간 간격 제한) |
| `shared/OperationAcorn/Store.lua` | 저장 데이터. 전역 ModData `OA_World` 하나에 모두 둔다. `Store.world(section)`, `Store.player(id)`, `Store.section(record, section)`, `Store.players()`, `Store.ensure(id, name)`(기록과 네 자리 채집점 번호를 만든다), `Store.idOf(character)`(캐릭터 modData `OA_Id`) |
| `shared/OperationAcorn/Sync.lua` | 바뀐 것 알리기. `Sync.changed(what, playerId, detail)`, `Sync.notice(playerId, key, args)`, `Sync.title(playerId, detail)`(사건의 제목: 확장 API의 큰 글씨, 없으면 캐릭터 위 글. `client/OperationAcorn/Titles.lua`가 보인다. 인자는 `{ key, args }`이면 플레이어 쪽에서 번역한다), `Sync.send(character, command, args)`(클라이언트 → 서버, `args.id`를 붙인다), `Sync.listen(what, fn)`(클라이언트 쪽) |
| `shared/OperationAcorn/Chunks.lua` | 칸이 불러질 때 할 일의 대기 표 (`LoadChunk`, 청크 키). `Chunks.handle(kind, fn)`, `Chunks.add(entry)`, `Chunks.remove(predicate)`, `Chunks.list(kind)`. `LoadGridsquare`는 쓰지 않는다 |
| `shared/OperationAcorn/Sprites.lua` | 이 모드 타일 이름 (`Sprites.terminal(dir, on)`, `Sprites.machineTiles(kind, dir, running)`, `Sprites.footprint(kind, dir)` ...). 시트 자리는 바꾸지 않는다 |
| `server/OperationAcorn/Server.lua` | 클라이언트 명령 받기: `OA.Server.on(name, function(character, record, args) ... end)`. `LoadChunk`를 `Chunks`에 잇는다 |
| `client/OperationAcorn/Client.lua` | 서버가 보낸 것을 `Sync` 듣는 쪽으로. `OA.Client.record(character)`(이 클라이언트가 보는 내 기록), 첫 접속 때 `hello` |

- **변경은 서버에서만 한다.** 화면은 `OA.Sync.send`로 서버에 부탁하고, 서버 핸들러가 기록을 고친 뒤 `OA.Sync.changed`를 부른다.
  혼자 할 때는 같은 과정이 즉시 돈다. 멀티플레이는 검증하지 않지만 막지도 않는다 (이 구조만 지킨다).
- **기록은 캐릭터마다 하나다.** 연구팀은 그 생존자와 거래한다. 캐릭터가 죽고 새로 시작하면 새 채집점 번호와 새 기록이다.
  강화, 신뢰도, 크레딧 모두 새로 시작한다. 이전 캐릭터의 상자와 기록은 세계에 남는다.
- **매 틱·매 프레임 처리 금지** (DESIGN 12장 성능 규칙). 시각 비교는 `EveryTenMinutes`, 날 바뀜은 `EveryDays`, 칸 일은 `Chunks`.
  게임 시간 이벤트는 빨리 감기(x40)나 잠잘 때 실제 1초에 여러 번 온다. 게임 시간을 따르지 않는 일(세계 훑기, 인벤토리 훑기, 표시 갱신)은
  `OA.due`로 실제 시간 간격(모듈 상수 `..._MS`, 기본 속도에서 게임 10분이 걸리는 실제 25초보다 짧게)을 두고, 게임 시간을 따르는 일은 부른 횟수가 아니라
  지난 게임 시간(`OA.hours()`의 차)으로 센다.
- **지켜보는 기계는 바로 일한다.** 기계는 `EveryTenMinutes`마다 지난 시간만큼 일하지만, 루팅 창이 기계 컨테이너를 그리는 동안(`Machines/Watch.lua`,
  `ISInventoryPane:renderdetails` 감싸기) 첫 대상 줄에 바닐라 작업 막대(`setJobType`/`setJobDelta`, 그리는 동안만)를 보이고, 그 막대가 차거나
  새 물건이 들어오면 `machineWork` 명령으로 그 자리에서 일하게 한다 (`OA.due`로 읽기 100ms, 부탁 400ms 간격). 일한 양은 어느 쪽이든 지난 게임
  시간이라 지켜봐도 더 만들지 않는다. 소리는 10분에 한 번만 낸다 (`Machines.NOISE_EVERY`). 켜기/끄기 버튼은 오븐처럼 루팅 창 아래 버튼 줄에 있다
  (`Machines/LootControls.lua`, `ISLootWindowContainerControls.AddHandler`; 기계 창에는 없다). 필요한 부품이 없거나 망가졌으면 켤 수 없고
  (`Machines.canSwitchOn`, 버튼은 꺼지고 이유를 툴팁으로), 부품을 분리하면 먼저 꺼진다. 일하지 않는 이유(꺼짐, 전기 없음, 산출함 가득 등)는
  투입함 첫 줄의 작업 이름 자리에 보인다 (`Machines.stopText`).

## 4. 저장 데이터와 주인

플레이어 기록(`Store.player(id)`)의 섹션:

| 섹션 | 주인 | 내용 |
| --- | --- | --- |
| `trade` | 거래(P2), 경제(P1)가 함께 쓴다 | `credits`(정수, 빚이면 음수), `trust`(소수까지), `stage`(0~5), `milestones`(지난 이정표 수), `bonus`(다음 정산 때 들어올 보너스 크레딧), `sharedSerums`(다음 보급에 실을 공용 혈청 수), `serial`(마지막 보급 명세서 번호), `lastSettle`(마지막 정산 요약 `{ at, credits, trust, boxes }`), `levels`·`pendingLevels`(운항 지원 개량의 받은 단계와 신청한 단계, 개량 id별), `levelsRev`(단계가 바뀔 때마다 오르는 수, 보상 캐시용). P1의 `Trust.add`, `Codex` 함수가 이 칸을 고친다. 나머지 칸은 P2 |
| `codex` | P1 | 도감, 털이, 처치 기록 |
| `shop` | P1 | 품목별 구매 시각, 주간 구매 수, 키트 대상별 사용 수 |
| `shred` | P1 | 종류별 최근 분해 수(날마다 ×0.9), 처음 분해한 종류 |
| `boxes`, `heli`, `orders` | P2 | 상자, 헬기(`line`: 정식 회선이 열림), 주문 |
| `upgrades` | P3 | 트리 점, 노드, 캡스톤, 2차 판, 산 혈청 수 |
| `missions`, `story` | P4 | 임무, 이야기 진행, 문서철 (교신 사본은 진행 칸에서 계산) |

기록의 `upgrades`는 옛 판의 세이브를 고친 단계 이름 목록이다. 각 부분이 `Store.addUpgrade(name, fn)`로 단계를 더하고, 서버가 시작할 때 `Store.upgradeAll()`이 기록마다 한 번씩 돌린다. 새 기록은 모든 단계를 한 것으로 시작한다.

세계 섹션(`Store.world(name)`): `market`, `requests`(P1), `sites`(P4, 운석 낙하지), `machines`(P5), `pending`(Chunks).

아이템과 오브젝트 modData 키는 모두 `OA_`로 시작한다: `OA_Bought`(상점에서 산 물건, 납품 거부), `OA_Cell`(나온 셀,
새 지역 웃돈), `OA_Mission`(임무 ID), `OA_Box`(상자 ID), `OA_Issued`(혈청 발급 시각), `OA_Owner`(발급받은 기록 ID).
개조 키트(P6)의 키: 키트 아이템 `OA_Target`(주문한 대상 하나: 가방은 아이템 ID, 차는 아래 `OA_TargetId`, 빈 문자열은 아무 데나), `OA_Voucher`(교환권으로 받음).
차의 `OA_TargetId`: 처음 대상으로 고를 때 엔진·트렁크 부품 modData에 쓴다 (차 자체의 modData는 저장되지 않고, 다른 ID는 유일하지 않거나 저장되지 않는다). 클라이언트가 만들면 `gear.tag`로 서버에 알린다. 토치 아이콘(`WeldingTorchMk`)은 아이템 없이 디스크에만 남아 있다.
가방 아이템 `OA_KitCap`, `OA_KitWeight`, `OA_KitBaseCap`, `OA_KitBaseRed`, `OA_KitRaw`; 트렁크 부품(`TruckBed`, `TruckBedOpen`) `OA_KitTrunk`, `OA_KitBase`,
`OA_KitRaw`; 엔진 부품 `OA_KitEngine`, `OA_KitPower`, `OA_KitLoud`. 확장 API가 읽는 `OA_Capacity`는 키트가 쓸 때 숫자다 (원래 용량에 더할 양).

## 5. 작업 묶음

| 묶음 | 맡는 것 | 파일 |
| --- | --- | --- |
| P1 경제 | 계열, 값 매기기, 시세, 요청 품목, 신뢰도와 단계 보상, 도감·털이·처치 보너스, 상점 목록과 한도와 가격, 분해 산출. 순수 로직 + 단위 테스트, 게임 어댑터는 얇게 | `shared/OperationAcorn/Economy/*.lua` |
| P2 거래 | 통신 단말(설치물, 전기, 창과 탭), 납품 상자(설치, 허용 규칙, 밀봉, 파괴, 재발급과 빚), 헬기(호출, 도착, 정산, 보급 상자, 영수증, 명세서), 첫 보급, 한꺼번에 담기, 감정가 툴팁과 견적 창, 새 지역 표시, 주문과 결제 | `*/OperationAcorn/Trade/*.lua`, `scripts/OA_trade.txt` |
| P3 강화와 몸 | 트리 셋과 2차 판의 데이터, 점과 혈청, 연구 승인, 캡스톤, 초기화, 트리 화면, Lua로 되는 노드 효과, API 노드의 선언(API가 있을 때만), 치료 혈청·지연제(유통 기한, 본인만) | `*/OperationAcorn/Upgrades/*.lua`, `scripts/OA_upgrades.txt` |
| P4 임무와 이야기 | 임무(장소 고르기, 아이템 넣기, 지도 원, 기한), 이야기 임무와 데드 드롭, 문서철, 무전 문구, 명세서 비고, 환각, 전용 주파수, 운석 낙하지(정하기, 실물 놓기, 파편), 이관 | `*/OperationAcorn/Story/*.lua`, `scripts/OA_story.txt` |
| P5 아지트 기계 | 분해대, 대량 분해기, 재단기, 프로판·오일 정제기, 목재 절단기, 연구팀 보관함, 대형 빗물 저장소, 설치형 미끼, 기계 부품(달고 떼기, 닳기), 따라잡기 처리, 시료 묶음 | `*/OperationAcorn/Machines/*.lua`, `scripts/OA_machines.txt` |
| P6 장비와 키트 | 연구팀 배낭, 개조 키트 넷(타이밍 액션으로 달기, 교환권), 개량 장비(Mk) | `*/OperationAcorn/Gear/*.lua`, `scripts/OA_gear.txt` |
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
| `OA.Trust.rewards(record)` | 지금 값의 표: 운항 지원 개량 단계에서 오는 `boxCapacity, callInterval(일), arrival = {min, max}(시간), nightDrop, rate, requestCount, requestPrice, discount, softerSupply, marketForecast`와 신뢰도로 오는 `trustAccel, requestBonus, backpack, kits, transferred`. 단계·이정표·`levelsRev`가 바뀌면 다시 만든다 |
| `OA.Support.step(id, n)`, `OA.Support.request(record, id, level, field)`, `OA.Support.cancel(record, id)`, `OA.Support.settle(record, balance)` | 운항 지원 개량 (DESIGN-terminal 2.6): 단계표, 신청(정식 단말, 바로 다음 단계, 신뢰도 단계, 빚 없음), 다음 정산 때 결제와 반영. 잔고가 모자란 신청은 다음 정산까지 기다린다 |
| `OA.Market.index(category)`, `OA.Market.update(day)`, `OA.Market.ship(category, weight, record)`, `OA.Market.refused(category)`, `OA.Market.history(category)` | 시세 |
| `OA.Requests.list(record)`, `OA.Requests.bonusFor(record, fullType)` | 이번 주 요청 |
| `OA.Codex.acquire(record, info)`, `OA.Codex.buildingSearched(record, buildingKey, containers)`, `OA.Codex.kill(record)` | 보너스를 `trade.bonus`에 쌓고, 공용 혈청은 `trade.sharedSerums`에 |
| `OA.Shop.catalog()`, `OA.Shop.price(entry, record)`, `OA.Shop.available(entry, record)`, `OA.Shop.bought(entry, record, count)`, `OA.Shop.serumPrice(tree, record)`, `OA.Shop.kitPrice(kind, target, record)` | 상점 |
| `OA.Shred.yield(info, record, extras)` | 기대 산출 개수(소수), 첫 분해 보너스. 실제 개수는 부른 쪽이 `OA.Shred.roll(expected)`로 굴린다 |

### P2가 내놓는 것

- `OA.Terminal.addTab(id, titleKey, factory, visible)`: 통신 단말 창에 탭을 단다. P4(문서철, 임무)가 쓴다.
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
| `oa_machines_01` | `oa_machines 6602` | `media/oa_machines.tiles` | `texturepacks/OperationAcornMachines.pack` (`pack=OperationAcornMachines`) | 0~157 (20줄) |

`mod.info`(`42/`과 `common/` 둘 다)의 `pack=`, `tiledef=` 줄은 위 표와 같다. 타일 이름은 `<시트>_<번호>` (예: `oa_machines_01_128`).
방향이 있는 것은 남, 동, 북, 서 순서이고 타일의 `Facing` 값이 `S`, `E`, `N`, `W`다 (앞면이 보는 쪽).

### 큰 기계는 여러 칸이다

큰 기계는 한 물체로 통째 그려서 발자국(footprint)의 칸마다 잘라 담는다 (이음매가 없다. 위로 높이 솟은 부분은 그 칸 그림 위로 겹쳐 올라간다).
남쪽 보기 기준 발자국은 x쪽 w칸 × y쪽 h칸이고, 동·서쪽 보기는 w와 h가 바뀐다.

| 종류 (`kind`) | 발자국 (w×h, 남쪽) | 보기 | 첫 칸 | 칸 수 |
| --- | --- | --- | --- | --- |
| `shredBench` | 2×1 | 멈춤만 | 0 | 8 |
| `bulkShredder` | 2×1 | 멈춤, 도는 중, 대기(160~) | 8 | 16 + 8 |
| `cutter` | 2×1 | 멈춤, 도는 중, 대기(168~) | 24 | 16 + 8 |
| `woodSaw` | 2×1 | 멈춤, 도는 중, 대기(176~) | 40 | 16 + 8 |
| `researchStorage` | 2×1 | 멈춤만 | 56 | 8 |
| `propaneRefiner` | 2×2 | 멈춤, 도는 중, 대기(184~) | 64 | 32 + 16 |
| `oilRefiner` | 2×2 | 멈춤, 도는 중, 대기(200~) | 96 | 32 + 16 |
| `rainStorage` | 2×2 | 돌지 않음. 물체는 빈 통(134~137). 가득 찬 통 그림 128~131(아이콘용), 물 높이 1~3은 덧그림 146~157 | 134 (+128, +146) | 4 + 4 + 12 |
| 미끼 (켜짐, 꺼짐) | 1×1 | 돌지 않음 | 132, 133 | 2 |

한 기계의 자리: 상태(멈춤, 도는 중) → 방향(S, E, N, W) → 그 방향 발자국의 칸을 y 바깥, x 안쪽 순서. 곧 `첫 칸 + (상태 × 방향수 + 방향) × w×h + dy × w + dx`
(방향수는 4). 대기 모습(켜져서 기다림: 등만 켜지고 움직이는 것은 없다)은 오버레이 뒤 160부터 기계마다 `대기 첫 칸 + 방향 × w×h + dy × w + dx`에 있다 (`GroupName=OA_<kind>Ready`). 빗물 저장소만 이 식을 따르지 않고 위 표의 자리에 있다 (네 칸의 순서는 앵커 `0,0`, `1,0`, `0,1`, `1,1`; 138~145는 쓰지 않는 빈 자리). 코드는 이 계산을 하지 말고 `Sprites.machineTiles`, `Sprites.rainStorageTiles`, `Sprites.rainOverlayTiles`를 쓴다. 1×1 물체(통신 단말, 납품 상자, 보급 상자, 낙하산 상자, 미끼, 낙하지 소품)는 그대로 한 칸이다.

**칸마다의 속성:** 기계의 모든 칸이 `CustomName`, `GroupName`(기계마다 하나, `OA_<kind>`), `SpriteGridPos`(`gx,gy`, 그 방향 발자국 안의 자리), `BlocksPlacement`, `solidtrans`,
`Facing`(돌지 않는 빗물 저장소는 `S`)을 갖는다. 연구팀 보관함의 컨테이너는 모든 칸에, **`IsWaterCollector`(빗물 저장소)는 앵커 칸에만 있다.** 앵커 = 발자국의 최소 x, 최소 y 칸이고 `SpriteGridPos=0,0`이다.
바닐라 여러 칸 가구와 같은 약속이다 (`newtiledefinitions`의 `SpriteGridPos`와 `GroupName`, 엔티티 스크립트 `SpriteConfig`의 `face X { layer { row = ... } }`; 피아노 `entity_piano.txt`가 예).

모든 타일이 공통으로 갖는 값: `CustomName`(영어 이름, 우클릭 메뉴 제목). 번역은 모드 번역 키로 한다.

| 타일 | 속성 |
| --- | --- |
| 통신 단말 0~7(개량), 16~23(조립) | `BlocksPlacement`, `solidtrans`, `Facing` |
| 납품 상자 8·9 | `container=crate`, `ContainerCapacity=50`, `IsLow`, `BlocksPlacement`, `solidtrans` |
| 보급 상자 10·11 | `container=militarycrate`, `ContainerCapacity=100`, `IsLow`, `BlocksPlacement`, `solidtrans` |
| 낙하산 상자 12 | `BlocksPlacement`, `solidtrans` |
| 그을린 땅 13 | 없음 (바닥에 얹는 그림) |
| 운석 바위 14 | `IsLow`, `BlocksPlacement` (걸어 지나갈 수 있다) |
| 낙하지 말뚝 15 | `IsLow` |
| 분해대·대량 분해기·재단기·프로판 정제기·오일 정제기·목재 절단기의 모든 칸 | `BlocksPlacement`, `solidtrans`, `Facing`, `GroupName`, `SpriteGridPos`, `IsMoveAble`, `PickUpWeight` (도는 중인 모습은 `GroupName=OA_<종류>On`) |
| 연구팀 보관함의 모든 칸 | 위와 같음. 칸마다 `container=locker`, `ContainerCapacity=100` 더 (칸마다 보관함 하나, 용량은 코드가 500으로) |
| 대형 빗물 저장소 빈 통 134~137 | 모든 칸 `IsLow`, `BlocksPlacement`, `solidtrans`, `GroupName`, `SpriteGridPos`, `Facing=S`, `IsMoveAble`, `PickUpWeight`. 앵커 칸(134)에만 `IsWaterCollector` |
| 대형 빗물 저장소 가득 찬 통 128~131 (아이템 아이콘 그림) | `IsLow`, `BlocksPlacement`, `solidtrans`, `GroupName`. 앵커 칸(128)에만 `IsWaterCollector`. `SpriteGridPos`가 없다: 같은 이름에 칸 위치가 겹치면 게임이 빈 통의 격자를 만들지 않는다 |
| 빗물 저장소 덧그림 146~157 (물 높이 1, 2, 3 각각 네 칸) | 없음 (`BlocksPlacement`, `solidtrans`, `IsWaterCollector` 모두 없는 꾸밈 그림) |
| 설치형 미끼 132(켜짐)·133(꺼짐) | `IsLow`, `BlocksPlacement` (걸어 지나갈 수 있다) |

- **기계는 바닐라 가구다 (`IsMoveAble`, 미끼 제외).** 게임이 불러올 때 이름(`GroupName`+`CustomName`), `Facing`, `SpriteGridPos`로 칸 격자와
  방향별 오프셋을 만든다 (격자는 방향이 있는 타일에만 만든다: 빗물 저장소에 `Facing=S`). 그래서 가구 도구가 기계를 칸마다 조각 하나("이름 (1/2)", 무게는
  `PickUpWeight`/10 = 기계 무게를 칸 수로 나눈 것)로 그 칸 바닥에 떼어 놓고, 인벤토리나 근처 바닥(3칸)의 조각을 모아 통째로 놓으며 드래그로 돌린다.
  `Machines/Moveables.lua`가 바닐라에 없는 것만 더한다: 부품이 끼워져 있거나 안에 뭐가 있으면 떼어내기를 막고 도구 창에 이유를 쓴다 (부품은 내용물처럼
  먼저 뺀다), 떼어 내면 등록을 지우고 조각에 기계 상태를 남기지 않는다, 놓을 때 `Machines.canPlace` 규칙을 지키고 바닐라가 놓은 일반 오브젝트를
  `Machines.place(..., bare)`(부품 없음)로 바꾼다. 상점에서 산 기계는 조각과 새 기계의 낡은 부품으로 배달된다 (`Machines.deliveryItems`).
  보존할 상태가 부품뿐이고 부품은 아이템으로 빠지므로, 조각에는 실을 것이 없다.
- **거래 물건(단말·상자)에는 `IsMoveAble`이 없다.** 납품 상자의 ID와 주인을 아이템에 실어야 해서 `Trade/Moveables.lua`가 가구 도구의 확인과 떼어내기를
  이 모드의 것(`Things.take*`)으로 바꾼다. 바닐라의 한 칸 가구 규칙대로 인벤토리에 들어갈 자리가 있어야 하고, 놓기는 이 모드의 커서가 한다.
- **기계 컨테이너의 칸:** 그림이 보여 주는 칸에 있다 (`Data.KINDS[kind].containerAt`, 남쪽 보기 기준 칸을 `Sprites.turnSquare`로 돌린다). 대량 분해기·재단기·목재 절단기의 산출함은 통·수레·판재 쪽 칸, 투입함은 다른 칸이다. 연구팀 보관함은 칸마다 보관함이 있다 (`everyTile`). `Machines.container(앵커, 역할)`이 그 칸의 것을 찾아 준다 (찾은 칸은 기억한다). 정제기는 앵커 칸에 투입함(재료)과 통 보관함(`tank`, 채울 프로판 통이나 휘발유 통)을 함께 둔다. 예전 세이브의 정제기는 청크가 불러질 때 빠진 컨테이너를 받는다 (`Machines.addMissingContainers`).
- **여러 칸 기계는 루팅 창에서 한 물건이다 (`Machines/LootReach.lua`).** 기계의 어느 칸 옆에 서도 그 기계의 컨테이너가 모두 목록에 오른다 (게임은 플레이어 주변 칸의 컨테이너만 올린다; `OnRefreshInventoryWindowContainers`의 `beforeFloor`에서 더한다). 기계의 컨테이너를 고르면 컨테이너가 없는 칸도 함께 강조된다 (`updateContainerHighlight` 뒤, 고른 컨테이너가 바뀔 때만).
- **컨테이너:** `IsoObject.new(cell, square, sprite)`로 만들면 바닐라가 `container`와 `ContainerCapacity`로 컨테이너를 만든다. 용량은 코드가 `ItemContainer:setCapacity`로 헬기 단계에 맞춰 다시 정한다
  (연구팀 보관함 300은 확장 API가 상한 100을 걷는다). 밀봉된 납품 상자(9)·봉인된 보급 상자(10)에는 컨테이너 속성이 없다 (있으면 게임이 불러올 때 컨테이너를 다시 만들어, 봉인된 상자가 루팅 창에 바닐라 '군용 보관함'으로 열렸다). 여는 코드가 컨테이너를 만든다.
- **빗물 저장소 (2×2, 열린 통):** 물 높이가 그림에 보인다 (0 빈 통: 마른 바닥에 흙과 낙엽, 1 사분의 일, 2 절반, 3 가득; 통 옆 수위 유리관에도 같은 높이). **놓는 물체와 엔티티의 `SpriteConfig`는 빈 통(134~137)이다. 물체의 스프라이트를 바꾸면 안 된다** (B42 `SpriteConfig`가 물체의 현재 스프라이트 이름을 엔티티 설정에서 찾아 없으면 컴포넌트를 무효로 표시한다). 물 높이는 덧그림이다: 높이 1~3이면 네 칸 각각에 `IsoObject.setOverlaySprite(Sprites.rainOverlayTiles(level)의 그 칸 이름)`, 높이 0이면 `setOverlaySprite(nil)`. 덧그림은 오브젝트와 함께 저장된다. 덧그림 타일은 빈 통과 달라지는 픽셀만 갖고 나머지는 투명이다. 빈 통 위에 덧그림을 알파 합성하면 그 높이의 완성 타일과 픽셀까지 같다 (`tile_art.py`가 열두 장 모두 단언한다). 앵커 타일(134)에만 `IsWaterCollector`를 둔다. B42의 비 모으기는 엔티티의 `FluidContainer` 컴포넌트가 한다 (`entity_raincollector.txt`). P5는 스크립트에
  `entity` 하나를 쓴다: `component FluidContainer { ContainerName = Collector, Capacity = 용량, RainFactor = 0.4 }`와
  `component SpriteConfig { face S { layer { row = oa_machines_01_134 oa_machines_01_135, row = oa_machines_01_136 oa_machines_01_137 } } }`
  (한 줄이 y 한 칸, 줄 안은 x 순서. 돌지 않으니 face S 하나). `Sprites.rainStorageTiles()`가 같은 네 칸을 준다. 바닐라 `waterMaxAmount`/`waterAmount` 타일 속성은 쓰지 않는다.
- **꺼짐 / 대기 / 도는 중:** 속성이 아니라 그림만 다르다. 꺼졌거나 전기가 없으면 멈춤(빨간 등), 켜져 있고 일감을 기다리면 대기(초록 등, 대량 분해기는 경광등도), 일하면 도는 중이다 (`Machines.refreshLook`). 상태가 바뀌면 코드가 `Sprites.machineTiles(kind, dir, running)`의 칸마다 그 칸 오브젝트에 `setSpriteFromName`을 한다 (칸 하나만 바꾸면 기계가 찢어진다. 이름 문자열을 받는 `setSprite`는 이름도 속성도 없는 맨 그림을 만든다).
  돌아가는 모습이 없는 기계는 `running`을 무시한다.
- 그을린 땅(13)은 바닥 위의 투명 그림이다. 바닥 타일을 바꾸지 말고 `IsoObject.new(cell, square, "oa_trade_01_13")`로 칸에 얹는다.

타일을 바꾸려면 `python tools/tile_art.py --preview`를 돌린다 (`tools/tile_art_preview_trade.png`; `..._machines.png`는 기계마다 서 있는 모습 그대로 이어 붙인 것, `..._machines_tiles.png`는 낱칸). 저장은 시트 자리로 타일을 가리키므로,
쓴 자리는 바꾸지 않고 새 타일은 빈 자리나 새 줄에 넣는다.

### 코드가 쓰는 이름: `OperationAcorn/Sprites.lua`

- `Sprites.FOOTPRINT[kind] = { w =, h = }` 남쪽 보기 발자국 (큰 기계 여덟 종류와 1×1 물체). `Sprites.footprint(kind, dir)` → `w, h` (동·서는 바뀐다; 모르는 kind는 nil).
- `Sprites.machineTiles(kind, dir, running)` → `{ { dx =, dy =, sprite = }, ... }` 발자국의 칸마다 하나. `dx`, `dy`는 앵커(최소 x, 최소 y)에서 0 이상. `dx=0, dy=0` 항목이 앵커다.
  `kind`는 `Sprites.MACHINE_KINDS`의 일곱 이름과 `rainStorage`. 모르는 kind는 nil.
- `Sprites.rainStorageTiles()` 같은 모양, 돌지 않는다: 빈 통의 네 칸 (물체의 스프라이트). `Sprites.machineTiles("rainStorage", ...)`도 같다. `Sprites.rainOverlayTiles(level)`은 물 높이 1~3(3보다 크면 3)의 덧그림 네 칸 `{ dx, dy, sprite }`, 0 이하(`nil` 포함)는 빈 목록. `Sprites.RAIN_LEVELS = 4`. 미끼는 한 칸이라 `Sprites.lure(on)`이 이름 하나를 준다 (켜짐 `oa_machines_01_132`, 꺼짐 `_133`). 켜진 미끼의 소리 고리는 타일이 아니라 기계 팩에 함께 든 그림 `oa_lurefx_01_0`~`_5`(`tools/tile_art.py` `lure_fx_frames`)를 오브젝트에 붙인 반복 애니메이션이다 (`Machines.lureFx`, `Data.LURE_FX`). 게임은 보통 오브젝트에 붙인 그림의 프레임을 넘기지 않으므로, 확장 API의 `anim.stepKey`(`Machines.declareAnim`, 클라이언트 `OnGameStart`)에 `Data.ANIM_KEY`(`OA_Anim`)를 알리고 켜진 미끼의 modData에 그 키를 1로 둔다. API가 그려지는 미끼만 프레임마다 `IsoSprite.update`로 넘기고, API가 없으면 고리는 멈춘 채 보인다. 붙인 그림은 저장되더라도 타일 번호가 없어 불러올 때 버려지므로 `Machines.onChunk`가 다시 붙인다.
- 무역 시트 함수 (`terminal`, `deliveryBox`, `supplyCrate`, `PARACHUTE_CRATE`, `SCORCHED_GROUND`, `METEOR_ROCKS`, `SITE_STAKE`)는 그대로다. 옛 `Sprites.machine`과 `Sprites.RAIN_STORAGE`는 없다.
- 시험: `tests/unit/sprites_test.lua` (발자국, 동서 바뀜, 칸당 하나, 모든 이름이 `.tiles`에 있고 속성이 맞는지).

### 에셋 이름

**아이템 아이콘:** `Icon = OA_<아이템 이름>` → `media/textures/Item_OA_<아이템 이름>.png` (32×32). 목록은 `tools/icons.txt`가 하나뿐인 원본이다.
아이템 이름과 아이콘 이름이 달라도 된다 (기계 아이템은 `Icon = OA_Cutter`처럼 아이콘 이름을 직접 적는다: FabricCutter→`Cutter`, PropaneRefinery→`PropaneRefiner`, OilRefinery→`OilRefiner`, LogSaw→`WoodSaw`, TeamLocker→`ResearchStorage`, RainCistern→`RainStorage`, BaitTrap→`Lure`). 모든 `scripts/OA_*.txt`의 `Icon=`이 PNG로 풀리는지는 시험 때 확인한다. 아이콘 이름이 바뀌면 거기 첫 열을 고치고 `python tools/icon_art.py`를 다시 돌린다 (옛 PNG는 지워진다). 지금 이름:
`CommTerminal`, `DeliveryBox`, `SupplyCrate`, `TerminalManual`, `SupplyManifest`, `SampleBundle`, `MeteorFragment`, `UpgradeSerumScout`, `UpgradeSerumLoad`,
`UpgradeSerumSurvival`, `UpgradeSerumShared`, `CureSerum`, `DelayDrug`, `ShredBench`, `BulkShredder`, `Cutter`, `PropaneRefiner`, `OilRefiner`, `WoodSaw`,
`ResearchStorage`, `RainStorage`, `Lure`, `BagCapacityKit`, `BagWeightKit`, `TrunkKit`, `EngineTuningKit`, `ResearchBackpack`, `FuelCanMk1`~`3`, `WeldingTorchMk1`~`3`,
`MissionItem`, `DocumentItem`, 이야기 묶음의 서른 가지 `MissionEnvelope`, `MissionSampleTin`, `MissionLogbook`, `MissionFilterCase`, `MissionTape`, `MissionFabricRoll`, `EvidenceEnvelope`, `ClinicRecord`, `WeatherLog`, `FarmJournal`, `SampleCooler`, `RosterPage`, `ReviewMemo`, `WardRecord`, `CellLog`, `SoilSample`, `StakeTag`, `RosterLostPage`, `FilterBundle`, `PharmacyLedger`, `CopyOriginal`, `SampleCase`, `DeadDropCase`, `FieldCallDevice`, `AnalysisReply`, `Appendix`, `SerumSheet`, `UnresolvedList`, `HandoverFile`, `KitVoucher` (`tools/icon_story.py`). 기계 부품 `Motor`, `ShredderBlade`, `CuttingBlade`, `SawBlade`, `Catalyst`, `SoundproofCover`는 등급을 색으로 구분한 세 그림이 있다:
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
