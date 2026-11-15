# AX product profile and capture capabilities

The normal `simulatorAXSnapshot` factory now selects the internal product profile.
This supersedes the disabled-factory status in the earlier AX integration notes.
There is no transport option, UI flag, fixture executable allowlist or device ID
that enables it. The live-validation override remains compile-time-only.

## Qualification and API

`SimulatorInspectionHost.prepare` now publishes `SimRuntime.identifier|ProductBuildVersion`
in `scope.runtime`. The selected runtime object has no `buildVersion` getter on the measured build. The lifecycle verifies its CoreSimulator image and reads `ProductBuildVersion` from the bounded plist below its actual `root`. It checks getter availability and rejects missing, malformed,
control-character and oversized metadata. The display name is never used.

`SimulatorAXNativeMetadata.qualification(runtime:executable:metadata:)` is the
single policy boundary used by the normal backend. Its default reader uses bounded
host metadata and `/usr/bin/xcode-select -p` (two-second deadline, bounded output),
the selected Xcode's `Contents/version.plist`, loaded Objective-C class images and
bounded framework Info.plist reads. It never discovers devices or calls AXP.
Headless tests inject scalar metadata at this boundary; fake receivers do not
claim native provenance.

The only enabled tuple is arm64, host build `26B123`, selected Xcode `27.2` /
`27B48`, runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B114`, system
AccessibilityPlatformTranslation bundle
`com.apple.accessibility.AccessibilityPlatformTranslation` / `591.4.5`, and
`/Library/Developer/PrivateFrameworks/CoreSimulator.framework` bundle
`com.apple.CoreSimulator` / `1174.20`. Framework image comparisons resolve framework
symlinks on both sides. AXPTranslator, AXPTranslationObject and AXPMacPlatformElement
must come from the system AXP image. SimDevice must come from the designated
CoreSimulator image. Product reads additionally require the actual element's
concrete class and image. The existing adapter's closed selector, defining owner,
ABI, return-type and bridge checks remain mandatory.

Snapshots include `qualificationFingerprint` with runtime, host, architecture,
Xcode and actual resolved framework metadata. Target executable and kernel process
lifetime remain in `target`. Native provenance is reread during current-state
validation; front executable/lifetime, boot, presentation, generation, fresh unique
retained-wrapper traversal and expiry checks remain authoritative. Missing or
mismatched provenance disables the profile with an explicit node capability reason.
The same-name Duo identifier/build does not match.

## Node policy

`SimulatorAXNode.capabilities` is immutable snapshot metadata. Its dictionary keeps
the existing LCD shape: `operations` and `reasons`. Operation names are `press`,
`increment`, `decrement`, `custom` and `setValue`. Only qualified, enabled,
known-role, unprotected, nonsecure nodes in a complete bounded capture can expose
operations. Missing child traversal and collection limits mark the capture
incomplete and disable every node. Secure/unknown subrole checks precede value
reads. Inherited protected-content false alone never establishes clear protection.

Press/adjustment require advertised AX actions. Custom actions retain their distinct
opaque handles. The LCD starts with an unselected placeholder and enables custom
dispatch only after an explicit action selection, including when only one action
exists. Root integration aligned the capability name with the closed `custom`
wire operation; the internal backend enum remains `customAction`. Editing additionally requires a current settable result and a
STRING value shorter than 128 UTF-16 code units, matching the measured profile's
existing domain. Numeric/Boolean setters and type changes remain unsupported.
Expected-old checks, immediate pre-write checks, fresh readback and explicit
single-use receipt restore retain the existing backend implementation. UI metadata
never authorizes dispatch: stale enabled metadata still encounters fresh backend
checks. Nonsetter delivery does not claim a guest semantic postcondition. Covered
press can be delivered without guest change. Point mapping stays disabled.

## Headless verification and root handoff

Run the AX inspection, AX adapter, AX LCD and AX host runners plus the inspection
lifecycle runner and `scripts/validate_distribution.py`. The inspection runner
also performs production and test-source typechecks and six native-safety tests.
The LCD runner constructs offscreen controls without opening windows. All native
runners enforce rejected entry routes, exact instance budget one and deadlines.
Evidence directories contain source hashes and complete compile/watchdog logs.
No live service, guest, debugger, installation or Git operation is part of this task.

Root integration reproduced the implicit custom selection in the offscreen LCD
check, then verified 40 LCD assertions and 230 AX policy assertions after fixing
selection and the capability name. The LCD details now include the native
qualification fingerprint. These checks do not establish live product routing.

Root must freeze sources, then use the **normal** factory without a qualification
override on the measured runtime. Read back the fingerprint, target lifetime,
capabilities and disabled reasons in the actual LCD. Verify deliberate selection
and dispatch, distinct custom handles, STRING expected/set/readback/restore,
secure/unknown/disabled refusals, stale capture/selection/lifecycle/expiry behavior,
and honest covered-press delivery. Check the Duo runtime remains disabled and
point mapping remains unavailable. Actual normal-factory service behavior, LCD
rendering and interaction, guest semantic postconditions, final full-host checks
and global installation remain root-owned and unverified by this headless task.


## Actual integration completion

The normal factory and actual LCD workflow passed in
`/tmp/mac-pilot-ax-normal-session-20261109-d`. See
[the live qualification record](simulator-ax-live-qualification.md#normal-product-factory-and-actual-lcd-completion-2026-11-09)
for product defects, actual fingerprints, guest oracle, local AppKit dispatch,
screenshots, cleanup and limits. The earlier root-owned/unverified wording above
is historical; this current evidence establishes the normal route on the exact
measured tuple. Physical pointer interaction, 3D and global installation remain
separate.
