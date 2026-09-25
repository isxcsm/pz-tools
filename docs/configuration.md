# 설정

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

## 앱 설정

앱 화면의 설정은 `%LOCALAPPDATA%/PzTools/settings.toml`에 저장됩니다. 앱이
소유하는 파일이며 고급 설정에서 편집하는 TOML과는 구분됩니다. 편집 가능한 TOML은
`%LOCALAPPDATA%/PzTools/config` 아래에 모입니다. 설정 화면의 **폴더 열기**로
찾아갈 수 있고, 직접 수정한 뒤 **설정 적용·앱 다시 시작**으로 적용합니다.
**기본 설정으로 복원**은 현재 `config` 폴더를 `config-backups`에 보관하고 기본
TOML을 다시 만듭니다. 앱 화면에서 선택한 일반 설정은 유지됩니다.
`config/app/default.toml`의 `[logs].record_minimum_level`은 새로 기록할 로그의
최소 수준이고 `max_entries`는 보관할 최대 건수입니다. 로그 화면의 최소 수준
필터는 보이는 목록만 바꾸며 이 기록 정책을 변경하지 않습니다.
앱은 처음 실행할 때 지원하는 구성요소별 TOML 11개를 만듭니다. 설정 키와 주석은
앱 화면 언어와 무관하게 영어로 유지합니다. 앱 언어를 바꿔도 사용자가 편집한 TOML을
다시 쓰지 않습니다. 기존 파일의 주석이나 누락된 키도 자동으로 수정하지 않습니다.
새 기본 파일이 필요하면 설정 화면의 **기본 설정으로 복원**을 사용합니다.
이는 **지원되는 편집 옵션**의 목록이지 실행 중 생성되는 모든 상태값의 목록은
아닙니다. 작업 상태·스케줄 예약·로그 기록 자체는 각 DB에서 관리합니다.

`settings.toml`의 `[ui]`의
`system_tray = true`를 켜면 창의 닫기 버튼이 앱을 종료하는 대신 시스템 트레이로
숨깁니다. 트레이 아이콘을 더블클릭하거나 우클릭 메뉴에서 `창 복원`을 선택하면
다시 표시됩니다. 트레이 메뉴의 `종료`는 종료 확인 후 앱과 백업 스케줄러를
종료합니다. 기본값은 `false`이며, 이 경우 창 닫기 버튼도 종료 확인을 띄웁니다.

## 백업 worker 설정

백업 worker는 `--config`로 다른 파일을 지정하지 않으면 중앙 설정 폴더의
`backup-worker/default.toml`을 읽습니다.
코드 기본값, TOML, 앱 화면에서 선택한 값, 직접 지정한 CLI 옵션 순으로 적용합니다.
앱 화면에 없는 `verify_staged_copies`는 TOML 값이 적용됩니다. TOML 안의 상대
소스 경로는 해당 TOML 파일이 있는 디렉터리를 기준으로 해석합니다.

```toml
format_version = 1

[[sources]]
id = "zomboid-main"
path = "C:/Users/example/Zomboid/Saves/Survivor/MySave"

[capture]
always_include = ["players.db", "vehicles.db", "thumb.png"]
full_scan_hash_comparison = true

[storage]
checksum = "auto"
compression = "auto"
content_deduplication = false
verify_staged_copies = true

[telemetry]
enabled = true
mode = "phase"
batch_size = 256
flush_interval_ms = 250
retain_runs = 1000
max_database_mib = 256
```

`capture.always_include`는 USN 또는 전수 비교 결과에서 변경되지 않은 파일도 해당
리비전에 다시 캡처할 상대 경로 목록입니다. 목록에 있는 파일이 없어졌다면 일반
파일과 동일하게 tombstone으로 기록합니다. 앱이 생성하는 backup worker 설정은
`players.db`, `vehicles.db`, `thumb.png`를 기본값으로 둡니다. 이전 파일에 이 키가 없으면
같은 기본 목록을 적용하되 파일에는 써넣지 않습니다. 빈 목록 `[]`을 명시하면
특별 처리를 끕니다. 이 설정은 게임 메모리의 데이터를 디스크에 쓰도록 강제하지는
못합니다.

`capture.full_scan_hash_comparison`은 기본 `true`입니다. USN을 사용할 수 없어
전수조사로 전환하면 메타데이터가 같은 파일도 SHA-256으로 비교합니다. 기준 해시가
없는 파일은 수집하여 기준을 만듭니다. `false`는 전수조사의 내용 읽기를 생략해
빠르지만 크기·시각이 같은 내용 변경을 놓칠 수 있습니다. `always_include`에는
영향을 주지 않습니다. 비교 해시는 저장 객체별 nullable 메타데이터로 관리하며,
옵션을 꺼도 기존 값과 무결성 검증용 체크섬은 보존합니다. 새로 계산하지 않은
비교 해시는 null입니다. 기존 SHA-256 체크섬은 호환되는 비교 기준으로 재사용합니다.

새 백업 이름의 언어는 앱 설정이 결정합니다. 수동·자동 백업에 따라 한국어에서는
`수동 백업 N`·`자동 백업 N`, 영어에서는 `Manual backup N`·`Automatic backup N`을
사용하며, 나머지 지원 언어도 해당 언어의 이름을 사용합니다. 이름을 편집하거나
이후 앱 언어를 바꿔도 이미 저장된 이름은 자동으로 변경하지 않습니다.
앱의 `[ui].language`, 작업자의 `[naming].language`, CLI의 `--name-language`는
`ko-KR`, `en-US`, `ja-JP` 같은 [지원 로케일 코드](localization.md)를 사용합니다.
기존 `Korean`·`English` 값도 계속 읽을 수 있습니다.

지원하는 체크섬 값은 `auto`, `none`, `xxhash64`, `sha256`입니다. 콘텐츠 중복
제거에는 `sha256`이 필요합니다. 지원하는 압축 값은 `auto`, `none`,
`brotli`입니다. 현재 `auto`는 프로파일 결과에 따라 체크섬은 `xxhash64`,
압축은 `brotli`로 해석됩니다.

`storage.verify_staged_copies`는 기본적으로 `true`입니다. 원본을 복사하면서
SHA-256 해시를 비교하고, 일치하지 않으면 다시 시도합니다. `false`여도
복사본에서 압축·중복 확인을 진행하며 기존 메타데이터 검사는 유지됩니다.
진행 중 갱신되는 게임 파일을 백업할 때는 `false`로 낮추지 않는 것이 안전합니다.

`telemetry.enabled = false`는 해당 worker의 모든 telemetry 기록을 끕니다.
Telemetry 모드는 `off`, `run`, `phase`, `raw`입니다. 보존 한도나 데이터베이스
크기 한도가 0이면 무제한입니다. 배치 크기와 flush 간격은 0보다 커야 합니다.

유효 설정을 검증하거나 출력하는 명령:

```powershell
dotnet run --project src/PzTools.Backup.Cli -- config validate --repository C:\Backups\pz
dotnet run --project src/PzTools.Backup.Cli -- config show --repository C:\Backups\pz
```

사용 가능한 재정의 옵션:

```text
--repository <path>
--config <path>
--source <id>=<path>                 (반복 가능, TOML 소스 목록을 대체)
--always-include <relative-path>     (반복 가능, TOML 목록을 대체)
--checksum <auto|none|xxhash64|sha256>
--compression <auto|none|brotli>
--content-deduplication <true|false>
--verify-staged-copies <true|false>
--full-scan-hash-comparison <true|false>
--telemetry-enabled <true|false>
--telemetry-mode <off|run|phase|raw>
--telemetry-batch-size <integer>
--telemetry-flush-ms <integer>
--telemetry-retain-runs <integer>
--telemetry-max-database-mib <integer>
```

알 수 없는 키와 옵션은 오류입니다. 소스 ID는 대소문자를 구분하지 않고
고유해야 하며, 소스 루트끼리 겹칠 수 없고 어떤 소스도 저장소와 겹칠 수 없습니다.

## 프로세스별 설정

Runner, Scheduler, Maintenance와 상태 프로세스는 각자 `default.toml`을 가집니다.
배포물의 `defaults/<component>/default.toml`, 중앙 설정 폴더의
`<component>/default.toml`, 중복되는 앱 설정,
해당 프로세스에 직접 지정한 `--config` 순으로 적용합니다. 같은 앱 설치 안에서는
구성요소별 설정을 공유하고 저장소별로 달리 지정할 때는 `--config`를 사용합니다.
telemetry DB 등 실행 데이터는 기존 위치에 남습니다.

부모는 자신의 설정을 자식에게 자동 전달하지 않습니다. Backup/Maintenance
Runner의 `--worker-config`만 의도적인 자식 설정 재정의입니다. Scheduler는 Runner나
worker의 TOML을 전달하지 않으므로 각 프로세스 설정의 소유권이 유지됩니다.

Maintenance worker의 편집 가능한 기본 설정은 진단 기록만 포함합니다.
보관할 자동 백업 수는 앱에서 설정합니다. 수동 백업은 이 개수에 포함되지 않으며
사용자가 직접 삭제할 때까지 보존합니다. 생성 경로를 알 수 없는 기존 백업도
자동 정리에서 제외합니다. 자동 팩 재압축 옵션은 제거했습니다.

```toml
[telemetry]
enabled = true
retain_runs = 100
max_database_mib = 64
```

모든 프로세스의 원시 경계 telemetry는 `[telemetry]`의 `enabled`, `retain_runs`,
`max_database_mib`를 사용합니다. `retain_runs` 또는 `max_database_mib`가 0이면 해당
한도는 적용하지 않습니다. `max_database_mib`는 DB 파일 자체의 엄격한 크기
상한이 아니라 사용 중인 페이지를 기준으로 오래된 진단 기록을 정리하는 기준입니다.
백업 주기는 앱에서 설정합니다. StateScheduler의
`[scheduler].interval_seconds`는 `--interval-seconds`가 없을 때만 사용합니다.

Archive worker는 검사·가져오기 때 `[archive]`의 `maximum_entries`,
`maximum_single_file_bytes`, `minimum_free_space_reserve_bytes`,
`minimum_free_space_reserve_percent`를 읽습니다. 기본값과 의미는
`deployment-layout.md`에 기록합니다.
