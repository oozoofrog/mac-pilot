# Production LCD → 3D Inspector qualification

Status: **Qualified for the stated UIKit/local AppKit scope** (2026-11-09).
Prior live9 evidence covers normal/minimum layout, camera zero-setter behavior,
selection/search, hidden/alpha apply/readback/revert, textures/tokens and refresh.
The focused continuation verifies the current receipt UI, automatic key transfer,
verified close/reopen with rotated owner and fresh capture, and real reserved
capture cancellation/close followed by terminal native release and stale UI fences.
No global installation, commit, push or publication was performed.

The host-only diagnostic reproduced the key-window failure without guest install,
attach or capture. The inspector first became key/main. AppKit then re-keyed the
LCD through `windowDeminiaturizationResponse` -> `_prepareToRestoreRegularFromDock`
-> `makeKeyAndOrderFront:`. Production called `deminiaturize` unconditionally on a
new non-miniaturized LCD. The narrow fix calls it only when `isMiniaturized`.
Initial accessory-to-regular activation and stable-active openings now pass the
same production button/coordinator path. No retry, forced inspector re-key,
external reacquisition, input-guard relaxation or backend delay was added.
This runtime call stack establishes a product restore race; incomplete initial
activation and nonactivating-panel action dispatch were not needed to explain it.

The first focused real run verified alpha apply/restore with exact independent
setter counts, rendered separate cleanup fields, cleared receipt after refresh,
native release and new-owner reopen. Cancellation hit actual durable reservation
before native dispatch. It is retained as a failed qualification attempt, safely
reconciled using all exact predecessor native release proofs plus the current
notDispatched/no-debugger receipt. No release success was invented for that capture.

The second focused run waits for an actual native terminal receipt while the
capture remains durably reserved, then uses Cancel and close. Thus it proves late
transport/UI delivery rejection after native completion, not interruption during
native traversal. The observed terminal had poolExited=true, operationContexts=0,
mainThread=true, traced=0, answerPublished=true and cancelObserved=false. Actual
capture and release transport receipts all succeeded (six joined operations).
UI authority remained stale/unselected/non-editable after native terminal release.
Parent/session independently verified cleanup, restoration and claim release.
Current runner intentionally selects this focused pending-only remainder;
`live.swift` retains the complete path and receipt-focused path for prepared requests.

Private evidence: `/private/tmp/mac-cu-focus-20261109/HANDOFF.md`.
Host regression: prepare with `--headless-entry --host-only`, then invoke
`host_runner.py --build ABS_BUILD --log NEW_ABS_LOG`. It verifies frozen inputs,
helper/unknown/inherited routes and uses a 30-second parent with exact executable
budget one. Host checks read only the selected device inventory/framebuffer.
Test-only swizzling and notification stacks are confined to `host.swift`.

Physical pointer/keyboard, human approval, broad rotation mapping and whole SwiftUI
value-view completeness remain outside the evidence. Local AppKit dispatch does
not establish those claims. Previous broad qualification and root full-suite
results are reused where their inputs are unchanged.

## Ownership and prerequisites

The lead must release the sole runtime owner after the SwiftUI worker finishes.
Run serially on an awake, unlocked console. Preserve the shared dirty checkout.
The focused continuation also owns the conditional LCD deminiaturization fix. No production test hooks were added.
The existing production AX live proof remains separate and need not be repeated.

Use the current `view-resident-product` UIKit C-main app, not the hierarchy fixture,
SwiftUI unsupported-entry test, or an archived snapshot. Fresh product preparation
must pass before UI preparation. Both preparations verify all recorded hashes
again before use. Changes to native inputs, backend, resident resources, app,
shared lifecycle or this harness require reprepare. Never use `--reuse-probe-from`
to bypass a changed input.

## Commands for the next runtime owner

Run from the repository root. Each output directory must be new. Set `DEVICE`
to the explicitly selected already-booted device claimed by this protected session.
Do not invent or silently select a device. These commands perform no global setup.

```sh
# Headless compilation/resources/signing and generated helper/reentry route proof.
python3 -B mac-computer-use/tests/simulator-inspector-product-live/prepare.py \
  --headless-entry --output /private/tmp/inspector-product-entry-NEW
python3 -B -m unittest discover \
  -s mac-computer-use/tests/simulator-inspector-product-live -p 'test_*.py' -v
python3 -B -m unittest discover -s scripts/tests -p test_native_check_safety.py -v
python3 scripts/validate_distribution.py

# After all owners freeze: fresh ordinary product and UI build, still headless.
xcrun python3 -B mac-computer-use/tests/view-resident-product/prepare.py \
  /private/tmp/inspector-product-prep-NEW
xcrun python3 -B mac-computer-use/tests/simulator-inspector-product-live/prepare.py \
  --product /private/tmp/inspector-product-prep-NEW \
  --output /private/tmp/inspector-product-ui-NEW

# Protected parent/worker/deadline transmission guard, no GUI/guest mutation.
xcrun python3 -B mac-computer-use/tests/simulator-inspector-product-live/runner.py \
  --guard --build /private/tmp/inspector-product-prep-NEW \
  --ui-build /private/tmp/inspector-product-ui-NEW --device "$DEVICE" \
  --output /private/tmp/inspector-product-guard-NEW \
  --deadline "$(python3 -c 'from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)+timedelta(seconds=1500)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

# Only after lead runtime authorization and exclusive desktop ownership.
xcrun python3 -B mac-computer-use/tests/simulator-inspector-product-live/runner.py \
  --live --build /private/tmp/inspector-product-prep-NEW \
  --ui-build /private/tmp/inspector-product-ui-NEW --device "$DEVICE" \
  --output /private/tmp/inspector-product-live-NEW \
  --deadline "$(python3 -c 'from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)+timedelta(seconds=1500)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
```

Do not execute either native binary's root entry outside this parent session.
The entry-only build has no product association and cannot be used for live mode.
No setup invocation, global app replacement, LLDB attach or foreground acquisition
is part of the test worker's headless delivery.

## Budgets and custody

Total parent deadline: **1,500 s**, including cleanup. Work admission ends at
**1,260 s**; shared parent reserves **235 s** cooperative grace and **5 s** receipt.
The UI child has **1,100 s** parent wall time and stops admission at **1,080 s**.
The shared exact target cleanup reserve is **117 s**. Each async UI operation wait
is at most **165 s**; independent oracle waits are **8 s**. No wait extends the
original parent deadline. Captures retain the actual **120 s TTL**; edits refuse
when fewer than five seconds remain. A slow sequence can fail its budget; that
is not permission to refresh authority or retry a write automatically.

Budgets: parent1, session worker1, guest app1; UI1 OR read-only Swift probe1;
normal resident supervisor1, LLDB worker1, selected debugserver1; serialized fixed
utility1. A screenshot child1 must have the exact UI process as parent. Permission
helper1 exists only during generated headless route checks (each five seconds,
exact executable budget1); live permission prompts/reentry are unexpected and fail.
The process validator imports the current product runner and maps only the exact
new UI executable to its established probe topology. It does not copy lifecycle or
obsolete watchdog code. The shared parent observes group topology and cooperative
cleanup; it does not acquire signal authority over guest/debugger descendants.

One declared foreground acquisition opens the actual LCD. Local `performClick`,
`sendAction`, outline row selection and control-delegate notifications drive the
actual AppKit controls. Global event counters, exact front application, claim,
window focus, process topology and wall time remain guarded. External input/focus
loss stops admission without repeated activation. Prior focus and toolbox defaults
are restored only while guards remain valid.

On missing native release proof, UI failure, deadline, unknown process, pending
callback or unreaped UI child, raise `ProbeCleanupUnknown`. Preserve app, data,
ledger and claim. The shared session must not terminate/uninstall the target in
this condition. Reconcile exact custody read-only before another runtime attempt.
A UI close request or UI authority revocation alone is not release completion.

## Required runtime evidence

The harness constructs `SimulatorWindow` for the selected actual device, uses its
Toolbox **3D 뷰 검사…** button and untouched default coordinator/backend. The UI
never calls a Swift transport wrapper directly. It checks open and camera controls
without capture, unselected edit gates, explicit capture, current-process texture
assets and editable tokens, outline selection/detail, search clearing selection,
hidden and alpha apply/readback/restore and exact independent guest setter counts.
Refresh must deselect and mint new tokens. Normal/minimum LCD and inspector
screenshots include per-view geometry; text height checks use intrinsic fitting
height, while editor overflow stays scrollable. Inspect the PNGs for actual
visibility, scroll reachability, texture content and clipping before accepting.
Geometry is limited to the tested orientation and size; no broad rotation mapping
is claimed. Local dispatch and visible windows do not prove physical pointer input
or human approval.

Every ledger checkpoint keeps pre-transition operation IDs. The read-only evidence
join matches each ID, kind, target and `validationOnly == false` to existing
`request.json`/`result.json` receipts and copies their existing transport folders.
Final cleanup requires durable `released`, release proof, registry release,
detach, children reaped and same-target recovery before target termination.
`session.json` and `parent.json` must independently show exact restoration, claim
release, group cleanup and bounded completion. No fake operation-count callback
or synthetic completion is used.

Close/reopen must use a new owner. The focused in-flight test waits for a real new
capture reservation and native terminal publication before pressing Cancel and closing. After actual terminal release,
the closed controller must remain stale, unselected and unable to edit/revert.
If the real transport completes too quickly to expose a reserved operation, this
race remains unqualified; the harness fails instead of injecting a delayed/mock
backend. Keep failure artifacts and request lead review before another run.

## Owner rotation and evidence limits

The lead's new-window owner rotation source was included in every fresh build.
The close/reopen runtime assertion passed in the focused continuation.
Existing-window reuse, shared serial queue, release requirements and stale ticket
fences were not changed. No support tuple, native runtime-stack proof, ledger fence,
expiry, typed mutation or watchdog/process budget was weakened.

This run used ordinary UIKit, not SwiftUI. Earlier SwiftUI startup evidence remains
separate. A hosting PNG can omit SwiftUI value-view text/shapes; no whole SwiftUI
value-view capture claim is made. UI actions here are local AppKit dispatch and
rendered-window observations, not physical pointer/keyboard or human approval.
