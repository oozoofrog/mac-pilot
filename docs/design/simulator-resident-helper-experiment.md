# Resident helper: bounded A/B lifetime experiment

This fixture-only experiment tests the mechanism selected in [the lifetime decision](simulator-debugger-lifetime-decision.md). It changes no production capture/edit source, schema, wrapper, manifest, or general qualification gate. Preparation is headless. A signed Simulator image and process-free LLDB parsing do **not** establish guest loader authorization or UIKit lifetime behavior.

The harness is [view-resident-lifetime](../../mac-computer-use/tests/view-resident-lifetime/). The existing fixture session has a narrow injectable experiment/worker route; its claim, input/focus guards, installation identity, restoration and failure-preservation rules still apply. There is no forked session implementation or new app integration.

## Fixed mechanism

- `resident.m` compiles with explicit MRC and Objective-C exceptions. Its only exported operation is `mac_cu_resident_submit(directory)`. The 2,554-byte wire contains bounded scalar identities and paths, one operation, sequence 1, an expiry and SHA-256. It cannot encode a target address, callback, selector, KVC key or code. The bootstrap copies all request bytes into one native context. No caller/JIT pointer escapes.
- Selected LLDB verifies the owned stopped main thread, loads one normally signed helper with `SBProcess.LoadImage`, verifies its UUID/path and exported entry, calls only that short bootstrap, and detaches. Submission stops other threads, has a 2-second expression deadline, disables exception trapping and does not force unwind. It never pumps a run loop. The load token is retained as evidence; no unload route exists.
- An ambiguous loader/submission return retains the actual LLDB engine, private transport and direct debugserver. The worker does not detach or destroy the debugger, and its supervisor does not reap either child without the worker's closed-debugger receipt. The bounded session reports pending recovery and preserves fixture/claim; the retained custody is an unresolved failure, not an extended test or successful cleanup. A stopped checkpoint or successful detach does not prove Objective-C catch/pool cleanup.
- The image's static `dispatch_async_f` callback observes its own image/PC, process start, executable, device, owner, main thread and traced state through compiled C. It refuses before traversal/setter if still traced. Fresh bounded UIKit traversal finds the exact fixture class, identifier, generation, scene and parent. It checks the original hidden value/count and calls one `setHidden:YES`.
- The catch is **inside** the callback's local pool. It stages capped C receipt bytes there. Work-finished publication precedes pool drainage; terminal publication follows actual pool exit and native context release. A caught post-write throw stays uncertain with no undo. The one-slot reservation never reopens, including after completion.
- A setter return is `enteredUnverified`, not `appliedObserved`: this helper does not read the property back. The independent fixture oracle verifies the applied value separately and never rewrites the native receipt.
- Request/receipt/cancel paths are fixed within a new owner-private directory. Directory traversal rejects symlinks; file reads require ownership, regular type, one link and bounded bytes. Cancellation revokes host authority before publishing its marker. After setter entry it never interrupts the target. A late result cannot restore that authority.

## Cases and acceptance

Run **A**, throw after write, and **B**, cancel after the independently persisted finite-setter-entry event, in separate fresh fixture lifetimes. B retains the fixture's existing 4-second finite setter. No nonreturning stress or full capture/edit matrix is included.

Both must prove one requested setter on the original generation, native untraced main-queue entry after submission/detach, callback PC in the pinned image, sentinel deallocation between work-finished and pool-exited, ordered terminal publication and zero remaining operation contexts. Observe the original post-write state first. Only then use the fixture's existing `replace` control to prove original target deallocation and weak clearing. Replacement construction is a separate fixture action, not another operation on the selected generation. The subsequent timer/control receipts establish main-queue progress. Require the original process identity to remain responsive/untraced, debugger children reaped, and the protected session's exact fixture/claim/foreground restoration.

One dylib remains resident until process exit. Receipts report its file and mapped-section sizes and the helper's bounded scalar tombstone bytes. This is not a total process-memory measurement. No operation-owned view or context may remain after terminal publication.

Any ambiguous load/submission, timeout, absent terminal, extra setter, missing sentinel/weak evidence, or failed recovery stops admission and preserves the fixture/claim. Host boundedness is not target recovery. Do not retry, force return, pop a pool, reset busy, inverse-edit, unload, re-sign the target, or run B after a failed A without a separately resolved ownership/recovery decision.

## Preparation and guarded execution

```sh
python3 -B mac-computer-use/tests/view-resident-lifetime/prepare.py /private/tmp/UNIQUE-resident-prepared
python3 -B -m unittest discover -s mac-computer-use/tests/view-resident-lifetime -p 'test_*.py' -v
python3 -B -m unittest discover -s mac-computer-use/tests/view-hierarchy-fixture -p test_session.py -v
python3 -B -m unittest discover -s scripts/tests -p test_native_check_safety.py -v
python3 scripts/validate_distribution.py
```

Preparation uses the existing `prepare.py --fixture-only`; it does not compile the changing whole-host Swift tree. Host console controls cover normal return, caught throw, finite post-entry cancellation and pre-entry cancellation. Native guard routes run under an exact one-process parent bound. The selected LLDB probe has no process and JIT is disabled; it checks the public loader binding and parses the exact submission shape. Sources, commands, toolchain/binary hashes, signature/platform/architecture, IR and full logs stay in the external preparation directory.

**Before live execution:** the foreground owner must finish/freeze the canonical host sources and run the existing fixture `prepare.py` without `--fixture-only`. `--reuse-probe-from` is allowed only when that script verifies every required dependency and binary byte. This experiment refuses a missing/stale whole-probe build. It never builds or installs the global app.

Supply a fresh absolute UTC deadline at most 480 seconds away. The guard uses the same parent/worker deadline route and makes no Simulator reads or mutations. `$DEVICE` is merely UUID syntax in the guard. Actual A/B commands require the selected already-booted device and explicit runtime ownership.

```sh
xcrun python3 -B mac-computer-use/tests/view-resident-lifetime/runner.py \
  --prepared "$PREPARED" --output "$GUARD_OUT" --device "$DEVICE" --deadline "$DEADLINE" --case A --guard

# Runtime owner only; separate commands and separate output directories/deadlines.
xcrun python3 -B mac-computer-use/tests/view-resident-lifetime/runner.py \
  --prepared "$PREPARED" --build "$FINAL_CANONICAL_BUILD" --output "$A_OUT" \
  --device "$DEVICE" --deadline "$A_DEADLINE" --case A
xcrun python3 -B mac-computer-use/tests/view-resident-lifetime/runner.py \
  --prepared "$PREPARED" --build "$FINAL_CANONICAL_BUILD" --output "$B_OUT" \
  --device "$DEVICE" --deadline "$B_DEADLINE" --case B
```

Each session allows 480 seconds: 240 work, 235 cooperative cleanup reserve, 5 receipt. Bootstrap allows 30 seconds, then 10 seconds worker grace. Only a closed-debugger receipt permits the two direct-child reap budgets and 5-second recovery observation. Otherwise custody remains pending without further target commands. Terminal/control observations each allow 8 seconds. The session preserves the existing 117-second fixture restoration reserve and 25-second read-only probe bounds. Cancellation after observed finite entry must revoke authority within 1 second.

Process budgets: one parent, one session worker, one exact fixture executable, one LLDB worker, one direct debugserver and one read-only canonical probe; one serialized allowlisted utility. No process-group signals or target signal authority exist in the live route. The separate headless console/LLDB parent allows one process for 5/45 seconds and cleans only its own headless group. Final acceptance requires the case evidence, `session.json`, and `parent.json`; a case result alone does not establish restoration.

## 2026-11-09 qualification attempt: incomplete

The canonical whole-host probe was rebuilt after the host UI freeze. All 94 preparation hashes still matched at runtime. Resident preparation was rebuilt with the corrected `enteredUnverified` semantics and the bootstrap custody guard. Four native host controls passed: normal return, caught throw, finite post-entry cancellation and pre-entry cancellation. The final resident preparation pins 54 inputs, including Python's framework executable and the CoreSimulator `simctl` executable. Focused harness tests passed 20/20; protected session tests passed 26/26; native safety tests passed 6/6; distribution validation passed. These are separate from UIKit runtime results.

Only the authorized, already-booted ordinary device was used: iOS 27.2 / 24B114, Xcode 27B48, host 26B123. Two pre-dispatch parent failures exposed missing executable identities and transient `ps` names. The first stopped before installation. The second stopped before the resident request or debugger dispatch. Both lifetimes/claims were reconciled and cleaned before the next attempt. The harness now counts Python launcher/framework paths under one budget, pins the observed `simctl` executable, and requires kernel identity for transient process names. The protected whole-host inputs remained unchanged.

The actual A operation loaded the signed helper once and returned from submission. Its native callback ran on the main thread, untraced, after the recorded detach return. It performed exactly one requested setter on the original generation, caught the post-write exception and published raw outcome `uncertain`. The independent oracle observed `hidden=true` and the unchanged alpha value. The sentinel deallocated between `workFinished` and `poolExited`; terminal publication followed with zero operation contexts. The image cost was 54,640 file bytes, 65,536 mapped-section bytes and an 8-byte scalar tombstone. This is not total process memory.

The parent failed with `cannot read owned PID status` for the exiting debugserver and cancelled the session. The precise failing call site was not retained as a traceback. The timestamp/exit receipts are consistent with a process-observation race; that inference is not a proved root cause. Both debugger children nevertheless exited with code 0, the group was empty, and independent readback confirmed the same fixture lifetime remained responsive and untraced. The raw receipt was not upgraded using the oracle.

After that reconciliation, a separate bounded cleanup removed only the owned fixture and its data, restored the exact original host/guest foreground and display state, and released the original claim. Cleanup finished with 197 seconds remaining on A's original deadline. Original failed case/session/parent evidence remains unchanged. No replacement control, weak-clearing proof, further setter, replay, or B run followed the post-dispatch failure. **A/B qualification did not pass and the mechanism is not selected by this attempt.** The remaining process-observation failure requires lead review before a new qualification run. Even a future passing A/B pair would select only the mechanism; current-app production integration remains separate.

Private commands, logs, receipt/oracle joins, cleanup readback and rooted source/binary/artifact manifests are indexed by `/private/tmp/mac-cu-resident-qualification-20261109-e/HANDOFF.md`. The final prepared helper is in `mac-cu-resident-prep-20261109-g`; earlier preparations are historical evidence. No production capture/edit source, wrapper, AX/UI source, gate, manifest, global installation or Git publication was changed by this qualification task.

### Lead review of process-observation failure

The lead independently checked all 120 frozen source/binary hashes, five final owned-source hashes and 405 artifact hashes; each matched. Source inspection found that `observe_servers` already distinguishes an exited/zombie PID from an unknown identity. The additional resident executable-budget path did not: after an identity read failed, it used `kill(pid, 0)`, which can still succeed while the process is a zombie. A deterministic headless regression reproduced that gap. It does not establish the precise historical failing call site because A3 did not retain a traceback.

The resident budget now uses the shared fresh exit/zombie readback for transient executable names. Only confirmed exit/zombie observations are omitted from the live instance budget. Unknown identities and detected PID reuse still stop the run. Parent topology and exact executable limits remain enforced. A bounded observation log records the sampled row and readback status; these observations grant no signal or reap authority. Final group cleanup still requires no live, zombie or unknown members.

The new tests failed before this change and the 22 resident harness checks passed afterward. The shared session and watchdog regression checks also passed. This is a harness correction only; fresh A and B sessions are still required before selecting the resident mechanism. Prior failed runtime evidence is unchanged.

## 2026-11-09 fresh A/B qualification: mechanism passed

After the lead's process-observation correction, a fresh preparation froze all current harness/resource inputs. The canonical host preparation accepted `--reuse-probe-from` only after its unchanged dependency and binary-byte checks. The current host helper/unknown/inherited routes were then checked again headlessly. Resident preparation, four native console controls, process-free LLDB parsing, both parent/worker guards, 22 resident tests, 26 session tests, six native safety tests and distribution validation passed. The unchanged watchdog's existing 18-test evidence was retained. All 120 combined source/binary hashes matched before runtime and after cleanup.

A and B each passed their case, session and parent in separate fresh fixture lifetimes on the same already-Booted, unclaimed ordinary device (iOS 27.2 / 24B114; Xcode 27B48). A retained raw `uncertain`, caught the finite post-write exception and supplied no undo. B retained raw `enteredUnverified`: host authority was revoked 0.002279 seconds after the independent `finiteDelayEntered` event, and the finite setter returned without interruption. Independent post-write oracle samples remain separate from both native receipts.

For each case, archived joins prove one signed helper image at the pinned UUID/path, callback PC in that image, accepted/submission/detach/untraced-main/work/pool/terminal order, exactly one requested setter on the original generation, sentinel deallocation between work completion and pool exit, and zero terminal operation contexts. The subsequent replacement control proved `oldWeakNil` and exactly one original-target deallocation. Main-timer progress and the same responsive, untraced process lifetime were observed before cleanup. Durable replay was refused with zero new debugger children or setter dispatches.

Both direct debugger children exited 0 and were reaped. Both sessions removed only their owned fixture and data, restored exact initial host foreground/lifetime/windows and guest foreground/lifetime/display state, released their claims, and left empty groups. A finished in 18.77 seconds and B in 17.00 seconds under separate absolute 480-second deadlines. No recovery extension was needed. Runtime ownership was released after independent cleanup readback.

Each helper costs 54,640 file bytes, 65,536 mapped-section bytes and an 8-byte scalar tombstone until fixture process exit. These figures are not RSS or total process memory. This passing pair qualifies only the resident lifetime mechanism. Current-app production readiness, the full ten-operation matrix, C/D and nonreturning stress remain unqualified. No production backend, gate, AX/UI, manifest, global installation or publication changed. Prior failed A3 evidence remains unchanged.

Private evidence index: `/private/tmp/mac-cu-resident-qualification-20261109-f/HANDOFF.md`. Current preparations: `/private/tmp/mac-cu-resident-host-20261109-f` and `/private/tmp/mac-cu-resident-prep-20261109-h`. The index includes exact commands/logs, raw receipt/oracle joins, cleanup readback and rooted source/binary/artifact hashes excluding the artifact manifest itself.
