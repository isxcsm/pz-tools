# 프로세스 구조

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

현재 헤드리스 구조는 두 개의 독립 파이프라인으로 나뉩니다.

```text
BackupScheduler → BackupRunner → Backup.Once
                ↳ MaintenanceRunner → Maintenance.Once (레인 판정·경량 작업)
                                      ├─ RevisionReclamation 자식 작업
                                      └─ ArtifactCleanup 자식 작업

StateScheduler  → StateCheckPipeline (같은 프로세스의 Collector → Reactor)
                → Scheduler outbox relay
StateRunner     → StateCollector.Once → StateReactor.Once (수동/직접 실행 경로)
```

BackupScheduler는 세이브별 job 목록을 갖지 않습니다. 하나의 `scheduler.db`에
repository, 현재 동적 target, 주기, 자동 백업 활성 여부, 다음 due와 pending
queue를 보관합니다. 한 tick의 백업 `run_index`는 BackupRunner에 전달합니다.
Backup이 성공하거나 변경 없음으로 끝나면 MaintenanceRunner의 경량 레인 판정까지
기다립니다. 무거운 레인은 각각 자식 프로세스를 시작하고 종료를 기다리지 않습니다.
각 자식 작업은 별도 `run_index`와 workflow를 사용합니다. 저장소·레인별 named
mutex가 살아 있으면 해당 레인의 중복 실행만 건너뛰고 다른 레인은 계속 판정합니다.
백업이 도래하면 실행 중인 무거운 레인에 양보 신호를 보내며, 저장소
잠금으로 백업 worker가 `Busy`를 반환해도 주기 due를 유지해 다음 tick에 다시
시도합니다. 점검기의 시작·실행 실패는 완료된 백업 결과를 변경하지 않습니다.
pending 실행 횟수는 Backup worker가 실제로 시작됐을 때만 감소합니다.

BackupRunner와 MaintenanceRunner는 정규화한 저장소 경로로 같은 저장소 접근
named mutex를 계산합니다. MaintenanceRunner의 별도 dispatch mutex는 경량 판정
동안만 보유하고, 무거운 자식 작업은 각자의 레인 mutex를 독립적으로 보유합니다.
실제 저장소 쓰기는 `.writer.lock`으로 직렬화합니다. 직접 실행된 Runner는 저장소에 `run_index`를 예약한 뒤 저장소
mutex를 기다리지 않고 한 번만 획득합니다. 경쟁 시 worker를 만들지 않고 예약한
workflow를 `Busy`로 완료합니다. Scheduler가 번호를 전달했다면 새 번호를 발급하지
않습니다.
상태 파이프라인은 `state.db` identity로 별도 mutex를 사용합니다. Runner가 만든
일반 자식은 kill-on-close Windows Job Object에 연결되며 stdout과 stderr를 동시에
끝까지 읽습니다. 오래 실행되는 점검 레인 작업만 명시적으로 Job에서 분리합니다.

## 데이터베이스 책임

- `%LOCALAPPDATA%/PzTools/control.db`: 설치 인스턴스 전역 `run_index` 원자 발급
- `repository.db`: 소스, workflow와 stage, 리비전, 전체 논리 파일 목록, 팩 위치
- `telemetry.db`: 기존 백업 엔진의 세부 원시 telemetry
- `.pztools/[<database-name>/]<component>/telemetry.db`: 해당 producer만 쓰는 프로세스 경계 이벤트
- `state.db`: pending 관측, 현재 게임 및 세이브 projection, 전이와 outbox
- `scheduler.db`: 단일 동적 target, mode, cadence, pending queue와 idempotent command inbox

번호 발급자는 mutex 획득 전에 `control.db`에서 번호를 확보합니다. 부모가 전달한
번호가 있으면 자식은 다시 발급하지 않습니다. 발급 실패는 실행 실패이며 저장소나
state DB의 로컬 번호로 묵시적으로 후퇴하지 않습니다. 배포 경계는
`deployment-layout.md`를 따릅니다.

상태 수집기는 현재 projection을 직접 수정하지 않습니다. 완결된 pending batch만
기록하고 Reactor가 하나의 트랜잭션에서 projection, transition과 outbox를 함께
적용합니다. 외부에서 보이는 의미가 바뀐 경우에만 전역 `state_revision`을 한 번
증가시키며 바뀐 row의 `changed_revision`에 같은 값을 씁니다. reader는 revision
비교와 전체 projection 읽기를 같은 read transaction에서 수행합니다.

## 리비전 보존

앱의 기본 보관 개수는 최신 활성 **자동 백업** 20개입니다. Retention lane은 앱에서
전달한 보관 개수(설정 없이 직접 실행하는 유지보수 CLI는 100개)를 보존하고 초과한 자동
백업만 `Deleted`로 표시합니다. 수동 및 생성 경로가 불명확한 기존 백업은 개수 계산과
자동 삭제에서 제외됩니다. 삭제 리비전은 즉시 조회 대상에서 사라지지만 팩과 객체는
그 자리에서 제거하지 않습니다. 삭제 리비전 누계가 기본 배치 크기 20개에 도달하기
전에는 RevisionCompaction과 ObjectGc를 `Skipped`로 끝냅니다. 임계치에 도달하면
RevisionReclamation 자식 작업이 최대 20개를 다음 활성 리비전 경계로 entry version을
재기준화한 뒤 삭제 row를 물리 제거하고, 이어서 참조가 사라진 객체와 빈 팩을
정리합니다. 두 작업은 순서 의존성이 있어 하나의 자식 작업으로 묶습니다.
자동 팩 재압축은 과도한 팩 재기록과 임시 디스크 사용을 방지하기 위해 비활성화했습니다.

`state.db`와 `scheduler.db`를 열 때 실행 파일이 지원하는 버전보다 높은
`schema_version`은 수정하지 않고 즉시 거부합니다. 낮은 버전만 순방향 migration
대상입니다.

## Project Zomboid 상태 판정

SaveDiscovery는 `Zomboid\Saves` 아래 marker를 탐색하며 reparse point를 따라가지
않습니다. GameActivity는 `players.db`를 `ReadWrite + FileShare.None`으로 열어 보기만
하고 어떤 바이트도 쓰지 않습니다. Windows sharing violation만 `Active`, 성공은
`Inactive`, 권한 또는 기타 I/O 오류는 `Unknown`입니다. CharacterState는 SQLite
read-only 연결로 `localPlayers`와 `networkPlayers`의 `isDead`를 읽습니다.
Activity lane이 실패하거나 `Unknown`을 반환한 세이브는 stale로 표시하며, 확정된
비-stale Active 세이브가 없고 stale/Unknown 관측이 하나라도 있으면 전체 게임
상태도 `Unknown`입니다.

StateScheduler의 기본 수집 간격은 3초입니다. Windows에서 Project Zomboid
프로세스의 종료 이벤트를 관찰하면 주기 도래를 기다리지 않고 상태 수집을 두 번
실행해 비활성 상태를 확정합니다. 종료 훅을 놓치거나 프로세스를 식별할 수 없는
경우에도 3초 주기 확인이 계속 동작합니다. 주기 경로는 같은 스케줄러 프로세스에서
Collector/Reactor를 실행하며, 기존 StateCollection mutex와 pending batch/outbox 복구를
유지합니다. 수동 즉시 갱신 및 직접 Runner 호출은 기존 별도 프로세스 경로입니다.

한 번의 Active/Inactive 관측은 상태 전이를 만들지 않습니다. 같은 값이 두 번
연속 관측돼야 확정하며 `Unknown`은 횟수를 늘리지 않습니다. 확정된
`Inactive → Active`는 해당 세이브를 현재 target으로 만드는 `ActivateTarget`,
`Active → Inactive`는 `ClearTarget`으로 대상과 예약을 해제합니다. 게임 종료로
추가 자동 백업을 만들지 않습니다. 세이브가 사라져도 `ClearTarget`을 보냅니다.
사망 백업은 옵션이 켜져 있고 플레이가 현재 활성으로 관측된 경우에만
`RunOnceNow`를 남깁니다. 복수 세이브가 동시에 활성으로 확정되면
`SuspendAmbiguous`로 자동 admission을 멈추고 단일 활성 세이브로 해소된 뒤에만
재개합니다. outbox와 Scheduler inbox는 서로 다른 DB이므로 idempotency key를
보존한 뒤 inbox commit이 성공한 메시지만 acknowledge합니다. `Alive ↔ Dead`는
별도 Character transition으로도 남깁니다.

`ActivateTarget`은 즉시 백업하지 않고 활성화 명령을 처리한 시각부터 설정된
자동 백업 간격이 지난 시점에 첫 periodic backup을 예약합니다. 간격을 변경해도
변경 시각부터 새 간격을 적용하되 정지·모호 상태를 활성으로 바꾸지 않습니다.
설정 변경은 대기 중인 상태 명령을 먼저 반영합니다. 종료 시 final backup은 더 이상
예약하지 않으며, 남아 있던 `FinalizeTarget` 명령과 Final 예약도 자동 실행하지 않습니다.
스케줄러는 실행 직전에 예약 ID와 플레이 상태를 다시 확인하고, 자동 worker는
게임 저장 준비/카운트다운 대기 전후에 게임 프로세스와 세이브 활성 상태를 확인합니다.
종료되었거나 상태가 불확실하면 `Skipped`입니다. 이미 캡처가 시작된 백업을 게임 종료만으로
중단하지는 않습니다. 수동 백업은 비실행 중에도 가능합니다.
앱 카운트다운은 자동 사용 설정·활성 예약뿐 아니라 신선한 단일 플레이 상태가 있어야
표시합니다. 상태 수집 간격과 활성 확정에 따른 지연은 남습니다.

## 원본 세이브가 없는 백업 정리

앱이 시작하는 StateScheduler는 `--repository`와 `--saves-root`를 받아,
자동 백업 사용 여부와 관계없이 1분마다 Maintenance worker의 `OrphanBackups`
레인을 별도 프로세스로 호출합니다. 다만 게임 프로세스가 실행 중이거나 판정이 불확실하면
무거운 레인·고아 정리는 보류합니다. 메뉴 상태도 보류하며 다음 게임 종료 후 점검에서
재개합니다. 이미 시작한 레인은 게임 시작을 감지하면 기존 취소 경계에서 양보합니다.
상태 수집은 이 정리 작업의 완료를 기다리지 않습니다.
중복 실행 방지, RepositoryAccess 잠금, writer lease, 백업 우선 양보를 적용합니다.

저장소 source key와 현재 설정의 `Saves/<mode>/<save>` 경로가 정확히 일치하고,
상위 경로를 정상 열거해 원본 폴더 부재가 확인된 경우만 대상으로 합니다.
루트 접근 실패, reparse point, 복원 journal, 실행 중 workflow는 보류합니다.
폴더가 남아 있는 세이브는 `players.db`가 없더라도 삭제하지 않습니다.
해당 세이브의 수동·자동 백업 모두 영구 정리 대상이며, 일반 보관 수 제한과 다릅니다.
참조 데이터를 제거한 뒤 GC로 불필요한 객체와 팩을 회수하고, 다른 세이브가 공유하는
객체는 유지합니다. 최신 리비전 번호만 빈 비공개 기준으로 남겨 동일 이름으로 다시
만든 세이브의 리비전 번호·캐시가 충돌하지 않게 하며 USN 체크포인트를 초기화합니다.
삭제 결과에는 세이브 ID와 리비전 수를 기록하며 변경 없는 확인은 로그를 남기지 않습니다.

## 비정상 종료 복구

앱 시작 시 스케줄러를 실행하기 전에 `InterruptedOperationRecoveryService`를 실행하고,
이후 `OrphanBackups` 레인의 매 회차에서도 재시도합니다. RepositoryAccess와 writer lease를
확보하지 못하면 즉시 보류하고, 세이브별 작업에는 SaveWrite 잠금도 적용합니다.
실행 기록에는 소유 프로세스의 PID와 시작 시각을 함께 기록합니다. 부모 및 실행 중인
단계의 프로세스가 모두 종료된 것으로 확인될 때만 Running을 Abandoned로 전환합니다.
PID 재사용을 구분하며, 기존 기록에 소유 정보가 없거나 확인 권한이 없으면 추측하지 않고
보존·보고합니다. 기존 구성요소별 잠금에 기반한 복구 경로도 유지합니다.

저장소의 미완성 staging/quarantine 임시파일과 참조되지 않는 팩을 회수합니다.
복원 journal이 정상인 세이브는 디렉터리 교체 상태를 수습하고, journal 없는 복원·캐릭터
회복 staging은 원본 폴더가 존재하고 사용 중이 아닐 때만 제거합니다. 단독 rollback,
손상된 journal, reparse point 등 원본 여부를 확정할 수 없는 항목은 보존하고 로그를 남깁니다.
한 세이브의 복구 실패가 다른 세이브의 복구나 앱 시작을 중단하지 않습니다.

`tests/PzTools.CrashFixture`는 실제 백업의 다섯 commit 경계와 복원 파일 작성 단계에서
테스트 프로세스를 멈추는 테스트 전용 실행 파일입니다. 부모 테스트가 강제 종료한 뒤
재실행 복구, 백업 내용 복원, 재시도 멱등성을 검증하며 앱 배포에는 포함하지 않습니다.
이 검증은 프로세스 강제 종료 대상이며 디스크 고장·전원 손실까지 보장하지는 않습니다.

## 설정 소유권

각 실행 파일의 편집 가능한 `default.toml`은 앱 데이터의 중앙
`config/<구성요소>/` 아래에, telemetry DB는 기존 identity 쪽에 둡니다.
`--config`도 현재 프로세스에만 적용됩니다. Scheduler는 Runner 설정을, Runner는
worker 설정을 기본적으로 전달하지 않습니다. Backup/Maintenance Runner에서만
명시적인 `--worker-config`로 자식 설정을 선택할 수 있습니다.
