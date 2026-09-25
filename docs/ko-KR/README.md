<p>
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

# PZ Tools

PZ Tools는 Project Zomboid 세이브를 백업하고 복원하는 Windows 앱입니다. 지원하는 세이브 형식에서는 캐릭터 회복도 제공합니다. The Indie Stone의 공식 제품은 아닙니다.

<a id="features"></a>
<a id="주요-기능"></a>
## 주요 기능

수동·자동 백업, 이름을 지정할 수 있는 백업 목록, 썸네일과 캐릭터 정보, ZIP 가져오기·내보내기, 플레이 종료 후 캐릭터 치료·부활을 제공합니다. 화면, 새 백업의 기본 이름, 게임 저장 알림은 18개 언어를 지원합니다. 테마, 시스템 트레이, 작업 진행률과 로그 필터도 사용할 수 있습니다.

<a id="getting-started"></a>
<a id="시작하기"></a>
## 설치와 실행

**Windows x64**와 Windows x64용 **[.NET 10 런타임](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**이 필요합니다. 현재 앱은 USN 파일 변경 추적을 위해 관리자 권한을 요청합니다. 게시된 배포본에는 WinUI 구성요소와 게임 연결용 소형 Java 런타임이 포함되며, 게임 JAR 파일은 포함되지 않습니다.

실행용 패키지는 [Releases](https://github.com/isxcsm/pz-tools/releases)에서 확인하세요. 게시된 패키지가 없으면 아래 소스 빌드 절차를 이용하세요. GitHub의 **Source code ZIP은 실행용 패키지가 아닙니다**.

1. 패키지 **전체를** 한 폴더에 압축 해제하고 `PzTools.App.exe`를 실행하세요. EXE만 옮기거나 서로 다른 빌드의 파일을 섞지 마세요.
2. 설정에서 세이브 폴더를 확인하고 별도의 백업 폴더를 지정하세요. 게임 세이브 폴더를 백업 위치로 사용하지 마세요.
3. 세이브를 선택해 수동 백업을 만들고 앱에서 완료 여부를 확인하세요. 자동 백업 간격과 보관 개수도 설정하세요.
4. 업데이트할 때는 PZ Tools를 종료하고 새 패키지 전체를 다른 폴더에 준비하세요. 세이브와 백업 데이터는 앱 파일과 따로 보관하세요.

설정과 제어 데이터는 `%LOCALAPPDATA%\PzTools`, 백업은 지정한 폴더에 저장됩니다. [배포 및 데이터 경로](../deployment-layout.md)에 상세 위치가 있습니다.

<a id="backups-and-retention"></a>
## 백업 보관과 삭제

초기 설정은 **5분 간격, 자동 백업 20개 보관**입니다. 자동 백업 토글로 켜거나 끄며, 간격은 1~60분으로 설정합니다. 꺼도 간격은 유지됩니다. 자동 백업은 플레이 중인 세이브를 대상으로 하며, 앱을 재시작하면 새 간격을 시작합니다. 기존 사용자 설정은 유지됩니다.

수동 백업은 이름을 바꿀 수 있고 자동 백업 보관 개수 제한에서는 제외됩니다. **영구 보관을 뜻하지는 않습니다.** 직접 삭제하거나 원본 세이브가 사라져 백업 정리가 실행되면 수동 백업도 삭제될 수 있습니다. 원본 세이브를 삭제하거나 옮기기 전에 중요한 백업을 ZIP으로 내보내 다른 드라이브에 보관하세요.

백업만 삭제하면 현재 세이브는 유지되지만 삭제한 백업은 복원·내보내기할 수 없습니다. 앱에서 세이브를 삭제하면 해당 백업도 제거합니다. 저장 공간 정리는 나중에 실행될 수 있어 삭제 직후 파일 크기가 줄지 않을 수 있습니다. [설정](../configuration.md)과 [백업 정리 정책 — 영어](../repository-housekeeping.md)을 참고하세요.

<a id="game-saving"></a>
## 백업 전 게임 저장

선택 기능인 게임 연결은 파일을 복사하기 전에 플레이 중인 게임에 저장을 요청합니다. JVM 에이전트를 사용해 게임 스레드에서 `GameWindow.save(true)`를 호출합니다. Workshop 모드나 게임 설치 파일 수정은 필요하지 않습니다. 확인된 **Build 42 / Java 25 싱글플레이** 구조를 대상으로 하는 실험적 기능이며 멀티플레이는 지원하지 않습니다.

게임 저장과 5초 카운트다운은 각각 켜고 끌 수 있습니다. **‘게임 저장 완료’는 ‘백업 완료’가 아닙니다.** 이후 파일 복사와 압축이 진행됩니다. 연결을 끄거나 플레이 중이 아닌 세이브를 백업하면 디스크에 기록된 내용만 포함됩니다. 저장 요청이 실패하거나 응답이 불확실하면 성공으로 표시하지 않습니다. [게임 저장 연동 — 영어](../save-bridge.md)에 동작과 제한을 정리했습니다.

<a id="restore-and-archives"></a>
## 복원과 ZIP 가져오기·내보내기

복원할 세이브의 플레이를 먼저 종료하세요. 백업을 선택하고 확인 창의 대상을 확인하세요. **복원하면 현재 파일을 교체하므로 그 백업 이후의 진행 내용은 사라집니다.** 복원이 중단됐다면 게임에서 세이브를 불러오기 전에 PZ Tools를 다시 실행해 상태를 확인하세요. 자동으로 이전 상태에 돌아갔다고 가정하지 마세요.

현재 세이브나 백업을 ZIP으로 내보낼 수 있고, ZIP의 내용을 확인한 뒤 가져올 수 있습니다. 장기 보관용 ZIP은 앱의 백업 폴더 밖에 보관하세요. 같은 드라이브의 백업은 드라이브 고장에 대비하지 못합니다. [명령줄 사용법](../cli.md)에서 동일한 작업의 CLI 명령을 확인할 수 있습니다.

<a id="character-recovery"></a>
## 캐릭터 회복

먼저 수동 백업이나 ZIP 내보내기를 하세요. **캐릭터 회복은 원본 파일의 추가 백업을 만들지 않습니다.** 플레이 중이 아닌 현재 세이브만 수정하며 과거 백업은 편집하지 않습니다. 지원 범위는 **Build 42.20.4, 월드 형식 249, 로컬 플레이어 1명(ID 1)**입니다.

치료·부활은 체력을 회복하고 지원하는 부상과 일시적 상태를 해제합니다. 긍정적·부정적 특성, 경험치, 기술, 레시피, 기존 소지품은 유지합니다. 영구 면역 기능이 아니며 모드 고유의 효과를 모두 제거하지는 않습니다.

사망으로 비워진 소지품은 본인의 좀비 또는 시체에서 회수하고 해당 원본을 제거합니다. 신분증은 필요하지 않습니다. 물건 상태·가방 내용·착용 및 부착 정보를 유지하며, 손장비는 저장된 아이템 식별자가 있을 때 복원합니다. 이미 사라진 물건을 만들지 않으며, 본인 여부가 불확실하면 변경하지 않습니다. [캐릭터 회복과 제한 — 영어](../character-recovery.md)

<a id="backup-engine"></a>
<a id="백업-엔진"></a>
<a id="compatibility-and-limits"></a>
<a id="지원-범위와-주의사항"></a>
## 저장 방식과 호환성

매번 세이브 전체를 복제하지 않고 변경된 데이터를 저장합니다. 가능한 환경에서는 NTFS USN으로 변경을 추적하고, 사용할 수 없으면 전체 스캔과 내용 비교로 전환합니다. 복사본 검증과 Brotli 압축은 기본으로 켜져 있으며 중복 데이터 제거는 선택 사항입니다. 게임 저장 응답과 개별 파일 검증이 **모든 파일이 정확히 같은 순간의 상태라는 것까지 보장하지는 않습니다**.

배포 전 개발 단계이므로 호환되지 않는 백업 저장소는 `repository-reset-required`로 거부합니다. 자동 변환하거나 삭제하지 않습니다. **새 빈 백업 폴더**를 선택하고 필요한 이전 백업은 기존 폴더째 보관하세요. **오류 해결을 위해 `Zomboid/Saves`나 `repository.db`만 따로 삭제하지 마세요.** 현재 형식·스키마는 [저장소 형식](../repository-format.md), 고급 옵션은 [실행 설정 — 영어](../runtime-configuration.md)에 있습니다.

<a id="troubleshooting"></a>
## 문제 해결과 문의

앱이 시작되지 않으면 런타임 설치와 전체 패키지 구성을 확인하세요. 파일 사용 중 또는 계속 변경 중이라는 오류가 나면 게임 저장이 끝난 뒤 백업을 다시 시도하세요. 자동 백업이 실행되지 않으면 간격, 플레이 중인 세이브와 PZ Tools 실행 여부를 확인하세요. 트레이로 창을 닫는 것은 앱 종료가 아닙니다.

작업이 실패하거나 일부만 완료됐다면 반복 실행하기 전에 로그를 확인하세요. 복원이나 캐릭터 편집이 중단된 상태에서는 먼저 처리 상태를 확인해야 합니다. [이슈](https://github.com/isxcsm/pz-tools/issues)에 문의할 때 앱 버전·커밋, 게임 버전, 재현 순서와 관련 로그를 적어 주세요. 개인 경로와 민감한 정보는 지우고, 필요하지 않은 전체 세이브는 첨부하지 마세요.

<a id="building"></a>
<a id="빌드와-개발"></a>
## 소스 빌드

Windows, `global.json`에 지정된 .NET SDK, PowerShell 7, Windows x64 Java 25 JDK, Visual Studio C++·WinUI 빌드 도구가 필요합니다. 저장소 루트에서 예시 JDK 경로를 실제 경로로 바꿔 실행하세요.

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release -p:JdkPath="$jdk"
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

게시 스크립트는 **새 폴더 또는 빈 폴더**에 앱과 작업 프로그램을 함께 준비합니다. 다시 빌드할 때는 다른 출력 경로를 사용하세요. [개발·검증 안내 — 영어](../development.md)에 의존성, 배포본 검사, CLI 사용법과 별도 동의가 필요한 테스트를 정리했습니다.

<a id="technical-documentation"></a>
## 문서

[문서 목차 — 영어·한국어](../README.md)에서 모든 참고 문서와 원문 언어를 확인할 수 있습니다. [다국어 처리 — 영어](../localization.md)는 번역 범위를 설명합니다. [검증 보고서](../verification-report.md)는 작성 시점의 결과이며 이후 모든 커밋이나 게임 버전의 통과를 보장하지 않습니다. [외부 구성요소 고지 — 영어](../../THIRD_PARTY_NOTICES.md)도 확인하세요.
