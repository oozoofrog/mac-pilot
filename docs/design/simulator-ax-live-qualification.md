# Production-backed AX fixture qualification

`mac-computer-use/tests/simulator-ax-live/` now builds and runs a bounded AX-only session against the actual production Objective-C adapter, AXP translator, SimDevice bridge, Swift backend and inspection service. It does not use fake transport or attach LLDB. The normal product profile and actual LCD route are now qualified on the measured tuple. See the current normal-route evidence below; historical override measurements remain separate.

## Build and execution

Use unique nonexistent absolute output paths outside the repository:

```sh
python3 -B mac-computer-use/tests/simulator-ax-live/prepare.py /tmp/UNIQUE-AX-BUILD
python3 -B mac-computer-use/tests/simulator-ax-live/session.py --device EXPLICIT-DEVICE-UDID /tmp/UNIQUE-AX-BUILD /tmp/UNIQUE-AX-SESSION
python3 -B mac-computer-use/tests/simulator-ax-live/assess.py /tmp/UNIQUE-AX-SESSION
```

The session requires an explicit device UDID. It never selects another device or boots, creates, deletes or shuts down devices. Each build assigns a unique fixture bundle identity. Existing installation or data for that identity causes refusal. The fixture scene/entry guards, canonical host helper/unknown/inherited routes and six native safety regressions must pass before device work.

The canonical `native_build.run_swift`/`native_inputs` path compiles the host with `SAX_LIVE_VALIDATION`. All compiled Swift sources, the production main used to generate isolated dispatch, adapter header/implementation, build helper, generated baseline reader, fixture and test inputs and signed binaries have hashes. Native compilation inputs are frozen before compilation and checked afterwards. No view-capture Python/expression files or resources enter the AX binary manifest. The shared hierarchy session/probe files are read and hashed without modification. A generated baseline reader replaces its resource-dependent target read with kernel process-lifetime evidence; it does not invoke capture.

`prepared.json`, `frozen-compiled-inputs.json`, compiler commands/logs, toolchain, dispatch and safety logs stay in the build directory. Session evidence includes baseline, current boot identity, target ownership, production snapshot, identity measurements, independent oracle, per-operation delivery/readback/dispatch deltas, parent/session cleanup and assessment. The runner does not equate successful process exit with semantic qualification; run the assessment and inspect its per-case outcomes.

## Ownership and containment

The parent has a 200-second absolute monotonic deadline. Work stops at 75 seconds, reserving 125 seconds for cooperative cleanup. Budgets are one worker, one exact probe executable, one exact fixture executable and serialized simctl commands. The probe has a 35-second parent watchdog. Permission/helper entry checks have their own five-second watchdogs. No host activation or global keyboard/mouse injection occurs.

The runner reuses the existing claim, input-counter, selected-device, process-lifetime, guest-residual, baseline and conditional-restoration methods. It rejects existing claims without pruning or takeover. The fixture must match exact executable, kernel process start and selected UDID, and each AX validation rereads front PID, process lifetime, selected boot lifetime and host front PID. Parent input or focus changes stop interaction. Only this run's owned fixture may be terminated/uninstalled. Restoration may bring back only the original still-running guest lifetime, with unchanged host focus and no intervening user input. Failed ownership/cleanup is recorded and preserved for review instead of broad termination or force restoration.

The fixture periodically samples its actual text and secure-field properties independently of `editingChanged`. Its oracle records generation, action counters, adjustable model, actual text and a secure-value invariant without exposing the secure text. A fixture-owned request file deliberately destroys/recreates the same-label/frame button. No product app requires an SDK or oracle.

## Observed qualification

The final serial run used Xcode 27.2 (27B48), iOS Simulator SDK 27.2 and the selected iOS 27.2 runtime. Its 21 assessment predicates passed. These are fixture/runtime/executable-specific observations, not general app capability enablement.

- The installed SimDevice bridge encoding was `v40@0:8@16@24@?32`. The final probe observed 8,792 bridge requests and 8,792 replies. The validated adapter ABI accepted them without a fallback.
- The ten-node traversal contained nine named fixture nodes. Wrappers were `AXPMacPlatformElement`; translations were `AXPTranslationObject`. Each named node retained the same wrapper and translation across unchanged traversals, with exactly one wrapper occurrence. Same-label/frame guest recreation produced a different wrapper and zero occurrences of the retained old wrapper. This supports testing the existing exact retained-object rule within this short-lived fixture session. It does not establish a persistent guest identity across captures, PID reuse, app changes or runtime versions.
- Text and adjustable AX values were `NSTaggedPointerString`. No numeric or Boolean setter support was inferred from the adjustable model. Secure AX values were redacted. The runtime reported inherited protected-content false even for the secure field; the secure subrole and caller-established fixture protection remain necessary.
- Press incremented only its guest counter. Increment/decrement changed the independent model and their separate counters. Duplicate-name opaque custom handles incremented separate customA/customB counters. These five operations each entered the adapter once and had independently observed guest postconditions.
- String expected-old/set/readback and explicit receipt restore each entered once. Host typed readback and actual guest text agreed. Receipt reuse, secure, disabled, unknown protection, expected mismatch, numeric/Boolean domain, refresh, close, expiry and recreated-node cases each entered the adapter zero times and left the complete oracle unchanged. Expiry used the production service with a shortened 50 ms retention; scheduled revocation surfaced as `staleCapture`.
- Covered-node press entered the adapter and returned delivered without readback, but its guest counter did not change. This is an observed lack of guest postcondition, not semantic success or a universal hit-testing guarantee.
- All retained service sessions were invalidated; registered bridge tokens ended at zero. The fixture process was gone, its app/data were removed, original guest lifetime and host window/display state were restored, the exact claim was released and exact host/probe leftovers were zero.

The final source also passed the existing 158 headless AX assertions, six native safety regressions, helper dispatch guards and distribution validation. Those checks remain distinct from the real guest observations.

## Limits

The fixture-bound action factory exists only under `SAX_LIVE_VALIDATION`. No user, MCP or UI flag enables it. That historical run did not exercise the ordinary snapshot factory. The current run below does. The qualification probe deliberately calls the production service directly; it does not establish LCD clicks, LCD rendering, 3D behavior or production capability presentation.

No AXP point/display mapping, rotation/multiple-display behavior, app switch, PID reuse, device reboot, lost replies, native exception/hang recovery or guest-termination-during-dispatch qualification was performed. The selected screen was already active and portrait; baseline and restoration display readbacks match. No physical device, global installation/restart, commit, push or publication was performed. Parent watchdog containment does not make an arbitrary private native call interruptible in-process.


## Normal product factory and actual LCD completion (2026-11-09)

The successful current session is `/tmp/mac-pilot-ax-normal-session-20261109-d`, built
at `/tmp/mac-pilot-ax-normal-build-20261109-d`. Its assessment passes **21 predicates**.
All positive captures and actions use actual `SimulatorInspectionHost.prepare`,
`activeScreen`, fresh host scope and normal `simulatorAXSnapshot`; no qualification
override or synthetic fingerprint is used. `SAX_LIVE_VALIDATION` remains compiled
only for bridge counters and the prior independent identity measurement. The
fixture-bound capture helper is not called. The shared baseline and Python session
helper are frozen inside the build; prepared verification checks their hashes.

Two real product defects were exposed and corrected before the passing run:

- Session `...-b` refused capture before any mutation because actual `SimRuntime`
  has no `buildVersion` getter. Read-only evidence is in
  `/tmp/mac-pilot-ax-runtime-metadata-20261109/runtime.json` and
  `metadata-with-build.json`. The lifecycle now validates the selected runtime
  object's loaded CoreSimulator image, reads its actual `root`, and reads only a
  bounded regular `System/Library/CoreServices/SystemVersion.plist` below that
  resolved root. `ProductBuildVersion` must match the build grammar. Missing,
  malformed, oversized, escaping or unverified metadata fails closed. There is no
  display-name or request-field fallback. The actual resolved metadata path and
  fingerprint are recorded in `runtime-metadata.json` in the successful session.
- Session `...-c` captured but refused all native dispatches because AXP lives in
  the dyld cache. Resolving a nonexistent executable leaf left the framework's
  top-level symlink unresolved, while loaded class images used `Versions/A`.
  `/tmp/mac-pilot-ax-runtime-metadata-20261109/native.json` records that mismatch.
  `canonicalImage` now resolves explicit symlinks and existing parent directories
  with a finite bound. Exact image equality remains required. This is covered by
  the 231-assertion AX policy check, including an absent dyld-cache executable.

Both failed sessions completed fixture termination/removal, claim release,
restoration and zero exact probe residuals. No mutation entered the native adapter
in either failed session. Session c's attempted commands are refusals, not deliveries.

The actual scope is `main|rot0|rot0|402.0x874.0`, with the actual selected boot
lifetime and runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B114`.
`production-snapshot.json` records the full qualification fingerprint: arm64,
host `26B123`, Xcode `27.2` / `27B48`, AXP `591.4.5`, CoreSimulator `1174.20`, exact
resolved loaded class images and verified receiver images. Target PID, executable
and kernel start tuple are independently recorded in `target.json` and snapshot.
The same-name Duo runtime mismatch remains covered by the focused lifecycle and
product-profile assertions. Duo was never operated.

Normal-factory press, increment, decrement, both duplicate-name custom handles,
STRING expected/set/readback and explicit receipt restore each entered the adapter
once and matched the independent guest oracle. Receipt reuse, secure, disabled,
expected mismatch, unsupported numeric/Boolean values, refreshed/closed captures
and same-label/frame recreated wrappers entered zero times. Covered press was
reported delivered, but the guest counter stayed unchanged; no semantic success
is claimed. Unknown-protection and expiry fault evidence from the previous
`/tmp/mac-pilot-ax-live-session-20261109-d` remains reused because those backend
inputs did not change.

The separate declared LCD phase opens the actual production `SimulatorWindow`
and inspector. It acquires foreground once and retains input counters and its own
window focus guard. It uses local AppKit `performClick`, popup selection and a
window-local point event. This is **not physical pointer verification**. The
production controls route through `executeSimulatorCommand` and existing activity
start/finish accounting. The harness observes structured responses at that command
boundary; it does not call the AX backend and label that a UI click.

`lcd-actions.json`, `lcd-result.json`, `lcd-snapshot.json` and `lcd-probe.log` prove:
opening has zero captures; refresh requires the actual refresh button; row selection
has no dispatch; custom selection starts at the explicit placeholder; two distinct
handles affect their distinct guest counters; press and STRING apply/restore match
the independent oracle; secure/disabled controls remain unavailable; point
candidates never auto-select or create HID contacts; invalidation removes apply and
restore authority. Each deliberate action produces exactly one command. Current
headless LCD coverage additionally checks failed drafts, selection changes,
late receipts and no retarget/retry. The real LCD and inspector screenshots are
`lcd.png` and `inspection.png`; these remain outside Git for root review.

The parent budget is 200 seconds, with work stopped at 100 seconds and cleanup
reserved. Exact budgets are one worker, one probe and one guest, with serialized
simctl. The AX and LCD probes have independent 35/40-second watchdogs. Production
permission-helper dispatch, rejected arguments and inherited root entry passed
before GUI. Six native safety regressions passed. `session.json` and `parent.json`
confirm guest gone, unique app/data removed, exact claim released, original guest
PID/lifetime/screen and host window geometry restored, no errors and zero probe
residuals. No global install, setup registration, HID injection, external service,
Git operation or 3D backend change was performed.

Remaining limits: short STRING domain only; no point mapping; no rotation/multiple
display, app switch/PID reuse/reboot, transport fault or guest-termination-during-
dispatch qualification. Root retains textured 3D, UIKit integration, final visual
judgment and global installation ownership.
