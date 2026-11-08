#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/validate_distribution.py
python3 -m unittest discover -s scripts/tests -v
src=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
out="$(mktemp -d "${TMPDIR:-/tmp}/mac-pilot-check.XXXXXX")"
trap 'rm -rf "$out"' EXIT
swiftc -typecheck "$src"/*.swift
swiftc "$src/DecisionService.swift" mac-computer-use/tests/decision-service-selfcheck.swift -o "$out/decision-service"
"$out/decision-service"
swiftc -parse-as-library "$src/DecisionService.swift" "$src/DecisionSettingsWindow.swift" mac-computer-use/tests/decision-settings-selfcheck.swift -o "$out/decision-settings"
"$out/decision-settings"
python3 mac-computer-use/tests/check-decision-answer.py
bash mac-computer-use/tests/check-simulator-gestures.sh
swiftc -typecheck simulator-pilot/skills/simulator-pilot/tool/sim-pilot.swift
git diff --check
