# Native Inspector UI implementation

The UI implementation is isolated in three new canonical Swift files. It uses AppKit and MetalKit, without SceneKit, private APIs, Simulator transport, or guest HID. Opening the controller constructs the window but does not capture or select a view. Root owns LCD integration, target attestation, serialization, and backend lifecycle.

## Root integration API

Compile `SimulatorInspectorModel.swift`, `SimulatorInspectorRenderer.swift`, and `SimulatorInspectorWindow.swift` together with the existing host. No mutable backend type is referenced.

```swift
let context = SimulatorInspectorContext(
    deviceID: deviceID, displayID: displayID, targetID: targetLifetimeIdentity,
    targetLabel: presentationName, presentationRevision: revision)
let callbacks = SimulatorInspectorCallbacks(
    capture: { context, generation, completion in /* root capture */ },
    cancel: { context, generation in /* cancel matching owned operation */ },
    edit: { context, command, completion in /* adapt command.envelope */ },
    revert: { context, envelope, completion in /* guarded undo */ },
    release: { context, inspectionID in /* revoke registry; nil is harmless */ },
    restoreHostFocus: { /* return focus to invoking LCD control */ })
let inspector = SimulatorInspectorWindowController(context: context, callbacks: callbacks)
inspector.showWindow(nil)
```

Retain one controller per invoking LCD context. Every completion must execute on the main thread. Call `updateContext(_:)` on a device, display, target lifetime or presentation revision change. Call `markStale(reason:)` on disconnect, motion or other invalidation, even when presentation strings remain equal. Both cancel/release previous authority and retain historical data as read-only. Release and cancel must be idempotent, scoped to their context, and safe when no operation/inspection exists. Do not attach or change the guest while constructing the controller. The root must supply an explicitly selected target, never a latest-device fallback.

Capture completion is `Result<SimulatorInspectorCapture, Error>` after root integration. It carries an attested `context` and `payload`; accepted payload shapes are `content.snapshot`, `snapshot`, or a direct snapshot dictionary. The snapshot schema is the implementation design's nested roots/assets/editing contract. Opening the window does not query an app. The explicit capture resolves the current app and its lifetime, and the UI accepts that target only while the same device/display/presentation capture remains pending. The context comes from the host preflight, never the untrusted snapshot. Generation guards reject replaced/cancelled results.

The model currently recognizes editing `registryState` values `active` and `ready`; unknown states are read-only. `inspectionID`, `ownerID`, `targetEpoch`, and `expiresAt` are nonempty strings; expiry is ISO 8601 with optional fractional seconds. Root should normalize a numeric backend epoch to its stable string representation if necessary. Unsupported or incomplete editing metadata remains read-only.

`InspectorCommand` is typed. Its `envelope` contains `operationID`, `captureID`, `inspectionID`, `ownerID`, `targetEpoch`, `editToken`, `property`, `expected`, `value`. Only `hidden` Boolean or finite `alpha` in 0...1 is possible. Root adapts field names to the backend entry; the UI sends no address, selector or arbitrary expression as an edit target. The model preserves the original capture value for expected-value checks. A forward edit consumes forward-edit authority until a fresh capture, so a second operation cannot reuse obsolete expected values.

Revert callback envelope contains `operationID`, `captureID`, `inspectionID`, `ownerID`, `targetEpoch`, `undoToken`. The token must originate from a matching server receipt. No inverse value is synthesized. Root must use server undo validation, not interpret the token as an object address.

Edit/revert completion expects a direct receipt dictionary with `operationID`, `status`, `mutationOutcome`, `before`, `requested`, `observed`, `undoToken`, `needsRefresh`, `cleanup`. The operation ID must echo the requested UUID. The UI presents status, outcome, observation and cleanup separately; it does not convert transport delivery into observed success. Transport failures preserve the draft and require a new capture before another forward edit. A receipt with a mismatching ID is ignored while the pending operation remains cancellable. Closing or changing selection during pending work cancels/revokes authority; it never sends an inverse mutation.

## Rendering and controls

The window contains a native outline/search pane, an MTKView scene and a scrolling property/editor pane. Tree selection, projected picking and detail share capture-local IDs. Search retains matching ancestors and performs no automatic selection. Multiple overlapping polygons populate an explicit candidate menu. The renderer does not choose one of them. Window roots are not automatically selected.

Visible camera buttons support orbit, zoom and reset; a labelled slider controls synthetic depth in points. Scene arrow keys orbit. Mouse drag orbits and scroll zooms. Clicking uses CPU homogeneous clipping and the same projection as GPU drawing. Projection uses point bounds for hit tests and drawable pixel dimensions for raster aspect, so backing scale does not become an extra point-coordinate multiplier. All updates are static and redraw on demand; Reduce Motion has no animated transition to disable.

Textures use captured local PNGs and fixed-space TL/TR/BR/BL corners. Per-image admission checks PNG signature/IHDR, encoded size, dimensions/format, capture/node joins, then aggregate budgets before ImageIO. Limits: 64 images; 4096x4096; 4 MiB encoded each; 16 MiB encoded aggregate; 128 MiB decoded RGBA aggregate. ImageIO validates type, frame count and actual dimensions again before creating an RGBA bitmap and GPU texture. RGBA is premultiplied and blending is `one / oneMinusSourceAlpha`. Quads use deterministic back-to-front ordering without depth writes. Missing or failed textures get outlines. Selection gets an outline and an explicit selected-view detail label. Identical image payloads on different nodes remain valid.

Cache ownership is one immutable capture with bounded textures. Replacement and close release that cache. Metal device/pipeline failures retain the tree and show persistent 3D-unavailable text. Image allocation/decode failures produce outlines; no substitute screenshot or synthetic texture is generated. Texture provenance records source property, descendant-content status and unverified clipping. Synthetic depth is separate from source corners and does not claim physical Z or perfect zero-spacing composition.

Search Down transfers keyboard focus to the outline; native arrow navigation and row selection show details. Return has no guest operation. Tab traverses native editor/buttons. Escape clears candidate picking, then draft, then pending capture/edit before closing. Close invokes the host focus callback. UI focus traversal, AX names, narrow layout and actual keyboard behavior still need guarded runtime verification.

## Headless evidence and remaining checks

`mac-computer-use/tests/simulator-inspector-3d/run.py` compiles/typechecks only owned modules and runs a Foundation/model/math executable. It imports the existing native parent watchdog, rejects helper/unknown/inherited entry with exit 64, enforces one exact executable and a 20-second run deadline, and records source hashes plus full compile/run logs in a unique temporary directory. Tests never initialize NSApplication, a window or GPU.

Assertions cover selection/generation/context mismatch, no search autoselection, pending conflicts and receipt ordering, draft retention, expiry and server-token undo gating, duplicate/invalid hierarchy, finite geometry, depth budget, malformed/oversized PNG, image count/decoded aggregate budgets, valid identical images, camera rotation, projected picking, near clipping and transparent ordering. The test-authored 1x1 PNG has generated valid chunks and CRCs. Optional saved-snapshot parsing is source-data evidence only; captured IDs/images remain outside the repository.

Final evidence paths and counts are reported to the lead. Distribution validation is a source/package check. No full host build, Metal shader execution, rendered texture/UV comparison, window layout, keyboard/VoiceOver, LCD focus restoration, live capture, guest mutation/readback/revert, physical-device behavior, global installation, Git commit or publication was performed by this headless worker. Root must run integrated checks serially under the native safety rules before delivery.

## Lead integration review

The lead verified the delivered source hashes and headless log. Tree reload and
programmatic reveal now suppress native selection callbacks; reveal expands
ancestors without selecting them. Filtering preserves only a still-visible
explicit selection. Clearing selection immediately disables the editor and
clears its displayed values. These changes prevent a redraw from discarding or
transferring selection and prevent stale enabled controls after deselection.
The updated owned-module typecheck and 41 model/math assertions plus five dispatch
guards passed in `/tmp/mac-pilot-inspector-ui-lead-headless.log`. This repetition
did not supply the optional recorded snapshot, so it does not add another saved
hierarchy parse. Native selection-event, focus and keyboard behavior still need
the integrated runtime check.

Root subsequently added explicit target binding at capture completion. Forty-five
model/math assertions pass, including rejection of a different device or
presentation and rejection of target binding without a pending capture. The
production frame encoder is shared by normal drawing and offscreen Metal checks.
Those checks found and corrected an extra vertical flip in CGContext image
decoding. Thirteen actual GPU assertions now pass for four-corner UV orientation,
ImageIO/texture creation, transparent composition, capture-order ties at equal
depth, and cache release. The initial failures and zero remaining processes are
preserved under `/tmp/mac-pilot-inspector-metal-{26o49ult,x4paw6js}`; the passing
run is recorded by `/tmp/mac-pilot-inspector-gpu-fixed.log`. No window was ordered
and no guest input was sent by these GPU checks.

## Guarded host presentation verification (2026-11-09)

The host-only runner is `tests/simulator-inspector-3d/run-window.py`. It compiles
canonical Model/Renderer/Window and the exact extracted `SimulatorElementBrowser`
class with its canonical AX wire model. No Simulator transport, debugger or
coordinator is linked. Independent selfcheck dispatch rejects permission-helper,
unknown, daemon, implicit and inherited entry routes before NSApplication. The
parent enforces one exact executable, a 55-second deadline and owned-process cleanup.
The six native-safety regression tests passed before GUI work. Each GUI launch
passed its own five dispatch guards. Local controls/window events are the only
input; unlocked/awake console, physical-input counters and key-window checks guard
execution. The original foreground application is restored when those guards
still match; close first returns focus to a test-owned host sentinel.

The successful final run is `/tmp/mac-pilot-inspector-window-49yziwgk`. It displayed
15 actual canonical PNG assets from the expired `live-finite/capture-snapshot.json`
identified by the archived UIKit runtime HANDOFF. The archive was unchanged and
immediately marked stale/read-only. It supplied display data only. No former
fixture was revived, queried or mutated. Assertions exercised initially empty
selection, explicit tree/detail/outline identity, single-match search without
selection, overlapping polygons awaiting explicit candidate choice, candidate
selection, local scene arrow orbit, visible orbit/zoom/depth/reset controls,
900×600 minimum window and normal 1200×760 content, and scrolling long details.
Onscreen PNGs were saved with screencapture and directly inspected.

Separate synthetic `MOCK-*` callback data exercised cancel/late capture, replaced
presentation generation, alpha draft, matching readback receipt, explicit receipt
restore, selection change during pending work, transport failure preserving the
draft, and close/late edit completion. Four mock edit calls and one explicit mock
restore occurred. Selection/close sent no inverse edit. Close emptied the Metal
texture cache, cleared scene event closures and released callback captures.
These are host command-state checks, not guest editing qualification.

Observed presentation corrections:

- Detail content formerly started halfway down the scroll pane. A flipped detail
  stack anchors short content at the top and keeps long content scrollable.
- The old 740×480 declared minimum could not fit the camera/control constraints.
  The minimum is now 900×600. The final minimum screenshot retains camera,
  depth and candidate controls; the detail editor scrolls.
- Empty candidate UI now has a visible prompt. Selection status names the selected
  class instead of continuing to report “selection none”. Long tree labels have
  a measured horizontal column extent and remain available by scrolling.
- The supplied AX inspection screenshot showed a vertically clipped state label.
  A fixed 341×480 synthetic browser reproduced vertical compression: state frame
  12 pt versus 14 pt fitting height. Target/state/filter resist compression; the
  existing detail/action scroll panes can shrink within 40/80 pt floors. The final
  state frame is 14 pt. No AX capabilities, selection or action semantics changed.

Before images: `/tmp/mac-pilot-inspector-window-1gkf8fis/archive-normal.png` and
`archive-minimum.png`; AX reproduction before:
`/tmp/mac-pilot-inspector-window-a1sq6i8s/ax-browser-constrained.png`.
After images are in the final run directory: `archive-normal.png`,
`archive-minimum.png`, `archive-candidates.png`, `archive-orbit-depth.png`,
`mock-readback.png`, `ax-browser-narrow.png`, `ax-browser-constrained.png`.
The earlier unscrolled mock receipt screenshot with all receipt lines visible is
`/tmp/mac-pilot-inspector-window-1gkf8fis/mock-readback.png`.

Final checks: 46 model/math assertions (including archived parse), 13 real GPU
assertions, 6 safety regressions, distribution validation and `git diff --check`
passed. The current window runner compilation typechecked the affected canonical
modules and AX wire/browser class. No new import required a full-host typecheck.
Final result records zero remaining owned window processes; all earlier owned
checks also cleaned up. Full logs, source/artifact hashes and the compact handoff
are outside Git in `/tmp/mac-pilot-inspector-host-handoff-20261109`.

Remaining integration work belongs to the lead: current-app capture/edit,
debugger safety, actual guest readback/restore, real LCD focus return, global
installation and final integrated runtime checks. Full keyboard Tab traversal,
VoiceOver and human testing were not established. No qualification flag,
installation, device operation, commit, push or publication occurred here.

The lead verified all 11 source hashes and 110 artifact hashes and inspected the
normal/minimum archive windows and constrained AX browser image. A subsequent
label-only correction changes `주소 (읽기 전용)` to `뷰 ID`: schema-2 node UUIDs
are capture identities, not object addresses. The recorded window images precede
that wording change. This does not add current-app or guest-edit evidence.
