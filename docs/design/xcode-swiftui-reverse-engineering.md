# Xcode SwiftUI View Debugger 역공학

2026-11-09 · Xcode 27.2 / 27B48 · arm64 정적 조사 · iOS Simulator 27.2 / 24B114

## 결론과 적용 범위

설치된 Apple 바이너리에서 **`dbgSubviewHierarchy` → `makeViewDebugData` → host JSON subhierarchy 변환** 경로를 확인했다. generic `_UIHostingView<Content>`의 Content 타입을 외부에서 복원하는 방식 외에, UIView provider의 Objective-C 진입점을 검증할 근거가 생겼다. 다만 이 조사에서는 호출하지 않았다. `makeViewDebugData` 내부에서 `_viewDebugData`와 `_ViewDebug.serializedData`로 이어지는 현재 runtime의 직접 호출은 아직 복구하지 못했다.

현재 collector의 `visibility: 1`은 그래프 속성의 visibility `8`과 교집합이 없다. 단순히 속성 이름만 추가하면 반환되지 않을 수 있다. 또한 Apple의 draw-hierarchy 속성 helper는 alpha를 임시 변경한다. 같은 이름의 public draw API를 직접 호출하는 실험과 안전 특성이 다르다.

이 문서는 [현재 확장 설계](xcode-view-hierarchy-extension.md)의 후속 입력이다. [1.31.0 전달 기록](simulator-inspection-delivery.md)의 UIKit 캡처·3D·편집·복원 근거를 유지한다. 과거 [텍스처 계약 조사](xcode-view-texture-contract.md)의 미복구 상수 일부를 이번에 복구했다. 구현, live 캡처, 전체 Xcode parity 또는 사용자 요청 전체의 완료를 의미하지 않는다.

## 설치본 식별과 증거 규칙

아래 경로는 Xcode `Contents/` 또는 runtime root 기준이다. 주소는 **각 Mach-O arm64 slice의 unslid VM 주소**다. SHA-256은 universal 파일 전체의 값이다. raw 출력과 절대 설치 경로는 비공개 handoff에만 둔다. 표의 artifact 이름은 그 handoff directory 기준이다.

| ID · 소유 경로 | 버전 · arm64 UUID | SHA-256 |
| --- | --- | --- |
| K · `SharedFrameworks/DebugHierarchyKit.framework` | 1.0 / 2 · `BD40A994-CE92-3712-AADD-7E933A3D7273` | `16a1d475f183ed86ea152acc8f226d422cc0d10473e03a5d9de701a80a890bc6` |
| F · `SharedFrameworks/DebugHierarchyFoundation.framework` | 1.0 / 2 · `0267FA46-B667-3A1C-A1A8-A1CA8BF48F8D` | `9b3fa4e438950d4d54ac083fd1dc36212097373ce44bb5f9d3c232d4b08c8872` |
| DF · `Frameworks/DebuggerFoundation.framework` | 27.2 / 25436 · `CC98409A-589D-3B7F-BD41-3C37FB98236F` | `29d944b6166d8eabb976bf829c0e4aa7b4306af828a5341b21b58a952a506b2d` |
| I · `Frameworks/IDEiOSDebugger.framework` | 27.2 / 25403 · `3B1657E8-A3AA-35E3-8307-102FF00A1922` | `9d73f39c692256182df084d01c6f21249d74d7cca1b1f5153d8b86939ebca71d` |
| U · `PlugIns/DebuggerUI.framework` | 27.2 / 25436 · `C4604869-10E1-323A-9033-AC5C75D4A1D2` | `f1620e327bab0564401ba3d7f31807f92ae42a8eee53df5e317f0fd83ea30cc4` |
| DK · `PlugIns/DebuggerKit.framework` | 1.0 / 1 · `EEC891AD-6FDC-3044-81A8-03E0F6CC4CB4` | `725671b525004ef172fe0fb524fdfb2d790a5ea0cfe3c9d5ec1a25757e69dde7` |
| DV · `SharedFrameworks/DVTKit.framework` | 27.2 / 25451 · `A31DB986-4F3A-3571-8323-876B5B673649` | `5e3412992ccd40f49847e573ba02ee5f96dcd5a576fee6f0f0a22eccc1789e1b` |
| S · runtime `usr/lib/libViewDebuggerSupport.dylib` | DebugHierarchyFrameworks-74 · `8C744EE1-9422-3225-9CEF-1963882D4107` | `c0a05281fbb2a6db75800123707446cbc5d31c837ffd2fd158aa45b1b5804202` |

SDK `.tbd`와 `.swiftinterface`는 실행 이미지가 아니다. 이전 감사의 SwiftUI/SwiftUICore SDK 선언은 재사용하되 manifest의 원본 hash와 이번 읽기 범위를 구분한다. 실제 S는 CoreSimulator의 설치 이미지 목록에서 24B114 runtime root를 찾아 읽었다. 별도 24B91016s runtime의 존재는 확인했지만 분석 대상으로 섞지 않았다. runtime의 SwiftUI/SwiftUICore 독립 실행 파일은 없고 dyld shared cache 두 파일과 map이 있다. cache를 추출하거나 로드하지 않았다. 대신 cache mapping에서 Mach-O header의 LC_UUID와 map의 __TEXT 범위 hash만 읽었다. SwiftUI UUID는 `BCEF6306-9F1B-3CC2-9B42-233178DB4456`, __TEXT SHA-256은 `db6763a26507c54f5eb50e5a6d3ae58b938cc13bf3814e8fe246f9063324dfcf`다. SwiftUICore UUID는 `48F6182E-C74E-36F6-B833-8F6BED405A34`, __TEXT SHA-256은 `b24e5f6ad9c60e5d69a917a47c44c1123017594ccdc57422950e9ee22fc2790a`다. 이는 재구성한 실행 파일 전체 hash가 아니다. `runtime-image-header-manifest.json`에 주소와 hash 범위를 기록했다. 내부 호출은 아직 복구하지 않았다.

## 호출·데이터 흐름

```text
Xcode host
  DF: _canCaptureSwiftUIViewHierarchy
      user-default gate AND destination platform capability
  I: initialRequestPropertyActions
      UIView action + [dbgSubviewHierarchy] when gate passes
  F: DebugHierarchyRequest / PropertyAction serialize -> target transport
      [현재 capture.py도 DBGTargetHub transport를 사용]
Target S
  UIView fallback property provider
      dbgSubviewHierarchy (Data, public.data, visibility 8)
      respondsToSelector(makeViewDebugData) -> object.makeViewDebugData()
      -> NSData 후보 [현재 SwiftUI 내부 serializer 호출은 미복구]
Host DF
  DBGSubhierarchySnapshotDataTransformer
      property.dataValue -> NSJSONSerialization
      -> properties / children -> com.apple.subhierarchy.view groups
      -> capture-local unique node IDs
      -> displayList.items["0"].identity.value <-> CALayer.dbg_ListID

Image lane
  K RequestFactory -> snapshotImage / draw-hierarchy / encodedPresentationLayer
  S UIView -> UIImage provider -> encoded image value -> K DBGImage decoder
  S CALayer -> CAEncodeLayerTree -> opaque bytes
  DF layer unarchiver -> CALayer tree
  U layer snapshot -> DK DBGLayerExporterPool
  DV DVTLayerImageExporter -> CARenderer + Metal texture -> CGImage
```

위 지도는 복구한 메서드별 흐름을 연결한 것이다. 모든 화살표를 실제 단일 Xcode 세션에서 관찰한 것은 아니다. 특히 transport 이후 graph property를 transformer에 배분하는 직접 call site와 SwiftUI 내부 serializer는 미복구다.

| 근거 | 실제 관측 · 의미 | 비공개 artifact / 주소 |
| --- | --- | --- |
| host graph 요청 | I의 `_canCaptureSwiftUIViewHierarchy` 결과가 참이면 `addPropertyNames:`를 호출한다. constant NSArray는 `dbgSubviewHierarchy` 한 항목이다. U의 Mac describer에도 같은 분기가 있다. | `iosdebugger-annotated.txt` `0x90a8–0x90c0`, array `0x11b08`; `ui-graph-caller.txt` `0x9ce8c–0x9cea4`; `resolved-constants.json` |
| host gate | DF는 `captureSwiftUIViewHierarchyEnabled`와 launchSession → runDestination → targetDevice → platform → extendedInfo의 capability를 확인한다. enable getter는 `DBGCaptureSwiftUIViewHierarchyEnabled` defaults를 읽는다. 현재 설정값이나 기본값은 읽지 않았다. | `debuggerfoundation-annotated.txt` `0x38ac`, `0x2e68c` |
| 실제 guest provider | S는 graph property를 Data / `public.data`, visibility `8`로 기술한다. 이름 비교 뒤 selector 응답을 확인하고 `makeViewDebugData`를 호출한다. 응답하지 않으면 nil 경로다. | `support-ios-annotated.txt` `0xc000–0xc064`, `0xc71c–0xc758`; `ios-graph-caller.txt` |
| visibility 의미 | F `_isTargetingProperty:`는 property와 action visibility를 `tst`하고 교집합이 없으면 거절한다. 이름 목록은 contains XOR exclusive로 판정한다. false는 목록 포함을 선택한다. | `foundation-annotated.txt` `0xc41c–0xc430`, `0xc48c–0xc4d4` |
| host graph decode | DF는 `dataValue`를 JSON으로 읽고 property의 `snapshotNode`에 연결한다. root를 순회하며 unique node를 만들고 hosting 노드의 additional group과 snapshot root group에 연결한다. | `debuggerfoundation-transformers.txt` `0x28ce8`, `0x28e20`, `0x28fa4` |
| child/property schema | root dictionary의 `properties`, `children`을 읽는다. property에서 정수 `id`, optional `attribute`를 읽고 타입 해석과 값 생성을 수행한다. child group은 `com.apple.subhierarchy.view`다. 일부 타입의 child merge 경로가 있으므로 host 표시 트리가 원본 JSON과 동일하다고 단정하지 않는다. | 같은 artifact `0x290a4–0x29974`, `_typeFromPropertyDicts:` `0x29bf8` |
| graph/layer 연결 | DF는 `displayList` property의 `items` → 문자열 키 `0` → `identity` → `value`를 읽고 CALayer의 `dbg_ListID`로 재귀 검색한다. 미완료 연결은 pending map에 둔다. | 같은 artifact `0x2bf90–0x2c390` |

`properties` 항목의 모든 `id` 매핑, `attribute`의 의미, modifier별 값, environment 내용과 source file/line의 공급 경로는 완전하게 복구하지 않았다. SDK enum의 type/value/transform/position/size/environment/phase/layoutComputer/displayList 이름만으로 반환 필드를 보장하지 않는다. graph가 있다는 이유로 원본 소스 위치나 Text의 실제 문자열이 있다고 가정하지 않는다.

## 이미지 요청과 decoder

K의 constant array를 Mach-O segment의 VM→file offset으로 찾아 NSArray storage→CFString을 따라 읽었다. chained pointer의 하위 target bits를 해석한 한정 정적 스크립트를 사용했다. isa/import binding은 해석하지 않았으며 이 스크립트를 일반 Mach-O decoder라고 보지 않는다. 각 한 항목 array와 해당 disassembly의 `setPropertyNames:exlusive:` 호출을 대조했다.

| K factory · 범위 | 복구한 property array | action 구성 |
| --- | --- | --- |
| `_requestForEncodedLayersWithSnapshot:` `0xa9a8–0xac17` | `0x26ad8` → `encodedPresentationLayer` | CALayer group IDs, property action, discovery 2 |
| `_requestForRenderedEffectViewsWithSnapshot:` `0xac18–0xaf13` | `0x26af0` → `snapshotImageRenderedUsingDrawHierarchyInRect` | property + run-loop action, discovery 2 |
| `_requestForRenderedMultiLayerViewsWithSnapshot:` `0xaf14–0xb1df` | `0x26b08` → `snapshotImageRenderedUsingDrawHierarchyInRect` | multi-layer predicate, property + run-loop action, discovery 2 |
| `_requestForRenderedViewsWithSnapshot:` `0xb1e0–0xb707` | `0x26b20` → `snapshotImage` | view/type predicates, property action, discovery 2 |

두 exclusive 인수는 각 factory에서 0이다. F의 KVC archive 목록에는 `objectIdentifiers`, `objectIdentifiersAreExclusive`, `propertyNames`, `propertyNamesAreExclusive`, `types`, `typesAreExclusive`, `exactTypes`, `exactTypesAreExclusive`, `visibility`, `options`, `optionsComparisonStyle`가 있다(`0xbb38`). request dictionary의 identifier/name/initiator/priority/discovery/compression/payload/crawler/actions serializer도 확인했다(`0x4cd8`). 이 결과는 전체 factory wire payload의 실행 덤프가 아니다. run-loop 옵션과 모든 기본값을 재현했다고 주장하지 않는다.

- **UIImage 경로:** S에서 `snapshotImage`는 `__dbg_snapshotImage`로, draw-hierarchy 속성은 별도 helper로 분기한다(`0xc3cc–0xc410`). 이미지 속성 기술에는 `UIImage`, image logical type, `public.png`가 있다. K `DBGImage(JSONSerialization)`는 PNG/TIFF 데이터 분기와 `image` dictionary 분기를 구분한다. dictionary 분기는 JSON-compatible value decode 후 `imageData`, `metadata`를 읽고 PNG type으로 만든다(`0x12a1c–0x12c9c`). raw wire의 모든 값이 바로 PNG bytes라는 뜻은 아니다.
- **opaque layer 경로:** S의 CALayer property 분기에서 `CAEncodeLayerTree` 호출을 확인했다(`0x5f94–0x5fc4`). DF `_decodedLayerForLayerProperty:`는 custom data와 view describer의 `unarchiveLayerForView:fromData:`를 사용한다(`0x18e18`). `DBGLayerTreeUnarchiver`는 keyed archive를 풀고 `rootLayer`, `geometryFlipped`, `CATintedImage` 치환 및 class fallback을 다룬다(`0x1dd28`). 이 경로는 PNG decoder로 대체할 수 없다.
- **host rendering:** U의 CALayer snapshot이 DK `imageForLayer:bounds:options:`를 호출한다(`0x2ed8`). DK exporter pool은 DV `DVTLayerImageExporter`를 만들고 options/layer/bounds를 설정한 뒤 `copyImageForTime:`을 호출한다(`0x18d8`, `0x1c24–0x1c84`). DV는 `CARenderer.rendererWithMTLTexture:options:`와 beginFrame/render/endFrame을 사용한다(`0x1293c`, `0x12bcc–0x12bdc`). Xcode는 private debugger archive 지원과 CA layer rendering을 결합한다. 모든 렌더링 호출 자체가 비공개라는 뜻은 아니다.

**안전상 중요한 관측:** S의 draw-hierarchy helper는 순회 중 원래 alpha를 저장하고 `setAlpha:`를 호출한 다음, 다른 view bounds를 기준으로 `drawViewHierarchyInRect:afterScreenUpdates:YES`를 호출하고 alpha를 복원한다(`0x12ecc–0x12f70`, `0x130a8`). 그러므로 이 속성 요청을 무변경 수집으로 분류하면 안 된다. helper의 모든 예외·중단 경로에서 복원이 보장되는지는 미검증이다. 별도 worker의 hosting composite 실험에 이 helper를 자동 도입하지 않는다.

Text·Shape는 graph의 실제 type/value와 rendering lane 양쪽에서 확인해야 한다. display-list와 layer 연결은 Xcode의 대응 방식에 대한 구체적 근거다. encoded layer에 모든 SwiftUI 픽셀이 있거나 graph의 모든 노드가 독립 이미지/geometry를 가진다는 증거는 아니다. 효과·마스크·Metal/video·애니메이션·색 공간·scale·방향은 각각 충실도 검증이 필요하다.

## 외부 근거와 남은 간격

[k_kohey의 직접 역공학 기록](https://zenn.dev/k_koheyi/articles/2514551c3a2f31)은 **iOS 26.2 / Xcode 26.2.0**에서 `makeViewDebugData` → `ViewGraph.viewDebugData` → `_ViewDebug.serializedData` 호출과 graph 기록을 위한 시작 시 환경 변수 `SWIFTUI_VIEW_DEBUG=287`을 보고한다. 빈 `[]`가 main-thread 호출만으로 해결되지 않았다는 관측도 있다. 이는 현재 설치본 내부 호출이나 필수 launch 설정의 증명이 아니다. 이 조사에서는 환경 변수를 쓰거나 target을 재시작하지 않았다. 해당 저자의 코드를 제품에 복사하지 않았다.

현재 SDK의 typed API 후보와 [고정 commit의 SwiftUIViewDebug 작성자 코드](https://github.com/OpenSwiftUIProject/SwiftUIViewDebug/blob/a9067fe57dc333845a22edf4e88b443d81f478a2/Sources/SwiftUIViewDebug/ViewDebug.swift)는 별도 경로다. 그 코드는 알려진 generic Content를 사용한다. 이번에 복구한 Objective-C provider와 같은 bytes를 만든다고 아직 증명하지 않았다. 현재 Apple SwiftUI dyld-cache 내부의 두 메서드 호출·graph 기록 flag·serializer를 정적으로 복구하는 작업이 남아 있다. 현재 host의 전체 graph property dispatch call site도 남아 있다.

## 다음 실험과 제품 계약

가장 작은 추가 측정은 **이미 허가된 동일 target 작업 안에서**, 알려진 hosting registry 객체에 selector capability를 확인하고 정확히 `makeViewDebugData`의 반환 타입·byte count·JSON 여부를 읽는 variant다. generic adapter를 대체하거나 동시에 debugger를 붙이지 않는다. 새 dylib 주입·attach·target 재시작은 이 문서가 승인하지 않는다.

| 단계 | 기대 관측 | 반증·실패 조건 |
| --- | --- | --- |
| G1 · direct provider | 같은 hosting token, capability, NSData/null/error, byte count, JSON top-level type. 허용한 byte/depth/node/time cap 이내에서 roots의 `properties`와 `children`을 확인한다. | capability 없음, NSData가 아님, nil, `[]`, malformed/oversized JSON이면 해당 상태를 보존한다. selector 존재만으로 graph 성공 판정 금지. |
| G2 · 기존 DBG transport | 기존 request의 identifier/version/discovery/compression을 유지하고 **별도 action**에 `propertyNames:["dbgSubviewHierarchy"]`, `propertyNamesAreExclusive:false`, `visibility:8`을 지정한다. 기존 UIKit visibility 1 action은 유지한다. | direct 성공인데 transport 누락이면 visibility/name/type/options/provider serialization을 분리 진단한다. graph visibility를 무조건 전체 15로 올리지 않는다. |
| G3 · 교차 확인 | 같은 작업의 direct bytes, generic typed serialized bytes, transport data를 각각 hash/JSON 구조로 비교한다. root/stack/Text/Shape/조건부 child 변경을 실제 반환 관계로 확인한다. | 구조가 다르거나 비어 있으면 동등성을 주장하지 않는다. 빈 graph를 UIKit 노드나 타입명 분해로 합성하지 않는다. launch-time 기록 부족은 별도 가설이다. |
| I1 · hosting composite | 기존 worker가 소유한 직접 draw 실험의 PNG와 실제 화면을 고정 Text/Shape ROI에서 비교한다. 이미지에 subtree scope와 scale/crop/orientation을 명시한다. | 누락 픽셀, 중복 subtree texture, 잘못된 alpha/좌표면 실패. Apple draw-hierarchy property helper로 자동 우회 금지. |
| I2 · 추가 layer 연구 | composite가 요구 충실도를 충족하지 못할 때만 exact encoded-layer response와 archive class/size contract를 별도 실험으로 좁힌다. | 알 수 없는 archive를 제품에서 일반 unarchive하지 않는다. host class 치환·CA rendering 성공을 전제로 하지 않는다. |

이 표는 **제안하는 mac-cu 실험 계약**이다. Apple의 완성된 wire specification이 아니다. G2는 G1 결과와 기존 transport 안전 조건을 확인한 다음 단일 owner가 실행한다. visibility 의미는 현재 host F에서 확인했지만 guest가 사용하는 Foundation 구현의 동등성도 response로 검증해야 한다.

제품 normalizer는 `captureID + target PID/start/path/device/boot + owner/epoch + hostingNodeToken`에 graph와 image를 함께 묶는다. graph node는 capture-local read-only이며 UIKit editToken을 만들지 않는다. 원본 child order를 보존하고 source/environment/value는 반환 여부와 오류 상태를 구분한다. geometry가 없으면 tree-only, composite는 hosting plane 한 곳에만 표시한다. opaque/unknown format은 unavailable로 둔다. target 변경·취소·late response·release 시 모든 graph 선택을 무효화한다. main-thread 제한만으로 deadlock·graph 기록 부족·target allocation 위험이 해결된다고 보지 않는다.

## 검사와 산출물

수정 소유권은 이 문서 하나다. raw disassembly, symbol/string 목록, constant 해석, binary/source SHA-256, SDK 감사 참조, checks와 handoff는 비공개 unique evidence directory에 둔다. manifest는 자기 자신을 hash하지 않는다. 문서 whitespace와 로컬 링크를 검사하고 repository distribution validator를 실행한다. GUI, native test/preview, Simulator 명령, LLDB attach, dylib 로드, hook/patch, 서명 변경, 설치·게시를 실행하지 않았다. 다른 worker의 runtime 결과를 이번 정적 조사의 성공으로 집계하지 않는다.
