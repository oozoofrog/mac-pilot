# Swift AX integration

This source integrates `SimulatorAXAdapter.h/.m` into the existing Swift collection and press paths and adds `SimulatorAXInspection.swift`. It does not enable new guest semantics. Root must add the new Swift file, link one adapter object compiled with ARC, Objective-C exceptions, ARC exception cleanup, blocks and `-Wall -Wextra -Werror`, and import `SimulatorAXAdapter.h` using `-import-objc-header`. No build/setup scripts are changed here.

## Callable boundary

All functions are synchronous and intended for `executeSimulatorCommand`'s background path. They admit nested calls using a dispatch-specific key on the single `SimulatorAXExecutor`. Never invoke them on the UI main thread.

- `simulatorAXSnapshot(device, screen:scope:currentScope:budget:maxNodes:) -> SimulatorAXSnapshot`. Serialize `.dictionary` at the UI boundary. `currentScope` must reread the selected device, boot lifetime, presentation/screen and generation; a captured constant is suitable only for the compatibility read path. `SimulatorAXScope` carries separate device identity, device lifetime, presentation, generation, runtime and optional **AXP** display mapping. Do not pass a CoreSimulator display number as an AXP display number.
- `simulatorAXAction(SimulatorAXActionRequest, budget:) -> SimulatorAXActionResult`. Requests use capture/node IDs and the closed `SimulatorAXOperation`: press, increment, decrement, custom handle, typed expected/new value, or explicit restore receipt. `.dictionary` separates state, delivery, typed readback and optional restore receipt. Target, stale and expiry failures become named boundary states; other preflight failures throw. No user transport option enables qualification.
- `simulatorAXPoint(captureID:point:budget:) -> [String: Any]`. Without an internally qualified mapping it returns `unsupported` and its reason. It never substitutes rectangle selection for a backend point query. A qualified hit must resolve uniquely to a retained capture wrapper; otherwise it reports unsupported.
- `simulatorAXInvalidate(captureID)` and `SimulatorAXInspectionService.shared.invalidateAll()` revoke authority and release tokens. Root must invalidate on close, refresh, selection, display, generation, and transport changes. Refresh also revokes prior device captures in the service. Failed captures conservatively revoke all retained authority.

The existing `simulatorElements`, `simulatorFrontPid`, describe, wait, target selection, paste helper and press entry signatures remain available. AX KVC/unchecked IMP use was removed from this file. Device-name KVC remains unrelated to AX. Existing press/front signatures were correct; the adapter adds validated dispatch and exception results rather than correcting their ABI. AX value reads now redact unknown guest protection. This can remove values from compatibility rows and prevents value-based selection where protection has not been established.

## Ownership and state

The executor owns translator construction, the strong bridge delegate, token registration/removal, all lazy operations and sessions. The callback queue is separate. The ObjC boundary now also contains the closed singleton accessor, closed focused/selected-range reads and SimDevice request send. Bridge send validates concrete `SimDevice` ownership and `v40@0:8@16@24@?32` before dispatch; this newly enforced signature still needs installed/guest bridge qualification. A mismatch rejects the request without a raw-call fallback.

Each operation has one absolute monotonic deadline. Queue admission and every tree field use its remaining budget. The callback-retained response cell uses a lock and one terminal transition. Timeout/cancel discards late and duplicate results. The callback captures no session/token/device. A bridge closure resolves its token on each invocation, so retaining an old closure does not preserve routing after unregister. Completion callbacks never enter the waiting executor.

Snapshots retain immutable scalar details and no opaque parent/children/custom objects. Sessions retain exact wrappers and custom action objects for at most 15 seconds, at most four sessions, at most 1024 nodes and 64 levels. Defaults are 600 nodes and 40 levels. Ordered node/parent/child IDs are capture-scoped UUIDs. Shared wrappers/cycles and limits are reported as truncation. Snapshot rows preserve old browser keys and add typed/status details at serialization. Original guest frames and the existing SpringBoard/root rotation and host presentation normalization remain separate. No UIKit polygon mapping, traits, context IDs or fabricated display identity are used.

Target checks include PID, kernel process start seconds/microseconds, executable path, front application and current device/presentation scope. Actions additionally require a fresh bounded traversal with exactly one occurrence of the retained object. Pointer/objectID equality is not permanent guest identity. `exactGuestIdentity` remains an internal disabled qualification gate until serial guest destruction/recreation evidence establishes an acceptable runtime identity rule.

## Mutation policy

Production profiles default to disabled and have no request decoder. Semantic action and point profiles must match verified runtime and executable. A profile must also establish clear guest protection; inherited host `NO` alone grants nothing. New writes require known subrole/protection, current enabled state, supported typed domain, expected-value equality, current AXValue settable status, and adapter capability checks. The expected value is read again immediately before setter dispatch. AX offers no atomic compare-and-swap guarantee against independent guest edits.

The adapter performs one dispatch. BOOL false means rejected; BOOL true and void mean delivered, followed by fresh readback. Setter equality produces `postconditionObserved`, unchanged readback produces `noChange`, and another value produces `postconditionMismatch`. A nonsetter produces `deliveredReadback`, which does not establish semantic success. Exceptions, timeout/cancel during dispatch or failed postdispatch validation return `outcomeUncertain`, revoke the session and forbid retry through it. A new capture reconciles current state; it does not prove an old write was never delivered. Explicit restore receipts bind the exact session/node and observed before/after values, are consumed once, and must pass the same current-value/type/domain/capability guards. No automatic rollback exists.

Duplicate custom names have separate opaque handles, exact retained action objects and name field status. The adapter checks current action identity and uses only the system action's handler/target selector. No pointer, selector, KVC key, AXValue type or generic object enters from transport.

## Headless evidence and serial qualification

Run `python3 mac-computer-use/tests/simulator-ax-inspection/run.py` and the existing adapter runner. The inspection executable links production Swift and adapter code with injected fake backends and narrow dependency stubs. A compile-time Swift flag exposes only a token-count assertion. Fake objects/results are separate test objects. Production code has no test-mode transport switch. No AXP singleton, Simulator service, GUI, boot, attach, input, installation or global restart is exercised. The runner rejects helper/unknown/inherited routes and uses the existing parent watchdog, exact instance budget one and 20-second deadline. Logs and source/artifact hashes remain in the unique printed `/tmp` directory.

An in-process deadline cannot stop a blocked private call, memory fault or native hang. The executor can consequently block expiry cleanup as well. Hard containment needs a separate supervised transport design; this implementation makes no such claim.

Upcoming serial guest cases, before enabling any production profile:

1. Verify actual singleton/bridge signatures, returned classes, token cleanup and callback liveness with one claimed fixture device; verify two independent tokens never cross-route.
2. Check nil/empty/unsupported/errors, parent/children ordering, help/subrole/value types, secure fields and unknown protection without value disclosure.
3. Recreate guest nodes with identical labels/frames/object IDs, replace the front app, reuse PID, restart the device, rotate/change screens and refresh/close during pending requests. Establish identity qualification independently of pointer equality.
4. Verify press BOOL and increment/decrement void delivery against independent guest counters/models and fresh readback; check covered/disabled nodes and no input leakage.
5. Verify string/numeric/boolean setters individually with domain limits, secure/unknown rejection, expected mismatch and explicit restore. Inject lost replies, deadline, exceptions and guest termination; reconcile without retries.
6. Verify duplicate-name custom action counters and exact handle routing after removal/recreation.
7. Qualify presentation-to-AXP primary-display mapping using actual point results across rotation and multiple displays. CoreSimulator display 1 and AXP display 0 remain distinct namespaces. Compare LCD pixel alignment separately; mocks establish neither pixel alignment nor guest setter fidelity.
