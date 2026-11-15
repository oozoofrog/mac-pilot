# UIKit 뷰 캡처 API

## 일반 앱의 3D 검사: schema 2

현재 3D 창은 `simulatorCaptureEditableViews(_:cancellation:)`를 사용한다. 기본값 `validationOnly == false`가 일반 앱 경로다. 결과의 `SimulatorViewEditingContext`는 대상 수명, owner·inspection·epoch·capture ID와 validation 경로를 유지한다. `simulatorEditView`, `simulatorRevertView`, `simulatorReleaseViews`는 이 context를 사용한다. 모든 호출은 main thread 밖에서 실행한다.

LLDB는 서명과 hash를 확인한 resident helper를 한 번 로드하고 고정 요청을 복사한 뒤 detach한다. helper가 앱의 main queue에서 캡처·편집을 실행한다. 편집은 `hidden`과 유한한 `alpha` 0...1로 제한한다. 약한 참조, 현재 계층과 예상 이전 값을 다시 확인하며 주소나 사용자 문자열을 실행 코드로 사용하지 않는다. 텍스처와 편집 token은 같은 operation에서 연결한다.

취소는 host의 실행 권한을 철회한다. 쓰기 후 예외·결과 유실은 불확실 상태를 유지하며 자동 재실행이나 역변경을 하지 않는다. local pool과 operation context가 해제된 뒤 terminal 결과를 발행한다. 반환하지 않는 앱 callback의 복구를 host timeout으로 보장하지 않는다. helper는 자연스러운 앱 종료까지 남으며, 다른 버전이 이미 로드돼 있으면 새 helper를 겹쳐 로드하지 않는다.

지원된 조합은 arm64 / Xcode 27.2 build 27B48 / iOS Simulator 27.2 build 24B114다. 현재 앱의 서명된 `com.apple.security.get-task-allow`, 실제 container, PID/start/path/device와 debugger 상태를 확인한다. 확인된 UIKit C-main과 표준 SwiftUI startup을 지원한다. SwiftUI에서는 내부 UIKit 계층과 편집을 확인했으며, hosting texture의 텍스트 누락과 SwiftUI 값 타입 노드 미노출을 제한으로 표시한다.

`native_build.build_view_capture_resources(destination)`가 canonical 소스에서 helper를 빌드·서명하고 리소스 manifest를 만든다. setup과 격리 검증은 같은 진입점을 사용한다. 저장소에는 생성 dylib를 넣지 않으며, 제품 런타임은 `tests/`에 의존하지 않는다.

[제품 통합 계약](design/simulator-resident-production-integration.md)에 현재 데이터·수명·빌드 계약과 실제 검증을 기록했다. [LCD 사용 흐름](simulator-inspector.md)은 사용자 조작을 설명한다. **아래 내용은 별도의 schema 1 수집 실험과 과거 geometry 검증 기록이다.** 일반 앱의 3D 창이나 schema 2의 실행 경계를 아래 LLDB expression 경로로 바꾸면 안 된다.

## 기존 schema 1 경로와 검증 기록

The production entry is `simulatorCaptureViews(_:cancellation:)` in
[SimulatorViews.swift](../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/SimulatorViews.swift).
It is a synchronous, off-main-thread API with a thread-safe cancellation token,
not a GUI action. Shared Python deadlines use system-wide
`clock_gettime(CLOCK_MONOTONIC)` rather than Xcode Python 3.9's process-relative
`time.monotonic()`. Supervisor send/worker receive readings and remaining budgets
are retained in results; absence of that clock fails before child creation. `simulatorViewCaptureTarget(pid:deviceID:)` obtains a read-only
PID/start-time/executable/device identity first. Requests accept that typed target,
a text query and a fixture-validation policy; they never accept expressions,
LLDB commands or shell text.

```swift
// Run on an existing background queue. Keep the token in the caller for cancellation.
let cancellation = SimulatorViewCaptureCancellation()
let target = try simulatorViewCaptureTarget(pid: fixturePID, deviceID: claimedUDID)
var request = SimulatorViewCaptureRequest(target: target, query: "Fixture")
request.validationOnly = true
let result = try simulatorCaptureViews(request, cancellation: cancellation)
switch result.status {
case .success: consume(result.content) // Still verified=false, overlayEnabled=false.
case .cancelled, .timeout, .cleanupFailed: report(result.content)
default: report(result.content)
}
// From another queue: cancellation.cancel()
```

`validationOnly` additionally requires the executable `HierarchyFixture` in an
app with bundle ID `local.mac-pilot.hierarchy-fixture`. Ordinary `simulatorViews`
(including MCP `action=views`) returns typed `unavailable` with `isError=true`;
no debugger is started. There is no legacy direct-attach bypass. The existing LCD
legacy schema-1 capture controls remain disabled; the separate 3D window uses schema 2 above. The isolated static portrait fixture has now
passed actual collection, same-target recovery and all seven independent corner
comparisons. This does not validate ordinary apps or LCD presentation.

The canonical setup copies [view-capture/](../mac-computer-use/skills/mac-computer-use/scripts/view-capture/)
into `Contents/Resources/view-capture` before signing. A bare development executable
can instead have that directory adjacent to it. No test-directory or temporary
script is a runtime dependency. Selected Xcode supplies Python, `lldb` and the
exact `LLDB.framework/Resources/debugserver`; no pip packages are required.

## Ownership and cleanup

The Swift caller waits for its directly created supervisor for at most 160 seconds
plus a 3-second final TERM grace. The supervisor has a 45-second work deadline and
100 seconds reserved for cleanup. It starts one exact debugserver directly with a
private AF_UNIX socketpair, verifies its PID/start/path/parent, then starts one
Python LLDB worker with the other FD. The worker uses `ConnectRemote(fd://...)`,
waits for connected state, rechecks the target and separately requests
`RemoteAttachToProcessWithID`. It does not ask LLDB to spawn an implicit server.
There are no retries and the budgets are one supervisor, one worker, one server.

Target identity includes start seconds/microseconds, resolved executable path and
`SIMULATOR_UDID` read through Darwin process APIs. Missing identity, paused or traced
state, a different device, PID reuse and another debugger are rejected. The main
thread must have the unique `com.apple.main-thread` queue name and must return true
from `NSThread.isMainThread`; thread index 1 is insufficient.

Expressions have at most an 8-second timeout, unwind-on-error, exception trapping,
and no fallback that resumes every other thread. A cancellation/deadline watcher
can request `SendAsyncInterrupt`; that void call alone is never success evidence.
An active interrupt control thread prevents concurrent detach/destruction. The
worker attempts `Detach(false)` after every attach attempt, rechecks the same target
running/untraced, and closes its debugger. The supervisor waits up to 70 seconds
for cooperative worker cleanup, then reaps only its own worker/server with bounded
TERM/KILL waits (at most 10 seconds each), and performs a final 5-second same-target
observation. These children are the only force-termination targets. No target app,
historical PID/PGID, other debugger or user process is signalled; no SIGCONT is used.
Failure to prove detach, recovery or child reaping yields `cleanupFailed` and no
published hierarchy. Swift's final supervisor-deadline error also explicitly leaves
recovery unverified and retains the evidence directory.

Preflight and attach are **not atomic**: an external debugger or process exit can
race the final check. Killing an owned helper after a native LLDB hang is not a
rollback guarantee. An app may exit or remain stopped after a debugger failure;
this code reports that state and does not try to repair it with arbitrary signals.
Debugger evaluation executes target code and may have lasting side effects even
when detach succeeds. Prior prototype passes do not establish general app safety.

## Result and geometry contract

Results carry a typed status, capture ID, target lifetime/device, capture time and
runtime capture interval, raw `hierarchy`, `geometry`, and cleanup/recovery reports.
Successful Swift results add `snapshot` (roots, parent IDs, sibling order, original
properties and per-node geometry) and `text` rendered from the **same hierarchy**.
Known statuses include `unavailable`, `unsupported`, `identityUnknown`,
`identityChanged`, `targetUnavailable`, `expressionError`, `cancelled`, `timeout`,
`invalidResponse` and `cleanupFailed`. Invalid caller input may throw before launch.
Failure responses retain a private evidence directory; successful Swift captures
remove their temporary artifacts. Each runtime/worker JSON document is bounded to
16 MiB, geometry to 20,000 views, and the converted hierarchy to 100,000 nodes/512
depth. The text filter is never interpolated into target expressions.

The collector reuses the original undocumented DBGTargetHub property request.
Unsupported runtime classes/selectors, main-thread discovery or response schemas
fail explicitly. Geometry is a separate traversal of actual UIKit windows/subviews
in the same expression: each bounds corner is converted to its UIWindow and then
`UIScreen.fixedCoordinateSpace`, with per-window screen identity/bounds/scale and
scene orientation. Geometry joins only by an exact address within that capture;
missing joins stay unknown. `UIView.frame` is retained as a superview observation,
never summed through ancestors, and AX data is never substituted for UIKit views.

All geometry, snapshots and API success responses retain `verified=false` and
`overlayEnabled=false`. Corners do not establish clipped/visible polygons, 3D
projection support, screenshot timing or LCD alignment. Hierarchy and geometry are
sequential observations while evaluating one expression; other threads can run as
needed by debugger evaluation. The runtime interval makes that limit visible.
The existing fixture oracle is a separate observation, not an atomic counterpart.

The platform contracts are documented by [Apple UIView.frame](https://developer.apple.com/documentation/uikit/uiview/frame),
[Apple UICoordinateSpace](https://developer.apple.com/documentation/uikit/uicoordinatespace),
[LLVM SBProcess](https://lldb.llvm.org/python_api/lldb.SBProcess.html) and
[LLVM SBExpressionOptions](https://lldb.llvm.org/python_api/lldb.SBExpressionOptions.html).
These sources support API use. The fixture observations below separately establish
the limited runtime result; DBGTargetHub remains an undocumented dependency.

## Reproducible headless checks and next live check

From the repository root:

```sh
python3 -B mac-computer-use/tests/check-view-capture.py
python3 -m unittest discover -s scripts/tests -p test_native_check_safety.py -v
python3 scripts/validate_distribution.py
git diff --check
```

The first command tests the actual production state machine with fake transport
and children, expression error/timeout/cancellation/recovery failures and real
read-only Darwin identity/direct-child reaping. It syntax-checks the actual target
expression against the installed Simulator UIKit SDK, builds/signs the canonical
app with output paths redirected to a temporary directory, verifies packaged
resources, runs the Swift API/text/tree/helper roundtrip, and runs isolated
production helper/unknown/inherited-entry dispatch under the existing parent
watchdog (5 seconds per route, exact executable budget 1). It never enters the GUI
route, starts a debugger connection, modifies the installed app or installs a fixture.

After the parent has coordinated a live check, the resource CLI is callable as:

```sh
xcrun python3 -I mac-computer-use/skills/mac-computer-use/scripts/view-capture/capture.py \
  --identity "$fixturePID" "$claimedUDID"
# Copy the returned target dictionary without weakening its identity fields into:
# {"schemaVersion":1,"target":{...},"query":"","validationOnly":true}
# Store request.json in a new private directory (0700), under the parent watchdog.
xcrun python3 -I mac-computer-use/skills/mac-computer-use/scripts/view-capture/capture.py \
  --capture "$privateRun/request.json"
# Cancellation: create $privateRun/cancel; continue waiting for cleanup/result.
```

The fixture launch/claim/restore orchestrator is now in
`tests/view-hierarchy-fixture/session.py`, with a separate build/dispatch preparation
step and headless session checks. It runs exactly one fixture/capture on an already
booted single-screen portrait device. Its required `--deadline YYYY-MM-DDTHH:MM:SSZ` is converted once from UTC to
monotonic time and shared unchanged by parent and worker; receipt + 360 seconds
is an additional maximum. A GUI-free `--guard` exercises the same CLI delivery.
Admission is 285 seconds before that fixed end, reserves its full
163-second lifetime and 117 seconds for fixture/state/claim cleanup, plus 5 seconds
for parent receipts. Too little time fails before claim/install/launch; worker
startup and tool/message delivery never restart the clock. Cancellation at 120 seconds leaves at most 118 seconds of
capture plus 117 seconds of cleanup (235 seconds cooperative grace). The live
CLI-only state probe uses direct-child stop/wait and no process-group signal;
server-exit races are observations, and unknown servers count against the budget. It preserves existing claims,
fixture installations/data and other devices; verifies PID/start/path/device,
restores original foreground/layout, removes only its newly installed fixture,
and releases only its UUID/PID claim. Parent and worker observe combined-session
input event counters without collecting event contents. New input cancels work;
cancelled sessions do not launch the original app to force foreground restoration.
Cleanup can still verify an already-restored original foreground without input.
No process-group signal or fixture wait/reap
is used. Uncertain ownership/recovery is preserved for review. See the
[fixture preparation](../mac-computer-use/tests/view-hierarchy-fixture/README.md) and
[native check safety](native-check-safety.md) before any foreground action.

Actual static portrait UIKit payload/selector compatibility, main-thread detection,
target recovery and nested/scroll/transformed/hidden/off-clip bounds corners passed
in the later fixture run described below. Visible clipping, other orientations,
3D, moving screenshots and actual LCD correspondence remain unverified. Do not
enable ordinary capture or overlays from this limited pass. Global installation
and release remain separate work.

A coordinated fixture session reached the guarded `UIApplicationMain` entry but
terminated with the SDK's missing-UIScene-lifecycle runtime trap before writing its
oracle. No production capture/debugger/server was started. The new fixture and its
data were removed, original foreground/display/host layout was confirmed, the claim
was released and the new session group was empty. The existing fixture now has an
explicit scene manifest/delegate plus private lifecycle diagnostics. Its build,
signature, shared-entry dispatch and manifest/export agreement pass headlessly;
UIKit scene/oracle execution and all hierarchy/coordinate checks still require a
new coordinated run. Ordinary capture and overlays remain disabled.

The next coordinated session reached the fixture foreground and observed its new
oracle file. Its guest display became landscape (`rot90`) while SpringBoard had
reported `rot0`, so the portrait gate correctly stopped before debugger creation.
That does not establish physical device pose. Cleanup/restoration completed again;
no hierarchy or coordinates were collected. The static fixture now supports only
portrait UI, preserves the ready oracle before later gates and copies lifecycle
logs from its own data container. Its actual portrait readback/interface orientation
and the production capture path remain unverified until another coordinated run.

A later fixture run passed portrait/oracle/foreground gates and exercised the real
owned debugserver connection and fixture attach. The first main-thread expression
failed with `module Foundation not found` in the wrapper prefix. Detach, same-lifetime
running/untraced recovery, worker/server reaping and fixture/session restoration
were verified; main-thread BOOL, hierarchy and geometry were not collected.

The compiler setup now creates a target from the exact fixture executable with the
`ios-simulator` platform, derives the SDK through selected Xcode's `xcrun --sdk
iphonesimulator`, validates its SDK metadata/module maps and binds that SDK to the
target/platform. Fixed Foundation/UIKit/Darwin module declarations load into the
target's module context with JIT disabled. They are not inserted into the separately
parsed expression prefix. Imports are refreshed on the selected main-thread frame
after attach, and the original `NSThread.isMainThread` execution proof remains.
Private selector/coordinate-space return types are explicitly annotated for LLDB's
expression type checker; the collection algorithm is unchanged. The target triple,
platform, SDK property and module search settings are retained before/after attach.
These choices use the [LLVM platform API](https://lldb.llvm.org/python_api/lldb.SBPlatform.html)
and the separate [module loader](https://github.com/llvm/llvm-project/blob/main/lldb/source/Plugins/ExpressionParser/Clang/ClangModulesDeclVendor.cpp)
and [expression prefix parser](https://github.com/llvm/llvm-project/blob/main/lldb/source/Plugins/ExpressionParser/Clang/ClangExpressionParser.cpp).

`tests/check-view-capture-modules.py --fixture EXISTING_EXECUTABLE --output NEW_DIR`
runs under Xcode Python and reproduces the prefix error, then checks the actual
main-thread, dlopen and full collector expression types with `sizeof`, JIT disabled
and no process. It exercises the same target/SDK/module helper used in production;
it does not execute expression bodies, load DBGTargetHub in a target, prove the
main-thread BOOL or establish coordinates/LCD alignment. Standalone Clang syntax
checks are a separate result. The SDK/module fix still needs the next coordinated
capture; no extra live retry was performed in the completed window.

A subsequent real fixture capture completed main-thread BOOL confirmation,
DBGTargetHub collection, Swift tree conversion, same-lifetime detach/recovery and
owned child reaping. The coordinate gate failed: all seven views' first corners
matched the independent oracle, while the three constructed corners matched zero
local y inputs. Tree/geometry exact-address joins and expected parents matched;
oracle-before/after/cleanup were identical. This localizes a construction/conversion
path problem, not a proven compiler defect. Original geometry remains unverified.

The next fixture-only collection adds bounded diagnostic observations in the same
expression: raw bounds, CGRect getters, original array/window/screen stages,
repeated helper calls read into locals then arrays, a separate field/aggregate
path through the same conversions, and small fixed scalar checks. These fields do
not replace `corners` or change `.01` validation, verified/overlay flags, capture
count, expression deadline or cleanup. At most 32 fixture-named views receive the
extra observations; the existing 16 MiB and view limits remain. Instrumentation
can change code generation, so a non-reproduction is reported rather than assumed
fixed. The independent fixture oracle is unchanged and has identifiers, not object
addresses.

`tests/check-view-capture-geometry.py --capture EXISTING_DIRECTORY --output NEW_JSON`
replays saved data read-only, collects all seven errors and stage differences, and
runs the original strict gate separately. The session also persists that diagnostic
report before invoking the unchanged strict gate, so the first assertion cannot
hide later views. Raw original captures are never overwritten.

## Measured corner fix and frontend handoff

The instrumented fixture run reproduced the failure before any window/screen
conversion: CGRect fields and scalar getters agreed, but `CGPointMake(17, 29)`
read back as `(17, 0)` both immediately and after array storage. All seven views'
helper paths lost local y; the separate aggregate path matched every oracle
corner exactly through the same window/screen conversions. This establishes the
failing helper/return path in the selected LLDB context, not a vendor/compiler or
specific ABI defect. No array-only loss, common screen offset or clip-only error
was observed.

The primary collector now reads the existing CGRect min/max getters into scalars
and initializes CGPoint aggregates directly. It preserves corner order, the
original first `bounds.origin`, getter semantics, window/screen conversion,
0.01-point gate and all verification flags. The next real run passed all seven
views with zero error, 14 hierarchy/geometry nodes, exact within-capture address
joins, no missing geometry, expected parents/hidden/clips flags, main-thread BOOL,
DBGTargetHub and the production Swift conversion. The helper diagnostic still
lost y in that successful run, so the result is an observed path-specific repair.
Both runs verified same-lifetime detach/recovery, direct child reaping, new-fixture
bundle/data removal, original foreground/display/host-layout restoration, claim
release and an empty new session group. The successful bounded session took about
21 seconds. Historical zombies are outside that group and were not signalled.

For the next frontend integration, retain these distinct inputs:

- Identity is `(captureID, target PID/start/path/device, object address)`; exact
  tree/geometry joins are valid only in that captured lifetime. The independent
  oracle has unique identifiers and parents, not object addresses.
- Corners are ordered top-left, top-right, bottom-right, bottom-left in each local
  bounds, then converted to `UIScreen.fixedCoordinateSpace` **points**. The tested
  portrait screen was 402 × 874 points, interface orientation 1, scale/nativeScale 3;
  its screenshot was 1206 × 2622 pixels. Multiplying by 3 explains dimensions;
  it does not prove pixel content alignment or atomic timing.
- Existing `ActiveScreen.rotation` is host presentation; `guestRotation` is guest
  readback. `presentingGuestFrame` consumes guest-oriented AX rectangles and applies
  their relative rotation. Fixed-space UIKit polygons must keep all four corners
  and establish their fixed→guest→host conversion explicitly; they must not be fed
  into that AX rectangle path under an assumed coordinate equivalence.
- `SimulatorScreenView.layout()` fits/centers the framebuffer and applies the host
  rotation. `simulatorTouchPosition` then maps already-shown top-left screen points
  to AppKit bottom-left viewport points using
  `s=min(viewport.width/W, viewport.height/H)`,
  `(viewport.midX+(x-W/2)*s, viewport.midY-(y-H/2)*s)`.
  Device pixel scale and host backing scale are not extra input-coordinate factors.
  Preserve letterboxing, masks, current display identity and motion invalidation.

These LCD paths were read, not opened or changed for the fixture test. A later
integration must measure its real viewport/backing/host rotation and rendered
pixels. Existing AX selection and input flows are preserved. `verified=false`,
`overlayEnabled=false` and `clippingVerified=false` remain mandatory; visible clip
polygons, 3D, other orientation/foldable combinations and moving/atomic alignment
are unsupported by this evidence.
