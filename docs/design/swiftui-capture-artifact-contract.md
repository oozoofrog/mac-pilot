# Headless UI capture artifact contract

`tests/view-hierarchy-prototype/ui_capture_contract.py` is a read-only contract
module for ProcessObservation integration. It does not change the observer,
session, preparation, production capture, or installed application. It grants no
editor, target execution, socket, signal, or cleanup rights. Runtime attempt 3
remains unauthorized.

## API and caller authority

All arguments below are required keyword arguments except the positional argv.
Returned dataclasses are frozen and contain immutable strings/tuples/FilePins.
JSON strings use sorted compact JSON. Invalid input raises `ContractError`.
Constructors are value objects, not cryptographic authority tokens.

`prepare(capture_resource, resident_resource, python, resource_hashes, build,
selected_tools) -> Prepared`:

- `capture_resource`: canonical absolute directory containing production Python
  resources. `resident_resource`: canonical absolute directory containing the
  prepared `resident-build.json` and image. Production can use the same directory;
  the explicitly synthetic trace uses separate directories.
- `python`: exact native-verified interpreter argv path, not an arbitrary Python
  executable inferred from request files.
- `resource_hashes`: externally verified prepared mapping of basename to SHA-256.
  Must include capture.py, resident_transport.py, edit_backend.py,
  swiftui_product.py and swiftui_graph.py. Supply the full prepared resource set.
- `build`: externally verified prepared resident-build object. The actual build
  file must equal it. ABI, architecture, image, source names and hashes are checked.
- `selected_tools`: externally verified mapping with exactly `server`, `python`,
  `sdk`, `lldb`. Values are actual tools_for_xcode paths and the resolved LLDB
  binary path. `server` is tools_for_xcode's resolved debugserver; `python` is its
  Resources/Python path (not an imported interpreter). `sdk` must equal the build.
  Server, LLDB binary and SDKSettings hashes must equal the build pins.

The caller must establish selected Xcode provenance before supplying these
values. This module does not execute xcode-select or resolve an arbitrary
framework alias into authority. For filesystem reads, pass resolved paths without
symlink ancestors. Native tool files are bounded at 512 MiB, resident/resources at
64 MiB. Revalidation rehashes these pins; integrate with a bounded observation
schedule rather than calling it once per unrelated process row.

`bind_capture(argv, prepared, target, expected_request, owned_app, owned_data,
bundle_id, ui_temporary_root, supervisor) -> CaptureBinding`:

- `argv` must be the actual five-element capture command:
  `[python, '-I', capture_resource+'/capture.py', '--capture', requestPath]`.
- `target` and `expected_request` must come from the independently bound current UI
  operation. The request file must equal both bindings and pass the canonical
  schema-2 validator, including inspectionScope and operation-specific fields.
- `owned_app`, `owned_data`, `bundle_id`: independently verified target containers
  and bundle. The target executable must be directly inside the app. Info.plist
  must agree with bundle and executable. This does not prove simctl's live
  container mapping; root must supply that evidence.
- `ui_temporary_root`: exact current UI temporary root. Its immediate child must
  be `mac-cu-views-<canonical UUID>`, owned by the current user and private.
- `supervisor`: native-verified complete identity dictionary containing `pid`,
  `start` (seconds/microseconds list), `parent`, `group`, `path`.

`CaptureBinding.commands(role)` returns tuples of exact origin command tuples.
Roles are `supervisor` and `resident-worker`. Supervisor commands cover manifest,
admit, stage, and tools_for_xcode. Worker commands are only the two actual
canonical/staged image codesign verifications. No generic codesign/xcrun matcher,
first-launch, install, launch, terminate, or native wrapper descendant is admitted.
Repeated calls and per-role budgets remain the observer's responsibility.
Debugserver Popen is a separate native identity role, not a utility command.
Host capture.py --identity remains root's existing role.

`bind_worker(argv, capture, observed_supervisor, observed_parent, expected_server,
current_request, expected_wire, now) -> WorkerBinding`:

- `argv` is the actual six-element resident_transport.py --worker command.
- `observed_supervisor` and `observed_parent` are current complete native
  identities. Both must equal the capture supervisor. Parent observation ordering
  is resolved by the caller; PID magnitude has no ordering meaning.
- `expected_server` is the independently observed complete debugserver identity.
  The production config emits pid/start/parent/path, **not group**. These four
  fields must match. Production status also emits transient state/traced fields;
  those fields are not used as lifetime identity. The complete expected identity is exposed as
  `expected_server_json` for root's native check and lifetime/reuse fence.
- `current_request` is root's current operation binding. It must equal the capture
  binding. Root must retire completed/rejected bindings and reject re-entry.
- `expected_wire` is an independently authorized current ledger wire object.
  It must equal wire.json. Obtain this from root's active operation/ledger binding;
  do not treat an untrusted wire.json read as new authority. Initial capture's
  ledger-generated epoch, capture and transition fields are not in the UI request.
  This explicit input accommodates actual Ledger.wire output and synthetic minimal
  tracing wires without inventing those fields. Common request fields, request
  digest when present, and noninitial epoch are also checked independently.
- `now` is the caller's current CLOCK_MONOTONIC value. It must precede the worker
  deadline. Root continues checking its own current cutoff after admission.

The channel must be exactly
`owned_data/Library/Caches/org.oozoofrog.mac-cu-resident/<SHA256 compact sorted target>/<operationID>`.
The module joins host admission/channel/wire files, channel worker/native request,
root pin and staged image with prepared build, target, operation, paths and server.
It verifies the ABI-2 header, exact canonical JSON payload and transport digest.
`WorkerBinding` exposes `channel`, `fd`, `expected_server_json`, `wire_json`,
`files`, and `commands(role='resident-worker')`.

The FD is a decimal integer in 1...2147483647. Argv proves no actual child socket
inheritance, endpoint identity or descriptor access. The config token is checked
for production shape only; root must bind the observed environment/token if that
is part of its native worker authentication.

`revalidate(binding)` works with Prepared, CaptureBinding and WorkerBinding. It
rejects changed/replaced files by device/inode/mode/owner/link count/size/mtime/
ctime and hash. Reads walk every ancestor with directory-relative O_NOFOLLOW,
reject nonregular/multilink/oversized files, check private artifacts, and compare
inode metadata before and after the bounded read. Atomic replacement invalidates
a previous pin even when bytes match. JSON files have a 64 KiB bound. There is no
persistent FD lock or filesystem freeze; root must revalidate at the admission
boundary and native-verify current identities. No userspace read promises immunity
to a concurrent owner replacing an ancestor immediately after a check.

## Evidence

The focused tests adapt only the synthetic trace's host directory before invoking
production supervise. Production-generated argv is never replaced. Actual
admit/stage/tools discovery/worker validation/cleanup execute with intercepted
subprocess and Engine seams. Capture/edit/revert/release and the existing staged
pin branch pass. Another positive uses actual Ledger.reserve/Ledger.wire for an
initial capture with an allocated epoch. No child or target engine executes.

Negative checks cover wrong target/operation/container/bundle, parent/start/server,
channel/resource paths, pin hash/UUID, wire/native digest, FD, deadline, malformed
and oversized files, file/ancestor symlinks, scope, stale inode replacement and
retired-operation mismatch. These are module-level proofs, not full observer
replay, native wrapper qualification, live capture or a runtime authorization.
