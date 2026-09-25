# 명령줄 계약

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Backup, Maintenance, 상태 worker와 세 Runner는 모두 일회성입니다. Scheduler만
주기 상태를 소유합니다. worker를 직접 실행하면 worker가 전역 `control.db`에서 `run_index`를 발급합니다.
Runner를 직접 실행하면 Runner가 mutex 획득 전에 번호를 발급하며, Scheduler가
`--run-index`를 전달하면 그 값을 전체 파이프라인에서 사용합니다. 백업
`--revision`은 CLI 전용 명시적 주입값이며 현재 리비전보다 큰 값만 허용합니다.

```text
backup --repository <path> --source-id <id> [--run-index <n>] [--revision <n>]
    [--always-include <relative-path>]...
    [--full-scan-hash-comparison <true|false>]
restore --repository <path> --source-id <id> --revision <n> --target <save-path>
verify --repository <path>
maintenance prune --repository <path> --source-id <id> --keep <n>
maintenance gc --repository <path>
```

새 일회성 실행 파일과 Scheduler의 핵심 인자는 다음과 같습니다.

```text
PzTools.Backup.Runner --repository <path> --source-id <key> [--run-index <n>]
    [--config <runner.toml>] [--worker-config <backup-worker.toml>]
PzTools.Maintenance.Runner --repository <path> --source-id <numeric-id> [--run-index <n>]
    [--config <runner.toml>] [--worker-config <maintenance-worker.toml>]
PzTools.State.Runner --state-db <path> --saves-root <path> [--run-index <n>]
    [--config <state-runner.toml>]
PzTools.State.Collector.Cli --state-db <path> --saves-root <path> --run-index <n>
    [--config <state-collector.toml>]
PzTools.State.Reactor.Cli --state-db <path> --run-index <n>
    [--config <state-reactor.toml>]

PzTools.Backup.Scheduler configure --scheduler-db <path> --repository <path>
    [--interval-minutes <0..60>] [--config <backup-scheduler.toml>]
PzTools.Backup.Scheduler run --scheduler-db <path>
    [--control-db <path>] [--worker-directory <path>] [--once]
PzTools.State.Scheduler --scheduler-db <path> --state-db <path>
    --saves-root <path> [--control-db <path>] [--interval-seconds <n>]
    [--worker-directory <path>] [--once]

PzTools.Zomboid.Archive.Cli inspect --archive <file>
PzTools.Zomboid.Archive.Cli export --repository <path> --source-id <numeric-id>
    --revision <n> --output <file> [--run-index <n>] [--control-db <path>]
PzTools.Zomboid.Archive.Cli import --archive <file> --saves-root <path>
    [--run-index <n>] [--control-db <path>]
```

`restore`는 빈 디렉터리만 받는 명령이 아닙니다. 대상과 같은 부모 디렉터리에
staging을 완성한 뒤 기존 세이브를 rollback 이름으로 옮기고 원자적인 디렉터리
교체를 수행합니다. `players.db`를 배타적으로 열 수 없는 실행 중 세이브는 거부하며,
중단 시 남은 복구 journal은 다음 앱 시작에서 정리 또는 rollback됩니다.

새 복원 journal(v2)은 staging 디렉터리의 볼륨·파일 식별자를 기록합니다.
대상 폴더와 원본 rollback이 함께 있으면, 대상이 실제로 이동된 staging인지
확인한 경우에만 rollback을 제거합니다. 같은 이름의 다른 폴더, 확인 불가능한
구형 journal(v1), 접근 오류 등은 충돌로 보고하고 원본·staging·journal을
보존합니다. `installed` 단계 이름만으로 성공을 추측하지 않습니다. rollback을
되돌리는 복구 자체가 중단된 경우도 원본 디렉터리 식별자로 재개합니다.

개발 빌드는 `scripts/publish-tools.ps1`로 모든 실행 파일을 같은 디렉터리에
게시합니다. Runner는 그 디렉터리의 고정된 worker 이름만 실행하며 임의 실행 파일
이름을 받지 않습니다.

백업 worker는 기본적으로 `%LOCALAPPDATA%/PzTools/config/backup-worker/default.toml`을
읽습니다. `--config`로
다른 TOML 파일을 선택할 수 있으며, 앱 사용자 설정과 명시적인 CLI 옵션은
`configuration.md`에 설명된 우선순위로 적용됩니다. 각 Runner와 Scheduler의 `--config`는
그 프로세스 자신의 설정만 선택합니다. 부모 설정은 자식에게 암묵적으로 전달되지
않으며, Backup/Maintenance Runner에서 자식 설정을 바꾸려면 `--worker-config`를
명시해야 합니다.

백업 worker의 `--always-include`는 반복할 수 있고, 하나라도 주어지면 TOML의
`capture.always_include` 전체를 대체합니다. 경로는 source root 기준 상대 경로이며
절대 경로와 `..`는 거부합니다.

종료 코드:

| 코드 | 의미 |
|---:|---|
| 0 | 명령이 성공적으로 완료됨 |
| 1 | 백업, 복원, 저장소 또는 I/O 실패 |
| 2 | 안전한 경계에서 취소됨 |
| 3 | 검증을 완료했으며 손상되거나 누락된 데이터를 발견함 |
| 4 | 유지보수 트랜잭션은 커밋됐지만 하나 이상의 실제 파일을 제거하지 못함 |
| 64 | 명령, 설정 또는 인자가 잘못됨 |
| 75 | Runner mutex 또는 저장소 writer lease가 이미 사용 중임 |

Runner의 75는 named mutex가 사용 중이어서 worker를 시작하지 않은 `Busy`입니다.
직접 실행한 Runner는 이 경우에도 mutex 검사 전에 발급한 `run_index`와 `Busy`
workflow를 남깁니다. Scheduler가 전달한 번호도 그대로 사용합니다. Scheduler는
이 tick을 누적하지 않으며 final/pending attempt도 소비하지 않습니다.

Runner와 일회성 worker는 표준 출력에 version, component, `runIndex`, outcome,
시작·완료 시각, result/error를 가진 공통 JSON envelope를 기록합니다. 부모는
전달한 `run_index`, component와 종료 코드가 envelope와 일치하는지 검증하며
불일치는 `invalid-runner-result` 또는 `runner-contract-mismatch` 실패로 정규화합니다.
진단 명령의 오류는 표준 오류에 `success`, `code`, `message` 필드를 가진 JSON으로
출력할 수 있습니다. Telemetry는 별도로 기록되므로 성공한 백업의 종료 코드를
바꾸지 않습니다. 성공한 백업 결과의
`warnings` 배열에는 비권위적인 telemetry 오류, 격리된 staging 파일, 발견된
고아 팩이 포함됩니다. `restore`, `verify`, 모든 `maintenance` 명령은 기존
저장소를 요구하며 경로 오타로 새 저장소를 만들지 않습니다.
