# Native check execution safety

These instructions apply to this repository's desktop test apps and persistent previews. Their purpose is to keep a test failure from multiplying applications, stealing focus or leaving background test processes on the user's desktop.

## Before opening a GUI

1. Inspect every path that executes the current binary: permission probes, approval dialogs, guides, daemon/client startup and relaunch. A changed test entry point must retain the helper routes it uses. Do not truncate `main.swift` and unconditionally enter the test in every child invocation.
2. Use `mac-computer-use/tests/native_check_support.py` to generate isolated dispatch. The root test requires `--native-check`; a child inherits a marker that rejects re-entry into that route before AppKit starts. The `--check-screen-recording` helper keeps its production dispatch. Unrecognized arguments and normal daemon/client/update/guide routes are rejected in the test executable.
   Independent window selfchecks use `native-selfcheck-entry.swift` and the support script's `--selfcheck` launcher; they reject all helper routes because they do not implement production helpers.
3. Run the generated app's helper, rejected arguments and inherited root entry under the parent watchdog before the GUI test. The helper must finish within its deadline without opening the test window. Rejected routes must exit 64. Passing type checks or using a different bundle ID does not establish these properties.
4. Keep app bundles, outputs and source hashes in a unique local directory. Never replace the installed daemon, invoke setup, register a global socket, copy Keychain keys or modify Plugin caches to run a development check.

## During a check

- Run one foreground check at a time on an unlocked, awake desktop. Keep the existing input/focus checks. If the app loses focus, stop input rather than activating repeatedly or relaxing the checks.
- Use a parent process watchdog; an in-app timer cannot protect a blocked main thread or a recursively launched copy. Declare a wall-clock deadline and exact executable instance budget before launch. The current runners allow one root and one short-lived permission helper. A deadline breach, third instance, unexpected exit or interruption must fail the run and clean its owned processes.
- Identify processes by the resolved executable path within that run's unique output directory, plus the process group the launcher created. Freeze matching app instances before killing them so they cannot continue spawning while cleanup proceeds. Never use broad names such as `Simulator`, `mac-cu`, `python` or `Check`, terminate the installed app, or reset Dock state.
- Persistent preview windows still need a parent watchdog, singleton enforcement and a finite lifetime. A successful `open` command is not permission to leave an unmonitored app running indefinitely.
- Simulator inventory reads are separate from device mutations. Claim a selected device for interaction and preserve other sessions' devices. Downloads, new device creation or booting are not substitutes for mock failure/cancellation checks.

## If duplicate icons/windows or relaunch occurs

Stop the check immediately, freeze/terminate only the owned test executable instances and clean the launcher's process group. Verify the remaining instance count is zero. Retain logs, source hashes and failure evidence; do not rerun the GUI to diagnose an unbounded spawn path. Trace its arguments and parent chain first, fix dispatch and prove the non-GUI guards, then do one bounded run.

Report the actual failure and cleanup to the user. Do not report the failed live check as passed because an earlier mock test succeeded. Record which live actions were never exercised.

## Completion installation for user verification

The user has given standing authorization to replace the global mac-cu app after completed implementation work. Finish isolated checks first, then perform the local delivery step using the canonical setup build/signing path. Back up the previous app, retain the existing bundle/signing identity and user state, gracefully restart the daemon, and read back the installed/running version and user-facing entry point. Do not ask for the same installation authorization again. This does not authorize Git pushes or marketplace publication, and it does not permit replacing the global app merely to run an unvalidated development check.

## Regression basis

Run `python3 -m unittest discover -s scripts/tests -p test_native_check_safety.py -v` before GUI work. Its fixtures are command-line executables without AppKit, use a fixed fan-out rather than recursive spawning, and check helper/unknown/inherited entry, instance budget, timeout, interruption, orphan cleanup and unrelated process survival. The full repository check includes these tests.

The preparation-manager harness once removed all production executable dispatch. Its menu asked the executable to run `--check-screen-recording`; the child re-entered the GUI test, which checked the permission again. This formed a linear chain of app instances and Dock icons. The shared dispatch generator, inherited-entry guard and independent watchdog protect separate failure points in that chain. Both the manager check and existing LCD runner must use them.
