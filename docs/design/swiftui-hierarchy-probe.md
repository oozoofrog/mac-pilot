# SwiftUI 외부 계층·픽셀 실험

## 현재 결과 — 2026-11-10

14번째 제한 실행에서 두 캡처를 수집했다. 새 fixture lifetime은 한 번이며 누적 9번이다. 외부 typed adapter가 앱 내부 graph oracle보다 먼저 실행됐고, charlie 분기에서 102개, delta 분기에서 106개의 실제 선언형 노드를 반환했다. 두 캡처 모두 원본 children과 속성에서 Text, Shape, container, UIKit representable을 확인했다.

두 hosting subtree 합성 이미지의 고정 ROI 6개는 각각 독립 화면과 최대 채널 차이 0이었다. 기존 snapshotImage에도 Text·Shape가 있었지만 UIKit representable은 없었다. typed/direct 그래프는 byte 단위로 같지 않다. 속성 ID로 비교하면 각 쌍의 차이 70개는 모두 UISceneConfiguration 진단 문자열의 포인터 값이다. child 관계와 나머지 값은 일치했다.

대상 수명, 같은 작업의 capture/scene/hosting 연결, callback image 범위, pool/context 정리, debugger 자식 종료, 원래 화면 복원과 claim 해제를 확인했다. 원본 runner의 `passed=false`는 그대로 보존했다. 이 runner는 수집 완료와 제품 합격을 구분한다.

**제품 검증은 아직 남아 있다.** 캡처 receipt에는 명시적 boot-generation token이 없고, 이전 SwiftUI ID를 실제 제품 consumer가 거절하는 검사는 실행하지 않았다. 두 조건은 [제품 통합 계약](swiftui-product-integration-contract.md)의 필수 검증이다. 일반 앱 경로, 실제 inspector, UIKit 편집 회귀와 전역 앱 설치도 별도 단계다. 이전 13회 실패 기록은 유지한다.

## 최초 실험 기록

아래는 2026-11-09의 최초 세 lifetime 기록이다. 현재 결과로 소급 변경하지 않는다.

2026-11-09 · probe unit attempt1 · **허용된 live lifetime 3/3 종료, 통합 합격 미달**

## 결론

별도 Swift helper의 generic protocol conformance로 **fixture의 구체적 Content를 모르는 외부 코드가 실제 hosting view의 `_viewDebugData()`를 호출했다.** no-flag baseline에서는 typed route와 ABI를 확인한 `makeViewDebugData`가 모두 `[]`를 반환했다. 별도 fresh-launch `SWIFTUI_VIEW_DEBUG=287` variant에서는 실제 선언형 graph 1,210,085 bytes가 반환됐다. 그러나 구조 budget을 초과하여 runtime에서 거절했다.

no-flag baseline의 직접 `drawHierarchy(in:afterScreenUpdates:false)`는 true를 반환했다. B PNG의 고정 ROI 6개는 독립 screenshot과 RGBA 차이가 0이었다. Text·Shape·UIKit representable을 확인했다. **이 fixture에서는 A `snapshotImage`도 Text·Shape를 포함했다.** A는 UIKit representable의 픽셀을 포함하지 않았다. 과거 Text·Shape 누락이 모든 SwiftUI 화면에서 발생한다고 일반화하지 않는다.

완료 기준은 충족하지 못했다. nonempty graph와 B를 **같은 성공 캡처**에 연결하지 못했고, 조건부 branch 재캡처와 이전 capture identity 만료도 실행하지 못했다. 거절된 raw graph를 오프라인에서 읽은 결과를 runtime 합격으로 바꾸지 않았다. production integration·전체 UI·전역 앱 설치의 근거가 아니다.

## 실제 실행

대상은 일반 iOS Simulator 27.2 / 24B114, arm64, Xcode 27.2 / 27B48이다. 이미 boot된 지정 device만 사용했다. Duo, device 생성·boot·reset, 사용자 앱 재시작, persistent defaults는 변경하지 않았다.

| lifetime | 조건 | 결과 |
| --- | --- | --- |
| 1 | no-flag, 앱 내부 graph 호출 0 | typed cast 성공. typed/direct 각각 2-byte `[]`, bytes/hash 동일. A/B와 독립 화면 수집. B pixel 합격. graph 실패이므로 branch 변경 생략. |
| 2 | 별도 새 fixture에 287 요청 | 8초 readiness oracle timeout. target은 live/untraced였다. debugger attach 전에 종료했다. 앱 내부 flag readback은 얻지 못했다. |
| 3 | 새 fixture에 287, bounded lifecycle 진단 추가 | `App.init` 및 oracle에서 287 확인. 실제 typed graph 반환 후 `graphBudgetRefused`. direct·A/B·branch를 실행하기 전에 중단. 독립 화면은 보존했다. |

lifetime 2의 crash report와 보존된 unified-log 항목은 발견하지 못했다. lifetime 3은 같은 scene·flag·8초 guard를 유지하고 초기화, preference, onAppear, timer 단계를 기록했다. App.init 뒤 약 4.0초에 state 초기화, 약 4.4초에 rects/onAppear, 약 4.8초에 첫 timer tick을 관측했다. lifetime 2의 원인을 이 결과만으로 확정하지 않는다.

세 lifetime 모두 소유 target의 종료, 앱·data 제거, 원래 guest/host foreground·window 상태 복원, claim release, parent group의 live/zombie/unknown 0을 확인했다. debugger를 사용한 lifetime 1·3은 detach, 같은 target의 responsive/untraced 상태, debugger 자식 종료, local pool sentinel 소멸과 operation context 0을 확인했다. callback PC는 기록한 helper image의 text 범위 안에 있었다. image는 target lifetime 동안 유지하고 unload하지 않았다. callback 시간은 각각 약 1.61초, 1.96초였다.

## 실제 graph와 거절 이유

오프라인 진단은 보존한 원본 bytes를 읽었다. `children`만 따라 관계를 만들었다. 타입명이나 fixture 소스로 자식을 합성하지 않았다.

| 관측 항목 | 값 |
| --- | --- |
| root array | 1 root, 102 actual nodes |
| 선언형 최대 depth | 35 |
| 전체 JSON container/scalar | 33,397 |
| 전체 JSON 최대 depth | 88 |
| 최대 container 항목 수 | 42 |
| 실제 property IDs | 0·1 각 102개, 3·4 각 37개, 2는 2개 |
| 직접 관측한 type node | `ProbeContent` 1, VStack/HStack 각 1, `SwiftUI.Text` 3, filled Rectangle/Circle 각 1, `ProbeUIKit` 1, padding 2, opacity 1 |
| 실제 문자열 value | `ALPHA SWIFTUI 731`, `BRAVO DECLARATIVE 482`, `CHARLIE BRANCH 263` |

원본에 `properties`/`children`, UInt32 범위 `id`, `attribute`의 `type`, `readableType`, `flags`, `value`, `name`, `subattributes`가 있다. Text 문자열은 실제 attribute value 안에서 확인했다. property 8이나 display-list identity는 이 graph에서 관측하지 못했다. 전체 ID·flags 의미, 모든 geometry의 좌표 공간, source 위치를 보장하지 않는다.

helper는 모든 JSON container/scalar를 합쳐 4,096개, JSON depth 64로 제한한다. 이 두 한도를 실제 출력이 넘었다. raw bytes는 16 MiB file cap 안이므로 먼저 보존했다. 거절 직후 direct provider와 이미지 수집을 중단했다. 따라서 lifetime 3의 direct가 nil을 반환했다고 해석하면 안 된다. **그 호출 자체를 실행하지 않았다.** 같은 이유로 lifetime 3의 최종 hosting/image association receipt도 없다. request·target·loaded image·callback receipt와 raw graph의 연결은 보존했다.

오프라인 진단의 더 큰 읽기 상한은 거절 원인을 수량화하기 위한 것이다. runtime cap을 바꾸거나 acceptance를 다시 열지 않는다. 다음 단위는 실제 선언형 node/depth와 property reflection 비용을 구분하는 bounded parser 계약이 필요하다. 이후 새로 허가된 live 검증에서 같은 hosting/capture의 direct·typed·B와 branch 변경·stale identity를 함께 확인해야 한다.

## 픽셀 판정

baseline의 hosting bounds는 402×874 pt, scale 3, PNG는 1206×2622 px다. portrait, fixed-space origin (0,0)을 확인했다. 독립 fixture geometry가 반환한 global ROI를 좌상단 기준으로 3배 변환했다. A objectID/class는 같은 callback의 hosting address/class와 유일하게 연결했다. B는 `hostingSubtreeComposite` 한 장이며 자식별 texture로 복제하지 않았다.

제목·부제·branch·Rectangle·Circle·UIKit representable의 6개 ROI에서 B와 독립 화면의 최대 RGBA 차이는 모두 0이다. 허용치는 동일 좌표의 8-bit quantization 1 code value다. antialias 경계를 제외하거나 정렬을 사후 조정하지 않았다. 고정 interior patch의 rectangle RGB는 (217,38,51), circle은 (106,197,139)이며 reference와 같다. circle의 apparent opacity는 채널별 약 0.6492–0.6499로, 예상 0.65와 half-code quantization 범위 안에서 일치한다. 채널별 허용치는 `0.5 / (255 × (1 − sourceChannel))`로 계산했다. PNG alpha는 흰 배경과 합성된 255이며, 별도 shape alpha plane이라고 주장하지 않는다.

원본 A/B/reference PNG는 보존했다. 구현 agent가 프레임을 열어 세 Text, 두 도형, overlay와 UIKit witness를 확인했다. 사람의 디자인 승인으로 표현하지 않는다. A는 SwiftUI 자체 픽셀을 포함하지만 UIKit descendant ROI가 비어 있다. effects·encoded layers·per-declarative-node self texture는 별도 미검증이다.

## 구현과 검증 경계

소유 경로는 `mac-computer-use/tests/swiftui-hierarchy-probe/`와 이 문서뿐이다. 기존 production·fixture/support·manifest·전역 설치본을 수정하지 않았다. commit/push/publication도 하지 않았다.

- `Bridge.swift`: helper-owned MainActor protocol과 `_UIHostingView` generic extension. fixture module·concrete Content 의존성이 없다. 별도 빌드·서명한 helper와 일반 `SwiftUI.App`을 사용했다. 앱에는 graph API 호출이 없다.
- `resident.m`, `capture.inc`: 고정 digest wire, PID/start/path/device, scene, helper path/UUID, typed live view를 검사한다. 첫 baseline graph 호출은 debugger texture provider보다 먼저다. 이후 고정 `makeViewDebugData`의 capability와 object 반환·인수 ABI를 검사한다. arbitrary selector/KVC, unsafeBitCast, swizzling, renderer 설정 변경은 없다.
- `debugger.py`: current production의 runtime 및 symbol/PC/module에 연결된 SwiftUI idle startup 검사를 사용한다. LLDB는 짧은 load/submit만 실행한다. target의 정상 main callback은 traced=false를 확인한 뒤 UI 작업을 한다. forced unwind, JIT UI callback, run-loop pumping, 임의 pool pop, saved-pointer cleanup은 없다.
- `runner.py`: 기존 session machinery의 claim/input/focus/정확한 executable budget/cleanup reserve를 유지한다. flag variant는 성공적으로 정리된 실제 empty baseline을 요구한다. `/usr/bin/env SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287`은 새 소유 fixture launch 한 번에만 적용한다. raw 수집만으로 `passed=true`를 만들지 않는다.
- `graph.py`: root array, empty array, error object, nil, malformed, budget rejection을 구분한다. `assess_pixels.py`와 `diagnose_rejected_graph.py`는 오프라인 재현 도구다. 후자는 runtime rejection을 변경하지 않는다.

bitmap은 최대 2048×4096, 32 MiB이며 file cap은 16 MiB다. graph/direct/A/전체 elapsed gate는 3/4/5/8초다. framework 함수 내부 실행·allocation을 선점 제한한다고 주장하지 않는다. 불명확한 반환은 custody를 유지해야 한다. parent deadline은 660초다. terminal의 `residentScalarBytes=8`은 원래 admission atomics 두 개의 크기이며 helper 전체 heap/metadata 비용이 아니다. image의 mapped-section/file 비용은 별도로 보존했다.

초기 native safety 검사에서는 full-table `ps` 지연으로 7개 중 4개 오류가 발생했다. 별도 진단에서 3초 timeout 이후 반환까지 51.421초가 걸렸다. 모든 실패를 보존했다. 이후 offline RE 종료 뒤 같은 enumeration이 0.090초에 반환했고, 새 preparation들의 native safety 7/7과 현재 production-helper·unknown·inherited dispatch가 통과했다. timeout을 늘리거나 guard를 우회하지 않았다. canonical whole-host probe는 preparation hash를 검증한 경우에만 재사용했다.

추가 검사: protocol/classification 계약 8/8, 고정 submit 식의 no-target LLDB 파싱, source/Python AST/문서 링크, distribution validator. 초기 bridge 접근 수준과 dependency 제목 줄 assertion 오류, deadline fractional-second 형식 거절, pixel opacity quantization 계산 오류도 원본 로그와 함께 보존했다. 최종 fixture build에는 unused `try?` 및 SDK driver 경고가 남아 있다. target platform은 Simulator이고 빌드·서명 검사는 통과했다.

[첫 Xcode RE](xcode-swiftui-reverse-engineering.md)와 [현재 runtime RE](swiftui-runtime-debug-data-path.md)를 근거로 해석했다. 별도 visibility-8 graph transport는 실행하지 않았다. alpha를 임시 변경하는 Apple draw-hierarchy property helper는 사용하지 않았다. 일반 실행 앱의 무재시작 지원은 확립되지 않았다. source/binary/artifact SHA-256, 전체 raw 출력, 선택 PNG와 상세 handoff는 private evidence에 있으며 manifest는 자기 자신을 hash하지 않는다.

## 2026-11-09 시도 4 — 앱 실행 전 중단

13:31 UTC에 수정된 파서로 추가 검증을 시작했으나, 기존 입력 가드가 설치 전에 중단했다. 부모와 worker는 모두 `InterruptedError('desktop input observed; stop interaction, no forced foreground restoration')`를 기록했다. 가드는 combined-session event counter의 변화를 확인하며 이벤트의 발생 주체는 기록하지 않는다. 시간 제한, 가드, 소스 hash 또는 수락 조건은 변경하지 않았고 재시도하지 않았다.

**시도 횟수는 4/4다. 실제 테스트 앱 실행은 누적 3회이며 이번 시도에서는 0회다.** 앞선 세 번의 결과와 원본 transaction의 `passed=false`를 유지한다.

새 전체 준비 검사는 통과했다. native safety 7/7, watchdog 아래의 helper·inherited·daemon·normal·unknown 진입 경로 5/5, helper와 일반 fixture 빌드·서명, targetless LLDB를 확인했다. host 재사용 시 입력 57개의 동일성을 확인했고 최종 준비 입력 146개의 hash를 다시 대조했다. parser/protocol 테스트 14/14와 distribution validator도 통과했다. 별도 보조 검사는 SDK와 runtime의 build 번호가 같다고 잘못 가정하여 실패했다. 실제 메타데이터에서 기존 검증과 동일한 SDK 27.2 / 24B113 및 runtime 27.2 / 24B114를 확인했다. 이 보조 검사 때문에 준비 단계의 가드를 교체하거나 완화하지 않았다.

이미 켜져 있던 일반 기기의 claim을 획득한 뒤 원래 host foreground/window와 guest foreground/display 상태를 읽었다. 설치·실행 전 중단했으므로 target PID/start/path, LLDB attach, resident load, callback, graph, image 및 branch-control 작업은 없었다. `SWIFTUI_VIEW_DEBUG=287` 실행 설정도 어떤 프로세스에도 적용되지 않았다.

그래프·픽셀의 별도 수락 결과는 **실패이며 해당 단계는 미실행**이다. typed/direct 비교, A/B와 독립 화면 픽셀, 두 분기 상태, capture/hosting/scene 연결, callback/pool 정리, helper 단일 로드와 capture-local 만료를 검증하지 못했다. 새 PNG와 ROI 측정은 없다. 이전 baseline의 이미지는 이 검증을 대신하지 않는다. baseline A에는 이미 Text/Shape가 있었으므로 이번 시도가 Text/Shape 누락을 재현했다는 주장도 하지 않는다.

복원 후 읽은 host와 guest의 원래 상태가 일치했고 claim은 해제됐다. 독립 조회에서 고유 bundle과 data는 없었으며 소유 executable은 0개였다. worker group의 live·zombie·unknown 항목도 모두 비었다. 설치되지 않은 fixture를 제거했다고 주장하지 않는다. quarantine이나 소유권이 불확실한 target은 남지 않았고 foreground·Simulator·debugger 사용권을 반납했다.

worker는 이 결과만 문서에 추가했다. lead는 원본 자료의 hash를 확인한 뒤 이 절을 한국어로 정리했다. harness와 제품 소스는 변경하지 않았다. 준비·빌드 로그, 원본 session/parent 기록, 실패 판정, 정리 결과 및 자기 자신을 포함하지 않는 SHA-256 manifest는 비공개 증거에 있다. 제품 통합·전역 설치·게시는 하지 않았다. 제품의 기록·재실행 흐름에 대한 사용자 선택은 별도로 남아 있다.


## 2026-11-09 시도 5 — debugger 초기화 실패

사용자가 새 입력 없는 검증 시간을 허용한 뒤, lead는 같은 유한 검증의 마지막 허용 시도를 5/5로 명시했다. 13:41:07 UTC에 기존 runner를 정확히 한 번 실행했다. **이번 실제 fixture 실행은 1회이며 누적 실제 실행은 4회다.** 시도 4는 설치 전 중단되어 실제 실행이 0회였다. 여섯 번째 시도나 자동 재시도는 없다.

시도 4의 완료된 준비 빌드를 재사용했다. 준비 입력 146개, binary 6개, 이전 artifact 86개와 원본 transaction 4개의 hash가 모두 일치했다. source manifest 21개 중 차이는 lead가 한국어로 정리한 시도 4 부록뿐이며, 이 문서는 준비 입력 146개에 포함되지 않는다. 기존 native safety 7/7, watchdog 진입 경로 5/5, parser/protocol 14/14와 빌드·서명·targetless LLDB 결과를 재사용했다. 전체 테스트와 빌드를 반복하지 않았다. 기존 일반 기기의 claim이 비었고 소유 executable이 실행 중이지 않음을 확인했다. SDK 27.2 / 24B113과 runtime 27.2 / 24B114는 기존 검증과 같은 조합이다.

fixture는 실행됐고 독립 oracle은 `SWIFTUI_VIEW_DEBUG=287`, branch `charlie`, 앱 내부 graph 호출 0을 기록했다. 그러나 별도 Python debugger worker가 `import lldb`에서 `_lldb` ImportError로 실패했다. `LLDBEngine` 생성은 `SBDebugger.Create()`보다 앞에서 실패했다. connect·attach·helper load·submission·callback은 실행하지 않았다. targetless `xcrun lldb` 검사는 이 standalone Python worker의 `_lldb` import 성공을 증명하지 않는다. 원인 수정은 이번 runtime-only 범위 밖이므로 소스나 실행 환경을 변경하지 않았다.

runner는 약 17.3초 뒤 실패를 기록하고 fixture와 claim을 보존했다. 원본 session·parent·experiment·target 및 capture 준비 기록은 수정하지 않았고 `passed=false`를 유지했다. typed/direct stage는 모두 `notCalled`다. 그래프의 실제 children/properties, typed/direct 구조·bytes, A/B·독립 화면, 두 캡처의 ROI와 원본 PNG, branch 변경, hosting/capture/device-boot 연결, callback/pool·helper 단일 로드 및 이전 token 만료는 미실행이다. 새 PNG가 없으므로 픽셀이나 이미지 관찰의 합격을 주장하지 않는다. B는 계속 단일 `hostingSubtreeComposite`이며, 이전 baseline A에 이미 있던 Text/Shape를 누락 재현으로 바꾸지 않는다.

별도 실패 정리에서는 import가 attach 전에 실패한 소스 순서, debugger 종료와 자식 회수, 동일 target의 live/untraced 상태, 비어 있는 worker group을 먼저 확인했다. 원래 claim과 PID/start/path/device를 다시 검사하고 기존 input/focus 가드를 사용했다. 원래 660초 마감 안에서 정리 시간을 최대 117초로 제한했다. 소유 fixture만 종료·제거했으며 host·guest의 원래 PID/start/path, window와 display 상태가 입력 없는 조회에서 일치했다. 사용자 앱 재시작, 강제 foreground 복원, process-group kill은 없었다.

**13:43:08 UTC에 foreground·Simulator·debugger 사용권을 반납했다.** 독립 조회에서 fixture app/data와 device claim은 없었고 소유 executable은 0개였다. 원래 worker group의 live·zombie·unknown 항목도 모두 비었다. 이 후속 정리의 성공은 원본 runtime transaction 실패를 바꾸지 않는다. 별도 semantic/pixel/identity 수락 결과는 실패다.

worker는 이 부록과 비공개 증거만 작성했다. harness·parser·fixture·공유 안전 코드·제품·manifest·전역 앱은 변경하지 않았다. 백업, Git 변경 명령, 게시와 제품 통합은 하지 않았다. 원본 기록의 hash, 준비·source·binary·artifact manifest, 실패 판정과 후속 정리 근거는 비공개 handoff에 보존했다. 제품의 기록·재실행 흐름에 관한 선택은 여전히 범위 밖이다.


## 2026-11-09 시도 6 — 제출 후 프로세스 식별 가드 중단

lead는 인터프리터 수정과 새 전체 준비 뒤 같은 유한 검증을 시도 6/6으로 명시했다. 14:05:44 UTC에 `/usr/bin/python3 -B`로 runner를 정확히 한 번 실행했다. **이번 실제 fixture 실행은 1회이며 누적 실제 실행은 5회다.** 앞선 시도 5개는 실패로 유지한다. 시도 4는 실제 실행이 0회였다. 일곱 번째 시도, 자동 재시도, 새 검증 단위나 예산 재설정은 없다.

현재 전체 준비 `mac-cu-swiftui-verified-prep-yfsy9qak/prepared/base`를 재사용했다. 준비 입력 148개, binary 6개와 readiness flag 3개의 일치를 입장 전에 확인했다. workerRuntime은 현재 실행 파일의 Xcode Python 3.9.6, `cpython-39`/`cpython-39-darwin`, arm64와 선택한 Xcode/LLDB 파일 33개를 고정했다. debugger의 실제 `-I` import 검증은 이 완료된 준비에 포함돼 있다. 준비 명령 18개의 exit 0, native safety 7/7, watchdog 진입 경로 5/5, 회귀 검사 26/26 및 빌드·서명·targetless LLDB의 유효한 근거를 재사용했다. 영향받지 않은 빌드와 검사를 반복하지 않았다. 이전 시도 5의 원본 기록 24개도 다시 hash로 대조했다. 이전 Python 3.15와 LLDB CPython 3.9 바인딩의 불일치는 이번 실행에서 발생하지 않았다.

기존에 boot된 지정 일반 기기, iOS 27.2/24B114 arm64와 Xcode 27.2/27B48을 사용했다. SDK 27.2/24B113은 구분한 기존 검증 조합이다. claim이 없고 소유 executable이 0개임을 먼저 확인했다. 660초 이내의 새 절대 마감은 14:16:44 UTC였으며 보호된 정리 예산 117초와 기존 입력·focus·process budget 가드를 유지했다. fixture 하나에만 launch-time `SWIFTUI_VIEW_DEBUG=287`을 적용했다. 독립 oracle은 branch `charlie`와 앱 내부 graph 호출 0을 기록했다.

LLDB는 attach, main-thread checkpoint, helper 1회 load와 callback 제출을 완료했다. 그 뒤 성공적으로 detach했고 debugger와 debugserver는 exit 0으로 회수됐다. 그러나 parent는 PID 44896의 `(debugserver)` 표본을 kernel identity로 확인하지 못해 `RuntimeError('cannot verify resident executable PID 44896')`를 기록했다. 가드는 이 표본을 `unknown`으로 분류하고 worker에 협조 중단을 요청했다. runner는 약 14.6초 뒤 exit 1로 끝났다. 입력이나 focus 거절은 기록되지 않았다. 종료 중 process 표본과 관련된 실패이지만 그 식별 조회의 내부 원인은 이번 범위에서 진단하거나 수정하지 않았다.

worker는 `ProbeCleanupUnknown`을 기록하고 fixture와 claim을 보존했다. 원본 session·parent·experiment·target과 전체 live 기록 29개는 수정하지 않았다. 원본 `passed=false`도 유지한다. 원본 복사본에는 terminal이 없었으나 같은 target의 channel에는 이후 `cancelledBeforeEntry` terminal이 게시됐다. 이 후속 기록 16개는 원본과 분리해 보존했다. terminal은 같은 operation ID와 digest, 취소된 authority, helper UUID와 text 범위 안의 callback PC를 연결한다. callback은 detach 반환 뒤 main thread에서 untraced 상태로 실행됐다. `captureEntered=false`, `poolExited=true`, `operationContexts=0`이며 authority는 다시 열리지 않았다. capture에 진입하지 않았으므로 capture-local pool sentinel은 생성되지 않았다.

실제 graph children/properties, root/container/Text/Shape/representable, typed/direct ABI와 bytes·구조 비교는 **미실행**이다. host stage classifier는 typed와 direct 모두 `notCalled`로 판정했다. A snapshot, 단일 B `hostingSubtreeComposite`, 독립 화면과 두 번째 capture도 없다. PNG가 없어 두 캡처의 고정 ROI 검사와 원본 이미지 관찰은 실행할 수 없었다. 사후 정렬이나 임계값 변경은 없다. 조건부 branch 변경, 실제 hosting/capture/device-boot 연결, 두 캡처 사이 helper 재사용과 capture-local identity 만료도 검증하지 못했다. 한 번의 helper load와 취소 callback의 정리 근거는 두 번의 성공 캡처를 대신하지 않는다. 이전 baseline A에는 이미 Text/Shape가 있었으며 이번 실행은 Text 누락을 재현하지 않았다. 별도 semantic·pixel·identity 수락은 실패다.

별도 정리는 후속 terminal을 원래 reservation·취소 digest와 대조한 뒤 진행했다. 원래 worker group이 비었고 debugger 자식이 회수됐음을 확인했다. 같은 PID/start/path/device의 live·untraced 상태와 독립 timer sequence 증가를 읽었다. 원래 claim의 lock과 소유자, 현재 unlocked desktop, host PID/start/path/window, guest foreground와 display를 다시 확인했다. 기존 InputGuard와 DesktopGuard를 사용했고 원래 절대 마감 안에서 정리를 최대 117초로 제한했다. 소유 fixture만 종료·제거했다. target 재실행, debugger 명령, helper unload, 사용자 앱 재시작, 강제 foreground 복원이나 process-group kill은 없었다.

**14:07:41 UTC에 foreground·Simulator·debugger 사용권을 반납했다.** fixture app/data와 선택 기기의 claim은 없었다. 소유 executable은 0개였고 원래 worker group의 live·zombie·unknown 항목도 모두 비었다. 원래 host·guest의 PID/start/path, window와 display는 입력 없는 readback에서 일치했다. 이 정리 성공은 원본 transaction 실패를 바꾸지 않는다.

저장소 쓰기는 이 한국어 부록의 append뿐이다. 기존 문서 prefix의 bytes와 SHA-256을 보존했다. 비공개 증거에는 원본 실패, 별도 후속 terminal·정리, 수락 판정과 current source/build/preparation/artifact SHA-256 manifest를 남겼다. manifest는 자기 자신을 포함하지 않는다. harness·parser·공유 안전 코드·fixture·제품·manifest·전역 앱·`.agent-loop`는 변경하지 않았다. 백업, Git 변경 명령, 게시, 제품 통합과 완료 설치는 하지 않았다. 제품의 기록·재실행 흐름은 여전히 별도 미결정 범위다.


## 2026-11-09 시도 7 — deadline 형식 오류로 입장 전 중단

**수락 실패. 같은 probe의 재계획한 마지막 시도 7/최대 7을 한 번 호출했다.** test owner가 UTC deadline에 소수 초를 포함했으므로 runner가 입장 전에 거절했다. 새 fixture lifetime은 0회이며, 이전 5회와 합친 실제 lifetime은 5회다. 이전 여섯 번의 실패와 원본 증거는 유지한다. 재호출이나 여덟 번째 시도는 수행하지 않았다.

현재 전체 준비 `mac-cu-swiftui-reaping-prep-98gk3o6u/prepared/base`의 입력 hash 149개, Xcode Python 3.9.6/arm64 및 Xcode/LLDB pin 33개, readiness flag 3개를 호출 전에 대조했다. 모두 일치했다. 완료된 준비 명령 18개의 exit 0, native safety 7/7, production helper·거절·상속 진입 경로 5/5와 baseline을 재사용했다. 빌드와 영향받지 않은 검사는 반복하지 않았다. 선택한 일반 기기는 iOS 27.2 / 24B114에서 이미 boot된 상태였다. 기존 claim과 준비 executable 잔여가 없고 fixture app/data가 없음을 확인했다. 입력·focus·unlocked 검사도 유지했다.

실제 호출은 `/usr/bin/python3 -B`로 2026-11-09T14:44:19.461942Z에 시작했다. 기록한 deadline은 `2026-11-09T14:55:19.461942Z`이며 cap 660초와 보호 cleanup 117초를 선언했다. 그러나 `session.received_deadline`은 정수 초 형식 `YYYY-MM-DDTHH:MM:SSZ`만 허용한다. 원본 오류는 `ValueError: deadline must be UTC YYYY-MM-DDTHH:MM:SSZ`다. runner는 약 0.422초 뒤 exit 1로 끝났다. 이 호출 형식 오류는 test owner의 실행 오류이며, 준비된 reaper 수정의 runtime 실패를 입증하지 않는다. deadline·가드·수락 기준을 바꾸거나 오류를 고쳐 재실행하지 않았다.

실패 지점은 `session.parent` 호출 전이다. live 출력 디렉터리, worker/process group, claim, fixture 설치·실행, debugger와 reaper thread가 생성되지 않았다. typed external graph와 direct `makeViewDebugData`는 모두 `notCalled`다. `nil`, `errorObject`, `rootArray` 결과가 관찰됐다고 기록하지 않는다. 실제 raw 계층·보존 property·typed/direct bytes 비교·동일 target join·detach 후 callback·pool/context·helper 재사용 근거는 없다. 새로운 A/B PNG와 독립 screen PNG, 6개 ROI 판정, charlie→delta 변경, 완료된 capture identity join 및 이전 selection/token 만료도 검증하지 못했다. baseline A에는 이미 Text/Shape가 있었고 UIKit representable만 없었다는 기존 관찰은 유지한다. B는 hosting subtree 전체의 composite라는 의미를 유지한다.

2026-11-09T14:45:02.451677Z의 별도 읽기 검증에서 claim 전체가 이전과 같고 선택 claim이 없음을 확인했다. 소유 fixture app/data와 준비 executable 잔여는 0이었다. 원래 host/guest foreground의 PID·start·path·bundle, host window, display와 unlocked 상태도 일치했다. custody는 취득하지 않았으며 남은 custody가 없다. cleanup mutation, foreground 복원, 사용자 앱 재실행은 필요하지 않았고 수행하지 않았다.

원본 invocation·runner log·exit 기록은 불변으로 보존했다. 생성되지 않은 session/parent/experiment transaction을 만들거나 성공으로 고치지 않았다. 별도 `offline-acceptance.json`은 `passed=false`이며 관찰 사실, 수락 predicate와 누락 근거를 구분한다. 저장소 변경은 이 한국어 부록의 append뿐이다. 기존 문서 prefix의 bytes와 SHA-256을 유지했다. source/build/preparation/prior-evidence/artifact manifest와 최종 배포 검증·공백 검사의 전체 로그는 비공개 handoff에 보존한다. harness·parser·fixture·공유 안전 코드·제품·manifest·`.agent-loop`·전역 앱은 변경하지 않았다. 설치·재시작·백업·설정·profile·Keychain·plugin/cache 변경, commit/push/publication은 수행하지 않았다. 제품의 기록·재실행 흐름은 여전히 범위 밖이다.


## 2026-11-09 추가 시도 8: lead 실행과 Python worker 종료 경합

시도 7의 소수 초 deadline 인자 오류를 수정했다. lead가 `strftime`으로 초 단위 UTC를 생성하고 실제 `received_deadline` 파서와 admission을 검증한 뒤 runner를 한 번 실행했다. 준비 입력 149개는 변경되지 않았다. 기존 실패 기록을 보존하고 시도 8/max8로 명시했다. 새 fixture lifetime은 1회이며 누적 6회다.

debugserver는 새 reaper가 exit 0으로 회수했다. 같은 parent 표본에서도 debugserver는 `goneOrZombie`였다. 그러나 종료 중인 LLDB Python worker의 짧은 `(Python)` 표본에서 fresh identity를 확인하지 못해 가드가 중단했다. 정확한 실패 syscall과 errno는 이번에도 기록되지 않았다. LLDB detach·close와 두 직접 자식의 회수는 완료됐다. 이는 전체 관찰 경합이 해결됐다는 근거가 아니다.

후속 channel의 terminal은 `cancelledBeforeEntry`다. helper 범위 안의 main-thread callback, untraced 상태, pool exit와 context 0을 확인했다. typed/direct graph와 PNG 호출은 실행되지 않았다. branch 변경과 capture identity 수락도 미완료다. 원본 session/experiment의 실패 값과 파일은 변경하지 않았다.

별도 cleanup은 원래 deadline과 117초 상한 안에서 동일 PID/start/path/device, 원래 claim, 취소된 작업의 digest와 terminal, reaped debugger children, empty worker group, 살아 있는 untraced fixture의 heartbeat 및 입력·포커스 가드를 확인했다. 소유 fixture만 종료·제거했다. app/data 부재, 원래 host/guest/display 복원, claim 해제와 잔여 프로세스 0을 확인했다. 실제 정리 완료는 2026-11-09 14:51:06 UTC다. 강제 foreground 복원이나 사용자 앱 재실행은 하지 않았다.

실기 검증은 8/8 실패 상태로 유지한다. 개별 자식의 회수만으로 일관되지 않은 프로세스 관찰을 해결하지 못했다. 다음 검토는 기존 process-read 제한 안에서 관찰을 완료하고, 끝까지 확인할 수 없는 상태는 계속 거절하는 감시 구조다. 추가 실기 실행, 제품 통합 또는 전역 설치는 수행하지 않았다.


## 2026-11-10 시도 9 — 설치 전 parent/group 관찰 거절

**수락 실패. 재계획한 attempt9/max9에서 기존 runner를 한 번 호출했고, 새 fixture lifetime은 0회다. 누적 lifetime은 6회이며 실기 검증은 FAILED9/9다.** whole-observation 수정, 독립 리뷰의 부모 문맥 수정, 새 전체 준비와 현재 CLI guard를 근거로 같은 단위를 실행했다. 이전 실패 8회는 유지했다. 열 번째 호출이나 재시도는 하지 않았다.

준비 base는 `/tmp/mac-cu-swiftui-headless-prep-s4r6l0ha/prepared/base`다. 선언된 pin 149개, supplemental source 231개와 correction source 10개를 대조했다. 중복을 합친 source/binary 263개가 실행 전후 일치했다. 준비 manifest에서 빠진 native-safety test source는 supplemental pin으로 확인했다. 현재 Xcode Python 3.9.6 arm64/LLDB proof의 context pin 33개와 별도 proof 일치도 검증했다. 기존 native safety 7개, 준비 18단계, dispatch 5개, canonical reuse 57개와 actual CLI guard 성공 증거를 재사용했다. 준비물이나 manifest를 다시 만들거나 수정하지 않았다.

기존 no-flag baseline을 실제 `runner.select_variant(True, baseline)`으로 검증했다. 지정 기기는 이미 boot된 iOS 27.2 / 24B114였다. 선택 claim, fixture app/data와 준비 executable 잔여는 없었다. 원래 desktop은 unlocked였고 focus guard와 정적 portrait 검사가 통과했다. `/usr/bin/python3 -B`와 변경하지 않은 runner CLI로 2026-11-09 16:03:54.333 UTC에 시작했다. deadline은 `strftime`으로 만든 `2026-11-09T16:14:54Z`다. 실제 `received_deadline` 및 `session_budget` admission을 호출 전에 검증했다. cap 660초, 보호 cleanup 117초와 세션 `CLOCK_MONOTONIC`을 유지했다. 부모 예외 경로에는 transmission 성공 flag가 없지만, 별도 평가에서 기록된 부모·worker의 절대 deadline 일치, 양수 dispatch 지연과 잔여 시간 감소를 확인했다.

부모는 `IdentityChanged('process parent/group changed during observation')`를 기록하고 소유 worker에 협조 중단을 요청했다. worker는 `InterruptedError('cancelled before install')`로 중단했다. runner는 16:03:58.695 UTC에 exit 1로 끝났다. 부모가 기록한 경과 시간은 약 4.69초다. 관찰 로그의 PID 67015는 `proc_pidinfo`와 `kill0`의 ESRCH 및 `goneOrZombie`를 기록했다. 그러나 parent/group 거절을 일으킨 행과 PID는 저장되지 않았다. 따라서 이 PID의 종료가 거절 원인이라고 단정하지 않는다. 이전 간헐적 `ps` 지연의 원인도 이번 실행으로 확정하지 않는다.

fixture 설치·실행, attach, helper load, callback, 실제 typed graph와 direct `makeViewDebugData`, branch 변경은 실행하지 않았다. 실제 캡처는 0회다. raw root/container/Text/Shape/representable 관계, ABI·구조 비교, capture/device-boot 연결, capture-local identity 만료, helper 재사용과 pool/context는 미검증이다. 새 A/B/독립 screen PNG가 없어 ROI 판정과 `view_image` 검사를 수행하지 않았다. 의미·픽셀·identity 수락은 각각 미실행이며 통합 수락은 실패다. 기존 A가 Text/Shape를 포함했고 UIKit witness만 달랐다는 사실을 유지한다. B는 단일 `hostingSubtreeComposite`이며 per-node SwiftUI texture가 아니다.

runner는 원래 host/guest의 PID·start·path·bundle, host window와 display 일치를 확인하고 claim을 해제했다. fixture를 설치하지 않았으므로 종료·제거는 필요하지 않았다. 뒤이은 독립 desktop 검사는 host focus 변경을 감지하여 read-only probe 실행 전에 중단했다. 강제 foreground 복원이나 재검사를 하지 않았다. 따라서 종료 시점 복원은 runner 증거로 확인되며 이후 현재 foreground 일치는 주장하지 않는다. 16:05:15.972 UTC의 독립 읽기에서 claim 전체가 원래 값과 같고, fixture app/data가 없으며, 정확한 준비 executable 2종의 잔여가 각각 0이고 worker group의 live/zombie/unknown이 모두 0임을 확인했다. **custody는 해제됐다.** pose 입력은 없었고 framebuffer portrait는 runner에서 같았다. 물리 pose는 직접 관찰하지 않았다.

비공개 증거는 `/private/tmp/mac-cu-swiftui-attempt9-jhptuxf7`에 보존했다. `invocation.json`에 정확한 argv와 파서·예산 증거가 있고, `live/parent.json`, `live/session.json`과 빈 `runner.log`는 원본 그대로다. 생성되지 않은 experiment나 capture transaction을 만들지 않았다. `offline-acceptance.json`은 별도 실패 평가다. source/binary 및 기존 증거 785개 파일의 전후 hash를 비교했고 변경이 없었다. 이 부록은 기존 문서 prefix의 bytes와 SHA-256을 보존했다. 별도 문서 hash, 배포 validator와 diff 검사 결과는 비공개 handoff에 기록한다. 소스·manifest·다른 문서·`.agent-loop`, 전역 앱, 설정·profile·Keychain·plugin을 변경하지 않았다. 제품 통합·UI·설치와 기록 workflow 결정은 후속 root 작업이다.


## 2026-11-10 시도 10 — 설치 전 별도 process group 거절

**수락 실패. 같은 검증 단위의 attempt10/max10에서 기존 runner를 정확히 한 번 실행했다. 새 fixture lifetime은 0회이며 누적 lifetime은 6회다. 결과는 FAILED10/10이다.** 앞선 실패 기록을 보존했다. 열한 번째 호출이나 재시도는 하지 않았다.

현재 `mac-cu-swiftui-isolated-prep-vk2ueum9/prepared/base`의 준비 pin 149개, supplemental source 232개와 correction source 10개를 호출 전에 대조했다. 모두 일치했다. 준비에 포함된 Xcode Python 3.9.6 arm64/LLDB proof와 별도 proof도 일치했다. 완료된 전체 준비 18단계, native safety 7개, dispatch 5개, 현재 headless 188개와 unchanged runner guard 성공 근거를 재사용했다. 재빌드, manifest 수정, headless 검사 재실행은 하지 않았다. 기존 no-flag baseline은 실제 `runner.select_variant(True, baseline)`으로 검증했다.

지정된 기존 일반 기기는 iOS 27.2 / 24B114에서 이미 boot돼 있었다. 선택 claim, fixture app/data와 준비 executable 잔여는 없었다. 정적 portrait, unlocked desktop과 input/focus 가드를 확인했다. `/usr/bin/python3 -B` 호출은 2026-11-09 16:42:07.399 UTC에 시작했다. `strftime`으로 생성한 deadline은 `2026-11-09T16:53:07Z`다. 실제 `received_deadline`과 `session_budget`을 호출 전에 검증했다. 660초 상한, 보호 cleanup 117초와 `CLOCK_MONOTONIC`을 유지했다. 사후 읽기에서도 parent/worker deadline 일치, 양수 dispatch 지연과 잔여 시간 감소를 확인했다.

parent는 `IdentityChanged('unexpected separate process group')`를 기록했다. 이번에는 거절 표본이 남았다. `group admission`의 PID 38361, parent 38358, group 38361이며 path는 선택한 Xcode Python의 `Resources/Python.app/Contents/MacOS/Python`이다. 이 표본에는 start identity가 없다. 따라서 그 프로세스의 생성 주체나 전체 실행 경로를 확정하지 않는다. 별도 PID 38356의 ESRCH와 `goneOrZombie` 기록은 거절 원인에 귀속하지 않는다. 시도 9의 rejecting PID는 계속 UNKNOWN이며, 당시 별도 ESRCH67015도 원인으로 귀속하지 않는다. 이전 간헐적 ps 지연도 설명되지 않은 상태다.

worker는 `InterruptedError('cancelled before install')`로 중단했다. runner는 16:42:11.562 UTC에 exit 1로 종료했다. 원본 session의 `passed=false`, parent 오류와 cooperative TERM 기록을 그대로 보존했다. fixture 설치·실행, attach, helper load, callback, typed external graph, direct `makeViewDebugData`, branch 변경은 실행하지 않았다. typed/direct stage는 모두 `notCalled`다. 실제 ABI·bytes·root/container/Text/Shape/representable 관계, geometry/property 출처와 구조 비교는 미검증이다. 새 A/B/독립 screen PNG가 없으므로 원본 이미지 관찰과 고정 ROI/pixel 평가도 미실행이다. 기존 A에 Text/Shape가 있었고 UIKit witness만 달랐다는 구분을 유지한다. B는 단일 `hostingSubtreeComposite`이며 per-node SwiftUI texture가 아니다.

동일 lifetime의 두 캡처, 실제 capture/hosting/device-boot 연결, helper 재사용과 callback pool/context 정리는 관찰하지 못했다. collector의 `captureIdentity`는 request operationID/nodeGeneration을 결과 필드에 넣고 operationID 차이와 helper 재사용을 검사한다. 이 필드 이름만으로 실제 selection 또는 permission invalidation을 증명할 수 없다. 해당 branch 자체가 이번에는 실행되지 않았다. 제품 Inspector의 selection/permission invalidation은 후속 필수 통합 검사로 남는다. offline feasibility도 외부 graph·rendering 근거가 없어 입증되지 않았다.

runner는 원래 host/guest identity, window와 display가 같은지 확인한 뒤 claim을 해제했다. 설치가 없었으므로 fixture 종료·제거는 수행하지 않았다. 독립 읽기에서 claim 전체 불변, 선택 claim 부재, fixture app/data 부재, 정확한 준비 executable 잔여 0, worker group의 live/zombie/unknown 0을 확인했다. 기록된 runner·worker·거절 표본과 parent PID도 더 이상 없었다. 현재 InputGuard와 DesktopGuard 아래에서 원래 host/guest의 PID/start/path/bundle, host window, display와 unlocked 상태 일치를 확인했다. 선택 claim lock의 nonblocking exclusive 획득도 가능했다. 강제 foreground, 사용자 앱 재시작, 광범위 signal이나 추가 cleanup mutation은 없었다. 물리 pose는 직접 관찰하지 않았으며 display portrait와 입력 없음만 확인했다.

**2026-11-09 16:42:43 UTC에 native·foreground·Simulator custody를 반납했다.** 원본 runtime 실패는 정리 성공과 별개다. 의미·픽셀·capture association 수락은 각각 미실행이며 전체 수락은 실패다. 기록 UX 결정, 제품 통합·UI·설치는 root의 후속 범위다.

비공개 증거는 `/private/tmp/mac-cu-swiftui-attempt10-upyumw71`에 보존했다. 정확한 argv, parser budget, current pins, 원본 transaction hash, 별도 offline 평가와 독립 custody/readback을 포함한다. 시도 9와 correction/review/preparation의 기존 증거를 전후 hash로 대조했다. 저장소 쓰기는 이 부록의 append뿐이며 기존 prefix의 bytes와 SHA-256을 유지했다. harness·parser·fixture·공유 guard·제품·manifest·다른 문서·`.agent-loop`는 수정하지 않았다. 전역 설치·재시작, 백업, 설정·profile·Keychain·plugin 변경, Git 게시도 하지 않았다.


### 2026-11-10 — attempt11/max11 작업자 사전 검사 중단

이번 작업자는 준비된 입력을 검증한 뒤 private 사전 검사에서 중단했다.
`remote_watchdog`에 없는 `processes` API를 호출하여 `AttributeError`가 발생했다.
이는 작업자의 검사 코드 오류다. SwiftUI runner와 native target 동작의 실패로 분류하지 않는다.
재시도 금지 조건에 따라 runner를 호출하지 않았다. 실제 runner 호출은 0회이고 새 fixture lifetime은 0개다.
이전 FAILED10/10과 누적 fixture lifetime 6개는 그대로 유지한다. attempt11 장부의 최종 분류는 부모가 결정한다.

사전 확인에서 이전 private artifact 104개, 현재 prepared pin 152개, 검토된 source pin 3개의 SHA-256이 일치했다.
선택한 Xcode Python/LLDB binding과 `select_variant(True, baseline)` 검증을 통과했다.
CoreDevice wrapper의 expected/installed 버전은 모두 `651.31`이었다.
기존 고정 device의 Booted 상태, device plist hash, 원래 guest identity, 활성 portrait display,
unlocked host와 fixture bundle/data 및 claim 부재를 확인했다. 마지막 executable inventory 검사는 위 API 오류로 완료하지 못했다.
STRICT_SECOND_UTC deadline 생성과 received_deadline/session_budget 검증 단계에는 도달하지 않았다.
660초 상한 및 117초 cleanup reserve를 변경하지 않았다.

독립 최종 readback에서 해당 fixture/probe executable, fixture bundle/data와 device claim이 없었다.
원래 guest의 PID/start/path/device가 유지됐고 traced=false였으며 host는 unlocked였다.
runtime custody를 획득하지 않았으므로 종료·제거·claim 해제 작업은 없었다.
현재 absence는 과거의 관측하지 않은 descendant custody를 증명하지 않는다.

raw runner transaction과 passed flag는 생성되지 않았다. graph·pixel·capture-local identity·helper custody는 미평가다.
외부 graph, A/B PNG, branch mutation, helper load와 callback cleanup을 실행하지 않았다.
feasibility는 미확정이며 제품 Inspector UI/selection/permission invalidation, 일반 앱 지원, 설치 수락을 주장하지 않는다.
사전/사후 source·binary·artifact hash는 일치했다. private 근거는
`/private/tmp/mac-cu-swiftui-attempt11-rydzrovc/`의 HANDOFF와 hash map에 보존한다.


## 2026-11-10 시도 12 — debugger 아래에 보인 검사 대상의 group 거절

시도 11의 private 사전 검사는 존재하지 않는 `remote_watchdog.processes` 호출에서 중단됐다. 실제 runner 호출과 새 fixture lifetime은 모두 0이었다. Lead는 기존 `rows()` API로 호출을 바로잡고 API binding을 먼저 확인했다. canonical source와 준비 입력 152개는 변경하지 않았다. 별도로 기록한 시도 12에서 기존 runner를 한 번 실행했다. 새 소유 fixture lifetime은 1개이며 누적 7개다.

parent는 첫 debugger 준비 단계에서 `unexpected separate process group`으로 중단했다. 거절된 표본의 PID와 실행 경로는 검사 대상 fixture와 일치했다. 표본의 parent는 같은 세션의 debugserver였으며 group은 fixture의 group이었다. 이 표본에서 새 kernel start 조회는 끝나지 않았다. 같은 lifetime의 request, 이전 identity, debugger recovery 및 이후 독립 identity는 일치했다. 현재 감시기는 검사 대상도 worker 후손으로 따라가 helper group 규칙을 적용한다. 이 실행은 해당 분류 경계를 다시 검증할 근거이며, 일반적인 parent 변경 허용 근거는 아니다.

원본 parent/session 결과는 실패로 보존했다. 후속 독립 조회에서 같은 operation/digest의 `cancelledBetweenStages` terminal을 확인했다. authority는 revoked, 다음 작업은 금지 상태였다. detach와 debugger 자식 reap, callback image/PC와 시간 순서, pool 종료, sentinel remaining 0, operation context 0을 확인했다. 같은 target의 untraced identity와 증가하는 heartbeat도 확인했다. 원래 deadline 안에서 해당 fixture만 종료·삭제했다. 원래 SpringBoard·호스트·창·display 상태가 일치했고 선택 기기의 claim을 해제했다. 원본 실패 기록은 변경하지 않았다.

늦게 보존한 typed graph는 1,210,085 bytes이며 현재 parser의 오프라인 판정은 `rootArray`, root 1개, 선언형 node 102개, 최대 선언형 depth 35다. 이 출력은 취소된 실행의 부분 근거다. direct provider, A/B 이미지, 독립 화면, branch 변경 및 최종 hosting association은 실행하지 않았다. graph 출력만으로 전체 수집이나 제품 지원을 합격 처리하지 않는다. 수집 runner는 다시 실행하지 않았다.
