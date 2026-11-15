# SwiftUI product runtime qualification

Status: **not qualified**. One actual owned fixture lifetime was attempted on the existing ordinary iPhone 18 Pro. LCD startup stopped before inspector capture because the parent observer rejected a display-read child in a separate process group. The failed raw result remains unchanged.

`tests/swiftui-inspector-product-live/prepare.py` builds the canonical whole-host session probe and canonical mixed Swift/MRC resident through the existing preparation path. It then builds the actual SwiftUI `Fixture.swift` application with a unique bundle ID. No experimental graph resident is built or loaded. The launch wrapper applies `SWIFTUI_VIEW_DEBUG=287` only to this new owned fixture. Product capture still obtains inspection scope from the real coordinator and host preparation.

The shared UI harness has a focused SwiftUI lane. Its assertions cover real LCD 3D-button dispatch, actual declarative outline selection, property search, hosting composite identity, branch recapture, stale graph rejection, independent UIKit witness hidden/alpha setter counts and restoration, minimum-size layout, and close/reopen ownership. These assertions compiled but have **not executed successfully**. Timing-dependent late-result cancellation is retained for the existing UIKit lane; the new lane does not claim that evidence.

The fixture adds a weakly held UILabel witness with independent hidden/alpha setter counts and per-instance generation. The existing branch control remains finite, session/PID bound, and freshness checked. No graph/debug API was added to the fixture.

## Observed blocker

The actual LCD creates `devicectl device info displays --device ... --quiet --json-output ...` beneath the isolated UI executable. The shared native observer's `isolated_probe` role is bound to `session-probe`. Mapping the UI executable later in the product budget callback cannot satisfy the earlier native separate-group admission check. The observer correctly stopped with `IdentityChanged('unexpected separate process group')`. No identity, input, focus, quarantine, or release gate was relaxed.

A follow-up needs an explicit, bounded UI-root/read-helper topology contract that retains exact executable identity, argv validation, parent/group joins, output-path validation, helper count limits, and independent cleanup. It must preserve the existing session-probe route. Do not fix this by accepting arbitrary separate groups or rewriting the observed process identity.

## Evidence and limits

The worker handoff records the unique private evidence directory, exact commands, hashes and raw logs. Fresh build/sign/routes passed. Native safety regressions passed 7/7; probe regressions passed 36/36; existing product harness tests passed 5/5; distribution validation passed.

The initial default-Python command failed its LLDB import preflight before a target lifetime. Xcode Python passed its parent/worker guard and began the single actual lifetime. The fixture launched with flag 287 and supplied its independent oracle. The UI stopped during initial activation after the watchdog cancellation. No product graph, composite, boot-generation consumer negative, selection, mutation, branch capture, screenshot, or layout assertion was reached.

Independent reconciliation read native exit state for the worker/UI/display helper, proved no target backend ledger/request, verified the exact untraced fixture lifetime, removed only its installation/data, verified original host and guest identities/display state, and released the exact claim. It recorded zero owned processes. No resident was injected or unloaded. No user app was restarted. No global installation, backup, setup registration, publication or acceptance occurred. `hostingSubtreeComposite` and read-only/tree-only SwiftUI semantics remain the intended contract; no general Text/Shape-loss reproduction is claimed.

## Attempt 2: observer topology patch, runtime still unqualified

The scoped follow-up adds a manifest-bound actual UI executable/resource contract
before parent/worker child admission. It removes the late UI-to-probe row rewrite.
The headless replay preserves attempt 1's rejection and exercises the UI's inherited
worker group, separately grouped display/identity/screenshot helpers, argv and
output checks, forward-exec identity fences, singleton and per-role budgets.
The existing standalone probe and target-role tests still pass.

Attempt 2 passed LCD activation, actual inspector opening/screenshot and host-only
camera assertions. The native observer then stopped the first capture with
`IdentityChanged('unknown UI descendant')`. No graph/composite was accepted. The
current contract remains incomplete: canonical `resident_support.admit` creates
bounded read utilities beneath the capture supervisor; these are rejected by the
new descendant branch. Its later canonical LLDB worker runs
`resident_transport.py --worker`, while the new role currently admits only
`capture.py --worker`. These harness gaps require review and headless proof before
any third lifetime. No production integration failure is established. The rejected
row was not recorded by the new direct exception; the exact transient utility PID
and argv therefore remain unproven. Do not infer them from a process name.

Independent reconciliation joined the sole capture request, terminal result,
quarantined ledger and native process identities. The result states `notDispatched`,
`notEntered`, `cancelled before dispatch`, children reaped and recovery verified.
The evidence directory has admission/bootstrap/request/result/authority/cancel only;
no channel, wire or debugger evidence exists. Source inspection places that
cancellation before `support.stage`, debugger creation and resident dispatch.
The exact target was still untraced. Only the owned fixture was terminated and
removed. Original host/guest identities and display state were restored, the exact
claim was released and zero owned processes remained. This is pre-dispatch cleanup,
not a normal resident release proof. The quarantined ledger remains unchanged.

Evidence: `/private/tmp/mac-cu-ui-topology-TTbRIFPL/HANDOFF.md`. Both raw attempts
retain `passed=false`. No third lifetime, global installation, user-app restart,
backup, plugin change, Git operation or loop-state write occurred.

## Headless contract audit after attempt 2

Status: **incomplete; runtime attempt 3 remains blocked for root review**.
No new preparation or runtime was performed. Historical prepared pins are not
current after the diagnostic/test edits. Audit hashes below do not replace them.

All UI topology rejection branches now retain the observed row through `reject`.
Exact-role budget and exec-stabilization failures also retain the available full
identity. Snapshot-only failures leave `start` unknown. No argv or start identity
is inferred from the row, and rejection evidence grants no signal authority.

`tests/view-hierarchy-fixture/test_canonical_call_trace.py` executes production
`resident_support.manifest/admit/stage`, `capture.tools_for_xcode`, and
`resident_transport.supervise/worker/finish_children` with intercepted subprocess
entry points, private synthetic files, and an engine factory that raises before
any engine executes. Capture, edit, revert and release inputs each produce 17
subprocess calls. The existing-pin stage branch produces no additional call.
The actual worker argv comes from production `Popen`, including its real
`pass_fds` arguments. The test checks that these FDs exist in the parent; it does
not prove inheritance into a real child or grant socket authority to the observer.
The transport writes request/channel/wire/worker artifacts into the synthetic
owned data cache. No native terminal result or successful target operation is
simulated or claimed. The worker stops at the explicit headless engine boundary.

`canonical-call-audit.json` records source hashes, functions, lines and Python
spawn expressions. Its regression fails if an audited source changes. These are
**audit pins**, not build, manifest, preparation or runtime qualification pins.
The trace tests explicitly demonstrate current observer rejection of canonical
utilities and worker argv. Their passing status means the gap remains reproduced.

The source-backed role matrix is:

| Role / source | Parent and group | Required command or join | Current evidence / remaining gap |
| --- | --- | --- | --- |
| UI root; `session.bind_ui_process_contract` | Fixture worker; worker PGID | Prepared actual binary and Contents/Resources capture resource | Existing manifest binding; no fresh preparation in this audit |
| Capture supervisor; `SimulatorViews.swift:63`, callers at 147 and 419 | UI; Foundation child owns PGID | `xcrun python3 -I <UI resource>/capture.py --capture <host folder>/request.json` | Existing argv role; request read is still unbounded/follows links and joins target only |
| Identity read; `remote_watchdog.helper_role` | Direct UI; own PGID | Exact resource, PID, device; selected Python alias | Existing retained read contract; current `SimulatorTargetIdentity` uses native reads, not this CLI |
| Display; `SimulatorDisplayState.swift:7`, `Simulator.swift:322`, `SimulatorStatus.swift:38` | Direct UI; own PGID | `xcrun devicectl device info displays --device <device> --quiet --json-output <unique output>` | Existing role; one-display limit is not a concurrency proof; passive observation and synchronous reads can overlap |
| Display wrapper; selected Xcode `usr/bin/devicectl` | Same PID on forward exec, `/bin/zsh` | Exact selected script and CoreDevice executable; exact version plist read | Existing forward chain and PlistBuddy role; selected wrapper must be pinned |
| Admission; `resident_support.py:18,30` | Supervisor; inherited supervisor PGID | Exact resource-image codesign, xcode-select, SDK query, xcodebuild version, device/runtime inventories, owned app/data container queries, app signature and entitlements | Production-generated calls recorded; UI observer still rejects these descendants |
| Discovery; `capture.py:223` | Supervisor; inherited supervisor PGID | xcode-select and selected Simulator SDK query | Recorded; no generic xcrun allowance is valid |
| simctl wrapper; selected Xcode `usr/bin/simctl` | Supervisor child; inherited PGID; wrapper descendants inherit | `/bin/bash`, selected script, exact CoreSimulator version plist; shell subshells and `sort --version-sort` / `head -n1` in version comparison; final CoreSimulator simctl | Newly identified source gap; no native wrapper topology captured |
| xcodebuild dispatch | Supervisor; inherited PGID | Only `-version`, selected executable chain | Alias/exec chain has not been qualified by this trace |
| Stage signing; `resident_support.py:75` | Supervisor; inherited PGID | codesign verify strict of exact target-keyed staged image | Recorded; absent when existing pin matches |
| Debugserver; `resident_transport.py:260` | Supervisor; inherited PGID | Selected exact executable, positive FD from socketpair `pass_fds` | Production argv/parent-side FD recorded; observer lacks the complete config/server-lifetime join |
| Canonical worker; `resident_transport.py:273` | Supervisor; inherited PGID | `python -I resident_transport.py --worker <owned-data-cache channel> <positive fd>` | Recorded; current observer instead admits legacy `capture.py --worker`, so canonical role still fails |
| Worker validation; `resident_transport.py:195`, `resident_support.manifest` | Worker; inherited supervisor PGID | codesign verify strict of prepared image, then exact staged image | Recorded; deep worker utility topology remains rejected |
| Screenshot; UI harness `live.swift:169` | Direct UI; own PGID | screencapture exact window argument and declared output label | Existing synthetic contract; no screenshot taken in this audit |
| Recovery; `finish_engine`, `finish_children`, `capture.recovered/stop_child` | Existing owned children | Direct Popen-child wait/termination and native target readback; no new subprocess | Closed-child path executed with fake children; target and native custody were not exercised |

The selected simctl/devicectl wrappers also contain `xcodebuild -runFirstLaunch`
branches. Reading the selected version plists found matching versions 1174.20
and 651.31. That is read-only source/config evidence, not proof that the branch
cannot run later. Setup is outside this assignment. A future observer must reject
that branch rather than authorize it as a generic xcodebuild utility.

Remaining implementation requirements before another lifetime:

- Bind selected wrapper/tool hashes, resident build/image, owned app/data container
  and complete operation identity to freshly verified product/UI manifests.
- Replace the legacy worker role with bounded, no-symlink request/channel/wire/
  worker/admission reads. Join target, operation, supervisor lifetime, prepared
  resource, staged image, server identity and channel under owned target data.
- Classify the selected wrapper's finite shell descendants and stable forward
  exec chain. Native parent/start/path/group reads must surround argv reads.
- Establish source-backed concurrent role limits, including independent display
  observation. Preserve partial-observation cutoff and pending-parent semantics.
- Feed complete positive family phases and adversarial joins through the native
  observer seams. The present trace deliberately records admission failures; it
  is not full positive-family acceptance evidence.

Evidence: `/private/tmp/mac-cu-contract-headless-n5X17vUC/HANDOFF.md`.
Attempt-2 raw/quarantined evidence and root's rejected-row regression are retained.
No installed application, preparation manifest, runtime budget, loop state, target,
Simulator, GUI, LLDB session, global setup or Git publication was changed.

## Recording readiness follow-up

The two original failures and independent cleanup remain authoritative. A fresh
headless preparation does not consume or authorize attempt 3. The recording
readiness work adds actual intercepted preparation dispatch traces, a separate
unintegrated transition predicate, and real-button eligibility/target-action
assertions for the existing recorded-launch UI lane. It does not qualify a button
click or restart. See [recording readiness](swiftui-recording-readiness.md) for the
live-claim incompatibility, fixture launch-argument blocker, integration limits,
and the proposed single capture-only runtime plan for root review.


## Canonical temporary capture path (headless attempt 1)

Attempt 3 failed because Foundation supplied `/var/folders/...` to the artifact
observer. The same inode was accepted as `/private/var/folders/...`; the unchanged
reader rejects symlink ancestors with `openat`/`O_NOFOLLOW`. Foundation's
`resolvingSymlinksInPath()` also retained the alias in the headless reproduction.
The trusted `simulatorViewCaptureFolder` producer now uses `realpath` on the
existing temporary root before appending and creating its UUID folder. Resolution
failure throws; directory mode remains 0700. Existing private request/result/cancel
file handling is unchanged.

Schema 1, schema 2 capture/edit/revert/release, and explicit recording preparation
all derive request/result/cancel/evidence paths from this same returned URL. No
helper argv, queue, spawn budget, ownership rule or recording workflow changed.
The capture observer still does not authorize the recording workflow.

`mac-computer-use/tests/canonical-temporary-path/run.py` freezes the full production
Swift file and canonical dependencies, appends a guarded entry in that same file,
and runs the actual private producer under the native watchdog (one executable
instance; helper, unknown and inherited routes rejected before entry). Its actual
0600 request bytes in the actual 0700 folder pass the unchanged Python reader and
schema-2 binder for capture/edit/revert/release. Synthetic dependencies never launch
a guest fixture or target engine. Private-file, file/ancestor symlink and same-byte
inode replacement negatives remain rejected. Source currentness and full logs are
retained under `/private/tmp/mac-cu-canonical-path-zmztpfb8`.

This is a headless path fix, not runtime attempt 4. Runtime attempts 1–3 remain
failed; product runtime and normal recording-button behavior remain unqualified.
Historical prepared manifests and binaries are unchanged and now stale for this
source. No preparation, installation, Simulator action, LLDB attach, claim action
or cleanup reconciliation was performed. Root's later exact inactive-claim release
is taken from the task handoff; full host-window restoration remains false because
the T3 layer-3 window is missing.


## Composite-first scheduling (headless only)

Attempt 4 remains failed, as do attempts 1–3. Its preserved resident answer records
a 2.8980679167434573-second graph call before rendering was refused by the shared
two-second start budget. UIKit texture collection did not supply the separately
typed hosting composite. The resident now schedules the hosting composite before
graph serialization for each admitted host. Both stages retain one shared clock,
cancellation admission, separate outcomes and intervals, and all existing caps.
A call admitted before expiry may return after expiry; no next call is admitted.
Rendering preflight refusal still permits graph admission if time/cancellation allow.

Controlled headless scheduler tests and canonical mixed Swift/MRC compile/signing
are source/build evidence only. Existing product/UI preparations are stale for this
source change; historical prepared manifests remain unchanged. No fifth runtime,
fixture, Simulator operation, debugger attach, claim action, GUI, installation or
cleanup reconciliation is authorized or performed by this change. Actual graph plus
composite, boot join, branch/stale/edit/reopen and recording acceptance remain pending.


## Bounded bootstrap and failure-owner repair (2026-11-10)

Runtime5 remains failed. Lead retirement closed custody independently; it did not
produce normal releaseProof. Its 20.31 s load-attempt to loaded-image interval
includes loading and verification. Individual costs were not measured.

Production now resolves the fixed entry with module-scoped `FindSymbols` across
all symbol types, then requires exactly one code symbol with the exact name.
The global reserved-namespace, legacy/current lookup, UUID, path, unique module,
and text-range checks remain. A file-only LLDB SBModule check matched the former
linear scan on the canonical resident (372 symbols); no SBTarget or process was
created. This removes Python symbol-table traversal, not a proven runtime delay.
The worker also checks the existing cancellation marker at bootstrap checkpoints,
including before submission. Deadlines, submission count and unknown-caller
retention are unchanged.

The UI harness preserves the original failure and waits for the production
coordinator's host custody plus durable debugger/child completion. Two read-only
properties expose existing coordinator state. The wait ignores task cancellation
so main-queue cleanup can finish. It admits no input or backend request. Failure
still exits 1. At the pre-existing owner bound, unresolved custody is reported and
the actual UI process remains alive for reconciliation. The runner waits for that
owner on cancellation/failure; native parent identity checks remain strict.
Host settlement does not establish native releaseProof or a passed workflow.

Headless evidence: transport, owner-wait, capture/edit and native guard tests;
actual whole-source Swift/UI compile; canonical resident build; bounded dispatch
checks. Custody timing tests use explicitly labelled doubles. Standard preparation
rejects changed harness source pins; those pins and historical preparations were
left unchanged. Fresh preparation and any runtime authorization belong to lead
review. No runtime6, installation, restart, or runtime acceptance occurred.

Lead review corrected the failure-owner join: `Ledger.finish` omits `debuggerClosed` and `activeCall` from its compact cleanup receipt. The UI now reads each bounded original result, joins operation/digest/target/owner/inspection to the ledger, and then checks native child settlement. A test uses the actual `Ledger.finish` serializer and rejects reserved operations, missing/mismatched receipts and unresolved child custody. The compiled reader also accepted runtime5's archived compact ledger with its original full receipts while preserving `authority=revoked` and absent releaseProof. This proves only host-child settlement, not normal release, runtime success or fixture retirement authority.
