# 구현 및 검증 보고서

기준일은 2026-09-22입니다. 자동화 가능한 구현·검증과 관리자 권한 USN 실장
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
