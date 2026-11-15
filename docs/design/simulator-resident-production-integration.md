# 현재 앱의 뷰 검사 실행 경계

## 결정과 근거

UIKit 수집과 편집은 컴파일한 resident helper의 main-queue callback에서 실행한다. LLDB는 정확한 helper 이미지를 로드하고, 고정 요청을 복사하는 짧은 bootstrap을 호출한 뒤 detach한다. 뷰 탐색, texture 수집, getter, setter와 readback을 LLDB expression 안에서 실행하지 않는다.

2026-11-09의 새 A/B 실험은 이 실행 경계를 검증했다. A는 쓰기 후 예외를 잡았고 원시 결과를 `uncertain`으로 유지했다. B는 유한 setter 진입 후 2.279ms에 host 권한을 철회했다. 반환한 setter의 원시 결과는 `enteredUnverified`였다. 두 경우 모두 callback의 pool에서 sentinel이 해제됐고, terminal 발행 전에 operation context가 0개가 됐다. 독립 replacement 동작은 원래 뷰의 weak 참조 해제와 한 번의 deallocation을 확인했다. 각 case, session, parent와 정리 결과가 통과했다.

리드는 `/private/tmp/mac-cu-resident-qualification-20261109-f/HANDOFF.md`의 원시 join과 정리 기록을 확인했다. 소스·바이너리 해시 120개, 최종 소스 해시 12개와 artifact 해시 199개가 일치했다. 이 근거는 실행 경계의 선택을 뒷받침한다. 이후 일반 앱과 패키징 검증 결과는 아래 후속 절에 기록한다. UI 연결 검증은 별도 범위다.

## 구현 범위

- schema 2의 capture/edit/revert/release, weak registry, operation ID·sequence, durable ledger와 검증된 epoch 전환을 유지한다. 사용자 문자열을 실행 코드, selector 또는 KVC로 변환하지 않는다.
- 같은 operation에서 texture와 편집 token을 만든다. 현재 decoder의 join과 이미지 예산을 유지한다. 이미지가 없으면 원인을 표시하고 생성 성공으로 바꾸지 않는다.
- helper는 canonical 소스에서 빌드하고 서명한다. 생성 dylib를 Git에 추가하지 않는다. 설치와 격리 검증은 같은 build/resource 경로를 사용한다. 제품 런타임은 저장소의 `tests/`를 참조하지 않는다.
- 한 대상 수명에는 검증한 ABI와 이미지 한 개를 사용한다. 다음 요청은 같은 이미지에서 실행한다. 다른 버전이 이미 로드됐으면 새 이미지를 겹쳐 로드하거나 unload하지 않고 명시적으로 거절한다.
- bootstrap은 크기가 제한된 요청을 완전히 복사한다. JIT 주소, callback 또는 호출자 소유 포인터가 callback까지 남지 않는다. callback의 예외 처리, autorelease pool, context 해제와 terminal 발행 순서를 유지한다.
- 실제 읽기·변경은 detach 이후 main queue에서 실행한다. getter·setter·drawing 호출이 반환하지 않으면 host 취소만으로 target 복구를 보장할 수 없다. 취소는 host 권한과 다음 admission을 철회한다. 강제 unwind, pool pop, inverse edit 또는 자동 재실행을 하지 않는다.
- 반복 operation과 release에서도 오래된 request·epoch를 다시 허용하지 않는다. 불확실한 dispatch 또는 callback은 ledger에 남기고 다음 변경을 차단한다. host 재시작으로 차단을 지우지 않는다.

## 일반 앱과 Swift 연결

일반 앱 요청은 fixture validation 경로를 사용하지 않는다. `validationOnly`는 capture에서 정한 값으로 editing context에 보관하고 edit/revert/release까지 유지한다. public 도구 입력으로 qualification을 덮어쓸 수 없다.

host는 현재 선택한 Xcode·LLDB·Simulator runtime, signed debug entitlement, 앱 bundle/executable, PID/start/path/device와 실제 debugger 상태를 확인한다. 시스템 앱, 다른 debugger가 붙은 앱, 불완전하거나 미지원인 identity는 거절한다. 이름만 같은 runtime을 허용하지 않는다. target을 다시 서명하거나 자동으로 재시작하지 않는다.

일반 앱 검증은 기존 `HierarchyFixture`와 다른 bundle을 사용한다. 앱에 mac-cu helper나 등록 SDK를 링크하지 않는다. 제품의 기본 Swift wrapper와 정상 요청으로 캡처하고 hidden/alpha 변경·readback·복원·refresh·release·재열기를 확인한다. helper의 결과와 독립 앱 관측값, PNG, target·debugger 정리를 각각 기록한다. 검증한 UIKit/SwiftUI 진입 범위만 지원한다고 보고한다.

## 완료 경계

필요한 결과는 새 실행 경계의 headless 회귀 검사, 보호된 실제 일반 앱 검사, LCD에서 연 3D 창의 캡처·선택·편집·복원, 필수 저장소 검사와 전역 앱 교체다. 아래 절은 완료한 backend 검증을 기록한다. 전체 제품 완료에는 LCD/3D 검증과 전역 앱 교체가 남아 있다.

## Implemented contract and qualification — 2026-11-09

The schema-2 backend is implemented and the **normal UIKit route passed** through
`simulatorCaptureEditableViews`, `simulatorEditView`, `simulatorRevertView` and
`simulatorReleaseViews`, with `validationOnly == false`. This is backend and
ordinary-app evidence. Integrated LCD/3D window verification and global installation
remain the lead's work; this worker did neither.

- `view-capture/operation.inc` is the single shared implementation of weak registry,
  bounded graph/texture collection, typed compare/set/readback, guarded undo,
  durable operation receipts and verified-release epoch turnover. `resident.mm`
  compiles it with explicit MRC and native exceptions. `edit.expr` is now a thin
  headless regression wrapper; the production schema-2 LLDB expression path refuses
  execution. Process-free module declarations do not execute target work.
- `resident_protocol.py`, `resident_support.py` and `resident_transport.py` provide
  the private ABI-2 copied-byte channel, exact selected-toolchain/runtime/signature
  admission and custody-preserving bootstrap. The only executable expression calls
  `mac_cu_resident_submit_v2` at its verified image symbol. No JIT object/callback
  pointer survives submission. The native callback requires an untraced main thread,
  catches inside its local autorelease pool, stages bounded C receipt bytes, drains
  the pool, frees the operation context and then publishes terminal evidence.
- One image is pinned per PID/start/path/device lifetime. Later operations and
  owner/epoch turnover reuse it without `LoadImage`. The complete reserved export
  namespace, image UUID/path/hash and ABI are checked. Unknown/duplicate/version-
  conflicting residents refuse before another load; no unload or anchor reset exists.
  The helper stays resident until natural target exit. Private transport diagnostics
  are retained in the app's owned cache and copied to host evidence directories.
- A durable reservation precedes debugger creation. Cancellation durably quarantines
  host authority before publishing its marker. A returning setter cancelled after
  entry yields `enteredUnverified`; a caught post-write exception yields `uncertain`.
  Neither grants undo or later write authority. Ambiguous loader/submission calls
  retain the actual debugger/transport and children. Missing native terminal evidence
  remains pending/uncertain; a deadline is never target-recovery evidence.
- `SimulatorViewEditingContext.validationOnly` is immutable. Capture results attest
  the route, and refresh/edit/revert/release retain it. Existing API names remain.
  `neverDispatched: true` identifies host admission refusal before the transport
  boundary. An evidence directory alone does not imply target dispatch. Exceptions
  escaping after that boundary preserve uncertainty. Inspector/model/coordinator,
  AX and SimulatorWindow sources were not changed by this worker.

### Build and resource entry

`native_build.build_view_capture_resources(destination)` copies canonical resources,
compiles `resident.mm` against the selected iPhoneSimulator SDK, signs the generated
arm64 dylib and emits `resident-build.json`. The manifest records image UUID/hash/ABI,
source hashes, compiler, SDK, selected LLDB/debugserver hashes and Xcode version.
`setup.py` and isolated fixture/product preparation call this same function. Source
archives contain no generated dylib. Product runtime imports no `tests/` resource.

The ordinary app is `tests/view-resident-product`: a distinct debug bundle with
ordinary UIKit content and independent state/control oracles. It links no mac-cu
helper, SDK or registration code and is outside the HierarchyFixture bundle
allowlist. Its protected runner calls the real normal Swift wrappers and preserves
selected-device claims, exact lifetimes, display/windows, input/focus guards and
parent executable budgets. Use `xcrun python3` for runtime LLDB; Homebrew Python 3.15
is not the selected extension's interpreter.

### Actual supported entry and measured limitation

The qualified tuple is **arm64, Xcode 27.2 / 27B48, iOS Simulator 27.2 / 24B114**.
Admission verifies the actual selected SDK/LLDB hashes, registered app container,
strict bundle signature and the signed Simulator entitlement
`com.apple.security.get-task-allow`. It also verifies already-running/untraced
PID/start/path/device identity. System apps and another debugger's app are refused.
No target is re-signed, auto-launched or restarted by the product.

The qualified ordinary UIKit entry is the exact kernel Mach wait → CoreFoundation
run loop → `UIApplicationMain` → that executable's C `main` → selected runtime
`start_sim` → host `start` chain. Active application callbacks are rejected. An
initial run was correctly rejected inside the independent oracle's file write;
its app/debugger/claim were fully cleaned before another lifetime was admitted.
The oracle's disk writes were then moved off main, without widening the entry check.

초기 SwiftUI 검사(`swiftui-b`)는 helper 로드 전에 startup allowlist에서 거절됐다.
이 과거 기록은 그대로 보존한다. 후속 검사는 측정한 표준 SwiftUI idle 진입을
별도 구조 검증으로 허용한다. 정확한 kernel/CF/UIApplicationMain prefix 다음에
동일한 selected runtime의 SwiftUI framework startup symbol 세 개가 연속해야 한다.
그다음 실제 앱 실행 파일의 compiler-generated `$main` 하나와 C `main`, 동일한
runtime의 `start_sim`, host `start`가 와야 한다. 삽입 callback, 추가 앱 frame,
중첩 run loop, 순서 변경과 다른 이미지 경로는 거절한다.

`$main`은 앱 이름을 고정하지 않는다. 지원 범위는 ASCII 식별자로 구성된
최상위 `Module.Type` nominal App이다. LLDB가 읽은 symbol의 demangled 이름과
frame 이름, generated-main mangled suffix, symbol의 실행 파일 경로, symbol 주소
범위 안의 frame PC를 함께 검사한다. mangling substitution은 LLDB의 실제 symbol
정보로 연결한다. 임의의 SwiftUI/app wildcard나 target expression으로 검증하지 않는다.
Unicode 식별자, nested/generic App과 다른 startup 형태는 이 근거로 지원하지 않는다.
기존 UIKit 진입 정책은 유지한다.

### Acceptance and evidence boundary

The final normal UIKit sequence passed ten operations: textured capture, hidden
apply/readback, exact replay with zero duplicate writes, hidden restore, alpha
apply/readback/restore, refresh with fresh tokens, verified release, new-owner fresh
capture and final release. The initial operation loaded one helper; every later
native operation reused it. The final ledger retained verified epoch retirement.
All eight successful captures across accepted cases produced eight validated,
current-process/token-bound PNG assets each. Representative assets and the actual
app screenshot were visually inspected.

Weak-deallocated, reparented and expected-value-conflict cases refused before a
setter. Separate final throw-after-write and finite post-entry cancellation cases
proved one original-generation setter, sentinel deallocation between native work
completion and pool exit, zero terminal contexts, original weak clearing and one
original deallocation, main-queue progress, raw uncertain outcomes and no authority
resurrection. Cancellation revoked host authority **40.865 ms** after independent
finite-setter entry. Each final session restored exact prior state, removed only
its owned app/data, released its claim and left an empty process group.

The archived verifier passed **142 joins** over **22 native operations**, eight
captures and 64 assets. Headless evidence includes 61 Python capture/edit/ledger
checks, 1,454 shared-operation assertions, both pool-mode controls, Swift API and
PNG decoder checks, 26 protected-session checks, six native-safety checks, ten
resident protocol/custody checks and distribution validation. These are separate
from actual runtime evidence. Earlier failed sessions remain failed, including a
pre-launch transient-tool observation failure and a host-only-refusal classification
failure. The latter was reconciled read-only and cleaned within its original deadline;
the final throw/cancel sessions passed after the narrow receipt/harness fix.

Private command/log/receipt/oracle/PNG/hash index:
`/private/tmp/mac-cu-production-resident-20261109-a/HANDOFF.md`.
Final UIKit preparation: `/private/tmp/mac-cu-resident-product-host-20261109-h`.
Measured SwiftUI preparation: `/private/tmp/mac-cu-resident-product-swiftui-20261109-b`.

Unchanged limits: geometry/LCD alignment remains unverified; private texture semantics,
protected surfaces and arbitrary app entry shapes are not generalized from these
results. Nonreturning app callbacks were not stressed and cannot be forcibly cleaned.
An initial refusal before registry creation does not fabricate a release proof or
reset durable authority; unsupported reconciliation may require natural target restart.
No global install/setup execution, profile/Keychain/config mutation, manifest/version
change, commit, push or publication was performed by this worker.

### 표준 SwiftUI idle 진입의 후속 실측 — 2026-11-09

같은 **arm64 / Xcode 27B48 / iOS Simulator 24B114**에서 새 preparation과
`validationOnly: false` wrapper로 실제 수집을 수행했다. capture, hidden 적용·readback,
중복 replay, hidden 복원, alpha 적용·readback·복원, refresh, release,
새 owner의 capture와 최종 release가 통과했다. 요청은 총 10개이며 replay를 제외한
native operation은 9개다. 캡처 3회에서 각 7개, 총 21개 PNG를 검증했다.
helper는 첫 요청에서 한 번 로드됐고 이후 요청에서 재사용됐다. native helper의
파일 바이트와 UUID는 이전 UIKit/SwiftUI preparation과 동일하다.

실제 device screenshot과 texture를 비교했다. `UIViewRepresentable`의 teal 카드
texture는 화면의 카드와 일치했다. `_UIHostingView` texture는 흰색으로 수집됐으며,
화면에 보이는 SwiftUI `Text` 두 개는 그 texture에 나타나지 않았다. 계층은
UIKit window, hosting view, representable host와 실제 UIView 경계를 나타낸다.
모든 value-type SwiftUI View node나 SwiftUI render surface를 노출한다고 주장하지 않는다.
따라서 이번 검증은 표준 SwiftUI 앱 진입과 그 안의 UIKit 수집·편집을 지원하는 근거다.
SwiftUI 전체 화면 texture 충실도와 LCD/3D 합성 검증은 별도 범위다.

원시 request digest, detach/callback/pool 순서, image PC/UUID, token/PNG 연결,
재실행 방지와 epoch 전환을 독립 검사한 50개 조건이 통과했다. session과 parent가
통과했고 기존 host/guest 수명·display·window 복원이 확인됐다. 소유한 앱과 data만
제거했고 debugger children과 process group을 정리했으며 claim을 해제했다.

Python capture/edit/product 회귀 75개와 native safety 6개, host helper/unknown/
inherited-entry route, headless session guard와 distribution 검사가 통과했다.
native 소스를 변경하지 않았으므로 기존 finite fault 검증은 다시 실행하지 않았다.
새 근거, 정확한 명령, 원시 기록, PNG와 rooted hash 목록은
`/private/tmp/mac-cu-swiftui-qualified-20261109-a/HANDOFF.md`에 있다.
과거 `swiftui-b` 거절 기록은 수정하지 않았다. 전역 설치와 LCD/3D 검증은 리드가 수행한다.
