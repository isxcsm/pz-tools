# 소리 시스템 (PZUIKit, OA, BU, API)

소리 에셋 작업 전에, 소리가 나는 지점을 한 곳으로 모은다. 에셋을 바꾸거나 새로 넣을 때 표 한 줄만 고치면 되게 하는 것이 목표다.

## 1. 지금 상태 (2026-10-18 점검)

### 타이핑 계열
| 엔진 | 쓰는 곳 | 구조 | 소리 |
|---|---|---|---|
| `PZUITypedText` + `PZUIKit.Typing` (키트) | OA 서류철, 서류 뷰어, BU 설명서 | 시계 하나로 프레임마다 글자 수를 셈 (`Markup.count`, 줄 인쇄는 `Typing.printed`). 클릭은 본 곳까지만 당김 | 없음. 글자가 늘어나는 순간을 밖에 알리는 지점이 없다 |
| `CommsScript` 타임라인 + `OATabComms` | 단말 교신 (팀 줄 수신, 주인공 입력·지우기·전송) | 줄을 시작할 때 타임라인을 한 번 만들고, 프레임은 `Script.at(tl, t)`로 상태만 읽음 | 줄 수신 `RadioZap`, 전송 `RadioButton`, 바닥 `RadioStatic`. 글자 단위 소리 없음 |
| `FieldCall` | 현장 무전 | 교신 스크립트를 자막으로 | 팀 줄에 `RadioZap` |
| API `text.title` (Java) | OA, BU 제목 연출 | 큐, 스타일별 등장·유지·퇴장 | 없음. 착지(도장 `impact`) 순간을 Lua가 모른다 |

판정: 엔진 자체는 깔끔하다 (시계 하나, 상태 계산, 프레임은 읽기만). 지저분한 건 **소리 쪽**이다.

### 소리 재생
- 직접 호출 26곳, 네 가지 API가 섞여 있다: `getSoundManager():playUISound`, `emitter:playSound`, `square:playSound` / `playSoundLocal`, `PlayWorldSound`.
- 바닐라 소리 이름이 파일마다 상수로 흩어져 있다 (`Alert.SOUND`, `FieldCall.SOUND_IN`, `OATabComms.SOUND_*`, `Things.LATCH_SOUND`, `Presentation.SOUND` 등, BU는 `Sync.sound(panel, "LightSwitch")`).
- 일시정지 처리가 교신 바닥 소음에만 있다 (`holdSound`).
- 게임 소리 낮추기(덕킹)가 교신 탭 전용으로 들어 있다 (`hush`).
- UI 버튼 소리: 키트 `Combo`, `PopMenu`만 `UISelectListItem`, OA 상점·연구창은 직접 호출, `PZUIButton`은 바닐라 `ISButton` 기본음.
- `addSound`(좀비가 듣는 소리)는 소리가 아니라 게임 규칙이다. 이 시스템에 넣지 않는다.

### 게임 사실 (jar·스크립트 확인)
- 모드 소리는 `media/scripts/*.txt`의 `sound <이름> { category = ..., master = ..., loop = ..., clip { file = media/sound/x.ogg, volume = ..., pitch = ..., distanceMax = ... } }`. 바닐라도 `file =` 클립을 쓴다 (`sounds_zombie_voice_tutorial.txt`).
- 한 소리에 `clip`이 여럿이면 재생마다 하나를 무작위로 고른다 (`GameSound.getRandomClip`). 변주는 이것으로 한다.
- 클립마다 `volume`, `pitch`, `distanceMin/Max`, `reverbFactor`, 소리마다 `category`, `master` (Primary, Ambient, Music...), `loop`, `is3D`.
- 소리 스크립트 파일에 `//` 주석이 있으면 파서가 그 파일을 통째로 버린다 (오류 없음). `/* */`만 쓴다. `build.py`가 만드는 머리말도 그렇다.
- **볼륨 설정은 `file` 클립에 안 먹는다.** 옵션의 효과음·환경음·음악 크기는 FMOD VCA(`vca:/Settings_Sfx` 등)로만 줄이는데, `file` 클립은 VCA를 거치지 않는 채널 그룹(`InGameNonBank`)에 나고 볼륨은 `clip.volume × 소리별 고급 볼륨`뿐이다 (`GameSoundClip.getEffectiveVolume`). 그래서 모든 모드의 자체 소리가 효과음 0에서도 최대 음량으로 났다. API가 고친다: `getEffectiveVolume`(메뉴용 포함)의 반환에 소리 `master`의 사운드 매니저 볼륨을 곱한다 (event 클립은 VCA가 줄이므로 그대로). 사운드 매니저 값이라 덕킹도 따른다. 확인: 효과음 0에서 파일 0, 0.5에서 0.5, 바닐라 이벤트 1 그대로.
- 바닐라 소리 이름은 3036개이고, 그 밖의 이름을 쓴 큐는 아무 소리도 나지 않는다 (경고 없음). `oa.box.latch`의 `PZ_MetalSnap`이 그랬다 (`CloseMetalToolbox`로). `build.py --check`가 세 모드의 큐 표를 바닐라·`sounds.json` 이름과 대조한다.

## 2. 만들 것

### S1. 단일 재생 지점 `PZUIKit.Sound` (키트, 공용)
모든 소리는 **큐 이름**으로 낸다. 큐 이름 → 정의는 각 모드의 표 한 곳에 있다.

```lua
Sound.define("oa.comms.in", { sound = "RadioZap" })            -- 표에서
Sound.define("oa.key", { sound = "OA_Key", gap = 45 })          -- gap: 같은 큐의 최소 간격(ms)
Sound.ui(cue)                    -- 화면 소리 (UI). 핸들
Sound.at(cue, square)            -- 세상의 칸에서, 그 자리에서 들리게
Sound.on(cue, character)         -- 캐릭터의 에미터에서. 핸들
Sound.stop(handle)
Sound.loop(owner, cue)           -- 화면 반복음: 게임 일시정지에 멈추고 풀리면 다시 (교신 바닥 소음)
Sound.unloop(owner)
Sound.duck(owner, on)            -- 환경음만 낮춤 (효과음은 그대로: 장면의 키·무전도 효과음이라 같이 줄었다). 쥔 owner가 하나라도 있으면 낮춘 채, 다 놓으면 원래대로
Sound.typed(cue, from, to)       -- 글자 from+1..to가 나왔다: gap 안에서 한 번. 한꺼번에 많이 뛰면(클릭으로 당김) 소리 없음
```
- 정의가 없는 큐는 아무 소리도 내지 않고 한 번만 로그에 남긴다 (에셋이 아직 없는 큐).
- 시간 판단과 정의 표는 게임을 안 건드리는 shared 쪽에 두어 단위 테스트한다. 게임 호출은 얇은 어댑터 하나.
- 덕킹은 지금 교신 탭 코드를 그대로 옮긴다 (옵션 값 × 비율, 복귀는 옵션 값).

### S2. 타이핑 소리 지점
- `PZUITypedText`: 글자 수가 바뀌는 곳(`advance`) 한 곳에서 `self.typeCue`가 있으면 `Sound.typed(typeCue, old, n)`. 줄 인쇄(문서)는 줄마다 `rowCue` 한 번. 클릭으로 당긴 건 소리 없음. 큐는 패널을 만드는 쪽이 넘긴다 (OA 단말 종류별, BU 설명서).
- 교신 `OATabComms.advance`: 상태의 `shown`(팀 글자), `input`(주인공 글자), 단계(`erase`)가 바뀐 만큼 큐를 낸다. 줄 수신, 전송, 바닥 소음, 덕킹도 S1으로.
- `FieldCall`도 같은 큐로.

### S3. 제목 소리 (API, 범용)
- `text.title` spec에 `sounds = { enter = "...", land = "...", leave = "..." }` (게임 소리 이름). Java가 그 순간에 화면 소리로 낸다: `enter` 등장 시작, `land` 등장이 끝난 순간 (도장이 찍히는 순간), `leave` 퇴장 시작. 일시정지·잠에는 시계와 같이 선다 (제목 시계가 서면 순간도 늦어진다).
- API는 내용을 모른다: 이름만 받는다. 어떤 스타일에 어떤 소리를 쓸지는 모드 표.
- OA `Titles`, BU `Titles`는 스타일별 큐를 표에서 찾아 이름을 넘긴다. API 텍스트가 없을 때의 대체 표시는 시작에 `enter` 한 번.

### S4. 기존 호출 옮기기
26곳 전부 S1 큐로. 처음에는 지금 쓰는 바닐라 소리를 그대로 정의해 동작이 같게 하고 (테스트로 확인), 에셋은 표만 바꾼다.
- 키트: `Combo`, `PopMenu` (`kit.select`), `PZUIButton` (`kit.press`, 바닐라 기본음 대신 큐)
- OA: 교신(수신, 전송, 바닥 소음, 덕킹), 현장 무전, 교신 알림(세상 소리), 환각 벨, 헬기 연출, 상자 걸쇠·부숨, 무대 판자, 무대 무전 소리, 혈청 검사, 상점·연구창 UI
- BU: `Sync.sound` → 큐 이름으로 (서버가 큐를 보내고 클라이언트가 표에서 찾는다)

### S5. 에셋 파이프라인 (`pz-tools/mods/tools/sound/`)
- `sources/`: 원본 (CC0 라이브러리, 직접 만든 것). `sources/LICENSES.csv`: 파일, 출처, 라이선스, 작성자.
- 합성(numpy)은 기각했다: 음 높이가 있는 저음은 통 두드리는 소리가 되고, 바늘 연타 인쇄음은 옛 2D 게임 효과음처럼 들렸다 (사용자 청취). 현대 키보드 녹음(Cherry KC 1000, OpenGameArt)도 기각: 옛날 키보드 소리가 아니었다. 지금은 위키미디어 공용의 CC0·퍼블릭 도메인 녹음 (`sources/commons/`, LICENSES.csv): IBM Model F 122 (1984)의 타건 8개(글자)·1개(백스페이스)·스페이스바, IBM M2의 엔터, Star LC-10 도트 프린터의 짧은 줄 출력 4개(`KIT_PrintRow`, 서류 줄). 빠른 타이핑 녹음이라 누름 뒤 40 ms 안에 뗌·다음 키가 오므로 `slice.py`로 타격 시점(국소 피크 -10 dB)을 찾아 그 앞 3 ms부터 60 ms만 쓰고 끝을 `fadeOut`으로 줄인다.
- **키보드 (`Sound.defineKeyboard`).** 키 소리는 무작위가 아니라 글자로 정한다: 같은 글자는 늘 같은 키 (글자 코드 × 황금비의 소수부로 고르게: 단순 나머지는 받침 없는 한글 음절을 두 키에 몰았다), 띄어쓰기는 스페이스바, 줄바꿈은 엔터, 지우기는 백스페이스 한 키 (교신 지우기는 초당 10자로 일정). 큐는 `{ keyboard = "kit.terminal" }`(`erase = true`면 지우는 키), 엔진은 마지막에 나온 글자를 `Sound.typed(cue, from, to, char)`로 넘긴다 (`PZUITypedText`: `parse.plain`, 교신: 입력 줄·팀 줄의 글자). `preview.py --keyboard`가 같은 규칙으로 문장을 쳐 본다.
- `build.py`: 앞뒤 자르기 (클립 피크 기준: 피크 -30 dB 2 ms 앞부터 -50 dB까지. 전체 눈금 기준으로 자르면 조용한 녹음의 방 소음부터 잡혔다), `length`, 모노 44.1 kHz, 피크 맞춤, ogg로 각 모드 `media/sound/`에. 소리 스크립트 `.txt`도 표에서 생성 (변주 클립, 볼륨, 마스터).
- `report.py`: 소리마다 파형·스펙트로그램·음량·길이 그림 (나는 들을 수 없으므로 이것으로 검수한다. 듣는 검수는 사용자).
- `preview.py`: 한 소리를 게임처럼 이어 친 WAV (`report/preview_<이름>.wav`: 초당 글자 수, gap, 줄 사이 쉼). 게임 밖에서 듣는 검수용.
- 도구: ffmpeg, SoX, Audacity(사용자 청취·편집), Python scipy·soundfile·pyloudnorm·librosa·matplotlib. 설치됨.

### S6. 소리 목록
S1~S4가 끝나면 두 모드의 사건을 전부 훑어 표로 만든다: 사건, 큐, 지금 소리, 원하는 소리, 공용(키트)/모드, 바닐라 재사용/새 에셋(CC0/직접). 새 에셋이 필요한 것만 S5로.

2026-10-18 훑음. "바닐라" 열의 이름은 게임 스크립트에 있는 것만 적었다 (`build.py --check`가 대조). 들어 보고 정하는 것은 사용자 청취 몫.

**있는 큐**

| 사건 | 큐 | 지금 | 메모 |
| --- | --- | --- | --- |
| 교신 팀 줄 시작 / 전송 / 바닥 소음 | `oa.comms.in` / `send` / `static` | RadioZap / RadioButton / RadioStatic (반복) | 바닐라 |
| 교신 팀 글자 들어옴 | `oa.comms.recv` | 무음 | 후보: 텔레프린터 수신음(새 에셋) 또는 무음 유지 |
| 교신 주인공 타이핑 / 지우기 | `oa.comms.key` / `oa.comms.erase` | 키트 키보드 (Model F, 백스페이스) | 녹음 |
| 서류 글자 / 줄 출력 | `oa.paper.key` / `oa.paper.row` | 키트 키보드 / `KIT_PrintRow` (Star LC-10) | 녹음 |
| 교신 대기 알림 (세상) | `oa.comms.alert` | RadioZap | 바닐라 |
| 헬기 통과 | `oa.heli.pass` | Helicopter | 바닐라 |
| 상자·화물 걸쇠 / 부숨 | `oa.box.latch` / `oa.box.break` | CloseMetalToolbox / BreakFurniture | 걸쇠는 이름 오류로 무음이었다 (고침) |
| 무대 판자 / 무대 무전 | `oa.stage.plank` / `oa.stage.radio` | BreakBarricadePlank / RadioTalk | 바닐라 |
| 환각 벨 | `oa.hallucination.ring` | TelevisionTestBeep | 바닐라 |
| 혈청 검사 | `oa.serum.test` | FirstAidApplyAlcoholWipes | 바닐라 |
| BU 스위치 / 발전기 정지 | `bu.switch` / `bu.generator.stop` | LightSwitch / GeneratorStopping | 스위치는 제어반 레버라 더 무거운 소리 후보: KnobSwitch, 새 에셋(차단기 레버) |
| BU 설명서 줄 | `bu.manual.row` | 무음 | 화면이지 프린터가 아니다: 무음 유지 |
| 키트 선택 / 버튼 | `kit.select` / `kit.press` | UISelectListItem / UIActivateButton | 바닐라 |
| 제목 순간 (스타일 10종 × 등장·착지·퇴장, 줄 포함) | `kit.title.*` | 아래 표 | 제목은 순간마다 소리를 한 번 내고 멈추지 않는다: 스스로 끝나는 소리만 된다 |

**게임 녹음으로 들어 봄** (2026-10-18). 게임 출력을 루프백 장치("What U Hear")로 녹음해 바닐라 기준음과 같이 쟀다 (`tests/ingame/sound_listen.lua`: a 액션·키·프린터, b 제목, c 교신; 녹음은 `tools/sound/report/listen/`). 바닐라 UI 클릭 최대 -9~-11 dB, 평균 -28~-31 dB 기준으로:
- 교신 덕킹이 효과음 볼륨을 낮춰 교신 자신의 키(6 dB)와 무전음(10~15 dB)까지 줄였다. 덕킹은 환경음만 낮춘다 (게임은 교신 중에도 돌고, 좀비 소리는 들려야 한다). 고친 뒤 키 최대 -16, 팀 줄 시작 RadioZap -28~-31, 바닥 잡음 평균 -51.
- 타자기 제목 연타가 다른 제목보다 10 dB 작았다: 피크 -12 → -6 (줄 -16 → -10).
- 액션: 자물쇠 -39 (바닐라 렌치 -38과 같다). 키 -35, 지우기 -32, 프린터 줄 -34 (UI 클릭보다 5~8 dB 아래, 연타라 맞다). 프린터 줄은 원본이 5 kHz 위로 잘린 옛 녹음이라 키보다 먹먹하다.

**제목 소리** (2026-10-18). 제목은 소리를 한 번 내고 멈추지 않으므로 스스로 끝나는 소리만 된다. 바닐라 이벤트의 반복 여부는 FMOD 뱅크 밖에서 알 수 없어 게임에서 쟀다 (`tests/ingame/sound_e2e.lua`, 한 번 재생 뒤 2·5·10초): CampfireLight, TuneIn, VehicleRadioTuneIn, HeartBeat, WaterDrip은 10초 뒤에도 울린다 (못 쓴다). UseMatch, UseLighter, RadioZap은 2초 안에, LureHitWater는 5초 안에 끝난다.

| 스타일 | 순간 | 소리 |
| --- | --- | --- |
| stamp | 착지 / 줄 착지 | `KIT_TitleStamp` (Kenney impactPlank_medium 5개: 나무 "탁", 낮은 울림에 중고음 타격) / `KIT_TitleStampLine` (impactGeneric_light: 0.1초, 더 가볍게). 처음 고른 impactWood는 게임 녹음에서 500 Hz 위가 비어 멀리서 "웅" 하는 소리였다 |
| type | 등장 / 줄 등장 / 퇴장 | `KIT_TitleType` (Erika 5 타자기 1.3초 연타 3개: 글자가 찍히는 1.3초와 같은 길이, 피크 -6) / `KIT_TitleTypeLine` (1.5~1.6초, -10) / `KIT_TitleFeed` (캐리지 리턴: 종이가 올라가기 시작할 때) |
| notice | 등장 | RadioZap (신호가 잡힘) |
| discovery | 등장 | UseMatch (성냥을 그어 횃불이 켜짐) |
| dust | 퇴장 | UseLighter (종이에 불이 붙음) |
| sink | 퇴장 | LureHitWater (물에 잠김) |
| bleed, pulse | | 무음: 바닐라 WaterDrip·HeartBeat는 반복음. 한 번 떨어지는 방울, 한 번 뛰는 심장 녹음이 오면 한 줄 |
| unveil, brief | | 무음: 안개는 소리가 없고, 짧은 소식은 자주 뜬다 |

**타임드 액션** (2026-10-18 연결). 바닐라 액션은 시작에 캐릭터 소리를 내고 끝·중단에 `stopOrTriggerSound`로 멈춘다. 가구를 들고 놓는 것(ISMoveablesAction)은 작업 중 소리 없이 끝에 UI 소리 한 번이다. 키트의 한 지점 `Sound.timed(class, during, done)`이 같은 일을 한다: 파일 끝에서 클래스의 start/stop/perform을 감싸, `during`은 일하는 동안 캐릭터에서, `done`은 끝났을 때 화면에서 낸다. 큐 대신 액션을 받는 함수도 된다 (도구·종류에 따라 다른 소리). 코드에 쓴 큐가 표에 없으면 `build.py --check`가 잡는다.

| 액션 | 큐 | 소리 |
| --- | --- | --- |
| OA 물건·기계 놓기 (`ISOAPlaceThing`, `ISOAMachinePlace`), BU 상자 작동 (`ISBUActivateBox`: 들었다 놓는 셈) | 끝 `oa.action.place` / `bu.action.place` | UIObjectMenuObjectPlace |
| OA 기계·미끼 줍기 (`ISOAMachinePickUp`, `ISOAMachineTakeLure`), BU 상자 회수 (`ISBUTakeBox`) | 끝 `oa.action.pickup` / `bu.action.pickup` | UIObjectMenuObjectPickup |
| OA 기계 부품 넣기·빼기, 장비 키트 장착 (`ISOAMachinePartIn/Out`, `ISOAFitItemKit`, `ISOAFitVehicleKit`) | `oa.action.wrench` | RepairWithWrench |
| OA 상자 봉인 (`ISOASeal`) | `oa.action.tape` | FixWithTape (끝의 걸쇠는 `oa.box.latch`) |
| OA 상자 해체, 손으로 화물 열기, 손 파쇄 (`ISOADismantleBox`, `ISOAUnseal` 맨손, `ISOAMachineShred`) | `oa.action.dismantle` | Dismantle |
| OA 지렛대로 열기, 지렛대로 화물 열기 (`ISOAPryOpen`, `ISOAUnseal` 지렛대) | `oa.action.pry` | BeginRemoveBarricadePlankCrowbar |
| OA 자물쇠 따기·경보 끊기 (`ISOAPickLock`, `ISOADisarm`) | `oa.action.pick` | `OA_LockPick`: 바닐라에 맞는 소리가 없어 녹음 (OpenGameArt Tegurd, CC0). 실제로 따는 33~46.5초를 두 클립으로, 액션 동안 반복 |
| OA 검사 키트 (`ISOAUseSerum` 검사) | `oa.serum.test` | FirstAidApplyAlcoholWipes (주사·복용은 무음) |
| OA 흙 시료 (`ISOAStoryAction` 흙; 말뚝 살펴보기는 무음) | `oa.action.soil` | DigFurrowWithHands |
| OA 시체 시료 (`ISOAHarvestAction`) | `oa.action.harvest` | FirstAidApplyAlcoholWipes |
| BU 배선 연결·해제 (`ISBUConnect`, `ISBUDisconnect`) | 전기 `bu.action.wire`, 물 `bu.action.wrench` | GeneratorConnect / RepairWithWrench |
| BU 배관 추가·제거, 필터 교체 (`ISBUAddPipe`, `ISBURemovePipe`, `ISBUReplaceMedia`) | `bu.action.wrench` | RepairWithWrench |
| BU 단계 올림, 역설계, 상자 분해 (`ISBUUpgradePanel`, `ISBUReverseEngineer`, `ISBUTakeApartBox`) | `bu.action.electric` | Dismantle (전기 작업) |
| BU 배터리 되살리기 (`ISBUReviveBattery`: 베이킹소다 용액을 셀에 채움, 충전이 아니다) | `bu.action.battery` | PourWaterIntoObject |
| BU 눈 치우기 (`ISBUClearSnow`) | 없음 | 손으로 털어냄: 무음 |
| 창 열기 (`ISBUOpenPanel`, `ISBUOpenRack`, `ISOAMachineOpen`, `ISOAUseTerminal`) | 없음 | 0~1틱: 창이 열리는 것이 결과 |

### S7. 제목 소리 다시 (2026-10-19)

사용자 청취 결과 (2026-10-19), 지금 제목 소리는 장난 같고 촌스럽다.
- 노티스: 화면은 '우우웅' 하는 고주파 간섭인데 소리는 치지직이다. 화면은 등장과 퇴장 때 모두 흔들리는데 소리는 등장 때만 난다.
- 스탬프: 소리가 촌스럽다.
- 더스트: 재가 날리는 동안 소리가 없다.

목표는 두 가지다. 소리가 그 순간의 의미에 맞을 것, 그리고 요즘 게임과 영상 타이틀 수준일 것.

**기준 (사용자 지적, 2026-10-19).** 화면에 보이는 것을 하나하나 흉내 내지 않는다. 도장이 보인다고 도장 소리, 잉크가 보인다고 물방울, 불이 보인다고 타닥 소리를 붙이면 유치하다. 소리는 그 타이틀이 게임에서 어떤 순간인지를 맡는다.
- 스타일마다 실제로 쓰이는 곳(호출)을 보고 역할을 정한다: 업적, 해금, 업무 정보, 발견, 새 국면, 상실, 안도, 공포, 작은 피드백.
- 자주 나오는 것은 짧고 작게, 드물고 중요한 것은 크고 길게 한다.
- 모든 스타일이 한 계열의 소리다: 절제된 시네마틱 게임 UI, 따뜻하고 깨끗하게, 짧은 자연 잔향.
- 화면과는 큰 박자만 맞춘다. 소리의 정점은 제목이 다 들어온 때(또는 그 스타일의 결정적 순간)에 둔다. 퇴장의 긴 연출에는 작은 여운만 두거나 소리를 두지 않는다.

**API (순간과 수명).** 순간은 `enter`, `land`, `leave`에 `hold`를 더한다.
- `hold`는 착지 때 시작해 제목이 끝날 때까지 이어지는 소리다. 소리 스크립트의 `loop`로 늘이고, 퇴장 동안 볼륨을 퇴장 진행에 맞춰 0까지 내린다.
- 모든 순간의 소리는 제목의 수명에 묶인다. 제목이 사라지거나, 다음 제목이 먼저 나서 빨리 퇴장하면(`now`) 남은 소리를 짧게(0.15초) 줄여 끈다.
- 줄(subtitle)도 같은 순간을 가진다.
- 일시정지와 끊김 보정(프레임당 0.1초)은 제목 시계와 같이 간다.

**스타일별 소리** (쓰이는 곳 → 역할 → 소리). 정점: 소리가 시작된 때부터 가장 큰 때까지.

| 스타일 | 쓰이는 곳 (호출 수) | 역할 | 소리 | 정점 |
| --- | --- | --- | --- | --- |
| stamp | 등급 갱신·재지정, 납품 봉인, 도토리 100개 (5) | 공식 인정, 업적 | 착지 때 묵직하고 단정한 확정 한 방 + 따뜻한 울림 (2.5초) | 착지 |
| dust | 단계 상승, 신규 품목, 트리·보드 개방, 대금 지급, 물림 저항 준비 (10) | 성장, 해금 | 차오르다 따뜻하게 풀리는 상승 (3초); 퇴장은 작은 여운 | 1.0초 (다 들어옴) |
| notice | 무전 호출, 투하, 임무 개시, 새 요청, 기한, 채무 (9) | 업무 연락 | 짧고 절제된 수신 신호 (1.2초) | 시작 |
| discovery | 낙하지 발견, 마을 수색, 밀집 구역 소탕, 임무 확보, 이스터에그 (8) | 발견 | 부풀다가 드러나는 발견음 (3초); 퇴장은 작은 여운 | 1.9초 (횃불이 열림) |
| unveil | 첫 보급, 현장 도착, 보급선 개통 (3) | 새 국면 | 넓게 열리는 공간감의 상승 (4.5초); 퇴장은 작은 여운 | 3.0초 |
| sink | 임무 만료·포기·실패, 약물 소실 (5) | 상실 | 낮게 가라앉는 음 (3.5초) | 0.25초 |
| pulse | 혈청 반전, 음성 판정, 물림 지연 끝 (5) | 긴장 뒤 안도 | 긴장에서 안도로 풀리는 음 (3초) | 0.5초 |
| bleed | 감염 양성 (1) | 공포 | 불길하고 묵직한 한 방 + 어두운 울림 (4초) | 0.3초 |
| brief | 키트 장착, 수색 보너스, 처치 기록 (3) | 작고 잦은 피드백 | 아주 짧은 틱 (0.6초) | 시작 |
| type | 안내서, 호출 부호 | 문서 | 지금 그대로 (타자기 녹음) | |

**소리 출처 (2026-10-19 다시).** 녹음을 가공한 첫 후보 51개(위키미디어·Kenney·OpenGameArt)는 사용자가 거의 다 기각해서 지웠다. 기각 이유는 셋이다. 들을 수 없는 상태에서 설명문으로 원본을 골랐고, 목표와 다른 물건의 녹음(UPS, 치과 스케일러, 커피 로스터)을 가공해 흉내 냈으며, 야외 현장 녹음이라 사람 소리가 섞였다. 이제 후보는 Stable Audio 3 Small-SFX(공개 가중치, Stability AI Community License: 연 매출 100만 달러 미만 무료 상업 이용)로 만든다. 이 PC의 GTX 1080에서 fp32로 돌린다(PyTorch 2.7.1 cu126, 체크아웃 `C:/git/pz-workspace/sa3`). `tools/sound/ai_titles.py`에 큐마다 프롬프트 두세 가지가 있고, 시드를 바꿔 후보 8개씩 만든다. 가공은 앞 무음 자르기, 길이와 끝 페이드, 모노 44.1 kHz, 피크 맞춤만 하고, 홀드는 끝을 앞에 교차해 반복 이음새를 없앤다. 층 쌓기나 피치 변형은 하지 않는다. 후보는 `tools/sound/gen/`(git 밖)에 두고, `prompts.json`에 파일마다 프롬프트와 시드를 적어 고른 것을 다시 만들 수 있게 한다.

**듣는 검수.** 타이틀랩(`lab-audio.js`, `gen/manifest.js`의 목록)이 스타일의 시간대로 후보 소리를 재생하고, 후보마다 따로 들어 보는 ▶가 있다. 사용자가 후보를 바꿔 들으며 고르면, 고른 것을 게임에 넣는다. 레벨은 S6의 기준(바닐라 UI 클릭)에 맞춘다.

## 3. 순서
S1 → S2 → S4 (동작 동일 확인) → S3 (API) → S5 → S6 → 에셋 → 연출 템포 재조정 → 통합 E2E.

## 4. 검토
- **키 소리 연타.** 교신 팀 줄은 초당 28자, 문서는 초당 60~80자다. 글자마다 내면 소리가 뭉개진다. 큐의 `gap`으로 최소 간격을 두고, 그 사이 글자는 소리 없이 지나간다. 값은 에셋을 넣으며 정한다.
- **일시정지.** 교신은 장면 시계(`UI.sceneNow`)로 일시정지에 서고, 서류 타이핑은 실제 시계로 일시정지에도 간다 (읽을 수 있게). 소리는 각자 시계를 따른다: 글자가 나오면 소리도 난다. 반복음(`loop`)만 일시정지에 멈춘다 (바닐라 일시정지 규칙: 덮지 않는다).
- **덕킹 복귀.** 게임이 교신 중에 꺼져도 옵션 값은 바뀌지 않는다 (사운드 매니저 볼륨만 낮췄다). 그대로 둔다.
- **멀티플레이.** 싱글 기준. BU의 서버→클라이언트 소리 명령은 큐 이름을 실어 그대로 둔다.
