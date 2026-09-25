# Windows USN 저널

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

Windows 변경 추적 계층은 NTFS 볼륨에서 volume serial number, journal ID,
읽을 수 있는 첫 USN, next USN, lowest valid USN을 조회합니다. 유효 체크포인트는
`(volume serial, journal ID, next USN)` tuple이며 증분 읽기 전에 세 값을 모두
검사합니다.

읽기는 레코드 버전 2~3과 고정 1 MiB 버퍼를 사용합니다. typed 레코드를 반환하기
전에 모든 레코드 길이, 버전, 파일 이름 범위, USN의 경계를 검사합니다. V2의
64비트 파일 및 부모 참조와 V3의 128비트 참조는 `UInt128`로 정규화합니다. 호출
중 저널이 증가하더라도 캡처한 상한에서 읽기를 중단하고 상한 이상의 레코드는
무시합니다.

증분 계획기는 이 범위를 고정 크기 batch로 소비하므로 큰 저널 구간 전체를
메모리에 올리지 않습니다. rename old/new 상태는 batch 경계를 넘어 유지하며,
하나의 파일 참조 번호에 여러 경로가 연결된 하드링크도 모두 추적합니다.

바이너리 파서 테스트는 권한 없이 실행됩니다. 실제 볼륨 조회와 범위 제한 읽기
테스트는 `PZTOOLS_TEST_USN=1`을 설정해야 실행되며, 현재 개발 장비에서 저널
접근을 위해 볼륨을 열려면 관리자 권한 프로세스가 필요합니다. 비활성화된 통합
테스트는 성공이 아니라 skipped로 보고됩니다. 범위 테스트는 저널의 파일 참조가
`FILE_ID_INFO`와 일치하는지도 확인합니다. 따라서 일회성 프로세스도 관리자
권한으로 실행해야 할 수 있습니다. 향후 최소 권한 상승 helper는 배포 선택지이며
백업 프로세스 로드맵에 포함하지 않습니다. helper가 도입되더라도 저장소나
telemetry 상태의 소유권을 가져서는 안 됩니다.
