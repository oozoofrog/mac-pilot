#!/usr/bin/env python3
"""Build a physical-device runner using local Xcode signing assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


def apply_runner_icon(host, build, watch):
    catalog = build / "Runner.xcassets"
    icon = catalog / "AppIcon.appiconset"
    icon.mkdir(parents=True)
    source = Path(__file__).resolve().parents[2] / "assets/mac-cu-icon.png"
    shutil.copyfile(source, icon / source.name)
    item = {"filename": source.name, "idiom": "universal", "platform": "watchos" if watch else "ios", "size": "1024x1024"}
    info = {"author": "xcode", "version": 1}
    (catalog / "Contents.json").write_text(json.dumps({"info": info}))
    (icon / "Contents.json").write_text(json.dumps({"images": [item], "info": info}))
    plist = host / "Info.plist"
    metadata = plistlib.loads(plist.read_bytes())
    partial = build / "AppIcon.plist"
    subprocess.run(["xcrun", "actool", "--compile", str(host), "--platform", "watchos" if watch else "iphoneos",
                    "--minimum-deployment-target", metadata["MinimumOSVersion"], *(["--target-device", "watch"] if watch else ["--target-device", "iphone", "--target-device", "ipad"]), "--app-icon", "AppIcon", "--output-partial-info-plist",
                    str(partial), str(catalog)], check=True, stdout=sys.stderr)
    metadata.update(plistlib.loads(partial.read_bytes()))
    metadata["CFBundleDisplayName"] = "MacPilot Runner"
    plist.write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY))
    subprocess.run(["codesign", "-d", "--extract-certificates", str(host)], cwd=build, check=True)
    signer = hashlib.sha1((build / "codesign0").read_bytes()).hexdigest()
    subprocess.run(["codesign", "--force", "--sign", signer, "--preserve-metadata=identifier,entitlements,flags,runtime",
                    str(host)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Build root on a volume with space for Xcode outputs")
    parser.add_argument("--team", required=True, help="Apple development team identifier")
    parser.add_argument("--dry-run", action="store_true", help="Show the output root and registration path without building")
    parser.add_argument("--platform", choices=["iOS", "watchOS"], default="iOS", help="Device platform to build and register")
    args = parser.parse_args()
    watch = args.platform == "watchOS"
    root = args.output.expanduser().resolve()
    pointer = Path.home() / "Library/Application Support/mac-cu" / ("watch-xctest.json" if watch else "physical-xctest.json")
    if args.dry_run:
        print(json.dumps({"output": str(root), "registration": str(pointer)}))
        return
    root.mkdir(parents=True, exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix="macpilot-runner-", dir=root))
    project = Path(__file__).resolve().with_name("MacPilot.xcodeproj")
    command = ["xcodebuild", "-project", str(project), "-scheme", "MacPilotRunner", "-configuration", "Debug",
               "-destination", f"generic/platform={args.platform}", "-derivedDataPath", str(build),
               "OBJROOT=" + str(build / "Build/Intermediates.noindex"), "SYMROOT=" + str(build / "Build/Products"),
               "SHARED_PRECOMPS_DIR=" + str(build / "Build/Intermediates.noindex/PrecompiledHeaders"),
               "CLANG_MODULE_CACHE_PATH=" + str(build / "ModuleCache.noindex"),
               "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=" + args.team, "COMPILER_INDEX_STORE_ENABLE=NO"]
    subprocess.run(command + ["build-for-testing"], check=True, stdout=sys.stderr)
    config, = (build / "Build/Products").glob("*.xctestrun")
    target = plistlib.loads(config.read_bytes())["MacPilotRunner"]
    host = Path(target["TestHostPath"].replace("__TESTROOT__", str(config.parent)))
    apply_runner_icon(host, build, watch)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(host)], check=True)
    if plistlib.loads((host / "Info.plist").read_bytes())["CFBundleIdentifier"] != target["TestHostBundleIdentifier"]:
        raise RuntimeError("XCTest host bundle identifier does not match the run configuration")
    if not (host / "embedded.mobileprovision").is_file():
        raise RuntimeError("Physical runner has no embedded provisioning profile")
    pointer.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=pointer.parent, delete=False) as tmp:
        json.dump({"configuration": str(config), "transport": "watch-files-v1" if watch else "usb-socket-v1"}, tmp)
    os.replace(tmp.name, pointer)
    print(json.dumps({"configuration": str(config), "runner": str(host)}))


if __name__ == "__main__":
    main()
