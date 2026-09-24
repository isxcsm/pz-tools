# 저장소 형식

저장소 형식 버전 1은 다음 구조를 사용합니다.

```text
repository/
  repository.db
  telemetry.db
  .pztools/
    backup-worker/
      telemetry.db
    backup-runner/
      telemetry.db
    maintenance-worker/
      telemetry.db
    maintenance-runner/
      telemetry.db
  packs/
  staging/
  .writer.lock
```

구성요소의 편집 가능한 `default.toml`은 저장소 내부가 아닌
`%LOCALAPPDATA%/PzTools/config/<구성요소>/default.toml`에 둡니다.
기존 저장소 내부 TOML은 앱이 자동으로 이동하지 않습니다.

`repository.db`가 권위 있는 상태입니다. 저장소 UUID, 저장소 범위 `run_index`,
소스 등록, 소스 범위 리비전 번호와 체크포인트, 팩 및 객체 위치, 버전이 있는
카탈로그 항목을 관리합니다. 저장소 루트의 `telemetry.db`는 백업 엔진의 세부
이벤트이며, `.pztools` 아래 DB는 각 프로세스의 경계 이벤트입니다. 둘 다
진단용이므로 손실되어도 어떤 리비전이 존재하는지는 바뀌지 않습니다.

스키마는 순서가 있는 전진 전용 migration을 사용하고 모든 SQLite connection에서
foreign key를 활성화합니다. `schema_migrations`는 적용된 스키마 버전을 기록합니다.
저장소 형식 버전과 스키마 버전을 분리하여 외부 저장소 계약을 바꾸지 않고 내부
스키마를 발전시킬 수 있습니다. 스키마 버전 2에는 현재 항목의 파일 및 부모 참조를
위한 expression index가 추가됐고, 스키마 버전 3에는 workflow/stage 실행 상관관계와
리비전의 `Active/Deleted` 상태가 추가됐습니다. 스키마 버전 4에는 UI reader가
`NotModified`를 빠르게 판정하는 `repository_change_revision`이 추가됐습니다.
스키마 버전 5는 리비전마다 편집 가능한 `display_name`을 보관합니다. 기존
리비전의 빈 이름은 앱 시작 시 설정 언어로 한 번 채우며, 이름 변경도 repository
change revision을 증가시켜 목록에 즉시 반영합니다.
스키마 버전 8은 `backup_kind`(`Manual`, `Automatic`, `Unknown`)를 리비전에
영속 저장합니다. 커밋 시 예약된 workflow가 `backup-maintenance`이고 소유자가
`backup-scheduler`인 경우만 자동 백업이며, 직접 실행·앱 수동 실행·가져오기는
수동 백업입니다. 초기 백업과 증분 백업 모두 같은 커밋 경계를 사용합니다.
업그레이드 시 기존 workflow로 확인되는 자동/수동 기록만 분류하고 나머지는
`Unknown`으로 보존합니다. 기존 이름은 덮어쓰지 않습니다. 새 기본 이름은
`수동 백업 N` / `자동 백업 N`(영어: `Manual backup N` / `Automatic backup N`)이며,
N은 종류와 무관하게 증가하는 기존 소스 리비전 번호입니다.
자동 정리는 활성 `Automatic`만 세고 삭제합니다. `Manual`과 `Unknown`은
사용자 삭제 전까지 개수 제한 없이 보존됩니다.
따라서 저널 run은 현재 리비전 전체를
메모리에 올리지 않고 USN 레코드에 나온 식별자만 읽습니다.

배타적으로 공유되는 `.writer.lock`을 보유한 프로세스만 저장소 상태를 변경할 수
있습니다. lock 파일은 의도적으로 계속 존재합니다. 소유권은 열려 있는 배타적
핸들이므로 프로세스가 비정상 종료되어도 오래된 논리 lock이 남지 않습니다.
변경 API는 lease의 저장소 경로만 소유 증거로 보지 않으며 이미 dispose된 lease를
거부합니다.

`run_index`는 실제 run이 시작될 때 할당되고 영속적으로 증가합니다. 실패하거나
중단된 시도도 index를 소비하므로 성공한 run 사이에는 번호 공백이 생길 수 있습니다.
`revision`은 팩과 객체 등록, 항목 버전 적용, 소스 체크포인트 갱신, run 완료를
함께 수행하는 최종 트랜잭션 안에서만 계산하고 삽입합니다. 따라서 실패한
트랜잭션은 리비전 번호를 소비하지 않습니다.

소스 체크포인트는 USN 검증에 필요한 세 값을 모두 포함합니다.

```text
volume identity + journal ID + next USN
```

카탈로그 경로는 정규화한 루트 상대 표시 경로와 버전이 있는 대소문자 비구분
비교 키로 저장합니다. 정규화 충돌이 발생하면 항목을 조용히 합치지 않고
트랜잭션을 실패시킵니다. 객체 ID는 불투명 locator이며 체크섬이 아닙니다.
콘텐츠 기반 식별자는 명시적으로 활성화한 중복 제거 전략에서만 사용합니다.

최신 리비전을 포함해 사용자 삭제는 `Deleted` 마킹만 하며 조회·복구·내보내기에서
즉시 제외됩니다. 보존 한도를 넘긴 활성 리비전도 같은 방식으로 마킹합니다.
`source_state.current_revision`과 체크포인트는 변경하지 않습니다. 삭제된 최신 리비전은
사용자에게 보이지 않는 내부 증분 기준으로 유지하며 GC도 그 항목의 객체 참조를 보존합니다.
RevisionCompaction은 현재 내부 기준을 제외한 삭제 항목을 기본 20개 배치로 정리합니다.
다음 활성 리비전 또는 삭제된 현재 내부 기준에서 필요한 항목들의 시작
지점을 재기준화한 뒤 삭제 리비전 row를 물리 제거합니다. 가비지 컬렉션은
보존된 항목이 참조하지 않는 객체와 팩을 별도로 제거합니다. 팩 압축은 대체 팩을
기록하고 검증한 뒤 모든 객체 locator를 트랜잭션으로 전환하고 기존 팩을
superseded 상태로 표시하되 reader를 위해 파일은 남겨 둡니다. 이후 명시적인
가비지 컬렉션이 superseded 팩을 제거합니다.
새 리비전이 생성되면 이전 삭제 기준도 정리 대상이 되며 더 이상 참조하지 않는 객체는
GC가 회수합니다. 변경 없는 백업은 숨긴 리비전을 다시 노출하거나 번호를 재사용하지 않습니다.
