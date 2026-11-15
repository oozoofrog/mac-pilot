# UIKit edit qualification: runner and live qualification boundary

The latest conditional-pool experiment was **rejected and removed**. Omitting the
expression-local pool in LLDB's no-exception mode did not release either A/B
sentinel. It also prevented C from completing deallocation/replacement within its
bound. D and the normal ten-operation sequence passed with that candidate.
Canonical successful-return pool behavior is restored; only its lifetime comments
changed. The interrupted-cleanup blocker and disabled general gates remain.
See [Conditional-pool experiment](#conditional-pool-experiment-rejected) below.

The fixed ten-operation schema-2 sequence passed on the owned ordinary iOS 27.2
build `24B114` device with Xcode `27B48` and host build `26B123`. The successful
fixture session took 65.824 seconds. All three captures produced 15 canonical
Swift-validated, token-bound PNG assets. Hidden and alpha edits and their server
undo operations each invoked exactly one corresponding setter. All three releases
returned exact release proofs and zero owned entries. Same-owner recapture and
new-owner reopen produced fresh inspections, epochs, captures and tokens.

Fixture PNG review showed the target disappear/return for hidden edit/undo and
become lighter/return for alpha 0.5/undo. Node, parent, window and scene generations
remained unchanged. Detach, same-lifetime recovery, exact child reaping, fixture
removal, original guest/host/display restoration and claim release passed. A
separate read-only audit found no remaining fixture app/data, claim, probe or
owned session-group process. General capture/edit gates remain false. This is
fixture UIKit qualification; LCD/3D rendering, general-app qualification, global
installation and publication remain separate.

The subsequent four bounded failure families are complete. Actual weak-target
deallocation/replacement and same-view reparenting were refused before setter
entry. Actual throw-after-write and parent cancellation recovered the process but
did **not** establish autorelease cleanup: each created sentinel had no deallocation
event during six seconds of fresh post-recovery observation. This blocks product
edit enablement. The unchanged host catch tests do not override this live result.

Root reviewed the first attached schema-2 stack and corrected its fixture-only
admission predicate. The measured `HierarchyFixture.FixtureEntry.main/$main`
pair is allowed only directly below `UIApplicationMain`, followed by `main` in
the exact same executable. `start_sim` must come from the same RuntimeRoot as
UIKitCore and immediately precede `/usr/lib/dyld`'s `start`. Arbitrary Swift
entry names, reordered or extra app frames, foreign runtime loaders, nested
callbacks and non-idle stacks remain rejected. All ten successful operations
recorded this exact candidate stack before injection and separately confirmed
main-thread execution. The policy was not widened during runtime qualification.

## Owned implementation

Runner and fixture changes are under `mac-computer-use/tests/view-hierarchy-fixture/`.
The live compiler corrections are confined to canonical `capture.py`, `edit.expr`
and their tests. Production AX, host UI, Swift wrappers, public schema and general
qualification gates remain unchanged.

The selected LLDB parser uses MRC but imports module declarations separately.
The expression now supplies explicit receiver/result/container types where its
lazy method lookup cannot infer them, preserves all retain/autorelease operations,
and avoids the observed loaded-image symbol collision on the local name `state`.
Finite checks use `__builtin_isfinite`; the SDK's inline libc++ `isfinite` wrapper
type-checked but could not be resolved by the live JIT.

LLDB also disables Objective-C exception compilation. The expression uses a
target-side catch only when `OBJC_ZEROCOST_EXCEPTIONS` is defined. Otherwise the
existing LLDB exception trap aborts evaluation, and the canonical host records
`dispatchResultLost/uncertain`, quarantines authority and never retries. No target
busy bit is reset after an aborted expression. Actual compiler ownership and the
chosen exception boundary are recorded after the main-thread proof. Schema-2
evaluation disables automatic compiler fix-its. The failure qualification below
now measures trap/unwind recovery and records its interrupted-pool cleanup gap.

- `session.py --edit-qualification` extends the existing protected parent/worker
  route. The geometry and schema-1 texture modes retain their default budgets and
  routes. The modes are mutually exclusive.
- `edit_qualification.py` performs the fixed ten-operation sequence below. It
  admits only the explicitly named `MacCUQualificationEditTarget` class, exactly
  once in the canonical snapshot. The fixture gives that class the identifier
  `fixture.editTarget`. Schema 2 currently omits accessibility identifiers, so
  selection uses the unique class name and opaque snapshot token. No address
  lookup or numeric address cast is used for selection or mutation.
- `edit-supervisor.py` calls canonical `capture.py:supervise`, with a test-owned
  `ledger_root` inside the evidence directory. The canonical `run_engine` and
  `LLDBEngine` remain the only debugger path. Its `Popen` boundary records the
  actual direct children and their kernel lifetimes; it does not substitute a
  transport. There is no ledger path, expression, force or mutation toggle in the
  closed public request. The global private ledger is not used by this runner.
- `capture-converter.swift` selects the canonical schema-1 or schema-2 Swift
  converter. `session-probe.swift` calls this same function. Schema-2 textures
  therefore pass the production PNG, byte/size, capture, token and parent-join
  checks. The runner exports validated asset bytes with their actual capture ID,
  asset ID, node token and hash. Exporting bytes does not establish rendered UI.
- `fault-target.m` implements the named fixture UIView in Objective-C with ordinary
  `super` calls and hidden/alpha counters. Its two fault setters remain entirely
  within Objective-C frames. `edit-oracle.swift` observes the view. The seven geometry nodes and the old
  geometry oracle schema are unchanged. The separate atomic `edit-oracle.json`
  samples actual values every 0.2 seconds. It keeps at most 128 samples and
  256 KiB. Each sample includes PID, scene ID/state, node/parent/window/scene
  generations and setter counts. Construction counters have an explicit
  baseline. This instrumentation is fixture-owned; production requires no SDK.

## Fixed primary sequence

| Operation | Inspection sequence | Expected independent observation |
|---|---:|---|
| Textured editable capture | 1 | Named target visible, alpha 1; construction baseline unchanged |
| Hidden false → true | 2 | Hidden true; hidden setter count +1 |
| Server undo hidden | 3 | Hidden false; hidden setter count +1 |
| Alpha 1 → 0.5 | 4 | Alpha 0.5; alpha setter count +1 |
| Server undo alpha | 5 | Alpha 1; alpha setter count +1 |
| Release | 6 | Exact release proof, zero owned registry entries, no setter change |
| New inspection, same owner | 1 | Fresh capture/epoch/tokens; original values and generations |
| Release | 2 | Exact release proof; no setter change |
| New inspection, new owner | 1 | Fresh capture/epoch/tokens; original values and generations |
| Final release | 2 | Exact release proof; no setter change |

Each operation gets one UUID, one sequence and one canonical request digest.
Undo requests contain the server's undo token; the runner does not construct an
inverse edit. Release never undoes a property. Recapture and reopen use fresh
inspection IDs only after verified release. Target PID, kernel start, executable
path and device must stay identical through the whole primary sequence.

For every operation the evidence includes the original request, canonical
receipt, selected main-thread stack saved before injection, target identities
before/after attach, detach/recovery, exact child identities and exit/readback.
The oracle must produce a fresh sample after debugger cleanup. Generation or
counter drift fails the sequence. Visible screenshots are separate artifacts
before changes and after hidden/alpha edits and undo. Root must inspect those
pixels; neither readback nor a PNG file establishes the visible result.

There are no automatic retries, replacement operation IDs after uncertainty,
public fault toggles, saved-address reconstruction or alternative debugger entries.
Failure stops the sequence. An observed mutation remains observed when a later
input, cancellation or cleanup check fails. A missing result remains unknown.
Cleanup validation runs even when an input/focus interruption ends the wait.

## Deadlines and ownership

The CLI requires an explicit already-booted `--device` and a fresh finite UTC
`--deadline`. It converts wall time once to `CLOCK_MONOTONIC`; parent and worker
receive the same absolute deadline. The internal total ceiling is 3,300 seconds.
This is a cleanup-safe ceiling, not a target duration or capture lifetime.

| Reservation | Seconds |
|---|---:|
| Setup allowance | 180 |
| Pre-operation probe | 25 |
| One canonical supervisor operation | 163 |
| Post-operation observation/conversion | 72 |
| Final fixture/foreground/claim cleanup | 117 |
| Final parent receipt | 5 |
| Full sequence admission minimum | 2,902 |
| Parent cooperative stop margin | 352 |

The admission minimum is `180 + 10 × (25 + 163 + 72) + 117 + 5`.
Every new operation independently reserves its complete pre-probe, supervisor,
post-observation and final session cleanup. The 163-second supervisor ceiling
preserves the canonical 45-second work and 100-second cleanup budgets plus outer
margin. The 72-second post allowance includes two 25-second probes, an 8-second
screenshot, an 8-second oracle wait and 6 seconds of readback margin. Operations
are serial; unused time does not extend another operation's own deadline.

Capture TTL stays 120 seconds in production, with wall and monotonic/uptime
checks. The runner also keeps a conservative monotonic cap from capture dispatch.
It refuses expired authority clearly and does not extend TTL, automatically
recapture, or skip an operation to make the run pass. Slow cleanup can therefore
make this primary sequence fail despite time remaining in the session budget.

The session permits one fixture, one supervisor, one LLDB worker, one
debugserver and one read-only probe, with serialized simctl commands. The parent
checks executable paths and child topology. The supervisor records kernel start
identities, exact executable/parent matches, direct-child waits and absence after
cleanup. The parent performs a final session-group readback without group signals.
The probe retains its separate direct-child watchdog and group readback.

Host event counters and host focus are observed during operation waits. The
focus read uses `NSWorkspace` through the Objective-C runtime; it does not use
AX, inject events or activate an app. Guest foreground, display, host lifetime,
and unlocked state are checked before/after operations. Cancellation or input
loss prevents further operations and foreground restoration input. Unknown
debugger/probe cleanup preserves the fixture and claim for review. No target
signals, all-thread fallback, group kill, broad process-name cleanup or blind
reaper kill is added.

Fixture uninstall requires the exact owned installation and confirmed fixture
exit. Original guest restoration requires its matching PID/start/path/device and
running/untraced state. Host PID/start/path, display and window layout must agree.
The runner never relaunches a replacement lifetime or forces host focus. Claim
release checks the exact owner and reads back the resulting claim file. Partial
or unknown cleanup is reported as failure and retains evidence.

## Preparation checks available now

From the repository root:

```sh
python3 -B mac-computer-use/tests/view-hierarchy-fixture/check-edit-preparation.py
```

This command writes a unique private temporary evidence directory. It runs the
26 existing session regressions, the new schema-2 sequence/runner checks, the six
native-safety regressions, fixture build/sign/entry guards, and focused compilation
of `SimulatorViews.swift`, `SimulatorViewHierarchy.swift` and the shared converter.
The guarded focused executable exercises both converter routes and the existing
typed wrapper refusal/receipt checks. It does not build the changing whole host,
run UIKit, query a live Simulator, attach LLDB or install anything.

The directory contains `checks.json`, full named logs, `source-hashes.json`,
`artifact-hashes.json` and `qualification.json`. The fixture's
`fixture-prepared.json` explicitly marks the whole probe unverified. Unbuilt
native input hashes are inventory only. A fixture-only build cannot authorize
the runtime session. All generated apps, captures, private ledgers and logs stay
outside Git and release resources.

## Root commands after AX native source freeze

Root must first finish the native peer work and own the only foreground/runtime
check. Use a new directory and rebuild the whole probe; do not reuse a pre-freeze
probe for the first run of this mode.

```sh
work="$(mktemp -d /tmp/mac-cu-uikit-edit-qualification.XXXXXX)"
python3 -B mac-computer-use/tests/view-hierarchy-fixture/prepare.py "$work/prepared"
```

`prepare.py` hashes all fixture/test sources, generated dispatch, canonical
resources, whole Swift sources and `native_inputs` before/after preparation.
Changed inputs invalidate the build. The full preparation proves existing
helper/unknown/inherited entry routes before any GUI use and writes
`prepared.json` with `wholeProbeVerified` and `editQualificationReady` true.
Existing reuse checks remain strict; the shared converter is now also a reuse
input. Subsequent changes invalidate prepared reuse.

Use an explicit booted device UUID. The guard command below exercises the same
deadline transmission but performs no device read, claim, launch or attach.

```sh
device='EXPLICIT_ALREADY_BOOTED_DEVICE_UUID'
deadline="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=3300)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
xcrun python3 -B mac-computer-use/tests/view-hierarchy-fixture/session.py \
  --guard --edit-qualification --build "$work/prepared" --output "$work/guard" \
  --device "$device" --deadline "$deadline"
```

Only after root grants the runtime window on an unlocked desktop, generate a
**new** deadline immediately before the actual run:

```sh
deadline="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=3300)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
xcrun python3 -B mac-computer-use/tests/view-hierarchy-fixture/session.py \
  --edit-qualification --build "$work/prepared" --output "$work/live" \
  --device "$device" --deadline "$deadline"
```

Retain `prepared.json`, `parent.json`, `session.json`, `edit-sequence.json`, every
operation directory, private ledger, oracle copies, texture asset maps and
screenshots. A successful process exit is insufficient without successful
fixture removal, restoration, claim release and zero owned-child readback.

The runtime command must use Xcode's Python, as the production Swift wrapper does.
The parent imports the selected Xcode LLDB extension in the same isolated Python
interpreter before any device read, claim or fixture installation. An incompatible
interpreter fails admission; it is not silently replaced. A confirmed pre-attach
failure with no injection artifacts, unchanged target lifetime and fully reaped
children can clean the fixture. Missing or contradictory cleanup evidence still
preserves the fixture and claim; no operation is retried.

## Earlier runtime stops

The first attempt used Homebrew Python 3.15, which cannot load the selected
Xcode LLDB extension. The canonical worker reported `notDispatched`,
`connected=false`, `attachRequested=false` and `mutationOutcome=notEntered`.
Independent oracle counts stayed at their construction baseline. The runner
initially classified `detach: not attempted` as unknown cleanup. An explicit
read-only reconciliation established the unchanged running/untraced lifetime and
absent debugger children before exact fixture removal and claim release. No
restoration input was required. The runner now distinguishes this complete proof
from missing or contradictory cleanup evidence and checks interpreter admission
before installation.

The second independent run used Xcode's Python and the fresh whole probe. Its
saved pre-injection stack contains the expected kernel Mach wait, CoreFoundation
run loop and `UIApplicationMain`, followed by the fixture's Swift
`FixtureEntry.main()` and `FixtureEntry.$main()` frames, `main`,
`dyld_sim/start_sim`, and `dyld/start`. The predicate at that time admitted only the
fixture's `main` frame and does not admit `dyld_sim/start_sim`. It therefore
returned `unsafeEntry` before even the BOOL main-thread expression. That worker
preserved the rejection for root's explicit policy review.

Canonical detach and same-lifetime running/untraced recovery passed. Both
debugger children were reaped and absent. Independent actual hidden/alpha values
and setter counters remained at their construction baseline. The session verified
fixture removal, original guest/host/display restoration, claim release and an
empty owned process group. This is a failed qualification with verified cleanup,
not a successful primary sequence.

After root's narrow startup correction, two additional independent fixture
lifetimes failed before an answer: first on LLDB ownership/type compilation, then
on the unresolved libc++ finite predicate. Their original uncertain receipts were
preserved. Both lifetimes completed verified cleanup before another deliberate run.
The compiler corrections above then enabled the successful ten-operation sequence.
All raw evidence, original screenshots, private ledgers and hashes remain outside
the source tree.

Current checks pass: 61 Python capture/edit tests, 1,454 host-expression assertions,
26 session regressions, 19 qualification tests, six unchanged native-safety tests,
the actual process-free LLDB expression/predicate checks, both MRC syntax branches,
ARC rejection, full canonical typecheck, native entry guards and distribution.
The host-expression exception assertions use a compiled target-side catch. They
do not establish live LLDB trap/unwind behavior.

`check-edit-modules.py --fixture EXISTING_EXECUTABLE --output NEW_DIR`, run with
`xcrun python3`, parses the complete canonical expression with JIT and automatic
fix-its disabled. It also interprets the production finite predicate on finite,
infinite and NaN constants without a process. This catches failures that standalone
Clang syntax or an unevaluated `sizeof` alone misses.

The primary runtime sequence consumed each server undo token once and preserved
two verified predecessor release proofs in the final ledger. It did not issue a
duplicate undo or a stale retired request against the live target. Those rejection
paths retain their headless coverage and are not claimed as live fault tests.

Same-address reuse, window/scene replacement, process restart/PID reuse,
nonreturning setters, other cancellation boundaries, lost transport responses,
detach failures, memory bounds and ordinary-app/runtime qualification remain
separate work. The four bounded cases below do not qualify those paths. General
capture/edit gates remain false.

## Original four bounded actual failure families

`session.py --failure-case throw|cancel|replace|reparent` runs one family in a new
owned fixture lifetime through the existing protected parent. The canonical
`capture.supervise → run_engine → LLDBEngine` path performs capture and the one
edit/refusal operation. The fixture-only control file accepts exactly a request
UUID, fixed action, session token, PID, node generation and issue time. The timer
accepts a control once, within eight seconds, for the matching fixture lifetime.
No selector, expression, address, arbitrary value, delay or fault mode was added
to the public schema. There is no production fault implementation.

The fixture uses explicit MRC for its Objective-C setter. A sentinel is created
and autoreleased inside the setter, outside the event writer's own local pool.
The independent atomic event file records entry, actual applied value/counters,
sentinel creation/deallocation and target generation/deallocation. The bounded
model oracle continues to sample on the normal main run loop after recovery.
The controller and oracle retain the selected view only weakly. Replacement
removes it, waits for weak nil in a later timer turn, then creates one view with
the same class, label and frame. Diagnostic addresses are observed only; no
address selects an edit or reconstructs an object.

| Family | Actual result | Independent model | Full qualification |
|---|---|---|---|
| A: throw after write | `expressionError`, `resultLost`, `uncertain`; no target answer or undo | hidden false → true, hidden count 1 → 2, alpha count 1; one sentinel created, no deallocation event | **Blocked** by interrupted autorelease cleanup |
| B: parent cancel after finite setter entry | `cancelled`, `resultLost`, `uncertain`; no target answer or undo | Same applied value/counts; cancellation follows the independent four-second-delay entry marker; setter never records return; sentinel has no deallocation event | **Blocked** by interrupted autorelease cleanup |
| C: deallocate/recreate | Target expression returns `conflict/weakNil/notEntered` | Old generation deallocates; replacement keeps class/label/frame and construction counts 1/1; no extra setter | Passed for observed deallocation; allocator used a different address |
| D: reparent the same view | Target expression returns `conflict/staleGraph/notEntered` | Node/window/scene stable; parent generation changes; counts remain 1/1 | Passed for a different parent in the same window |

Each case used one capture and one edit/refusal, with a separate claim and exact
PID/kernel-start/path/device. All eight operations recorded MRC and
`lldbTrapAndHostUncertainty`, the approved main stack before dispatch, main-thread
proof, successful detach, same-lifetime running/untraced recovery, and two reaped
and absent debugger children. All four sessions removed their exact fixture and
data, restored the original guest/host/display state, released the claim, and
observed an empty owned process group. Worker durations were 25.201 seconds (A),
24.496 (B), 26.008 (C) and 19.308 (D).

The A receipt preserves LLDB's original exception-breakpoint error, including its
statement that execution returned to the state before evaluation. The independent
write remained applied; that debugger statement is **not rollback**. Raw
`setterEntered: false` with `mutationOutcome: uncertain` remains unchanged and
does not assert non-entry. The separate oracle proves entry and application.
An exact replay returned the retained uncertain receipt without child creation;
a new operation ID under the old authority was quarantined before child creation.
Both checks produced zero extra setters. B admitted no subsequent target operation.

The existing 3,300-second parent ceiling and conservative full-sequence admission
reserve remain. Each operation reserves 25 seconds preflight, 163 seconds canonical
work/cleanup, 72 seconds observation and 117 seconds final session cleanup. Controls
have an eight-second bound; the slow setter has four seconds finite work; sentinel
observation has six seconds. The 120-second capture TTL is unchanged. A new case
starts only after known complete cleanup of the previous lifetime. No uncertain
operation is retried, inverse-edited, force-drained or released through new injection.

The two missing deallocation events are a concrete cleanup qualification failure,
not evidence of a stuck/traced process. A Foundation-only positive control executes
the exact sentinel/event-writer body and verifies deallocation on normal explicit
pool drain. That control does not establish LLDB cleanup. No safe production fix
was inferred from the debugger's register/stack recovery. General gates remain
false, and ordinary SDK-free app and LCD/3D qualification remain separate.

Evidence is retained in `/private/tmp/mac-cu-uikit-failures-bneiien8`: each
`live-*` tree contains raw requests, digests, dispatch/answer presence, compiler
and stack receipts, model/events, child ownership, session cleanup and parent
readback. Original uncertain receipts are not rewritten. `HANDOFF.md` and the
complete hash manifests describe the checks and remaining limits. No global
installation, AX/UI change, input injection, other-device operation, Git operation
or publication was performed.

## Conditional-pool experiment: rejected

Evidence root: `/private/tmp/mac-cu-uikit-pool-dlgt1l6q`. The proposed conditional
`@autoreleasepool` was tested in five fresh fixture lifetimes on the same owned
ordinary device `64A62D96-12FE-4D9C-81AE-ED9C3A2174F0`. Refreshed inventory and
identity evidence confirmed iOS 27.2/24B114, Xcode 27.2/27B48, host 26B123, and no
existing claim or fixture. No other device was operated.

The hypothesis was insufficient. Disabling the lexical pool does move normal
autoreleases into the caller pool in the compiled Foundation harness. However,
the admitted UIKit idle stack does **not** establish bounded drainage of that
pool. Both actual fault sentinels remained alive through another 34 fresh model
ticks. The exact enclosing pool and its runtime drainage mechanism were not
observed; no pool pointer was saved, inspected by a cleanup expression or popped.

| Candidate run | Observed result | Qualification |
|---|---|---|
| A: throw after write | `expressionError/resultLost/uncertain`; hidden count 1 → 2; one sentinel created, no deallocation through 6.799 s / 34 fresh ticks after recovered sample | Failed lifetime cleanup |
| B: parent cancel after finite setter entry | `cancelled/resultLost/uncertain`; hidden count 1 → 2; one sentinel created, no deallocation through 6.801 s / 34 fresh ticks | Failed lifetime cleanup |
| C: remove/deallocate/recreate | Capture succeeded; fixed control timed out with `fixture control not acknowledged; no operation follows`; no target deallocation or replacement event | Failed prerequisite; stale-token edit was never dispatched |
| D: reparent | `conflict/staleGraph/notEntered`, unchanged 1/1 setter counts, same node/window/scene and changed parent | Passed bounded refusal |
| Normal sequence | All ten operations succeeded in 61.303 s; 15 token-bound PNG assets per capture; exact hidden/alpha setter deltas, server undo and three release proofs | Passed candidate sequence only |

C is a regression from the original local-pool run. Its retained control file
matches the issued request, and the old generation has no deallocation event.
The model stops persisting samples when the removed target no longer has a
window. Traversal retention in the undrained caller pool is consistent with this
result and the compiled lifetime test; the live file evidence does not directly
observe the pending weak-reference state. No same-address reuse was observed or
required. There was no second C edit or retry.

Both A/B retained their raw missing-answer receipts and supplied no undo token.
The independent model proves the write; it does not upgrade canonical certainty.
For each case, canonical retained-receipt replay and a new ID under old authority
were checked with child construction forbidden. Both produced zero debugger
children and zero extra setters. B still forbids every subsequent target operation;
these two checks stop at host admission. No busy reset, release injection, inverse
setter, inferred rollback or post-uncertainty cleanup expression was used.

The runtime audit (`/private/tmp/mac-cu-uikit-pool-dlgt1l6q/runtime-audit.json`)
joins all **17** actual operations to exact request digests, main-stack and compiler
receipts, target lifetimes, answers or absence, child ownership and oracle samples.
C contributes one capture; A/B/D contribute two operations each; normal contributes
ten. Every attach detached successfully, recovered the same running/untraced
process and reaped its two debugger children. All five sessions removed their
owned app/data, restored the same original guest and host lifetimes/display/windows,
released their claim and left an empty process group. The independent
cleanup readback (`/private/tmp/mac-cu-uikit-pool-dlgt1l6q/final-cleanup-readback.json`)
found zero owned target/probe/group processes, fixture installations/data or claims.

The rejected expression and its complete 100-input freeze are retained under
`runtime-source-snapshot/`, `prepared/`, `source-freeze-sha256.json` and
`rejected-pool-candidate.patch`. Those runtime artifacts must not be described as
qualification of the final restored source. `prepared-final/` separately rebuilds
the fixture and packages final current resources. Each preparation reuses only
the whole probe after its built-in **56** native source/binary checks; each copied
probe passes current helper/unknown/inherited-entry guards. The original failure
and successful-primary-sequence evidence directories remain untouched.

Final retained changes are limited to accurate expression lifetime comments,
successful-return lifetime regression coverage, A/B host-admission evidence and
this document. The new Foundation regression executes the canonical expression
with Objective-C exceptions both enabled and disabled. It requires sentinel
deallocation and weak-map clearing on successful return, before the caller pool
drains, then checks no second deallocation. It fails against the rejected
candidate and passes against the restored expression (**20 assertions**).
`view-edit-production/run.py` now invokes it after the existing **1,454** assertions.
These checks do not establish interrupted LLDB cleanup.

Other focused checks: **61** backend tests, **53** fixture tests (8 failure,
19 sequence, 26 session), **6** native-safety regressions, selected-Xcode
process-free LLDB parsing/ownership/finite predicates, fixture build/signing,
entry guards and distribution. Detailed logs, final source/binary hashes,
artifact hashes with explicitly rooted relative keys, narrow diff and remaining
limits are linked from
HANDOFF.md (`/private/tmp/mac-cu-uikit-pool-dlgt1l6q/HANDOFF.md`).

No correct interruption-lifetime fix is qualified. Lead integration still owns
the mechanism decision. General/current-app capture/edit, onscreen LCD/3D UI,
other fault boundaries and memory bounds remain separate. No global installation,
credentials, Git commit/push/publication or AX/UI/Swift-wrapper edit occurred.
