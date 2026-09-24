# PzTools 앱 본체 구현 로드맵

이 문서는 완료된 헤드리스 백업·상태 기반 위에 PzTools 앱 본체를 구축하기 위한
작업 계획입니다. 기존 프로세스 구현 로드맵은 제거하고, 지금부터 필요한 Scheduler
재설계, projection 계층, WinUI 3 화면, 수동 작업과 압축 파일 가져오기·내보내기까지
하나의 작업 범위로 다시 정의합니다.

이번 로드맵은 다음 상태에서 완료됩니다.

- 앱 실행 중 상태 수집과 현재 플레이 세이브 자동 백업이 동작합니다.
- 앱 종료 시 앱이 시작한 Scheduler, Runner와 worker도 모두 종료됩니다.
- 한국어·영어, 시스템·밝음·어두움 테마와 합의된 설정 화면을 제공합니다.
- 세이브 목록과 현재 세이브·백업 리비전 상세 화면을 제공합니다.
- 수동 백업, 리비전 복구, 압축 파일 가져오기·내보내기를 UI에서 실행할 수 있습니다.
- 진행률과 metrics는 각 producer의 telemetry에서만 파생됩니다.
- 뷰별 메모리 snapshot과 revision을 통해 UI가 변경된 뷰만 갱신합니다.
- 실제 Project Zomboid 표본을 포함한 종단 테스트와 Release 검증을 통과합니다.

Windows 서비스, 트레이 상주, 앱 종료 후 자동 백업과 로그인 자동 시작은 이번 범위가
아닙니다.

## 현재 구현 기준선

다음 기능은 구현과 자동 검증이 끝난 기반선이며 다시 구현하지 않습니다.

- 일회성 초기 백업과 USN 기반 증분 백업
- USN 경계가 유효하지 않을 때 전수조사 폴백
- 캡처 실패 시 리비전을 생성하지 않는 안정적 파일 캡처
- 불변 팩, SQLite 리비전 카탈로그, 전체 논리 snapshot 재구성
- 복원과 저장소 검증
- Retention, 삭제 리비전 병합, 객체 GC와 선택적 팩 compaction
- Backup, Maintenance, 상태 Collector/Reactor와 각 Runner
- `state_revision` 기반 Project Zomboid 현재 상태 projection
- producer별 독립 `default.toml`과 `telemetry.db`
- Scheduler, Runner와 worker 사이의 `run_index` 전파
- named mutex, writer lease와 kill-on-close Job Object 기반 프로세스 안전장치

현재 구현의 per-save Scheduler job과 `save-path → job-id` 매핑은 새로 확정한 실행
모델과 충돌합니다. 이 부분은 UI 연결 전에 제거합니다.

## 확정 정책

### 앱과 프로세스 수명

- WinUI 앱 프로세스가 전체 도구의 최상위 owner입니다.
- 창을 닫아 앱이 종료되면 StateScheduler, BackupScheduler와 실행 중인 모든 자식도
  종료합니다.
- 정상 종료에서는 먼저 취소를 전달하고 제한된 정리 시간을 준 뒤 Job Object를
  닫습니다.
- 앱 충돌이나 강제 종료에서도 Job Object가 자식 프로세스 트리를 정리합니다.
- 메뉴 및 페이지 이동은 Scheduler 수명에 영향을 주지 않습니다. Scheduler와
  projection loop는 Page나 ViewModel이 아니라 애플리케이션 전역 `AppHost`가
  소유합니다.
- 앱이 꺼진 뒤 동작하는 서비스, 별도 daemon과 tray-only host는 만들지 않습니다.
- 앱이 필요한 권한으로 시작되고 자식은 부모의 권한을 상속합니다. worker별 권한
  상승 프롬프트는 만들지 않습니다.
- AppHost는 Scheduler의 예기치 않은 종료를 감지해 제한된 횟수와 backoff로
  재시작합니다. 반복 실패 시 무한 재시작하지 않고 해당 Scheduler를 `Faulted`로
  표시합니다.

### BackupScheduler의 단일 동적 대상

- BackupScheduler는 세이브별 영속 job 목록을 갖지 않습니다.
- Scheduler의 주 대상은 현재 플레이 중인 세이브 하나입니다. 종료된 세이브의
  final backup은 별도 pending command로 순서를 보존합니다.
- `Inactive → Active` 전이가 확정되면 해당 세이브를 `current_target`으로 설정하고
  `Continuous`로 실행합니다.
- `Active → Inactive` 전이가 확정되면 직전 대상을 유지한 채 `Limited(1)`로 전환해
  final backup을 한 번 시도합니다.
- final backup의 worker가 실제로 시작돼 attempt가 소비되면 Scheduler는
  `Paused`로 전환하고 대상을 해제합니다.
- final backup 전에 같은 세이브가 다시 활성화되면 `Continuous`로 복귀합니다.
- 다른 세이브가 활성화되면 새 세이브로 대상을 교체하며 이전 세이브의 확정 종료
  전이가 있다면 그 final backup 명령을 pending queue에서 한 번 처리합니다.
- 정확히 하나의 활성 세이브를 판정할 수 없을 때 임의 대상을 선택하지 않습니다.
  기존 target이 활성 후보에 포함되면 유지하고, 그렇지 않으면 상태를
  `Ambiguous`로 표시한 채 새 자동 백업을 admission하지 않습니다.
- 세이브가 목록에 존재한다는 이유만으로 자동 백업하지 않습니다.
- StateReactor 명령에는 `save_id`, 정규화 경로, transition ID와 원인
  `state_run_index`를 포함합니다.
- `save_id`는 Saves root 기준의 `게임 모드/세이브 디렉터리` 상대 경로를 Windows
  대소문자 비구분 규칙으로 정규화한 내부 key입니다. 표시 이름이나 목록 index를
  식별자로 사용하지 않습니다. 디렉터리 이름이 바뀌면 새 세이브로 취급합니다.
- repository의 source는 Scheduler job이 아닙니다. 해당 세이브를 처음 백업할 때
  내부 source 메타데이터를 생성하거나 재사용합니다.
- source 경로와 ID는 Scheduler가 CLI 인자로 전달하며 부모 TOML을 자식에게
  전달하지 않습니다.
- 자동 백업 활성 여부는 target과 mode에서 분리된 권위 설정입니다. 간격 0에서는
  State 명령이 target을 갱신할 수 있지만 periodic, final과 death run을 admission하지
  않습니다.
- 백업이 `Succeeded` 또는 `NoChange`일 때만 같은 실행 흐름에서 Maintenance를
  호출합니다.

### 수동 작업과 배타 제어

- 수동 백업, 복구, 가져오기와 내보내기는 UI의 `OperationCoordinator`를 통해
  시작합니다.
- 다른 실행을 차단해야 하는 작업은 모달로 표시하고 관련 버튼을 비활성화합니다.
- UI 상태는 편의 장치일 뿐 최종 안전장치가 아닙니다. 각 CLI와 Runner도 정규화한
  repository 또는 save identity의 named mutex를 획득합니다.
- operation scope는 `RepositoryWrite`, `RepositoryRead`, `SaveWrite`로 구분하고 여러
  scope가 필요한 작업은 항상 같은 순서로 획득해 교착을 피합니다.
- 영속 PID row, `is_running` flag와 고아 처리가 필요한 논리 lock은 만들지 않습니다.
- 플레이 중인 세이브에는 `복구하기`를 제공하지 않습니다.
- 작업 중 앱이 종료되면 자식도 종료하며 staging 산출물은 다음 시작 또는
  각 producer의 시작 복구에서 정리합니다. repository staging만 Maintenance의
  정리 대상입니다.

### Telemetry, 진행률과 metrics

- producer는 원시 telemetry를 발생 단위로 자신의 독립 SQLite DB에 기록합니다.
- 진행률 전용 파일, IPC progress server와 별도 누적 counter 저장소를 만들지
  않습니다.
- `TelemetryProjectionHost`가 각 DB를 한 번 읽고 같은 이벤트 스트림을 여러
  reducer에 전달합니다.
- AppHost의 `TelemetrySourceCatalog`가 component, identity, 설정 경로와 현재
  workflow를 등록합니다. projector가 파일시스템 전체를 추측해 탐색하지 않습니다.
- `OperationProgressReducer`는 작업 단계, 완료 파일 수, 전체 파일 수, 완료 바이트와
  전체 바이트를 계산합니다.
- `MetricsReducer`는 처리량, 단계별 시간, 오류 수와 실행 결과 통계를 계산합니다.
- `TelemetryHealthReducer`는 `Waiting`, `Healthy`, `Stale`, `Disabled`, `Unreadable`,
  `UnsupportedSchema`를 구분합니다.
- 실행 중 여부와 버튼 잠금은 workflow 및 자식 프로세스 수명으로 판단합니다.
  진행 정도만 telemetry에서 판단합니다.
- 작업은 실행 중이지만 telemetry가 손상되거나 지연되면 진행 카드를 유지한 채
  `실행 중이지만 진행 정보를 확인할 수 없습니다`를 표시합니다.
- telemetry 실패는 백업, 복구, Maintenance와 archive 작업의 성공 여부를 바꾸지
  않습니다.
- 각 telemetry DB는 재생성을 식별하는 `telemetry_instance_id`를 가집니다. cursor는
  instance ID와 `event_id`를 함께 저장해 DB 교체 후 낮아진 ID도 놓치지 않습니다.
- UI에 필요한 진행률 때문에 원시 event를 1초 집계값으로 바꾸지 않습니다. 실제
  병목이 측정되기 전에는 producer에서 sampling하거나 합치지 않습니다.

### Projection과 뷰 revision

- projection 출력은 영속 캐시가 아니라 앱 프로세스 메모리에 둡니다.
- 앱 시작 시 권위 DB와 보존된 telemetry에서 다시 구성합니다.
- projector는 입력 cursor를 소유하고 불변 snapshot을 `RevisionedViewStore`에
  게시합니다.
- 각 `ViewKey`는 독립적인 단조 증가 `view_revision`을 가집니다.
- `view_revision`은 앱 session 범위의 메모리 식별자이며 앱 재시작 후 1부터 다시
  시작할 수 있습니다. 영속 변경 감지는 각 원본 DB revision과 telemetry cursor가
  담당합니다.
- snapshot의 의미가 같으면 revision을 증가시키지 않습니다.
- UI는 자신이 마지막으로 적용한 revision과 다를 때만 해당 뷰를 다시 읽습니다.
- 초기 구현은 뷰 단위 전체 snapshot 교체를 사용합니다. 행 단위 patch protocol은
  실제 성능 문제가 확인되기 전에는 만들지 않습니다.
- 서로 다른 SQLite DB를 하나의 projector에서 직접 조인하지 않습니다. 각 DB의
  snapshot을 만든 뒤 composer가 메모리에서 조합합니다.
- 선택한 세이브와 선택한 revision 같은 사용자 선택 상태는 projector snapshot에
  넣지 않고 ViewModel이 stable ID로 소유합니다.
- projection loop는 UI thread 밖에서 실행하고 최종 ViewModel 적용만
  `DispatcherQueue`를 사용합니다.

### 설정

- 앱 UI 전용 설정도 자체 `default.toml`을 가집니다.
- 언어는 한국어와 영어를 지원합니다.
- 테마는 시스템, 밝음, 어두움을 지원합니다.
- 기본 세이브 경로는 `Environment.SpecialFolder.UserProfile`을 기준으로
  `Zomboid\Saves`를 구성합니다.
- 기본 백업 저장소 경로는 같은 기준으로 `Zomboid\Backups`를 구성합니다.
- 기본 백업 경로 하나를 여러 세이브 source가 함께 사용하는 단일 repository root로
  취급합니다. 세이브마다 별도 repository 디렉터리를 만들지 않습니다.
- 자동 백업 간격은 0~60분 정수이며 기본값은 5분입니다. 0은 자동 백업
  비활성화입니다.
- 간격 0은 periodic, final과 death-triggered backup을 포함한 모든 자동 실행보다
  우선합니다. 수동 백업은 계속 사용할 수 있습니다.
- 활성 리비전 보존 개수는 1~100이며 기본값은 100입니다.
- 사망 시 즉시 백업은 토글이며 기본값은 비활성화입니다.
- 사망 백업이 활성화되면 확정된 `Alive → Dead` transition에 대해 동일 대상의 다음
  due를 즉시 당깁니다. 같은 transition은 idempotency key로 한 번만 반영합니다.
- UI 설정 서비스는 각 component의 설정 또는 권위 Scheduler 상태를 명시적으로
  갱신합니다. 런타임에 부모 설정 파일을 자식에게 암묵적으로 전달하지 않습니다.

### 초기 UI 구조

```text
메뉴 | 세이브 목록 | 세이브 상세
설정 |             |
```

- 왼쪽 메뉴에는 우선 `저장`만 둡니다.
- 메뉴 아래에는 활성 대상의 다음 백업 예정 시각과 남은 시간을 표시합니다.
- 남은 시간은 `next_due_utc`에서 UI가 계산하며 초마다 새 projection revision을
  만들지 않습니다.
- 메뉴 하단에는 실행 중 작업의 진행 카드를 표시합니다.
- 내보내기 카드가 백업 카드보다 위에 표시되며 작업 종류별로 독립 표시할 수
  있습니다.
- 목록 상단에는 `압축 파일 가져오기` 버튼을 둡니다.
- 목록 항목에는 `thumb.png`, 게임 모드, 세이브명과 마지막 플레이 시각을
  표시합니다.
- 활성 세이브 thumbnail에는 초록색 반투명 플레이 overlay를 표시합니다.
- 사망 캐릭터 세이브에는 thumbnail 우측 상단에 해골 badge를 표시합니다.
- 상세 상단에는 현재 세이브를, 아래에는 활성 백업 리비전을 최신순으로
  표시합니다.
- 상세 하단에는 sticky `수동 백업`, `복구하기`, `압축 파일로 내보내기` 버튼을
  둡니다.
- `복구하기`와 `내보내기`는 백업 리비전을 선택했을 때만 활성화합니다.
- 창 폭이 좁으면 목록 선택 후 상세 페이지로 이동하는 적응형 레이아웃을
  사용합니다.

### Archive 가져오기와 내보내기

- archive 기능은 `PzTools.Zomboid.Archive` 라이브러리와 일회성
  `PzTools.Zomboid.Archive.Cli`로 구현합니다.
- Scheduler와 Runner를 추가하지 않습니다.
- 내보내기는 선택한 리비전을 임시 디렉터리에 복원하고 manifest를 추가한 뒤
  압축합니다. Backup worker를 다시 호출하지 않습니다.
- `inspect`는 전체 압축을 풀지 않고 manifest와 thumbnail을 읽어 UI 확인창에
  제공합니다.
- import는 staging 디렉터리에 압축을 풀고 path traversal, 형식 버전, 필수 marker와
  manifest를 검증한 뒤 최종 Saves 위치로 이동합니다.
- 동일한 세이브명이 있으면 대소문자를 구분하지 않고 `세이브명(1)`,
  `세이브명(2)` 순으로 사용 가능한 이름을 선택합니다.
- 손상됐거나 Project Zomboid archive가 아닌 입력은 최종 Saves 디렉터리를 변경하기
  전에 거부합니다.
- import/export producer도 자체 telemetry DB와 기본 설정을 가지며 진행 카드는
  이 telemetry를 projection해서 표시합니다.

## 프로젝트 구성

새 프로젝트는 책임을 과도하게 쪼개지 않고 다음 단위로 추가합니다.

```text
PzTools.Projections
  projection runtime, view store, telemetry/state/backup/scheduler projector

PzTools.App.Core
  AppHost, 설정, OperationCoordinator, 프로세스 수명과 ViewModel용 application service

PzTools.App
  unpackaged x64 WinUI 3 화면, resource, theme, navigation과 binding

PzTools.Zomboid.Archive
  archive manifest, inspect, export, import와 검증

PzTools.Zomboid.Archive.Cli
  일회성 archive 프로세스 계약
```

projector마다 별도 `.csproj`를 만들지 않습니다. 하나의 projection 프로젝트 안에서
입력 책임별 클래스를 분리하고 공통 cursor, health, revision store를 재사용합니다.

## 초기 뷰 계약

```text
SettingsView
  language, theme, saves_root, backup_root, interval_minutes,
  retained_revisions, backup_on_death

SaveListView
  revision, saves[]
  save: save_id, mode, name, last_played_utc, thumbnail_key,
        activity, character_state, freshness

SaveDetailView(save_id)
  live_save, backup_revisions[]

BackupRevisionView
  revision, created_utc, logical_size, file_count, status, thumbnail_key

ScheduleStatusView
  mode, current_target, next_due_utc, last_run_index, last_outcome

OperationView
  operation_id, kind, run_index, status, phase,
  completed_items, total_items, completed_bytes, total_bytes,
  telemetry_health, message

MetricsView
  producer, window, run_count, success_count, failure_count,
  bytes_processed, throughput, phase_durations

TelemetrySourceView
  component, identity, instance_id, health, last_event_utc, message
```

thumbnail byte 배열 전체를 일반 view snapshot에 넣지 않습니다. `thumbnail_key`를
통해 별도 cache와 stream provider가 이미지를 제공합니다.

## 작업 단위 요약

| ID | 작업 단위 | 의존성 | 완료 결과 |
|---|---|---|---|
| A01 | UI/UX와 뷰 계약 확정 | - | 화면 상태, 동작, empty/error/loading 상태 명세 |
| A02 | 단일 동적 대상 Scheduler 재설계 | A01 | per-save job 제거, 활성 대상 자동 백업과 final backup |
| A03 | 권위 DB change revision과 읽기 API | A02 | repository/scheduler 변경 감지와 최적 읽기 |
| A04 | UI용 telemetry 이벤트 계약 보강 | A01 | 진행률·health·metrics를 계산할 원시 이벤트 |
| A05 | Projection runtime | A03-A04 | cursor, reducer, `RevisionedViewStore` |
| A06 | State·Backup·Scheduler projector | A05 | 목록, 상세, 다음 백업 메모리 뷰 |
| A07 | Telemetry projector와 reducer | A04-A05 | 진행률, health와 metrics 메모리 뷰 |
| A08 | 리비전 파일 직접 읽기와 thumbnail cache | A03 | 팩 전체 해제 없는 `thumb.png`·선택 파일 읽기 |
| A09 | AppHost, 설정과 프로세스 수명 | A02, A05 | 앱 수명에 묶인 Scheduler와 background projection |
| A10 | WinUI 3 Shell과 설정 화면 | A01, A09 | navigation, i18n, theme, 설정 적용 |
| A11 | 세이브 목록과 상세 화면 | A06, A08, A10 | thumbnail, overlay, badge와 revision history |
| A12 | 수동 백업과 복구 | A07, A09, A11 | 모달 배타 실행, 진행 카드와 결과 처리 |
| A13 | Archive 라이브러리와 CLI | A04, A08 | inspect/import/export와 안전 검증 |
| A14 | Archive UI 연결 | A07, A11-A13 | picker, 확인창, 충돌 이름과 진행 카드 |
| A15 | 종단 검증과 완료 | A01-A14 | 실제 표본, 장애·수명·UI·Release 검증 |

## 구현 상태 (2026-09-22)

- A01~A14: 구현 및 자동 검증 완료
- A15: Debug/Release 173개 전체, 관리자 권한 USN, 실제 생존·사망 표본, 게시
  프로세스·앱 종료 수명과 장애 fixture 검증 완료
- A15 잔여: 네이티브 WinUI 육안 및 실제 플레이 흐름 확인 결과 기록

명령, 결과와 남은 수동 확인 절차는
[`verification-report.md`](verification-report.md)에 기록합니다. 잔여 실장 검증 전에는
로드맵 전체를 완료로 표시하지 않습니다.

## 상세 작업 계획

### A01 - UI/UX와 뷰 계약 확정

- 3단 레이아웃의 정상, loading, empty, stale와 error 상태를 wireframe으로
  정의합니다.
- 저장 목록 미선택, 세이브 없음, 백업 없음과 thumbnail 없음 상태를 정의합니다.
- 버튼별 활성화 조건과 modal operation matrix를 작성합니다.
- 활성 세이브, 사망 세이브, stale 세이브의 overlay 우선순위를 정합니다.
- 한국어·영어 문자열 key를 먼저 고정하고 코드에 사용자 표시 문자열을 직접
  넣지 않습니다.
- 각 화면이 소비하는 view snapshot과 revision 경계를 확정합니다.
- UI는 DB schema, CLI JSON과 telemetry row를 직접 해석하지 않는다는 경계를
  명시합니다.

### A02 - 단일 동적 대상 Scheduler 재설계

- `backup_jobs`, `job_id`와 정적 `save-path → job-id` 매핑 의존을 제거합니다.
- Scheduler DB를 `current_target`, mode, remaining attempts, interval,
  `next_due_utc`, automatic enabled, pending final queue, generation과 command inbox
  중심으로 migration합니다.
- 기존 개발 DB를 전진 migration하되 per-save job row를 자동 실행 대상으로
  변환하지 않습니다.
- StateReactor outbox가 `ActivateTarget`, `FinalizeTarget`, `ClearTarget`,
  `RunOnceNow` 명령을 생성하게 합니다.
- 명령은 transition ID 기반 idempotency key를 유지합니다.
- BackupScheduler가 target의 source key와 경로를 BackupRunner에 명시적인 CLI
  옵션으로 전달하게 합니다.
- 첫 백업에서 repository source를 만들고 이후 동일 source를 재사용합니다.
- 활성 대상만 주기 실행하며 inactive 목록 전체를 순회하지 않는지 검증합니다.
- 활성, 종료, final backup 전 재활성, A에서 B로 전환과 `Busy`를 종단 테스트합니다.
- A 종료와 B 시작이 같은 상태 batch에 들어와도 A final 명령을 잃지 않고 B를
  장기 target으로 유지하는지 검증합니다.
- interval 0에서 모든 상태 명령을 처리하되 자동 run은 하나도 admission하지 않는지
  검증합니다.
- 사망 백업 설정이 꺼졌을 때는 transition만 기록하고, 켜졌을 때는 동일 target의
  due를 한 번만 즉시 당기는지 검증합니다.

### A03 - 권위 DB change revision과 읽기 API

- repository에 UI-visible metadata commit마다 증가하는
  `repository_change_revision`을 추가합니다.
- scheduler DB에 대상, mode, due와 결과가 의미 있게 바뀔 때만 증가하는
  `scheduler_revision`을 추가합니다.
- Maintenance 내부 진행처럼 UI 출력에 영향이 없는 변경은 불필요한 revision을
  만들지 않습니다.
- reader는 `last_seen_revision`을 받아 같으면 `NotModified`, 다르면 하나의 read
  transaction에서 새 revision과 snapshot을 반환합니다.
- 세이브 source별 활성 리비전 목록, 생성 시각, 논리 크기, 파일 수와 상태를 읽는
  전용 read model을 추가합니다.
- UI reader가 writer lease를 획득하거나 recovery mutation을 실행하지 않게 합니다.
- 동일 데이터 반복 읽기, 동시 commit과 Maintenance 경계에서 일관된 snapshot을
  검증합니다.

### A04 - UI용 telemetry 이벤트 계약 보강

- 모든 event에 schema version, producer, scope, `run_index`, event sequence, UTC,
  monotonic elapsed와 versioned payload를 유지합니다.
- telemetry metadata에 DB format version, `telemetry_instance_id`, producer와 생성
  시각을 기록합니다.
- Backup과 restore에 workload discovered, item started/completed, bytes read/written,
  phase started/completed와 heartbeat event를 추가합니다.
- Maintenance는 lane started/completed와 처리한 revision/object/pack 수를 남깁니다.
- Archive inspect/import/export도 같은 operation event vocabulary를 사용합니다.
- 전체량을 아직 모르는 단계는 total을 추측하지 않고 unknown으로 남깁니다.
- event는 실제 처리 사실만 기록하며 UI percentage를 producer가 계산해 저장하지
  않습니다.
- heartbeat는 실행 중 operation에만 기록하며 idle DB의 event 부재를 장애로
  간주하지 않습니다.
- telemetry DB가 unreadable, disabled 또는 schema 불일치인 fixture를 만듭니다.
- projector는 한 주기에 여러 event page를 소비해 backlog를 따라잡고, producer DB에서
  retention으로 제거된 run은 operation 및 metric 메모리에서도 제거합니다.
- raw event 비용을 Release profile로 측정하되 합의대로 현재 단계의 CI 성능 실패
  기준은 두지 않습니다.

### A05 - Projection runtime

- `ViewKey`, `RevisionedView<T>`, immutable snapshot과 `ReadIfChanged` 계약을
  구현합니다.
- 동일 snapshot 재게시에서 revision이 증가하지 않도록 semantic comparer를 둡니다.
- projector별 cursor와 cancellation 가능한 background loop를 구현합니다.
- 한 projector 실패가 다른 projector와 UI thread를 중단하지 않게 health를
  분리합니다.
- subscriber 등록 해제와 AppHost 종료 시 모든 loop가 정리되는지 검증합니다.
- UI 적용 중 새 revision이 도착해도 오래된 snapshot이 최신 값을 덮지 않게 합니다.
- `view_revision`이 session-local이라는 계약과 UI selection이 ViewModel 책임임을
  테스트합니다.
- 시작 시 빈 메모리에서 DB snapshot을 재구성하는 테스트를 작성합니다.

### A06 - State·Backup·Scheduler projector

- `StateProjector`가 `state_revision`을 따라 `SaveListView`를 만듭니다.
- 게임 모드는 Saves root의 상대 경로, 세이브명은 세이브 디렉터리 이름으로
  정규화합니다.
- 마지막 플레이 시각은 상태 수집 시 정의한 세이브 write marker의 UTC mtime을
  저장하고 표시합니다. 초기 marker는 `players.db`의 `LastWriteTimeUtc`로 고정하며
  파일이 없거나 읽을 수 없으면 값을 추측하지 않습니다.
- `BackupProjector`가 repository revision을 따라 source별 백업 history를 만듭니다.
- `SchedulerProjector`가 단일 target, mode, due와 마지막 실행 결과를 만듭니다.
- `SaveDetailComposer`가 state와 backup snapshot을 메모리에서 조합합니다.
- `SettingsProjector`가 앱 및 component 설정의 유효값을 `SettingsView`로
  게시합니다.
- 삭제·무효화 세이브가 목록에서 사라지고 stale 세이브는 기존 정보를 보존하는지
  검증합니다.
- 서로 다른 projector 갱신 순서에서도 임시 잘못된 source 연결을 만들지 않도록
  stable `save_id`로 조합합니다.

### A07 - Telemetry projector와 reducer

- producer DB별 마지막 `event_id` cursor를 관리하고 새 row만 page 단위로 읽습니다.
- cursor는 `(telemetry_instance_id, event_id)`이며 instance가 바뀌면 새 DB의 남은
  event에서 reducer를 재구성합니다.
- 읽을 DB 목록과 disabled 여부는 `TelemetrySourceCatalog`에서 받습니다.
- DB 읽기는 read-only connection을 사용하고 producer write를 막지 않습니다.
- `OperationProgressReducer`가 `run_index`별 phase와 item/byte 진행률을 계산합니다.
- `MetricsReducer`가 보존된 event 범위에서 실행 및 phase 통계를 계산합니다.
- `TelemetryHealthReducer`가 설정, DB 접근, schema version, 마지막 heartbeat와 현재
  workflow 상태를 조합해 health를 판정합니다.
- 실행 중 heartbeat가 끊기면 `Stale`, SQLite open/read 실패는 `Unreadable`, 설정으로
  꺼졌으면 `Disabled`로 구분합니다.
- workflow가 실행 중일 때만 heartbeat timeout을 적용하고 idle producer를
  `Stale`로 오판하지 않습니다.
- telemetry가 trim되어 cursor가 사라지면 남은 최소 event부터 안전하게 재구성하고
  해당 window 밖의 metric을 추측하지 않습니다.
- telemetry 장애 중에도 OperationView는 workflow 상태를 유지하고 진행 수치만
  unavailable로 바뀌는지 검증합니다.

### A08 - 리비전 파일 직접 읽기와 thumbnail cache

- repository의 논리 리비전에서 상대 경로 하나의 object locator를 찾는 read API를
  추가합니다.
- pack offset의 bounded stream을 사용해 전체 팩이나 전체 리비전을 풀지 않고
  `thumb.png`를 읽습니다.
- 필요할 때 `players.db`도 단일 파일 stream 또는 임시 read-only 파일로 제공할 수
  있는 계약을 둡니다.
- `capture.always_include`에 지정한 `thumb.png`와 `players.db`는 변경 여부와 무관하게
  매 리비전의 capture 대상에 넣습니다. 목록은 TOML과 반복 가능한 CLI 옵션으로
  재정의할 수 있으며, 파일이 사라지면 tombstone으로 기록합니다.
- thumbnail cache key는 repository/source/revision/object identity를 포함합니다.
- live save thumbnail 읽기는 게임 쓰기를 방해하지 않는 공유 모드와 실패 fallback을
  사용합니다.
- 손상, 누락, 지원하지 않는 이미지와 GC/compaction 동시 경계를 검증합니다.
- cache 크기 제한과 LRU eviction을 두되 원본 repository를 변경하지 않습니다.

### A09 - AppHost, 설정과 프로세스 수명

- `AppHost`가 StateScheduler, BackupScheduler, projector와 operation service를
  애플리케이션 수명 동안 한 번만 생성합니다.
- Scheduler 프로세스를 앱 수명 Job Object에 연결하고 stdout/stderr를 UI thread
  밖에서 소비합니다.
- Scheduler별 readiness, 정상 종료와 unexpected exit를 구분하고 bounded restart
  및 `Faulted` 상태를 ViewStore에 게시합니다.
- 정상 종료 cancellation과 강제 종료 fallback을 구현합니다.
- 페이지 이동과 ViewModel disposal이 Scheduler를 종료하지 않는지 검증합니다.
- 앱 전용 기본 TOML과 Settings read/write service를 구현합니다.
- `%LocalAppData%\PzTools` 아래 앱 runtime identity를 두고 앱 설정, archive
  telemetry와 producer별 임시 inventory를 사용자 save/archive 경로와 분리합니다.
- 설정 파일은 임시 파일 작성 후 같은 볼륨에서 교체해 부분 TOML을 노출하지
  않습니다.
- 여러 component 설정 적용 중 실패하면 변경 전 파일 snapshot으로 되돌리고,
  Scheduler의 트랜잭션 갱신을 마지막 commit 지점으로 사용합니다.
- 경로 변경은 검증 후 적용하며 실행 중 operation과 충돌하면 거부합니다.
- 새 경로의 AppHost 시작에 실패하면 새 host를 종료하고 이전 설정과 host를
  다시 시작합니다.
- interval, retention과 death backup 설정을 해당 component 설정과 권위 상태에
  반영합니다.
- 앱 재시작 후 설정, Scheduler target과 due 상태를 복원합니다.
- repository, archive import와 export staging을 producer별 inventory로 확인해
  비정상 종료가 남긴 임시 산출물만 안전하게 정리합니다.

### A10 - WinUI 3 Shell과 설정 화면

- Visual Studio 솔루션에 WinUI 3 앱 프로젝트를 추가하고 x64 Debug/Release 빌드를
  구성합니다.
- Windows App SDK 및 필요한 Visual Studio workload를 먼저 확인하고 누락 시 설치
  항목을 문서화합니다.
- 기존 console 도구와 같은 배포 디렉터리에서 실행할 수 있는 unpackaged 앱으로
  구성하고 관리자 실행 manifest를 적용합니다.
- `NavigationView` 기반 왼쪽 메뉴와 목록·상세 3단 Grid를 구현합니다.
- `NavigationView`의 Settings item을 pane 하단에 두고 progress card 영역은 별도
  pane footer로 구성합니다.
- 한국어·영어 `.resw` resource와 런타임 언어 전환을 구현합니다.
- 시스템·밝음·어두움 테마를 root element에 적용하고 재시작 후 유지합니다.
- 경로 picker, interval 0~60, retention 1~100과 사망 백업 toggle을 구현합니다.
- slider에는 현재 값 표시와 키보드로 정확히 입력할 수 있는 control을 함께 둡니다.
- 설정 오류, 접근 권한과 존재하지 않는 경로를 화면에 명확히 표시합니다.
- 키보드 탐색, focus, screen reader label과 색 대비를 점검합니다.

### A11 - 세이브 목록과 상세 화면

- SaveListView를 virtualized 목록에 binding합니다.
- thumbnail placeholder, 플레이 overlay와 사망 badge를 구현합니다.
- 모드, 이름, 마지막 플레이 시각을 현재 locale로 표시합니다.
- 선택 상태를 stable `save_id`로 유지하고 목록 갱신 후에도 가능한 경우 보존합니다.
- 상세 상단 live card와 최신순 backup history를 구현합니다.
- history가 많아도 UI thread에서 팩이나 DB를 직접 읽지 않게 paging 또는 점진
  materialization을 적용합니다.
- 선택 revision에 따라 복구·내보내기 버튼 상태를 갱신합니다.
- 다음 백업 예정 시각과 countdown을 Scheduler snapshot에서 표시합니다.
- 창 폭에 따른 목록/상세 전환과 뒤로 가기를 구현합니다.

### A12 - 수동 백업과 복구

- 수동 백업은 선택한 세이브를 대상으로 BackupRunner를 한 번 실행합니다.
- 자동 백업과 같은 repository mutex 및 workflow 계약을 사용합니다.
- 활성 operation scope에 따라 중복 수동 백업 버튼을 비활성화합니다.
- 복구는 선택 revision을 staging에 복원·검증한 뒤 대상 세이브를 교체합니다.
- 교체는 `staging → 기존 save의 rollback 이름 변경 → staging의 최종 이름 변경`
  순서로 수행합니다. 중간 실패나 다음 앱 시작에서 rollback 또는 완료를 판정할 수
  있는 inventory를 남깁니다.
- 플레이 중인 세이브의 복구 버튼을 비활성화하고 CLI에서도 다시 검사합니다.
- 복구 모달은 대상 세이브와 revision, 되돌릴 수 있는 백업이 무엇인지 표시합니다.
- 백업 및 복구 진행 카드는 telemetry projection만 사용합니다.
- telemetry 장애, worker 실패, 취소와 앱 종료에서 모달·버튼·workflow 상태가
  일관되게 정리되는지 검증합니다.
- 외부 CLI와 UI 작업이 동시에 시작돼도 named mutex가 마지막 방어선으로 동작하고
  operation scope 획득 순서가 교착을 만들지 않는지 검증합니다.

### A13 - Archive 라이브러리와 CLI

- versioned manifest와 archive 디렉터리 구조를 정의합니다.
- 초기 archive(v1)는 ZIP container와 루트 `pztools-manifest.json` marker를 사용합니다.
- 현재 archive(v2)는 `게임모드/세이브명/파일` 구조로 묶고 manifest도
  `게임모드/세이브명/pztools-manifest.json`에 둡니다. 가져오기는 v1도 지원합니다.
- `inspect`, `import`, `export` 명령과 공통 JSON 결과 envelope를 구현합니다.
- inspect는 manifest, thumbnail, 게임 모드, 세이브명과 마지막 플레이 시각을
  반환합니다.
- export는 revision restore, manifest 작성, 압축과 최종 파일 교체를 단계별로
  수행합니다.
- import는 staging extraction, path 검증, marker 검증, 이름 충돌 해결과 최종
  디렉터리 이동을 수행합니다.
- 절대 경로, `..`, reparse point와 중복 경로를 가진 archive를 거부합니다.
- 실패 시 불완전한 archive 또는 save 디렉터리를 최종 경로에 남기지 않습니다.
- 각 명령은 자체 telemetry와 health를 제공하며 별도 Scheduler 상태를 만들지
  않습니다.
- archive telemetry는 입력·출력 파일 옆이 아니라 AppHost가 넘긴 앱 runtime
  identity 아래에 기록합니다.
- 대용량 archive에서 전체 파일을 메모리에 올리지 않는 streaming 구현을
  검증합니다.

### A14 - Archive UI 연결

- `압축 파일 가져오기`에서 Windows file picker를 엽니다.
- inspect 실패 시 Project Zomboid archive가 아니라는 오류를 표시합니다.
- inspect 성공 시 thumbnail, 모드, 세이브명과 마지막 플레이 시각을 확인 모달에
  표시합니다.
- 확인 후 import를 실행하고 충돌 이름으로 결정된 최종 이름을 결과에 표시합니다.
- revision 선택 후 `압축 파일로 내보내기`에서 저장 위치를 선택합니다.
- import/export 동안 해당 operation scope의 다른 액션을 차단합니다.
- export 진행 카드를 백업 카드보다 위에 표시합니다.
- 취소, 디스크 부족, 권한 오류, 손상 archive와 앱 종료를 검증합니다.

### A15 - 종단 검증과 완료

- 앱 시작부터 두 Scheduler 및 projector 준비, 화면 표시까지 cold start를
  검증합니다.
- 실제 생존·사망 세이브 표본을 read-only로 사용해 목록, badge와 상세 메타데이터를
  확인합니다.
- 플레이 시작 후 활성 overlay, 자동 백업, 다음 due와 진행 카드를 확인합니다.
- 플레이 종료 후 동일 세이브의 final backup 1회와 target 해제를 확인합니다.
- 앱 종료 시 Scheduler, Runner와 worker가 남지 않는지 확인합니다.
- Scheduler를 의도적으로 비정상 종료해 bounded restart와 최종 `Faulted` 표시를
  확인합니다.
- 메뉴와 설정 이동 중에는 background 작업이 유지되는지 확인합니다.
- telemetry 정상, disabled, stale, unreadable과 schema 불일치 상태를 각각 UI에서
  확인합니다.
- telemetry DB 삭제·재생성 후 instance ID가 바뀌어도 새 event를 처음부터 다시
  읽고 이전 cursor 때문에 누락하지 않는지 확인합니다.
- 수동 백업·복구와 자동 백업 경쟁에서 mutex와 UI operation gate가 모두
  동작하는지 확인합니다.
- 복구 디렉터리 교체의 각 경계에서 프로세스를 종료하고 다음 시작의 rollback
  복구가 원본 또는 완전한 새 세이브 하나만 노출하는지 확인합니다.
- revision export 후 다른 이름으로 import하고 원본 논리 파일 목록과 비교합니다.
- 같은 archive를 반복 import해 `(1)`, `(2)` 이름이 결정적으로 생성되는지
  확인합니다.
- 한국어·영어와 세 테마에서 주요 화면의 잘림, 대비와 focus를 점검합니다.
- Debug 및 Release 빌드, 전체 단위·통합 테스트와 실제 표본 opt-in 테스트를
  실행합니다.
- 관리자 권한이 필요한 실제 USN 테스트를 명시적으로 실행하고 결과를 기록합니다.
- 문서, 기본 TOML, CLI help와 배포 스크립트를 최종 구현과 일치시킵니다.

## 완료 기준

A01부터 A15까지의 구현과 검증이 모두 끝나야 이번 로드맵을 완료로 표시합니다.
특히 화면만 동작하고 다음 항목 중 하나가 빠지면 완료가 아닙니다.

- per-save Scheduler job 제거와 단일 동적 대상 전환
- 앱 종료 시 전체 자식 프로세스 종료
- telemetry 기반 진행률 및 손상 상태 표시
- view revision 기반 변경 뷰 갱신
- 팩 전체 해제 없는 thumbnail 읽기
- 수동 백업과 안전한 복구
- archive inspect/import/export
- 실제 세이브 표본과 Release 종단 검증

## 이번 로드맵에서 미루는 작업

- 앱 종료 후에도 동작하는 Windows 서비스 또는 tray host
- 로그인 자동 시작과 작업 스케줄러 등록
- 클라우드 동기화와 원격 백업
- archive 암호화와 비밀번호 보호
- 리비전 pin, 메모, 태그와 사용자 임의 삭제 UI
- 다중 게임 지원과 게임별 plugin 구조
- 목표 팩 크기와 다중 출력 팩 분할
- 실제 측정치에 근거하지 않은 추가 hot-path 최적화
- 성능 수치를 이용한 CI 실패 기준
- metrics 전용 고급 dashboard와 장기 통계 warehouse
- MSIX 패키징과 Microsoft Store 배포
