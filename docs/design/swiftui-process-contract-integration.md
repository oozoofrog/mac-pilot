# SwiftUI 제품 검증용 프로세스 계약 통합

UI 검증 감시기는 `ui_process_contract.py`에서 native 프로세스 관찰,
`ui_capture_contract.py`의 파일 연결 검증, `ui_tool_contract.py`의 도구 매칭을
결합한다. 이 코드는 검증 harness에만 적용한다. 제품의 실행 권한이나
debugger custody를 부여하지 않는다.

## 관찰과 최종 허용

초기 목록 검사는 준비한 UI 실행 파일 하나와 그 자식의 경로, 부모, 프로세스
그룹, 깊이, 개수를 제한한다. 이 단계의 `candidate`는 명령 검증 성공이 아니다.
최종 허용 전에 전체 live 목록의 native PID/start/parent/group/path와 argv를
대조한다. 자식 PID가 부모보다 작은 경우에도 부모부터 의미를 검증한다.
모든 파일 연결과 argv 검사가 끝나면 native 관계를 다시 읽는다.

종료 중인 helper와 exec 경계의 불완전한 관찰은 기존 3초 cutoff 안에서 목록을
재확인한다. cutoff를 연장하지 않는다. 경로의 forward exec 후보는 최종 명령
역할과도 일치해야 한다. argv에서 추정한 경로를 관찰 이력으로 기록하지 않는다.
native exit 확인 없이 이전 역할과 실행 후보를 제거하지 않는다.

## 파일과 작업의 연결

준비 manifest는 실제 UI 실행 파일, 복사한 capture resource, 선택한 도구와
wrapper, harness의 동시 실행 근거 소스를 고정한다. bind 단계에서 이 해시를
재확인한다. 감시기는 현재 파일을 읽어 같은 계약을 확인한다.

UI 요청은 native target binding의 대상과 세션 owner에 연결한다. app의
Info.plist와 data container의 MCMMetadataIdentifier를 같은 bundle ID로
대조한다. device와 app/data container 경로도 일치해야 한다.

capture supervisor는 자신의 argv에 있는 private request와 준비한 resource에
연결한다. 현재 ledger의 owner, inspection, sequence, operation digest가
요청과 일치해야 한다. 제품 supervisor는 내부 texture request를 포함한 최종
wire의 SHA-256을 transport child 생성 전에 같은 예약 작업에 기록한다.
감시기는 이 독립적인 ledger 해시를 wire 파일과 비교한다. wire 저장 실패는
dispatch 전에 종료한다. 완료된 작업의 worker나 utility 재진입은 거절한다.

resident worker는 `resident_transport.py --worker`만 허용한다.
request, admission, wire, channel, worker config, ABI-2 bytes, staged image,
resident pin과 native debugserver identity가 같은 작업을 가리켜야 한다.
FD 인자는 양의 정수로 제한하지만 이 검사만으로 실제 FD 상속을 증명하지 않는다.

## 프로세스 한도

UI와 별도 session probe는 합쳐서 하나만 허용한다. UI 아래에서는 display
origin 두 개를 허용한다. 각 display wrapper family는 최대 세 프로세스다.
identity, capture supervisor, resident worker, debugserver와 screenshot은
각각 하나다. capture utility origin은 하나이며 simctl wrapper family는
최대 다섯 프로세스다. 따라서 UI를 제외한 후보는 최대 16개다. worker 자신의
기존 inventory utility 한도는 별도로 유지한다.

두 display origin을 시작한 Swift 큐는 native argv로 구분하지 않는다.
합산 한도의 근거는 [선택 도구 계약](swiftui-tool-wrapper-contract.md)에 있다.
setup, boot, install, 알 수 없는 helper와 다른 경로의 codesign 호출은 거절한다.

## 검증 범위와 남은 작업

통합 검사는 production 함수를 subprocess/Engine 경계에서 가로채 얻은
capture/edit/revert/release 명령과 실제 생성한 파일을 사용한다. native PID와
argv 관찰은 합성 데이터다. 정상 경로, wrapper 자식, 역순 PID, 두 display,
잘못된 worker/resource, PID 재사용, 그룹 이탈, 다른 data container와 거절
진단을 검사한다. 이 근거는 실제 GUI, LLDB attach 또는 제품 캡처 성공이 아니다.

실제 제품 실행은 아직 검증되지 않았다. 현재 source로 새 준비 빌드와 entry
guard를 통과한 뒤, 별도로 통제한 runtime에서 전체 제품 흐름을 확인해야 한다.
기존 실패 횟수와 원본 증거는 유지한다.

사용자는 기록 없이 실행된 앱에 대해 명시적인 **SwiftUI 기록을 켜고 다시 실행**
버튼을 선택했다. 사용자가 버튼을 눌렀을 때만 재실행하며 현재 실행 상태의
손실을 안내한다. 이 준비 흐름의 제품 구현과 검증은 별도 작업이다.
