# UIKit hierarchy fixture

This development-only app supplies nested, transformed, hidden, clipped and
scrolled views with stable accessibility identifiers. It is a capture target,
not a preview. Its scene manifest names the exported `FixtureSceneDelegate`, and
`UIWindow(windowScene:)` owns the window. The current SDK rejects the former
legacy application-only lifecycle before any oracle can be written. After layout it writes `Documents/geometry-oracle.json` in its
own app container: four bounds corners converted by UIKit to the screen's fixed
coordinate space in points, plus screen scale, orientation and a timestamp.
The fixture supports portrait UI only; physical device pose is not observed or
changed. SpringBoard's `rot0` does not prove physical portrait. The session still
requires actual guest display `rot0`, then separately checks oracle/interface
orientation and screenshot size. The corners are not clipped polygons or proof of
alignment with an LCD image.
The oracle and the debugger capture are separate observations, not an atomic
snapshot; compare their timestamps and stable fixture state explicitly.

Build only, without installing or launching (the output directory must not
exist):

```sh
mac-computer-use/tests/view-hierarchy-fixture/build.sh /tmp/unique-hierarchy-fixture-build
```

No simulator is started by the build. Do not install or run until the device
is claimed and the foreground window is coordinated. Read the current booted
inventory and record the selected device, its foreground app and orientation
immediately before the check. Preserve the original foreground app and device
state, restore them afterward, and remove only this fixture and its data if
the fixture was not previously installed. If an existing fixture with this
bundle ID is found, stop instead of replacing it. Do not use another app as a
debug target. Before launch, implement and prove a bounded parent watchdog,
exact executable instance budget, PID/start/path checks, cleanup and restore;
simctl launch is not a direct-child ownership or wait guarantee. The macOS
native test dispatch guard does not establish those simulator guarantees.

Apple specifies that a transformed view's `frame` is undefined and provides
coordinate-space conversion from view bounds to the screen's fixed space:
[UIView.frame](https://developer.apple.com/documentation/uikit/uiview/frame),
[UICoordinateSpace](https://developer.apple.com/documentation/uikit/uicoordinatespace).
These are API guarantees, not evidence that debugger output, clipping, screen
rotation, screenshot timing or LCD placement has been verified here.

## Bounded session

`prepare.py /absolute/new-build-directory` builds/signs the existing fixture and a
CLI-only canonical state/snapshot probe. The latter preserves production permission
helper dispatch with `native_check_support.isolated_main`; unknown/daemon/inherited
entry routes are proved under its parent watchdog before any state read. The
fixture's shared `entry.swift` admits only `--fixture-session <matching-token>`,
rejects inherited entry and all helper/unknown routes before `UIApplicationMain`.
Its host-only build proves those routes without UIKit. No design preview exists.
Preparation does not install or launch UIKit. It compares the bundled scene
manifest with the actual exported Objective-C class in the fixture executable.
This is compile/packaging evidence, not proof that UIKit invoked the scene delegate.
When only fixture sources changed, reuse the byte-verified canonical CLI probe:

```sh
python3 -B mac-computer-use/tests/view-hierarchy-fixture/prepare.py /tmp/new-fixture-build \
  --reuse-probe-from /tmp/previous-validated-build
```

Reuse checks every canonical Swift input, generated dispatch, probe source and
binary against the prior receipt. It rebuilds/signs the fixture and recompiles its
shared entry guard, without rebuilding unrelated production Swift. Source/binary hashes must still match
at execution. Imports are inert.

```sh
python3 -B -m unittest discover -s mac-computer-use/tests/view-hierarchy-fixture -p test_session.py -v
python3 -B mac-computer-use/tests/view-hierarchy-fixture/prepare.py /tmp/new-fixture-build
# Only inside the parent's coordinated 6-minute foreground window:
xcrun python3 -B mac-computer-use/tests/view-hierarchy-fixture/session.py \
  --build /tmp/new-fixture-build --output /tmp/new-fixture-evidence --device SELECTED-BOOTED-UDID \
  --deadline "$AUTHORIZED_UTC_END"
```

`AUTHORIZED_UTC_END` must be the parent's fixed end in **UTC
`YYYY-MM-DDTHH:MM:SSZ`**, including cleanup and tool/message delivery time. No
relative duration, offset timezone, fractional timestamp or implicit local time is
accepted. At CLI receipt, one wall/monotonic pair converts that end once; the
shared clock is `clock_gettime(CLOCK_MONOTONIC)`: Xcode Python 3.9's
`time.monotonic()` is process-relative on this host and cannot carry deadlines
between processes. Failure to read the shared clock fails before child creation;
there is no process-relative fallback. The actual end is the earlier of that value and receipt + 360 seconds. Parent and
worker receive the exact same monotonic end, including worker startup delay.
Admission = end - 285, stop = end - 240, usable worker end = end - 5. Less than
285 seconds remaining fails before claims, install or launch. An expired or
malformed value fails before any child session is launched. Later wall-clock
changes cannot restart the budget.

Before requesting desktop time, finish preparation/hash checks and run the same
parser/parent/worker route without Simulator reads, UIKit or debugger activity:

```sh
xcrun python3 -B mac-computer-use/tests/view-hierarchy-fixture/session.py \
  --guard --build /tmp/new-fixture-build --output /tmp/new-deadline-guard \
  --device SELECTED-BOOTED-UDID --deadline "$GUARD_UTC_END"
```

The guard records the parent send clock/remaining time, child receive clock/remaining
time and dispatch delay, verifies that the child budget does not grow (1 ms
precision tolerance), and records zero mutations and
final group residuals. It uses the same worker deadline validation and admission
boundary as the actual session. Synthetic tests also exercise real CLI rejection,
late receipt, delayed worker admission, unchanged deadline after clock changes,
and the actual `--worker` dispatch's zero-mutation refusal below reserve. The same
CLI guard runs under selected Xcode Python, not only the host development Python.
An actual production capture worker CLI receives an already-expired shared-clock
deadline and rejects it before engine construction; this check does not create a
debugger or server. Successful live comparison will also require supervisor/LLDB
worker clock receipts to agree.

Do not repeat a separate native read-only preflight after the time window starts:
the actual session already checks current inventory/claim/app data/foreground
before mutation. Static source/build/hash verification and guard runs belong
before the user's time window; only the essential changing-state checks remain
in the actual launch path. Preserve the fixed end supplied by the parent rather
than adding six minutes after receipt.

There is one session, one fixture launch and one production capture; no retries.
Select an already-booted, unlocked, active, single-screen portrait device. This
bounded check refuses foldables/other orientations rather than changing pose. It
records original guest foreground PID/start/path/bundle, display/layout readback,
host foreground and stable host window IDs/bounds/layers. Existing fixture app or
orphan fixture data causes refusal before install. No download, device creation,
boot, user-app termination, PGID signal or historical zombie operation is present.

The outer parent reuses the existing `remote_watchdog` direct-child cooperative
stop/identity/group readback helpers. Total deadline is 360 seconds, with capture admission no later than 75 seconds:
75 + full production capture 163 + session cleanup 117 + parent receipt 5 = 360.
Request stop at 120 seconds; even a capture started at 75 has at most 118 seconds
remaining then. Cooperative worker grace is 235 = 118 + 117 seconds, capped by the
same absolute parent deadline. There is no artificial delay. Insufficient admission
or cleanup budget fails explicitly; newly owned fixture cleanup/restore still runs
on admission failure, and incomplete cleanup/restoration preserves the claim.

The 117-second cleanup budget is: terminate 8 + gone observation 4 + pre-uninstall
inventory 11 (simctl 8 + plutil 3) + uninstall 8 + post-uninstall inventory 11 +
data inventory booted read 5 + two complete CLI probes 50 + optional foreground
restore launch 8 + local identity/files/claim margin 12. The data scan checks the
absolute deadline while iterating. Foreground already restored uses one probe.
Post-capture state probe 25 + screenshot 8 + converter probe 25 + local comparison
margin 12 is admitted only when all 117 cleanup seconds remain afterward; a slow
capture can therefore finish safely with coordinate verification incomplete.
Local filesystem/kernel stalls can exceed a nominal deadline; the parent records
that failure and never kills a still-owning reaper to manufacture a time-bound pass. Budget: parent 1, session
worker 1, newly installed fixture 1, production supervisor 1, LLDB worker 1,
debugserver 1, state probe 1; simctl operations are serial. Prepare dispatch keeps the existing native guard unchanged. Live CLI probes use
only the existing remote watchdog's direct-child stop/wait/readback operations,
with exact executable budget 1 and total budget 25 seconds: initial scan is inside
a 15-second work interval, a final scan can overrun by at most 3 seconds, then
TERM grace 2 + direct-child KILL/wait 2 + residual scan 3. No live probe uses PGID
signals. Unknown descendants cause incomplete cleanup, with no signal authority. Parent polls exact fixture executable count and the selected debugserver in its
owned group. Server lookup reuses `identify_live_server`: exit/zombie races are
recorded separately; unknown observations count against the budget without giving
this observer ownership or signal authority. Production cleanup/recovery and the
final group residual decide success; a natural server exit is not a failure.
production owns/reaps its worker/server. An unexpected duplicate cancels the
session and forbids retries. Never kill a reaper while it might own debugger
children: failure to finish retains evidence, fixture and claim for review.

Claim owner is the live session-worker PID plus a fresh UUID in the existing
sim-pilot claims file. A nonblocking per-device flock excludes concurrent fixture
sessions. Refuse every pre-existing claim (including stale ones), preserve all
other records, verify ownership before mutations and during capture, and remove
only that exact record. Existing sim-pilot writers do not honor this flock; their
claim changes are detected, not made atomic by this test. Do not run them in parallel.

`simctl launch` creates **no direct-child wait authority**. Ownership requires the
new installed bundle/path, returned PID, process start after launch, exact resolved
executable and `SIMULATOR_UDID`. After capture cleanup, recheck the same running,
untraced lifetime and ask simctl to terminate only this owned fixture. Observe
PID/start residual as gone/live/zombie/unknown; launchd owns wait/reap. Require gone
before uninstall; no ambiguous lifetime is signalled or reaped. Check bundle path
before uninstall and confirm both bundle and owned data are removed. A failed or
partial install/launch with uncertain ownership is preserved for review.

Restore the original foreground with no action if it already matches. Otherwise,
only if host focus is unchanged and the original app is still the same live,
untraced PID/start/path/device, `simctl launch` brings that existing lifetime back
(no terminate-running flag). Read back original PID/start, screen/layout and host
windows, then release the owned claim. No host activation, click, key, rotation,
fold or preference change is sent. A user focus change stops further interaction.
Parent and worker also monitor combined-session input event counters without
recording keys, locations or event contents. New input cancels work and capture;
capture cleanup finishes before fixture disposal. A cancelled/input-interrupted
session never launches an app to force foreground restoration. If the original
foreground already matches, read-only confirmation and claim release remain safe;
otherwise retain the claim and report incomplete restoration.
Failure receipts are retained, never rewritten as a pass.

`compare.py` requires unique main queue + `NSThread.isMainThread`, successful
DBGTargetHub response, exact address joins through the production Swift converter,
all seven fixture identifiers/parents/hidden/clipped properties, four corners per
view within 0.01 point of UIKit's independent oracle, same target recovery and
child reaping. It checks portrait PNG dimensions against screen points and scale.
Corners include off-clip and hidden views; they are not visible polygons. Oracle,
collector and screenshot remain separate observations. LCD placement, 3D,
nonportrait/foldable mapping and moving screen timing remain unsupported; no
`verified` or `overlayEnabled` flag is promoted by this test.

The current simctl help describes `--stdout`/`--stderr` file redirection but does
not specify host-versus-guest path semantics. The previous host-path attempt did
not produce a host file; this is not treated as captured diagnostics. The session
now uses ordinary non-console launch arguments and copies fixed diagnostic files
from the exact new fixture data container instead.

The simulator-only diagnostic branch appends entry/application/scene/view/oracle
stages to its own `Documents/fixture-lifecycle.log` and uses NSLog as a fallback.
It never logs the token or environment values. Host dispatch guards exclude the
container-writing branch. Oracle and lifecycle files are copied immediately when
the oracle appears, before subsequent foreground/orientation gates, and again
before uninstall. Missing files are reported as unavailable; preservation errors
prevent falsely reporting clean evidence disposal. An exact target that becomes
gone/zombie/unknown before oracle creation fails immediately; the eight-second
oracle timeout is not extended. A launch PID is not a successful UIKit launch.
Headless dispatch/class/export checks do not replace the next coordinated
scene/oracle/capture verification.

Corner diagnostics remain separate from the original published geometry. Getter
values are later repeated measurements; "immediate" means local readback from a
repeated CGPointMake call before copying to its diagnostic array, not a CPU-register
probe of the original inline array call. Original stored/window/screen values and
field-path values are labeled independently. Fixed scalar CGRect/CGPoint records
help distinguish getter, make/local, array and Objective-C conversion stages.
Alternative field-path agreement cannot turn a failing original comparison into a
pass. No diagnostic parameter or arbitrary expression is exposed to callers.

Actual diagnostic collection isolated y loss to the CGPointMake local return path:
getters agreed with fields, array storage added no loss, and all seven aggregate
alternatives matched their oracle corners. The exact vendor/ABI cause is unknown.
The primary path now uses scalar CGRect getters and aggregate point initialization.
A subsequent real collection passed the unchanged 0.01-point gate for all seven
views with zero error and exact tree/geometry joins. Main-thread BOOL, DBGTargetHub,
Swift conversion, same-target detach/recovery, owned child reaping, fixture/data
removal, original-state restoration and claim release passed too. The remaining
helper diagnostic still reproduced the loss; the original failed files are retained.
This is static portrait fixture evidence. No LCD window was opened, no pixel-content
alignment or visible clipping was proved, and no verification flag or ordinary-app
capture UI was enabled. See docs/simulator-view-capture.md for the frontend contract.

## Schema-2 edit qualification

The existing geometry and texture modes remain available. The new protected
`session.py --edit-qualification` mode performs a fixed capture/edit/server-undo/
release/recapture/reopen sequence. It requires a fresh whole probe after AX native
source freeze and sole runtime ownership. Preparation does not qualify UIKit or
LLDB execution.

The fixed ten-operation sequence has passed on the owned iOS 27.2 fixture, with
15 validated textures per capture, hidden/alpha edit and undo setter counts,
fresh epochs/tokens after releases, visible fixture PNG changes and verified
cleanup. This does not qualify ordinary apps or the LCD/3D renderer.

Before a guarded live run, use Xcode Python to check the complete canonical
expression against the prepared fixture without a process or JIT:

```sh
xcrun python3 -B mac-computer-use/tests/view-hierarchy-fixture/check-edit-modules.py \
  --fixture "$work/prepared/HierarchyFixture.app/HierarchyFixture" \
  --output "$work/edit-module-check"
```

The check covers LLDB's actual method/subscript types, MRC mode, disabled
target-side exceptions and finite-value predicate interpretation. Standalone
Clang syntax alone cannot detect LLDB's module and missing-inline-symbol errors.

Run `python3 -B mac-computer-use/tests/view-hierarchy-fixture/check-edit-preparation.py`
from the repository root for headless checks and a fixture-only build. It does
not compile the whole host or use a live Simulator. Exact root preparation and
runtime commands, finite budgets, evidence boundaries and remaining gates are in
[the qualification handoff](../../../docs/design/simulator-view-edit-live-qualification.md).

### Bounded failure qualification

`session.py --failure-case throw|cancel|replace|reparent` uses the same prepared
probe, explicit booted device, UTC deadline and protected parent. Run each family
in a fresh owned lifetime and complete its cleanup before the next one. The fixed
fixture controls live in `fault-target.m` and `edit-oracle.swift`; they are absent
from the public capture/edit request. The normal ten-operation mode is unchanged.

The actual deallocation/recreation case returned `weakNil` before setter entry;
the observed allocation used a different address. Reparenting the same view
within the same window returned `staleGraph` without a setter. Throw-after-write
and parent cancellation after the independent finite-delay entry marker both
preserved the applied model value and uncertain receipts. Process recovery,
debugger child reaping, fixture/data removal and restoration passed for all four.
Both interrupted setters created an autoreleased sentinel without a deallocation
event during six seconds of fresh post-recovery observation. **Product edit
enablement remains blocked by this cleanup gap.** No automatic retry or inverse
setter followed either uncertainty.

Focused preparation checks, without Simulator or GUI:

```sh
xcrun python3 -B -m unittest discover \
  -s mac-computer-use/tests/view-hierarchy-fixture -p test_failure_qualification.py -v
```

The runner retains all original receipts and separately records the independent
oracle, cancellation marker, old-authority no-dispatch proofs, cleanup and exact
process absence. A failed full qualification can still have verified process
cleanup; check both fields rather than treating the exit code as a cleanup claim.

