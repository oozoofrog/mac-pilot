# Mac Pilot

Codex와 Claude Code용 Mac 자동화·iOS 시뮬레이터 독립 프로젝트입니다. `mac-computer-use`와 `simulator-pilot` 두 패키지를 이 저장소에서 개발하고 직접 배포합니다.

[English](README.md) | 한국어

## 설치

```sh
codex plugin marketplace add oozoofrog/mac-pilot --ref main
codex plugin add mac-computer-use@mac-pilot
codex plugin add simulator-pilot@mac-pilot
codex plugin list --json
```

Plugin 설치 후 설치된 전체 패키지 안의 setup을 실행하고 필요한 macOS 권한을 허용한 뒤 새 대화를 시작합니다. 기존 앱의 bundle ID와 전역 실행 경로, Keychain 항목은 유지합니다. [설치·이전 절차](docs/installation.md)를 따릅니다.

## 기능

- [mac-computer-use](mac-computer-use/skills/mac-computer-use/SKILL.md) 1.27.0: Mac 앱·브라우저·웹뷰 제어와 네이티브 시뮬레이터 LCD, 이동 손잡이·분리형 도구 모듈·집중 모드.
- [simulator-pilot](simulator-pilot/skills/simulator-pilot/SKILL.md) 1.8.1: 시뮬레이터 앱 실행·로그·테스트 데이터·변경 확인. 앱 빌드는 각 프로젝트 지침을 따릅니다.
- 선택적 OpenAI Decisions 판단·검증: API 키는 Keychain에 저장합니다. 설정의 연결 확인은 합성 텍스트만 전송하며 요청 본문·검증된 응답·시간·오류를 표시합니다. 일반 AX/HID 조작에는 API 키가 필요하지 않습니다.

소스 패키지가 곧 배포 경로이며 중복 미러를 만들지 않습니다. 개인 프로필·캡처·생성 실행 파일은 로컬에 보존하고 배포에서 제외합니다. [검증 기록](docs/mac-cu-device-window-validation.md)과 [개발·릴리스 명령](docs/releasing.md)을 참고하세요.
