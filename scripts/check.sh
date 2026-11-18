#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/validate_distribution.py
python3 -m unittest discover -s scripts/tests -v
python3 -B mac-computer-use/tests/test_native_build.py
src=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
out="$(mktemp -d "${TMPDIR:-/tmp}/mac-pilot-check.XXXXXX")"
trap 'rm -rf "$out"' EXIT
python3 -B "$(dirname "$src")/native_build.py" -typecheck "$src"/*.swift
python3 -B mac-computer-use/tests/simulator-ax-adapter/run.py
python3 -B mac-computer-use/tests/simulator-ax-inspection/run.py
python3 -B mac-computer-use/tests/simulator-inspector-3d/run.py
python3 -B -m unittest discover -s mac-computer-use/tests/swiftui-hierarchy-probe -p test_graph.py -v
python3 -B -m unittest discover -s mac-computer-use/tests/swiftui-product-backend -v
python3 -B mac-computer-use/tests/swiftui-product-backend/run.py "$out/swiftui-product-backend"
python3 -B mac-computer-use/tests/swiftui-product-backend/run-scheduling.py "$out/swiftui-scheduling"
python3 -B -m unittest discover -s mac-computer-use/tests/swiftui-recording-preparation -v
python3 -B -m unittest discover -s mac-computer-use/tests/simulator-inspector-product-live -v
python3 -B mac-computer-use/tests/swiftui-recording-preparation/run.py "$out/swiftui-recording-preparation"
python3 -B mac-computer-use/tests/swiftui-recording-entry/run.py "$out/swiftui-recording-entry"
python3 -B mac-computer-use/tests/canonical-temporary-path/run.py "$out/canonical-temporary-path"
python3 -B mac-computer-use/tests/simulator-inspection-lifecycle/run.py
python3 -B mac-computer-use/tests/simulator-target-identity/run.py
python3 -B mac-computer-use/tests/simulator-ax-lcd/run.py
python3 -B mac-computer-use/tests/simulator-ax-lcd/run-host.py
python3 -B mac-computer-use/tests/check-view-capture.py
python3 -B mac-computer-use/tests/check-view-edit.py
python3 mac-computer-use/tests/check-simulator-observation.py
swiftc "$src/DecisionService.swift" mac-computer-use/tests/decision-service-selfcheck.swift -o "$out/decision-service"
"$out/decision-service"
swiftc -parse-as-library "$src/DecisionService.swift" "$src/DecisionSettingsWindow.swift" mac-computer-use/tests/native-selfcheck-entry.swift mac-computer-use/tests/decision-settings-selfcheck.swift -o "$out/decision-settings"
python3 mac-computer-use/tests/native_check_support.py --selfcheck "$out/decision-settings" --timeout 30
python3 mac-computer-use/tests/check-decision-answer.py
swiftc -parse-as-library "$src/SimulatorPreparation.swift" mac-computer-use/tests/simulator-preparation-fixtures.swift mac-computer-use/tests/simulator-preparation-selfcheck.swift -o "$out/preparation"
"$out/preparation"
swiftc -parse-as-library "$src/SimulatorPreparation.swift" "$src/SimulatorPreparationWindow.swift" mac-computer-use/tests/native-selfcheck-entry.swift mac-computer-use/tests/simulator-preparation-fixtures.swift mac-computer-use/tests/simulator-preparation-window-selfcheck.swift -o "$out/preparation-window"
python3 mac-computer-use/tests/native_check_support.py --selfcheck "$out/preparation-window" --timeout 30
# Physical device tool, offline: fakes stand in for the device and Device Hub; nothing is sent to a device and no
# window opens. Needs Xcode (CoreDevice) installed. The live check (check-device-live.py) needs a device and stays out.
device="$out/device"
mkdir -p "$device"
(
    export TMPDIR="$device" CLANG_MODULE_CACHE_PATH="$device/cache"
    flags="$(python3 -B "$(dirname "$src")/native_build.py" --emit-stub-modules "$device/modules")"
    hid_link() {
        sed -n '/^final class HIDLink {/,/^var hidLinks:/p' "$src/Simulator.swift" | sed '$d'
        sed -n '/^let usKeys:/,/^\/\/ MARK: - Pasteboard/p' "$src/Simulator.swift" | sed '$d'
    }
    { printf 'import AppKit\nimport IOKit\nimport XPC\n'; hid_link; } > "$device/hid-link.swift"
    swiftc -parse-as-library "$device/hid-link.swift" "$src/SimulatorGestureHID.swift" mac-computer-use/tests/hid-transport-selfcheck.swift -o "$device/hid-transport"
    "$device/hid-transport"
    { sed -n '1,/^@main struct HIDTransportSelfcheck/ p' mac-computer-use/tests/hid-transport-selfcheck.swift | sed '$d'; hid_link; } > "$device/stubs.swift"
    sources=("$device/stubs.swift" "$src/SimulatorGestureHID.swift" "$src/PhysicalDeviceLink.swift" "$src/PhysicalDeviceSession.swift" "$src/Device.swift" "$src/DeviceHubView.swift")
    for check in device-tool device-remote device-hub; do
        swiftc -parse-as-library $flags "${sources[@]}" "mac-computer-use/tests/$check-selfcheck.swift" -o "$device/$check"
        "$device/$check"
    done
    # Without CoreDevice: a copy whose CoreDevice load paths point nowhere still starts (every import is weak).
    cp "$device/device-hub" "$device/no-coredevice"
    for name in CoreDevice CoreDeviceUtilities; do
        old="$(otool -L "$device/no-coredevice" | awk "/\/$name.framework/{print \$1}")"
        install_name_tool -change "$old" "/nonexistent/$name.framework/$name" "$device/no-coredevice" 2>/dev/null
    done
    codesign -f -s - "$device/no-coredevice" 2>/dev/null
    DEVICE_HUB_EXPECT_NO_COREDEVICE=1 "$device/no-coredevice"
    swiftc -parse-as-library $flags "$src/PhysicalDeviceLink.swift" "$src/PhysicalDeviceSession.swift" mac-computer-use/tests/physical-device-link-selfcheck.swift -o "$device/physical-link"
    "$device/physical-link" --missing-runtime
)
python3 -B mac-computer-use/tests/setup-signing-selfcheck.py
swiftc -parse-as-library "$src/SimulatorBudget.swift" mac-computer-use/tests/simulator-budget-selfcheck.swift -o "$out/simulator-budget"
"$out/simulator-budget"
python3 -B mac-computer-use/tests/check-sim-pilot-budget.py "$out/sim-pilot-budget"
bash mac-computer-use/tests/check-simulator-gestures.sh
swiftc -typecheck simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift
git diff --check
