#!/usr/bin/env python3
"""Run the product XCTest operations against a dedicated installed fixture on an already booted test phone simulator."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    booted = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"]))["devices"]
    if not any(d["udid"] == args.udid for devices in booted.values() for d in devices):
        parser.error("Select an already booted test simulator")
    tests = Path(__file__).resolve().parent
    project = root / "project"
    shutil.copytree(tests.parents[1] / "skills/mac-computer-use/scripts/physical-xctest", project)
    shared = root / "mac-cu-src"
    shared.mkdir()
    shutil.copyfile(tests.parents[1] / "skills/mac-computer-use/scripts/mac-cu-src/XCTestSocket.swift", shared / "XCTestSocket.swift")
    with (project / "Tests/Runner.swift").open("a") as target:
        target.write("\n" + (tests / "Acceptance.swift").read_text())
    app = root / "Fixture.app"
    app.mkdir()
    bundle = "org.macpilot.fixture.xctest"
    plist = dict(CFBundleIdentifier=bundle, CFBundleExecutable="Fixture", CFBundleName="Fixture",
                 CFBundleVersion="1", CFBundleShortVersionString="1.0", CFBundlePackageType="APPL",
                 MinimumOSVersion="17.0", LSRequiresIPhoneOS=True, UILaunchScreen={})
    (app / "Info.plist").write_bytes(plistlib.dumps(plist))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    run("xcrun", "swiftc", "-parse-as-library", "-target", os.uname().machine + "-apple-ios17.0-simulator",
        "-sdk", sdk, str(tests / "Fixture.swift"), "-o", str(app / "Fixture"))
    run("codesign", "--sign", "-", str(app))
    existing = subprocess.run(["xcrun", "simctl", "get_app_container", args.udid, bundle],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if existing.returncode == 0:
        parser.error("Fixture bundle already exists on this simulator")
    run("xcrun", "simctl", "install", args.udid, str(app))
    try:
        run("xcodebuild", "test", "-project", str(project / "MacPilot.xcodeproj"), "-scheme", "MacPilotRunner",
            "-destination", "platform=iOS Simulator,id=" + args.udid, "-derivedDataPath", str(root / "DerivedData"),
            "OBJROOT=" + str(root / "Intermediates"), "SYMROOT=" + str(root / "Products"),
            "-parallel-testing-enabled", "NO", "-only-testing:MacPilotRunner/MacPilotTests/testSimulatorAcceptance",
            "-only-testing:MacPilotRunner/MacPilotTests/testSocketSession",
            "-resultBundlePath", str(root / "acceptance.xcresult"))
    finally:
        run("xcrun", "simctl", "uninstall", args.udid, bundle)


if __name__ == "__main__":
    main()
