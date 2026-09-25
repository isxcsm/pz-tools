# 구현 및 검증 보고서

## 2026-09-25 외부 리뷰 반영

검토 기준은 `dev`의 `2d9108c`와 이번 작업 트리 변경입니다. 기본 브랜치는
현재 `main`이며 개발 코드는 `dev`에서 관리합니다. 아래 결과는 로컬 Windows에서
실행한 결과이고, GitHub hosted runner에서 실행한 결과로 표현하지 않습니다.

| 리뷰 항목 | 판단과 처리 |
| --- | --- |
| 접근 실패를 삭제로 기록할 가능성 | 수용. USN 후보와 강제 수집 경로에서 오류를 숨기는 Exists 검사를 제거하고 실제 부재를 확인합니다. 판단 불가 시 리비전·체크포인트는 유지합니다. |
| 예상치 못한 target이 생기면 rollback 삭제 | 수용. 복원 journal v2에 staging 디렉터리 식별자를 기록합니다. 충돌과 구형 journal의 불확실한 상태는 원본·작업 기록을 보존합니다. 복구 중 재종료도 원본 식별자로 재개합니다. |
| 고아 백업 보존 정책 | 구현 오류가 아닌 정책 제안. 사용자 확인에 따라 기존 자동 정리를 유지합니다. 수동 백업도 예외가 아니므로 장기 보관은 ZIP 내보내기를 사용합니다. |
| .NET/배포 검증 CI 부재 | 수용. `windows.yml`에 Windows Release 빌드, 테스트, 새 배포본 생성, 배포물·worker 검증, 별도 synthetic JVM job을 추가했습니다. |
| UI 관리자 권한 요구 | 권한 분리 제안은 타당하나 별도 설계 작업입니다. 사용자 확인에 따라 현재 관리자 실행과 USN 동작을 유지합니다. |

로컬 검증:

- Release 솔루션 빌드: 경고 0, 오류 0.
- 새 배포본 `artifacts/app-review-safety` 생성 성공. 기존 실행 폴더를 덮어쓰지 않았습니다.
- 최종 Release 전체 테스트(새 배포본 연결): **676 통과, 0 실패, 22 건너뜀 / 698개**.
- 별도 synthetic JVM 브리지 검증: **22 통과, 0 실패, 실제 게임 probe 1개 건너뜀**.
  `scripts/test-save-bridge.ps1 -JdkPath <Java-25-JDK>`로 실행했습니다.
- 테스트 증거: `artifacts/review-test-results/review-distribution.trx` (Git 제외).
- README: 18개 언어, 로컬 링크·이미지 417개 검사 통과.

최종 테스트 재현:

```powershell
dotnet build PzTools.sln -c Release -p:Platform=x64 -warnaserror
pwsh scripts/publish-app.ps1 -Configuration Release -JdkPath C:\path\to\jdk-25 -Output artifacts/review-fresh
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/review-fresh).Path
$env:PZTOOLS_TOOLS_DIR = $env:PZTOOLS_DISTRIBUTION_DIR
dotnet test tests/PzTools.Backup.Tests -c Release --logger "trx;LogFileName=review.trx" --results-directory artifacts/review-test-results
```

CI는 `global.json`의 SDK와 Java 25, Windows 2025 runner를 사용합니다.
자동 실행에 실제 사용자 세이브, 실제 게임 PID, 관리자 USN opt-in을 제공하지
않습니다. JVM 검증은 별도 job에서 가짜 게임 프로세스만 사용합니다. TRX 결과는
커밋 SHA가 포함된 artifact 이름으로 업로드합니다. 일반 CI 통과만으로 실제 게임
연동이나 관리자 USN 실장 검증까지 완료됐다고 보지 않습니다.

## 2026-09-22 검증 기록

이하 기준일은 2026-09-22입니다. 자동화 가능한 구현·검증과 관리자 권한 USN 실장
테스트는 완료했으며, 네이티브 WinUI 육안 및 실제 플레이 흐름 확인만 남아 있습니다.

## 완료된 검증

| 항목 | 결과 |
|---|---|
| 최신 Release 전체 테스트 | 181개 중 179개 통과, 관리자 opt-in USN 2개 건너뜀 |
| 이전 관리자 Release 종단 테스트 | 당시 173개 모두 통과, 실패·건너뜀 없음 |
| 실제 USN 실장 | NTFS volume query와 journal range read 모두 통과 |
| 실제 세이브 표본 | `%USERPROFILE%\Zomboid\Saves`에서 생존·사망 표본 판정 통과 |
| 게시 프로세스 체인 | StateRunner, BackupRunner, MaintenanceRunner 종단 테스트 통과 |
| 게시 Archive CLI | backup → export → inspect → import 및 논리 파일 확인 통과 |
| AppHost 수명 | 두 Scheduler 시작, 종료 cancellation, bounded restart와 Faulted 게시 통과 |
| 게시 앱 종료 | 앱 종료 후 Scheduler·Runner·worker를 포함한 PzTools 프로세스 0개 확인 |
| 복구 장애 경계 | prepared, original-moved, installed journal 복구 및 범위 밖 inventory 거부 통과 |
| telemetry projection | 정상, disabled, stale, unreadable, future schema, instance 교체 통과 |
| telemetry backlog/retention | 단일 projection의 다중 page 소진과 trim된 run 메모리 제거 통과 |
| DB 미래 버전 방어 | State/Scheduler의 future schema 거부 및 버전 marker 보존 통과 |
| Maintenance admission | 삭제 리비전 batch 미만 skip, 임계치 도달 시 compaction/GC 통과 |
| Release 배포 | `scripts/publish-app.ps1` 성공, 앱과 10개 도구 실행 파일 게시 |
| 코드 형식 | `dotnet format PzTools.sln --verify-no-changes --no-restore` 통과 |
| 게시 CLI help | Backup, BackupScheduler, StateScheduler, Archive 명령 확인 |

Release 종단 테스트는 다음 opt-in 변수를 함께 사용했습니다.

```powershell
$env:PZTOOLS_TOOLS_DIR = (Resolve-Path 'artifacts/app').Path
$env:PZTOOLS_REAL_SAVES_ROOT = Join-Path $env:USERPROFILE 'Zomboid\Saves'
dotnet test tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj -c Release
```

## 최종 관리자 검증 결과

관리자 Windows PowerShell에서 `scripts/verify-a15.ps1`을 실행한 결과 Release 게시,
실제 세이브 표본, 게시 프로세스 종단 테스트와 실제 USN 테스트를 포함한 173개가
모두 통과했습니다. 앱 종료 후 잔류 PzTools 프로세스도 없었습니다.

```text
통과: 173, 실패: 0, 건너뜀: 0
앱 종료 후 잔류 PzTools 프로세스: 0
```

## 검증 실행 방법

두 묶음을 한 번에 실행할 수 있도록 `scripts/verify-a15.ps1`을 제공합니다. 관리자
PowerShell에서 실행하면 최신 Release 앱을 게시하고, 실제 USN·실제 세이브·게시
프로세스 종단 테스트를 실행한 뒤 앱을 엽니다. 사용자가 화면 체크리스트를 확인하고
앱을 닫으면 Scheduler·Runner·worker 잔류 프로세스도 검사합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-a15.ps1
```

이미 최신 게시 산출물이 있으면 `-SkipPublish`, 화면 검증을 별도로 할 때는
`-SkipApp`을 사용할 수 있습니다. PowerShell 7이 설치되어 있다면 같은 위치에서
`pwsh -File .\scripts\verify-a15.ps1`로 실행해도 됩니다.

### 관리자 권한 USN

비관리자 터미널에서는 볼륨 핸들을 열 때 Windows `액세스가 거부되었습니다`가
발생합니다. 앱 실행 manifest는 `requireAdministrator`이며, 관리자 PowerShell에서
다음 테스트가 실제로 통과하는 것을 확인했습니다. 재검증할 때는 다음 명령을
사용합니다.

```powershell
$env:PZTOOLS_TEST_USN = '1'
dotnet test tests/PzTools.Backup.Tests/PzTools.Backup.Tests.csproj `
  -c Release --no-build `
  --filter 'FullyQualifiedName~UsnRecordParserTests.QueryRealNtfsVolume_WhenExplicitlyEnabled|FullyQualifiedName~UsnRecordParserTests.ReadRangeRealNtfsVolume_WhenExplicitlyEnabled'
```

## 남은 WinUI 육안 및 실제 플레이 흐름

2026-09-22 재확인 결과 Computer Use의 `@oai/sky`로 네이티브 PzTools 창을 찾아
화면을 캡처할 수 있습니다. 기존 관리자 권한 VS 디버그 창에서는 접근성 트리가
창·제목 표시줄만 반환됐으며, 종료 키 입력은 반영되지 않았습니다. 자동 입력 검증을
완료한 것으로 보지 않습니다. 다음 항목은 최신 빌드를 실행해 확인해야 합니다.

- 한국어·영어 전환과 시스템·밝음·어두움 테마
- 넓은 3단 화면과 좁은 목록/상세 전환, 키보드 focus와 잘림
- 실제 플레이 시작 시 초록색 overlay, 진행 카드와 다음 백업 countdown
- 플레이 종료 후 final backup 1회 및 대상 해제
- 실제 화면에서 수동 백업, 복구 modal, archive 가져오기·내보내기

앱 종료 후 Scheduler·Runner·worker가 남지 않는 항목은 검증 스크립트에서 이미
통과했습니다.

이 화면·플레이 흐름 확인 결과까지 기록되면 로드맵 A15와 전체 목표를 완료로
표시할 수 있습니다.

### 2026-09-22 Fluent 화면 개선

- Mica, 통합 제목 표시줄, 테마 기반 카드 표면, 자동 축소 탐색 영역을 적용했습니다.
- 설정 입력 폭, 세이브 상세의 작은 창 배치, 로그 목록·상세의 반응형 배치를 보강했습니다.
- Release x64 앱 빌드: 오류 0, 경고 0.
- 기존 테스트: 통과 180, 실패 0, 환경 의존 테스트 건너뜀 7.
- 새 빌드의 육안 확인은 기존 디버그 실행 종료·재시작 대기 상태입니다.
  이전 화면 캡처와 빌드 성공을 새 화면의 시각적 검증으로 간주하지 않습니다.

### 탐색 여백·설정 그룹·로그 밀도 추가 개선

- 탐색 선택 표시줄의 좌우 여백과 설정 항목의 하단 여백을 확보하고 중복 테두리를 제거했습니다.
- 설정을 표준 `SettingsExpander.Items` 안의 `SettingsCard`로 묶었습니다.
- 정상 주기 점검 로그는 추적으로 분류하고, payload의 실패·저하 결과는 오류·경고로 유지합니다.
- 회귀 테스트: 181 통과, 실패 0, 환경 의존 7 건너뜀.
- 현재 디버그 앱의 실제 화면 캡처는 성공했습니다. 다만 설정 클릭을 두 입력 경로로
  시도해도 메뉴가 전환되지 않았으며, 외부 파일 수정의 XAML Hot Reload 반영도
  관찰되지 않았습니다. 따라서 이번 추가 변경의 새 화면·테마·클릭 E2E는 미검증입니다.
