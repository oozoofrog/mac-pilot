# LCD 화면 검사

LCD의 **검사**에서 접근성 요소를 읽고, 선택한 요소의 속성·지원 동작을 확인한다. **3D 뷰 검사**는 현재 앱의 UIKit 뷰 계층을 별도 창에 표시한다. AX 요소와 UIKit 뷰를 같은 대상으로 간주하지 않는다.

1. LCD 도구 막대에서 **검사**를 열고 **화면 요소 새로 읽기**를 누른다. 창 열기와 목록 선택만으로 앱을 조작하지 않는다.
2. 목록에서 이름·종류·화면 안 여부를 보고 선택한다. 선택은 기기를 조작하지 않는다. LCD의 점선 강조와 아래 선택 표시·중심 좌표·크기를 확인한다. **화면에서 선택**은 실제 AX 사각형에 포함되는 후보를 깊은 요소부터 보여 준다. 겹친 후보나 부모는 목록에서 바꿔 고를 수 있다. 이 모드의 클릭은 터치를 보내지 않으며 **Esc** 또는 **화면 선택 종료**로 보통 LCD 입력으로 돌아온다.
3. **선택한 위치 탭**을 누르면 실제 기기 화면에 터치를 보낸다. 실행 직전에 전면 앱과 요소 속성·위치를 다시 검사하며 달라졌으면 실행을 거부한다.
4. 요소가 제공하는 접근성 동작을 선택해 실행한다. 지원되는 문자열 값은 초안을 입력한 뒤 적용한다. 복원은 마지막 적용값과 현재 값이 같고 해당 결과의 권한이 유효할 때 사용할 수 있다. 화면이 바뀌면 **화면 요소 새로 읽기**를 누른다.

앱 화면은 스스로 바뀔 수 있다. 목록은 읽은 시점의 정보이며 실시간 스트림이 아니다. LCD 입력, 명령 실행, 화면 기하 변경, 닫힘 때 선택을 해제한다. 화면 일부만 보이는 요소는 목록에서 정보를 볼 수 있으나 탭은 허용하지 않는다. 요소가 없는 경우 LCD 직접 조작을 사용할 수 있다. 강조는 마지막으로 AX를 읽은 시점의 정보이며 현재 앱 상태를 보장하지 않는다. 터치 탭과 **접근성 동작 실행(AXPress)**은 별개다. AXPress는 요소가 실제로 해당 동작을 제공할 때만 사용할 수 있다.

보호된 값과 지원 여부를 확인하지 못한 값은 편집할 수 없다. press·증가·감소·custom action의 전달과 앱의 실제 상태 변경은 별도 결과다. 이름이 같은 custom action도 각각 선택한다. **전문 도구**의 이름 기반 탭은 목록에서 선택한 AX 대상과 다른 경로이므로 결과가 여러 개일 때 선택 의미를 확인한다. 다중 터치 패드는 1~3개 접점을 HID로 전송한다.

## 3D 뷰 검사

**3D 뷰 검사**를 열고 **캡처**를 누른다. 캡처 과정에서 앱을 잠시 정지할 수 있다. 창을 열거나 카메라를 움직이는 동작은 캡처를 시작하지 않는다. 트리 또는 장면의 후보에서 뷰를 명시적으로 선택한다. 회전·확대·깊이 간격은 검사 창의 표시만 바꾸며 기기에 입력하지 않는다.

선택한 뷰의 `hidden` 또는 `alpha` 초안을 **적용**하면 실행 중 앱 메모리를 변경한다. 소스 파일은 변경하지 않는다. **복원**은 같은 뷰의 현재 값이 마지막 적용값과 일치할 때만 허용한다. 대상·계층·현재 값이 바뀌었거나 캡처가 만료되면 새로 캡처하고 다시 선택한다. 불확실한 실행은 자동 재시도하지 않는다.

현재 지원 범위는 arm64, Xcode 27.2 / 27B48, iOS Simulator 27.2 / 24B114의 디버그 서명이 있는 실행 중 앱이다. 확인된 UIKit C-main 또는 표준 SwiftUI startup 경로만 허용한다. 시스템 앱, 다른 debugger가 붙은 앱과 미지원 진입 경로는 거절한다. 캡처 helper는 대상 앱이 종료될 때까지 남는다.

SwiftUI 앱에서도 표시하는 트리는 UIKit 뷰 계층이다. SwiftUI 텍스트·도형이 텍스처에서 누락될 수 있으며, SwiftUI 값 타입의 모든 뷰를 표시하지 않는다. superview 기준 frame을 LCD 좌표로 추정하지 않으며 UIKit 뷰의 LCD 강조는 제공하지 않는다. [캡처 API와 수명 계약](simulator-view-capture.md)에 개발용 진입점과 검증 범위를 정리했다.

## 설계 근거

Apple의 [Accessibility Inspector 실제 탐색 흐름](https://developer.apple.com/documentation/accessibility/inspecting-the-accessibility-of-screens)은 대상 앱 확인, 요소 선택과 강조, 기본 속성·지원 동작·상세 속성·계층 확인을 분리한다. 이 흐름을 AX 목록과 화면 선택에 적용했으며 UIKit 뷰 구조와 혼동하지 않는다.


- [Apple HIG: Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields): 필터에 영구 접근성 이름을 주고 필수 명령 입력을 기본 경로에서 제거했다.
- [Apple HIG: Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls): 자주 쓰는 탐색을 먼저, 전문 기능은 명시적 진입 뒤에 배치했다.
- [Apple HIG: Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons): 읽기·선택과 실제 터치 전송을 명명된 별도 버튼으로 구분했다.
- [Apple HIG: Panels](https://developer.apple.com/design/human-interface-guidelines/panels): 현재 선택과 속성을 가까이 배치하고 기존 검사 작업 영역을 유지했다.
- [Apple HIG: Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers): 지속 탐색과 결과는 기존 검사 작업 영역에서 유지하며 입력 초안을 보존했다.
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility): 네이티브 목록·방향키 선택·접근성 이름, 색 외의 선택 문자와 상태 문구를 사용한다.

## 검증 범위

실제 Simulator에서 정상 AX 동작·값 복원, 일반 UIKit 및 SwiftUI 내부 UIKit 뷰의 캡처·편집·복원, 예외·취소와 대상 수명 검사를 수행했다. LCD→3D 창의 선택·편집·복원·재열기, 최소 크기와 결과 표시를 확인했다. UI 취소 검증은 native 완료 뒤 늦게 도착한 결과가 편집 권한을 되살리지 못하는 경우를 확인했다. native 계층 순회 도중의 중단을 검증한 결과는 아니다. headless 검사나 로컬 AppKit action 호출은 물리 키보드·마우스, VoiceOver 읽기 순서 또는 사용자의 디자인 승인을 대신하지 않는다.

## SwiftUI 기록 준비와 명시적 재실행

캡처의 hosting graph가 `emptyArray` 또는 실제 호출된 `nil` 결과로 기록 준비 필요를 보고하면 **SwiftUI 기록을 켜고 다시 실행** 버튼을 표시한다. SwiftUI 섹션 부재나 일반 수집 오류만으로 기록 설정을 추정하지 않는다. 버튼 아래에는 현재 실행 상태가 사라지고 기존 실행 인자·환경 변수가 복원되지 않는다고 표시한다. 사용자 클릭만 재실행을 요청한다. 검사·캡처·선택·실패 경로는 재실행하지 않는다.

진행 중인 capture/edit/revert, native callback custody, 미확인 정리, 다른 세션의 기기 claim은 재실행을 차단한다. 기존 inspector session은 정상 release로 정리하며, ledger가 검증한 released 상태만 실행 준비에 사용할 수 있다. 선택한 device/PID/start/path와 boot/presentation generation을 다시 확인한다. 현재 지원하는 Xcode/runtime 및 설치된 user app admission을 그대로 사용한다.

새 실행에만 `SWIFTUI_VIEW_DEBUG=287`을 전달한다. 전역 launchctl·기기 환경은 변경하지 않는다. 대상 PID에 한 번 종료를 요청하고 종료를 관측한 뒤 한 번 launch한다. 불확실한 launch는 읽기 전용으로 수명을 확인하고 재전송하지 않는다. 영속 dispatch 기록은 같은 이전 수명의 재시도를 차단한다. 성공은 새 수명과 해당 환경 키를 확인한 결과다. 실제 선언형 계층은 사용자가 화면을 준비한 뒤 새 캡처로 확인한다.

이번 구현 근거는 headless typecheck와 synthetic transition/model 검사다. 실제 제품 버튼, 종료·재실행, 현재 boot/generation 연결, 새 graph·Text/Shape 합성 이미지, 사용자 상태 손실 안내와 창 레이아웃 검증은 runtime owner의 후속 작업이다.
