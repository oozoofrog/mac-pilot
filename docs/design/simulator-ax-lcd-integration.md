# LCD AX UI and command integration

Implemented in the canonical native sources. This worker did not modify `SimulatorWindow.swift`, 3D controllers, UIKit capture/edit sources, build/setup helpers, manifests or release metadata. Existing dirty changes remain in place.

## Root integration hooks

`SimulatorAXHostLifecycle.shared` provides a lock-protected lifecycle store. Its methods never synchronously enter main, handleQueue or the AX executor. AX backend `currentScope` rereads this store on every validation; it does not capture a constant scope.

```swift
func update(deviceID: String, bootIdentity: String?, presentation: String,
            generation: UInt64, runtime: String?, qualifiedAXPDisplay: UInt32? = nil)
func invalidate(deviceID: String)
func cancelPendingReads(deviceID: String)
func current(deviceID: String) throws -> SimulatorAXScope
```

Root must wire the owning window, rather than introducing another selected-device authority:

1. Resolve the actual UDID, actual boot lifetime and runtime from authoritative device evidence. Keep object pointer/connection generation separate from boot identity. Supply nil boot/runtime if unavailable; typed refresh then fails with an explicit identity-unavailable reason. Do not generate a boot identity from a pointer, timestamp, random UUID or presentation counter.
2. Before a refresh is admitted, publish the current presentation/screen/rotation and a monotonically increasing host generation. Publish again only when the authoritative identity/presentation changes. `update` cancels the previous budget and queues revocation of that device's retained sessions; it must not run for every unchanged frame poll.
3. On screen/rotation/reconnect/input/close, call `invalidate(deviceID:)` before publishing a replacement scope. Direct HID input must use this hook as well. Existing execute-command mutations already invalidate the host scope. Root must republish verified current identity/presentation before the next explicit refresh. Never invalidate the scope merely because an `axAction` begins: that would revoke the action's own retained session.
4. On close or cancelled/superseded read, call both `cancelPendingReads(deviceID:)` and `toolbox.cancelPendingAXRead()`. Close/target changes also require `invalidate(deviceID:)` and `toolbox.invalidateInspection()`. Cancellation is cooperative and does not terminate a blocked private native call.
5. Assign `toolbox.onOpen3D: () -> Void`. The entry invokes this callback only. Root may open its current-device 3D controller here, without attaching, capturing, collecting input or choosing another device. This worker does not implement the capture callback.

Keep the generation increasing across close/reopen of the same owning window and across presentation changes. `invalidate` removes scope and cancels the in-flight budget immediately under the lock; token/session release is queued on the AX executor. Thus fresh scope checks deny old authority even while release is waiting behind a private call. Other devices are not revoked by this host lifecycle hook.

`qualifiedAXPDisplay` is an AXP namespace value. Leave it nil until actual mapping qualification succeeds. CoreSimulator display ID `1` does not establish AXP display `0`. Setting this field does not enable any action or qualify the backend.

## Commands and payloads

Both LCD and external requests continue through `executeSimulatorCommand`, `SimulatorToolActivity`, and the existing request/result accounting. Backend calls require a background thread. The external tool route requires an explicit device UDID for new commands; it does not choose the only/latest device. The owning LCD already passes its actual device object directly.

Read:

```json
{"action":"axSnapshot","device":"<actual UDID>"}
```

`structuredContent.inspection` contains compatibility `pid`, `elements`, and presentation `scope`, plus `axSnapshot`. The snapshot carries capture/node IDs, process lifetime, actual device/boot scope, host generation, ordered parent/child IDs, original and presented frames, monotonic read/expiry times, field statuses/scalars, advertised actions, distinct custom handles, and current capability reasons. The UI decodes typed snapshot/node/field/value models once. It retains tree order in the list; point candidates are explicitly marked AX frame candidates and sorted by depth.

Action:

```json
{"action":"axAction","device":"<actual UDID>","ax":{"captureID":"...","nodeID":"...","operation":"press"}}
```

The closed envelope accepts only:

- `press`, `increment`, `decrement`: captureID, nodeID, operation.
- `custom`: the same keys plus `handle`, taken from that node's retained custom action handles. Duplicate names retain distinct handles.
- `setValue`: the same keys plus `expected` and `value`, each exactly `{ "type": "string" | "number" | "boolean", "value": <matching scalar> }`. Types must match. Numbers must be finite; integer NSNumber inputs that lose precision when converted to Double are rejected. Strings are bounded to 65536 UTF-16 code units. Boolean strings/numbers are not coerced to booleans.
- `restore`: the same keys plus `handle`, containing the exact prior restore receipt.

Unknown operations/keys, selector/expression input, type mismatches and nonfinite numbers are rejected. There is no request field for qualification or transport profile. Before dispatch, the selected device's current host scope must equal the retained capture scope. The backend resolves the capture/node IDs and validates current lifetime/identity/protection/support again. New mutations never resolve labels, addresses or dictionary equality.

Results use `structuredContent.axResult` and `axBinding` (captureID/nodeID). State, delivery, typed readback and optional restoreReceipt remain separate. The LCD shows these values directly, including unsupported, rejected, staleCapture, expiredCapture, targetChanged, outcomeUncertain, noChange and postcondition mismatch. Thrown errors have a separate error presentation. No automatic retry or rollback occurs. A failed/stale draft remains visible against its original selection and cannot apply to another node. A result for a changed selection, invalidated capture or closed inspection cannot install a restore receipt. Restore requires a deliberate click and exact receipt; backend expiry/current-value checks still apply.

Existing external `describe` (including legacy inspection), `press` and `tap` behavior is preserved. Rich row additions are stripped before legacy selected-element tap equality, so capture/field metadata does not break the legacy contract. Typed AX selection itself does not grant HID tap authority. AX request envelopes are omitted from activity summaries so drafts are not copied into those summaries.

## UI and capability state

Opening inspection does not capture. The user explicitly refreshes, filters/selects rows, then deliberately executes an enabled operation. Point selection lists candidates without automatically selecting even a single candidate; selection/search do not send guest actions. The details pane shows capture/target/scope, parent/ordered children, each field's available/nil/unsupported/failed/redacted status and diagnostics. A scrollable compact action area contains press/increment/decrement, exact custom-action choice, a typed draft/apply control, receipt-bound restore and the no-capture 3D entry.

The normal product profile now publishes immutable per-node operations on its exact
measured runtime/host/framework tuple. Actual normal-factory and LCD evidence is
recorded in [the current live qualification record](simulator-ax-live-qualification.md#normal-product-factory-and-actual-lcd-completion-2026-11-09).
Unsupported profiles and incomplete/protected/disabled nodes remain fail closed.

Snapshot expiry revokes UI action/restore state at the reported monotonic expiry. Refresh, lifecycle invalidation and selection changes discard old result bindings. The existing toolbox activity ID and presentation comparison suppress superseded command/read publication. Root cancellation hooks additionally suppress reads cancelled without a geometry change.

## Headless verification and evidence

No Simulator/AXP singleton/device calls, visible windows, input, installation, setup, commit or push were performed. AppKit fixtures instantiate controls and existing offscreen layout windows without ordering them onscreen. Native routes were rejected before entering each executable; parent watchdogs used an exact executable budget of one and 25/30/60-second deadlines. Full logs and hashes are outside Git:

- `/tmp/mac-cu-ax-lcd-check.g0ugge0d`: **38** focused LCD wire/state assertions. Exact scalar/envelope rejection, no auto point selection, disabled unqualified actions, field diagnostics, duplicate custom handles, failed-draft retention, late-receipt rejection, explicit restore and typed read accounting. `compile.log`, `watchdog.log`, source/artifact hashes and zero remaining instances are retained.
- `/tmp/mac-cu-ax-host.qz4c1mxt`: **171** AX assertions, extending the existing 158 backend assertions with host identity gating, exact capture routing/revocation, refresh revocation before transport construction, cancellation, AXP nil namespace, fresh lifecycle reads while the executor is blocked, invalidation and profile-key rejection. Fake transport only; `compile.log`, `watchdog.log`, source/artifact hashes and zero remaining instances retained.
- `/tmp/mac-pilot-ax-inspection.e90csnkt`: existing **158** backend assertions and native safety checks passed before the host extension.
- `/tmp/mac-cu-ax-lcd.pcqbyyub`: whole-source typecheck via canonical `native_build.py`; existing UI-state and toolbox selfchecks passed under the native watchdog, including their rejected dispatch routes. `final-typecheck.log`, `existing-toolbox.log`, `distribution.log`, final source hashes and artifact hashes are retained. Remaining TLS API deprecation warnings are outside this change.

Commands to reproduce focused checks:

```sh
python3 -B mac-computer-use/tests/simulator-ax-lcd/run.py
python3 -B mac-computer-use/tests/simulator-ax-lcd/run-host.py
python3 -B scripts/validate_distribution.py
```

`check-simulator-gestures.sh` now includes `SimulatorAXUIModel.swift` in its explicit toolbox source list. Existing UI-state fixtures were adjusted only for explicit refresh and unselected point candidates; its scoped legacy tap fixture continues to exercise the legacy route.

## Required serial guest checks owned by root

1. Wire real boot/runtime/presentation evidence and lifecycle invalidation. Confirm missing boot identity gates refresh, then capture the selected app with exactly one owned device/window. Read back capture/target/boot/screen/generation/expiry in the LCD.
2. Compare typed field status, parent/ordered children and advertised actions with the actual guest fixture. Confirm protected/unknown fields remain redacted and disabled, and all production mutations remain disabled until the backend's independent qualification cases pass.
3. During pending reads/actions, rotate/switch displays, reconnect/reboot, change the front app, refresh, select another row and close/reopen. Check that old replies cannot mutate the replacement selection or install receipts. Check same-name devices and simultaneous windows remain separately owned.
4. After backend qualification is actually established and capability metadata is deliberately updated, verify press/increment/decrement/custom against independent guest counters. Duplicate custom names must affect their distinct counters. Verify string/boolean/finite-number setters, expected-value mismatch, disabled/covered/protected nodes, finite-number boundaries and exact receipt-bound restoration.
5. Inject lost replies/timeouts/guest termination. Preserve uncertain delivery separately from failed preflight; reconcile with a new capture without automatic retry. Test expiry before action and before restore.
6. Qualify actual AXP point mapping across rotations/displays separately from rectangle candidates. Verify LCD pixel alignment independently; headless fixtures do not establish it.
7. Open the 3D entry and confirm no attach/capture/input occurs until the separate explicit 3D capture action. Root owns texture/Metal/capture/edit qualification, final full-suite checks and local delivery.

No runtime AX semantics, guest setter success, pixel mapping, Metal rendering or installed-app behavior is claimed by this worker.
