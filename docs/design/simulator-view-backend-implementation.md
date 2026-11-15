# Simulator view backend implementation

2026-11-09. The fixture-only executable edit backend and verified-release epoch
transition are implemented. Schema 1,
its metadata/texture probe, and the disabled general-app policy remain compatible.
The new schema 2 capture collects textures and creates weak edit tokens in the
same target expression. Headless checks establish source/algorithm behavior;
they do not qualify UIKit, LLDB, idle-stack injection, or visible results.

The subsequent [live qualification](simulator-view-edit-live-qualification.md)
completed the fixed ten-operation fixture sequence: three textured schema-2
captures, hidden/alpha edits and server undo, three verified releases, same-owner
recapture and new-owner reopen. Canonical Swift validated 15 token-bound assets
per capture. Independent setter counters, stable generations, original screenshot
review and exact cleanup passed. General capture/edit gates remain false; this
does not qualify ordinary apps or LCD/3D composition.

Live LLDB required explicit Objective-C receiver/result/container types and a
collision-free registry local name. `__builtin_isfinite` avoids an unresolved SDK
inline libc++ wrapper. The parser reports MRC ownership and disables automatic
fix-its for schema 2. Where LLDB disables Objective-C exception compilation,
`OBJC_ZEROCOST_EXCEPTIONS` excludes the target catch; the unchanged debugger trap
and host missing-receipt path preserve uncertainty and quarantine without retry
or a target busy reset. Four subsequent bounded UIKit failure families establish
weak-deallocation and same-view reparent refusal. Throw-after-write and parent
cancellation preserve uncertainty and recover the exact process, but their
autoreleased setter sentinels have no deallocation event during the six-second
post-recovery observation. This cleanup qualification failure blocks product edit
enablement. The host harness's compiled catch assertions do not override it.
See [actual failure evidence](simulator-view-edit-live-qualification.md#four-bounded-actual-failure-families).

## Implemented paths A–H

| Deliverable | Production path |
|---|---|
| A: closed requests | `view-capture/edit_backend.py:contract`, reached through `capture.py:request_contract`. Exact fields per operation, strict JSON Boolean/numeric distinction, finite alpha in 0...1, bounded UUID/class/target/sequence fields. No expression, selector, KVC, output path, address identity, qualification flag, digest or lease is accepted from the caller. |
| B: owned registry | `view-capture/edit.expr`. One `NSMapTable strongToWeakObjectsMapTable` at the stable `NSObject` class association and constant `sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1")` key. Shape/owner/inspection/epoch/busy checks precede use. Persistent values are Foundation metadata; views, traversal collections and lambdas are local to the expression. Read-only captures never create tokens. |
| C: mutation | The same expression performs strong local weak lookup, bounded current scene/window/subview traversal, exact object/parent/window/class checks, expected-old comparison, no-change skip, entry journal, exactly one typed setter, fresh graph checks and final readback. It never casts a saved numeric address to an object. A compiled target catch or LLDB trap plus host quarantine preserves uncertainty after entry. |
| D: undo/release | Host and target retain bounded server receipts. Revert derives identity/property/before/applied from that receipt, checks the latest same-token property revision and current value, then uses the same guarded setter path. Release revokes host authority before dispatch and removes only the owned map/node/undo/revision payload. The target retains a bounded sequence/result tombstone. Closing never inverse-edits. |
| E: reservation | `edit_backend.py:Ledger`. Private per-target durable reservation, nonblocking file lock, canonical SHA-256, operation ID, sequence high-water, bounded result/undo records. A surviving reserved operation quarantines the whole inspection, including requests with new IDs. Exact duplicates return a receipt or `resultUnavailable`; neither dispatches. |
| F: lifecycle | `capture.py:supervise → _supervise → run_engine → LLDBEngine.edit_operation`. The existing exact debugserver/direct-child ownership, selected Xcode, identity probes, cooperative cancellation, detach and recovery remain in force. No alternate attach utility exists. Limits remain 8 s/expression, 45 s/work, 100 s/cleanup and 160 s/Swift helper ceiling. No target signals or all-thread fallback were added. |
| G: entry support | `LLDBEngine.select_main` writes `main-thread-entry.json` before target expressions. `edit_backend.py:safe_entry` requires a bounded known kernel Mach wait → CoreFoundation run loop → UIKit app runner → exact fixture `main` stack. Unknown, app-active, layout-active and wrong-module frames reject before injection. Main queue name and the subsequent BOOL proof alone are insufficient. This predicate is an unqualified fixture hypothesis. |
| H: Swift/UI | `SimulatorViews.swift` exposes typed capture/edit/revert/release requests and mutation outcomes through the existing cancellation/helper path. `SimulatorViewHierarchy.swift:simulatorEditableViewHierarchySnapshot` produces the frozen nested snapshot, assets, editing context and per-node edit tokens only after successful target collection and verified cleanup. |

`GENERAL_APP_CAPTURE_QUALIFIED` and `GENERAL_APP_EDIT_QUALIFIED` are false.
`FIXTURE_EDIT_ENABLED` permits only the experimental exact fixture route; it is
not a claim of runtime qualification. The request cannot change these switches.
The fixture bundle/executable policy is reapplied before either engine construction
or dispatch. Root supplies and serializes the exact target lifetime and LCD context.

## Textures and edit identity in one operation

Editable capture holds the traversed live views in local strong collections through
metadata collection, the fixed DebugHierarchy image request, and the final graph
checks. It creates an internal address-to-token texture join from those live
objects. That address is never an edit identity or reconstructed object. The join
must agree on class and parent, and each token can join only once. The final graph
must contain the same live objects with the same parent/window/class and hidden/alpha
values before the registry becomes active. A failed capture does not restore the
previous capture's authority.

The fixed texture request is generated internally with `hierarchy_request(True)`.
Before it runs, the expression bounds traversal and estimates image sizes from
bounds and screen scale: at most 64 views, 4096 pixels per axis and 128 MiB estimated
RGBA. This estimate is not a guarantee about UIKit/DebugHierarchy allocations.
Over-budget or unsupported collection produces an explicit texture-unavailable
reason. It does not fabricate an image or claim a textured result.

Swift reuses the existing `simulatorViewHierarchySnapshot` decoder for base64,
PNG signature/IHDR/CRC, 4 MiB per image, 16 MiB aggregate encoded data, 128 MiB
estimated decoded RGBA and 64-image limits. Only validated assets with a matching
same-operation join are attached to editable nodes. Asset `nodeID` becomes the
opaque edit token; node `assetID`, `assets` and `capabilities.textures` are populated.
Ambiguous, wrong-class, wrong-parent or missing joins do not attach a texture.
The target result cache and durable ledger do not retain image payloads.

The existing schema 1 fixture texture probe and aggregate `CGPoint` corner fix are
preserved. Neither capture path claims independent solo textures, clipping,
protected-surface support or verified LCD alignment. `descendantContent` remains
`unknown`; the renderer must independently validate/decode PNG pixels. There is no
remaining outline-only integration placeholder in the editable capture path.

## Closed schema 2 wire

All requests contain exactly:

```text
schemaVersion: 2
kind: capture | edit | revert | release
target: {pid: Int32, start: [UInt64 seconds, UInt64 microseconds], path: absolute path, deviceID: UUID}
validationOnly: true
ownerID, inspectionID, operationID: UUID
targetEpoch: UUID | null
sequence: Int in 1...4096
```

Additional fields:

| Kind | Fields |
|---|---|
| capture | `replaceCaptureID: UUID|null`; both it and `targetEpoch` are null only for initial capture. Initial sequence is 1. |
| edit | `captureID`, `nodeToken`, `expectedParentToken: UUID|null`, `expectedWindowToken`, `expectedClass`, `property: hidden|alpha`, `expectedValue`, `value` |
| revert | `captureID`, `undoToken` |
| release | `captureID`, `reason: close|refresh|expired|cancel|targetChanged` |

The host creates the epoch/capture UUID, digest, expiration, fixed texture request,
and any server undo receipt. IDs are normalized to canonical uppercase UUIDs and
executable paths to their real path before ledger admission. Internal target wire
fields are not accepted by the public schema.

Limits are 20,000 nodes, depth 512, 16 MiB target answer, one target operation,
120-second capture TTL, 4,096 operation identities per epoch, 256 result receipts
and 256 undo receipts. Wall expiry and a monotonic/uptime expiry are enforced;
selection does not renew either. The host stores at most 128 target-lifetime
ledgers. Capacity exhaustion fails closed. It does not evict unresolved authority.
If operation capacity is exhausted before a verified release, the history reaches
64 retired epochs, or target busy remains unresolved, further rollover is refused.
Explicit lifecycle reconciliation, normally a new fixture process lifetime during
qualification, is required. A verified terminal release can retire a full operation
epoch while preserving its complete replay fence.

## Host reservation and failure semantics

The default private ledger directory is
`~/Library/Application Support/mac-cu/view-edit-ledger` (0700). Files and lock files
are 0600. Target identity determines the filename; the request supplies no ledger
path. Symlink/non-owned/non-private files are refused. An atomic temporary file,
file fsync, rename and directory fsync commit the reservation before child creation.
The target lock remains held through cleanup and final receipt persistence.

The ledger contains bounded metadata and minimal receipts, not images or full
thread stacks. Receipts are capped at 16 KiB each; detailed stack/compiler/operation
results stay in the private evidence directory. A reservation surviving host exit
or interrupted dispatch quarantines the inspection. No old reserved operation is
resumed. A changed digest conflicts; a missing evicted result or old sequence
cannot authorize another setter. There is no automatic retry or replacement ID.

A target exception after setter entry, LLDB interruption, lost result, mismatched
readback or lost post-set identity remains uncertain. The target busy bit may
survive an interrupted expression and is never blindly reset. `setterEntered`
reports confirmed entry; a false value alongside `mutationOutcome: uncertain`
is not proof of non-entry. Reentrancy is rejected while the operation is busy.

A received `appliedObserved` receipt survives cancellation, detach failure,
child-cleanup failure, or final ledger-write failure. `status`, `mutationOutcome`
and `cleanup` remain separate. Such failures revoke further edit/undo authority;
they do not rewrite an observed application as `notEntered`. Target-side release
can fail while `authorityRevoked` is true on the host. Release may clean either
owned old/attempted generation after a failed refresh, but cannot revoke a newer
successful capture using a stale unrelated capture ID.

Undo is an explicit guarded operation, not rollback. Value ABA and side effects of
overridden getters/setters cannot be excluded. App logic may overwrite a value
after readback. A current value matching the requested value is not proof that a
previous lost operation succeeded. Unexpected target loss/epoch loss, expired
captures, conflicts and untrusted replies require explicit refresh/reconciliation.

## Verified-release inspection rollover

The inspector's release → fresh inspection lifecycle is supported without changing
Swift wrapper names or the public schema 2 request. Recapture can retain `ownerID`
and issue a new `inspectionID`; close/reopen can issue both IDs. A restarted host
reads the same durable evidence. An initial request remains sequence 1 with null
`targetEpoch` and `replaceCaptureID`. Exact replacement inside the existing
inspection still uses its existing epoch, replaced capture and next sequence.

The host and target implement these invariants:

1. **Release is evidence, not a revoked bit.** The target removes only map/node/
   undo/revision payload and records a Foundation-owned `releaseProof` containing
   owner, inspection, epoch, actual released capture, operation, canonical digest,
   sequence and the epoch's entry transition ID. It invokes no inverse setter.
   The host accepts retirement only after validating that exact proof and receiving
   success with verified detach, same-lifetime recovery and reaped children. A
   failed/uncertain release, cancellation, missing proof or older unresolved host
   reservation cannot make the epoch eligible.
2. **Transition authority is server-owned.** The host creates `transitionID` and
   copies the exact predecessor proof and prior retirement history from its private
   ledger. The public contract rejects `transition`, `releaseProof`, `retired` and
   lifecycle metadata. Before any child or target dispatch, one fsync/rename commit
   stores the successor identity, retired predecessor, transition and reserved
   initial operation. The existing nonblocking target lock spans the operation.
3. **The target independently agrees.** A successor requires a released, nonbusy
   predecessor with no weak/undo payload and all target operations finished. Its
   release proof and retirement history must exactly match the host evidence.
   Missing, active, quarantined, busy, malformed or different predecessor state
   refuses the transition without replacing ownership. A successor dictionary is
   built locally with busy=true and the operation reserved *before* the association
   is replaced. No intermediate empty/unreserved epoch is published. Persistent
   values remain Foundation metadata plus the existing zeroing-weak map; no injected
   callback, custom lifetime object, timer or busy-reset path was added.
4. **Retirement is permanent for that target lifetime.** Both sides retain at most
   64 compact predecessor proofs. A retired inspection ID or epoch is rejected
   before operation replay, including delayed initial captures with null epoch and
   stale release/edit/revert operations. Owners may be reused with a fresh inspection.
   Old operation histories and image payloads are not retained after retirement;
   the inspection/epoch fence rejects every old operation identity regardless of
   its sequence or result-cache eviction. Entry transition IDs also remain fenced.
   No history entry is evicted; attempt 65 fails with `capacityExceeded`.
5. **Interruption never supplies a release.** A host reservation surviving restart
   quarantines its successor even if dispatch never occurred. Lost target receipts,
   failed terminal persistence and host/target disagreement do not retry, roll back
   the ledger or infer completion from current values. An exact completed duplicate
   returns its bounded receipt; capture snapshots/authority are not replayed. An
   in-flight/evicted duplicate remains unavailable/uncertain. A changed transition
   ID for the current successor, or reuse of a retired entry ID, is refused.

**Explicit remaining blocked path:** an initial capture rejected before registry
injection (for example, an unsafe/unknown main-thread entry) does not prove that
this host owns a releasable target tombstone. No-target-state retirement is not
implemented. A fresh inspection fails with
`predecessorNotVerifiedReleased; noTargetStateRetirementUnsupported`; it does not
fabricate `registryReleased`. The retained failed reservation requires explicit
reconciliation or a new fixture process lifetime. This is distinct from the fixed
normal successful capture → verified release → fresh inspection path.

Ledger/target lifecycle metadata has internal version 1. Legacy source18 metadata
without this version, unknown required lifecycle metadata, malformed history,
and inconsistent persisted release evidence fail closed. This change does not
silently migrate or reset an existing legacy target tombstone or ledger. Root must
use a fresh owned fixture lifetime when first qualifying the upgraded backend.

## Stable Swift API and inspector mapping

The names below are stable for the root adapter:

```swift
let cancellation = SimulatorViewCaptureCancellation()
var request = SimulatorViewEditableCaptureRequest(target: target)
request.ownerID = ownerID
request.inspectionID = inspectionID
request.operationID = captureOperationID
request.sequence = 1
request.validationOnly = true // only the exact fixture is admitted
let capture = try simulatorCaptureEditableViews(request, cancellation: cancellation)
let context = try SimulatorViewEditingContext(target: target, result: capture)
// capture.content["snapshot"] is the frozen textured/editable snapshot on success.

let identity = try SimulatorViewEditIdentity(node: selectedRawSnapshotNode)
let edit = try simulatorEditView(SimulatorViewEditRequest(
    context: context, identity: identity,
    expected: .hidden(false), value: .hidden(true),
    operationID: uiOperationID, sequence: nextSequence), cancellation: cancellation)
// Pass edit.content directly to the inspector completion.

let revert = try simulatorRevertView(SimulatorViewRevertRequest(
    context: context, undoToken: serverUndoToken,
    operationID: uiUndoOperationID, sequence: nextSequence), cancellation: cancellation)

let release = try simulatorReleaseViews(SimulatorViewReleaseRequest(
    context: context, reason: .close,
    operationID: releaseOperationID, sequence: nextSequence),
    cancellation: SimulatorViewCaptureCancellation())
```

All helper calls run off the main thread. Root owns serialization, monotonically
increasing sequence assignment, target/display/presentation attestation and main-thread
UI completions. The same cancellation type is accepted by every wrapper. A fresh
cancellation object for explicit release permits cleanup after the previous
operation was cancelled. Release does not automatically undo.

| Inspector envelope | Typed backend mapping |
|---|---|
| `operationID` | Pass its UUID unchanged to edit/revert; this binds receipt ordering. |
| `captureID`, `inspectionID`, `ownerID`, `targetEpoch` | Compare with the retained `SimulatorViewEditingContext` before dispatch. |
| `editToken` | `SimulatorViewEditIdentity.editToken`. Never pass an address. |
| Selected node `parentID`, `geometry.windowID`, `className` | `expectedParentToken`, `expectedWindowToken`, `expectedClass`. The raw snapshot also provides `windowToken`; it is identical to this geometry window ID. |
| `property`, `expected`, `value` | `.hidden(Bool)` or `.alpha(Double)` on `SimulatorViewEditRequest`. The property follows the typed enum case. |
| `undoToken` | `SimulatorViewRevertRequest.undoToken`; server derives the inverse value. |
| Host serialized counter | `sequence` for capture/edit/revert/release, including failed dispatched reservations. Never reuse an old sequence with a new operation ID. |

For refresh, set `request.replacing = context` and the next sequence. The wrapper
uses the retained owner/inspection/epoch and names the old capture. A stale capture
completion still returns the exact target/owner/epoch/capture IDs. Build a context
from that returned result and explicitly release it even if UI generation checks
reject publication. A later successful replacement makes an older release fail
closed instead of releasing the new capture. Keep the original operation ID and
evidence after transport uncertainty; do not infer success or automatically retry.

`SimulatorViewMutationResult` exposes typed `status`, `operationID`,
`mutationOutcome`, `before`, `requested`, `observed`, `undoToken`, `needsRefresh`,
`cleanup`, and the full `content`. Added status cases include `noChange`, `conflict`,
`expired`, `busy`, `outcomeUncertain`, `resultUnavailable`, `undoConflict`,
`ownershipConflict`, `keyCollision`, `capacityExceeded`, and `unsafeEntry`.
The snapshot's `editing.expiresAt` is ISO 8601 with fractional seconds, as required
by the inspector model. Internal target/ledger time remains numeric.

## Build callers and headless validation

`tests/check-view-capture.py` now uses canonical `native_build.run_swift` only for
its whole-source guard build. `tests/view-hierarchy-fixture/prepare.py` uses it only
for the whole-source session probe, and includes `native_inputs(SOURCE)` in both
reuse validation and final hashes. Old prepared manifests without those hashes
fail reuse. View-only compiles, fixture build and all entry/watchdog guards remain.
Neither whole-source caller was executed while peer inputs were changing.

Focused entry point:

```sh
python3 -B mac-computer-use/tests/check-view-edit.py
```

It runs the production schema/ledger/supervisor tests, existing capture/session/
native-safety regressions, complete generated Objective-C expression syntax checks,
focused Swift compiles and guarded CLI selfchecks, distribution validation and
scoped diff checks. It does not invoke setup, compile the full host or touch a
Simulator service. Artifacts/logs/hashes are retained in a unique temporary directory.

`tests/view-edit-production/run.py` embeds the complete canonical `edit.expr` in a
Foundation-only UIKit-shaped host harness. Only request/answer transport locations
are substituted; the production admission, registry, traversal, texture join,
compare/set/readback, undo, release and journal branches execute unchanged.
Framework loading, UIKit geometry and the private image collector are host shims;
this is not live UIKit or LLDB evidence. The harness uses explicit MRC,
`@autoreleasepool`, `-fobjc-exceptions`, strict warnings, rejected entry routes,
a parent deadline and an exact one-executable budget. No GUI framework is linked.

The UIKit Simulator syntax check uses the selected SDK, Objective-C++ and explicit
`-fno-objc-arc`. An ARC compilation must fail at the expression's explicit mode
guard. LLDB's actual ownership mode, unwind cleanup and cross-expression lifetime
still require live verification; the host harness cannot establish them.

## Remaining live qualification

The primary fixture sequence above passed. Root must freeze integrated inputs
before further protected serial qualification:

1. The primary sequence recorded accepted frames/module paths and MRC ownership
   for all ten baseline operations and eight subsequent fault-family operations.
   Live active/layout rejection remains separate. Exception/cancellation process
   recovery does not establish autorelease cleanup. Do not treat the predicate or BOOL as proof.
2. Verify weak identity across separate expressions, detach/reattach/JIT disposal,
   actual same-address reuse and scene/window changes. Actual weak deallocation
   and reparenting within one window now refuse before setter entry.
3. Actual hidden/alpha readback, visible changes and guarded undo passed. Throwing
   setters and cancellation after applied-value entry now preserve uncertainty;
   old-authority replay/new-ID admission is fenced before child creation. Their
   missing sentinel deallocation remains a blocking cleanup gap. Nonreturning
   setters, other timeout/cancellation boundaries, target exit and detach failure
   still need qualification. Running/untraced recovery and child reaping passed
   independently for the baseline and the four bounded failure families.
4. Same-operation image/token joins passed live through canonical Swift conversion.
   Memory bounds, per-node texture semantics, transformed/clipped/protected surfaces,
   renderer picking/composition and LCD alignment remain separate.
5. Validate a separate SDK-free debuggable app before any general-app enablement.
   Both general gates remain false. Root owns integrated runtime validation and
   completion installation; this worker performed no GUI, Simulator boot/install,
   debugger attach, input, global installation/restart, commit, push or publication.

## Recorded headless evidence

The complete focused run passed at:

`/var/folders/tf/wn7gzzvd6l7f7_ttdx84ps880000gn/T/mac-cu-edit-headless-h3yoespb`

- `capture-edit.log`: 46 tests (26 capture + 20 edit/entry/ledger tests).
- `session.log`: 26 protected-session regressions.
- `native-safety.log`: 6 parent-watchdog regressions.
- `production-expression.log`: 743 assertions executing the canonical expression;
  weak nil, replacement, stale/reparented graph, owner/epoch/expiry, no change,
  expected-old conflict, dedup/digest/high-water/result eviction, throw-before and
  write-then-throw, mismatch/detach, undo conflict, release, texture joins, node/depth
  bounds and preservation of an unrelated association. Exact executable leftovers: 0.
- `syntax-metadata.log`, `syntax-texture.log`, `syntax-editable.log`: complete
  generated expressions compile against the selected iPhoneSimulator 27.2 SDK.
  Existing deprecated `UIApplication.windows` warnings remain. The explicit ARC
  rejection is recorded in `syntax-arc-rejection.log`.
- `swift-compile-*.log`, `swift-run.log`: targeted hierarchy/texture/editable Swift
  compilation and guarded headless execution. The editable selfcheck verifies
  nonempty token-bound assets, ambiguous/wrong-class texture refusal, ISO expiry,
  typed receipts that preserve applied observation under cleanup failure, and all
  four wrappers through the real packaged Python schema/policy path. Nonfixture
  requests are rejected before the ledger, process probe, or debugger children.
- `distribution.log`, `scoped-diff.log`, `sha256.json`: package/diff checks and source
  hashes. Source edits after this run require their corresponding focused recheck.

The first host-harness compile failed because its geometry getters required
CoreGraphics linkage. The harness now supplies scalar geometry shims and links
only Foundation; the production UIKit expression is separately compiled against
the real Simulator SDK. No failed GUI/Simulator attempt occurred.

Final response-validation hardening was rechecked with all 46 Python capture/edit
tests in `/tmp/mac-cu-edit-final-validation.log`. The last native/syntax/Swift inputs
are unchanged from the complete run above. The narrow prepare-reuse check is in
`/private/var/folders/tf/wn7gzzvd6l7f7_ttdx84ps880000gn/T/mac-cu-edit-build-callers-25qetd9z/check.log`: an old prepared manifest without the adapter header hash was
rejected before any compiler or executable invocation.

The isolated helper sets `sys.dont_write_bytecode` before importing the backend,
including under Python `-I`; it does not write bytecode into signed resources.
The isolated-import check passed with no resource mutation in
`/var/folders/tf/wn7gzzvd6l7f7_ttdx84ps880000gn/T/mac-cu-edit-module-guard-edhgesvu/isolated-import.log`.
Final owned-source hashes are in `/tmp/mac-cu-edit-final-source-hashes.json`.

## Rollover implementation handoff (supersedes source18 lifecycle evidence)

Changed only `edit_backend.py`, `edit.expr`, `test_view_edit_backend.py`,
`tests/view-edit-production/main.mm`, and this handoff. `capture.py`, Swift wrappers,
AX, inspector host/window, setup/native build, fixture trees, and global app remain
unchanged by this worker. The user explicitly excluded installation and live tests
from this headless assignment. No subagents, GUI/guest apps, Simulator/AXP queries,
LLDB, setup invocation, commit, push, or user-data mutation were performed.

Final focused evidence directory:

`/private/var/folders/tf/wn7gzzvd6l7f7_ttdx84ps880000gn/T/mac-cu-rollover-final-gvybs818`

- `capture-edit.log`: **59 tests**, comprising 26 existing capture tests and 33
  backend/entry tests. The real supervisor uses fake process transport. New coverage
  includes same/different owner, recapture/reopen/restart, exact replacement, all
  retired operation kinds, missing/invalid release proof, unfinished predecessors,
  interrupted reservations, lost terminal persistence/receipts, duplicate results,
  pre-injection rejection, malformed/legacy state and actual 64-retirement capacity.
- `production-expression.log`: **1,454 assertions**, including the unchanged
  baseline branches and the new actual canonical expression transition branches.
  Host-only Foundation shims provide UIKit geometry/collector behavior. These are
  not live UIKit/LLDB assertions. Five rejected entry routes ran under the parent
  watchdog; exact executable leftovers were zero.
- `native-safety.log`: **6** parent-watchdog regressions passed. No GUI route ran.
- `syntax-editable.log`: the complete changed expression compiles against the
  selected iPhoneSimulator 27.2 SDK with explicit MRC. Existing UIApplication.windows
  deprecation remains. `syntax-arc-rejection.log` confirms the required ARC refusal.
- `distribution.log`, `tracked-diff.log`, `owned-diff.log`: distribution and whitespace
  validation. The owned-file check includes these untracked implementation files.
- `reopen-regression.json`: initial capture, verified release, same-owner new
  inspection, second release, and changed-owner reopen all succeed through the real
  supervisor/fake transport. The original failing log remains unchanged at
  `/tmp/mac-pilot-edit-reopen-regression.log`.
- `source18-current-sha256.json`, `source18-comparison.json`, `owned-sha256.json`:
  final hashes, changed-source comparison and narrow worker-owned source hashes.

The first post-change runs also passed (20 then 32/33 Python tests, 743 then 1,454
production assertions). There was no failed native/GUI attempt. The final run above
includes the last code edits. The first owned-file whitespace driver misclassified
`git diff --no-index --check` exit 1 (added-file differences) as failure. Its corrected
check accepts normal 0/1 only when there are no whitespace diagnostics; the final
owned-file check passed. `owned-diff-driver-initial.log` retains that driver issue.
Existing 26 session, metadata/texture syntax and
Swift checks from source18 remain applicable to unchanged inputs; they were not
rerun. Root's full repository build/check and subsequent icon recovery remain
separate evidence. No global installation was performed.

**Root/live qualification still required:** freeze these hashes, use the sole
Simulator owner and a fresh owned fixture lifetime, then exercise actual LCD
capture → release → fresh inspection and close/reopen with both owner patterns.
Verify actual weak/registry survival across separate expressions and debugger
reattach; actual hidden/alpha and undo readback plus visible outcomes; target
busy/exception/cancellation/receipt-loss fences; verified running/untraced recovery
and owned-child cleanup; real texture joins, memory limits, rendered composition
and LCD alignment. Check the ordinary SDK-free debuggable app separately before
any general-app enablement. `GENERAL_APP_CAPTURE_QUALIFIED` and
`GENERAL_APP_EDIT_QUALIFIED` remain false. Root owns the integrated changelog,
build, UI review and completion installation.
