# SwiftUI recording preparation: advisory claim admission

The production recording helper admits a live selected-device claim only when the
claimant is a verified native ancestor of the actual helper. This is advisory
process coordination. It does not authenticate a conversation, logical session,
or user intent. A separately launched installed daemon that is not a descendant
continues to refuse a live claim. The `by` string grants no authority.

## Request and release boundary

`recording_preparation.validate_request` validates the current
`SimulatorViews.swift` serializer before claim reads, admission or ledger access:

- Exact root fields: `explicitClick`, `target`, `scope`; click must be literal true.
- Exact target fields: `pid`, `start`, `path`, `deviceID`.
- Exact recording scope fields: `deviceID`, `bootIdentity`, `presentation`,
  `generation`, `runtime`. This recording wire has no `displayID`; the capture
  graph scope is a different schema.
- PID is an exact integer in 1...2147483647. Start is two exact integers:
  seconds in 1...UInt64.max, microseconds in 0...999999. Generation is an exact
  integer in 0...UInt64.max. Bool and floating point values are refused.
- Target path is an absolute canonical real path, at most 4096 UTF-8 bytes,
  without NUL. Device is a canonical uppercase UUID and equals the scope device.
  Scope strings are nonempty, without NUL, at most 1024 UTF-8 bytes.
- Boot identity has the existing `device:pid:seconds:microseconds:path` form,
  the same device, bounded numeric fields and a canonical `launchd_sim` path.
  Native boot verification remains mandatory at dispatch boundaries.

Validation cannot prove that a person clicked a button. The existing explicit
production UI action and state-loss disclosure remain the entry point. The
helper still requires the real Ledger to read and validate terminal release,
including cleanup/recovery, empty nodes/undo and release receipts. A durable
per-target `.recording` marker, under the existing ledger lock, prevents replay.

## Claim snapshot

`ClaimAdmission(device, probe)` reads the existing sim-pilot claim file directly.
It neither invokes another identity helper nor writes, prunes, acquires or
releases any claim. Internal underscore-prefixed file/clock/dead-process seams
are for executable tests; no request field selects them.

The read is bounded to 1 MiB, uses `O_NOFOLLOW`, checks regular-file type, same UID
and absence of group/world write permission, and compares inode/device/size and
change times before/after reading and against the selected pathname. Duplicate
JSON keys, nonfinite JSON constants and duplicate case-insensitive selected-device
entries fail closed. The selected value must have exactly the existing fields
`pid`, `by`, `note`, `since`, with a nonempty string `by`, string `note`, PID greater
than 1 and a finite timezone-aware date. Unrelated entries are preserved; an
unrelated-device update does not invalidate an unchanged selected claim.

The initial snapshot fixes one of three routes:

1. No selected claim: absence must persist at every recheck.
2. Dead selected claim: the exact claim value must persist and its PID must stay
   absent. Only `ProcessLookupError` establishes absence; denied reads fail closed.
3. Live selected claim: walk from `os.getpid()` through native parents, at most
   32 nodes, stopping only at that claimant. Each node is read through the existing
   ProcessProbe, with repeated status/path reads and a second full-chain pass.
   PID 1, cycles, missing/denied reads, stopped/unknown/zombie states, exec,
   reparenting and PID reuse fail closed. Pin PID, start, parent and path for
   every chain node. Ordinary runnable/sleeping transitions do not change
   native identity and remain eligible across repeated reads.

Claimant native birth must be no later than `since`, and `since` must be no later
than the observed wall clock. Whole-second sim-pilot timestamps represent the
lower bound of that second. A claimant born later in that same second is refused;
there is no one-second PID reuse tolerance. A fresh ordinary claim can establish
a later timestamp. Every recheck compares the selected value and the original
chain; it never selects a replacement claimant or temporarily releases a claim.

## Dispatch and observer integration

Recheck cancellation, the pinned claim/chain, native boot and old target before
SIGTERM. After old exit observation, recheck before persisting `launchDispatch`,
and again after persistence immediately before the single selected-Xcode launch.
Recheck after launch returns and again before returning the verified successor.
The existing 8-second termination, 15-second launch and 5-second reconciliation
bounds remain unchanged. Launch is argv-free for the app and adds only the
qualified recording environment to the existing narrow launch environment.
There is no retry, escalation, product fixture argument or fixture whitelist.
Uncertain outcomes remain uncertain even if read-only reconciliation observes a
candidate. A marker records intent, not a syscall receipt.

The later observer integration must bind the validated request and real released
Ledger to the exact marker `{stage, target}` and native preparation-helper parent.
Keep pre-marker admission read-only. Preserve exact selected-Xcode wrapper roles,
serial utility budgets, old/new native lifetime history, fixture one-shot record,
shared owner cursor and cleanup custody. Preparation success alone does not grant
capture authority to an observer or publish a successor binding. None of that
observer/fixture wiring is implemented by this change.

## Limits and verification

Claims do not share an atomic lock with native process lifetime, boot, executable
replacement or numeric-PID signal dispatch. A same-UID writer can alter and restore
an advisory claim between reads. Exec/reparent/PID reuse can occur after the last
read. Numeric `kill` and simctl launch are not lifetime-atomic. This change narrows
those windows; it does not establish a transactional ownership transfer.

Focused tests use file, clock and native-process doubles. They cover ancestor and
foreign claims, pinned dead/absent routes, timestamp ambiguity, native identity
changes, invalid files/schema, and mutation after both durable dispatch markers.
They also read a real production Ledger serialized by the existing schema-2
supervisor test path. Existing intercepted `capture.main` recording call traces
remain applicable. These are headless checks, not live recording, simulator,
physical-input, runtime acceptance, installation or publication evidence.
