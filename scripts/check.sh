#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/validate_distribution.py
python3 -m unittest discover -s scripts/tests -v
src=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
out="$(mktemp -d "${TMPDIR:-/tmp}/mac-pilot-check.XXXXXX")"
trap 'rm -rf "$out"' EXIT
swiftc -typecheck "$src"/*.swift
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
bash mac-computer-use/tests/check-simulator-gestures.sh
swiftc -typecheck simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift
git diff --check
