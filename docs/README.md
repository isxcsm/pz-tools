# Documentation / 문서 목차

[English user guide](../README.md) · [한국어 사용 안내](ko-KR/README.md)

Start with the guide in your language for installation, backup retention, restore
warnings and troubleshooting. The reference documents below retain their original
languages, shown in the tables; a translated link label does not mean the target
itself has been translated.

설치·백업 보관·복원 주의사항·문제 해결은 아래 언어별 사용 안내부터 읽으세요.
참고 문서는 표에 표시한 원문 언어로 제공됩니다. 번역된 링크 이름과 문서 본문의
언어를 혼동하지 않도록 구분했습니다.

## User guides / 언어별 사용 안내

Every guide covers the same user topics and links directly to the same references.
GitHub does not switch README language automatically; select a guide explicitly.
모든 안내는 같은 사용 주제와 참고 링크를 제공하며 언어를 직접 선택해야 합니다.

| Language / 언어 | Guide / 안내 |
| --- | --- |
| English | [English](../README.md) |
| 한국어 | [한국어](ko-KR/README.md) |
| 简体中文 | [简体中文](zh-CN/README.md) |
| 繁體中文 | [繁體中文](zh-TW/README.md) |
| 日本語 | [日本語](ja-JP/README.md) |
| Русский | [Русский](ru-RU/README.md) |
| Português (Brasil) | [Português (Brasil)](pt-BR/README.md) |
| Español (España) | [Español (España)](es-ES/README.md) |
| Français | [Français](fr-FR/README.md) |
| Deutsch | [Deutsch](de-DE/README.md) |
| Polski | [Polski](pl-PL/README.md) |
| Türkçe | [Türkçe](tr-TR/README.md) |
| Українська | [Українська](uk-UA/README.md) |
| Italiano | [Italiano](it-IT/README.md) |
| ไทย | [ไทย](th-TH/README.md) |
| Bahasa Indonesia | [Bahasa Indonesia](id-ID/README.md) |
| Čeština | [Čeština](cs-CZ/README.md) |
| Español (Latinoamérica) | [Español (Latinoamérica)](es-MX/README.md) |

## Setup and operations / 설치와 사용

| Document / 문서 | Original language / 원문 | Purpose / 내용 |
| --- | --- | --- |
| [Development and validation / 개발·검증](development.md) | English | Build dependencies, publishing, distribution tests and opt-in tests / 빌드·게시·검증 |
| [Configuration / 설정](configuration.md) | 한국어 | Ordinary settings and worker options / 일반 설정과 작업 프로그램 옵션 |
| [Advanced runtime configuration / 고급 실행 설정](runtime-configuration.md) | English | Per-component tuning and validation / 구성요소별 설정 |
| [Deployment layout / 배포·데이터 경로](deployment-layout.md) | 한국어 | App files, user data and backup folders / 실행 파일과 데이터 구분 |
| [CLI commands / 명령줄](cli.md) | 한국어 | Backup, restore, ZIP and maintenance commands / 작업별 명령 |
| [Game extensions / 게임 확장](game-extensions.md) | English | Vehicle extension, standard game saving and compatibility boundaries / 차량 확장·기본 게임 저장·호환 범위 |
| [Runtime pause / 게임 상태·일시정지](runtime-pause-backups.md) | English | Observation, pause/resume, guarded saving and state ownership / 관측·시간·저장 안전성 |
| [Game-save bridge / 게임 저장 연동](save-bridge.md) | English | Connection behavior, game-version limits and build details / 게임 연결과 제한 |
| [Character recovery / 캐릭터 회복](character-recovery.md) | English | Supported edits, inventory limits and interrupted edits / 지원 범위와 중단 처리 |

## Storage and application design / 저장소·앱 설계

| Document / 문서 | Original language / 원문 | Purpose / 내용 |
| --- | --- | --- |
| [Repository format / 저장소 형식](repository-format.md) | 한국어 | Current format/schema and incompatibility handling / 현재 저장 형식과 호환성 |
| [Compact representation / 저장 표현 경량화](compact-repository-format.md) | English | IDs, timestamps, checksums and dated layout comparisons / 저장 표현과 측정 |
| [Path normalization / 경로 정규화](path-normalization.md) | English | Shared path identities and historical spelling / 경로 공유와 과거 표기 |
| [Repository housekeeping / 백업 정리](repository-housekeeping.md) | English | Revision/history cleanup and DB space recovery / 이력·공간 정리 |
| [Pack format / 팩 형식](pack-format.md) | 한국어 | Immutable data containers and checksums / 백업 데이터 구조 |
| [USN tracking / USN 변경 추적](usn-journal.md) | 한국어 | Windows file-change tracking and fallback / 변경 감지와 전체 스캔 |
| [Stable capture / 파일 복사 검증](stable-capture.md) | 한국어 | Copy verification, retries and inaccessible files / 검증·재시도·접근 실패 |
| [Process architecture / 프로세스 구조](process-architecture.md) | 한국어 | Workers, scheduling, ownership and recovery / 작업 프로세스와 복구 |
| [JVM component reload / JVM 구성요소 교체](module-reload.md) | English | Compatible updates and generation ownership / 호환 업데이트와 작업 소유권 |
| [Vehicle drivetrain design / 차량 구동계 확장 설계](vehicle-drivetrain-design.md) | 한국어 | Torque/shift/reverse implementation design, integration risks and validation gates / 차량 구동계 구현 설계·위험·검증 기준 |
| [Vehicle drivetrain E2E / 차량 구동계 E2E](e2e-vehicle-drivetrain.md) | 한국어 | Experimental candidate setup, user driving checks, tuning and rollback / 실행 후보·사용자 주행 검증·튜닝·복귀 |
| [Telemetry / 진단 기록](telemetry.md) | 한국어 | Event storage, projections and progress / 로그와 진행률 |
| [UI contract / 화면 설계](ui-ux-contract.md) | 한국어 | View and interaction contract; compare with current implementation / 화면·상호작용 계약 |
| [UI assets / 앱 아이콘](ui-assets.md) | 한국어 | Icon sources and generated assets / 아이콘 원본과 생성물 |
| [Localization / 다국어 처리](localization.md) | English | Resource sources, settings and translation checks / 번역 원본과 검증 |
| [Documentation maintenance / 문서 유지보수](documentation-maintenance.md) | English / 한국어 | Topic parity, link rules and validation limits / 내용·링크 검사 기준 |
| [Third-party notices / 외부 구성요소 고지](../THIRD_PARTY_NOTICES.md) | English | Dependency notices / 의존성 고지 |

<a id="measurements-and-history"></a>
## Measurements and historical records / 측정·과거 기록

These are records of the named scenario, date or commit. Test counts and performance
figures are not current guarantees. Use the current repository format and CI results
for the commit you plan to run; do not follow an old reset or migration plan blindly.

아래 문서는 명시된 시점·커밋·조건의 기록입니다. 과거 통과 건수나 성능 수치를
현재 결과로 읽지 마세요. 사용할 커밋의 저장 형식과 CI 결과를 확인하세요.

| Document / 문서 | Original language / 원문 | Scope / 범위 |
| --- | --- | --- |
| [Verification report / 검증 보고서](verification-report.md) | 한국어 | Dated local checks and remaining manual checks / 시점별 검증 기록 |
| [Performance profile / 성능 프로파일](performance-profile.md) | 한국어 | Profiling method and measurements / 프로파일링 조건과 수치 |
| [Storage performance follow-up / 저장소 성능 개선](storage-performance.md) | English | Implementation notes with commit-specific benchmarks / 구현과 당시 측정 |
| [Gameplay background load / 플레이 중 백그라운드 부하](gameplay-background-load.md) | English | Save preservation, resident bootstrap, idle maintenance and state polling / 저장 보존·에이전트·점검 |
| [Storage hotpaths / 저장소 주요 경로](storage-hotpaths.md) | English | Request lookup, reader reuse and bounded collection / 조회·리더·정리 |
| [Active-only backup and follow-up / 자동 백업과 추가 최적화](active-backup-followup.md) | English | Exit/settings guards, scan queries, thumbnails, restore and version inspection / 종료·간격 설정·추가 최적화 |
| [Connection and merge review / 연결·병합 검토](connection-startup-and-merge-review.md) | English | Earlier connection fixes and merge evidence / 연결 수정·병합 기록 |
| [Fingerprint reconciliation / 해시 브랜치 정리](fingerprint-followup.md) | English | Earlier branch reconciliation and regression evidence / 브랜치 정리 당시 검증 |
| [Localization review / 문구 검토](localization-review.md) | English | Earlier UI wording changes and review boundaries / UI 문구 변경 범위 |
| [Implementation roadmap / 구현 로드맵](implementation-roadmap.md) | 한국어 | Historical plan and implementation record, not a promise of future work / 당시 계획과 진행 기록 |
| [Computer-use diagnosis / 입력 차단 진단](computer-use-diagnosis.md) | 한국어 | 2026-09-22 environment investigation / 특정 환경 진단 |

## Download and support / 배포와 문의

[Releases](https://github.com/isxcsm/pz-tools/releases) lists any published packages;
if no runnable package exists, follow [the build guide](development.md).
[Issues](https://github.com/isxcsm/pz-tools/issues) is for reproducible problem reports.
Do not include private save data or personal paths unnecessarily.

실행 패키지가 아직 없으면 소스 빌드 안내를 사용하세요. 문의에는 재현 순서와
관련 로그를 적되 불필요한 전체 세이브나 개인 경로는 올리지 마세요.

Live JVM character state and extension execution feedback: [design and validation](runtime-character-death.md).
