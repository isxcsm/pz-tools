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
- `lab.py` + `lab/index.html` (소리 실험실): 모드 Lua의 큐를 전부 읽어(`Sound.defineAll/define/defineKeyboard/timed`, 손으로 쓴 목록 없음) `lab/manifest.js`를 만들고, 페이지가 게임처럼 재생한다. 모드별(PZUIKit, OA, BU)·종류별(UI, 교신·서류, 액션, 월드)로 큐, 사건(S6 표), 우리/바닐라, 정의 위치, 쓰는 곳을 보여 준다. 우리 소리는 클립을 무작위로 골라 스크립트 볼륨으로 내고, 큐의 gap 연타, 액션 길이만큼 반복하다 멈추는 "액션 중", 줄 출력, 키보드 타이핑(`Sound.keyOf` 그대로, 초당 글자 수와 지우기)을 한다. 바닐라 소리는 FMOD 뱅크 안이라 재생하지 못한다. 실행: `python -X utf8 lab.py [--listen report/listen]`, 저장소 루트를 정적 서버로 열고(`.claude/launch.json`의 `sound-lab`, 포트 8773) `mods/tools/sound/lab/index.html`. `--listen`에 게임 녹음(`a.wav` + `a_events.txt`)이 있으면 `ref` 줄(바닐라 UI 클릭)을 `lab/ref/`로 잘라 레벨 기준으로, 바닐라 큐의 게임 녹음(`act`/`done`)을 같은 큐 줄에 붙인다. 후보는 `candidates/<큐 이름 또는 소리 이름>/*.ogg` (하위 폴더 하나는 변주 묶음 하나): 큐마다 현재/후보 라디오와 ▶, 메모가 있고, "선택 내보내기"가 바뀐 선택과 메모를 JSON으로 보여 준다(브라우저 localStorage에 저장). `candidates/`, `lab/ref/`, `lab/manifest.js`는 git에 없다.
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
| 제목 순간 (스타일 10종 × 등장·착지·유지·퇴장) | `kit.title.<스타일>.<순간>` | S7: 고른 소리 (`KIT_T_*`), 타자(type)는 키트 키보드 | 제목 하나에 소리 하나, 줄은 무음 (타자는 줄도 친다) |

**게임 녹음으로 들어 봄** (2026-10-18). 게임 출력을 루프백 장치("What U Hear")로 녹음해 바닐라 기준음과 같이 쟀다 (`tests/ingame/sound_listen.lua`: a 액션·키·프린터, b 제목, c 교신; 녹음은 `tools/sound/report/listen/`). 바닐라 UI 클릭 최대 -9~-11 dB, 평균 -28~-31 dB 기준으로:
- 교신 덕킹이 효과음 볼륨을 낮춰 교신 자신의 키(6 dB)와 무전음(10~15 dB)까지 줄였다. 덕킹은 환경음만 낮춘다 (게임은 교신 중에도 돌고, 좀비 소리는 들려야 한다). 고친 뒤 키 최대 -16, 팀 줄 시작 RadioZap -28~-31, 바닥 잡음 평균 -51.
- 타자기 제목 연타가 다른 제목보다 10 dB 작았다: 피크 -12 → -6 (줄 -16 → -10).
- 액션: 자물쇠 -39 (바닐라 렌치 -38과 같다). 키 -35, 지우기 -32, 프린터 줄 -34 (UI 클릭보다 5~8 dB 아래, 연타라 맞다). 프린터 줄은 원본이 5 kHz 위로 잘린 옛 녹음이라 키보다 먹먹하다.

**제목 소리** (2026-10-18 쟀고, 2026-10-19에 S7로 바뀜). 제목은 소리를 한 번 내고 멈추지 않으므로 스스로 끝나는 소리만 된다. 바닐라 이벤트의 반복 여부는 FMOD 뱅크 밖에서 알 수 없어 게임에서 쟀다 (`tests/ingame/sound_e2e.lua`, 한 번 재생 뒤 2·5·10초): CampfireLight, TuneIn, VehicleRadioTuneIn, HeartBeat, WaterDrip은 10초 뒤에도 울린다 (못 쓴다). UseMatch, UseLighter, RadioZap은 2초 안에, LureHitWater는 5초 안에 끝난다. 그 바닐라 소리와 Kenney 충격음으로 때운 제목 소리는 흉내 내기라 지웠다. 지금 제목 소리는 S7이다 (스타일마다 한 소리, 줄은 무음).

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
| type | 안내서, 호출 부호 | 문서 | 키트 키보드 (교신의 주인공 타자와 같은 손: 글자마다 키, 스페이스, 다 치면 엔터, 종이 올릴 때마다 엔터) | |

**소리 출처 (2026-10-19 다시).** 녹음을 가공한 첫 후보 51개(위키미디어·Kenney·OpenGameArt)는 사용자가 거의 다 기각해서 지웠다. 기각 이유는 셋이다. 들을 수 없는 상태에서 설명문으로 원본을 골랐고, 목표와 다른 물건의 녹음(UPS, 치과 스케일러, 커피 로스터)을 가공해 흉내 냈으며, 야외 현장 녹음이라 사람 소리가 섞였다. 이제 후보는 Stable Audio 3 Small-SFX(공개 가중치, Stability AI Community License: 연 매출 100만 달러 미만 무료 상업 이용)로 만든다. 이 PC의 GTX 1080에서 fp32로 돌린다(PyTorch 2.7.1 cu126, 체크아웃 `C:/git/pz-workspace/sa3`). `tools/sound/ai_titles.py`에 큐마다 프롬프트 두세 가지가 있고, 시드를 바꿔 후보 8개씩 만든다. 가공은 앞 무음 자르기, 길이와 끝 페이드, 모노 44.1 kHz, 피크 맞춤만 하고, 홀드는 끝을 앞에 교차해 반복 이음새를 없앤다. 층 쌓기나 피치 변형은 하지 않는다. 후보는 `tools/sound/gen/`(git 밖)에 두고, `prompts.json`에 파일마다 프롬프트와 시드를 적어 고른 것을 다시 만들 수 있게 한다.

**고른 소리를 게임에 넣기 (`tools/sound/install_title_picks.py`).** 타이틀랩에서 고른 것은 `title_picks.json`에 쌓인다 (`"스타일:순간"` → 파일, 프롬프트, 시드). 이 스크립트가 그 목록을 게임에 맞춘다.
- 한 소리는 제목 하나에 하나다. 줄(subtitle)은 무음이다. 예외는 인장판(seal)의 꼬리표로, 따로 박히는 물건이라 `seal:line.land`(`KIT_T_Seal_LineLand`)가 있다.
- 고른 파일(gen 폴더, `--gen PATH`)을 키트 `media/sound/KIT_T_<스타일>_<순간>.ogg`로 쓴다 (`KIT_T_Stamp_Land`). 가공은 레벨 맞춤(체감 크기)과 5 ms 페이드뿐이고, 자르지 않는다: 후보는 `ai_titles.py`에서 이미 잘렸고, 다시 자르면 천천히 차오르는 소리의 앞이 깎여 정점이 타이틀랩에서 들은 시각과 어긋난다. `build.encode`로 ogg에 쓴다.
- 같은 스크립트가 `kit_sounds.txt`와 `Sound.lua`에 구분선 사이 블록을 생성한다 (`title picks begin` ... `end`). 다시 돌리면 블록만 바뀐다 (`build.py`가 소리 스크립트를 다시 쓸 때도 블록은 남긴다). 고른 것이 빠진 `스타일:순간`은 파일과 항목이 지워지고, 같은 목록·파일·레벨로 다시 돌리면 아무것도 쓰지 않는다 (소리마다 원본 파일, 해시, 레벨이 블록 주석에 있다). gen 폴더에 파일이 없는 고름은 설치된 소리를 그대로 두고, 레벨이 바뀌었으면 설치된 소리 자체에 새 레벨을 준다. `--dry`는 하려는 일만 찍는다.
- 고름이 없는 `스타일:순간`은 소리가 없다. 옛 대용품(RadioZap, UseMatch, UseLighter, LureHitWater)과 타자기 녹음(Erika 5, `KIT_TitleType`·`KIT_TitleFeed`)은 지웠다.
- 타자(type)는 생성음이 아니라 키트 키보드(`kit.terminal`, 사운드랩에서 듣는 것)를 친다 (사용자: AI 후보보다 낫다). `Sound.TITLE_KEYBOARDS`가 스타일을 키보드에 잇고, `Sound.titleSounds`가 API의 `keys`·`space`·`land`(다 친 뒤 엔터)·`feed`(종이 올릴 때마다 엔터)로 넘긴다. 타이밍은 API의 strike: 교신 주인공의 손(초당 14자, 단어마다 ±20%, 띄어쓰기 뒤 0.12초, 절 끝 0.4초), 줄은 제목 뒤 엔터 0.35초 다음에 친다. 퇴장은 0, 0.9, 1.8, 2.7초에 반 줄씩 올라가고 엔터는 갈수록 2 dB씩 작아진다.
- 퇴장 여운은 화면에 맞춘다 (`ai_titles.py`의 fit): 타이틀랩에서 잰 곡선(`title_curves.json`: 보이는 양·움직임)으로, 퇴장이 시작될 때 1에서 다 사라질 때 0까지 음량을 깎고 길이도 그만큼 만든다. 더스트(재가 흩날려 사라질 때까지 9초)와 노티스(신호가 끊기는 4.3초)가 이렇게 만들어졌다.
- 레벨은 스크립트의 `LOUD` 표에 역할로 정한 체감 크기(LUFS, 가장 큰 400 ms, `build.loudness`)다. 처음에는 피크로 맞췄다 (S6의 바닐라 클릭 피크를 기준으로, 2026-10-19 게임 녹음으로 다시 정함). 그런데 타이틀 소리는 타격 뒤 긴 울림이거나 차오름이라 피크가 높아도 들리는 크기는 작았다. 피크로 맞춘 결과 -24~-38 LUFS여서 notice와 brief는 클릭보다 작았고, 단말 부팅을 키운 뒤(S8) 사용자가 "거의 안들리긴하네"라고 했다 (2026-10-20). 그래서 체감 크기 사다리로 다시 정했다: 클릭 약 -31, 단말 줄 출력 -28, 단말 켜짐 -22, 환영 -19.

| 스타일 | 등장·착지·유지 (LUFS) | 퇴장 | 이유 |
| --- | --- | --- | --- |
| seal | -17 (꼬리표 -20) | | 작전 이름, 도토리 100개: 한 판에 한 번씩, 모드에서 가장 큰 순간 |
| bleed | -19 | -27 | 감염 양성, 한 번: 그다음으로 무거운 순간 |
| unveil | -20 | -28 | 새 국면 (3): 드물고 큰 차오름 |
| stamp | -20 | -28 | 등급, 상자 밀봉: 한 판에 몇 번인 업적 |
| sink | -21 | -29 | 상실 (5): 느껴져야 하지만 실패가 소리쳐서는 안 된다 |
| discovery | -21 | -29 | 발견 (8): 사건, 업적보다 조금 아래 |
| pulse | -23 | -31 | 안도 (5): 부드럽게 |
| dust | -23 | -31 | 성장·해금 (10): 잦다 |
| notice | -25 | -33 | 업무 정보 (9, 무전이 연달아 옴): 신호지 사건이 아니다 |
| brief | -27 | -35 | 작고 잦은 피드백: 단말 줄 출력 수준의 틱 |
| type | | | 키트 키보드의 레벨 그대로 (교신 키와 같다). 퇴장의 엔터는 하나마다 2 dB씩 작게 |

퇴장은 꼬리다: 스타일 레벨보다 8 dB 아래. 고른 것은 `title_picks.json`의 14개다 (type은 키보드라 고름이 없다).

**소리를 낸 순간의 볼륨** (2026-10-19). 게임의 UI 소리는 내는 즉시 원래 볼륨으로 시작하고, `setVolume`으로 준 볼륨은 UI 이미터의 다음 틱에 채널에 들어간다. 확장 API는 화면을 그리는 단계에서 소리를 내므로, 다음 틱까지 한 프레임 동안 짧은 소리의 타격음이 원래 볼륨으로 다 나갔다 (타자 퇴장의 엔터가 2 dB씩이 아니라 0.7 dB씩 작아졌다). API는 볼륨을 준 직후 이미터를 한 번 틱해 그 자리에서 들어가게 한다.

**듣는 검수.** 타이틀랩(`lab-audio.js`, `gen/manifest.js`의 목록)이 스타일의 시간대로 후보 소리를 재생하고, 후보마다 따로 들어 보는 ▶가 있다. 사용자가 후보를 바꿔 들으며 고르면, 고른 것을 게임에 넣는다. 레벨은 S6의 기준(바닐라 UI 클릭)에 맞춘다.

### S8. 단말 연출 소리 (2026-10-19)

사용자 지적: 단말의 연출 화면(부팅, 꺼짐, 조립 단말의 간헐적 노이즈)에 소리가 없다. 조립 단말과 정식 단말을 구분할 것.

**두 단말은 두 기계다.** 정식 단말은 2반이 보급한 장비다: 단단한 스위치, 깨끗한 브라운관, 제대로 된 비프. 조립 단말은 주운 부품으로 엮은 약한 신호의 기계다: 덜컥이는 토글, 지글대며 치솟는 잡음, 웅웅대는 변압기, 싸구려 스피커, 그리고 창이 열려 있는 동안 이따금 신호가 약해진다. 화면 연출(`Trade/BootSeq`)도 그렇게 다르다: 조립 단말만 글자가 깨지고, 깜박이고, 흔들리고, '신호 약함 · 재시도' 줄이 있고, 부팅 뒤 14초마다 0.5~1.1초 화면이 흐려진다.

**큰 박자만.** 부팅은 단말을 열 때마다 나온다: 짧고 작게. 소리는 연출의 큰 박자에만 둔다. 글자 하나, 깜박임 하나에는 두지 않는다.

| 큐 (`oa.term.<단말>.<이름>`) | 화면의 순간 | 정식 | 조립 |
| --- | --- | --- | --- |
| power | 전원, 화면이 가운데서 열림 (0.1초부터) | 단단한 스위치와 짧은 브라운관 예열음 | 덜컥 토글, 잡음이 치솟았다 가라앉음 |
| hum (반복) | 부팅 내내 깔리는 바탕. 정적의 세기를 따른다: 화면이 열릴 때 1, 글이 나오는 동안 1/2.2, 접힐 때 함께 줄고 콘솔이 끝나면 멈춤 | 작은 브라운관 웅웅거림 | 지글대는 잡음과 낮은 험 |
| line | 점검 줄의 결과('정상', '확인')가 뜰 때 | 작은 틱 | 거친 틱 |
| jolt | (조립만) 부팅 중 화면이 흔들리는 순간 (0.24초 연속) | | 접촉 불량의 짧은 지직 |
| ready | 밝은 마지막 줄 '환영합니다' | 깨끗한 확인 비프 | 싸구려 스피커의 비프 |
| off | 글이 한 줄로 접혀 점이 될 때 (탭이 나타남), 창을 닫을 때 | 브라운관 꺼짐 | 지직하며 꺼짐 |
| spell (반복) | (조립만) 신호 약화. 화면이 흐려지는 만큼(`fade / WEAK_FADE`) 소리도 | | 끊기고 흔들리는 무선 간섭 |

건너뛰기(클릭)는 꺼짐만 낸다: 건너뛴 사이의 박자는 소리 내지 않는다. 반복음은 게임이 일시정지되면 소리를 0으로 두고(4장 규칙), 풀리면 돌아온다. 단말 탭을 바꾸는 클릭은 키트의 선택음(`kit.select`)이다.

**만들기.** 큐마다 그 순간에 맞는 소리 하나를 만든다 (`tools/sound/ai_terminal.py`, 타이틀과 같은 Stable Audio 3 Medium). 처음에는 타이틀처럼 큐마다 후보 6개를 넓게 뽑아 고르게 했는데, 사용자 지적대로 그건 고르기 위한 생성이라 그 순간을 겨냥한 소리가 아니었다 (프롬프트는 두루뭉술하게 둘을 번갈아, 길이는 화면과 어긋나게, 큐마다 따로라 한 기계로 들리지 않았다). 지금은 이렇게 만든다.
- 프롬프트는 그 순간 하나만 말하고, 길이는 화면의 시간대로 청한다 (BootSeq: 스위치의 어두운 0.1초, 화면이 열리는 0.35초, 1초에 가라앉는 정적; 꺼짐의 0.28초; 덜컥임의 0.24초).
- 화면의 시간 곡선(같은 수치로 10 ms마다 얼마나 큰 순간인지)이 목표다. 시드 8번을 시도해 소리의 크기 곡선이 목표를 가장 잘 따르는 것(두 곡선의 상관, 화면이 끝난 뒤 남는 소리는 뺌)을 남긴다. 정식의 소리는 음이 있는 쪽, 조립의 잡음은 잡음 쪽을 더 친다.
- 한 단말은 한 기계다: 꺼짐은 그 단말의 켜짐 소리에서, 바탕음은 켜짐이 가라앉은 웅웅거림에서, 조립의 덜컥임은 켜짐의 치솟는 잡음에서, 약신호는 바탕음에서 이어 만든다 (오디오에서 오디오로).
- 바탕음은 길게 만들어 가장 고른 구간을 남기고, 끝을 앞에 0.25초 겹쳐 이음새 없이 돈다.
- 가공은 앞 무음 자르기와 화면이 끝나는 곳의 페이드뿐이다. 잡음 큐(조립의 켜짐, 바탕, 덜컥임, 줄, 꺼짐, 약신호)는 클릭 제거를 하지 않는다 (지직임이 소리다).

만든 것은 바로 `install_terminal_picks.py`로 들어간다: `terminal_picks.json`, OA의 `media/sound/OA_Term_<Tier>_<Cue>.ogg`, `oa_sounds.txt`와 `Sounds.lua`의 구분 블록. `build.py`는 소리 스크립트를 다시 쓸 때 이 블록도 남긴다. 시도한 것은 모두 `gen/term/tries/`에, 남긴 것의 프롬프트·시드·맞음 정도는 `gen/term/made.json`에 있다. 단말 랩(`tools/sound/lab/terminal.html`, sound-lab 서버)은 게임의 부팅 계산과 그리기를 그대로 옮겨, 두 단말을 나란히 열고 게임에 들어간 소리를 그 레벨대로 들려준다: 사용자는 듣고 통과시키거나 고칠 곳을 말한다.

**레벨.** 한 번 나는 소리는 가장 큰 20 ms로, 반복음은 평균(RMS)으로 맞추되 가장 큰 20 ms가 그보다 6 dB를 넘지 않게 한다 (지직이는 잡음을 평균으로만 맞추니 튀는 지직이 클릭보다 컸다). 피크로 맞추면 첫 클릭 하나가 튀는 후보가 같은 피크의 다른 후보보다 게임에서 20 dB 작게 들렸다 (2026-10-19, 하나씩 녹음, 키트 클릭은 가장 큰 20 ms -26). 파일의 가장 큰 20 ms는 게임에서 6~9 dB 낮게 나온다.

| 큐 | 정식 | 조립 | 이유 |
| --- | --- | --- | --- |
| power | -26 | -25 | 열 때마다: 클릭보다 7 dB쯤 아래 |
| ready | -29 | -29 | 끝 신호, 켜짐보다 아래 |
| off | -31 | -30 | 넘어가는 소리 |
| jolt | | -30 | 한 부팅에 두세 번 |
| line | -36 | -36 | 줄마다: 아주 작은 틱 |
| hum (RMS) | -40 | -38 | 바탕. 글이 나오는 동안은 여기서 7 dB 더 작다 |
| spell (RMS) | | -34 | 14초마다, 박자들보다 아래 |

## 3. 순서
S1 → S2 → S4 (동작 동일 확인) → S3 (API) → S5 → S6 → 에셋 → 연출 템포 재조정 → 통합 E2E.

## 4. 검토
- **키 소리 연타.** 교신 팀 줄은 초당 28자, 문서는 초당 60~80자다. 글자마다 내면 소리가 뭉개진다. 큐의 `gap`으로 최소 간격을 두고, 그 사이 글자는 소리 없이 지나간다. 값은 에셋을 넣으며 정한다.
- **일시정지.** 교신은 장면 시계(`UI.sceneNow`)로 일시정지에 서고, 서류 타이핑은 실제 시계로 일시정지에도 간다 (읽을 수 있게). 소리는 각자 시계를 따른다: 글자가 나오면 소리도 난다. 반복음(`loop`)만 일시정지에 멈춘다 (바닐라 일시정지 규칙: 덮지 않는다).
- **덕킹 복귀.** 게임이 교신 중에 꺼져도 옵션 값은 바뀌지 않는다 (사운드 매니저 볼륨만 낮췄다). 그대로 둔다.
- **멀티플레이.** 싱글 기준. BU의 서버→클라이언트 소리 명령은 큐 이름을 실어 그대로 둔다.
