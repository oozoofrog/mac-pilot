# Explicit recording workflow: headless readiness

Status: **normal-button runtime blocked; capture-only observer unchanged**.
The two failed product runtime attempts retain their original numbering and raw
results. No third lifetime is authorized by this note.

## Actual production call trace

`test_recording_call_trace.py` calls `capture.main()` with
`--prepare-recording <private folder>/recording-request.json`. It executes the
actual recording function, admission, claim reader, boot checks and Ledger reader.
Subprocess boundaries and SIGTERM are intercepted. The Xcode setting check and
recording environment readback use explicitly synthetic inputs. These are not
normal-button runtime qualifications.

Each admission has ten subprocess calls: canonical resident signature, selected
Xcode, Simulator SDK, Xcode version, device inventory, runtime inventory, exact
app container, app signature, executable entitlements, and exact data container.
After verified release and no live claim, one durable `.recording` marker precedes
one SIGTERM to the exact original PID. The launch argv is exactly
`/usr/bin/xcrun simctl launch <device> <bundle>` with the selected `DEVELOPER_DIR`
and per-launch `SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287`. Timeout is 15 seconds.
An uncertain launch permits one read-only
`/usr/bin/xcrun simctl spawn <device> launchctl list`, with a five-second timeout.
Replay performs admission again but cannot repeat the signal or launch.
Invalid release recovery and a real live harness claim prevent both operations.
No Engine or real child executes in this trace.

The capture-only observer still rejects this origin. Generic capture utilities,
wrapper paths, depth, counts and forward-exec rules were not broadened. The new
workflow needs a distinct native UI ancestry/artifact binding before admission.
A request's `explicitClick` field alone is insufficient evidence of a UI action.

## Transition design and evidence boundary

`ui_recording_contract.py` is an isolated, read-only transition predicate. It is
**not wired into remote_watchdog or the product runner**. It takes an explicit
request, original exact lifetime, typed scope, durable termination marker and an
independently verified release verdict. It then requires independent original
exit, fresh native new PID/start/path/device, unchanged boot/presentation scope,
independent app/data reconciliation and a second matching native read. Every
phase uses the caller's existing cutoff. Unknown outcome is terminal. The tests
reject missing exit, result-only authority, lifetime reuse, tracing, scope change,
container failure and deadline expiration. The boolean release/container inputs
are caller obligations, not implemented artifact validators or runtime receipts.

Future integration must validate the released ledger with production's complete
schema/proof rules; bind the private request, immutable prepared resource hashes,
selected Xcode setting, UI ancestry and one-shot marker; and retain the same
three-second observation cutoff. Both parent and worker observers must reconcile
the new lifetime before publication. The session's target binding, UI operation
binding, fresh capture, release evidence and cleanup owner must then agree on that
new lifetime. Do not rewrite process rows or accept a claimed result PID.

## Concrete runtime blockers

1. `recording_preparation.no_claim` rejects every live sim-pilot device claim,
   including the current harness worker. `Claim.check()` runs continuously during
   UI work and cleanup. `Claim.release()` removes the claim and closes the fixture
   lock. There is no transfer/lease primitive acknowledged by production. Dropping
   the claim around the click is unclaimed interaction and is not an acceptable
   handoff. The product check was preserved.
2. The SwiftUI fixture requires `--fixture-session <token>` and the matching
   `MAC_CU_FIXTURE_SESSION` environment variable at startup. The normal product
   button intentionally restores neither arguments nor environment. Its relaunch
   would exit 64. A separately reviewed, owned fixture startup contract is needed;
   silently adding fixture arguments to production is not the requested workflow.
3. The current runner always launches with recording flag 287. It cannot establish
   the missing-recording button's eligibility. Its observer/cleanup target binding
   is fixed to the original lifetime. No transition or new preparation origin is
   integrated, and no actual button callback has been exercised here.

## UI harness and source pin review

The recorded-launch UI lane now checks the actual button's visibility, enabled
state and target/action binding. It records eligibility without clicking a restart
that should be unavailable. These assertions must execute during a later runtime;
compilation alone is not UI evidence. Existing fresh graph/composite, branch
capture and stale-ID rejection assertions remain unchanged.

The UI change adds only control inspection and a JSON receipt. It adds no window,
process, queue or display read. The harness still creates one LCD and no
AppDelegate/MenuBar/StatusBoard. The passive device lane plus synchronous
handleQueue lane retains the aggregate two-display bound. Only live.swift's
SOURCE_PINS and canonical call-audit hash changed after this review.

## Proposed single runtime, for root review only

Keep normal-button qualification separate. After reviewing fresh headless build,
entry guards, manifest pins and existing reconciliation receipts, root may choose
the original capture-only **attempt 3** with one foreground owner and the existing
claimed SwiftUI fixture launched with flag 287. Retain the fixed deadline, input
and focus guards, singleton/process budgets, ordinary capture wireDigest binding,
exact release and cleanup. Do not click the recording button. Any uncertain
outcome stops the run and requires independent reconciliation without retry.

Normal-button runtime requires all three blockers above to be resolved and its
new origin/transition to pass complete adversarial observer tests first. No
runtime permission, attempt counter reset, installation or publication follows
from headless preparation.
