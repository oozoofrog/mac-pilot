# 검사 기능의 제한된 구현 실험

## 목적과 결정

초기 공식·비공식 API 조사와 코드 감사를 완료했다. 이 문서는 제품 통합 전에 실행할 최소 실험의 범위와 통과 조건을 정한다. 실제 제품 구현 목표는 LCD 접근성 작업, 별도 창의 3D 뷰 탐색, 지원되는 속성의 명시적 변경·재조회·복원이다.

객체 식별의 첫 후보는 `NSMapTable`의 strong-key/zeroing-weak-value registry다. 저장된 주소를 객체로 변환하지 않고 현재 계층에서 찾은 객체와 weak 조회 결과를 비교한다. 정지된 앱을 사용자가 탐색하는 동안 계속 붙잡아 두지 않는다. [독립 검토](simulator-view-edit-contract-review.md)의 계약은 실험으로 확인할 설계이며, 구현 성공을 뜻하지 않는다.

## 이미지 수집 실험

기존 fixture-only 수집 경로에 내부 검증 옵션 하나를 추가한다. 옵션은 기존 요청의 `propertyNames`에 `snapshotImage`만 추가한다. 기본 요청과 일반 앱 캡처 제한은 유지한다. 임의 속성 이름, LLDB 명령, 표현식이나 외부 실행 경로를 입력으로 받지 않는다.

- 대상: 기존 `HierarchyFixture`, 기존에 부팅된 해당 기기 하나. 다른 세션의 claim, 기존 fixture·data, 사용자 앱과 Simulator 상태를 보존한다.
- 새 옵션을 검증 경로에만 허용하는 테스트와 기존 capture/session/dispatch 검사를 먼저 통과시킨다.
- 새 준비 디렉터리와 manifest를 사용한다. 기존 성공 prepared08/live06 및 원시 증거는 변경하지 않는다.
- GUI·Simulator 실행 담당자는 하나다. 준비 이후 실행 시점에 6분 이내의 UTC 종료 시각과 기존 프로세스 예산을 기록하고 parent watchdog 경로로 실행한다. 기존 reserve·detach·복구·cleanup·input guard를 축소하지 않는다.
- 성공 조건: 동일 capture 내 원래 node ID와 이미지 속성 연결, 실제 wire 형식과 픽셀 크기 확인, 소유 프로세스 정리와 대상 복구. 부모·자식 이미지의 포함 관계는 알려진 fixture 도형과 실제 디코딩된 이미지로 확인한다.
- 이미지가 없거나 의미가 불명확하면 해당 결과를 기록한다. 그 결과를 독립 뷰 texture로 표시하지 않는다. 실패 원인을 확인하지 않고 API 변형을 자동 재시도하지 않는다.

## 객체 수명 실험

별도 Foundation CLI harness에서 weak registry, 안정된 association key, 기존 타사 association 보존, detach·deallocation·주소 재사용·capture 교체를 검사한다. 이 작업은 GUI·Simulator·LLDB를 실행하지 않는다. native helper는 명시적 진입 인자와 inherited-entry 거부, parent deadline과 정확한 instance budget을 사용한다.

이 결과는 Objective-C 객체 수명 근거다. UIKit/LLDB에서의 보장은 후속 단일 담당 runtime 실험으로 확인한다. 편집 기능은 typed `hidden: Bool`, `alpha: finite 0...1`부터 구현한다. 각 동작은 이전 값 비교, setter 진입 기록, 결과 재조회와 복구 상태를 분리한다. 결과가 불확실한 변경은 자동으로 재실행하지 않는다.

## 다음 제품 통합 계약

- 선택은 guest 작업을 실행하지 않는다. AX 동작·값 변경과 UIKit 속성 변경은 각각 별도 명시적 명령이다.
- 트리, 3D 선택, 속성 상세는 같은 capture에 연결한다. 새 capture에서 주소가 같다는 이유로 이전 선택·편집 권한을 유지하지 않는다.
- 3D 펼침 간격은 표시용 깊이다. 실제 layer transform과 별도 필드로 보관한다. texture는 실제 의미가 확인된 node 이미지에만 적용한다.
- 일반 debuggable 앱 지원은 fixture 결과와 별도로 검증한다. SDK가 있는 fixture만 성공한 결과를 SDK 없는 일반 앱 지원으로 보고하지 않는다.
- 최소 지원 OS·렌더러·공통 schema는 실험 결과를 반영한 구현 설계에 확정한다. SceneKit 사용 가능성과 장기 유지 여부를 혼동하지 않는다.

## 소유권

이미지 실험 담당자가 `view-capture/`, 기존 fixture session/prepare 및 관련 capture 테스트를 단독 수정한다. 객체 수명 담당자는 새 독립 테스트 디렉터리와 자신의 증거 문서만 수정한다. 실험 중 canonical Swift 입력을 변경하지 않아 prepare manifest가 무효화되지 않게 한다. 제품 코드 통합과 전역 설치는 이 실험의 완료 이후 별도 단계다.
