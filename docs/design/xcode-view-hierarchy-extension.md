# SwiftUI 런타임 계층과 렌더링 확장

2026-11-09 · 읽기 전용 설계 검토 · 사용자 선택: **SwiftUI 텍스트·도형과 선언형 계층**

## 결정

다음 작업은 **실제 SwiftUI 선언형 런타임 트리 수집과 텍스트·도형의 충실한 표시를 함께 검증하는 한정 실험**이다. UIKit 탐색 기능 확장이나 host UI의 SwiftUI 전환은 이번 범위가 아니다. 1.31.0 UIKit 캡처·hidden/alpha 편집·복원 계약을 보존한다. 두 결과 중 하나만 성공하면 요청을 완료한 것으로 판정하지 않는다.

첫 후보는 hosting view의 `_viewDebugData()`와 `_ViewDebug.serializedData`로 얻는 트리, 그리고 같은 hosting subtree의 실제 렌더링이다. 현재 설치 SDK에 두 API 선언이 존재한다. 임의 앱에서 호출 가능한 adapter, JSON 스키마, 이미지 충실도는 아직 검증하지 않았다. underscored API를 Apple의 안정된 외부 검사 API라고 표현하지 않는다.

## 현재 상태와 차이

현재 구현 판단은 [1.31.0 전달 기록](simulator-inspection-delivery.md)과 [제품 설명](../simulator-inspector.md)을 우선한다. 기존 기록의 성공은 이번 재실행 결과가 아니다. [swiftui-assessment](swiftui-assessment.md)는 주로 **mac-cu host UI를 SwiftUI로 작성하는 선택**을 검토한다. guest 선언형 트리 수집 가능성을 판정하는 문서가 아니다. 과거 텍스처 실험의 ‘3D 미구현’ 설명도 현재 사실로 사용하지 않는다.

아래 소스는 `mac-computer-use/skills/mac-computer-use/scripts/` 기준이다.

| 항목 | 현재 mac-cu의 실제 동작과 근거 | 이번에 필요한 차이 / Apple 근거 |
| --- | --- | --- |
| UIKit 구조·이미지 | `mac-cu-src/SimulatorViewHierarchy.swift:172–289`는 owned registry 노드로 트리를 만들고 같은 작업에서 class/parent를 확인하여 텍스처만 연결한다. | 실제 선언형 노드가 필요하다. Xcode는 SwiftUI와 UIKit 혼합 구조를 보여 준다. [WWDC19](https://developer.apple.com/videos/play/wwdc2019/412/) |
| SwiftUI 텍스트·도형 | 전달 기록은 hosting PNG에서 누락될 수 있다고 명시한다. `SimulatorViewHierarchy.swift:278–283`도 이 한계를 표시한다. | 보이는 Text·Shape가 계층 표시에도 나타나야 한다. 현재 누락의 내부 원인은 확정되지 않았다. |
| 선택·3D | `SimulatorInspectorWindow.swift:133–208`, `SimulatorInspectorRenderer.swift:105–140`: 트리/장면 선택, 겹친 후보, 카메라, 텍스처/윤곽. 검색은 트리만 필터링한다. | 선언형 선택 ID와 해당 그래프 metadata를 연결해야 한다. 기존 UIKit 선택 토큰으로 바꾸지 않는다. Xcode의 선택·속성 구조는 [현재 문서](https://developer.apple.com/documentation/xcode/diagnosing-issues-in-the-appearance-of-your-running-app/)에 설명돼 있다. |
| 속성·제약 | `SimulatorViewHierarchy.swift:265–270`은 제품 노드의 properties를 hidden/alpha로 재구성한다. `SimulatorInspectorModel.swift:75–81,117–124`는 이를 읽는다. | 실제로 반환된 타입·값·modifier·위치/크기만 표시한다. 현재 제품 경로에는 identity가 연결된 constraint graph가 없다. 요청 키가 있다는 이유로 제약 조건을 표시하지 않는다. |
| 안전·수명 | `SimulatorInspectorIntegration.swift:96–103,133–168,177–214,230–265`, `SimulatorInspectorModel.swift:199–241`: target/context/generation, owner/epoch/token, late result 거절, release, 편집·복원 gate. | 선언형 노드는 캡처 한정 읽기 전용이다. UIKit 편집 권한을 상속하지 않는다. SwiftUI 값 타입에는 객체 참조 기반 워크플로를 그대로 적용할 수 없다. [WWDC19](https://developer.apple.com/videos/play/wwdc2019/412/) |

### 정확한 현재 요청과 누락 진단

[현재 capture.py](../../mac-computer-use/skills/mac-computer-use/scripts/view-capture/capture.py)의 `hierarchy_request`(492–503)는 discovery 1, initiator version 4, priority 0, compression false, visibility 1, `propertyNamesAreExclusive=false`인 `DebugHierarchyPropertyAction` 하나다. 요청 속성은 frame/bounds/center/transform/clipsToBounds/hidden/alpha, AX identifier/label, text와 Auto Layout 항목이다. texture 옵션은 **snapshotImage 하나만 추가**한다. 제품 capture도 338–341에서 이 옵션을 고정 사용한다. 선언형 그래프나 encoded-layer 전용 요청은 없다.

[operation.inc](../../mac-computer-use/skills/mac-computer-use/scripts/view-capture/operation.inc):250–320은 살아 있는 UIView를 보유한 상태로 frame, bounds에서 변환한 fixed-space corners, hidden/alpha와 토큰을 읽는다. `libViewDebuggerSupport`의 `DBGTargetHub`에서 같은 요청 결과를 얻고 class/parent를 재검사한다. [normalizer](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/SimulatorViewHierarchy.swift):220–251은 여기서 **asset만** registry 토큰에 연결한다. 원래 DBG 속성·SwiftUI 그룹은 제품 노드에 합치지 않는다. 따라서 수집기 응답에 선언형 정보가 있더라도 현재 UI에 도달한다는 보장은 없다.

**기존 관측:** [초기 UIKit 텍스처 실험](simulator-view-texture-experiment-result.md):58–71에서 부모 PNG에 자식 색상이 없었다. 이는 해당 fixture의 self 이미지 근거다. [제품 qualification](../../mac-computer-use/tests/simulator-inspector-product-live/QUALIFICATION.md):182–184와 전달 기록은 SwiftUI hosting 이미지의 누락 한계를 기록한다. 이번 감사에서는 그 PNG를 다시 열거나 SwiftUI 픽셀을 측정하지 않았다.

**추론:** SwiftUI의 텍스트·도형이 UIView별 이미지와 다른 렌더링 표현에 있고, 현재 self-image 요청이나 product 정규화에서 빠질 가능성이 있다. 이 설명은 ‘SwiftUI는 항상 GPU만 사용한다’는 단정이 아니다. 요청 variant, raw 응답, decoded PNG와 화면을 같은 정적 fixture에서 비교해야 원인을 좁힐 수 있다. Renderer는 현재 PNG를 디코딩해 quad에 올린다(81–103,125–138). 입력 PNG에 없는 텍스트를 복원하지 않는다.

## 근거 수준과 실행 후보

- **Apple 문서 사실:** 현재 Xcode 문서는 SwiftUI의 크기·배치 진단을 설명한다. WWDC19는 선언형 트리, 값 타입, reflection으로 읽는 custom view 속성과 modifier, UIKit 혼합 표시를 시연한다. WWDC19의 세부 UI/속성이 Xcode 27.2에서도 모두 같다고 주장하지 않는다. 외부 수집 프로토콜은 공개하지 않는다.
- **설치 SDK의 정적 관측:** Xcode.app의 version은 27.2 / 27B48이다. iPhoneSimulator SDK `SwiftUI.framework/.../arm64-apple-ios-simulator.swiftinterface:27944,28006`에 generic `_UIHostingView<Content>`와 MainActor `_viewDebugData() -> [SwiftUICore._ViewDebug.Data]`가 있다. `SwiftUICore.framework/.../arm64-apple-ios-simulator.swiftinterface:19132–19191`에는 type/value/transform/position/size/environment/phase/layoutComputer/displayList, `serializedData`, Encodable 선언이 있다. Data 내부 필드는 opaque다. SDK의 선언·export는 현재 guest의 성공 응답이나 안정된 ABI를 증명하지 않는다.
- **직접 작성된 공개 실험 코드:** [SwiftUIViewDebug, 고정 commit a9067fe](https://github.com/OpenSwiftUIProject/SwiftUIViewDebug/blob/a9067fe57dc333845a22edf4e88b443d81f478a2/Sources/SwiftUIViewDebug/ViewDebug.swift):66–89는 **앱 안에서 알려진 generic V**의 hosting view를 cast하고 `_viewDebugData()`를 `serializedData`로 바꾼다. 임의 앱의 Content 타입을 외부에서 지워 호출하는 방법은 입증하지 않는다. 코드를 복사하거나 dependency를 추가하지 않았다.
- **버전 의존 private 단서:** 설치된 DebugHierarchyKit의 문자열에서 `encodedPresentationLayer`, `snapshotImageRenderedUsingDrawHierarchyInRect`를 확인했다. Foundation 문자열에서는 지정한 SwiftUI/graph 후보가 검출되지 않았다. 문자열의 존재나 부재로 지원 가능성을 판정하지 않는다. [기존 한정 정적 조사](xcode-view-texture-contract.md)의 encoded-layer/rendered-view/effect factory 후보는 재사용하되, 미복구 payload를 추측해 보내지 않는다.

### 후보 데이터 계약

별도 `swiftUI` 섹션을 추가하고 기존 UIKit roots/assets/editing을 유지한다. 아래는 **제안 스키마**이며 관측된 Apple wire 형식이 아니다.

| 영역 | 필요한 계약과 거절 조건 |
| --- | --- |
| 캡처 | schemaVersion, provider/SDK/runtime build, captureID, PID/start/path, device/boot/display/presentation, owner/epoch, startedAt/finishedAt. 그래프와 이미지가 별도 pass면 각각 시각과 consistency 상태를 둔다. |
| Hosting 연결 | `hostingNodeToken`은 같은 작업의 registry 토큰이어야 한다. 같은 주소·이름만 보고 다른 캡처에 연결하지 않는다. 호스트가 여러 개면 각각 독립 graph root를 둔다. |
| 선언형 노드 | 원본에서 확인한 child 관계, capture-local nodeID, parentID/order, 원래 type 이름과 실제 property 값/status/provenance. provider ID가 없으면 순회 경로로 캡처 내부 ID만 만들고 persistent identity라고 부르지 않는다. 타입명 분해로 자식 노드를 만들지 않는다. |
| 속성·소스 | property는 available/unavailable/failed/redacted를 구분한다. source file/line은 debug provider가 반환해 연결을 검증했을 때만 제공한다. reflection 문자열은 typed editable value가 아니다. environment 전체를 무제한 덤프하지 않는다. |
| geometry | 반환된 position/size/transform의 공간과 변환을 보존한다. fixed-space 변환을 입증하기 전에는 장면 picking/LCD 강조를 허용하지 않는다. geometry가 없는 구조 노드도 트리에서 선택할 수 있다. |
| 렌더링 | representation=`nodeSelf`/`hostingSubtreeComposite`/`encodedLayer`/`referenceComposite`, owner graph/node 또는 hosting token, descendant inclusion, pixel scale/bounds, clipping/effects, format/byte budget, completeness와 실패 이유. displayList 문자열은 PNG나 실행 가능한 scene으로 간주하지 않는다. |
| 권한 | 선언형 노드는 `editableProperties=[]`. 캡처 교체·reconciliation·target 변경으로 ID를 만료한다. 명시적 UIKit 노드 선택만 기존 token/edit gate로 진입한다. |

트리는 runtime serialized graph만 사용한다. UIKit class명, 스크린샷 segmentation, 소스 AST에서 만든 트리를 runtime 계층으로 내보내지 않는다. composited screenshot crop은 per-node texture나 graph가 아니다.

## 다음 실행 단위와 합격 조건

**한 일반 Simulator runtime, 한 소유 fixture, 한 hosting root**에서 시작한다. Duo는 별도 runtime qualification 비용이 있으므로 이 실험에 합치지 않는다. fixture는 표준 SwiftUI startup, 사용자 정의 root, VStack/HStack, 고유 문자열 Text 두 개, Rectangle/Circle, padding/overlay/opacity, 조건부 branch, 중첩 hosting과 작은 UIKit 대표 뷰를 포함한다. effect는 별도 variant로 둔다. fixture의 알려진 구조·색상·위치는 oracle이며 production 그래프를 만드는 입력이 아니다.

1. **정적 호출 adapter 확정.** 알려진 `Content` 타입의 fixture 내부에서 SDK에 선언된 API를 직접 호출하는 최소 검증을 먼저 준비한다. 그 결과는 oracle이다. 외부 제품 경로에는 같은 hosting 객체에서 serialized data를 얻는 고정 adapter가 추가로 필요하다. ObjC method가 실제 존재하면 signature/반환형을 확인한 고정 호출을 후보로 삼고, 없으면 Swift generic 호출/동적 타입 해석을 별도 좁은 단위로 입증한다. `unsafeBitCast`, 임의 KVC·selector 입력, 임의 Swift ABI layout 추정은 제품 계약으로 채택하지 않는다. 앱 계측이 필요한 oracle만 성공하면 일반 앱 지원은 아직 blocker다.
2. **동일 정적 장면 A/B.** A=현행 snapshotImage, B=같은 hosting root의 `drawHierarchy(in:afterScreenUpdates:false)`를 bounded bitmap으로 캡처한다. [Apple API](https://developer.apple.com/documentation/uikit/uiview/drawhierarchy(in:afterscreenupdates:))는 전체 subtree를 그리며 Bool은 완전성을 뜻한다. main-thread/read operation도 framework 실행·allocation을 유발한다. guest hidden/alpha 변경, reparent, renderer 설정 변경, run-loop pumping은 하지 않는다. 호출 성공 Bool, PNG, 원본 graph JSON, 요청/응답 hash, target identity, 독립 화면 reference와 정리 receipt를 남긴다. nil/false/timeout은 실패로 기록한다.
3. **표현 선택.** B가 Text·Shape를 포함하고 graph도 실제로 반환되면 `hostingSubtreeComposite` 한 장과 실제 선언형 트리를 함께 통합할 수 있다. 이 경우 graph 선택은 속성과 검증된 geometry를 보여 주며, 자식마다 같은 이미지를 중복 배치하지 않는다. 이는 개별 SwiftUI 노드의 독립 3D 텍스처를 확보한 결과는 아니다. 그 수준이 필요하거나 B가 실패하면 encoded-layer/rendered-view 후보의 정확한 serializer와 decoder를 한 variant씩 검증한다. [UIVisualEffectView 문서](https://developer.apple.com/documentation/uikit/uivisualeffectview)는 effect에 window/screen 전체 snapshot이 필요할 수 있다고 설명한다. effect composite는 표시 단위를 그대로 명시한다.
4. **제품 통합과 검증.** 외부 adapter로 얻은 graph와 충실한 hierarchy rendering 두 항목 모두 증거가 확보된 후 아래 소유 경로로 통합한다. 한 항목이 실패하면 raw 결과와 정확한 blocker를 반환하고 그 adapter/decoder 단위만 다음 실험으로 넘긴다. ‘미지원’ 문구만 추가해 요청을 완료하지 않는다. screenshot-only나 계측 fixture-only는 최종 대안으로 합격하지 않는다.

**관측 가능한 합격:** external capture에서 custom root·stack·Text·Shape와 modifier의 실제 관계를 확인한다. 알려진 문자열·도형이 hierarchy presentation에 보이며 baseline A의 누락과 B의 복구를 픽셀 및 사람의 프레임 검토로 대조한다. 문자·도형별 고정 ROI, 색/alpha, scale/orientation을 기록하고 antialiasing 허용 오차를 측정 후 고정한다. 조건부 branch 변경 뒤 새 캡처에는 새 노드가 나타나고 이전 ID·선택·권한이 살아나지 않아야 한다. 실제 반환되지 않은 source/constraints/property는 unavailable이어야 한다. 전체 Xcode parity는 합격 조건이 아니다.

실험 시작 전 [native check safety](../native-check-safety.md)의 dispatch/상속 entry 거절을 headless로 증명한다. 이후에만 부모 watchdog·기한·정확한 instance budget·단일 runtime owner·입력 guard로 직렬 실행한다. duplicate window/relaunch, timeout, target 변경, detach/recovery 불명확이면 중단·정리한다. 이 문서 작성 중에는 해당 실행을 하지 않았다.

## 구현 소유권과 검증 순서

| 순서·소유 파일 | 변경과 필요한 증거 |
| --- | --- |
| 1. `view-capture/operation.inc`, `capture.py`, 필요한 고정 Swift bridge | runtime graph와 hosting image를 같은 대상/작업에 연결. strict byte/depth/node/time limits, cleanup·취소·target 교체 검증. 기존 raw 문자열 dump를 제품 schema로 가정하지 않는다. |
| 2. `mac-cu-src/SimulatorViewHierarchy.swift` | 별도 graph/representation normalizer. 중복·순환·다른 capture/hosting ID·알 수 없는 encoding을 거절. 기존 UIKit token join과 budgets 유지. |
| 3. `SimulatorInspectorModel.swift` | UIKit/SwiftUI selection kind를 분리. optional typed metadata, capture-local identity와 stale 처리. model tests에 missing property, 재캡처 ID 변경, late graph response, token 혼용 거절 추가. |
| 4. `SimulatorInspectorRenderer.swift`, `SimulatorInspectorWindow.swift` | subtree composite는 hosting plane 한 곳에 표시. 실제 graph 트리와 선택 속성을 표시. geometry 없는 노드는 tree-only로 표시. GPU tests는 UV·투명 합성·duplicate descendant content 방지·picking과 representation 범위를 검증. |
| 5. `SimulatorInspectorIntegration.swift`, 기존 inspector/live 검사 | 기존 owner/epoch, context/generation, serial queue, release, pending 선택 변경 취소를 보존. UI tests는 graph 선택이 capture·edit·HID를 호출하지 않는지, 실패/부분 결과·최소 창 크기·닫힘/재열기를 확인. live에서는 target 독립 oracle와 화면을 대조하고 기존 UIKit hidden/alpha 적용·복원 회귀를 확인. |

UI 표시 옵션은 guest hidden/alpha를 변경하지 않는다. graph 선택이 UIKit editToken으로 변환되면 안 된다. 기존 모델/GPU 검사는 [main.swift](../../mac-computer-use/tests/simulator-inspector-3d/main.swift), [metal.swift](../../mac-computer-use/tests/simulator-inspector-3d/metal.swift), UI 검사는 [window.swift](../../mac-computer-use/tests/simulator-inspector-3d/window.swift)를 재사용한다. window fixture의 과거 label 기대가 현재 UI와 일치하는지도 구현 시 확인한다. 구현 후 distribution/native 검증과 전역 앱 설치는 부모의 별도 완료 단계다.

## 이번 감사의 증거 범위

현재 owning 소스와 필요한 schema/test 본문, 현재 전달/제품 문서, 설치 SDK 선언·두 DebugHierarchy framework의 제한된 문자열을 읽었다. `swift-intelligence`의 `swift_symbols`로 모델 파일 선언을 확인했다. cross-file index 완전성이나 빌드 성공을 주장하지 않는다. Apple 문서/WWDC와 고정 commit 공개 실험 코드를 확인했다. SDK private swiftinterface 후보 파일은 없었으며, 실제 존재하는 공개 swiftinterface를 사용했다.

새 문서의 whitespace와 로컬 링크 형태만 검사한다. production/test/manifest/skill 편집, build, GUI, Simulator 명령, debugger attach, runtime mutation, 설치·게시를 수행하지 않았다. 소스 SHA-256 manifest, 정적 발췌, URL 및 최종 문서 hash는 별도 비공개 handoff에 둔다. 현재 API 호출 가능성과 실측 화질은 **다음 실행 실험의 미해결 항목**이다.
