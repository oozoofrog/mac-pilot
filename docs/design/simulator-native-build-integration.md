# Simulator native build integration

The canonical `skills/mac-computer-use/scripts/native_build.py` owns mixed-language compilation. It resolves the adapter relative to itself, so packaged setup resources remain manifest-relative. It never launches, signs, installs, or retains an object in the package/app.

API:

```python
from native_build import run_swift, native_inputs
result = run_swift(['swiftc', *original_flags_and_sources, '-o', str(executable)],
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
```

Add the canonical scripts directory to `sys.path` before importing when outside that directory. `run_swift` forwards subprocess options to both compiler stages. A failing clang returns its result (or raises with `check=True`) before Swift runs. Captured successful clang diagnostics are preserved with Swift diagnostics. Existing log streams receive both stages. Each compiler has the caller's timeout. Temporary objects are removed even on failure.

The adapter compiles with `clang -fobjc-arc -fobjc-exceptions -fobjc-arc-exceptions -fblocks -Wall -Wextra -Werror`. Swift imports `SimulatorAXAdapter.h` and links the object once. Existing `-g`, optimization, SDK and target flags are forwarded where applicable. `-typecheck` imports the header without compiling or linking an object.

Wired callers: setup's whole-source app build, whole-source typecheck in `scripts/check.sh`, observation check, window live check, preparation live check. The latter two now freeze header, implementation, helper, runner and native safety helper hashes alongside Swift hashes. Native dispatch, foreground execution order, signing and watchdog behavior are unchanged. `scripts/check.sh` includes the three headless AX adapter, AX inspection and inspector model runners, and helper unit tests.

## Root integration required

These files belong to another worker and were not edited:

- `tests/check-view-capture.py`: replace only the whole-source `run(['swiftc', *sources, main, '-o', guard])` with `run_swift` using the same subprocess options as `run`. Leave partial view-only compilations alone.
- `tests/view-hierarchy-fixture/prepare.py`: replace the whole-source session probe's `subprocess.run(['swiftc', ...], check=True, timeout=180)` with `run_swift` and identical arguments. Add `*native_inputs(SOURCE)` to both the `unchanged` reuse validation list and final `files` hash input list. Old manifests without these hashes must fail reuse and be rebuilt. Leave the Swift-only guard and fixture build alone.

After the source owners freeze inputs, root must run the full whole-source typecheck/build and required native safety checks. Root owns runtime validation and completion installation. No full host build, GUI, device operation, setup execution or installation was performed by this worker.

## Scoped verification

Evidence directory: `/tmp/mac-cu-build-integration.WgRkoR` (outside Git).

- Tiny temporary Swift client references `SimulatorAXAdapter.self`; typecheck and full compile/link passed. Client was not executed.
- Three helper unit tests passed: typecheck import without object, clang failure short-circuit, temporary link object and subprocess option/diagnostic preservation.
- `python3 -B -m unittest discover -s scripts/tests -v` passed, including native safety tests.
- `python3 -B scripts/validate_distribution.py` passed.
- Changed Python files parsed successfully; shell syntax checked separately.
- `compile.log`, `check-*.log`, final strict compile log and changed input hashes are retained in the evidence directory. No generated binary/object is added to Git or package resources.
