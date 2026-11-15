# Inspector host integration status

Root owns `SimulatorInspectionLifecycle.swift`, `SimulatorInspectorIntegration.swift`
and the corresponding `SimulatorWindow` hooks. Source integration, normal AX,
resident capture/edit and actual LCD-to-3D qualification are complete. Local
1.31.0 delivery, daemon version readback and the installed inspector UI were
verified. Marketplace publication remains separate.

## Target and lifetime

`SimulatorBootIdentity` enumerates only `launchd_sim` processes and reads kernel
start time, executable identity and the exact `SIMULATOR_UDID` environment field.
It rejects missing/duplicate device identifiers, malformed argument buffers,
ordinary host processes, ambiguous boot matches and PID lifetime changes. It
does not log or persist process environments. The selected device's real boot
was read back successfully with the same PID/start identity. This is read-only
host evidence, not a guest AX or debugger check.

`SimulatorInspectionHost` publishes that boot, runtime and current display/guest
and host orientation with a monotonically increasing host generation. Generations
survive LCD close/reopen. Typed AX refresh/action admission prepares this scope;
direct LCD touch/drag/key/button/Crown, tool mutations, pose changes, reconnects
and close revoke it immediately. Hiding only the AX drawer cancels its reads and
captures without revoking a separate 3D inspection's unchanged display scope.

## 3D ownership

Opening the inspector constructs a host window only. Explicit capture resolves
the front app, verifies its process lifetime and selected display, and then runs
the backend on a per-device serial work queue separate from HID commands. The
same queue survives close/reopen so release and new debugger operations do not
overlap. Results bind the actual target only to the still-pending capture's same
device/display/presentation. Nodes remain unselected after capture.

Each newly constructed inspector window receives a new owner UUID. Showing an
existing window preserves its owner. A new owner cannot bypass the backend's
verified release requirement. Actual LCD close/reopen confirmed native release,
a new owner and fresh capture authority.

The coordinator retains the backend's exact capture/owner/inspection/epoch and
weak-node graph identity. It maps only typed hidden/alpha edits and server undo
tokens into existing wrappers. New operations advance their inspection sequence.
Cancellation, target invalidation and close discard UI authority immediately.
A late editable capture is explicitly released with its original identifiers.
Release never reverses a value. A release failure is surfaced in LCD feedback;
it is not reported as successful target cleanup.

Actual LCD-to-3D qualification has now passed capture/textures, explicit selection
and search, hidden/alpha edits and restores with independent setter counts,
refresh and normal/minimum layout. Native release was verified before guest
cleanup. A host-only trace found that unconditional deminiaturization of an
already visible LCD scheduled a later Dock restore, which took key/main from the
inspector. The conditional deminiaturization fix passed initial and stable-active
window regressions. A focused continuation confirmed reopen, new ownership and
late-result rejection after actual native completion but before transport/UI
delivery. It does not establish cancellation during native traversal.

The lead verified the earlier 88 source/build entries and 864 artifacts, then the
final product/UI/host frozen inputs (120/88/87 entries) and 526 artifacts. Six joined
capture/release operations succeeded in the final focused run. Exact guest/host
restoration, empty claims and no owned processes were verified after cleanup.

The receipt view now summarizes debugger detach, app recovery and child reaping
independently instead of flattening internal paths, addresses and stack traces.
Starting a new capture clears the prior receipt text when its model receipt is
revoked. This display change passed the 45 model checks and UI typecheck. Current
onscreen receipts and refresh clearing were subsequently inspected.

The default backend uses the qualified normal resident route described in
`simulator-resident-production-integration.md`. The lead verified real ordinary
UIKit and SwiftUI-app captures, typed edits, restores and adverse-path cleanup.
The SwiftUI capture contains UIKit hosting views and can omit SwiftUI text/shapes;
that limitation is carried in capture metadata and displayed in the inspector.
No UI or transport flag bypasses runtime, process-lifetime or signing checks.

Root reproduced and reviewed the fix for an integration blocker on 2026-11-09:
the inspector releases before recapture and creates a new inspection ID, while
the initial backend rejected different inspections even after successful release.
The backend now durably reserves a successor and predecessor release proof, then
requires the target's matching released ownership/history before transition.
Both sides retain 64 retired epochs without eviction; old requests cannot regain
authority or clear the successor. Busy, unresolved or malformed state refuses
transition. No ledger or target tombstone is deleted to bypass these checks.
Root verified all 18 current source hashes, 59 Python tests and 1,454 production
expression assertions. The supervisor reproduction now passes capture, release,
same-owner recapture, release and changed-owner reopen. The subsequent actual LCD
recapture/reopen qualification confirms the integrated path. Initial capture rejection
without proven target ownership cannot retire into a new inspection yet.

## Earlier check history

The records below describe their original intermediate state. Current acceptance
is the qualified normal AX/LCD and resident UIKit/SwiftUI paths, the complete
repository check, followed by focused whole-host builds and actual UI regressions
for the owner, receipt and focus deltas. No later source change invalidated the
native backend evidence. [Delivery verification](simulator-inspection-delivery.md)
records the local installation and its limits.

- Root reviewed the actual AX fixture run: all 58 frozen compilation inputs,
  71 source/signed-binary entries and 17 artifact hashes matched. The 21 assessment
  predicates agree with per-operation guest oracle observations. Covered press
  was delivered but changed no guest counter; its receipt correctly makes no
  semantic-success claim. Original guest/host/display restoration, fixture removal,
  claim release and zero probe leftovers were recorded. This qualifies the tested
  backend operations, not LCD UI or other runtime builds. The production AX factory
  and node capability metadata still need to expose the qualified support.
- Runtime names are insufficient for qualification: this machine has both ordinary
  iOS 27.2 build `24B114` and Duo iOS 27.2 build `24B91016s`. The fixture ran on the
  ordinary runtime with Xcode `27B48`. The host currently puts only the runtime name
  in its scope; product qualification must distinguish identifier/build and selected
  Xcode/framework identity before enabling actions. Do not enable Duo from the
  ordinary-runtime observation.
- Integrated repository check reached and passed the native build/sign/resource
  check, AX/3D/lifecycle checks, observation, settings, preparation, gestures and
  guarded LCD/toolbar/window regressions. It then failed at the icon check because
  that file-loaded setup caller lacked the sibling Python module search path.
  Root fixed the caller and reran the actual ICNS check successfully. The remaining
  simulator-pilot typecheck, distribution and diff checks also passed. This is a
  failed whole run plus focused recovery, not a single green whole-run claim.
  Logs: `/tmp/mac-pilot-inspection-integrated-check.log`,
  `/tmp/mac-pilot-inspection-icon-recheck.log` and
  `/tmp/mac-pilot-inspection-sim-pilot-typecheck.log`.
- `scripts/check.sh` now includes the focused editable-backend entry point, so
  schema/ledger/session, production-expression and Swift receipt checks are kept
  in the required regression path. Its previously verified evidence remains
  applicable until the pending ownership-transition fix changes those inputs.
- Whole-source typecheck passed after initial host/coordinator wiring; the log is
  `/tmp/mac-pilot-inspector-root-typecheck.log`. Other backend work was still in
  progress, so this is not the final frozen-source build.
- Model/math checks: 45 assertions and five entry guards, including explicit
  capture target binding. `/tmp/mac-pilot-inspector-bound-context-check.log`.
- Boot identity: nine parser/process assertions plus one selected live boot
  recheck, with five entry guards and no remaining process.
  `/tmp/mac-pilot-inspection-lifecycle-check.log`.
- Actual offscreen Metal: 13 assertions after correcting vertical inversion.
  `/tmp/mac-pilot-inspector-gpu-fixed.log`. No visible window or guest operation.
- Final source freeze, full repository build/checks, actual LCD/3D keyboard and
  focus checks, actual AX semantics, textured editable capture, hidden/alpha
  readback/revert, ordinary app qualification and global app installation remain.

The old `simulator-inspector-live-check.swift` still assumes automatic AX reading
and must be updated before reuse. It is not evidence for the new explicit-refresh
UI. Generated captures, binaries, process identifiers and validation receipts
remain outside Git and release resources.
