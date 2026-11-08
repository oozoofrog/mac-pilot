#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source="$here/../skills/mac-computer-use/scripts/mac-cu-src"
out="$(mktemp -d "${TMPDIR:-/tmp}/mac-cu-gesture-check.XXXXXX")"
trap 'rm -rf "$out"' EXIT
swiftc "$source/SimulatorGestures.swift" "$here/simulator-gestures-selfcheck.swift" -o "$out/timeline"
"$out/timeline"
swiftc -parse-as-library "$source/SimulatorGestureHID.swift" "$here/gesture-hid-selfcheck.swift" -o "$out/hid"
"$out/hid"
swiftc -parse-as-library "$source/SimulatorTouchOverlay.swift" "$here/simulator-touch-overlay-selfcheck.swift" -o "$out/overlay"
"$out/overlay"
swiftc -parse-as-library "$source/SimulatorPreviewLayout.swift" "$here/simulator-preview-layout-selfcheck.swift" -o "$out/layout"
"$out/layout"
swiftc -parse-as-library "$source/SimulatorRotation.swift" "$here/simulator-rotation-selfcheck.swift" -o "$out/rotation"
swiftc -parse-as-library "$source/SimulatorPreparation.swift" "$here/simulator-preparation-fixtures.swift" "$source/SimulatorRotation.swift" "$source/SimulatorObservation.swift" "$here/simulator-observation-selfcheck.swift" -o "$out/observation"
"$out/observation"
"$out/rotation"
swiftc -parse-as-library "$source/SimulatorPreparation.swift" "$here/simulator-preparation-fixtures.swift" "$source/SimulatorDisplayState.swift" "$here/simulator-display-state-selfcheck.swift" -o "$out/display-state"
"$out/display-state"
swiftc -parse-as-library "$source/SimulatorKeyboardState.swift" "$here/simulator-keyboard-state-selfcheck.swift" -o "$out/keyboard-state"
"$out/keyboard-state"
swiftc -parse-as-library "$source/SimulatorHingeSlider.swift" "$here/native-selfcheck-entry.swift" "$here/simulator-hinge-slider-selfcheck.swift" -o "$out/hinge"
python3 "$here/native_check_support.py" --selfcheck "$out/hinge" --timeout 30
swiftc -parse-as-library "$source/SimulatorHostActions.swift" "$here/native-selfcheck-entry.swift" "$here/simulator-host-actions-selfcheck.swift" -o "$out/host-actions"
python3 "$here/native_check_support.py" --selfcheck "$out/host-actions" --timeout 30
chrome=("$source/SimulatorRotation.swift" "$source/SimulatorHingeSlider.swift" "$source/SimulatorDeviceContainer.swift" "$source/SimulatorLCDContent.swift" "$source/SimulatorDeviceChrome.swift" "$source/SimulatorGesturePad.swift" "$source/SimulatorToolbox.swift" "$source/SimulatorToolbarDocking.swift")
swiftc -parse-as-library "${chrome[@]}" "$here/native-selfcheck-entry.swift" "$here/simulator-toolbox-selfcheck.swift" -o "$out/toolbox"
python3 "$here/native_check_support.py" --selfcheck "$out/toolbox" --timeout 60
swiftc -parse-as-library "${chrome[@]}" "$here/native-selfcheck-entry.swift" "$here/simulator-device-chrome-selfcheck.swift" -o "$out/chrome"
python3 "$here/native_check_support.py" --selfcheck "$out/chrome" --timeout 60
swiftc -parse-as-library "${chrome[@]}" "$here/native-selfcheck-entry.swift" "$here/simulator-toolbar-interaction-selfcheck.swift" -o "$out/interaction"
python3 "$here/native_check_support.py" --selfcheck "$out/interaction" --timeout 30
swiftc -parse-as-library "${chrome[@]}" "$here/native-selfcheck-entry.swift" "$here/simulator-window-move-selfcheck.swift" -o "$out/window-move"
python3 "$here/native_check_support.py" --selfcheck "$out/window-move" --timeout 30
swiftc -parse-as-library "${chrome[@]}" "$here/native-selfcheck-entry.swift" "$here/simulator-toolbar-docking-selfcheck.swift" -o "$out/docking"
python3 "$here/native_check_support.py" --selfcheck "$out/docking" --timeout 60
swiftc -parse-as-library "$source/SimulatorPreviewLayout.swift" "$source/SimulatorWindowPresentation.swift" "$here/native-selfcheck-entry.swift" "$here/simulator-window-presentation-selfcheck.swift" -o "$out/windows"
python3 "$here/native_check_support.py" --selfcheck "$out/windows" --timeout 30
swiftc -parse-as-library "$source/SimulatorWindowOcclusion.swift" "$here/simulator-window-occlusion-selfcheck.swift" -o "$out/occlusion"
"$out/occlusion"
python3 "$here/gesture-probe/check_trace.py" --self-test
node "$here/gesture-probe/playground-selfcheck.mjs"
python3 "$here/setup-icon-selfcheck.py"
