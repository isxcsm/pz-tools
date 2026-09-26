# Telemetry

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

생산 측에서는 `TelemetryEvent`, `TelemetryRunSession`, `telemetry.*`,
`telemetry.db`처럼 telemetry 용어를 일관되게 사용합니다. metric은 소비자가
원시 이벤트에서 파생하며 원시 이벤트 스키마에 다시 기록하지 않습니다.

저장소 루트의 `telemetry.db` 형식 버전 1, 스키마 버전 2는 백업 엔진의 세부 이벤트를
`(run_index, sequence)` 키로 저장합니다. `run_index`는 `repository.db`가 제공하며
telemetry가 권위 있는 식별자를 할당하지 않습니다. 이벤트에는 스키마 버전, scope,
이름, UTC timestamp, 단조 증가 경과 tick, 선택적 JSON payload를 저장합니다.

모드는 기록할 이벤트 scope를 선택합니다.

- `off`: 백업 엔진의 세부 telemetry DB에 run과 이벤트를 기록하지 않음
- `run`: run 범위 이벤트만 기록
- `phase`: run 및 phase 이벤트 기록
- `raw`: emit된 모든 이벤트 기록

writer는 bounded channel을 사용하며 정상적인 저장소 처리가 뒤처지면 기다립니다.
배치 크기와 flush 간격은 SQLite 트랜잭션 경계만 제어하며 이벤트를 sampling하거나
집계하지 않습니다. 프로세스가 비정상 종료되면 마지막 미커밋 배치를 잃을 수 있습니다.
flush 간격은 배치의 첫 이벤트부터 측정합니다. 새 이벤트가 도착해도 마감 시각을
뒤로 미루지 않으므로, 배치가 차지 않는 연속 진행 보고도 제때 기록됩니다.

SQLite 오류는 telemetry session을 비활성화하고 failure 상태에 남기지만, 백업
완료 경로로 예외를 전파하거나 저장소 트랜잭션을 변경하지 않습니다. 일회성 JSON
결과는 이 오류를 `warnings` collection에 노출합니다. 따라서 telemetry 초기화,
복구, 완료, 보존 오류는 성공한 리비전이나 프로세스 종료 코드를 바꾸지 않으면서도
확인할 수 있습니다. 일회성 백업 프로세스는 저장소 writer lease를 획득한 후 이전
`Running` telemetry row를 `Abandoned`로 표시할 수 있지만, 읽기 위해 데이터베이스를
열 때는 이 작업을 수행하지 않습니다.

완료된 run 수와 논리 데이터베이스 사용량에 따른 보존 처리는 리비전 보존과
독립적입니다. 소비자는 알고 있는 이벤트 sequence 다음부터 page 단위로 읽고,
자체적으로 정규화와 metric 집계를 수행합니다.

Runner, Maintenance, 상태 Collector/Reactor, 두 Scheduler, restore와 archive의 프로세스 경계
이벤트는 producer별 독립 `telemetry.db`에 원자적 row로 기록합니다. 디렉터리
identity는 `<identity>/.pztools/<component>/telemetry.db`, DB 파일 identity는
`<parent>/.pztools/<database-name>/<component>/telemetry.db`를 사용합니다. 따라서
producer는 다른 프로세스의 DB, schema, trim 또는 동시 쓰기를 알 필요가 없습니다.

프로세스 telemetry 스키마 버전 3의 event identity는
`(scope_id, run_index, component, event_sequence)`이며
UTC, 프로세스 시작 후 경과 tick, payload version과 선택적 JSON payload를 함께
저장합니다. producer는 집계나 IPC 전송을 하지 않습니다. `[telemetry]`의 기본값은
`enabled = true`, 최근 100개 run, 논리 크기 64 MiB입니다. metrics 소비자는 필요한
producer DB들을 읽어 정규화하고 결합합니다. 기록과 trim은 best-effort여서 초기화나
SQLite 오류가 관측 대상 프로세스의 결과 또는 종료 코드를 바꾸지 않습니다.

오래 실행되는 백업, restore와 archive 작업은 실행 중일 때만
`operation.heartbeat`를 남깁니다. projector는 workflow가 `Running`인 경우에만
heartbeat timeout을 `Stale` 판정에 사용하며, 완료된 작업이나 idle producer를
오래된 이벤트 때문에 장애로 표시하지 않습니다. archive 가져오기·내보내기와
리비전 복구는 파일마다 SQLite에 쓰지 않습니다. 진행 콜백은 누적 처리량의 최신
상태만 덮어쓰고 백그라운드 writer가 약 100ms마다 `progress.snapshot`으로
묶음 기록합니다. 단계가 바뀌거나 작업이 종료될 때는 직전 단계의 마지막 상태를
먼저 큐에 넣습니다. `run.started`와 완료·실패·취소·busy 이벤트는 덮어쓰지 않고
순서를 보존하며, 프로세스 종료 전에 마지막 상태와 종료 이벤트를 flush합니다.
telemetry 저장 실패는 원래 작업 결과에 영향을 주지 않습니다. percentage는
snapshot의 누적 처리량과 전체량으로 소비자가 계산합니다.

앱 내부에서 실행하는 세이브 삭제는 worker telemetry DB를 만들지 않습니다.
생산자는 단계별 누적 처리 개수를 보고하고 `LatestProgress`의 단일 슬롯이 이전 값을
교체합니다. UI 타이머는 최신 값만 가져가며 Dispatcher 콜백을 개별 파일마다 쌓지
않습니다. 완료·실패 결과는 이 슬롯과 별개인 작업 Task로 전달합니다. 파일 목록을
아직 수집 중이면 발견 개수만 표시하고, 총량이 확정된 검사·삭제 단계에만 퍼센트를
표시합니다. 빠른 작업을 오래 보이게 하려는 인위적인 대기는 넣지 않습니다.

## 로그 projection

앱은 producer별 telemetry를 읽어 `Trace`, `Information`, `Warning`, `Error`,
`Critical`로 분류하고 `logs.db`에 통합 보관합니다. 최근 항목을
`LogsView`에 게시합니다. `file.*.completed`, `progress.snapshot`,
`operation.heartbeat`와 `workload.discovered`는 진행률·metric 계산에는 사용하지만 일반 로그 목록에서는
제외합니다. 기록 최소 수준과 보관 건수는 `config/app/default.toml`의 `[logs]`, 로그
화면의 표시 수준과 개수는 앱 `settings.toml`의 `[logs]`에서 정하며 원시
telemetry 보존 설정에는 영향을 주지 않습니다.

실패 이벤트의 payload는 `failureCode`, `exceptionType`, `message`, `hResult`를
기본으로 두고, 알 수 있을 때 `phase`, `path`(세이브 기준 상대 경로), `saveId`,
`reason`, `innerExceptionType`, `innerMessage`를 더합니다. 진단 문자열은 한 줄
512자로 제한하고 백업 소스의 절대 경로는 가립니다. 백업 엔진의 `run.failed`와
자식 프로세스의 결과 envelope는 같은 `run_index`로 연결됩니다. 상위 runner와
scheduler는 자식 오류 코드를 전달하지만, 자세한 파일 정보는 원본 producer의
이벤트에 둡니다. 로그 화면은 이를 실패 원인 카드로 표시하고 원본 JSON도 보존합니다.
취소는 `.cancelled` 경고, 실제 실패는 `.failed` 오류로 분류합니다.

짧은 오류 메시지와 별도로 `IFailureDiagnostics`가 제공하는 기술 정보는
`diagnostics` 필드에 최대 6144자(초과 시 생략 표시 추가)로 보존합니다. 이 필드에도
백업 소스 절대 경로 가리기와 줄바꿈 정리를 적용합니다. JVM 저장 실패는 이 경로로
단계별 집계값을 남겨 기존 512자 메시지 제한 때문에 뒤쪽 진단이 사라지지 않게 합니다.
상위 runner의 짧은 메시지보다 원본 `backup-worker` 이벤트를 확인해야 합니다.
runner·일정·점검의 `.completed` 이벤트라도 결과가 `Failed` 또는
`Degraded`면 각각 오류/경고로 표시합니다.
이미 실행 중인 상태 검사를 중복 요청한 `state-scheduler`의
`tick.completed` (`Busy`, `Started=false`)는 추적 수준입니다. 사용자 백업의
실행 거절이나 실제 검사 실패까지 이 규칙으로 숨기지 않습니다.
완료 이벤트의 결과는 로그 수준·표시 문구·작업 카드가 함께 해석합니다. `Busy`,
`Cancelled`, `Degraded`, `Failed`를 성공 완료로 표시하지 않습니다. 숫자형
`outcome`은 `ProcessOutcome`, 과거 백업의 숫자형 `status`는 `RunStatus`로
구분합니다. 이미 저장된 로그를 일괄 수정하는 마이그레이션은 실행하지 않습니다.
각 점검 레인의 독립 telemetry DB도 앱이 읽으며, 일부 파일 정리에 실패한 경우
파일 수와 최대 8개의 파일 이름을 남깁니다.

## 진행률 지연과 재시도

process telemetry의 기록 실패 재시도에서는 같은 단계의 연속 진행률을 최신
샘플 하나로 합칩니다. 단계 경계와 시작·종료 등 의미 있는 이벤트 순서는 유지합니다.
읽기 쪽은 SQLite 공급자의 재시도 시간까지 `telemetry_read_timeout_seconds`
(기본 1초)로 제한합니다. `PRAGMA busy_timeout`만 설정해서는 공급자의 기본
30초 재시도를 제한할 수 없습니다.

첫 읽기에서 테이블이나 초기 메타정보가 아직 없는 경우 기존 초기화 유예 시간만큼
기다립니다. UI 작업이 없는 상태 수집기도 같은 규칙을 사용하며, 이미 읽었던 DB의
메타정보 소실이나 유예 시간을 넘긴 실패는 오류로 기록합니다. 잘못된 JSON·날짜·
인스턴스 ID는 해당 출처의 읽기 오류로 격리해 다른 출처의 갱신을 막지 않습니다.
읽기 오류에는 DB 경로, 처리 단계, 예외 메시지와 내부 예외를 남깁니다.

백업의 파일 검색(`scan`), 내용 비교(`hash`), 팩 압축(`capture`)도 진행 상태를
발행합니다. 파일 검색은 전체 개수를 알기 전까지 불확정 진행률이며, 내용 비교는
검사가 끝난 파일과 바이트 수를 사용합니다. 직렬화 전에 기존 진행률 간격으로
샘플링하고, 저장은 기존 bounded queue와 batch flush를 거칩니다.

UI가 시작한 작업은 실행 전부터 같은 `operation_id`를 coordinator에 전달합니다.
진행률 연결을 종류와 실행 번호만으로 추측하지 않으며, 같은 작업의 종료 상태는
늦게 도착한 `Running` projection보다 우선합니다.
