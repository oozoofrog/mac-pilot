#!/bin/bash
set -euo pipefail
if [[ $# != 1 || "$1" != /* || -e "$1" ]]; then
  echo "usage: $0 /absolute/nonexistent-output-directory" >&2
  exit 64
fi
out="$1"
mkdir -m 700 "$out"
app="$out/AXLiveFixture.app"
mkdir "$app"
src="$(cd "$(dirname "$0")" && pwd)"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
  -sdk "$sdk" "$src/main.swift" "$src/entry.swift" -o "$app/AXLiveFixture"
cp "$src/Info.plist" "$app/Info.plist"
cat > "$out/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
EOF
codesign --force --sign - --entitlements "$out/entitlements.plist" "$app"
codesign --verify --strict "$app"
shasum -a 256 "$src/main.swift" "$src/entry.swift" "$src/Info.plist" "$app/AXLiveFixture" > "$out/source-hashes.txt"
echo "Built $app (not installed or launched)"
