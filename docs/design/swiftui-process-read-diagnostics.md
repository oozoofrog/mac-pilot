# Opt-in process-read diagnostic preparation

This utility adds diagnostic boundaries only. It does not establish a latency cause,
qualify a helper, authorize an attempt, change an acceptance rule, or extend a budget.
FAILED 10/10, six fixture lifetimes, exhausted isolated-probe 3/3, and the unresolved
full fixture 74/75 and actual Foundation invocation remain unchanged. The root's
pre-Popen 12-second check and per-normalization checkpoints remain intact.

## Explicit caller usage

Importing `trace_process_reads.py` does nothing beyond definitions/imports. There is
no CLI, launcher, environment hook, census, subprocess selection, or automatic install.
An authored diagnostic caller must already have the reviewed modules loaded and an
owned private output directory (0700). The utility refuses existing trace files.
For example, around an **already authorized** call site:

```python
from trace_process_reads import ProcessReadTrace

# watchdog, native, session are the existing caller's modules.
# inherited_cutoff and parent_deadline are the ORIGINAL values, not new budgets.
with ProcessReadTrace(private_output, 'inventory',
                      cutoff=inherited_cutoff, deadline=parent_deadline) as trace:
    trace.bind_inventory(watchdog, 'rows')
    trace.bind_inventory(native, 'instances')
    trace.bind(watchdog, 'checkpoint', 'checkpoint')
    trace.bind(watchdog.ProcessObservation, 'check', 'checkpoint')
    trace.bind(watchdog.ProcessObservation, 'snapshot', 'snapshot')
    trace.bind(watchdog.ProcessObservation, 'validate_partial', 'validation')
    trace.bind(watchdog, 'wait_group_readback', 'readback')
    trace.bind(watchdog, 'graceful_stop', 'cleanup')
    # Invoke ONLY the pre-existing operation, unchanged, at this location.
    result = existing_operation()
```

For the existing CLI parent route, use role `cli-parent`, bind `session.parent` to
`parent`, `session.received_deadline` to `checkpoint`, `Path.read_text` to
`receipt-read`, and `session.save` to `receipt-write`. Those wrappers pass every
argument and return value unchanged. Receipt records identify only the fixed names
`session.json`, `parent.json`, `target.json`, or `other`. They never log file content.
Use explicit `trace.span('validation')`, `trace.span('parse')`, or
`trace.span('receipt-read')` at an authored caller's existing boundaries when finer
semantic milestones are available. Bind the actual owning validation callback if
its execution must be separated from the observer's surrounding work. A wrapper
around `parent` alone cannot separate its internal receipt validation.

Do not wrap already-running child processes retroactively. This scope is local to
one interpreter/thread and is not inherited instrumentation for a CLI child. A
future child-side diagnostic caller needs its own distinct private output and the
same inherited deadline. No executable-selection interface is provided.

## Boundaries and uncertainty

The reviewed source is the local Xcode CPython 3.9 `subprocess.py`, specifically
`run`, `Popen.__init__`, `_execute_child`, `communicate`, `_communicate`,
`_check_timeout`, polling/wait methods, and their direct `os.read`/`os.waitpid`
call sites. Current `close_fds=True` inventory calls use `_posixsubprocess.fork_exec`, then read
the exec-error pipe synchronously. `communicate(timeout)` starts its relative
interval after construction. POSIX `run` can kill and wait after timeout.

Temporary wrappers record entry, return, and escaping exception boundaries for
construction, `_execute_child`, the actual `_posixsubprocess.fork_exec` callable (or the runtime
`_fork_exec` alias when present), communicate,
selector selection, direct pipe reads (byte count and EOF), poll/wait/reap, and
kill requests. `_fork_exec` return records the returned PID; construction return
records `Popen.pid`. Kill/reap records observe existing operations and confer no
rights. No additional wait, signal, read, poll, or child launch is performed.
Polling can use a captured `_waitpid` default argument, so a poll method boundary
does not guarantee a separate actual `reap` syscall event.

A `_fork_exec` entry without return locates an incomplete C-call interval. It does
**not** distinguish fork, vfork, exec, or an internal lock. A returned PID followed
by an incomplete error-pipe read is a different interval. Error-pipe EOF means the
parent read returned EOF; it does not prove application readiness. Output EOF and
direct-child reap are separate from descendant absence. A missing stage can mean
an unused branch, wrong thread, unsupported runtime hook, truncation, storage
failure, termination, or a stall. It never proves an operation succeeded.

`rows`/`instances` entry and return delimit inventory; `check_output` return marks
its subprocess-result boundary. Per-row `realpath` records delimit normalization
with zero-based indices of normalization calls (including nonmatching native
instance rows). The gap after `check_output` and before normalization includes
checkpointing, splitting, field parsing, and scheduling. It is not an isolated
parser measurement. No stdlib internals are rewritten to synthesize finer stages.
These hooks are source-specific; another Python release or an unhooked fast path
requires source review. Existing observer checks remain authoritative.

Each record uses `clock_gettime(CLOCK_MONOTONIC)` explicitly, the session clock.
Declared original cutoff/deadline values are retained on every record. Numeric
cutoff/deadline locals within eight caller frames and observer `self.cutoff` are
also retained on entry when available; they are observations, never replacements.
No timestamp is compared with `monotonic_ns` or used to admit work. Timeouts and
unknown states remain unchanged. Unknown exception classes use `other`; known
observer, timeout, cancellation, and OS exception types have fixed labels. Messages,
argv, environment, path contents, and arbitrary user text are excluded.

## Storage and scope

Defaults: 64 KiB JSONL, 256 events, and 4096 total partial-output bytes. Hard
configuration ceilings: 1 MiB, 4096 events, 64 KiB partial output. The trace reserves
space/event capacity for one truncation indicator, then stops recording. Every
record is an immediate append through an exclusively created 0600 descriptor;
there is no queue, buffer flush dependency, or recursive trace logger. Completed
writes survive abrupt parent exit; this is not power-loss durability. A partial
write or storage failure leaves an unknown tail and sets `storage_failed`; it
cannot guarantee a marker on a failed device. Output directory ancestors must be
trusted and stable; directory ownership/mode checks are not protection against an
owner concurrently replacing paths.

Only the first observed `TimeoutExpired` saves actual stdout/stderr, in fixed
0600 `stdout.partial`/`stderr.partial` files in that private directory. The total
payload cap is shared, stdout first. Missing (`None`) is recorded as missing and
creates no stream file; empty is present with zero bytes. Byte output is preserved;
string output uses bounded UTF-8 encoding and can end inside a code point. Metadata
records source units, stored bytes, encoding, and truncation. Existing files are
never overwritten. Partial files are private raw evidence; do not publish them.
No command, exception message, or stream data goes in JSONL or this document.

There is one active scope per interpreter; nesting, concurrent scopes, and reuse
are rejected. Bindings are temporary process-wide mutations. Calls on other threads
bypass logging and invoke the original callable; they still encounter a temporary
wrapper. Hooks are restored in reverse order on success, error, or cancellation.
The diagnostic caller must use a quiescent interpreter with no concurrent hook
owners. Never cache wrappers for use after scope exit, fork inside the scope outside
the reviewed existing operation, or treat this as transparent production tracing.
The scope does not install hooks in other threads or automatically instrument an
advisory thread. Instrumentation adds Python and filesystem work and can perturb
the measured intervals. It is evidence preparation, not the cause fix.

## Future one-shot recipe (documentation only)

The lead must separately decide whether any execution is authorized. Do not run a
native proof from this preparation. If approved, author one fixed diagnostic caller
for the existing inventory or guard-parent read, with a fresh private directory and
current source pins. Preserve the existing 3-second observation cutoff, original
12-second work admission, CLI 10-second communicate interval where applicable,
25-second outer probe limit, and every ownership/process/cleanup budget. Do not
restart a deadline, widen permissions, repeat on timeout, or add a census sampler.
Instrument the owning thread explicitly; retain the outer caller's actual partial
timeout output too. Stop after that single authorized read. Reconcile existing
cleanup records independently before considering any subsequent action.

Inspect the last completed interval and first missing return alongside truncation,
storage status, inherited cutoffs, receipt read/write, and readback. An incomplete
`_fork_exec`, error-pipe read, output read/EOF, selector wait, normalization, or
receipt/readback interval supports a narrower next investigation. It establishes
neither a root cause nor helper acceptance. Missing stages remain unknown.
