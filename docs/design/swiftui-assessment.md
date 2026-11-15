# mac-cu의 SwiftUI 적용 조사

확인일: 2026-11-09 (KST). 범위: Apple 공식문서 본문·공개 DocC JSON·WWDC transcript와 현재 canonical 소스의 읽기 전용 검토. 구현, 빌드, GUI 실행, 설치, 기기 조작, SDK 변경, commit/push는 하지 않았다.

## 판단부터

SwiftUI는 mac-cu의 검사 목록·속성·설정 UI에 충분히 검토할 만한 선택이다. 최신 macOS에서는 borderless 창, floating window level, 배치 및 Liquid Glass 공통 컨테이너까지 공식 API가 있다. 따라서 특수 창이라는 이유만으로 배제하면 안 된다. 다만 **AppKit 직접 사용을 완전히 없애면서 현재 기능을 동일하게 유지할 수 있다는 근거는 확보하지 못했다.** IOSurface 실시간 표시, guest HID 전달과 release, 창 조작·회전 중 입력 차단은 표준 UI 선언과 별도의 검증 대상이다.

현재 권고는 **기존 AppKit 창에서 검사 UI 한 영역만 SwiftUI로 검증하는 (c)** 이다. 근거는 창·LCD·입력 계약을 이미 구현한 상태에서, SwiftUI의 이점인 선택 기반 목록/속성과 상태 표현을 가장 작은 변경으로 평가할 수 있기 때문이다. 검사 UI 작성 부담이 실제로 줄고 focus·AX 동등성을 확보하면 (b)로 확대할 수 있다. 이는 설계 추론이며, 실측 성능이나 개발 시간 우위를 증명한 결과는 아니다. 당장 전환하지 않고 현재 검사 기능의 좌표 검증을 완료하는 것도 유효한 선택이다.

Apple의 [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)는 기존 AppKit 계층에 부분 UI를 넣는 용도를 명시한다. [WWDC24 창 구성](https://developer.apple.com/videos/play/wwdc2024/10148/)과 [windowLevel](https://developer.apple.com/documentation/swiftui/scene/windowlevel(_:))은 창 기능의 실제 대응 근거다. 어느 문서도 외부 Simulator framebuffer/HID/LLDB 수집을 자동으로 제공한다고 설명하지 않는다. 그 분리는 아래 코드 관측에서 확인했다.

## 근거를 읽는 방법

- **문서 사실**: Apple 문서가 설명하는 기능과 macOS availability.
- **코드 관측**: 아래 파일에서 현재 확인한 구현. 미커밋 변경을 포함한 작업 디렉터리 기준이며 릴리스 전체의 보증이 아니다.
- **설계 추론**: 위 둘을 연결한 추천·브리지 예상·회귀 비용.
- **미확인**: 실행/컴파일/실측하지 않은 내용. 문서에서 직접 대응을 찾지 못한 것을 ‘지원 불가’로 바꾸지 않는다.

본문을 보지 못하는 JavaScript 셸은 수집으로 계산하지 않았다. Apple가 제공하는 동일 페이지의 `tutorials/data/documentation/…json`과 HIG/튜토리얼 DocC JSON으로 본문·플랫폼 metadata를 읽었다. 전체 문서의 저장·대량 다운로드는 하지 않았고 필요한 항목을 메모리에서 요약했다. 이 문서는 공식 문서의 한국어 적용 검토이며 문서 번역본이 아니다.

## 현재 코드와 배포 구조

소스 경로는 `mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/` 기준이다.

| 코드 관측 | 의미 |
| --- | --- |
| `SimulatorWindow.swift`: `SimulatorScreenView: NSView`, `screenLayer.contents = surface`, framebuffer descriptor와 IOSurface, NSWindowDelegate | LCD는 단순 이미지 위젯이 아니라 공유 surface 갱신 경로다. SwiftUI 이미지로 바꾸면 복사·색·지연·surface 수명을 재평가해야 한다. |
| 같은 파일: mouse down/drag/up, key down/up, modifiers/HID, `releaseInput`, inspection picking과 geometry gate | host 컨트롤 키 입력과 guest 입력의 경계를 보존해야 한다. |
| `SimulatorDeviceChrome.swift`: move/resize grips, hitTest, 키보드 순회, popover | 창 크기뿐 아니라 실제 조작·포커스·LCD 외부 영역의 입력 정책이 요구사항이다. |
| `SimulatorLCDContent.swift`: macOS 26 `NSGlassEffectContainerView`와 fallback, LCD/body/canvas 공통 합성, Reduce Motion, 회전 표시 | 기존 compact 공통 유리 컨테이너, 불투명 LCD, 회전 중 toolbar 숨김을 별도 합격 조건으로 유지한다. |
| `SimulatorToolbox.swift`: `NSTableView` AX browser, `NSOutlineView` hierarchy/properties/results; `import SwiftUI` 존재 | import만으로 SwiftUI UI를 사용한다고 판단할 수 없다. 검사 목록은 전환 후보이며 수집기는 독립이다. |
| `SimulatorAccessibility.swift`: supported AXPress와 선택 identity 대조 | 선택은 입력 동작이 아니다. 별도 tap/AXPress의 권한·identity 검사를 보존한다. |
| `SimulatorViewHierarchy.swift`, `scripts/view-capture/`, `docs/simulator-view-capture.md` | owned debugserver/private FD, LLDB expression, target identity/cancel/detach/recovery는 guest 수집 계층이다. |
| `main.swift`: CLI/권한/daemon/native host 분기; `setup.py`: 여러 Swift 파일을 `swiftc -O`로 빌드·bundle/sign/resource 설치 | 일반 Xcode SwiftUI 템플릿으로 entry를 바꾸면 helper dispatch와 daemon 수명까지 영향을 준다. hosting만으로는 App lifecycle 전환이 필요 없다. |

검토한 `setup.py`의 swiftc 명령에는 명시적 `-target`/deployment target이 없고 생성 Info.plist에도 `LSMinimumSystemVersion`을 찾지 못했다. 따라서 **프로젝트가 약속하는 최소 macOS는 unknown**이다. macOS 26 런타임 분기와 fallback이 존재한다고 deployment target이 26이라는 뜻은 아니다. 실제 compiler default·배포 바이너리 load command는 이번에 빌드/검사하지 않았다. 선택 Xcode 경로는 읽었지만 SDK가 모든 API를 컴파일할 수 있다고 확정하지 않았다. 새 프레임워크 도입이나 deployment target 변경을 실행하지 않았다.

## 공식문서 목록과 macOS 적용

다음 표의 모든 출처는 2026-11-09 본문/metadata 확인. 최소 버전은 표에 적은 **타입 또는 정확한 API** 기준이다. 같은 타입의 최신 overload까지 같은 버전으로 가정하지 않는다. 프로젝트 최소 버전이 unknown이므로 ‘사용 가능’은 해당 macOS/SDK를 선택하거나 availability guard·fallback을 마련한다는 조건이다. iOS availability는 macOS 근거로 사용하지 않았다.

| 공식 제목/링크 | macOS 최소 | 핵심 내용과 프로젝트 적용 |
| --- | --- | --- |
| [SwiftUI](https://developer.apple.com/documentation/swiftui) | 10.15 | 선언형 views·controls·data flow 및 AppKit 통합을 제공. UI와 수집 backend의 역할을 분리하는 출발점. |
| [Introducing SwiftUI](https://developer.apple.com/tutorials/swiftui), [Develop in Swift](https://developer.apple.com/tutorials/develop-in-swift/) | 학습자료, API별 상이 | 기존 튜토리얼에는 최신 SwiftUI/Xcode 관행을 보여주지 않는다는 Apple 경고가 있다. 최신 학습 경로로 Develop in Swift를 안내한다. macOS 창 설계의 availability 근거는 API 문서로 보완한다. |
| [App](https://developer.apple.com/documentation/swiftui/app), [WindowGroup](https://developer.apple.com/documentation/swiftui/windowgroup) | 11 | App은 단일 entry, Scene은 시스템 관리 수명. WindowGroup은 창별 독립 상태와 다중 창/표준 명령을 제공. 현재 daemon/CLI entry와 자동 교체하면 안 된다. |
| [Window](https://developer.apple.com/documentation/swiftui/window), [OpenWindowAction](https://developer.apple.com/documentation/swiftui/openwindowaction) | 13 | 단일 창과 식별자/값 기반 창 열기. singleton과 group의 재사용 방식·종료 동작이 다르므로 device/screen identity와 일치시켜야 한다. |
| [defaultSize(width:height:)](https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:)), [windowResizability](https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)) | 13 | 초기 기본 크기와 resize 제약. 복원 크기는 기본 크기를 덮을 수 있다. 현재 drag 중 clamp/고정 anchor와 동일하다는 뜻은 아니다. |
| [windowStyle](https://developer.apple.com/documentation/swiftui/scene/windowstyle(_:)), [PlainWindowStyle](https://developer.apple.com/documentation/swiftui/plainwindowstyle) | modifier 11, plain 15 | plain/borderless 스타일은 실제 지원. 기존 비정형 mask/hitTest/resize grips의 동등성은 별도 검증. |
| [windowLevel](https://developer.apple.com/documentation/swiftui/scene/windowlevel(_:)), [floating](https://developer.apple.com/documentation/swiftui/windowlevel/floating) | 15 | floating 레벨도 표준 대응이 있다. NSPanel의 모든 activation/collection 동작을 대체한다고 확장 해석하지 않는다. |
| [Tailor macOS windows with SwiftUI — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10148/) | 소개 기능은 macOS 15 세대; 개별 심볼 별도 확인 | toolbar 배경·title, restoration, default/ideal placement, display visibleRect, plain 창을 설명. 다중 디스플레이 배치의 유용한 근거. 모든 API를 13에 적용하면 안 된다. |
| [Commands](https://developer.apple.com/documentation/swiftui/commands), [ToolbarItem](https://developer.apple.com/documentation/swiftui/toolbaritem) | 11 | 메뉴 명령·툴바 항목. 기기별 focused command 대상과 기존 LCD 밖 compact rail 배치는 추가 설계가 필요하다. |
| [popover](https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:)) | 10.15 | 상태 binding과 anchor/arrow edge. macOS에서는 arrow edge를 존중한다. escape·focus 복귀·별도 live preview는 실제 동등성 확인 필요. |
| [inspector](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)) | 14 | 검사 영역 표현·presentation state 복원. 외부 앱 검사 데이터를 수집하는 API는 아니다. |
| [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) | 13 | 선택→목록/상세 관계에 적합. 기존 compact 창 폭을 잠식하는 기본 sidebar를 그대로 채택할 필요는 없다. |
| [Table](https://developer.apple.com/documentation/swiftui/table), [List](https://developer.apple.com/documentation/swiftui/list), [OutlineGroup](https://developer.apple.com/documentation/swiftui/outlinegroup) | 12 / 10.15 / 11 | 선택 binding과 identified tree 전개 지원. Table sortOrder 변경 후 실제 데이터 정렬은 앱 책임. outline 확장 상태·선택 복원·큰 트리 비용은 현재 동작과 대조 필요. |
| [FocusState](https://developer.apple.com/documentation/swiftui/focusstate), [onKeyPress](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)) | 12 / 14 | focus binding과 hardware key 처리. 인용 overload는 down/repeat 동작이다. guest raw keycode/modifier/up 전달 전부가 동등하다는 근거는 아니다. |
| [Managing model data in your app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) | Observation 연동 14 | 읽은 observable property를 추적해 갱신. capture identity·대상 수명과 view identity는 별개로 보관해야 한다. 이전 OS에는 기존 ObservableObject 계열 검토가 필요. |
| [Demystify SwiftUI — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10022/) | 개념 자료 | identity/lifetime/dependency, 값 타입 view와 pointer identity의 차이. capture 내 객체 주소를 영구 row identity로 삼지 않는 근거. |
| [Discover concurrency in SwiftUI — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10019/) | 개념 자료; task 정확한 overload 최소 버전은 미확인 | main actor와 update 순서, async 작업을 UI에 연결하는 방식. async라고 blocking LLDB가 자동 background가 되지 않는다. cancellation도 backend detach/recovery 완료를 대체하지 않는다. |
| [Demystify SwiftUI performance — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10160/) | 개념 자료 | dependency 범위·body 작업·List/Table identity와 업데이트 비용 점검. LCD 매 frame을 검사 목록 observable state에 전파하지 않는 설계가 합리적이다. 실제 개선 폭은 미측정. |
| [animation(_:value:)](https://developer.apple.com/documentation/swiftui/view/animation(_:value:)), [accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion) | 현재 metadata 10.15 / 10.15 | 특정 상태 변화에 animation 적용, Reduce Motion이면 큰 공간 이동/3D 효과 회피. 회전 표시 완료 전 입력 차단은 별도 상태 계약이다. |
| [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer), [Material](https://developer.apple.com/documentation/swiftui/material) | 26 / 12 | glass shapes를 함께 합성·morph하는 공식 컨테이너와 일반 blur material. 둘을 같은 효과로 취급하지 않는다. 현재 AppKit common container와 시각적 일치는 미검증. |
| [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | 디자인 지침 | Liquid Glass는 control/navigation 층, content에는 사용하지 말라는 지침. 불투명 LCD와 glass 조작부 분리에 맞는다. 툴바의 빈번한 명령·그룹·폭에 따른 overflow를 고려하되 현재 compact 배치를 무조건 표준 toolbar로 바꾸는 근거는 아니다. |
| [SwiftUI Accessibility: Beyond the basics — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10119/), [accessibilityElement(children:)](https://developer.apple.com/documentation/swiftui/view/accessibilityelement(children:)) | modifier 10.15; 세부 API별 상이 | 표준 control의 의미 자동 제공과 custom control의 보완, group/children/representation을 설명. AX는 렌더링 객체의 일대일 복제가 아니다. |

## AppKit ↔ SwiftUI 경계

| 공식 문서 (확인일 동일) | macOS 최소 | 수명·layout·입력에 대한 계약과 적용 |
| --- | --- | --- |
| [AppKit integration](https://developer.apple.com/documentation/swiftui/appkit-integration) | 항목별 | 양방향 통합이 공식 경로다. 전체 App entry를 바꾸지 않고 부분 채택 가능. |
| [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview), [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller) | 10.15 | 기존 AppKit 계층에 SwiftUI root를 넣는다. HostingView는 content size preference를 AppKit layout에 보고하고 event delivery를 조정한다. Controller는 기존 controller처럼 embed/present한다. |
| [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), [NSViewControllerRepresentable](https://developer.apple.com/documentation/swiftui/nsviewcontrollerrepresentable) | 10.15 | make/update/teardown을 시스템이 호출. delegate/target-action 역방향 전달은 Coordinator로 구현해야 하며 자동 state 동기화가 아니다. SwiftUI가 관리하는 root의 frame/bounds/transform을 직접 설정하면 undefined behavior라고 명시한다. |
| [dismantleNSView](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/dismantlensview(_:coordinator:)) | 10.15 | observer 등 정리 지점. mac-cu에서는 pointer/key release, callbacks 해제와 owned 작업 취소 계약을 설계해야 한다. view 제거가 debugger detach 완료라는 뜻은 아니다. |
| [sizeThatFits](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)) | 13 | 한 layout pass에도 여러 proposed size를 받을 수 있다. LCD 픽셀/guest point/host point 계약은 이 값들과 구분한다. |

설계 추론: (b)에서는 representable의 root layout을 SwiftUI가 소유하고, 기존 NSView 내부 layer 배치·screenPoint 변환은 bridge 내부가 소유하도록 경계를 그어야 한다. 기존 canvas의 직접 frame 조작을 representable root에 그대로 옮기면 위 계약과 충돌한다. (c)는 기존 AppKit 창 layout에서 hosting 영역의 크기를 관리하고 SwiftUI에 목록/상세만 맡긴다.

포커스는 두 체계를 연결해야 한다. SwiftUI FocusState 변경만으로 현재 `window.makeFirstResponder`와 guest release가 일치한다고 가정하지 않는다. host 검색창·행 선택·popover가 focus를 얻으면 LCD key 전달을 막고, 닫힐 때 이전 host control로 돌아오는 경로가 필요하다. AX 역시 hosting으로 자동 완성되지 않는다. 표준 controls의 label/value/selection을 보존하고 LCD bridge와 중복 AX 요소·읽기 순서를 별도 확인해야 한다.

## 기능별 대응표

| 현재 요구 | SwiftUI 표준 후보 | 유지/예상되는 bridge 및 제약 |
| --- | --- | --- |
| 실시간 LCD surface | View 합성, 이미지/그래픽 표시 | 현재 IOSurface→CALayer를 직접 대체하는 SwiftUI surface 경로는 이번 조사에서 미확인. 기존 NSView/CALayer bridge가 최소 변경 예상. 프레임 copy 없는 경로·지연·backing scale 실측 필요. |
| 정확한 pointer/key→guest HID | gesture, focus, onKeyPress | raw NSEvent, key up/modifiers/held input, first mouse, mask 밖 입력과 cancel/release는 기존 bridge 보존 예상. SwiftUI로 불가능하다고 확정하지 않음. |
| 창 이동·resize grips·화면 경계 clamp | windowResizability/defaultSize/placement, plain style | 정책 수준 대응은 존재. drag anchor·비정형 hitTest·resize 중 입력 release의 직접 동등 대응은 미확인. |
| LCD mask·glass body·공통 toolbar 합성 | Shape/clip, GlassEffectContainer | 창 클릭 영역과 시각적 clip은 다를 수 있음. 불투명 LCD·glass grouping·외부 control hitTest의 동등성은 검증 필요. |
| floating preview/panel | Window/WindowGroup/openWindow/windowLevel(.floating) | 레벨은 대응 확인. 실제 floating live preview 보존, key 여부/activation/닫기와 host window 연결은 기존 NSWindow 정책 대조 필요. 제거된 독립 LCD DesignPreview 앱을 재도입할 이유 없음. |
| 다중 기기/스크린 창 | 값/ID 기반 WindowGroup | device+screen identity와 close/reopen·복원·daemon 유지 계약 필요. Window singleton은 앱 종료 동작까지 다를 수 있다. |
| host 회전과 guest orientation·좌표 | rotation/animation, layout | 표시 효과가 guest rotation 확인이나 coordinate space를 대체하지 않음. 회전 중 toolbar 숨김·input gate·완료 후 geometry commit 유지. |
| AX 목록/선택/속성/결과 | Table/List/inspector | 수집·identity stale 검사·supported AXPress/tap은 기존 서비스. UI 선택만으로 guest action 실행 금지. |
| UIKit hierarchy | OutlineGroup/Table/상세 | tree 표현만 대체. LLDB/owned debugserver/cancel/detach/recovery는 그대로 독립 검증. |
| capture/AX/HID와 권한 | 상태·오류·진행 UI | SwiftUI는 권한 또는 guest introspection의 대체 수집기가 아니다. 현재 CLI/resource/signing/권한 identity 보존. |

## ‘순수 SwiftUI’ 세 가지를 동일 조건으로 비교

공통 조건: 현재 compact toolbar·LCD·회전/input gate·floating preview·다중 screen·선택과 명시 action 분리·권한/CLI·데이터 보존. 아래 비용은 정성적 설계 판단이며 일정 숫자나 벤치마크를 만들지 않았다.

| 판단 축 | (a) AppKit 직접 사용 없는 전체 앱 | (b) UI SwiftUI + LCD/창 최소 bridge | (c) AppKit 창 + inspector/settings 부분 SwiftUI |
| --- | --- | --- | --- |
| 요구 충족 근거 | 일반 UI/최신 창은 가능. raw surface/input와 현재 모든 계약 동등성은 미확인 | 기존 surface/input 경로를 유지할 수 있으나 bridge 설계 필요 | 검사 UI를 바꾸고 기존 창/LCD 계약 유지 가능 |
| 기존 toolbar | 최신 glass/toolbar로 재구성·시각 동등성 전면 검증 | 전체 합성 경계를 정하고 유지 가능성 검증 | 현 toolbar 유지하며 내부 검사 영역만 평가 가능 |
| 동작 회귀·검증 범위 | entry/창/입력/표시/검사 전반 | focus/layout/bridge/window state 전반 | 해당 영역 선택·focus·상태/AX 연결 중심 |
| 코드 복잡도 | 선언형 UI 이점, 저수준 직접 대체 미확인으로 총량 감소 보장 불가 | UI 간결화 여지, 양방향 소유권/Coordinator 부담 | 두 framework 공존하나 영향 범위 제한; 작은 부분에서 실익 측정 가능 |
| 빌드·배포 | App entry 전환이면 main.swift dispatch 재설계; 최소 OS 정책 확정 필요 | hosting 여부에 따라 entry 보존 가능; SDK/guard 확인 | 현재 swiftc/bundle 방식 유지 가능 예상. 실제 compile은 미실행 |
| 성능 | framebuffer 경로 재구성 위험, 실측 unknown | surface bridge 유지해도 state invalidate/합성 비용 검증 | LCD와 검사 state 분리 가능; 큰 목록 성능 여전히 검증 |
| 접근성 | 표준 control 이점; custom LCD/toolbar 자동 해결 아님 | bridge와 SwiftUI AX 경계 검증 | 좁은 범위에서 label/선택/읽기 순서 비교 가능 |
| 현재 기능 완성 지연 | 가장 넓은 선행 작업 예상 | 부분 채택보다 넓은 검증 예상 | 최소 범위로 선택 가능; 진행 중인 guest 좌표 검증과 분리 가능 |

(a)의 가치를 평가하려면 ‘AppKit 없는 것’ 자체가 우선 목표인지, 최신 macOS만 지원해도 되는지부터 제품 선택이 필요하다. 현재 요구를 그대로 보존하면서 완전 제거를 완료할 수 있다는 증거는 없다. (b)는 장기 UI 정비 방향으로 합리적 후보지만 지금 당장 선택해야 한다는 근거는 없다. (c)는 되돌릴 수 있는 최소 실험으로 우선 추천한다.

## guest가 SwiftUI인 경우의 검사 한계

**문서 사실:** SwiftUI view는 value type이며 pointer identity를 사용하는 UIView/NSView와 다른 identity 모델을 갖는다([Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/)). AX는 grouping/representation/children으로 시각적 구조와 다르게 표현할 수 있다([Accessibility WWDC21](https://developer.apple.com/videos/play/wwdc2021/10119/)).

**설계 추론:** AX semantic tree, SwiftUI의 선언/의존성 graph, 런타임 UIKit backing hierarchy는 일대일 대응을 전제할 수 없다. 현재 UIView 수집이 SwiftUI guest에서 반환하는 backing views를 표시할 수는 있어도, 모든 SwiftUI View의 원래 타입·state·modifier·source graph를 복원한다고 주장할 수 없다. AX 이름/동작은 사용자 의미를 설명하는 별도 관측이며 UIView geometry join의 대용물이 아니다. backing 구성의 구체적 모습과 OS별 변화는 이번에 확인하지 않았다.

**코드 관측:** 현재 collector는 guest 프로세스에 붙어 UIKit/undocumented DBGTargetHub를 읽는다. host의 NSView를 SwiftUI View로 바꾸어도 이 guest process 경계가 없어지지 않는다. Apple의 inspector modifier는 host UI 영역의 배치 API이지 다른 앱의 Xcode View Debugger 데이터를 얻는 API가 아니다. ‘host를 SwiftUI로 만들면 Xcode inspector를 바로 얻는다’는 결론은 근거가 없다.

**검증 범위:** 요청자가 전달한 최신 fixture strict 7뷰/14 join 성공은 이번 조사에서 원본 증거를 열어 독립 재검증하지 않았다. `docs/simulator-view-capture.md`에는 이전 단계의 실패/diagnostic 이력이 남아 있어 최신 성공을 그 문서만으로 확정하지 않는다. CGPoint 구성/변환 오류 수정 여부는 backend 담당의 실제 capture/oracle/cleanup 보고로 확정할 일이다. 성공하더라도 LCD viewport/host rotation/presentation mapping·clip·시점 일치는 별도다. host UI 전환의 이익이나 필요성을 그 좌표 오류에서 도출하지 않는다.

## 다음 결정과 가장 작은 검증 제안

선택지는 세 가지다. 현재 검사·좌표 검증을 먼저 끝낸다. 검사 UI의 반복 작성 부담을 줄이고 싶으면 (c)를 검증한다. 전체 UI를 SwiftUI 중심으로 정비하려면 (c)의 결과와 최소 macOS 정책을 확인한 뒤 (b)를 결정한다. (a)는 직접 AppKit 제거가 독립 목표일 때 별도 기술 검증이 선행되어야 한다.

(c)의 최소 다음 검증은 **기존 검사 영역에 동일 snapshot의 AX 목록·선택·속성/결과만 hosting하여 기존 UI와 비교**하는 것이다. 이는 다음 작업 제안이며 이번에는 코드·preview 앱을 만들지 않았다. backend·LCD·창·툴바·설치 구조는 이 검증의 변경 대상에 포함할 필요가 없다.

유지할 동작과 구체적인 합격 조건:

1. ‘읽기’ → loading → snapshot/실패를 명시한다. empty와 no-match를 구분한다. 실패/취소는 성공 상태로 보이지 않으며 재시도 대상 identity가 드러난다.
2. 검색창에서 Tab으로 목록에 진입하고 ↑/↓로 선택, 상세 속성이 같은 capture의 같은 행을 가리킨다. selection 표시와 텍스트/체크 등 비색상 상태 단서를 유지한다. 단순 선택·Return이 암묵적으로 guest tap을 실행하지 않는다.
3. 별도 ‘탭’/‘접근성 실행’ control에서만 action이 발생한다. supported AXPress가 없거나 stale capture이면 실행 불가와 새로 읽기 경로가 보인다.
4. LCD pick 중 mouse/key가 guest HID로 새지 않는다. Escape는 pick/popover 취소, 닫은 뒤 focus는 호출 host control로 복귀한다. 검색 입력이 LCD로 전달되지 않는다. held key/pointer는 focus 변경·close·취소 시 release된다.
5. VoiceOver에서 행 label/value/selection, 상세, loading/error/result 순서를 확인한다. SwiftUI+hosting이 같은 요소를 중복 노출하지 않아야 한다. custom control의 label을 symbol 기본값으로 대체하지 않는다.
6. 작은 창·긴 값·큰 snapshot에서 선택과 상세 문맥을 유지한다. Reduce Motion/Transparency와 light/dark, compact 공통 glass·불투명 LCD·회전 중 toolbar 숨김을 보존한다.
7. 실제 floating live preview, 다중 device/screen 창, backing scale·화면 이동·회전 후 pointer mapping은 후속 전환 범위에 들어갈 때 기존 테스트와 비교한다. UI 시험 성공을 좌표/수집 backend 성공으로 계산하지 않는다.

검증 비용을 판단하려면 선택 유지·읽기 중 취소·stale 결과 도착·화면 교체·닫기 재열기·keyboard/AX 경계를 먼저 측정해야 한다. FPS/메모리/빌드 시간 개선이나 일정은 현재 unknown이다. 구현을 승인받더라도 native 실행은 `docs/native-check-safety.md`의 GUI 전 dispatch 증명, parent watchdog/deadline/exact-instance budget 및 입력 guard를 따라야 한다. 제거된 DesignPreview 앱은 만들지 않는다.

## 이번에 실제로 확인한 것과 남은 한계

- 수행: 공식 웹/DocC 본문·macOS metadata, 현재 관련 소스·setup/entry·검사 수집 문서, 기존 작업 트리 상태, 문서 diff/배포 validator.
- 미수행: native 빌드/typecheck, GUI/기기·preview 실행, SDK 변경, global 설치/재시작, 릴리스/manifest 수정, backend live 증거 재검증. 문서 조사 요청의 범위를 지켰다.
- unknown: 지원 최소 macOS 정책, 실제 선택 SDK의 전체 API 컴파일 가능성, task overload의 정확한 availability, 완전 AppKit 제거의 동등성, 최신 fixture 원본과 LCD mapping, 성능/접근성 실제 동등성.
- Decisions API는 호출하지 않았다. 확정 기술 계약을 확률 분류로 대체할 필요가 없는 조사다. 하위 agent도 사용하지 않았다.
