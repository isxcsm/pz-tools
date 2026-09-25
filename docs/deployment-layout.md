# 배포 및 실행 데이터 경로

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

PzTools는 설치 파일, 앱 제어 데이터, 사용자가 선택한 백업 저장소를 서로 다른
수명과 권한 경계로 관리합니다.

```text
C:\Program Files\PzTools\
  PzTools.App.exe 및 worker 실행 파일
  defaults\<component>\default.toml   # 읽기 전용 배포 기본값

%LOCALAPPDATA%\PzTools\
  control.db                           # 설치 인스턴스 전역 run_index
  settings.toml                       # 앱 화면에서 저장한 사용자 설정
  config\                             # 편집 가능한 구성요소별 TOML
    app\default.toml                  # 앱 로그 기록·보관 정책
    backup-worker\default.toml        # 백업 엔진 설정
    maintenance-worker\default.toml   # 보관·정리 설정
    <component>\default.toml          # 나머지 구성요소 설정(총 11개)
  config-backups\                     # 기본 설정 복원 전 TOML 보관본
  state.db                             # 현재 게임/세이브 상태
  scheduler.db                         # 스케줄 상태와 명령 inbox
  operations\<component>\<operation>\ # 복구·압축 등 일시 작업 telemetry
  cache\
  temp\

<사용자가 지정한 BackupRoot>\
  repository.db, packs\, staging\, telemetry.db
  .pztools\<component>\...            # 진단 데이터 등; 설정은 중앙 config\에 보관
```

원본 세이브 디렉터리와 가져온 압축 파일 옆에는 PzTools DB나 `.pztools` 디렉터리를
만들지 않습니다. 개발 실행도 동일한 `%LOCALAPPDATA%\PzTools` 계약을 사용합니다.
telemetry DB 등 실행 데이터는 저장소에 남습니다. 기존 설정 파일은 앱이 자동으로
이동하거나 다시 쓰지 않습니다.

## 전역 run_index

`control.db`는 한 설치 인스턴스의 전역 단조 증가 `run_index`만 발급합니다.
Scheduler 또는 앱이 번호를 발급하면 Runner와 worker는 전달받은 값을 그대로 쓰며,
직접 실행한 CLI/Runner만 `--control-db` 또는 기본 control DB에서 발급합니다.
번호는 mutex 획득 전에 발급하므로 `Busy`나 실패로 인한 빈 번호는 정상이며 재사용하지
않습니다. control DB를 열거나 갱신하지 못하면 로컬 번호로 조용히 우회하지 않고 실행을
실패시킵니다.

DB를 잃어 새로 만들더라도 과거의 작은 번호와 충돌할 가능성을 줄이기 위해 최초 발급은
UTC Unix 밀리초를 16비트 왼쪽으로 이동한 시간 기반 하한을 사용합니다. 외부 복구 도구는
관측한 최대 번호를 배타 하한으로 전달할 수도 있습니다.

## 압축 가져오기 자원 한도

archive worker의 검사·가져오기 기본값은 엔트리 1,000,000개와 단일 파일 64 GiB입니다.
정상적인 고압축 게임 파일의 오탐을 피하기 위해 압축률만으로는 거부하지 않습니다.
경로·링크·중복 엔트리·단일 파일 크기 검사와 실제 해제 바이트 수 제한을 적용합니다.
전체 압축 해제 용량에 임의 상한은 두지 않지만, 가져오기 전에
필요 용량을 계산하고 대상 드라이브에 `max(5 GiB, 압축 해제 용량의 10%)`를 남길 수 없으면
거부합니다. 값은 `defaults/archive-worker/default.toml` 또는 해당 프로세스의 명시적
`--config`에서 조정합니다.
