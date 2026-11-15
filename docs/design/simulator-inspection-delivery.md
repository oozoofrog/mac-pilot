# LCD 검사 1.31.0 전달 검증

2026-11-09 canonical `mac-computer-use` 1.31.0을 빌드하고 전역 mac-cu 앱을 교체·재시작했다. 실행 중 daemon의 MCP `initialize` 응답에서 1.31.0을 확인했다. 기존 iPhone Duo LCD·검사 도구·프리뷰를 복원하고 설치된 앱의 **3D 뷰 검사** 창을 열어 화면과 포커스를 확인했다. 설치 후 UI 확인에서는 guest 캡처나 편집을 실행하지 않았다.

## 구현 및 검증

- LCD AX: 명시적 새로 읽기, 수동 선택, 지원 동작·문자열 적용·복원. 정상 제품 factory에서 실제 guest 결과와 대조했다.
- 3D: 현재 디버그 앱의 textured UIKit 계층, 트리·장면 선택, host 카메라, typed hidden/alpha 적용·복원. 독립 guest getter와 setter 횟수로 결과를 확인했다.
- 수명: 대상 PID/start/path, boot/runtime/display와 편집 epoch를 구분한다. 실제 객체 해제·계층 변경·값 충돌·예외·취소·release 후 새 owner 전환을 검사했다.
- 창: 초기·안정 상태의 포커스, 최소 크기와 스크롤, 결과 요약·지우기, 닫힘·재열기, native 완료 뒤 늦게 도착한 결과의 권한 거부를 확인했다.

`bash scripts/check.sh` 전체 검사가 통과했다. 이후 owner 갱신·receipt 표시·조건부 LCD 복원의 좁은 변경은 관련 모델 검사, 전체 host 빌드·서명·진입 가드, host 포커스 회귀와 실제 LCD→3D 후속 검증으로 확인했다. 전체 검사를 모든 후속 변경 뒤 다시 실행했다고 주장하지 않는다.

마지막 후속 검증의 실제 capture/release 6건이 성공했다. native 분리·앱 복구·자식 프로세스 종료를 확인한 뒤 guest 앱과 데이터를 제거했다. 원래 guest/host 상태와 설정을 복원했고 claim 및 소유 프로세스가 남지 않았다. 앞선 실패 기록과 정리 근거는 별도 로컬 로그에 보존했다.

## 로컬 설치

- canonical setup의 build/sign 경로로 staging 앱을 만들었다. 기존 bundle ID·인증서 체인·designated requirement가 같은지 확인한 뒤 교체했다.
- 이전 1.30.0 앱은 기존 지원 폴더의 `app-backups/`에 보존했다. 백업·설치본 파일 hash를 각각 이전 앱·staging 앱과 대조했다.
- 앱 외부 지원 파일 35개의 hash가 설치 전후 일치했다. Keychain 항목과 MCP 등록, 프로필, 캡처, Simulator 데이터는 수정하지 않았다.
- 실제 설치된 프로세스의 버전 응답, LCD와 3D 검사 창의 AX 상태 및 screenshot을 확인했다. 3D 창 열기만으로 캡처하지 않았다.
- 두 host manifest, catalog version과 README는 1.31.0이다. `simulator-pilot`은 1.8.2다. Git 커밋·push·marketplace 배포는 수행하지 않았다.

## 지원 범위와 한계

현재 캡처·편집 지원은 arm64, Xcode 27.2 / 27B48, 일반 iOS Simulator 27.2 / 24B114, 디버그 서명과 확인된 UIKit C-main 또는 표준 SwiftUI startup 경로에 한정된다. Duo의 별도 runtime build는 이 지원 근거에 포함되지 않는다. 시스템 앱과 다른 debugger가 붙은 앱은 거절한다.

SwiftUI에서는 UIKit hosting 계층을 표시하며 텍스트·도형이 PNG에서 빠질 수 있다. SwiftUI 값 타입 노드 전체와 UIKit 뷰의 LCD 강조는 제공하지 않는다. UI 취소 검증은 native 완료 뒤 transport/UI 전달 전 취소였으며, native 계층 순회 도중의 중단을 증명하지 않는다. 물리 키보드·마우스, VoiceOver 읽기 순서와 사용자의 디자인 승인은 별도다.

사용 방법은 [LCD 화면 검사](../simulator-inspector.md), 실제 UI 검증의 상세 계약은 [qualification](../../mac-computer-use/tests/simulator-inspector-product-live/QUALIFICATION.md)에 정리했다.
