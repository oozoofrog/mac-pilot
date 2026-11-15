# Isolated debugger lifecycle prototypes

## Directly owned server over a private socketpair

`remote_run.py` creates each debugserver as its own direct child, with an inherited AF_UNIX socketpair rather than a socket pathname or TCP port. It checks the exact Xcode executable, PID, process start time and parent before starting LLDB; `remote_collector.py` checks them again before connecting and before the separate remote attach. It checks the fixture's identity and stopped/traced status before attach, records evidence per case, and cleans up only its own direct children. The traced case uses another directly owned server and holder. No `SIGCONT` is sent; a deliberately stopped fixture is disposed with `SIGKILL` after its state is recorded.

The watchdog's 480-second budget reserves 101 seconds for cleanup, leaving 379 seconds for worker execution. It checks the exact fixture path against a budget of two instances (fixture and one probe). A nonblocking shared lock prevents concurrent probe launches. It permits one exact-path debugserver, or two in the traced case (collector and holder); the worker also enforces one per role. An unverified server snapshot counts toward the budget and grants no signal authority.

On failure, the watchdog first gives its directly created worker up to 85 seconds to run cleanup and reap that worker's direct children. The budget covers a server-start unwind (10s), holder release (8s), recovery observation including its last probe (5+3s), four sequential child TERM/KILL waits (40s), fixture probe and wait (3+5s), and 11s margin. The parent also reserves worker wait, group readback and process snapshot time. If necessary, it can kill and wait only that unreaped `Popen` child. There is no `killpg` fallback. Once the worker has been reaped, its old PGID and ancestor relationships never authorize signals to other processes. Recorded descendant server identities are observed only; live, zombie, reused or unknown descendants cause failure and are left for their actual owner. A bounded fresh snapshot separates live, zombie and unknown members of the historical group, and any of them means the observed group is nonempty. The snapshot grants no ownership or signal authority.

The worker owns waits for its fixture, LLDB clients and debugservers. The watchdog owns only the worker's wait. A fixture reparented to process 1 is no longer a child either can reap. If the worker cannot complete its cleanup before the deadline, this watchdog does not claim complete cleanup of grandchildren. A connection, attach, ownership, restoration, timeout, cancellation or cleanup mismatch fails the case. This experiment does not collect UIKit hierarchy data or justify enabling a production UI. Existing debugger races and external stops remain outside its verified contract.

The cancel case writes a private request after the fixture confirms it entered its spin loop. A collector control thread rechecks OS process identity and requests `SBProcess.SendAsyncInterrupt()` on the captured owned session. Its void return is recorded but does not prove cancellation; the expression result, interrupt engine log, timing and restored fixture are also required. Whether the installed Python/SWIG binding releases the GIL during expression evaluation is unverified; a control request serviced only after the expression deadline fails the case.

After serial coordination, run with a unique nonexistent output directory:

```sh
python3 mac-computer-use/tests/view-hierarchy-prototype/remote_watchdog.py --case connect --output /tmp/mac-cu-remote-connect-UNIQUE
```

`--case` is required and runs exactly one of `connect`, `success`, `error`, `timeout`, `cancel`, `exit`, `paused`, or `traced`. Start with `connect`, which does not attach; review that evidence before `success` or another case, and use a new output directory for each. The output contains source hashes, the case's debugger log, collector JSON with a timestamped timeline, and `*.evidence.json`. Review the expected state and actual cleanup; a pass is evidence only for this disposable fixture. The runner never accepts an external target PID and does not launch an AppKit test app.

## Previous implicit-server prototype

This is an unconnected experiment, not a production view capture. It creates a signed command-line fixture, checks its executable path, PID, start time and parent, and attaches only to that fixture. The expressions exercise the debugger protocol; they do not collect UIKit views. It records evidence for normal expression evaluation, errors, timeouts, interruption, exit, and preflight refusal for stopped or traced fixtures.

The runner samples parent ancestry from each owned LLDB PID and start time, recognizes only the active Xcode's exact debugserver executable, and records its PID and start time before any cleanup. It signals only a recorded matching server or its own process groups. Sampling can miss a short-lived or reparented server, so this is **not yet evidence of complete ownership or cleanup**; review the audit and agree a serial execution window before running it. A missing expected server, audit error, timeout or missing result fails the experiment. No user process may be substituted for the fixture. It never sends SIGCONT; it destroys the disposable fixture after recording its state.

After the cleanup guard is reviewed, run in the agreed serial test window with a unique, nonexistent output directory:

```sh
python3 mac-computer-use/tests/view-hierarchy-prototype/run.py --output /tmp/mac-cu-view-lifecycle-UNIQUE
```

Review source hashes, case logs, result JSON and final fixture state. A zero runner exit only means it completed its basic checks: it is not evidence that all expected outcomes, detach, debugserver cleanup, or restoration were proven. The result must be reviewed against each case's expected state. The fixture is cooperative; none of these tests proves safety when an external stop, competing debugger, PID reuse or debugger crash races with attachment. No production caller may use this prototype until those limitations are addressed by an explicitly supported contract.

## CLI-only direct-worker regression

`test_watchdog_cli.py` imports the actual `graceful_stop` and
`finish_direct_worker` functions without running watchdog main or any remote
runner. `watchdog_cli_helper.py` has only fixed normal/TERM/helper roles and
accepts no executable command. This regression does not authorize debugger runs.

Before running, use `python3 mac-computer-use/tests/view-hierarchy-prototype/test_watchdog_cli.py --guard`.
Then run once, serially:

```sh
python3 mac-computer-use/tests/view-hierarchy-prototype/test_watchdog_cli.py --output /tmp/mac-pilot-inspector/cli-owned-UNIQUE
```

Maximum total time is 42 seconds including cleanup (initial parent deadline 20s,
cleanup 6s per case, remaining case deadline 10s). Concurrent budget is supervisor
1, worker 1, fixed helper 1, plus at most one transient `/bin/ps` probe (3s
read timeout). The worker independently ends its work after 4s and waits its
finite 0.4s helper in `finally`; the supervisor waits the worker. On failure no
next case runs. Cleanup never kills the reaper or a group. TERM grace is 4s;
cleanup wait is 5s within a 6s parent alarm. Reaped Popen handles are tested with
TERM/KILL methods that raise if called. Forced KILL is deliberately not tested.

JSON evidence records identities, TERM request, finally/helper wait ordering,
return codes and separate live/zombie/unknown group snapshots. Snapshot failure
fails the run; disappearing identities are never silently classified as gone.
This proves only cooperative CLI cleanup. The historical PG23205 zombie failure
remains separate and unresolved; no signals or waits target that group. Debugger
main, traced lifecycle, UIKit, GUI and installation remain unverified/held.

The first CLI run failed before TERM: macOS framework Python's kernel executable
path differed from `sys.executable`. Normal exit passed; the TERM worker instead
reached its own alarm, waited its helper and was reaped. Both fresh group
snapshots were empty. The comparison now uses the supervisor's kernel executable
identity. A subsequent TERM-only run confirmed helper wait, worker exit and
supervisor wait with no new group residual; retain the original failed evidence.
