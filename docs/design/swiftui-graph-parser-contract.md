# SwiftUI 그래프 호스트 파서 계약

## 범위와 근거

`swiftui_graph.py`는 캡처별 읽기 전용 호스트 파서다. 프로덕션 캡처에는 연결하지 않는다. 기존 UIKit 제품과 편집 토큰을 변경하지 않는다. 노드는 실제 `children` 배열만 따라 만든다. 타입명, generic 인수, reflected `value.children`과 fixture 소스는 간선을 만들지 않는다.

기존 세 번의 실험은 실패/소진 상태를 유지한다. 이번 검증은 저장된 바이트의 새 headless 파서 검증이다. 원래 lifetime 3의 거절, direct 미호출, A/B 미수집을 뒤집지 않는다. lifetime 2의 8초 readiness 원인은 미확인 상태다. baseline A는 이미 Text/Shape를 포함하므로 이 자료는 보편적인 Text/Shape 수정의 증거가 아니다.

## 전송과 호출 영수증

probe callback은 원본 NSData만 최대 16 MiB까지 파일로 보존한다. callback에서 JSON을 해석하거나 reflected property를 순회하지 않는다. typed/direct/A/B 동작은 각각 시작과 반환 파일을 독점 생성한다. 파일에는 operationID, requestDigest, action, monotonicNS, callBegan, outcome과 bytes가 있다. ABI 또는 provider가 없으면 callBegan=false와 unsupported를 기록한다. nil은 callBegan=true일 때만 허용한다. 시작 파일 발행 실패 시 해당 동작을 실행하지 않는다. 반환 파일 발행 실패 시 후속 동작을 중단한다.

기존 3/4/5/8초 경과 gate, ABI 확인, target 재검증, pinned callback, pool/context 해제, cancellation/quarantine과 원본 reservation/digest/sequence 규칙은 유지한다. 시작 영수증만 있으면 반환은 미확인이다. 예외나 시간 gate 뒤에 반환 파일이 없다는 이유로 nil을 주장하지 않는다. raw 파일 크기 제한은 반환 뒤 파일 보존의 한계다. 비공개 SwiftUI 호출 내부의 메모리 할당이나 실행 시간을 선점 제한하는 기능은 아니다.

`observe`는 영수증 없는 호출을 `notCalled`로 분류한다. 이 상태는 이번 계측에서 호출 증거가 없다는 뜻이다. 옛 자료에 대해서는 terminal/control-flow 근거를 함께 확인해야 실제 미호출을 확정할 수 있다. 영수증 없는 raw 파일은 orphan artifact이므로 `malformed`다. 새 runner는 각 capture의 stage 파일로 분류한다. 원래 실험 결과 파일은 수정하지 않는다.

## 서로 다른 비용 한계

한계는 독립적으로 적용한다. 각 비용은 전체 캡처에 적용하며 depth는 0부터 센다. 기본값을 바꿔도 다른 한계를 자동으로 확대하지 않는다.

| 비용 | 기본 한계 | 측정 근거와 선택 이유 |
| --- | ---: | --- |
| raw bytes | 16 MiB | 기존 파일 상한 유지. 저장된 입력은 1,210,085 bytes다. |
| JSON 값 | 200,000 | 실측 33,397. reflected metadata 여유를 주되 유한하게 제한한다. |
| JSON 깊이 | 128 | 실측 88. declarative 깊이와 분리한다. |
| 컨테이너 원소 | 8,192 | 실측 최대 배열 42, 객체 6. 넓은 그래프에도 유한한 상한을 둔다. |
| 단일 decoded 문자열 | 256 KiB | 실측 최대 2,520 bytes. opaque 설명 문자열을 보존한다. |
| 전체 decoded 문자열 | 8 MiB | 값 문자열 실측 862,771 bytes. 객체 키도 비용에 포함한다. |
| 숫자 token | 128 문자 | CGFloat/UInt32 관측값을 충분히 수용한다. 거대 정수 변환 비용을 제한한다. |
| declarative 노드 | 4,096 | 실측 102. JSON 값 4,096 한계를 노드 수로 오용하지 않는다. |
| declarative 깊이 | 64 | 실측 35. 실제 children 간선에만 적용한다. |
| 노드별 children | 4,096 | 전체 노드 한계와 별도로 넓이를 제한한다. |
| 노드별 properties | 64 | 관측 ID는 0/1/2/3/4다. 알려지지 않은 ID도 UInt32로 보존한다. |
| reflected attributes | 32,768 | 명시적 attribute/subattributes 실측 5,731개다. value 내부 JSON 비용은 위에서 별도 계산한다. |
| attribute 깊이 | 64 | subattributes 간선의 실측 깊이는 6이다. reflected value의 JSON 깊이와 다르다. |

토큰 scanner는 decode 전에 nesting, 문자열, 숫자 길이와 컨테이너 폭을 제한한다. 문자열은 UTF-8로 검증한다. decoder는 중복 키와 비유한 수를 거절한다. decode 뒤 전체 JSON 비용을 반복 순회로 확정한다. 숫자 지수 overflow도 거절한다. 노드 정규화와 attribute 검증은 반복 stack을 사용한다. 문자열 경로를 반복 결합하지 않고 preorder index, parentIndex, childOrdinal로 순서를 보존한다. 각 단계는 제한된 입력 크기에 선형으로 동작한다. 문자열 키 정렬은 bounded error-object 진단에만 사용한다.

## 스키마와 반환 상태

root는 배열이다. 각 노드는 properties/children 배열이 있어야 한다. property는 UInt32 id와 객체 attribute가 필요하다. 같은 노드의 중복 property ID는 거절한다. bool과 실수는 integer ID가 아니다. attribute의 type/readableType/name은 존재하면 문자열이어야 한다. flags는 존재하면 UInt32다. subattributes는 존재하면 attribute 객체 배열이다. value는 위 JSON 한계 안에서 임의의 JSON이다. 선택 필드의 부재는 추정값으로 채우지 않는다.

모든 ID의 의미와 reflected 값은 opaque다. type 문자열도 표시값으로만 유지하며 타입 구조를 해석하지 않는다. 미지의 node 필드는 opaqueFields에 보존한다. property와 attribute의 미지 필드는 원본 객체 안에 보존한다. 이 표현은 capture-local이다. cross-capture ID, UIKit edit token, 편집 권한을 만들지 않는다.

| 상태 | 의미 |
| --- | --- |
| nil | 호출이 반환했고 실제 반환값이 nil이다. |
| notCalled | 시작 증거가 없다. 과거 자료에는 control-flow 검증을 추가한다. |
| unsupported | 고정 ABI나 반환 형식을 지원하지 않는다. |
| unavailable | 시작 후 반환 미확인 또는 바이트 보존 실패다. |
| emptyArray | 유효한 JSON root 배열이 비어 있다. 비어 있지 않은 그래프 성공과 구분한다. |
| errorObject | serializer가 root 객체를 반환했다. graph로 수락하지 않는다. |
| malformed | JSON 또는 node/property/attribute 계약이 모순된다. |
| overbudget | 명시된 비용 한계를 넘었다. |
| rootArray | 전체 비용과 스키마 검증을 통과한 비어 있지 않은 그래프다. |

부분 metadata truncation은 구현하지 않는다. 한계를 넘으면 전체 graph를 거절하고 metadataProvenance를 unavailable로 반환한다. 성공 시 completeOpaqueJSON은 바이트에 있던 필드를 생략하지 않았다는 뜻이다. serializer가 제공하지 않은 런타임 상태까지 완전하다는 뜻은 아니다. 바이트 또는 JSON만 유효한 상태는 그래프 수락이 아니다.

## 검증과 다음 단계

synthetic 검사는 풍부한 metadata와 많은 children의 비용 독립성, child 순서와 원본 값, 잘못된 ID/attribute, 중복 키, 비유한 수, UTF-8/JSON 오류, 모든 비용 gate와 skipped/nil/미반환을 검증한다. 기존 8개 protocol 검사는 유지한다. 비공개 saved-raw 회귀 검사는 실제 children만 순회해 102개 노드, 3개 SwiftUI.Text, 원본 property와 순서의 일치를 확인한다. captured JSON과 지역 증거는 저장소에 넣지 않는다.

실행 명령과 실제 로그, 현재 소스/빌드/입력 hash는 별도 private handoff에 둔다. live 시도, LLDB attach, Simulator 조작, 설치는 이 작업 범위에 없다. 제품의 restart-with-recording 또는 user-prepared launch 선택은 부모 세션이 결정한다. 이후 paired graph/direct/B/branch 검증은 별도 권한과 실행 범위가 필요하다.
