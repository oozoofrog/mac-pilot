# 현재 SwiftUI runtime의 debug data 경로

2026-11-09 · iOS Simulator 27.2 / 24B114 · arm64 오프라인 정적 조사

## 결론

현재 runtime에서 `makeViewDebugData`의 Objective-C metadata와 구현을 복구했다. 구현은 `UpdateGroup.main.ensure` 안에서 hosting view의 `ViewGraph.viewDebugData()`를 읽고 `_ViewDebug.serializedData`를 호출한다. optional Swift `Data`는 Objective-C 반환 경계에서 `NSData` 또는 nil로 변환된다. `_viewDebugData()`도 같은 graph reader를 호출하지만, `makeViewDebugData`가 `_viewDebugData()`를 직접 호출하는 형태는 아니다.

`SWIFTUI_VIEW_DEBUG`는 현재 바이너리에서도 유효하다. `getenv` → `atoi` 결과를 `swift_once`로 저장한다. `ViewGraph.instantiateOutputs` 내부 closure는 저장된 mask가 0이 아니면 `AGSubgraphSetShouldRecordTree`를 호출한다. provider 호출 자체가 기존 graph의 기록을 소급 생성한다는 근거는 없다. **일반적인 이미 실행 중인 앱에서 relaunch 없이 declarative tree를 항상 얻을 수 있다는 주장은 아직 성립하지 않는다.**

이 결과는 [앞선 Xcode 조사](xcode-swiftui-reverse-engineering.md)의 runtime 내부 간격을 좁힌다. 이미지 factory·alpha helper는 다시 조사하지 않았다. 동적 반환 bytes, 실제 Text/Shape 픽셀, 임의 앱 호환성은 이번 조사 범위 밖이다.

## 이미지와 주소의 기준

| 이미지 | 실제 LC_UUID | map `__TEXT` 범위 · SHA-256 |
| --- | --- | --- |
| SwiftUI | `BCEF6306-9F1B-3CC2-9B42-233178DB4456` | `0x1c9567000–0x1ca801e3c` · `db6763a26507c54f5eb50e5a6d3ae58b938cc13bf3814e8fe246f9063324dfcf` |
| SwiftUICore | `48F6182E-C74E-36F6-B833-8F6BED405A34` | `0x1c6d3a000–0x1c7c0e5c8` · `b24e5f6ad9c60e5d69a917a47c44c1123017594ccdc57422950e9ee22fc2790a` |

위 hash는 이전 조사 자료에서 재사용했다. 후속 lead 검토에서 두 `__TEXT` 범위를 실제 cache에서 다시 읽어 일치를 확인했다. 전체 재구성 이미지 hash가 아니다. 이번에는 실제 cache의 header, load commands, symbol/indirect-symbol table, owning code와 metadata 범위를 직접 읽었다. UUID도 현재 header에서 다시 확인했다. `.tbd`나 SDK interface를 runtime code로 사용하지 않았다.

아래 VM은 unslid cache VM이다. file offset은 `dyld_sim_shared_cache_arm64` 본체 기준이며, 이번 표의 항목은 모두 본체 mapping에 있다. subcache `.01`의 존재와 mapping은 별도 manifest에 보존했다. 독립 Mach-O 파일 offset과 cache file offset을 혼용하지 않는다.

| 소유 지점 | VM | cache file offset | raw artifact |
| --- | --- | --- | --- |
| SwiftUI `_UIHostingView` instance method list | `0x1ca5319e0` | `0xa5319e0` | `resolved-method.json` |
| `makeViewDebugData` entry, index 55 | `0x1ca531c7c` | `0xa531c7c` | 같은 artifact |
| selector string | `0x23881372b` | `0x7481372b` | `metadata-details.json` |
| ObjC type encoding `@16@0:8` | `0x23b30f30c` | `0x7730f30c` | 같은 artifact |
| ObjC thunk IMP | `0x1ca38bbbc` | `0xa38bbbc` | `objc-entry.txt` |
| Swift make implementation | `0x1ca3860b8` | `0xa3860b8` | `make-swift.txt` |
| ensure closure | `0x1ca39144c` | `0xa39144c` | `bridge.txt` |
| typed `_viewDebugData()` | `0x1ca38ab88` | `0xa38ab88` | `hosting.txt` |
| Core `ViewGraph.viewDebugData()` | `0x1c79f07b0` | `0x79f07b0` | `graph.txt` |
| Core append traversal | `0x1c783e77c` | `0x783e77c` | `append-full.txt` |
| Core serializer | `0x1c783f4cc` | `0x783f4cc` | `serializer.txt` |
| Core mask initializer | `0x1c783e6c8` | `0x783e6c8` | `flags.txt` |
| output-instantiation mask check | `0x1c79ee604` | `0x79ee604` | `recording.txt` |

Method-list header는 `0xe000000f`, count는 69다. entry의 raw words는 selector offset `0x002bbf0b`, type offset `0x02db7aec`, signed IMP relative offset `0xffe59f38`이다. selector와 type은 cache에서 최적화된 shared base `0x238557820`를 기준으로 해석했다. 이 base는 두 이미지의 동일 protocol entry와 실제 selector reference로부터 역산하고 문자열로 대조했다. cache header의 selector-base 필드를 독립 복구한 결과는 아니다. IMP는 entry의 IMP field 주소에 signed offset을 더해 계산했고, 결과 symbol이 Swift hosting view의 ObjC thunk와 일치했다. 일반적인 field-relative name/type decoder로 해석하면 잘못된 주소를 얻는다.

## 복구한 호출과 graph 추출

```text
makeViewDebugData ObjC metadata -> thunk 0x1ca38bbbc
  -> Swift make 0x1ca3860b8
     -> UpdateGroup.main.ensure(closure) [call 0x1ca38611c]
        -> hosting.viewGraph [0x1ca39146c]
        -> ViewGraph.viewDebugData [0x1ca391474]
        -> _ViewDebug.serializedData [0x1ca391484]
  -> Data._bridgeToObjectiveC [0x1ca38bc04], or nil

_viewDebugData 0x1ca38ab88
  -> hosting.viewGraph -> same ViewGraph.viewDebugData [0x1ca38ab9c]

ViewGraph.viewDebugData
  -> AGSubgraphGetTreeRoot [0x1c79f07ec]
  -> null root: empty Swift array
  -> non-null root: appendDebugData [0x1c79f07f8]
     -> AGTreeElementGetFlags / GetValue / GetType
     -> AGTreeElementMakeValueIterator / GetNextValue
     -> AGTreeValueGetKey / GetValue, AGGraphGetValue
     -> AGTreeElementGetNextChild + recursive append
```

SwiftUI의 두 imported call은 LC_DYSYMTAB의 indirect-symbol index로 해석했다. 그 symbol의 정의는 SwiftUICore nlist에서 위 주소로 확인했다. executable branch displacement와 symbol 이름을 함께 사용했으며 문자열 검색만으로 호출 관계를 만들지 않았다. `ViewGraph`의 null-root 분기는 빈 배열을 반환한다. non-null root에서도 필터와 traversal 결과에 따라 빈 배열이 가능하므로 `[]`만 보고 원인을 하나로 단정하지 않는다.

selector, ObjC type string, method metadata, GOT, once token과 mask는 원래 `__TEXT` map 범위 밖에도 있다. 이번 cache mapping reader는 이 범위를 직접 해석했다. 반면 `UpdateGroup.ensure`, AttributeGraph 내부 recording 구현, Foundation JSONEncoder 전체 구현은 imported 경계까지만 확인했다. 내부 lock·thread·재진입·기록 보존 정책을 복구했다고 주장하지 않는다. 이 경로를 무할당 또는 무부작용 provider로 보장하지 않는다.

## 기록 mask와 초기화 조건

initializer `0x1c783e6c8–0x1c783e6f0`는 `SWIFTUI_VIEW_DEBUG` 문자열을 `getenv`에 전달한다. 값이 있으면 `atoi`를 호출하고, 없으면 0을 저장한다. mask 저장 위치는 `0x22e5d6b68`, once token은 `0x22e5d6b60`이다. 이 주소는 현재 이미지의 정적 분석 식별자이며 제품 제어 지점이 아니다.

getter `0x1c783e6f4–0x1c783e744`와 output-instantiation slow path `0x1c79ee8b8–0x1c79ee8cc` 모두 같은 initializer를 `swift_once`에 전달한다. 초기화 전에는 이 경로의 첫 접근이 환경 값을 읽는다. 초기화 뒤에는 저장된 mask를 재사용한다. 따라서 실행 중 환경 값 변경이 이 accessor를 통해 반영된다는 근거는 없으며, graph 생성 뒤 provider를 호출하는 것만으로 과거 tree가 복구되지 않는다.

`ViewGraph.instantiateOutputs` closure(`0x1c79ee4c4`)의 `0x1c79ee614–0x1c79ee620`은 mask를 읽고 nonzero일 때 `AGSubgraphSetShouldRecordTree`를 호출한다. 실제 tree 구성 코드에는 `AGSubgraphShouldRecordTree` 검사 callsite도 존재한다. 이번 조사는 AttributeGraph 내부 설정의 모든 writer와 graph 재생성 조건을 열거하지 않았다. 이미 다른 경로에서 기록된 앱은 no-flag에서도 결과가 있을 수 있다. no-flag가 반드시 `[]`라는 결론은 아니다.

append traversal에서 직접 확인한 선택 bit는 다음과 같다. 이 표는 관측한 필터이며 전체 설정 사양이 아니다.

| bit · raw mask | 대응 AG key | 근거 VM |
| --- | --- | --- |
| 2 · `0x4` | `transform` | `0x1c783e958–0x1c783e96c` |
| 3 · `0x8` | `position` | `0x1c783e8e0–0x1c783e8f4` |
| 4 · `0x10` | `size` | `0x1c783e908–0x1c783e91c` |
| 5 · `0x20` | `environment` | `0x1c783e8b8–0x1c783e8cc` |
| 6 · `0x40` | `phase` | `0x1c783e930–0x1c783e944` |
| 7 · `0x80` | `layoutComputer` | `0x1c783e980–0x1c783e994` |
| 8 · `0x100` | `displayList` | `0x1c783e9a8–0x1c783e9bc` |

기존 저자의 `287`은 decimal `0x11f`, 즉 bit 0·1·2·3·4·8이다. 현재 바이너리의 decimal parser, nonzero recording 조건 및 위 필터와 양립한다. 현재 코드에 `287`이라는 필수 상수가 존재한다거나 이것이 최소/최적 mask라는 증거는 없다. bit 0·1의 모든 소비 지점도 완전하게 추적하지 않았다. 따라서 이 값은 소유 fixture의 비교 variant로는 근거가 있지만 임의 사용자 앱의 launch 설정으로 자동 적용할 계약은 아니다.

## serializer에서 확인한 범위

`serializedData`는 `JSONEncoder`를 생성하고 `[ _ViewDebug.Data ]`의 Encodable witness를 사용해 encode한다(`0x1c783f5e8`). 실패 경로는 localized error description을 dictionary로 encode하려고 다시 시도한다(`0x1c783f664–0x1c783f6b4`). 따라서 **NSData나 유효 JSON만으로 graph 성공을 판정하면 안 된다.** 정상 root array, 빈 root array, 오류 dictionary, nil, 형식 오류를 구분해야 한다.

| 구조 | 직접 확인한 key · 동작 | 근거 artifact / VM |
| --- | --- | --- |
| graph node | `properties`, `children`; 두 key의 encoding 경로 존재 | `data-keys.txt` `0x1c783f924`; `data-encode.txt` `0x1c783fa14` |
| property record | `id`, `attribute`; id를 UInt32로 encode하고 attribute를 별도 encode | `property-keys.txt` `0x1c783ff80`; `property-encode.txt` `0x1c783fe54` |
| attribute | `name`, `readableType`, `type`, `flags`, `subattributes`, `value` | `attribute-keys.txt` `0x1c784030c`; `attribute-encode.txt` `0x1c7840438` |
| 값 | optional value의 Encodable dynamic cast와 조건부 encode 경로 | `attribute-encode.txt` `0x1c7840628–0x1c78406a8` |
| AG 기본 값 | type metadata를 property key 0에, projected AG value를 key 1에 저장 | `append-full.txt` `0x1c783e804–0x1c783e834`; `project-value.txt` `0x1c783f450–0x1c783f4b4` |

`attribute`는 앞선 host decoder가 optional로 받아들이는 필드지만 현재 guest serializer의 위 property encode는 별도 필수 encode 호출을 한다. host 허용 범위를 guest의 생성 보장과 혼동하지 않는다. `value`가 모든 Swift 타입에서 구조화된 JSON으로 나오는 것은 아니다. 전체 property ID 대응표, attribute flags의 모든 bit, type 명명 규칙, reflection depth/필터 정책, Text 문자열·Shape path의 실제 표현은 미복구다. 타입명 분해로 children을 만들거나 원본 SwiftUI 선언을 합성하지 않는다.

## 단일 runtime owner에게 필요한 측정

기존 probe owner만 다음 비교를 수행한다. 이 문서는 attach·주입·재시작·환경 변경을 실행하거나 새로 승인하지 않는다.

1. **기존 no-flag baseline:** 이미 소유한 fixture의 launch 설정에 해당 key가 없었는지 기존 launch 기록으로 확인한다. 같은 hosting token에 direct provider와 typed reader/serializer를 적용하고 capability, 반환 클래스, nil/error, byte count, hash, JSON top-level, root count를 각각 기록한다. `[]`는 empty 상태다. direct와 typed가 다르면 dispatch·동기화·hosting instance 차이를 먼저 분리한다.
2. **별도 owned-fixture launch variant:** 현재 정적 근거에 따라 `SWIFTUI_VIEW_DEBUG=287`을 fixture 시작 전 설정한 variant를 비교할 수 있다. 기존 owner의 허가 범위와 launch 절차가 이를 포함할 때만 실행한다. 동일 view 구성·렌더 시점·capture budget에서 roots와 bounded properties/children을 비교한다. baseline empty/variant nonempty는 해당 fixture에서 기록 선행조건을 지지한다. variant도 empty이면 recording 성공을 주장하지 않는다.
3. **최소 actual bytes 질문:** node `properties`와 `children`의 타입, property의 UInt32 `id`, attribute의 실제 key와 optional/null/생략 상태, Text와 Shape의 value 표현, `displayList` identity 존재 여부를 제한된 예제로 받는다. 오류 dictionary도 보존한다. 원본 bytes hash와 제한된 JSON excerpt를 연결한다.
4. **판정 범위:** no-flag nonempty이면 flag가 언제나 필요하다는 가설은 반증된다. no-flag empty라도 일반 앱 전부에 relaunch가 필요하다고 일반화하지 않는다. 임의 사용자 앱 relaunch가 필요한 제품 흐름은 미결정 사항으로 남긴다. writable global patch, initializer 재실행, 타입명 기반 가짜 graph는 구현 경로에서 제외한다.

실험 성공은 실제 declarative children과 값이 반환되는 경우에만 인정한다. Text/Shape 렌더링 성공은 별도 픽셀 근거가 필요하다. 정적 callgraph는 두 결과를 대체하지 않는다.

## 조사·검사 범위

정적 접근은 세 종류로 제한했다. (1) cache mapping과 Mach-O symbol/indirect-symbol 해석, (2) owning 함수 범위만 synthetic 분석용 Mach-O로 감싸 기존 `llvm-objdump`에 전달, (3) cache 최적화 ObjC method metadata 해석이다. synthetic 파일은 분석용 byte wrapper이며 실행 이미지 추출본이 아니다. 실행하거나 로드하지 않았다. 도구 설치, GUI, Simulator 명령, runtime process 조회·attach, injection, 앱 hook, 시스템 변경, 설치·게시를 수행하지 않았다.

private handoff에는 실행 script와 hash, 실제 source/cache/image/range manifest, raw disassembly와 검사 로그를 둔다. manifest는 자기 자신을 hash하지 않는다. 문서 whitespace·로컬 링크 및 repository distribution 검사를 수행했다. 다른 worker의 live 결과는 이번 정적 결과에 포함하지 않았다.
