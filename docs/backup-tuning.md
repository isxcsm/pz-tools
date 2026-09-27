# 백업 튜닝 측정

[Documentation index / 문서 목차](README.md) · [Stable capture / 안정적 캡처](stable-capture.md)

2026-09-27, 제한형 캡처 구현 `6ae3519`에서 설정 조합을 총 78회 측정했습니다.
아래 값은 이 PC의 합성 데이터에서 선택한 절충값이며 모든 디스크의 최적값을 보장하지 않습니다.

## 조건과 측정 범위

- CPU: Intel Core i7-8700K, 6코어/12스레드. SSD: Samsung 960 EVO 500GB.
- 게임이 실행 중인 환경에서 측정했습니다. 게임 훅이나 저장 명령은 호출하지 않습니다.
- 전용 합성 파일을 반복해서 읽는 **OS 캐시가 포함된 실험**입니다. cold-cache 측정이 아니며, 다른 데이터로 수행한 과거 벤치마크와 수치를 직접 비교하지 않습니다.
- `small`은 9KiB 파일 6,000개, 총 55,296,000바이트(52.73MiB)입니다. `mixed`는 1~128KiB 파일 6,000개와 16MiB 파일 2개, 총 123.69MiB입니다. `large`는 64~112KiB 파일 12,000개, 총 1,081,332,736바이트(1.007GiB)입니다. 생성 seed는 1729이며 반복값·주기적 패턴·난수를 섞습니다. 실제 세이브 파일은 사용하지 않습니다.
- 저장 설정은 XxHash64, Brotli, 중복 제거 꺼짐으로 고정합니다. 안정된 복사 검증, 콘텐츠 fingerprint 기록, full scan 해시 비교는 켭니다. telemetry는 phase 모드입니다.
- 초기 백업은 매회 빈 저장소에 기록합니다. fallback은 같은 합성 파일의 성공한 초기 저장소를 매회 복제하고 USN을 의도적으로 비활성화합니다. `always_include=[]`로 추가 캡처를 없애고 변경 0건·새 revision 없음도 검증합니다.

[`TuningProfile.cs`](../src/PzTools.Backup.Benchmarks/TuningProfile.cs)는 `OneShotBackupService.RunAsync` 호출만 시간 측정합니다. 파일 생성, seed 저장소 복제, 결과 검증은 측정 밖입니다. 실행별로 저장 객체·fingerprint 개수와 원본 바이트 합계를 확인합니다. 별도의 `verify` 명령은 최종 large 후보의 저장소에 측정이 끝난 뒤 실행했으며, 팩 1개 검증·문제 0건으로 통과했습니다.

전체 시간과 scan/planning·capture·seal/commit 시간을 별도로 기록합니다. fallback의 planning에는 메타데이터 스캔과 해시 비교가 함께 포함됩니다. CPU 시간은 모든 스레드의 누적값이라 경과 시간보다 클 수 있습니다. 할당량은 누적 managed allocation이며, peak working set은 준비 과정을 포함한 프로세스 전체 값입니다.

## 재현 방법

저장소 루트에서 PowerShell 7과 .NET 10 SDK를 사용합니다. 아래 명령은 합성 입력과 새 출력 폴더를 만듭니다. 기존 출력 폴더를 재사용하거나 덮어쓰지 않습니다.

`capture-plan.json`의 최소 예시입니다. 1차 측정의 전체 후보는 `artifacts/tuning-20260927/small-capture/plan.json`과 `small-hash/plan.json`에 보존됩니다.

```json
{
  "base": {
    "copy_buffer_kib": 128,
    "small_file_staging_kib": 256,
    "staging_memory_mib": 16,
    "capture_read_concurrency": 2,
    "capture_queue_capacity": 16,
    "full_scan_hash_batch_size": 16,
    "full_scan_hash_read_concurrency": 2,
    "scan_batch_size": 512
  },
  "cases": {
    "baseline": {},
    "read-four": { "capture_read_concurrency": 4 }
  }
}
```

같은 `base`를 유지하고 `read-four`의 변경 키를 `full_scan_hash_read_concurrency`로 바꾼 파일을 `hash-plan.json`으로 준비합니다. 후보는 `base`에 각 `cases`의 값을 덮어씁니다. 설치된 사용자 설정은 변경하지 않습니다.

```powershell
dotnet build .\src\PzTools.Backup.Benchmarks\PzTools.Backup.Benchmarks.csproj -c Release
$bench = '.\src\PzTools.Backup.Benchmarks\bin\Release\net10.0-windows\PzTools.Backup.Benchmarks.exe'
& $bench --tune-generate --workload small --output .\artifacts\tuning-repro-small
.\scripts\measure-backup-tuning.ps1 -Source .\artifacts\tuning-repro-small\source -Plan .\capture-plan.json -Output .\artifacts\tuning-repro-capture -Scenario initial -Repeats 2 -OrderSeed 1729
.\scripts\measure-backup-tuning.ps1 -Source .\artifacts\tuning-repro-small\source -Plan .\hash-plan.json -Output .\artifacts\tuning-repro-hash -Scenario fallback -SeedRepository .\artifacts\tuning-repro-capture\r01-baseline\repository -Repeats 2 -OrderSeed 1729
```

[`measure-backup-tuning.ps1`](../scripts/measure-backup-tuning.ps1)은 매회 별도 프로세스를 실행하며, 각 round에서 후보 순서를 섞습니다. `plan.json`, 생성한 TOML, `order.json`, 원시 `results.json`, 중앙값·범위를 담은 `summary.json`, 실행별 `metrics.json`과 로그를 보존합니다. 최종 비교에서는 동일한 입력으로 반복 수를 3~5회로 늘립니다. `mixed`·`large`는 생성 명령의 `--workload`를 바꾸고 새 출력 경로를 사용합니다.

## small 1차 결과

각 후보 **2회**의 중앙값입니다. 초기 백업 11개 후보, fallback 10개 후보 중 주요 결과만 발췌했습니다. 이 표의 읽기 수는 각각 캡처 읽기 수와 해시 읽기 수입니다. 출처는 `artifacts/tuning-20260927/small-capture/summary.json`과 `small-hash/summary.json`입니다.

| 경로 | 기준 대비 변경 | 전체 시간(초) | CPU 시간(초) | peak working set(MiB) |
|---|---|---:|---:|---:|
| 초기 백업 | 기준 | 3.578 | 9.211 | 63.7 |
| 초기 백업 | 읽기 4 | 3.407 | 9.156 | 63.9 |
| 초기 백업 | 읽기 8 | 3.268 | 9.508 | 64.7 |
| 초기 백업 | 큐 4 | 3.653 | 9.188 | 64.0 |
| 변경 없는 fallback | 기준 | 1.963 | 3.398 | 61.4 |
| 변경 없는 fallback | 읽기 4 | 1.817 | 3.781 | 61.9 |
| 변경 없는 fallback | 읽기 8 | 1.907 | 3.883 | 62.7 |
| 변경 없는 fallback | 해시 배치 64 | 1.934 | 3.398 | 61.2 |
| 변경 없는 fallback | 읽기 4·해시 배치 64 | 1.856 | 3.664 | 61.9 |

초기 백업에서는 읽기 4·8이 재측정 후보입니다. fallback은 읽기 4가 가장 짧았지만 기준보다 CPU 시간을 더 사용했고, 읽기 8은 추가 이득이 없었습니다. 해시 배치 확대나 작은 파일에서의 버퍼 변경만으로 얻은 작은 차이는 아직 우열로 판단하지 않습니다. 단발 최저값보다 반복 중앙값·편차를 보고, 성능이 비슷하면 CPU·실제 메모리 사용이 낮은 쪽을 선택합니다.

staging 예산도 설정값과 실제 사용량을 구분합니다. 고정 버퍼 크기 S, 큐 Q, 예산 M일 때 작은 파일의 실효 풀 상한은 `min(Q, floor(M/S)) × S`입니다. 기준의 256KiB·큐 16에서는 최대 4MiB이므로 예산 16MiB를 늘리는 것만으로 효과를 기대하기 어렵습니다. 변경 없는 fallback은 이 staging 풀과 캡처 큐를 사용하지 않습니다.

## 최종 비교와 설정

후속 비교는 각 후보 3회 중앙값입니다. initial은 캡처 설정, fallback은 해시 설정을 비교했습니다.
mixed 초기 백업의 최종 후보는 읽기 4·큐 8·풀 예산 4MiB이며, fallback은 읽기 4·배치 16입니다.
large에서는 이 설정을 함께 적용했습니다.

| 데이터 / 경로 | 기존 전체 시간 | 선정값 전체 시간 | 감소율 |
|---|---:|---:|---:|
| mixed 초기 백업 | 4.212초 | 3.737초 | 11.3% |
| mixed 변경 없는 fallback | 2.071초 | 1.840초 | 11.2% |
| large 초기 백업 | 12.702초 | 8.799초 | 30.7% |
| large 변경 없는 fallback | 4.677초 | 3.963초 | 15.3% |

large 초기 백업 전체 범위는 기존 11.270~15.713초, 선정값 8.759~8.823초로 기존 쪽 변동이 컸습니다.
캡처 구간 중앙값도 6.955→4.755초였지만 전체 차이를 모두 캡처 설정의 효과로 단정하지 않습니다.
같은 경로의 CPU 중앙값은 28.078→27.766초, peak working set 중앙값은 79.80→78.65MiB였습니다.
large fallback은 CPU 9.313→10.516초로 증가하는 대신 경과 시간이 줄었습니다. 게임 프레임 시간은 측정하지 않았습니다.

```toml
[runtime]
copy_buffer_kib = 128
small_file_staging_kib = 256
staging_memory_mib = 4
capture_read_concurrency = 4
capture_queue_capacity = 8
full_scan_hash_batch_size = 16
full_scan_hash_read_concurrency = 4
scan_batch_size = 512
```

- 캡처 읽기 8개는 small에서 빨랐으나 mixed에서는 4개보다 느렸으므로 채택하지 않았습니다.
- 큐 16개는 mixed에서 8개보다 약 1.5% 빨랐지만 large에서는 추가 이득이 없었습니다. 복사본을 적게 보유하는 8개로 선택했습니다.
- 메모리 예산은 4MiB로 제한하고, 기본 큐·슬롯을 함께 적용한 실효 풀 상한은 2MiB입니다. 기존 실효 상한 4MiB에서 절반으로 줄었으며, 전체 앱 메모리 상한을 뜻하지 않습니다.
- 해시 배치를 16→64로 늘린 효과는 mixed에서 약 0.6%뿐이므로 16을 유지했습니다. 복사 버퍼·슬롯 크기도 유지했습니다.
- 안전성 검사·해시 기록·압축은 끄지 않았으며 실제 세이브/백업은 변경하지 않았습니다.

후속 원시 결과와 계획은 로컬 `artifacts/tuning-20260927/{mixed-capture,mixed-hash,large-capture,large-hash}`에 보존됩니다(빌드 산출물로 Git에는 포함하지 않음).
재현 시 위 예시 plan의 baseline을 유지하고, 선정값과 다른 네 키(`staging_memory_mib`, `capture_read_concurrency`, `capture_queue_capacity`, `full_scan_hash_read_concurrency`)를 후보에 함께 지정하면 됩니다.
