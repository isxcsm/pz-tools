# Computer Use 입력 차단 진단 (2026-09-22)

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

> 2026-09-22 특정 환경의 진단 기록입니다. 다른 환경이나 최신 빌드의 결과로 해석하지 마세요.

## 실측 결과

`scripts/diagnose-computer-use.ps1`은 실행 중인 관련 프로세스의 토큰을 조회하며
권한, OS 설정, 프로세스 수명을 변경하지 않습니다.

| 프로세스 | PID (검사 당시) | Integrity | Elevated | UIAccess |
|---|---:|---|---:|---:|
| Computer Use 입력 프로세스 | 4220 | Medium (`S-1-16-8192`) | 0 | 0 |
| Codex 에이전트 | 11944, 20888 | Medium | 0 | 0 |
| Visual Studio | 17184 | High (`S-1-16-12288`) | 1 | 0 |
| PzTools | 20272 | High | 1 | 0 |

계산기를 별도로 실행해 Computer Use로 숫자 `1`을 클릭했고, 표시값이 `0`에서
`1`로 바뀌는 것을 캡처로 확인했습니다. 일반 권한 앱에는 입력이 전달됩니다.
PzTools에서는 메뉴 클릭이 반영되지 않았습니다.

## 판정

Computer Use의 낮은 권한에서 높은 권한의 PzTools로 입력을 보내려 하므로 Windows
UIPI 입력 제한에 걸리는 조건입니다. 캡처 성공은 입력 권한이 있다는 뜻이 아닙니다.
PzTools의 관리자 권한 계약이나 UAC 설정은 변경하지 않았습니다.

- Microsoft SendInput 문서: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
- 동일 증상 사용자 보고 (제품 수정 완료를 뜻하지 않음): https://github.com/openai/codex/issues/45388
- 관리자 실행 공식 안내: https://learn.chatgpt.com/docs/windows/windows-app#run-commands-with-elevated-permissions

## 정상화 후 완료 기준

1. Codex 및 입력 프로세스 토큰이 실제 High로 실행되는지 다시 확인합니다.
2. PzTools 설정 메뉴 클릭 후 실제 화면 전환을 확인합니다.
3. 성공한 뒤에만 VS 재빌드·재실행 및 UI 반복 검증을 재개합니다.

관리자 실행 후에도 입력 프로세스가 Medium이면 단순 재시작으로 해결됐다고
기록하지 않습니다. 입력 helper를 임의로 재실행하거나 보안 정책을 완화하지 않습니다.
