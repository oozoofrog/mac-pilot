# Fixture recording restart entry

Run `python3 mac-computer-use/tests/swiftui-recording-entry/run.py` from the repository root. The runner extracts the marked Foundation/CryptoKit/Darwin implementation verbatim from `../swiftui-hierarchy-probe/Fixture.swift`, compiles a console executable, verifies rejected dispatch routes before executing tests, and typechecks the actual one-file iOS fixture. Each executable run uses `native_check_support.run_owned`, a deadline, exact executable ownership and a maximum of one instance. No Simulator application executes.

## Host contract (version 1)

All objects have closed fields. JSON files are limited to 8192 bytes. Write the control atomically as a same-UID regular single-link mode-0600 file at `Documents/restart-control.json`. Do not put fixture fields into production launch argv/environment. Initial entry remains `--fixture-session <session>` with matching `MAC_CU_FIXTURE_SESSION`. Initial recording flag is optional for compatibility. Restart entry requires zero extra arguments, absent session environment and exact `SWIFTUI_VIEW_DEBUG=287`. Both entries reject either inherited child marker.

Identity object, used consistently below:

```json
{"deviceID":"<SIMULATOR_UDID>","bundleID":"<CFBundleIdentifier>","executableRealpath":"<canonical executable>","dataRealpath":"<canonical NSHomeDirectory>","dataUUID":"<last data path component>","installationDigest":"<sha256>"}
```

`installationDigest` is SHA256 of UTF-8 `lowercaseSHA256(executable) + ":" + lowercaseSHA256(Info.plist)`. The app directory is the executable's parent and is checked against the running Bundle. Guest code uses `_NSGetExecutablePath`, Bundle, NSHomeDirectory and `sysctl(KERN_PROC_PID, getpid())` for the actual executable, app/data paths and self start time. Device UUID comes from the Simulator-provided `SIMULATOR_UDID`, not a guest query of host launchd. The host must independently bind device, boot, MCM container, native lifetime and installation. No same-UID launcher authentication is claimed.

`oldTarget` has exactly `{pid: integer, startSeconds: unsigned integer, startMicroseconds: unsigned integer}`. These are guest `kinfo_proc.p_starttime` values; host integration must join them to its native old-target binding rather than assume its target wire schema is interchangeable.

Arm control:

```json
{"version":1,"action":"armRestart","restartID":"<fresh UUID>","session":"<immutable session>","pid":123,"issuedUnixSeconds":1000.0,"remainingSeconds":30.0,"identity":{"deviceID":"…","bundleID":"…","executableRealpath":"…","dataRealpath":"…","dataUUID":"…","installationDigest":"…"},"oldTarget":{"pid":123,"startSeconds":990,"startMicroseconds":1}}
```

Host admission supplies wall time and remaining duration, capped at 60 seconds and its original work deadline. Guest requires age in `[0,5)` seconds and subtracts that age from remaining duration. Guest records its own current wall time and `systemUptime` and sets both expiries to that reduced duration. It does not compare a host monotonic timestamp with guest uptime. Startup checks both windows and elapsed-clock agreement within two seconds. Wall rollback, uptime rollback, expiration or discontinuity refuses startup. The host must still enforce its original monotonic deadline and boot pin; a fixture receipt does not extend either.

Pending record fields are exactly `{version,restartID,session,oldTarget,identity,issuedUnixSeconds,expiresUnixSeconds,issuedUptime,expiresUptime}`. Identity members above are nested under `identity`. Arm receipt is exactly `{version:1,status:"armed",restartID,pendingSHA256,pending}`. The hash is of exact stored pending bytes (Swift sorted-key JSON), not host JSON reserialization. The pending object is included for readback. Receipt appears under `restartReceipt` in both geometry/edit oracle files and in lifecycle event `restartControl`. The host must require a matching successful receipt before dispatch.

Cancellation control is exactly `{version:1,action:"cancelRestart",restartID,session,pid,issuedUnixSeconds,pendingSHA256}`. Only the old initial lifetime may cancel the exact pending bytes within the same fresh timestamp rule. Receipt is `{version:1,status:"cancelled",restartID,pendingSHA256}`. Cancellation burns the budget and retains pending evidence. Host may request cancellation only before product dispatch. The fixture cannot independently observe dispatch and does not authorize cancellation after uncertain dispatch.

Startup fields in lifecycle `App.init` / `ProbeState.init` and both oracle files are `{startupMode:"initial"|"recordingRestart",restartID:string|null,oldTarget,currentPID}`. Existing lifecycle `pid`, oracle generation/scene, branch control, witness and Text/Shape behavior remain. `graphOracleCalls` stays zero. Neither arm nor cancellation invokes graph/debug APIs or restarts a process.

## Persistence and refusal boundaries

The initial route exclusively creates `.recording-entry-v1` (0700) in the actual data container and `bootstrap.json` (0600) containing `{version:1,session,identity,oldTarget}`. Existing directory means refusal, including incomplete initial writes. There is no reset or overwrite route.

Arming first durably creates `arm.claim`, then exclusively writes `restart.pending.json`. No second arm is allowed, even after an interrupted write. All private reads use nofollow, same UID, regular single-link files, exact modes and size bounds. Writes sync files and directory boundaries. Installation reads are bounded and nofollow and detect size/mtime changes.

Consumption first exclusively creates and syncs `restart.spent`. This fixed tombstone arbitrates competing startup/cancellation. The consumer reads pending bytes and inode, uses `renameatx_np(RENAME_EXCL)` to `restart.consumed.json`, syncs the directory and compares consumed bytes/device/inode. It then validates capsule, claim, record, identity and clocks. Invalid consumption never restores pending or removes the tombstone. A crash after burn, rename or validation cannot grant another attempt. Cancellation shares the same exclusive spent marker.

Entry-shape/inherited-marker/invalid-current-clock failures occur before consumption. Failure to acquire the private directory also occurs before consumption. Native identity resolution failure (including unreadable installed executable/Info.plist) happens before the core is entered. These failures can leave pending intact, but they never refresh/rearm it; the original expiry and host deadline remain binding. Once the spent marker is created, every later failure is permanently burned. Initial reentry always fails on the existing private directory.

## Integration boundaries

No companion source is needed in the existing one-file iOS build. Root must wire host arm/readback/cancel and successor admission in its owned session/observer/UI code. Require exact record hash, old native target, original deadline, device boot, installation/container pins, startup receipt and independently observed new native identity. A PID or startup oracle alone does not qualify a successor. Keep production relaunch argv-free with only recording flag 287 added. Refresh source pins only after review; use fresh preparation for any later authorized runtime. This change does not qualify runtime, authorize a button action, install the app or publish Git changes.
