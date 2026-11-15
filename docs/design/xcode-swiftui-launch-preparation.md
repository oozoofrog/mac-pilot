# Xcode의 SwiftUI 기록 준비 시점

2026-11-09 · Xcode 27.2 / 27B48 · arm64 정적 확인

## 결론

현재 설치된 Xcode는 View Debugging이 활성화된 앱의 **실행 인자를 구성할 때 `SWIFTUI_VIEW_DEBUG=287`을 추가**한다. 별도 기록 버튼을 눌러 기존 그래프를 소급 생성하는 흐름이 아니다. 앱의 원래 환경 변수에 같은 키가 있으면 그 값이 우선한다.

이 결과는 [runtime 초기화 조사](swiftui-runtime-debug-data-path.md)의 후속 근거다. `287`은 이제 외부 저자의 실험값뿐 아니라 현재 Xcode의 플러그인 설정에서도 확인한 값이다. 최소 mask나 모든 플랫폼에서 필요한 값이라고 일반화하지 않는다.

## 설치본에서 확인한 연결

경로는 Xcode `Contents/` 기준이다. 주소는 DebuggerFoundation의 arm64 unslid VM 주소다.

1. `PlugIns/DebuggerUI.framework/Versions/A/Resources/DebuggerUI.xcplugindata`의 `Xcode.DebuggerFoundation.ViewDebugger.AdditionalEnvironmentVariable.SwiftUI` 항목은 `name: SWIFTUI_VIEW_DEBUG`, `value: 287`, `point: Xcode.DebuggerFoundation.ViewDebugger.AdditionalEnvironmentVariable`을 지정한다.
2. `-[DBGViewDebuggerAddition _loadAdditionalEnvars]` (`0x339a8`)는 그 extension point를 조회한다. 각 항목의 `name`과 `value`를 읽어 dictionary에 넣는다. `_additionalEnvars` (`0x33904`)는 결과를 `dispatch_once`로 보관한다.
3. `adjustedLaunchParametersForLaunchParameters:` (`0x3376c`)는 사용자 defaults의 View Debugging 비활성 여부와 `viewDebuggingEnabled`를 확인한다. 활성 경로에서는 위 dictionary를 복사하고 `originalEnvironmentVariables`를 병합한 뒤 `launchParametersByReplacingEnvironmentVariablesWithDictionary:`를 호출한다 (`0x337a4–0x337f0`). 원래 환경 변수를 나중에 병합하므로 명시적 기존 값이 우선한다.
4. 같은 메서드는 별도 조건을 통과하면 View Debugger 지원 dylib를 `DYLD_INSERT_LIBRARIES`에 추가한다 (`0x33810–0x338a0`). 환경 변수 추가와 dylib의 사전 로드 조건은 같은 검사가 아니다. 테스트 설정, on-demand 설정과 SceneKit 충돌 검사 등은 dylib 로드 경로에 있다.

DebuggerFoundation SHA-256은 `29d944b6166d8eabb976bf829c0e4aa7b4306af828a5341b21b58a952a506b2d`다. 플러그인 데이터 SHA-256은 `fae3c0680c4ce3124c07159a38376d21999317973c34c45d76ff31a71b69cc3e`다. 현재 파일의 hash를 다시 읽어 기존 disassembly의 설치본 식별과 대조했다. 관련 plist 항목, disassembly 범위와 hash 목록은 비공개 증거에 보관한다.

## Run과 attach의 차이

[Apple 문서](https://developer.apple.com/documentation/xcode/diagnosing-issues-in-the-appearance-of-your-running-app)는 scheme의 Debug executable을 사용한 실행과 이미 실행 중인 프로세스에 대한 attach를 모두 지원한다. 화면이 나타난 뒤 Debug View Hierarchy를 실행하면 현재 계층을 검사한다.

그러나 attach는 이미 실행한 프로세스의 시작 환경을 소급 적용하지 않는다. 현재 SwiftUICore는 첫 접근에서 `SWIFTUI_VIEW_DEBUG`를 `getenv`/`atoi`로 읽고 `swift_once`에 보관한다. graph output 생성 경로는 이 mask가 0이 아닐 때 tree 기록을 켠다. 따라서 **기록 없이 생성된 SwiftUI 그래프를 attach만으로 항상 복구할 수 있다는 근거는 없다.** Xcode의 attach 경로를 실제 실행해 이 한계를 관찰한 것은 아니다.

[소유 fixture 실험](swiftui-hierarchy-probe.md)에서는 일반 실행의 결과가 빈 배열이었고 기록 설정을 넣은 새 실행에서는 실제 선언형 노드가 나왔다. 이 관측은 해당 fixture의 준비 조건을 지지하며 임의 앱 전체의 결과를 보장하지 않는다. UIKit 계층·이미지 캡처 가능 여부와 선언형 그래프의 기록 여부도 구분한다.

## mac-cu에 적용할 방향

Xcode와 같은 실행 준비 흐름은 검사할 앱을 시작할 때 기록 설정을 넣고, 이후 현재 상태를 캡처하는 방식이다. 이미 기록된 실행이면 다시 시작할 이유가 없다. 기록 없는 실행에서 그래프가 비었을 때는 기존 계층·이미지와 그래프의 상태를 구분하고, 현재 실행 상태가 사라지는 재실행은 사용자가 선택하게 한다.

이 문서는 해당 제품 흐름의 구현 또는 사용자 선택을 대신하지 않는다. Xcode GUI, 앱 실행, attach, 환경 변수 변경, 전역 설정 변경은 이번 정적 확인에서 수행하지 않았다.
