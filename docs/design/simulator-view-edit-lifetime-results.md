# Foundation view-edit lifetime results

2026-11-09. The headless host-runtime experiment supports a capture-scoped strong-key/zeroing-weak-value registry. It does **not** enable production edits or establish LLDB, UIView, SafeEntry, or textured-inspector support.

## Files and execution

Only these new files belong to this experiment:

- `mac-computer-use/tests/view-edit-lifetime/main.m`: strict entry dispatch, lifetime/module tests and operation assertions.
- `mac-computer-use/tests/view-edit-lifetime/Operation.h`: fake graph and operation-driver interface.
- `mac-computer-use/tests/view-edit-lifetime/Operation.m`: small in-memory admission/operation fixture.
- `mac-computer-use/tests/view-edit-lifetime/registry-module.c`: unloadable runtime-only module; stores no callbacks or module-owned objects.
- `mac-computer-use/tests/view-edit-lifetime/run.py`: isolated build, source guard check, native watchdog, rejected-route checks and regressions.
- This results document.

Run from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 mac-computer-use/tests/view-edit-lifetime/run.py
```

Validated environment: macOS 27.2 (26B123), arm64, Apple clang 21.0.0 (clang-2100.3.34.1). The CLI and operation implementation use ARC, explicit autorelease scopes, `-Wall -Wextra -Werror`, and only `-framework Foundation`. The binary's dependencies include Foundation, its SDK-linked CoreFoundation dependency, libobjc and libSystem; no AppKit/UIKit. The C modules contain no Objective-C image metadata and do not manage Objective-C ownership themselves. The ARC executable installs the retained Foundation state before loading them.

Raw final evidence is local, outside the checkout:

- `/tmp/mac-cu-view-lifetime-qsw68w89/run.log`: exact compiler/check commands, tool versions, exit statuses, runtime assertions and cleanup.
- `/tmp/mac-cu-view-lifetime-qsw68w89/sha256.json`: all harness source, support source, executable and module SHA-256 hashes.
- `/tmp/mac-cu-view-lifetime-final-launch.log`: outer runner output, exit 0.
- `/tmp/mac-cu-view-lifetime-pha0vijc/run.log`: retained failed first experiment. The Objective-C module did not actually unload after `dlclose`; harness exited 1, owned leftovers were zero.
- `/tmp/mac-cu-view-lifetime-1mish5er/run.log`: passing intermediate C-module experiment, before the final source refinement.

No production source, installed app, helper dispatcher, common runner, capture resource, fixture, manifest, or other document was modified by this worker. No UI, NSApplication, Simulator, LLDB, bridge, input, install/restart, commit or publication was invoked.

## Observed results

The final harness passed **73 assertions**, exit 0. Nine rejected entry routes exited 64: production screen-recording helper, inherited `--native-check`, daemon, empty arguments, unknown arguments, extra root arguments, guide, update and client. The source-order check proves rejection precedes the explicit autorelease scope and test calls. Framework loading by dyld necessarily precedes `main`; no claim is made that argument parsing precedes dynamic loader work. No production helper was forged or implemented.

The runner uses the shared `native_check_support.check_routes(..., production_helper=False)` selfcheck semantics. Every launch uses `run_owned` with `max_instances=1`; rejected routes have 5-second deadlines, and the accepted harness has a 30-second deadline. The shared parent cleans only the exact unique executable and its owned process group, including failure/interruption. Final exact-executable leftovers: **0**. Six shared native safety regressions passed, including timeout, fixed fan-out, interruption, orphan cleanup and unrelated-process survival. Distribution validation and scoped `git diff --check` exited 0. New untracked files also received a direct trailing-whitespace/final-newline check, because `git diff` alone does not inspect untracked content.

### Lifetime and stable key

- `NSMapTable strongToWeakObjectsMapTable` did not retain the fake view. Final strong release zeroed lookup. A new same-class/default-property object did not acquire the old token.
- A strong local lookup preserved the object during the explicit operation scope. Releasing that local permitted weak zeroing. A strong object key survived its creator scope and was released when the map was dropped while the fake view remained alive.
- The fixture rejected still-alive detached and reparented nodes by fresh graph reachability plus weak identity/parent/window/class checks. The graph root is fixture-owned to simulate app ownership; it is not persistent registry retention of selected nodes.
- Clearing only the owned association preserved an unrelated association. Normal owner destruction released its associated value.
- Ordinary alloc/dealloc stress observed real address reuse at **allocation 8**, address `0x102e957c0`. Both lifetimes were `FakeView`, with the identical live parent/window objects, `hidden=false` and `alpha=1`. While the replacement was alive, the old token resolved nil and its prior association was absent. No numeric address was cast into an object. Addresses were observations only.
- Stress is capped at 20,000 allocations and at most 20,000 numeric-address records/weak keys. The successful run stopped after 8 allocations. A run without reuse reports `observed=false`; it cannot provide same-address evidence. `objc_constructInstance`/`objc_destructInstance` deterministic reuse was **not exercised**. This run proves actual ordinary reuse, not allocator-independent deterministic reuse, UIView reuse, or peak memory behavior.
- Two separately compiled C dylibs resolved the identical fixed `sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1")` key on the process-resident `NSObject` class anchor. Each `dlclose` returned 0 and subsequent `RTLD_NOLOAD` confirmed the module was absent. Foundation state remained after each unload and was read by the second module. State contains only Foundation values and a weak map; no persistent blocks, custom module classes, callbacks or JIT references. Schema/foreign-shape and owner collisions were refused without overwriting the foreign shape. Cleanup preserved the anchor's unrelated association. No per-capture selectors or global association removal were used.

The initial Objective-C module failure matters: successful `dlclose` alone is insufficient evidence of unload. The revised C shims prove runtime key persistence across **actual native code unload**, not LLDB expression/JIT disposal.

### Operation algorithm

The fake-view driver verifies JSON Boolean versus NSNumber numeric input, finite alpha in [0,1], 0/0.5/1 and exact readback; expected-old comparison; token/parent/window/class; generation and expiry; no-change skip; one setter invocation per operation ID; exact-payload replay versus payload conflict; high-water rejection after result eviction; guarded revert conflict and undo consumption.

The setter cases cover throw before write, write then throw, mismatched readback, detach after write and reentrant operation. Every exception after setter entry remains uncertain, including throw before write. Duplicate ambiguous operations reuse uncertainty without a second setter; a new operation is refused while quarantined. Reentrant entry returns busy. A simulated lost response quarantines dispatch. Capture release is idempotent and drops map/undo authority.

These are **algorithm tests**, not production integration. Full payload equality substitutes for a canonical digest. The journal is memory-only; tests explicitly simulate lost-response quarantine, rather than implementing a durable host journal or network transport. The driver keeps only the latest undo revision and uses a fixed fake node tuple and controlled clock. It does not implement the full schema, target epoch handshake, multi-node revision service, expiry cleanup service, bounded durable cache, or crash recovery. Its Boolean classification is tested on this host's Foundation JSON/NSNumber runtime class, not established for all Simulator runtimes. Value ABA remains undetectable. Tokens and ownership shape checks are not a security boundary against the inspected process.

## Remaining enablement gates

The later protected Simulator session must still establish:

1. Class-anchor/key and zeroing-weak behavior across separate LLDB expressions, detach/resume/reattach, JIT disposal, ARC/MRC differences and interrupted autorelease cleanup. C dylib results do not establish those conditions.
2. A bounded safe-entry predicate. Main-thread membership alone cannot establish safe UIKit debugger injection. Reject arbitrary UIKit/layout interruption unless independently justified; use a cooperative fixture checkpoint if that is the only validated capability.
3. Actual UIView deallocation/reuse, parent/window/scene changes, restart/PID reuse, weak nil, overwritten getters/setters, cancellation, nonreturning setters, exit and detach failures. Prove app running/untraced recovery and owned-child cleanup independently from mutation outcome. Do not retry an uncertain edit.
4. Real typed hidden/alpha changes, observed target readback and separately observed visible outcome; guarded revert conflict and app reconciliation behavior. No LLDB, UIView, SafeEntry or visible-pixel proof exists here.
5. Production schema and durable reservation integration; interrupted host reservation/restart; capture replacement/authority revocation; 20,001-node, 512-depth, 16-MiB and operation/cache/undo/epoch cap enforcement. This focused fixture bounds its own stress/traversal but does not complete those production capacity tests or repeated-capture memory measurements.
6. Per-node texture provenance and solo/subtree semantics, transforms, occlusion, clipping, protected/missing surfaces and inspector picking/alignment. This harness provides no LCD AX or 3D renderer evidence.

## Final binary hashes

Full source hashes are in `sha256.json` above.

| Artifact | SHA-256 |
|---|---|
| `lifetime-check` | `9e1ab281986946657e49728eabc321ba4db10b6d6a3320781fdef0dc3bd2b48e` |
| `module0.dylib` | `01cda619815f5471969bef88bb229c4bf52afd5c5919195c08acbf786a214dff` |
| `module1.dylib` | `1b9548cc3e950d1cf3b56f844eafdd34083d47ff02953435bcdbf53ea45ea46d` |
