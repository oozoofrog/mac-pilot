# LCD 접근성·3D 검사 구현 설계

## 제품 동작

현재 LCD의 **검사**에서 접근성 요소를 읽고 선택한다. 요소의 속성·부모/자식·지원 동작을 확인하고, 명시적 실행으로 접근성 동작이나 지원되는 값을 변경한다. **3D 뷰 검사**는 같은 기기·화면에 연결된 별도 네이티브 창을 연다. 이 창에서 사용자가 캡처를 시작하고, 트리와 3D 장면에서 같은 뷰를 선택해 속성을 확인·변경·복원한다.

창 열기와 요소 선택은 debugger attach 또는 guest 입력을 실행하지 않는다. 캡처와 변경은 별도 명령이다. 캡처는 앱을 일시 정지할 수 있다는 조건을 진입 지점에 표시한다. 변경은 실행 중 앱 메모리에 적용되며 소스 파일을 저장하지 않는다.

## 확정한 구조

- 기존 AppKit LCD·toolbar·IOSurface·HID와 창별 기기 소유권을 유지한다. 검사 기능 때문에 host UI를 전면 SwiftUI로 전환하지 않는다.
- 접근성 트리와 UIKit 뷰 트리는 별도 자료형으로 유지한다. 같은 label/frame으로 두 트리를 자동 결합하지 않는다.
- 별도 3D 창은 트리/검색, 장면, 속성/변경 결과의 세 영역으로 구성한다. 좁은 창에서 속성 영역은 스크롤하며 실행·복원 상태를 유지한다.
- 렌더러는 `MTKView`의 명시적 redraw와 단순 textured quad pipeline을 사용한다. camera와 quad projection은 별도 순수 수학 모델로 둔다. SceneKit에 새 의존성을 추가하지 않는다. Metal 장치를 만들 수 없으면 오류와 2D 트리는 유지하고 3D가 실행됐다고 표시하지 않는다.
- 실제 수집한 네 모서리와 확인된 texture 의미를 사용한다. 펼침 간격은 표시용 깊이다. 물리적인 layer transform Z와 같은 값으로 저장하지 않는다. texture가 subtree이면 자식을 다시 합성해 독립 texture처럼 보이지 않도록 표시 정책을 분리한다.

Apple은 [MTKView](https://developer.apple.com/documentation/metalkit/mtkview)가 Metal drawable과 필요 시 depth/stencil을 관리한다고 설명한다. 기존 native build에 맞춰 렌더링 코드는 Swift 안의 고정 Metal shader source 또는 패키지에 포함된 정적 자원으로 제한한다. 외부 shader·expression 입력은 받지 않는다. 현재 설치된 SDK로 컴파일하고 새 코드가 최소 OS를 암묵적으로 올리지 않게 availability를 검사한다. 기존 저장소에는 명시된 deployment target이 없으므로 빌드에서 확인한 OS 범위만 보고한다.

## 데이터와 수명

기존 `SimulatorViewCaptureTarget`의 PID/start/path/device 계약을 재사용한다. display·host presentation revision·operation generation은 host inspection context에 보관한다. 불완전한 대상 identity는 변경에 사용할 수 없다.

공통 capture에는 schema version, capture ID, read interval, 대상 수명, 기기/화면, cleanup/recovery, capability별 지원 상태를 담는다. UI는 검증한 immutable snapshot만 받는다. 백엔드의 원시 dictionary를 UI에서 반복 해석하지 않는다.

3D node에는 capture-scoped ID, parent ID, sibling order, class, 실제 속성, 네 모서리·coordinate space·window/screen, 선택적 asset descriptor를 담는다. 주소는 현재 read-only capture 안의 join 근거다. 편집 권한은 별도 opaque token이다. asset descriptor는 node ID, 형식, 픽셀 크기, scale, solo/subtree/layer 의미, 수집 구간과 비지원 이유를 구분한다.

### 구현 간 전달 형식

기존 `SimulatorViewCaptureResult.content["snapshot"]` 형식과 nested `roots`를 유지한다. 백엔드는 다음 필드를 추가하고 UI가 한 번 검증해 typed model로 변환한다.

```text
snapshot:
  captureID, capturedAt, processLifetime, roots, screenGeometry
  capabilities: { textures: Bool, editableProperties: ["hidden" | "alpha"], reasons: [String] }
  editing: null | { inspectionID, ownerID, targetEpoch, expiresAt, registryState }
  assets: { assetID: { format: "png", encoding: "base64", data,
             pixelWidth, pixelHeight, pointWidth, pointHeight,
             sourceProperty: "snapshotImage", descendantContent: "selfObserved" | "unknown",
             captureID, nodeID } }
node:
  existing id, className, parentID, siblingIndex, properties, geometry,
  frame, hidden, alpha, accessibilityIdentifier, accessibilityLabel, children
  assetID: String | null
  textureUnavailableReason: String | null
  editToken: String | null
  editableProperties: ["hidden" | "alpha"]
```

불명확하거나 없는 추가 필드는 미지원 상태다. 읽기 전용 주소 ID와 편집 token을 서로 바꾸어 쓰지 않는다. `editing`은 유효한 registry와 cleanup 완료가 확인된 경우만 제공한다. mutation receipt는 `operationID`, `status`, `mutationOutcome`, `before`, `requested`, `observed`, `undoToken`, `needsRefresh`, `cleanup`을 별도로 전달한다. UI는 callback으로 capture/cancel/edit/revert/release를 요청하며 private API를 호출하지 않는다.

fixture 실험에서 root PNG는 1206×2622였다. 1024×1024는 실험의 보수적 host 한도였으며 제품 목표 해상도를 충족하지 못한다. 제품 decoder는 최대 4096×4096, 이미지당 encoded 4 MiB, aggregate encoded 16 MiB, aggregate decoded RGBA 128 MiB, 최대 64개 이미지로 시작하고 실제 할당·회귀 검사로 검증한다. PNG signature/IHDR와 곱셈 overflow·aggregate 한도를 allocation 전에 검사한다. 크기를 줄여 원본 수집 성공으로 보고하지 않는다. 같은 픽셀을 가진 서로 다른 node는 정상일 수 있으므로 이미지 hash 중복을 오류로 만들지 않는다. asset ID 중복·알 수 없는 node join은 거부한다.

host decoder 한도는 target-side 이미지 생성 메모리 한도가 아니다. 일반 앱 texture 요청 전에 bounded traversal과 해상도/노드 예산을 검사하고, 검증된 object-scoped 요청이 가능하면 그 방식으로 제한한다. 안전한 제한을 구성할 수 없으면 metadata와 명시적 texture 비지원 결과를 제공한다. node ID 범위 필드는 실제 serializer 근거 없이 추정하지 않는다.

선택·검색·camera 변경은 capture 권한을 연장하지 않는다. 새 캡처, 대상 변경, motion/reconnect, 실패·취소·닫힘은 기존 operation generation을 무효화한다. 오래된 응답을 현재 UI에 게시하지 않는다. 이전 snapshot은 시각적으로 오래된 자료임을 표시한 탐색 용도로만 남길 수 있다.

## 접근성 백엔드

[ABI 실측](simulator-ax-abi-probe.md)을 호출 경계의 기준으로 사용한다. 메서드 유무, 실제 argument/return type, 요소의 capability를 각각 검사한다. Objective-C 예외는 Objective-C 경계에서 변환하고 Swift의 `do/catch`로 잡힌다고 가정하지 않는다. 기존 translator·delegate·token 등록 및 lazy IPC는 단일 executor에 직렬화한다. callback queue는 기다리는 executor와 분리한다.

새 snapshot은 parent/children, typed value, help/subrole, enabled/protected, action 목록, 필드별 available/unsupported/failed/redacted와 truncation을 보존한다. 미지원 값과 빈 문자열을 합치지 않는다. 실제 API가 제공하지 않는 traits나 display identity를 만들지 않는다.

기본 동작은 press와 실측한 increment/decrement다. custom action은 snapshot에 연결된 opaque handle로만 실행하며 같은 이름을 합치지 않는다. 값 변경은 `AXValue`가 settable이고 실제 guest 모델 변경이 확인된 타입만 허용한다. 상속된 `setAccessibilityValue:`가 있다는 이유로 편집을 켜지 않는다. void 반환은 전달 결과이며 성공한 값 변경의 증거가 아니다.

point picking의 실제 backend 후보는 `AXPTranslator.objectAtPoint:displayId:bridgeDelegateToken:`다. display mapping을 먼저 확인한다. context를 모르는 상태에서 `accessibilityHitTest:withDisplayId:contextId:`에 임의의 0을 넣지 않는다. 현재 사각형 후보 선택은 별도 방식으로 유지하고 backend hit test로 표시하지 않는다. 여러 후보를 자동 실행하지 않는다.

한 번의 전체 읽기에 absolute monotonic deadline·node/depth/cycle 한도를 적용한다. timeout 후 도착한 callback은 lock으로 보호한 단일 terminal state를 바꾸지 않는다. unknown protected 상태에서는 민감 값 노출·쓰기를 허용하지 않는다. 새 동작은 fixture의 독립 counter/model/readback과 입력 누출 검증을 통과한 뒤 capability를 켠다.

## UIKit 편집 백엔드

[객체 수명 계약](simulator-view-edit-contract-review.md)의 bounded zeroing weak registry를 첫 구현 후보로 사용한다. 하나의 안정된 class anchor/key에 capture 상태를 보관한다. 저장된 주소를 역참조하지 않는다. fresh traversal과 weak 조회로 같은 live 객체·parent·window인지 확인한다. 아직 CLI 및 UIKit/LLDB 실험이 완료되지 않았으므로 현재 편집 capability는 비활성 상태다.

최초 편집 속성은 `hidden: Bool`과 `alpha: finite 0...1`이다. 색상·frame·constraint·임의 selector/KVC는 이 계약의 기본 변경 경로가 아니다. 사용자가 입력한 문자열을 code로 조합하지 않는다. expected old value와 현재 typed getter가 다르면 setter를 호출하지 않는다. 한 operation은 한 속성만 변경한다.

호출 전, setter 진입, readback, detach/recovery를 각각 기록한다. 중복 operation은 재실행하지 않는다. timeout·exception·lost response는 실제 진입 근거에 따라 uncertain 상태를 유지한다. 현재 값이 요청값과 같다는 이유만으로 과거 성공을 단정하지 않는다.

복원은 저장된 이전 값을 사용하는 새 guarded operation이다. 같은 객체와 현재 값이 마지막 적용값에 일치할 때만 허용한다. 앱의 이후 변경을 덮어쓰지 않는다. 대상 종료나 debugger 실패 뒤의 rollback을 보장하지 않는다. 읽기·편집 모두 검증된 main-thread 진입을 사용하되, main-thread 확인만으로 UIKit의 재진입 안전성을 주장하지 않는다.

## UI 상태와 조작

1. 대상과 캡처 시점을 먼저 표시한다. 캡처 진행 중 취소를 제공한다. 실패한 새 캡처를 이전 자료의 성공으로 표시하지 않는다.
2. 읽기 완료 후 선택은 비어 있다. 트리 행이나 실제 장면의 뷰를 선택하면 같은 capture의 속성을 보여 준다. 검색 결과 하나만 남아도 자동 실행하지 않는다.
3. 회전·확대·깊이 조절은 host 장면에만 적용한다. 마우스 조작 외에 이름이 있는 camera 복원·회전·확대 controls를 둔다. 3D 입력을 guest HID로 전달하지 않는다.
4. 속성 초안과 현재 관측값을 분리한다. **적용**은 pending→readback/실패/불확실 결과로 이어진다. **복원**은 유효한 receipt가 있을 때만 활성화한다.
5. stale 거절은 초안을 보존하지만 재조회·재선택 없이 다른 대상에 적용하지 않는다. 실패·미지원·빈 자료·필터 결과 없음은 별도 상태다.
6. Tab/방향키로 목록과 controls를 탐색한다. Return은 선택/상세 경로이며 guest 동작을 암묵적으로 실행하지 않는다. Escape는 pick·편집 dialog 취소를 우선한다. 창 닫힘 뒤 focus를 호출한 host control로 돌린다.
7. 선택은 색뿐 아니라 행 상태·이름·outline로 표시한다. 접근성 이름과 결과 안내를 유지한다. Reduce Motion이면 camera/depth 전환을 애니메이션하지 않는다.

## 구현 소유 경로

- AX 담당: `SimulatorAccessibility.swift`, 새 ObjC adapter 및 AX 전용 테스트. `Simulator.swift`·Toolbox는 수정하지 않는다.
- capture/edit 담당: `SimulatorViews.swift`, `SimulatorViewHierarchy.swift`, `view-capture/`, 관련 fixture·테스트. capture와 mutation의 안전 supervisor를 재사용한다.
- UI 담당: 새 `SimulatorInspectorModel.swift`, `SimulatorInspectorWindow.swift`, `SimulatorInspectorRenderer.swift`와 독립 모델 테스트. transport·private API는 호출하지 않고 callback으로 요청한다.
- 리드 통합: `Simulator.swift`, `SimulatorToolbox.swift`, `SimulatorWindow.swift`, setup/check build 연결, 공통 문서·버전·최종 전달.
- runtime 검증 담당은 한 번에 한 명이다. 단계별 freeze와 release를 기록한다. 준비 manifest가 사용 중일 때 다른 담당자는 그 입력을 수정하지 않는다.

이미지 fixture 실험은 cleanup·복구·claim 해제와 빈 process group을 확인하고 종료했다. 해당 단계의 canonical Swift 동결을 해제한다. 다음 세 구현은 headless로 병렬 진행하며 모든 담당자가 완료한 뒤 전체 소스를 동결해 단일 runtime 검증을 시작한다.

## 완료 확인

소스 검사와 빌드 뒤, 실제 LCD AX 선택·명시 동작·지원 값 변경, 실제 capture의 textured 3D 선택·camera·깊이, hidden/alpha 변경·readback·복원을 검증한다. 일반 debug 앱 수집은 SDK 없는 별도 대상에서 확인한다. 캡처 geometry와 LCD pixel/host rotation 정합은 별도로 측정한다. fixture 한 건의 성공을 모든 OS·앱·SwiftUI 선언 graph·물리 기기 지원으로 일반화하지 않는다.

필수 distribution/native regression과 보호된 runtime 검증이 끝나면 canonical build로 전역 앱을 교체한다. 기존 앱 백업·서명 identity·권한·Keychain·사용자 데이터 보존, 재시작, 실행 버전·실제 UI readback을 확인한다. Git 게시와 marketplace 배포는 포함하지 않는다.
