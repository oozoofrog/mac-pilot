# Unwired kernel inventory candidate

Recommendation: **revise before wiring**. This is a fail-closed raw inventory
candidate, not an acceptance replacement or a latency fix. Runtime qualification
remains FAILED10/10, six fixture lifetimes, isolated-probe-observation exhausted3/3.
No reset, native proof, actual capture, installation or harness integration occurred.

## Source and ABI

The selected developer directory was `/Applications/Xcode.app/Contents/Developer`.
Primary ABI evidence is its `MacOSX.sdk/usr/include/` declarations:

- `libproc.h:92–103`: exact argument and return types for `proc_listpids`,
  `proc_pidinfo`, and `proc_pidpath`. This header labels these interfaces private
  and subject to change.
- `sys/proc_info.h:51,59–83,723–724,749`: ALL_PIDS=1, complete BSDInfo layout,
  TBSDINFO=3, and maximum path buffer 4*MAXPATHLEN.
- `sys/_types.h:72,84,87`, `sys/param.h:95,196`, `sys/syslimits.h:103`:
  32-bit UID/GID/PID types, MAXCOMLEN=16, MAXPATHLEN=1024.
- `sys/proc.h:148–152`: numeric states 1 through 5, including zombie=5.

The ctypes layout is 136 bytes, with pgid at 100 and start seconds at 120.
No native compilation was used. Pure tests verify layout and typed declarations.
Apple's [libproc wrapper source](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)
corroborates byte counts for proc_listpids, PID counts for proc_listallpids, and
strlen excluding NUL for proc_pidpath. This public source is supplementary evidence,
not proof that the installed library matches that revision.

## API and rejection contract

`Inventory(cutoff, worker, targets, retained, groups).sample()` takes an inherited,
finite absolute CLOCK_MONOTONIC cutoff. The caller establishes it once, including
any three-second characterization cap; this object never extends it. At most two
samples share that cutoff. There is no automatic retry, subprocess, ps fallback,
command runner, signal other than existence-only kill(pid,0), attach, or reap.
Backend and clock injection exist for pure tests.

A fixed 16,384-PID buffer is allocated. Enumeration uses PROC_ALL_PIDS without UID,
parent or group filtering. Zero/negative, partial, malformed or saturated results
reject completeness; there is no dynamic allocation growth. Cumulative observed
PIDs and retained groups are capped at 16,384, paths at 4,096 bytes, targets at 16.
Successful enumeration is not an atomic snapshot. Processes created after the list,
processes born and dead between samples, and identity changes that reverse between
reads cannot be ruled out. Unsampled orphan descendants remain unknowable.

Each enumerated or previously enumerated PID receives status, path, normalization,
and status reads. Every kernel/path/normalization boundary checks the same cutoff
before and after work. Synchronous calls and filesystem normalization have no hard
return-time guarantee. Expired results remain raw evidence with complete=false;
no independent deadline or late successful acceptance is introduced.

Failed/partial BSDInfo and path buffers never become identity. Unknown numeric
states remain unknown; valid numeric scheduling states are retained rather than
collapsed to S. PID/start/parent/group changes and cross-sample path changes are
sticky conflicts. Scheduling changes alone are not lifetime changes. This candidate
rejects exec changes conservatively: existing verified-role forward-exec rules,
strict argv validation, topology constraints, budgets and input guards remain in
the owning observer and must not be replaced by this API.

Worker group membership, recursively discovered descendants across groups, exact
target matches, and retained PIDs/groups are accumulated. All previously enumerated
PIDs are read again even if missing from a later list. Successful partial topology
is retained for membership only; it is not cached identity or role authority.
Retained group reuse can conservatively include unrelated processes. It never
confers ownership or signal authority. Orphan/reparenting conflicts remain rejected.

## Global completeness is the blocker

Every unresolved global PID blocks completeness, regardless of apparent family,
UID, parent, short name, or permission error. Exact matches in incomplete results
are lower bounds. A family-complete result is not a global duplicate census.
Duplicate exact targets reject the result even outside the worker family.

A new kill(pid,0) ESRCH may settle a missing PID; positive or denied kill0 never
establishes identity. A fresh zombie status is recorded separately from disappearance
and reaping. If its path is unreadable, global exact-executable accounting remains
incomplete, even though the family observer might treat that PID as terminal.
This is deliberately stricter than existing family termination handling.

PID zero is explicitly unresolved: no executable exclusion has been established,
and kill(0,0) would be group-scoped. No current-user or kernel-process exemption is
invented. If this host returns PID zero or persistent unreadable processes, this
candidate cannot produce a complete global result. Current-machine usability is
**unmeasured**, not asserted: no actual census was run. The optional census was
skipped because the source contract still cannot establish a generally usable
acceptance replacement. A future lead decision must resolve this exclusion contract
or accept that the inventory remains diagnostic-only; it must not weaken global
exact-instance checking silently.

## Evidence and integration gaps

Only the two new Python files and this document were added. Existing watchdog,
session, native support, callback, manifest and product files were not edited.
The lead's 12-second launch-admission and per-path checkpoint fixes remain intact.

Pure command:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s mac-computer-use/tests/view-hierarchy-prototype -p test_process_inventory.py -v
```

The 25 pure tests cover ABI buffers, completeness, limits, duplicate paths,
retained orphans/groups, cross-group descendants, identity changes, unknown/zombie
states, transient ESRCH, cutoff boundaries and forbidden launch/signal calls.
Distribution and diff validation are separate source checks. Private handoff files
hold exact outputs, patch and hashes; these are not release artifacts.

No actual kernel census, own-process identity characterization or direct CLI
reaping evidence exists. No native/helper topology proof, SwiftUI graph/pixel
acceptance, Simulator action, or explanation of the historical latency is supplied.
The lead's existing 1.320856-second observation and capped trace are prior evidence;
this candidate neither repeats nor upgrades them.


## Lead read-only characterization — 2026-11-10

The lead verified all 12 source pins and eight artifact pins, then ran the unchanged candidate once with the original three-second cutoff and a ten-second parent limit. The census interpreter exited 0 and was reaped. A separate existence read returned ESRCH for that recorded PID. No native test app, Simulator fixture or helper was launched.

The sample took 0.222326 seconds. It resolved 1,810 rows and retained 204 unknown PIDs. Of these, 193 had denied status reads while executable path reads succeeded, nine had fresh running status but no executable path, one remained unresolved after ESRCH status/path reads while kill0 still succeeded, and one was PID zero. The raw result remains `complete=false`; path matches are lower bounds. The selected Python launcher's `sys.executable` path did not equal the observed running-image path, so that comparison supplies no own-executable qualification. The fresh own-PID/start/parent/group status was recorded separately.

Local file metadata shows `/bin/ps` is owned by root and has mode `-rwsr-xr-x`. The unprivileged libproc candidate is therefore not an equivalent replacement for the current privileged inventory. No exemption for unreadable PIDs or additional privilege is introduced. The candidate remains unwired. PID zero alone is not the usability blocker. Apple's [XNU initialization source](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/bsd_init.c) associates process zero with `kernel_task`; that source fact does not resolve the other current unreadable PIDs or qualify this installed private ABI.

The next bounded approach retains the existing authoritative ps census and reduces only advisory sampling to the already-owned process family. It must preserve unknown samples, conservative cleanup and current acceptance cutoffs. This is a proposal for the proof harness, not a successful helper or SwiftUI capture. Existing FAILED10/10, six fixture lifetimes and prior failed source/CLI attempts remain unchanged.
