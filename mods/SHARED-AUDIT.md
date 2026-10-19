# 공용화 전수 감사 — 수정 목록 (2026-10-20)

OA(도토리 작전), BU(건물 설비), PZUIKit, PZExtAPI를 함께 읽고 같은 일을 따로 하거나 서로 다르게 하는 곳을 모았다.
각 항목의 형식:
- 지금 어떻게 되어 있는가
- 그래서 생기는 문제
- 공용 자리
- 우선순위

**공용 자리를 정하는 원칙**
- **API(Java):** 게임 메커니즘만 맡고, 모드 콘텐츠는 들고 있지 않는다.
  - 예: 칸 조건, 조명 유지, 모드 연결.
- **PZUIKit(Lua):** 표현과 Lua 수준의 공용 조각을 맡는다.
  - 예: UI, 소리, 타이틀 앞단, 동작 베이스, 가구 도구 훅.
  - 이미 Heavy, Furniture 같은 비 UI 조각을 들고 있다. 이름은 그대로 둔다(바꾸면 의존 선언만 늘어난다).

**우선순위**
- **A:** 지금 버그이거나, 유저 눈에 보이는 불일치.
- **B:** 같은 코드가 두세 벌이라 한쪽만 고쳐질 위험.
- **C:** 정리 차원.

---

## 1. 클릭과 UI 조작

### 1-1. 클릭 소리 경로가 둘이다 — A
- **지금:** 소리 내는 길이 두 갈래다.
  - `Sound.ui`를 직접 부르는 곳: TabShop, Upgrades/Window, Combo, PopMenu, TypedText.
  - `UI.flash`/`placeFlash`에 붙은 소리로 내는 곳: 이번에 연결함.
- **소리가 아예 없는 직접 그린 컨트롤:**
  - OA: StatusDraw 일부, TabStatus 부팅 "ok", TerminalBoot, Machines/Window(OAMachineBody, OAMachinePicker), TabDelivery.
  - BU: ISBUTabs, PanelPlan 토글, PanelManual 장 목록.
- **문제:** 새 컨트롤을 만들 때마다 어느 길로 갈지 갈린다. 이번 하위탭 무음도 이렇게 생겼다.
- **수정:**
  - kit에 `UI.click(el, key, cue)`를 클릭의 유일한 입구로 둔다(빛남 + 소리).
  - flash는 빛남만 맡는다.
  - 위 무음 컨트롤을 모두 `UI.click`으로 옮긴다.
  - 단위 테스트에 소스 스캔을 넣는다: `onMouseDown`/`onMouseUp` 안에서 `UI.click` 없이 상태를 바꾸면 실패.

### 1-2. 탭 줄이 세 벌이다 — B
- **지금:** OATerminalTabs, PZUISubTabs, BU ISBUTabs가 따로 있다.
  - 각자 hover, 선택 표시, 소리, 키보드 처리를 따로 한다.
- **문제:** 상위탭만 소리 나고 하위탭은 안 나는 식의 차이가 다시 생긴다.
- **수정:**
  - kit `PZUITabs` 하나로 합친다.
  - 모양 차이(상위/하위, 아이콘 유무)는 스타일 값으로만 받는다.

### 1-3. 바닐라 위젯이 섞여 있다 — C
- **지금:**
  - OA Maps가 ISButton을 쓴다.
  - NoApi와 Upgrades/Window가 ISModalDialog를 쓴다.
- **문제:** 우리 창 안에서 모양과 소리가 다르다.
- **수정:**
  - kit Button과 kit Confirm(OK만 있는 변형 추가)으로 바꾼다.
  - NoApi는 예외로 둔다. API가 없을 때 뜨는 창이라, 그때 kit가 있다는 보장이 없다.

### 1-4. 메뉴 툴팁 도우미가 여섯 벌이다 — C
- **지금:** `tooltip`/`unavailable` 지역 함수가 여러 곳에 따로 있다.
  - OA: Gear/Menu, Machines/Menu, Trade/ContextMenu, Upgrades/Hooks, HarvestMenu, Story/Menus.
  - BU: ContextMenu.
  - 월드 메뉴는 `ISWorldObjectContextMenu.addToolTip`, 인벤토리 메뉴는 `ISInventoryPaneContextMenu.addToolTip`으로 섞여 있다.
- **수정:** kit Menu에 `Menu.tip(option, text)`와 `Menu.unavailable(option, text)`를 둔다.

---

## 2. 타이틀(화면 중앙 연출)

### 2-1. 타이틀 앞단이 두 벌이다 — A
- **지금:** OA Titles.lua(219줄)와 BU Titles.lua(97줄)가 같은 일을 따로 한다.
  - API text 핸들 잡기, 스타일 조회, 대체 경로.
- **BU에만 빠진 것:**
  - 창 위에 뜰 때 깔리는 배경. 그래서 E2E 121번 문제(창 위 타이틀이 안 읽힘)가 BU 거절 타이틀에서 다시 난다.
  - 옛 API의 크기 대체.
  - 톤.
  - 가운데 맞춤.
- **수정:**
  - kit에 `PZUIKit.Titles.show(handle, spec)`를 둔다. 맡는 일:
    - 배경
    - 스타일 대체
    - 소리
    - 크기 대체
    - API가 없을 때의 혼잣말 대체
    - 처음 본 표시
  - OA와 BU는 스타일 이름과 문구만 넘긴다.
  - BU의 SEEN 표시도 이쪽으로 옮긴다.

### 2-2. 혼잣말 경로가 섞여 있다 — C
- **지금:** OA는 `OA.Say`(묶음, 혼잣말 옵션, 지연)가 있다. 그런데 바로 `player:Say`를 부르는 곳이 12군데 있다.
  - Gear/Menu, HarvestMenu, Upgrades/Hooks, Senses.
  - BU는 Finds와 Actions가 직접 부른다.
- **문제:**
  - 혼잣말 옵션을 꺼도 이 줄들은 나온다.
  - 거절 줄은 늘 나오는 게 맞지만, Senses의 발견 줄은 혼잣말이다.
- **수정:**
  - 두 이름으로 나눈다.
    - `refuse(character, text)`: 늘 나옴. 거절과 실패에 쓴다.
    - `say(character, ...)`: 옵션을 따른다. 혼잣말에 쓴다.
  - kit에 공용으로 둔다.
  - 직접 `:Say` 호출을 없애고, 이것도 소스 스캔으로 막는다.
- 참고: 머리 위 HaloText는 현재 한 군데도 쓰지 않는다(위반 없음).

---

## 3. 지형과 칸 판정

### 3-1. "자연 지면(흙, 풀, 모래)" 판정이 세 벌이고 서로 다르다 — A
- **지금:**
  - OA Story/Game `Game.GROUND`: API 칸 조건. 접두어 `floors_exterior_natural` 또는 `blends_natural_01`. 길, 도로, 물은 뺀다.
  - OA Story/Menus `bareGround`: Lua 문자열로 같은 접두어를 본다. 도로나 물을 빼는 조건은 없다.
  - BU FloorLines `madeFloor`: `blends_natural` 14글자만 본다.
- **문제:** BU 판정이 OA와 어긋난다.
  - `floors_exterior_natural` 바닥(자연 흙과 풀)을 깐 바닥으로 본다. 그래서 선이 땅에 묻히지 않고 위에 얹혀 그려질 수 있다.
  - `blends_natural_02` 계열(물가)은 자연으로 본다.
  - 같은 땅이 모드마다 다르게 판정된다.
- **수정:**
  - API 칸 조건에 이름 있는 판정을 둔다: `ground = "natural"`. 게임의 파기 규칙(`DiggingUtil.mining_floorCanDig`) 그대로다.
  - 세 곳이 모두 이것을 쓴다.
  - 고치기 전에 해당 타일 이름을 게임 데이터에서 확인한다.

### 3-2. "물건을 놓을 수 있는 칸" 판정이 다섯 벌이다 — A
- **지금:**
  - OA Trade/Objects `FREE`: API 조건. `free`, `solidFloor`, `water`, `vehicle`, `noObjectData`. 이유 판별은 Lua로 다시 한다.
  - OA Machines `squareProblem`: Lua. `TreatAsSolidFloor`, `isSolid`/`isSolidTrans`, 계단, 나무, `isFree`, 차량, 물 플래그.
  - BU Units `blocked`: Lua. 물 플래그, `getFloor`, `isFree`.
    - (정정: 게임의 `isFree(false)`가 이미 막힌 칸, 나무, 계단, 단단한 바닥 없음을 거른다. 차량은 보지 않았다.)
  - BU Links `squareCost`: Lua. `getFloor`, 계단, 물 플래그, 높인 바닥(1/3, 2/3).
  - OA StageGame 곳곳: 바로 `isFree(false)`.
- **문제:**
  - 물을 보는 방법이 둘이다: `isWaterSquare`와 `IsoFlagType.water`.
  - 바닥을 보는 방법이 둘이다: `getFloor`와 `TreatAsSolidFloor`.
  - BU 유닛은 차량이 걸친 칸, 바닥 재질만 물인 칸에 설치될 수 있었다.
  - 거절 이유 이름도 모드마다 다르다.
    - OA Trade: water, floor, vehicle, blocked, occupied.
    - OA Machine: noFloor, blocked, water, taken.
- **수정:**
  - API에 한 칸 판정 `squares.test(square, filter)`를 추가한다.
    - 지금 OA는 `nearest({list = {한 칸}})`를 우회로 쓰고 있다.
  - "왜 아닌가"를 돌려주는 `squares.why(square, filter)`도 함께 둔다. 조건 순서대로 처음 걸린 이름을 돌려준다.
  - 놓기 조건은 `place = true` 같은 이름 있는 묶음으로 둔다: 단단한 바닥, 물 아님, 계단·나무·막힘 없음, 차량 없음.
  - 다섯 곳이 모두 이것을 쓴다.
  - 이유 이름과 번역 키를 한 벌로 맞춘다.

### 3-3. "실내/실외"가 세 뜻으로 섞여 있다 — B
- **지금:**
  - `isOutside()`: 지붕이 없다. OA Objects, Machines(빗물), BU Solar/WaterUnits, WaterRun.
  - `getRoom() == nil`: 방이 아니다. BU Panels/Moveables(제어반 모양), OA StageGame.
  - BU `Panels.buildingAt`: BU 자체의 건물 개념. Links.
  - OA PlaceCursor는 건물·방·나무를 Lua로 다시 센다. Objects의 `OPEN_GROUND` 조건과 같은 내용이다.
- **문제:** 각자 뜻이 맞을 수는 있다(태양광은 하늘, 제어반 모양은 방). 그런데 이름 없이 원시 호출로 흩어져 있다. 지붕 있는 현관 같은 경계 칸에서 모드끼리 판정이 갈린다.
- **수정:**
  - 세 뜻에 이름을 붙여 API 조건으로 둔다: `sky`(하늘이 보임), `room`(방 안), `building`(건물 안).
  - 쓰는 곳마다 어느 뜻인지 고른다.
  - PlaceCursor의 재계산은 API 조건의 부분 판정으로 바꾼다.

---

## 4. 게임 오브젝트 공용 메커니즘

### 4-1. 오브젝트 조명이 두 벌이다 — B (성능 포함)
- **지금:** OA Lights(66줄)와 BU Lights(147줄)가 같은 장치다.
  - 칸에 게임 광원을 달고 떼고, 칸 키로 기억하고, 제거될 때 떼는 일.
  - 게임은 광원을 저장하지 않고, 로드 영역 밖으로 나가면 버린다. 그래서:
    - BU는 매 게임 분마다 주변 물건 조명을 다시 건다(`Lights.everyMinute`).
    - OA는 모양이 바뀔 때마다 다시 건다.
- **문제:**
  - 같은 버그를 두 번 고쳐야 한다.
  - BU의 매분 루프는 반복 부하다.
- **수정:**
  - API에 `lights.glow(object, color, radius)`를 둔다.
  - API가 청크 로드 때 다시 걸고, 오브젝트가 지워질 때 뗀다.
  - 두 모드는 켜기/끄기만 부르고, 매분 루프를 지운다.

### 4-2. 가구 도구 훅이 세 벌 겹쳐 걸린다 — B
- **지금:** 세 곳이 각자 `ISMoveableSpriteProps`의 같은 메서드들을 감싼다.
  - 감싸는 곳: OA Machines/Moveables, OA Trade/Moveables, BU Moveables.
  - 감싸는 메서드: new, canPickUp, pickUp, canPlace, place, getInfoPanelDescription.
  - 이 중 Trade의 `new(sprite)`는 받은 추가 인자를 버린다.
  - OA FirstHooks는 `ISMoveablesAction`도 감싼다.
- **문제:**
  - 감싸는 순서에 따라 동작이 달라진다.
  - 호출마다 세 번 종류를 찾는다.
  - 인자를 버리는 고리가 하나라도 있으면 뒤쪽이 깨진다.
- **수정:**
  - kit Furniture에 `Furniture.register(spritePrefix 또는 판별 함수, handlers)`를 둔다.
  - 감싸기는 kit가 한 번만 한다.
  - 스프라이트로 등록된 핸들러를 고르고, 없으면 바닐라로 넘긴다.
  - 세 파일은 핸들러 표만 넘긴다.

### 4-3. 시간 동작(timed action) 베이스가 세 벌이고 바라보는 방향이 다르다 — A
- **지금:** OA Machines, OA Trade, BU Actions의 `base()`와 `fixedDuration()`이 거의 글자 그대로 같다.
  - **차이:**
    - Machines는 칸 가운데(`x + 0.5`)를 본다.
    - Trade와 BU는 칸 모서리(`x`)를 본다. 그래서 캐릭터가 대상에서 살짝 비껴 선다.
  - OA Gear, Upgrades, Story/Action, HarvestMenu는 따로 derive한다.
- **수정:**
  - kit에 `PZUIKit.Action.base(name, {ticks, anim, face = "center"})`를 둔다.
  - 모두 이것을 쓰고, 바라보는 곳은 칸 가운데로 맞춘다.

### 4-4. 들고 있는 상자 판별 — C
- **지금:** BU `Moveables.heldBox`가 kit `Heavy.held`와 같은 일을 BU 품목 표로 다시 한다.
- **수정:** `Heavy.held` 결과에서 종류만 거른다.

---

## 5. 모드 뼈대(Core)와 동기화

### 5-1. API 연결 코드가 두 벌이다 — B
- **지금:** OA Core와 BU Core가 따로 갖고 있다.
  - `log`
  - `api()`/`handle()`: 버전과 기능 확인.
  - `declareOutlines()`: 글자 그대로 중복.
- **정책 차이:** 이건 맞다.
  - OA는 API가 없으면 꺼진다.
  - BU는 기능별로 확인하고 축소 모드로 돈다.
- **수정:**
  - API 쪽 Lua 진입점으로 둔다: `PZExtAPI.connect(modId, {min = 버전, needs = {...}})`. 핸들, 없는 이유, 기능 표를 돌려준다.
  - `outlines.declare(handle, list)`도 함께 둔다.
  - 꺼질지 축소할지는 각 모드가 그대로 정한다.

### 5-2. Sync(서버/싱글 분기) 뼈대가 두 벌이다 — B
- **지금:** OA Sync와 BU Sync가 같은 분기를 다른 모양으로 짰다.
  - 같은 분기: changed, notice, sound, title, send. 서버면 `sendServerCommand`, 싱글이면 바로 전달.
  - 다른 모양: OA는 listen/deliver 리스너, BU는 `BU.onX` 콜백과 `answering`.
- **문제:** 멀티 대응을 손볼 때 두 곳을 따로 고쳐야 한다.
- **수정:**
  - kit에 `PZUIKit.Sync.channel(modId)`를 둔다. 리스너 방식: `listen`, `deliver`, `send`.
  - BU의 `onX`는 그 위의 얇은 별칭으로 남긴다.

### 5-3. 모드 옵션 구역 만들기 — C
- **지금:** OA Client.options와 BU Options가 같은 생성 코드를 따로 갖고 있다. `getOptions`가 없으면 `create`.
  - OA Maps와 Hallucination은 `getOptions`를 또 직접 부른다.
- **수정:** kit에 `Options.section(modId, titleKey)` 한 줄을 둔다.

---

## 6. 작은 도우미

### 6-1. 퍼센트 표기가 여섯 벌이다 — C
- **어디:** OA TabMission, StatusModel, Upgrades/Texts, Infection; BU PanelUi, `BU.percent`.
  - 반올림 방식이 조금씩 다르다.
- **수정:** kit Text에 `Text.percent(fraction)`을 둔다.

### 6-2. 완화 함수(ease, approach, clamp)가 세 벌이다 — C
- **어디:** OA Core `easeOut`/`clamp`, OA MapFx `easeOut`, BU PanelUi `ease`/`approach`. kit UI 안에도 같은 계산이 들어 있다.
- **수정:** kit UI에 `UI.easeOut`, `UI.approach`를 둔다.

### 6-3. 색 팔레트 — 유지
- BU PanelUi PALETTE와 OA 창 팔레트는 kit 팔레트 이름 체계를 이미 따른다. 값이 다른 것은 각 모드의 개성이다.
- 할 일 없음.

### 6-4. 창 껍데기 — 유지
- 여섯 창(OA 넷, BU 둘)이 ISCollapsableWindow를 상속하고, kit 팔레트·그리기로 칠한다.
- 껍데기를 하나로 묶을 만큼 공통 동작이 크지 않다. 할 일 없음.

---

## 진행 순서 제안

1. **A 묶음:** 지금 유저 눈에 보이거나 판정이 갈리는 것.
   - 1-1 `UI.click`과 소스 스캔
   - 2-1 kit 타이틀 앞단
   - 3-1 자연 지면
   - 3-2 놓기 판정과 `squares.test`/`why`
   - 4-3 동작 베이스와 바라보기
   - 이 중 3-1, 3-2는 API 빌드와 설치가 필요하다.
2. **B 묶음:**
   - 1-2 탭
   - 3-3 실내외 이름
   - 4-1 조명 API
   - 4-2 가구 훅 등록
   - 5-1 connect
   - 5-2 Sync
3. **C 묶음:** 나머지 정리. B 묶음과 같은 파일을 만질 때 함께 한다.

**검증 방법**
- 묶음마다 해당 영역 단위 테스트와 LuaCheck를 돌린다.
- 인게임 확인은 마지막에 한 번에 모아서 한다.
- API를 바꾸면 extension-api 테스트도 돌린다.
