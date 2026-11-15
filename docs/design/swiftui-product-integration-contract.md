# SwiftUI 제품 통합 계약

2026-11-10. 외부 adapter의 두 실제 캡처에서 선언형 노드 102개와 106개를 얻었다. 같은 hosting root의 합성 이미지는 Text, Shape, UIKit representable을 포함했다. 각 캡처의 고정 ROI 6개는 독립 화면과 채널 차이 0이었다. 기존 snapshotImage에도 Text와 Shape는 있었다. 따라서 일반적인 Text·Shape 누락을 재현했다고 주장하지 않는다.

이 근거는 캡처 방법과 표현 선택을 뒷받침한다. 제품의 부팅 세대 연결, 이전 선택 거절, 실제 UI, 일반 앱 경로는 별도 검증 대상이다. 두 원본 실행 기록의 `passed=false`는 수집 전용 runner의 결과이며 변경하지 않는다.

## 범위

이미 실행된 앱에서 기록된 SwiftUI 그래프를 읽는 경로를 통합한다. 기록 없는 앱의 실행·재실행 UX는 사용자 답변을 기다린다. 이 결정은 기존 앱의 읽기 전용 수집, 파싱, 표시 구현을 막지 않는다. 현재 프로세스를 자동 종료하거나 재실행하지 않는다.

실제 serialized children만 트리로 사용한다. 기존 UIKit roots, 편집 token, release 계약은 유지한다. SwiftUI 노드는 캡처에 한정된 읽기 전용 값이다. source location과 fixed-space geometry를 입증하지 못한 노드는 각각 unavailable과 tree-only로 표시한다.

## 호스트 전달 형식

기존 snapshot에 아래 필드를 추가한다. 이 형식은 mac-cu 내부 계약이며 Apple wire 형식이 아니다.

```text
snapshot.inspectionScope = {
  deviceID, bootIdentity, displayID, presentation, generation, runtime
}
snapshot.swiftUI = {
  schemaVersion: 1,
  captureID: snapshot.captureID,
  inspectionScope: snapshot.inspectionScope,
  hosts: [{
    hostingNodeID, sceneID,
    status: available | empty | unavailable | error | overbudget,
    reason: string | null,
    graphStatus: original parser/call outcome,
    nodes: [{id, parentID, childOrdinal, properties}],
    rendering: {
      status: available | unavailable | error | overbudget,
      representation: hostingSubtreeComposite,
      assetID: string | null,
      drawHierarchyReturned: boolean | null,
      reason: string | null
    }
  }]
}
```

- `inspectionScope`의 값은 현재 `SimulatorInspectionHost.prepare` 결과에서 얻는다. `generation`은 음수가 아닌 정수다. device, boot, display, presentation, runtime을 작업 전후에 확인한다. 요청이 주장하는 값만 반영해서는 안 된다. 기존 `processLifetime`도 함께 연결한다.
- `hostingNodeID`는 같은 작업에서 보유하고 다시 확인한 UIKit registry token이다. scene/window/parent 연결도 확인한다. 주소나 class 이름만으로 다른 캡처에 연결하지 않는다.
- 선언형 `id`는 `swiftui:<captureID>:<hostingNodeID>:<index>`다. `index`는 parser의 실제 순회 순서다. `parentID`는 같은 hosting graph 안의 ID 또는 null이다. `childOrdinal`과 `properties`의 UInt32 ID 및 attribute JSON은 원본에서 얻는다. 타입 이름을 분해하여 children을 추가하지 않는다.
- `status=available`은 비어 있지 않은 정상 그래프다. 빈 배열은 `empty`다. nil, 호출하지 않음, 호출 오류, 불완전 receipt, malformed, 예산 초과는 원인을 보존한다. 실패를 빈 정상 트리로 바꾸지 않는다.
- SwiftUI node에는 UIKit editToken, editable property, undo 권한을 부여하지 않는다. graph 선택은 새 capture, edit, HID를 호출하지 않는다.
- 성공한 합성 PNG는 기존 `snapshot.assets` 예산 안에 포함한다. `nodeID=hostingNodeID`, `captureID` 일치, `representation=hostingSubtreeComposite`, `descendantContent=all`을 명시한다. host UIKit 노드의 `assetID`를 이 asset으로 바꾸고 이전 self asset은 제거한다. `rendering.assetID`는 같은 asset을 가리킨다. drawHierarchy가 false이면 성공 이미지로 표시하지 않는다.
- 여러 host가 있으면 각 host를 독립적으로 검증한다. 중복 host token, capture/scope 불일치, 잘못된 scene, 그래프 ID 충돌, 미연결 asset은 거절한다. 기존 UIKit-only snapshot에는 새 필드가 없어도 된다. 새 SwiftUI 섹션의 손상은 조용히 무시하지 않는다.

## 수집과 표시

현재 별도 Swift 모듈의 `_UIHostingView` protocol adapter를 canonical resident에 통합한다. fixture의 구체적인 Content나 직접 oracle을 제품에서 참조하지 않는다. 이미 검증한 main-thread resident callback, pinned image, reservation, receipt, pool/context 정리, target recovery를 유지한다. 기존 helper를 대상에서 unload하거나 덮어쓰지 않는다.

graph와 PNG를 같은 작업의 hosting 객체에 연결한다. 그래프 호출과 이미지 호출의 구간을 기록하며 두 호출을 원자적인 스냅샷이라고 표시하지 않는다. host/scene/parent가 바뀌면 결과를 거절한다. host의 직렬 parser는 기존 wire/JSON/topology/attribute 예산을 유지한다. 모든 host를 합친 그래프와 이미지 예산도 제한한다. 기존 resident 응답·시간 한도를 임의로 늘리지 않는다. 제한을 넘으면 이유를 표시한다.

Outline에서 SwiftUI roots를 해당 hosting 노드 아래에 표시한다. 기존 UIKit child는 유지하고 두 종류의 node를 구분한다. 검색은 실제 type/property text와 ancestor를 포함한다. 속성 문자열 출력에도 별도 한도를 둔다.

Renderer는 hosting composite를 hosting plane 한 곳에만 그린다. 합성 이미지가 포함하는 UIKit descendant texture를 다시 겹쳐 그리지 않는다. 중첩 host도 같은 규칙을 따른다. descendant의 트리 선택과 검증된 UIKit geometry는 유지한다. geometry가 검증되지 않은 SwiftUI node에는 3D plane, picking, LCD highlight를 만들지 않는다.

캡처 교체, scope 변경, 취소, 닫힘·재열기 때 이전 graph ID와 선택을 폐기한다. 이전 graph ID를 새 capture에서 선택하거나 UIKit 편집 token으로 제출하면 거절한다. 표시를 위해 오래된 결과를 다시 활성화하지 않는다.

## 소유권과 합격 조건

Backend 작업자는 `view-capture/`, `native_build.py`, `SimulatorViews.swift`, `SimulatorViewHierarchy.swift`, `SimulatorInspectorIntegration.swift`와 해당 검사에 한정한다. UI 작업자는 `SimulatorInspectorModel.swift`, `SimulatorInspectorWindow.swift`, `SimulatorInspectorRenderer.swift`, `tests/simulator-inspector-3d/`에 한정한다. 계약 변경은 조정자에게 먼저 보고한다. 공통 배포 문서, manifest, check.sh 연결과 최종 통합은 조정자가 맡는다.

첫 단계는 GUI 없는 컴파일·회귀 검사다. archived 실제 그래프/PNG는 parser와 표시 입력 검증에 사용할 수 있지만 live authority로 재사용하지 않는다. 모의 데이터는 명시적으로 구분한다. 제품 일반 경로의 실제 graph·PNG, 부팅 세대 연결, 재캡처 뒤 이전 선택 거절, 읽기 전용 선택, UIKit hidden/alpha 복원, 닫힘·재열기와 정리는 이후 한 명의 runtime owner가 직렬 검증한다. 실제 실행 전에는 최신 입력으로 native entry와 watchdog 검사를 준비한다.

전역 앱 설치는 구현과 검증을 마친 뒤 canonical 소스로 수행한다. Git commit, push, marketplace 배포는 이 요청에 포함하지 않는다.
