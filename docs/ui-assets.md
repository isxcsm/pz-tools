# 앱 아이콘

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

- 원본은 `src/PzTools.App/Assets/Navigation/pztools.svg`이며, 사용자 정의 타이틀바에서 사용합니다.
- 같은 원본에서 생성한 `pztools.ico`를 실행 파일 리소스와 `AppWindow.SetIcon`에 함께 지정합니다. 작업 표시줄과 Alt+Tab도 같은 디자인을 사용합니다.
- ICO에는 16, 20, 24, 32, 40, 48, 64, 128, 256px 이미지를 포함합니다. 빌드·게시 시 런타임 파일도 복사합니다.
- 원본을 수정하면 Node.js와 `sharp`(생성 시 사용 버전: 0.35.4)가 있는 환경에서 `node scripts/generate-app-icon.cjs`를 실행하고 SVG와 ICO를 함께 반영합니다.
- 생성된 ICO는 소스에 포함하므로 일반적인 Visual Studio 빌드에는 Node.js가 필요하지 않습니다.
