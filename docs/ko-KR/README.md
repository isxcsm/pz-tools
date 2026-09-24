<p align="center">
  <strong>한국어</strong> ·
  <a href="../../README.md">English</a> ·
  <a href="../zh-CN/README.md">简体中文</a> ·
  <a href="../zh-TW/README.md">繁體中文</a> ·
  <a href="../ja-JP/README.md">日本語</a> ·
  <a href="../ru-RU/README.md">Русский</a> ·
  <a href="../pt-BR/README.md">Português (Brasil)</a> ·
  <a href="../es-ES/README.md">Español (España)</a> ·
  <a href="../fr-FR/README.md">Français</a> ·
  <a href="../de-DE/README.md">Deutsch</a> ·
  <a href="../pl-PL/README.md">Polski</a> ·
  <a href="../tr-TR/README.md">Türkçe</a> ·
  <a href="../uk-UA/README.md">Українська</a> ·
  <a href="../it-IT/README.md">Italiano</a> ·
  <a href="../th-TH/README.md">ไทย</a> ·
  <a href="../id-ID/README.md">Bahasa Indonesia</a> ·
  <a href="../cs-CZ/README.md">Čeština</a> ·
  <a href="../es-MX/README.md">Español (Latinoamérica)</a>
</p>

<p align="center">
  <img src="../../src/PzTools.App/Assets/Navigation/pztools.svg" width="88" height="88" alt="PZ Tools" />
</p>

<h1 align="center">PZ Tools</h1>

<p align="center">
  <strong>살아남는 것은 플레이어의 몫. 돌아갈 시점을 남기는 것은 PZ Tools의 몫.</strong><br />
  Project Zomboid를 위한 자동 백업 · 세이브 히스토리 · 캐릭터 회복
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-x64-0078D4" alt="Windows x64" />
  <img src="https://img.shields.io/badge/UI-WinUI%203-1465AD" alt="WinUI 3" />
  <img src="https://img.shields.io/badge/.NET-10-512BD4" alt=".NET 10" />
  <img src="https://img.shields.io/badge/Languages-18-27B6B1" alt="18개 언어·로케일 지원" />
</p>

<p align="center">
  <a href="#주요-기능">주요 기능</a> ·
  <a href="#백업-엔진">백업 엔진</a> ·
  <a href="#시작하기">시작하기</a> ·
  <a href="#지원-범위와-주의사항">지원 범위</a> ·
  <a href="#빌드와-개발">빌드와 개발</a>
</p>

PZ Tools는 플레이 중인 세이브를 감지하고, 정해진 간격으로 백업하며, 썸네일과 캐릭터 정보로 돌아갈 시점을 고를 수 있게 해주는 Windows 앱입니다.

화면에서는 백업 하나를 선택하면 되지만, 그 뒤에서는 **게임 내 저장 요청, 파일 변경 추적, 증분 저장, 복사본 검증, 중단된 작업 복구**가 함께 동작합니다. 필요할 때는 월드를 되돌리지 않고 현재 캐릭터만 회복시킬 수도 있습니다.

## 주요 기능

| 원하는 것 | PZ Tools가 하는 일 |
| :--- | :--- |
| 플레이에 집중하기 | 플레이 중인 세이브 감지, 주기적 자동 백업, 다음 백업 카운트다운 |
| 중요한 순간 남기기 | 이름을 바꿀 수 있는 수동 백업, 자동 백업과 구분된 보관 정책 |
| 방금 플레이한 내용까지 저장하기 | 활성 월드에서 백업 전 `save(true)` 요청, 게임 속 5초 전 알림 |
| 돌아갈 시점 알아보기 | 썸네일, 캐릭터 이름, 생존 시간, 생존·사망 상태를 백업 목록에 표시 |
| 캐릭터만 회복하기 | 오프라인 치료·부활, 조건을 충족하는 본인 좀비의 소지품 회수 |
| 백업을 자주 남기기 | USN 변경 추적, 증분 저장, 압축, 선택적 콘텐츠 중복 제거 |
| 세이브 옮기기 | ZIP 검사·가져오기·내보내기, 선택한 백업 시점 복원 |
| 작업 상태 확인하기 | 진행률 카드, 실행별 로그, 오류·경고와 기술 정보 |

### 자동으로 남기는 기록, 직접 지키는 체크포인트

- **자동 백업** — 현재 플레이 중인 세이브를 대상으로 설정한 간격에 맞춰 실행합니다. 간격을 `0`으로 설정하면 자동 백업이 꺼집니다.
- **수동 백업** — 원할 때 직접 시점을 남기고, 알아보기 쉬운 이름으로 바꿀 수 있습니다.
- **구분되는 히스토리** — `수동 백업 N`과 `자동 백업 N`으로 생성하고 자동 백업은 별도로 표시합니다.
- **분리된 보관 정책** — 보관 개수에 따른 오래된 백업 정리는 자동 백업에만 적용합니다. 수동 백업은 이 정리 대상에서 제외합니다.
- **다음 실행 시각 표시** — 앱을 시작하면 설정된 간격부터 새로 카운트합니다. 지난 세션의 주기 예약이 밀렸다는 이유로 시작 직후 자동 백업하지 않습니다.

> 수동 백업의 보호는 **자동 백업 보관 개수 제한**에 대한 것입니다. 세이브·백업의 명시적 삭제나 원본 세이브가 사라진 고아 백업 정리는 별도 정책입니다. 장기 보관할 시점은 ZIP으로 내보내 두십시오.

### 디스크를 복사하기 전에, 게임에 저장을 요청합니다

게임 메모리의 최신 진행 상황과 디스크에 기록된 세이브는 같지 않을 수 있습니다. PZ Tools는 선택한 월드가 플레이 중일 때, 게임 스레드에서 `GameWindow.save(true)`를 호출하고 응답을 받은 뒤 파일 수집을 시작합니다.

- Workshop 모드 설치나 디버그 콘솔 조작 없이 연결합니다.
- 게임을 먼저 실행하고 PZ Tools를 나중에 켜도 연결할 수 있습니다.
- 게임 설치 파일이나 실행 옵션을 수정하지 않습니다. 연결에는 실행 중인 JVM에 로드하는 에이전트를 사용합니다.
- 캐릭터 머리 위에 **저장까지 5 → 4 → 3 → 2 → 1초**, 게임 저장 호출이 끝나면 **저장 완료**를 표시합니다.
- 자동 백업은 예정 시각에 앞서 연결을 준비합니다. 카운트가 `0`이 된 뒤 다시 5초를 기다리는 방식이 아닙니다.
- **백업 전 게임 저장**과 **게임 내 카운트다운**은 설정에서 각각 끌 수 있습니다.

게임 저장 호출 실패나 응답 불명 상태를 성공으로 처리하지 않습니다. 게임이 메뉴에 있거나 선택한 세이브를 플레이 중이 아니면 게임 저장 요청 없이 디스크의 세이브를 백업합니다.

게임 속 ‘저장 완료’는 게임 저장 호출의 반환을 뜻합니다. 이후 파일 수집·압축까지 끝난 **백업 완료**는 앱에서 따로 표시합니다. 연결 지연이나 게임 프레임 정지 상황의 정확한 초 단위 실행까지 보장하지는 않습니다.

자세한 연결 방식과 호환성은 [게임 저장 브리지 문서](../save-bridge.md)를 참고하십시오.

### 파일명 대신, 플레이 기록으로 고르는 복원 시점

현재 세이브와 백업 히스토리를 나란히 확인할 수 있습니다. 썸네일, 캐릭터 이름, 생존 시간, 사망 표시와 기록 시각을 보고 원하는 백업을 선택하십시오.

- 선택한 시점으로 세이브 복원
- 현재 세이브 또는 백업 리비전의 ZIP 내보내기
- ZIP 내부 검사 후 세이브 가져오기
- 플레이 중 원본을 덮어쓰는 작업 등 충돌 위험이 있는 동작 제한

복원은 임시 영역에 데이터를 준비하고 작업 기록을 남기는 방식으로 진행합니다. 중간에 종료되면 다음 실행의 복구 처리에서 남은 작업을 확인합니다.

### 월드를 되돌리지 않고, 캐릭터를 회복합니다

**현재 세이브를 플레이하지 않을 때만** 확인 모달을 거쳐 실행합니다. 과거 백업 리비전을 편집하지 않습니다.

| 회복하는 것 | 유지하는 것 |
| :--- | :--- |
| 체력·허기·갈증·피로·지구력과 정신 상태 | 긍정적·부정적 특성 |
| 17개 신체 부위의 상처·골절·화상·출혈 | 경험치·기술·레시피 |
| 박힌 유리·총알, 감염·질병·중독과 관련 타이머 | 외형·위치·생존 시간 |
| 스트레스·통증·공황·니코틴 금단 등 일시적 상태 | 체중·영양·운동 기록과 기존 소지품 |
| 사망 플래그와 회복 가능한 캐릭터 상태 | 알 수 없는 모드 데이터는 원형 보존 |

**부정적 특성은 치료 대상이 아닙니다.** 특성과 경험치 영역은 바이트 단위로 보존합니다. 회복은 영구 무적 기능이 아니므로 특성이나 주변 환경에 따라 증상이 다시 생길 수 있습니다.

사망 후 인벤토리가 비어 있다면, 저장 위치와 신분증의 캐릭터 이름이 일치하는 **본인 좀비 기록**에서 소지품과 가방 내부 데이터를 회수하는 경로도 제공합니다. 일치 대상이 모호하거나 지원하지 않는 형식이면 추측해서 덮어쓰지 않습니다. 이동한 좀비, 신분증이 없는 대상, 맵 청크에 저장된 시체는 현재 회수 경로에서 지원하지 않습니다.

지원 형식과 아이템·장착 상태의 세부 제한은 [캐릭터 회복 문서](../character-recovery.md)에 정리되어 있습니다.

### 일상적인 사용도 챙겼습니다

- **18개 언어·로케일** — 한국어, 영어, 중국어 간체·번체, 일본어, 러시아어, 브라질 포르투갈어, 스페인·라틴아메리카 스페인어, 프랑스어, 독일어, 폴란드어, 튀르키예어, 우크라이나어, 이탈리아어, 태국어, 인도네시아어, 체코어
- 화면 문구·백업 기본 이름·게임 내 저장 알림을 선택한 언어로 표시 ([번역 범위와 검증](../localization.md))
- 시스템·밝음·어두움 테마
- 선택 가능한 시스템 트레이 동작과 앱 중복 실행 방지
- 백업·복원·압축·삭제 작업의 진행률 카드
- 수준·작업 종류·실행 번호로 찾는 로그와 복사 가능한 기술 정보
- 일반 설정은 화면에서, 고급 동작은 구성요소별 TOML에서 조정

## 백업 엔진

### 변경된 파일을 찾고, 검증된 내용만 저장합니다

| 계층 | 동작 |
| :--- | :--- |
| 변경 추적 | 사용 가능한 NTFS USN 저널에서 변경을 추적합니다. 내용 변경 기록이 있으면 크기·수정 시각이 같아도 다시 수집합니다. |
| 폴백 | USN을 사용할 수 없거나 체크포인트가 유효하지 않으면 전수조사로 전환합니다. 기본적으로 SHA-256 내용 비교도 수행합니다. |
| 주요 파일 | `players.db`, `vehicles.db`, `thumb.png`는 기본 강제 수집 목록으로 관리합니다. 일반 변경 감지 결과에만 의존하지 않습니다. |
| 캡처 검증 | 원본과 임시 복사본의 해시를 비교하고, 일치하지 않으면 재시도합니다. 안정적으로 읽지 못하면 해당 백업을 실패 처리합니다. |
| 저장 | 변경 데이터를 불변 팩에 기록하고 SQLite 메타데이터로 리비전을 구성합니다. 매번 전체 세이브 사본을 만드는 방식이 아닙니다. |
| 공간 관리 | Brotli 압축, 선택적 콘텐츠 중복 제거, 오래된 자동 백업 정리, 미사용 객체 회수와 팩 재구성을 제공합니다. |

콘텐츠 중복 제거는 선택 기능입니다. 해시 비교와 캡처 검증도 조정할 수 있지만, 검증을 끄면 변경 누락이나 불안정한 파일을 걸러내는 능력이 줄어듭니다.

### 무거운 작업과 화면을 분리합니다

파일 수집·압축·복원·정리는 별도 작업 프로세스가 수행하고, 앱은 상태와 진행률을 표시합니다. 진행 이벤트는 묶어서 기록하고 최신 상태 위주로 반영하여 파일마다 UI를 갱신하는 비용을 줄입니다.

같은 저장소를 변경하는 작업은 직렬화합니다. 임시 파일과 게시 중인 데이터는 작업 기록을 통해 추적하고, 다음 시작과 유지보수 과정에서 중단된 작업을 복구·정리합니다. **강제 종료를 무시하는 대신, 어디까지 처리했는지를 남기는 구조**입니다.

측정 조건·결과·재현 명령은 [성능 프로파일](../performance-profile.md)에 공개되어 있습니다. 초기 백업, 증분 백업, 복원, 메모리 사용량과 저장소 크기를 함께 측정합니다. 실제 성능은 파일 수·크기·압축 가능성·디스크에 따라 달라집니다.

## 시작하기

### 실행 환경

- **Windows x64**, **.NET 10 런타임**
- WinUI 구성요소와 게임 저장 브리지용 Java 실행환경은 게시된 배포본에 포함됩니다.
- 게임 연동과 캐릭터 회복의 지원 범위는 [아래 호환성 표](#지원-범위와-주의사항)를 확인하십시오.

소스에서 배포본을 만드는 방법은 [빌드와 개발](#빌드와-개발)에 있습니다.

1. 배포 폴더의 `PzTools.App.exe`를 실행합니다.
2. 설정에서 세이브 디렉터리와 백업 디렉터리를 확인합니다.
3. 자동 백업 간격과 보관 개수를 정합니다. 게임 저장 연동과 알림도 여기서 선택합니다.
4. 세이브를 선택해 수동 백업을 남기거나, 플레이 중 자동 백업을 사용합니다.
5. 돌아가고 싶을 때는 해당 세이브의 플레이를 끝낸 뒤 백업을 선택해 복원합니다.

처음 실행할 때의 기본값은 **백업 간격 5분 · 자동 백업 보관 20개**입니다. 기존에 저장한 사용자 설정은 유지합니다.

설정과 제어 데이터는 `%LOCALAPPDATA%\PzTools`에, 백업 데이터는 지정한 백업 디렉터리에 저장합니다. 원본 세이브 안에 앱 관리용 DB를 추가하지 않습니다.

## 지원 범위와 주의사항

| 기능 | 현재 범위 |
| :--- | :--- |
| 앱·백업 엔진 | Windows x64. USN을 사용할 수 없는 환경에서는 전수조사로 폴백합니다. |
| 백업 전 게임 저장 | 검사한 Java 25 / Build 42 메서드 구조를 대상으로 하는 실험적 어댑터입니다. 멀티플레이는 지원하지 않습니다. |
| 캐릭터 회복 | Build **42.20.4**, 월드 형식 **249**, 로컬 플레이어 **1명(ID 1)**. 다른 형식·다중 플레이어·검증 불가 데이터는 거부합니다. |
| 모드 호환성 | 저장 구조를 바꾸는 모드나 게임 업데이트의 호환성을 일괄 보장하지 않습니다. 모드 고유의 디버프를 모두 해석하거나 제거하지 않습니다. |

> **알아두십시오.** `save(true)` 호출 반환과 개별 파일 검증은 월드 전체의 원자적 스냅샷을 보장하지 않습니다. 백업 수집 중에도 게임은 파일을 갱신할 수 있습니다. 또한 같은 디스크의 백업은 디스크 고장까지 대비하지 못합니다. 중요한 시점은 ZIP으로 내보내 별도 저장장치에도 보관하십시오.

게임 업데이트나 별도 저장 모드 때문에 연동을 사용하지 않으려면 **백업 전 게임 저장**을 끌 수 있습니다. 이때는 디스크에 기록된 내용만 백업하므로 아직 메모리에만 있는 진행 상황은 포함되지 않을 수 있습니다.

## 빌드와 개발

<details>
<summary><strong>소스 빌드 · 테스트 · 배포</strong></summary>

.NET 10 SDK, Windows/WinUI 빌드 환경, Windows x64 Java 25 JDK와 Visual Studio x64 C++ 빌드 도구가 필요합니다. 브리지의 JDK 선택 규칙과 네이티브 빌드는 [저장 브리지 빌드 안내](../save-bridge.md#building-and-publishing)를 참고하십시오.

```powershell
dotnet build PzTools.sln -p:JdkPath=C:\path\to\jdk-25
dotnet test PzTools.sln -p:JdkPath=C:\path\to\jdk-25
pwsh scripts/publish-tools.ps1 -JdkPath C:\path\to\jdk-25
pwsh scripts/publish-app.ps1 -JdkPath C:\path\to\jdk-25 -Output artifacts/app-local
```

게시 스크립트는 **새 폴더 또는 빈 폴더**만 받습니다. 다시 게시할 때는 다른 `-Output` 경로를 지정하십시오. 기존 설치 폴더나 사용자 설정을 자동으로 삭제하지 않습니다.

배포본 구성과 실제 작업 프로세스 검증:

```powershell
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/app-local).Path
$env:PZTOOLS_TOOLS_DIR = $env:PZTOOLS_DISTRIBUTION_DIR
dotnet test tests/PzTools.Backup.Tests -c Release
```

관리자 권한 USN, 실제 세이브와 게시 앱 수명까지 포함하는 별도 검증 스크립트도 있습니다. 실행 대상과 조건을 [검증 보고서](../verification-report.md)에서 먼저 확인하십시오.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-a15.ps1
```

배포에는 필요한 WinUI 구성요소와 작은 Java Attach 런타임을 포함합니다. 사용하지 않는 Windows App SDK AI/ML·위젯·프레임워크 설치 패키지는 NuGet 자산 단계에서 제외합니다. 게임 JAR는 배포하지 않으며, PDB는 배포본에서 제외하고 빌드 출력에 유지합니다. 배포 후 SDK 파일을 임의 삭제하거나 UI 바인딩·직렬화 코드를 무리하게 trimming하지 않습니다.

</details>

<details>
<summary><strong>CLI · 고급 설정</strong></summary>

GUI 없이도 백업·복원·검증·유지보수와 ZIP 작업을 실행할 수 있습니다. 범용 백업 엔진은 게임에 종속되지 않습니다.

```powershell
dotnet run --project src/PzTools.Backup.Cli -- config validate --repository <path>
dotnet run --project src/PzTools.Backup.Cli -- config show --repository <path>
dotnet run --project src/PzTools.Backup.Cli -- backup --repository <path> --source-id <id>
dotnet run --project src/PzTools.Backup.Cli -- verify --repository <path>
dotnet run --project src/PzTools.Backup.Cli -- restore --repository <path> --source-id <id> --revision <n> --target <save-path>
dotnet run --project src/PzTools.Backup.Cli -- maintenance prune --repository <path> --source-id <id> --keep <n>
dotnet run --project src/PzTools.Backup.Cli -- maintenance gc --repository <path>
dotnet run --project src/PzTools.Backup.Cli -- maintenance compact --repository <path> --max-pack-mib <n>
```

직접 CLI에서 게임 저장 연동까지 사용하려면 `backup`에 `--save-game`을 전달하십시오. 진단용 JSON 카탈로그 명령 `scan <source> <catalog.json>`, `diff <source> <catalog.json>`도 유지합니다.

```powershell
dotnet run --project src/PzTools.Zomboid.Archive.Cli -- inspect --archive <file.zip>
dotnet run --project src/PzTools.Zomboid.Archive.Cli -- export --repository <path> --source-id <id> --revision <n> --output <file.zip>
dotnet run --project src/PzTools.Zomboid.Archive.Cli -- import --archive <file.zip> --saves-root <saves-path>
```

주요 수집 기본값:

```toml
[capture]
always_include = ["players.db", "vehicles.db", "thumb.png"]
full_scan_hash_comparison = true

[storage]
checksum = "auto"
compression = "auto"
content_deduplication = false
verify_staged_copies = true
```

`auto`는 현재 체크섬에 xxHash64, 압축에 Brotli를 사용합니다. 콘텐츠 중복 제거에는 SHA-256이 필요합니다. `always_include`는 CLI의 반복 가능한 `--always-include <상대경로>`로 재정의할 수 있습니다.

`full_scan_hash_comparison = false`는 전수조사 시 내용 비교를 끄지만 `always_include`와 백업 무결성 검증을 끄지는 않습니다. 기존 비교 해시도 삭제하지 않습니다. 전체 설정과 우선순위는 [설정 문서](../configuration.md), 명령과 종료 코드는 [CLI 문서](../cli.md)를 참고하십시오.

</details>

## 설계 문서

| 주제 | 문서 |
| :--- | :--- |
| 게임 연동 | [게임 저장 브리지](../save-bridge.md) · [오프라인 캐릭터 회복](../character-recovery.md) |
| 백업 정확성 | [USN 변경 추적](../usn-journal.md) · [안정적 파일 캡처](../stable-capture.md) |
| 저장 구조 | [저장소 형식](../repository-format.md) · [불변 팩 형식](../pack-format.md) |
| 작업과 관측 | [프로세스 구조](../process-architecture.md) · [Telemetry](../telemetry.md) |
| 설정과 배포 | [설정](../configuration.md) · [런타임 구성](../runtime-configuration.md) · [배포 경로](../deployment-layout.md) |
| 검증 | [성능 프로파일](../performance-profile.md) · [검증 보고서](../verification-report.md) |
| 개발 계획 | [구현 로드맵](../implementation-roadmap.md) · [UI/UX 계약](../ui-ux-contract.md) |

---

PZ Tools는 Project Zomboid의 비공식 도구입니다. The Indie Stone의 공식 제품이 아닙니다.
