# UI harness selected-tool contract

`tests/view-hierarchy-prototype/ui_tool_contract.py` is a pure matcher and
read-only configuration loader. It neither starts processes nor grants signal,
Simulator, target-engine, setup or execution authority. Runtime attempt 3 remains
unauthorized. Root must integrate this module with the independently validated
origin/artifact contract and native observer; these tests are not that integration.

## API and trust boundary

- `required_paths()` enumerates selected native tools, shells, wrappers, framework
  plists and the seven harness/concurrency source inputs.
- `Configuration.read(developer, hashes)` checks an exact caller-provided SHA-256
  mapping. Preparation must supply these trusted hashes, not learn them from an
  untrusted observation. The selected developer path, wrapper source digests,
  framework versions and harness source digests are additionally fixed here.
  Unsupported input changes fail closed and require review. Re-read configuration
  immediately before each reconciliation batch; a cached instance is not a file
  mutation/race fence. Native executable code-signing/identity verification stays
  with the caller. Hash reads do not prove what a previously launched process mapped.
- `Identity(pid, start, parent, group, path)` contains full native identity;
  `start` is the native `(seconds, microseconds)` tuple. Paths are exact native
  executable paths, not argv[0].
- `Origin(identity, parent, argv, provenance, lane, edges_verified)` binds an
  **already validated** exact invocation to its full immediate parent identity,
  native origin PID/start/group and the validator receipt. Lanes are `capture`,
  `display`; optional source labels `display-passive` and `display-synchronous`
  share the same aggregate limit. Native argv and ancestry do not identify the
  submitting Swift queue. A nonempty receipt is not validated by
  this module: root/peer must perform its artifact joins first. Paths, device IDs,
  bundle IDs and display output ownership in origin argv are their responsibility.
- `Observation(identity, argv, ancestors, edges_verified)` supplies exact tuple
  argv and immediate-parent-first ancestor observations ending at the origin.
  Root observations have an empty ancestor tuple. The caller proves each native
  parent/start edge, including the origin's parent, and rejects PID reuse and
  uncertainty before setting `edges_verified`. Missing ancestors fail closed.
- `match(config, origin, observed, previous=None)` returns `Match` with explicit
  role, remaining forward exec states, child limits, provenance, origin/native
  identity keys and phase. Keep the previous match for each PID/start through
  partial observation; use it on the next observation to reject reverse exec.
  Shell descendants may exec the exact version/comparison helper; they may never
  exec the final simctl/devicectl tool. A shell-child's forward chain lists its
  shell state followed by terminal alternatives, not a sequence between helpers.
  Those alternatives are constrained by tool and ancestry; helper-to-helper
  exec transitions reject.
- `validate_snapshot(config, origins, rows)` takes `(Origin, Observation, prior
  Match)` triples. Origins include still-live **and reserved/unresolved** origins,
  even if the root row is currently absent. It rejects duplicate native identity,
  unregistered origin, excess children and excess display concurrency. Only native
  exit reconciliation releases a reservation. Caller retains last-known children
  in its reconciliation inventory until exit is proved: an omitted child is not
  proof of absence. This module does not own inventory or history.
- `Rejected` contains the exact recordable rejection reason. No rejection changes
  authority. Mixed executable/argv exec-boundary reads must be retried by the
  observer under its existing deadline, never accepted as a relaxed alias.

## Source-backed executable states

For exact read-only simctl inventory/container origins, the root chain is
`/usr/bin/xcrun` → `/bin/bash <selected simctl script> <exact tail>` →
`CoreSimulator.framework/Versions/A/Resources/bin/simctl <exact tail>`.
For the exact display origin it is xcrun → `/bin/zsh <selected devicectl script>`
→ the CoreDevice native devicectl with the same tail. Script and final native
argv[0] are exact absolute paths. These are source-backed fixture states, not
claims that a live Simulator wrapper run was observed in this work.

The simctl source permits its identical-argv bash command-substitution shells,
the exact `PlistBuddy -c 'Print :CFBundleVersion' <CoreSimulator Info.plist>`,
`sort --version-sort`, and `head -n1`. `sort` and `head` use the bare argv[0] spelled
in source but must have `/usr/bin/sort` and `/usr/bin/head` native paths. Builtin
`printf` stays a bash shell; `/usr/bin/printf` is not admitted. Maximum descendant
parent depth is two. Canonicalization subshells execute sequentially. The largest
pipeline has root shell + comparison substitution shell + builtin printf shell +
sort + head: five native identities, including the reserved root. At most two
shell descendants, one sort, one head and one PlistBuddy are admitted; the total
five cap applies across roles and aliases, so all those maxima cannot coexist.

Devicectl admits at most one substitution shell and one exact CoreDevice plist
reader, total three including root, depth two. It has no sort/head role. Setup
`xcodebuild -runFirstLaunch` is never an origin or a descendant role. Matching
current version values do not authorize that branch.

The exact xcodebuild origin `/usr/bin/xcodebuild -version` forwards in the same
PID/start to `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild` with
that selected full path as argv[0]. This was observed with a direct owned CLI
child under a ten-second external parent deadline; no wrapper or Simulator tool
was invoked. A sampled old-path/new-argv combination is retained as uncertain
read evidence and rejected by the matcher. There is no blanket argv[0] exemption.

`xcrun --sdk iphonesimulator --show-sdk-path`, exact `xcode-select -p`, codesign
`--verify --strict <bound path>` and `-d --xml --entitlements - <bound path>` have
only their direct native root role. The SDK query has no simctl wrapper. Only
xcodebuild -version was executed for native argv observation; other command states
come from canonical intercepted production calls and source-controlled fixtures.

## Display concurrency for this harness only

The pinned `simulator-inspector-product-live/live.swift` calls the workflow and
`NSApplication.run` directly. It creates exactly one `SimulatorWindow` for the
selected device. It does not instantiate production AppDelegate, MenuBar or
SimulatorStatusBoard. The workflow sends synchronous work through `handleQueue`.

`SimulatorWindow.refresh` enqueues `observeSimulator` on the serial handle queue.
`SimulatorObservationLane` has one `running` read and one replaceable `pending`
job per device. `invalidate()` cancels but does not clear `running`; replacement
cannot start until the prior read returns. The passive lane therefore contributes
one display invocation. `activeScreen` calls synchronous `displays`; inspector
capture/fresh validation uses `handleQueue.async`/`sync`. That serial queue adds
one concurrent invocation. Cancellation can overlap these two reads; it does not
justify a third. The angle lane uses XPC, not another devicectl subprocess.

Budget: one UI root, one LCD/device, one passive display lane, one synchronous
caller, **two aggregate display origins**. Each origin has at most three native
identities through its devicectl wrapper: six total display-family identities.
The origin reservation is shared across xcrun/zsh/native aliases and persists
when root observation is partial. The two source lanes establish the aggregate
bound; the observer does not claim to assign each invocation to a Swift queue. The serial
handle queue can accumulate an unbounded number of queued closures, but only one
executes at a time; no unbounded concurrent native process count follows from it.
This is not a budget for all production windows, menus, users, or capture-server
families. Root supplies independent supervisor/worker origin reservations.

## Verification boundary

Tests call actual `record_canonical_calls()` for capture/edit/revert/release with
all subprocess/Engine seams intercepted, then positively match their utility
origins and wrapper phases. Native rows in those tests are synthetic. Other cases
cover exact display phases, children, aggregate/partial counts, reverse exec,
wrong identity/parent/group, unknown commands/scripts/helpers, setup/mutation,
configuration hashes and versions. Existing gap tests are unchanged.

Integration, observer ownership/termination, real wrapper sampling, code loaded
before a hash change and any future runtime attempt are outside this module's
proof. No global installation or publication is part of this work.
