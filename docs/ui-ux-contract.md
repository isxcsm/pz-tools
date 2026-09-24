# PzTools UI/UX 및 뷰 계약

이 문서는 WinUI 3 화면과 projection 계층 사이의 초기 계약입니다. UI는 SQLite,
telemetry event와 CLI JSON을 직접 해석하지 않고 `RevisionedViewStore`의 정규화된
뷰만 사용합니다.

## Shell

넓은 창은 다음 3단 구조를 사용합니다.

```text
Navigation | Save list | Save detail
```

- Navigation pane 상단에는 `세이브 관리`와 `로그` 메뉴를 둡니다.
- Settings item은 pane 하단에 둡니다.
- 다음 백업 예정 시각과 countdown은 navigation 영역에 표시합니다.
- operation progress card는 별도 pane footer에 표시합니다.
- 창 폭이 좁으면 목록과 상세를 한 번에 하나씩 표시하고 뒤로 가기를 제공합니다.
- 페이지 이동은 AppHost, Scheduler와 projector 수명에 영향을 주지 않습니다.
- 창은 `MicaBackdrop`을 사용하고, 제목 표시줄·탐색·페이지 배경은 배경 재질을 드러냅니다.
  전체 콘텐츠를 감싸는 테두리와 모서리 라운드는 두지 않습니다. 개별 카드는
  `CardBackgroundFillColorDefaultBrush`와 `CardStrokeColorDefaultBrush`를 사용합니다.
  색상을 흰색으로 고정하지 않고 시스템 테마 리소스를 사용합니다.
- 펼친 탐색 영역은 248 px이며 창 폭에 따라 WinUI `NavigationView`가 자동 축소됩니다.
  제목 표시줄의 기본 창 제어 버튼과 창 끌기는 유지합니다.
- 펼친 탐색 메뉴는 좌우 12 px를 비우고, 하단 설정 항목은 아래에도 10 px를 둡니다.
  `NavigationView`의 기본 콘텐츠 테두리도 제거합니다.
- 페이지 좌우 여백은 24 px입니다. 세이브 목록, 상세 요약, 백업 리비전, 작업 버튼은
  개별 영역으로 구분하며 목록과 상세 사이 간격은 12 px입니다. 로그 필터·목록·상세도
  카드로 구분하고 목록과 상세 사이에 12 px를 둡니다. 카드 테두리는 1 px, 모서리는 8 px입니다.

## 설정 화면

설정은 세로 `ScrollViewer` 안의 Fluent `SettingsCard` 그룹으로 구성합니다.
좌우 여백은 24 px, 그룹 사이는 4 px로 둡니다. 최대 폭에 따른 추가 중앙 정렬 여백은
두지 않습니다. 섹션 제목·설명은 `SettingsExpander.Header`와 `Description`에 표시하고
페이지 제목은 목록과 분리된 고정 헤더에 둡니다. 고정 헤더 아래에는 20 px를 비웁니다.

| 그룹 | 카드 | Control | 기본값 |
|---|---|---|---|
| 일반 | 언어 | 한국어/영어 선택 | 한국어 |
| 일반 | 테마 | 시스템/밝음/어두움 선택 | 시스템 |
| 경로 | 세이브 디렉터리 | 경로와 폴더 선택 | `%UserProfile%\Zomboid\Saves` |
| 경로 | 백업 디렉터리 | 경로와 폴더 선택 | `%UserProfile%\Zomboid\Backups` |
| 백업 | 자동 백업 간격 | 0~60 slider와 NumberBox | 5분 |
| 백업 | 백업 개수 | 1~100 slider와 NumberBox | 100 |
| 백업 | 사망 시 백업 | ToggleSwitch | 꺼짐 |

간격 0은 periodic, final과 death-triggered run을 포함한 모든 자동 백업을 끕니다.
수동 백업은 계속 사용할 수 있습니다. 경로 또는 숫자가 유효하지 않으면 카드 안에
오류를 표시하고 적용하지 않습니다. 관련 설정은 기본 펼침 상태의 `SettingsExpander`로
묶고 각 항목은 `Items` 안의 `SettingsCard`로 표시합니다. 경로 입력은 최대 420 px, 슬라이더·숫자 입력은
최대 340 px로 제한하며 작은 창에서는 카드의 기본 세로 배치와 함께 입력 폭도
줄입니다. 저장 완료 상태 문구는 상시 표시하지 않습니다.

## 화면 밀도와 접근성

- 세이브 목록은 썸네일과 이름을 먼저 보여주고 모드·시각은 보조 정보로 표시합니다.
- 세이브 상세 폭이 520 px보다 작으면 썸네일·메타데이터와 하단 액션을 세로로 배치합니다.
  페이지의 가져오기·백업·복구·내보내기·찾아보기·삭제 버튼은 WinUI `SubtleButtonStyle`로
  통일합니다. 평소에는 텍스트/아이콘만, hover/pressed에서만 반투명 영역을 표시합니다.
  하단 작업 영역도 테두리 없는 반투명 배경을 사용합니다. 비활성 색과 키보드 포커스는
  WinUI 기본 스타일을 유지하며 파괴적 작업의 확인 대화상자는 기존 버튼 스타일을 유지합니다.
- 로그는 고정 폭 5열 표가 아니라 메시지, 구성 요소, 시각·실행 번호 순의 목록입니다.
  전체 실행 번호와 이벤트 코드는 선택한 로그의 상세에서 복사할 수 있습니다.
  페이지 폭이 800 px보다 작으면 목록과 상세를 위아래로 표시합니다.
- 설정 입력과 알림 닫기에는 현재 언어의 접근성 이름을 제공합니다.
- 진행률·로그·상태 데이터는 기존 projector 경로를 유지합니다. 시각적 변경을 위해
  UI에서 데이터베이스를 직접 읽거나 별도 수집 경로를 추가하지 않습니다.
- 정상 `tick.completed`, `collector.completed`, `reactor.completed`, `state-runner.completed`는
  프로젝터에서 추적 수준으로 분류합니다. 기본 정보 수준에서는 숨기지만 원시 telemetry는
  그대로 남으며, 추적 수준을 선택하면 볼 수 있습니다. tick의 실패 결과는 오류,
  busy·저하·취소 및 알 수 없는 outcome은 경고로 유지합니다. 실제 백업 결과 이벤트의
  정보 수준은 낮추지 않습니다.

## 세이브 목록

목록 상단에는 `압축 파일 가져오기` 버튼을 둡니다. 각 목록 항목은 다음 정보를
표시합니다.

- `thumb.png` 또는 placeholder
- 게임 모드
- 세이브명
- 마지막 플레이 시각
- 활성 세이브의 초록색 반투명 플레이 overlay
- 사망 캐릭터의 우측 상단 해골 badge

활성과 사망이 동시에 적용될 수 있습니다. stale 상태는 정보를 제거하지 않고
보조 문구로 표시합니다. 목록 선택은 `save_id`로 유지하며 projector가 소유하지
않습니다.

## 세이브 상세

- 상단 고정 영역에 현재 live save를 표시합니다.
- 아래에는 활성 백업 리비전을 최신순으로 표시합니다.
- 각 백업에는 저장소에 기록된 편집 가능한 이름을 표시합니다. 새 리비전의 기본
  이름은 생성 시점의 설정 언어에 따라 `백업 N` 또는 `Backup N`으로 저장하며,
  이름을 바꿔도 내부 리비전 번호는 유지합니다. 기존 이름 없는 리비전은 앱 시작
  시점의 설정 언어로 한 번 이름을 채웁니다.
- 리비전이 없으면 empty state를 표시합니다.
- 상세 하단에는 sticky `수동 백업`, `복구하기`, `압축 파일로 내보내기` 버튼을
  둡니다.
- `복구하기`와 `내보내기`는 리비전을 선택한 경우에만 활성화합니다.
- 플레이 중인 세이브의 `복구하기`는 비활성화합니다.
- 백업 operation이 활성 상태면 같은 repository의 수동 백업 버튼을
  비활성화합니다.

## Operation과 modal

다른 실행을 배타해야 하는 작업은 modal overlay에서 수행합니다. UI gate와 별개로
CLI 및 Runner의 named mutex가 외부 실행과의 최종 경쟁을 차단합니다.

| 작업 | UI 표시 | 주요 scope |
|---|---|---|
| 자동/수동 백업 | progress card | RepositoryWrite |
| Maintenance | 백업 실행에 포함 | RepositoryWrite |
| 리비전 복구 | 확인 및 진행 modal | RepositoryRead + SaveWrite |
| Archive 내보내기 | 진행 modal + progress card | RepositoryRead |
| Archive 가져오기 | 확인 및 진행 modal | SaveWrite |

내보내기 progress card는 백업 card보다 위에 표시합니다. 진행률은 telemetry를 직접
읽지 않고 `OperationView`만 사용합니다. archive·restore 생산자는 파일마다
누적 상태를 갱신하고 최신 `progress.snapshot`만 주기적으로 기록합니다. 단계 전환과
종료 시 마지막 상태를 먼저 기록하므로 UI는 이 누적값을 그대로 표시합니다.

## Telemetry 표시

```text
telemetry.db
  → TelemetryProjectionHost
  → OperationProgressReducer / TelemetryHealthReducer
  → RevisionedViewStore
  → ViewModel
  → WinUI
```

- `Waiting`: 전체량 조사 중인 indeterminate progress
- `Healthy`: 현재 phase와 가능한 진행률 표시
- `Stale`: 실행은 유지하되 진행 정보 지연 표시
- `Disabled`: 진행 정보 기록 비활성 표시
- `Unreadable`: telemetry를 읽을 수 없다는 오류 표시
- `UnsupportedSchema`: 지원하지 않는 telemetry 형식 표시

작업 실행 상태와 버튼 잠금은 workflow와 process 상태를 사용합니다. telemetry
장애가 발생해도 실행 중 카드를 제거하거나 버튼을 다시 활성화하지 않습니다.

Projector 자체 장애는 pane 하단의 지속 상태 카드로 표시합니다. state projector가
실패하면 복구를, backup projector가 실패하면 복구와 내보내기를 비활성화합니다.
scheduler projector가 실패하면 다음 백업 시각 대신 갱신 불가 문구를 표시합니다.
어느 경우에도 수동 백업은 막지 않습니다. 다음 projection 성공 시 카드는 자동으로
사라집니다.

실행 중 작업 카드는 항상 표시합니다. 성공/변경 없음/Busy는 완료 후 5초 동안 표시한
뒤 사라지고, 실패/취소/성능 저하 카드는 사용자가 닫을 때까지 유지합니다. 종료된
카드는 진행 막대를 숨기고 애니메이션을 중단하며 제목도 완료/실패/취소 등 결과로 바꿉니다.
종료 상태는 마지막 telemetry의 총량 유무나 장애 상태보다 우선합니다.
일시 작업의 telemetry source는 카드 수명이 끝나면 등록 해제하지만 정규화한 metric은
최근 100회 메모리 보존 범위에 남깁니다.

복구 호출은 선택한 리비전의 숫자형 `source_id`를 저장소의 `source_key`로 조회한 뒤
복구 CLI의 `--source-id`에 전달합니다. 이 CLI 인자는 논리 세이브 키를 의미합니다.
원본과 가져온 `(1)` 세이브는 각자 리비전 번호를 가지므로 번호가 같아도 충돌하지 않습니다.

## 로그 화면

로그는 별도 writer나 공유 DB를 두지 않습니다. `TelemetryProjectionHost`가 각
producer의 원시 telemetry를 `LogsView`로 정규화하고 UI는 이 뷰만 읽습니다.
파일 단위 완료 이벤트와 heartbeat처럼 빈도가 높은 진단 이벤트는 로그 목록에서
제외합니다. 항목 식별자는 `(source_id, telemetry_instance_id, event_id)` 조합이며
원문 payload는 상세 화면의 구조화 데이터로 제공합니다.

목록은 최신순이며 로그 화면 상단에서 최소 로그 레벨과 표시 개수(100~10,000개)를
직접 변경합니다. 별도 설정 페이지의 로그 카드는 두지 않습니다. 변경은 즉시 반영하고
앱 설정에 자동 저장하며, 백업 설정 파일이나 스케줄러 상태를 변경하지 않습니다.
최소 레벨 이상의 로그를 대상으로 component와 `run_index`로 추가 필터링합니다. 선택한
항목은 시간, component, 실행 번호, 이벤트 코드와 payload를 표시합니다. 이벤트
상세의 기본 정보와 구조화 데이터는 16 px 간격의 별도 카드로 나누고 카드 내부에는
20 px 여백을 둡니다. 구조화 데이터 제목과 본문 사이에는 16 px, 데이터 편집 영역
내부에는 12 px를 비우며 읽기 전용 데이터의 선택·복사·스크롤을 유지합니다. 이벤트
코드와 payload는 보존하고 사용자 문구만 현재 UI 언어로 변환합니다. telemetry DB가
읽히지 않거나 지원하지 않는 스키마이면 해당 source의 오류 행을 로그에 추가합니다.
원시 로그 보존과 trim은 계속 producer 설정의 책임이며 앱 설정의 표시 개수는
projection 결과의 최근 항목 수만 제한합니다.

## Archive 흐름

가져오기는 file picker, inspect, 확인 modal, import 순서로 진행합니다. inspect에
성공하면 thumbnail, 게임 모드, 세이브명과 마지막 플레이 시각을 표시합니다.
확인 창은 최대 폭 720 px이며 180 px 정사각형 썸네일 오른쪽에 이름과 메타데이터를
배치합니다. 본문 폭이 480 px 미만이면 세로 배치로 전환하며 열린 상태의 창 크기 변경도
반영합니다. 썸네일이 없으면 빈 이미지 열을 남기지 않습니다.
가로 배치에서는 빈 행 간격을 제거해 제목과 썸네일 사이 및 썸네일 아래 여백을 각각
24 px로 맞춥니다. 하단 기본 버튼은 약 128 px씩, 사이 간격 8 px로 오른쪽에 모으고
명령 영역의 세로 여백은 16 px로 둡니다. 취소 기본 선택과 기본 키보드 동작은 유지합니다.
Project Zomboid archive가 아니거나 손상됐으면 import 전에 거부합니다. 동일한
모드와 세이브명이 있으면 `세이브명(1)`, `세이브명(2)` 순으로 이름을 정합니다.
새 ZIP의 게임 파일 경로는 `게임모드/세이브명/파일`이며, 가져올 때는 해당
세이브 폴더만 대상 `Saves/게임모드` 아래로 이동합니다. 기존 루트 파일 형식(v1)도
계속 가져올 수 있습니다.

가져오기 성공 후에는 다음 정기 수집 주기를 기다리지 않고 기존 state runner를 즉시
실행합니다. 전역 실행 번호와 StateCollection mutex를 유지하며 Busy이면 제한된 횟수로
재시도합니다. 그 후 state → backup → details 순으로 정기 projector와 직렬화하여
즉시 투영하고 UI 목록을 적용한 뒤 완료 메시지를 표시합니다. 갱신 실패는 작업 실패와
구분해 이미 가져온 파일을 다시 가져오지 않도록 안내합니다. 세이브 삭제에도 같은
재수집 경로를 사용하며, 리비전 삭제는 재수집 없이 관련 뷰만 즉시 갱신합니다.

상세의 `현재 세이브 및 백업` 목록은 현재 세이브를 맨 위에 두고 기본 선택합니다.
이후 백업 리비전을 최신순으로 표시하며 주기적인 뷰 갱신에서는 사용자의 선택을 유지합니다.
각 백업 항목에는 `마지막 플레이`와 `기록 시간`을 별도 줄로 표시합니다. 마지막 플레이는
해당 리비전 카탈로그에 보존된 루트 `players.db` 수정 시각이며 파일이 없으면 `알 수 없음`입니다.
현재 파일 시각이나 백업 생성 시각으로 대체하지 않습니다. 기록 시간은 리비전 생성 시각입니다.
두 시각 모두 로컬 시간으로 표시하며 현재 세이브 항목에는 마지막 플레이만 표시합니다.
현재 세이브 선택 시 복구는 비활성화하고 내보내기는 실제 세이브 폴더를 대상으로 합니다.
백업 리비전 선택 시 기존 리비전 복구·내보내기 동작을 유지합니다.

현재 세이브 내보내기는 백업을 생성하거나 저장소의 리비전을 변경하지 않습니다.
플레이 중이거나 state projector 장애 시 비활성화합니다. archive worker의 `export-live`는
SaveWrite mutex를 획득하고 임시 폴더에 파일을 복사한 뒤 기존 형식으로 압축합니다.
복사 전·후 및 최종 출력 교체 직전에 경로·파일 크기·수정 시각을 비교하고 변경을 감지하면
중단합니다. reparse point와 세이브 내부 출력 경로는 거부합니다. 이는 게임 프로세스의
원자적 스냅샷을 보장하지 않으므로 플레이를 종료한 상태에서 사용합니다.
현재 세이브의 manifest는 sourceId와 revision을 모두 0으로 기록합니다(백업 리비전 아님).
실패 시 기존 출력 파일은 유지하며 이 작업의 임시 복사본과 불완전한 ZIP은 정리합니다.
복사/임시 복원과 압축 진행 상태는 archive producer telemetry의 정규화된
`OperationView`로 표시합니다.

## 삭제

세이브 목록 및 백업 리비전 행 오른쪽에 삭제 버튼을 둡니다. 현재 세이브 행에는 중복
삭제 버튼을 두지 않습니다. 두 목록 모두 16 px 아이콘과 40×40 px 클릭 영역을 사용하고,
버튼 오른쪽에 8 px 추가 여백을 두며 행의 세로 중앙에 정렬합니다. hover 배경은 유지합니다.
확인 창은 대상 이름·경로 또는 리비전 번호와 영향 범위를
표시하고 기본 버튼은 취소입니다. 진행 중인 작업이나 관련 projector 장애가 있으면
삭제를 차단합니다. 세이브 상태가 오래됐거나 플레이 중/상태 불명이면 원본 삭제도 차단합니다.

세이브 삭제는 해당 세이브의 모든 백업 리비전을 삭제 마킹하고 정확히
`SavesRoot/Mode/Name` 폴더와 하위 파일을 영구
삭제합니다. 휴지통이나 별도 보관 폴더로 이동하지 않으며 확인 창에서 되돌릴 수 없음을
명시합니다. 경로 이탈·reparse point·players.db 누락·사용 중인 파일·읽기 전용 파일은
삭제 전에 거부합니다. 사전 검증 이후 OS 오류로 중단되면 일부 파일은 이미 삭제됐을 수
있습니다. 기존 버전이 만든 보관 폴더는 자동으로 비우지 않습니다. 실제 사용자 세이브는
자동 테스트에서 삭제하지 않으며 임시 테스트 픽스처만 사용합니다.
백업 삭제는 선택한 세이브 키와 저장소에 등록된 경로가 일치할 때만 수행하며,
다른 세이브의 백업과 이미 내보낸 외부 압축 파일은 건드리지 않습니다.
writer lease 아래에서 전체 백업 삭제 마킹을 미확정 트랜잭션으로 준비하고 폴더 삭제 후
확정합니다. 폴더 삭제 실패 시 마킹은 롤백합니다. 파일 시스템과 DB를 하나의 원자적
트랜잭션으로 묶을 수 없으므로 폴더 삭제 후 DB 확정 실패는 별도의 부분 실패로 안내합니다.
삭제 마킹된 백업의 물리 정리는 기존 점검기·내부 증분 기준 보존 정책을 따릅니다.

리비전 삭제는 repository writer lease와 작업 mutex 아래에서 기존 `MarkRevisionDeletedAsync`를
사용합니다. 최신/마지막 리비전도 삭제할 수 있으며 사용자 백업 목록이 비어도 됩니다.
삭제된 최신 리비전은 내부 증분 기준으로만 유지하고 삭제 마킹 즉시 화면에서 제외합니다.
삭제 리비전은 복구·내보내기 대상에서 제외하며 pack/object를 직접 제거하지 않습니다.
실제 공간 회수는 유지보수가 처리합니다. 화면 갱신은 기존 state/backup projector를 따릅니다.

## 초기 뷰 경계

- `SettingsView`: 유효 설정과 설정 오류
- `SaveListView`: 목록에 필요한 현재 세이브 요약
- `SaveDetailView(save_id)`: live save와 백업 리비전 목록
- `ScheduleStatusView`: 자동 활성 여부, target, mode, next due와 마지막 결과
- `OperationView(operation_id)`: 실행 상태, telemetry health와 진행률
- `MetricsView(producer)`: 보존 범위의 정규화된 metric
- `TelemetrySourceView(component, identity)`: producer DB health
- `LogsView`: 정규화된 최근 로그와 구조화 payload
- `ProjectorHealthView`: projector별 정상/장애 상태와 버튼 안전 정책

각 뷰는 session-local `view_revision`을 가지며 의미 있는 snapshot 변경에서만
증가합니다. UI selection, hover, focus와 countdown은 projection revision에
포함하지 않습니다.
