# Installed Simulator AX ABI probe

## Decision and scope

The installed ABI supports a typed boundary for reads, press, adjustment, attribute setters and point queries. Metadata does **not** establish working guest dispatch or safe value editing. Keep mutations disabled until serial fixture tests verify their semantics. No production implementation changed.

Three historical assumptions need correction: display-aware element hit testing requires a context ID; `performEscapeAction` is void; and `setAccessibilityValue:` is inherited rather than an AXP override. Direct element `pid` is absent. Use `translation.pid` after validation. Neither translation display identity nor a public traits getter was found.

## Installed versions and probe boundary

Observed on 2026-11-09: arm64, macOS 27.2 (26B123), Xcode 27.2 (27B48), AccessibilityPlatformTranslation 1.0 / 591.4.5, AppKit 6.9 / 2775.20.133. The AXP binary resides in the dyld cache. These are installed runtime metadata results, not SDK availability promises. Other OS/build/architecture combinations require separate ABI qualification.

The Objective-C helper links Foundation and explicitly loads only `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation` with `RTLD_NOW | RTLD_LOCAL`. Its dependencies load transitively; image lists before/after are in JSON. It enumerates 17 AXP/custom-action classes with `objc_copyClassList`, `class_copyMethodList`, `class_getSuperclass`, `method_getTypeEncoding`, copied argument/return types and property metadata. It sends no AXP/custom-action messages, creates no AXP objects, calls no IMP, registers no device/delegate and issues no target request. No NSApplication, window, run loop, Simulator launch, boot, install, attach, input or setting mutation occurs in helper source.

Dispatch was reviewed before execution. Exactly `--metadata` is accepted. No argument, unknown argument and inherited `MAC_PILOT_AX_ABI_ENTERED=1` root entry each exited 64 before the explicit dlopen. Foundation/dyld startup necessarily precedes main; rejection does not claim zero system startup initialization. The watchdog proved rejection routes first, then ran metadata. Child environment was limited to PATH, HOME, TMPDIR, LANG and the recorded markers; inherited DYLD variables were excluded.

Each run used a parent-created session/process group, 15-second deadline, exact executable instance budget one, path verification through libproc and owned-group cleanup. Metadata exited 0 in 0.169 seconds; sampled peak one; all four runs ended with zero owned leftovers and zero cleanup signals. No owned children or new GUI/service process appeared during the metadata run; the sole new sampled process was the watchdog's `ps`. Unrelated background processes appeared during reject-route snapshots and were untouched. Sampling and source review do not prove absence of every transient process, dependency-internal IPC or launch initializer effect. No GUI side effect was observed; this was not a visual desktop inspection or IPC trace. No foreground lease was used for this CLI experiment.

## Exact method support

`self` and `_cmd` are included in encodings. `@` is an object, `@?` a block, `:` a selector, `B` the installed BOOL encoding, `v` void, `i` signed 32-bit, `I` unsigned 32-bit and `Q` unsigned 64-bit. CGPoint/CGRect contain doubles here. An object encoding alone does not establish NSArray contents, mutability, ownership annotations or nullability. `absent` means absent from the enumerated class/superclass method lists, not proof that dynamic forwarding can never supply it. The wrapper must reject unqualified forwarding.

Abbreviations: T = AXPTranslator; O = AXPTranslationObject; E = AXPMacPlatformElement; A = NSAccessibilityCustomAction. Owner `NSAccessibilityElement` indicates inherited AppKit behavior, which needs guest-semantic verification.

| Class | Selector | Defining owner | Exact encoding |
| --- | --- | --- | --- |
| T | `+sharedInstance` | AXPTranslator | `@16@0:8` |
| T | `-frontmostApplicationWithDisplayId:bridgeDelegateToken:` | AXPTranslator | `@28@0:8I16@20` |
| T | `-macPlatformElementFromTranslation:` | AXPTranslator | `@24@0:8@16` |
| T | `-objectAtPoint:displayId:bridgeDelegateToken:` | AXPTranslator | `@44@0:8{CGPoint=dd}16I32@36` |
| T | `-setBridgeTokenDelegate:` | AXPTranslator | `v24@0:8@16` |
| O | `-bridgeDelegateToken` | AXPTranslationObject | `@16@0:8` |
| O | `-setBridgeDelegateToken:` | AXPTranslationObject | `v24@0:8@16` |
| O | `-pid` | AXPTranslationObject | `i16@0:8` |
| O | `-objectID` | AXPTranslationObject | `Q16@0:8` |
| O | `-displayID` | absent | `—` |
| O | `-displayId` | absent | `—` |
| O | `-contextID` | absent | `—` |
| E | `-translation` | AXPMacPlatformElement | `@16@0:8` |
| E | `-pid` | absent | `—` |
| E | `-accessibilityChildren` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityParent` | AXPMacPlatformElement | `@16@0:8` |
| E | `-accessibilityRole` | AXPMacPlatformElement | `@16@0:8` |
| E | `-accessibilitySubrole` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityRoleDescription` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityTitle` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityLabel` | AXPMacPlatformElement | `@16@0:8` |
| E | `-accessibilityIdentifier` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityValue` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityHelp` | NSAccessibilityElement | `@16@0:8` |
| E | `-accessibilityTraits` | absent | `—` |
| E | `-traits` | absent | `—` |
| E | `-isAccessibilityEnabled` | AXPMacPlatformElement | `B16@0:8` |
| E | `-accessibilityFrame` | AXPMacPlatformElement | `{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8` |
| E | `-accessibilityActivationPoint` | AXPMacPlatformElement | `{CGPoint=dd}16@0:8` |
| E | `-accessibilityActionNames` | AXPMacPlatformElement | `@16@0:8` |
| E | `-accessibilityPerformPress` | AXPMacPlatformElement | `B16@0:8` |
| E | `-performPress` | absent | `—` |
| E | `-performIncrementAction` | AXPMacPlatformElement | `v16@0:8` |
| E | `-performDecrementAction` | AXPMacPlatformElement | `v16@0:8` |
| E | `-accessibilityPerformIncrement` | NSAccessibilityElement | `B16@0:8` |
| E | `-accessibilityPerformDecrement` | NSAccessibilityElement | `B16@0:8` |
| E | `-performEscapeAction` | AXPMacPlatformElement | `v16@0:8` |
| E | `-accessibilityPerformAction:` | AXPMacPlatformElement | `v24@0:8@16` |
| E | `-accessibilityCustomActions` | AXPMacPlatformElement | `@16@0:8` |
| E | `-accessibilityIsAttributeSettable:` | AXPMacPlatformElement | `B24@0:8@16` |
| E | `-accessibilitySetValue:forAttribute:` | AXPMacPlatformElement | `v32@0:8@16@24` |
| E | `-setAccessibilityValue:` | NSAccessibilityElement | `v24@0:8@16` |
| E | `-accessibilityAttributeNames` | AXPMacPlatformElement | `@16@0:8` |
| E | `-accessibilityAttributeValue:` | AXPMacPlatformElement | `@24@0:8@16` |
| E | `-accessibilityAttributeValue:forParameter:` | AXPMacPlatformElement | `@32@0:8@16@24` |
| E | `-accessibilityHitTest:` | AXPMacPlatformElement | `@32@0:8{CGPoint=dd}16` |
| E | `-accessibilityHitTest:withDisplayId:` | absent | `—` |
| E | `-accessibilityHitTest:withDisplayId:contextId:` | AXPMacPlatformElement | `@40@0:8{CGPoint=dd}16I32I36` |
| E | `-isAccessibilityProtectedContent` | NSAccessibilityElement | `B16@0:8` |
| E | `-accessibilityIsProtectedContent` | absent | `—` |
| E | `-isSecureTextEntry` | absent | `—` |
| E | `-accessibilityIsSecureTextEntry` | absent | `—` |
| A | `-name` | NSAccessibilityCustomAction | `@16@0:8` |
| A | `-target` | NSAccessibilityCustomAction | `@16@0:8` |
| A | `-selector` | NSAccessibilityCustomAction | `:16@0:8` |
| A | `-handler` | NSAccessibilityCustomAction | `@?16@0:8` |
| A | `-perform` | absent | `—` |

The full JSON also includes both method kinds for every superclass, all AXP classes, properties and image provenance. No implementation-pointer lookup was used as a method-support test.

## Comparison with pinned idb and repository

Compared with idb headers pinned at [5f31fc0450c844f89e6a0e8315552b10a944bed5](https://github.com/cameroncooke/idb/tree/5f31fc0450c844f89e6a0e8315552b10a944bed5/PrivateHeaders/AccessibilityPlatformTranslation), retained in the earlier research directory:

- Header `accessibilityHitTest:withDisplayId:` is absent; installed replacement `accessibilityHitTest:withDisplayId:contextId:` adds UInt32 context. Never cast the old two-argument signature to the new selector. Translator `objectAtPoint:displayId:bridgeDelegateToken:` remains a candidate that avoids inventing context zero.
- Header BOOL `performEscapeAction` changed to void. Increment/decrement and generic action are void in both evidence sets. Press remains BOOL.
- Header directly declares element `pid`, `accessibilityValue`, `setAccessibilityValue:` and `accessibilityTitle`. Installed `pid` is absent; value/title/getter/setter are inherited from NSAccessibilityElement. ABI compatibility of the inherited setter does not prove forwarding to guest state.
- Translation token/objectID/PID types, frontmost, conversion, press, generic attribute access, settable query and two-argument attribute setter match the pinned candidate signatures. No `displayID`, `displayId` or `contextID` translation getter appears; inspect the complete property metadata rather than invent one.
- AXP's `respondsToSelector:` and `isAccessibilitySelectorAllowed:` overrides are present. Later capability checks must combine exact method metadata with per-instance advertisement; either alone is insufficient. New tree-cache/registration selectors exist, but were neither invoked nor semantically qualified.

Current `SimulatorAccessibility.swift` source: `FrontFn` `(object, selector, UInt32, NSString) -> object?` and both press casts `(object, selector) -> Bool` agree with this arm64 ABI. No demonstrated cast mismatch in these existing paths. `macPlatformElementFromTranslation:` is object-in/object-out. Current hard-coded display 0 remains a mapping assumption, not an ABI fact. KVC for token/PID/frame/value/children can box scalars and structs but is not a typed ABI guard or an exception boundary. The new UI does not yet have live value setters, increment or backend point-hit dispatch to validate.

The bridge's CoreSimulator send cast agrees in broad types with prior static installed encoding `v40@0:8@16@24@?32`; this helper did not load CoreSimulator or independently qualify the block's argument ABI. Block signatures are not recoverable from `@?` alone. Do not label that path newly live-verified.

## Ready-to-implement typed boundary

Prefer a small Objective-C adapter compiled for the host architecture with explicit method declarations and `@try/@catch`, exposed through typed Swift operations. Keep private interfaces behind this adapter. Validate actual class lineage, defining method, argument count, argument/return encodings and approved installed-build capability profile before any call. Then perform the allowed per-instance capability checks. Missing/changed ABI returns `unsupportedABI`; absent selector returns `unsupportedSelector`; no attribute/action advertisement returns `unsupportedCapability`. Nil, exception, timeout, target change and delivery uncertainty remain distinct results. Do not fall back to arbitrary selectors or KVC keys supplied by users.

Proposed C/Objective-C IMP prototypes (self and selector first):

```objc
id       (*Object0)(id, SEL);
id       (*Object1)(id, SEL, id);
id       (*Object2)(id, SEL, id, id);
BOOL     (*Bool0)(id, SEL);
BOOL     (*Bool1)(id, SEL, id);
void     (*Void0)(id, SEL);
void     (*Void1)(id, SEL, id);
void     (*Void2)(id, SEL, id, id);
int32_t  (*PID0)(id, SEL);
uint64_t (*ObjectID0)(id, SEL);
id       (*Front)(id, SEL, uint32_t, id);
id       (*Point)(id, SEL, CGPoint);
id       (*PointToken)(id, SEL, CGPoint, uint32_t, id);
id       (*PointContext)(id, SEL, CGPoint, uint32_t, uint32_t);
CGPoint  (*ActivationPoint0)(id, SEL);
CGRect   (*Frame0)(id, SEL);
SEL      (*Selector0)(id, SEL);
```

These are invocation shapes, not an implementation or a promise that unchecked casts are safe. Prefer compiler-generated typed messaging for struct returns and ARC ownership. On arm64 CGRect and CGPoint must use their declared struct ABI; object-return `perform` cannot represent them. Requalify other architectures instead of assuming identical struct dispatch. Validate parsed types/layouts; preserve raw encodings for diagnosis rather than only comparing offset strings.

Read object results as retained, bounded-session NSObject/NSArray references. Validate each actual object type before using it. Avoid Swift array bridging or serialization when a lazy native array can be traversed in the adapter, but do not promise zero allocation or zero copy: encodings expose neither collection representation nor cache behavior. Holding arrays/objects does not freeze guest state. Build immutable snapshots before crossing queues/UI boundaries; retaining a container does not prove its nested values are immutable. No returned pointer may outlive its owning session/pool without retained ownership. NS/CF ownership transfer rules must remain explicit.

For adjustment, dispatch only approved `performIncrementAction` / `performDecrementAction` after current AXIncrement/AXDecrement advertisement. Their void result is `dispatched`, never success. For generic action, allow only adapter-owned action constants. Press BOOL is dispatch feedback; reread fixture state even after YES. Never infer supported action-name contents from the presence of `accessibilityActionNames`.

For value editing, require advertised AXValue and successful `accessibilityIsAttributeSettable:`; candidate setter is void `accessibilitySetValue:forAttribute:` with value first and attribute second. Keep `setAccessibilityValue:` disabled pending proof of inherited behavior. Accept only a fixture-qualified value type and bounds; do not convert arbitrary strings to numbers or write arbitrary attributes. A successful settable query is necessary but does not prove setter fidelity or transactional behavior. Void setter return supplies no success bit. Do not report safe editing before guest state and side effects are verified.

For custom actions, metadata establishes `name -> id`, weak `target -> id`, `selector -> SEL`, `handler -> block`. It does not reveal the returned block's signature or the target's selected method. The installed AppKit header declares `BOOL (^)(void)` handler and target methods either `BOOL method(void)` or `BOOL method(NSAccessibilityCustomAction *)`. Retain the action and a resolved strong target for the operation; copy a qualified block within the ObjC boundary. Verify a target method's actual BOOL/no-arg-or-one-object encoding before invocation. Only use a selector obtained from the retained, snapshot-bound system action, never from user input. Duplicate names require separate opaque action handles. No generic `perform` method is present. AXP-specific handler semantics remain untested.

## Secure/protected values and execution lifetime

Inherited `isAccessibilityProtectedContent -> BOOL` and its setter exist. No E/O `traits`, `accessibilityTraits`, `isSecureTextEntry` or `accessibilityIsSecureTextEntry` getter was found. Role/subrole and generic attribute enumeration are candidates for secure-field detection, not verified secure policy. `supportsSecureCoding` indicates serialization support; it does not indicate password content. Default to redaction and disabled writes when protection status is unknown. Do not expose raw element data as an escape hatch or call the protected-content setter.

Serialize global translator creation, delegate installation, token registration, all lazy reads, mutations and token removal on one owned executor. Keep its callback-completion queue separate from any synchronous wait executor; assert queue identity to prevent self-deadlock. A process-wide weak bridge delegate needs strong owner lifetime. Multiple LCD windows must not replace it independently.

Use one absolute monotonic whole-tree deadline, node/depth/cycle bounds and cancellation state. Pass only the remaining budget into each lazy request; a per-property five-second wait can otherwise multiply across the tree. Hold response state in a callback-retained heap object with a lock and one terminal transition. Read/write the result under that lock; after timeout, late callbacks must not update the returned result, resume twice or retain a token forever. A semaphore signal only orders the successful wait path; current code ignores timeout and may read `response` concurrently with a late write. Cancellation cannot retract a delivered mutation. Mark timed-out writes `deliveryUncertain`, never auto-retry, and reconcile through a fresh read.

Catch NSException inside the Objective-C boundary and return a typed backend failure before returning to Swift. Swift `do/catch` does not catch NSException. Compile that adapter with ARC exception cleanup enabled. Exceptions do not repair an ABI mismatch, memory fault, hang or guest side effect; avoid continuing a corrupted session. An in-process deadline cannot interrupt an arbitrary blocking private call. If hard containment is required, use a separately designed request helper with an outer deadline and token/session invalidation; this metadata helper is not that runtime transport.

## Next serial fixture tests

1. On one explicitly claimed, already available fixture device, verify token scoping, actual returned class/types, PID/objectID lifetime, parent/children, help/value/role/subrole, raw traits availability and secure redaction. Verify independent windows cannot cross-route tokens. Include nil/empty/unsupported/error separately.
2. Verify exactly one press, increment and decrement against independent fixture counters; compare AX action names and disabled/nonsettable cases. Void dispatch and BOOL dispatch must be distinguished from observed counter change.
3. Verify duplicate-name custom actions, both handler and target-selector forms, stale/weak target failure, target method ABI rejection and state reread. Reject unqualified target/block forms without dispatch.
4. Verify text/numeric/bool AXValue setters against the fixture's model and callbacks, including bounds, validation rejection, secure fields and inherited setter versus explicit attribute setter. Determine whether the latter changes guest state, an Inspector override or only host cache. Do not enable edits until this passes.
5. Verify translator point query and context-aware element query against independent overlapping/nonrectangular landmarks. Establish actual display/context sources, orientation/fold/external-display mapping and rendered LCD alignment. Missing mapping is unsupported; zero is not a discovered identity.
6. Inject delayed/lost/duplicate replies, timeout after dispatch, cancellation, app/PID/display replacement, concurrent windows, refresh/close during traversal and cyclic/mutable arrays. Prove no repeated writes, no late result publication, bounded traversal and clean token release. Test exception conversion independently. Preserve production input guards and native-check watchdog rules for every later GUI run.

## Evidence and checks

Local-only artifact root: `/tmp/mac-pilot-ax-abi.050aZ7/` (resolved `/private/tmp/mac-pilot-ax-abi.050aZ7/`). `metadata.json` is complete runtime output; `support-matrix.json` records supported and absent candidates; `versions.json` records installed versions; `metadata.m` and `watchdog.py` are helper sources; `ax-abi-metadata` is the executable. `build.log`, `watchdog.log`, `watchdog.json`, and each route's `.stdout`/`.stderr` preserve full logs. `sha256.json` records source/executable/evidence hashes. Prior pinned inputs remain at `/tmp/mac-pilot-ax-research.m82jnK/`. No binary or full local log was added to Git.

Checks: clang build passed without diagnostics; reject routes 64/64/64; metadata 0; zero owned leftovers. Distribution validation and document whitespace results are recorded in `distribution.log` and `doc-checks.json`. Only this new document was written in the repository. Existing edits were preserved. No production build, runtime guest invocation, GUI check, local installation, restart, commit, push or publication was performed; those are outside this research assignment.

Primary ABI references: [Apple type encodings](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html), [Apple runtime declarations](https://github.com/apple-oss-distributions/objc4/blob/main/runtime/runtime.h), [Clang ARC ownership and exception rules](https://clang.llvm.org/docs/AutomaticReferenceCounting.html), and the installed Xcode SDK `AppKit.framework/Headers/NSAccessibilityCustomAction.h` (retained with its hash in the artifact directory). These support type interpretation, metadata lookup, ownership and exception handling; they do not document Apple's private guest protocol.
