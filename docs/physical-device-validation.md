# Physical device validation

Test device: iPhone 14 Pro, iOS 27.2, on macOS 27.2 with Xcode 27.2 (CoreDevice 651.31). Device names and
identifiers are not recorded here. User-facing behavior and limits are in
[physical-device.md](../mac-computer-use/skills/mac-computer-use/references/physical-device.md).

## Apple Watch direct access (2026-11-21)

On Xcode 27.2, a paired physical Apple Watch Series 11 running watchOS 27.2 appeared with its own CoreDevice identifier and network transport. With the tunnel up, the watch advertised screenshot, display, lock-state and HID digitizer services. Its primary display reported 416 × 496 pixels at scale 2 and rotation `rot0`. The response omitted device orientation.

The guarded device harness selected the watch, refused a different identifier, released the watch and refused capture after release. A production-code capture returned a 208 × 248 JPEG. A tap received a digitizer barrier reply. The watch reported its backlight was off, and the subsequent capture still showed a black screen. This run did not establish a visible tap or swipe effect. The installed MCP listed and allowed the watch and refused its keyboard and USB XCTest commands. A later display request timed out. A direct Xcode display query also timed out after 45 seconds.

After the owner woke the watch, Xcode reported `activeOn` and `passcodeRequired: false`. The first capture timed out. Once the network connection was available, the installed mac-cu MCP returned a 208 × 248 image of the app grid. A tap at (104, 52) opened Settings. A swipe from (103, 207) to (103, 73) moved the list from Notifications and Smart Stack to General, Focus and Airplane Mode. The reverse swipe returned the list to the top. A separate screenshot confirmed each transition. The client then released the watch.

### Signed watchOS XCTest runner

The paired watch ran the development-signed watchOS test bundle on Xcode 27.2. The runner returned an authenticated pong, activated Calculator, read its XCTest accessibility snapshot, found a calculator button by its exact label and exited cleanly. The calculator's digit buttons had labels and empty identifiers. A device file transfer initially lost its completion acknowledgement because the runner removed the request before CoreDevice finished inspecting it. Keeping the current request until the next authenticated command allowed consecutive commands to complete.

## iPhone status (2026-11-14)

| Area | Status |
| --- | --- |
| USB connection | Verified (below) |
| Network connection | Verified in part on 2026-11-14 (below); Wi-Fi drop and recovery not checked |
| `list`, `allow`, `release`, `screenshot` | Verified |
| `tap`, `swipe`, folder first tap | Verified |
| `button` home, volumeUp, volumeDown | Verified |
| `type` digits, `key` delete | Verified |
| `type` letters | Only with a Korean hardware keyboard layout, where US key codes give other characters (`h` → `ㅗ`); not verified with a US layout |
| `view` (Device Hub already running, `focus` false) | Verified |
| Mac non-interference around input | Verified for the steps below |
| Lock/side button, landscape refusal, input refusal on a locked device, cancellation, `view` with `focus: true` or with Device Hub not running | Not verified on a device |

mac-cu has no window of its own for a physical device's screen. An earlier LCD window for physical devices was built,
measured and removed; its results are kept under "Earlier rounds" as history only.

## 2026-11-14 USB round

USB, tunnel connected, paired, device unlocked. Each step ran the production tool code in a fresh process under
`check-device-live.py` (parent watchdog, one executable instance). The test copy of `Device.swift` only recorded the
Mac's cursor position, front app and its PID right before the first and right after the last HID send; nothing was
posted to the Mac and no Mac screenshot was taken. A device screenshot was inspected before each tap.

| Step | Result |
| --- | --- |
| `list`, `allow`, `screenshot` | Pass: Connected over USB, unlocked. Screenshots took 0.95–0.98 s per call (portrait 393×852 points). |
| `button home` on the button feature | Fail before the fix: 3 of 3 presses ignored although the barrier was answered (343, 293, 56 ms; one held 0.3 s). |
| `button home` on the digitizer feature (current code) | Pass: 12 of 12 presses took effect (from an app, from Spotlight 5 times, from Photos, closing a folder 3 times). |
| `button volumeUp`, `volumeDown` (earlier the same day) | Pass: the volume HUD appeared, one step each. Barrier answered in 912 ms (first use of the button connection) and 117 ms. |
| `swipe` | Pass: 8 of 8 took effect; barrier answered in 2–27 ms. |
| `tap` with the connection closed right after the barrier | Fail: 3 of 3 taps on the Search pill ignored (barrier 7–122 ms). |
| `tap` with the connection held 500 ms after an answered barrier (current code) | Pass: 6 of 6. |
| Folder first tap | Pass: 3 of 3 rounds opened the Utilities folder on the single tap; Home closed it each round. |
| `type hello`, then 5 × `key delete` | The device's hardware keyboard layout was Korean, so `h` arrived as `ㅗ`. In this round Photos came to the front after Spotlight was opened (cause not found), and the five deletes went to Photos (no visible change there). |
| `type 12345`, then 5 × `key delete`, 5 rounds | Pass: 25 of 25 characters and 25 of 25 deletes took effect; field empty after each round; no dropped or repeated key. |
| `view` × 4 (`focus` false) | Device Hub opened at the device without coming to the front; a 0.1 s sampler of the front app saw no change during two of the steps. The device's screen was already streaming in Device Hub (View Screen clicked) for the whole round. |
| `screenshot`, `tap` with Device Hub streaming | Pass; tap barrier answered in 139 ms. |
| Mac non-interference | 68 of 68 input steps: cursor, front app and PID identical right before the first and after the last HID send. Whole steps (including process start): 118 of 120 identical; the 2 differences were in `view` steps while the user was using the Mac. |

The fixes in this round are in the current code: Home goes out on the digitizer feature, other buttons on the button
feature, and the input connection is kept 500 ms after an answered barrier without delaying the result.

## Earlier rounds

**2026-11-13, USB.** The first read-only run returned the device as Connected over USB and a 393×852 screenshot in
1.5 s; the audit allowed the explicit identifier, refused a random one, released, and refused the original after
release. With a 500 ms hold after the last event (before the barrier existed), taps opened Clock and Settings, left
and right swipes changed and restored the Home Screen page, a downward swipe opened Spotlight, `type test` appeared
and four deletes cleared it, and ten more alternating page swipes ended on the original page. Cursor, front app and
PID were identical before the first and after the last send for all 23 recorded actions.

**2026-11-14, physical-device LCD window (removed).** A mac-cu window that showed the device screen from repeated
CoreDevice screenshots, with a USB capture variant, was measured: about 1.6–1.8 frames per second, median
request-to-display about 560–590 ms, about 7 MB per wide-color frame and about 14.6 MB/s on the tunnel while open.
The window and its tests were removed in favor of Xcode's Device Hub. In-process CoreDevice calls kept from that work:
screenshot median 528–643 ms within one process, lock state about 33 ms, display information 6–8 ms, and a usage
assertion (which raises the tunnel for a network device) in 43 ms over USB.

**2026-11-14, Device Hub first run.** The production launcher opened a 296×620 Device Hub window for the device;
the front app and cursor did not change. The device was unpaired at that time, so the window showed Pair and the tool
refused `allow`; pairing was not attempted. The round above was run after the device was paired again.

**2026-11-14, button feature and barrier.** Buttons moved to the button feature and the fixed 500 ms wait after the
last event was replaced by CoreDevice's barrier (a message holding only `isBarrier: true`, sent with a reply; see
[device-hub-connection-analysis.md](design/device-hub-connection-analysis.md) section 4). Every simulator HID message
was recorded before and after the transport change and compared byte for byte (24 messages identical with
`SWIFT_DETERMINISTIC_HASHING=1`). After the volume presses the device locked itself and later disconnected; the
remaining steps were run in the round above.

## Reproduce

Run from the repository root with one device, chosen by its identifier after checking the inventory entry. Screenshots
and the harness log can contain personal information: keep them in the build directory and remove it afterwards.
The harness accepts only `--live` with JSON, rejects inherited entry and other arguments, does not create
`NSApplication`, and reads but never posts Mac events.

```sh
eyebuild dir device-live-check
D=/Volumes/eyedisk/build/mac-pilot/device-live-check
S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache" PYTHONDONTWRITEBYTECODE=1
{ sed -n '1,/^@main struct HIDTransportSelfcheck/ p' mac-computer-use/tests/hid-transport-selfcheck.swift | sed '$d'; sed -n '/^final class HIDLink {/,/^var hidLinks:/p' "$S/Simulator.swift" | sed '$d'; sed -n '/^let usKeys:/,/^\/\/ MARK: - Pasteboard/p' "$S/Simulator.swift" | sed '$d'; sed -n '/^struct ShellResult /,/^struct SimulatorScreen /p' "$S/Simulator.swift" | sed '$d'; sed -n '/^func jpegBase64(/,/^func point(/p' "$S/Simulator.swift" | sed '$d' | sed 's/, guides: \[GuideBox\]? = nil//' | sed 's/let picture = guides.map.*$/let picture = scaled/' | sed 's/guides == nil ? 0.7 : 0.8/0.7/'; } > "$D/stubs.swift"
sed 's/remote.send(message)/observedSend(remote, message)/' "$S/Device.swift" > "$D/Device.swift"
FLAGS=$(python3 mac-computer-use/skills/mac-computer-use/scripts/native_build.py --emit-stub-modules "$D/modules")  # bash; zsh: ${=FLAGS}
swiftc -parse-as-library $FLAGS "$D/stubs.swift" "$S/SimulatorGestureHID.swift" "$S/PhysicalDeviceLink.swift" "$S/PhysicalDeviceSession.swift" "$D/Device.swift" "$S/DeviceHubView.swift" mac-computer-use/tests/device-live-harness.swift -o "$D/device-live-harness"
ID=<identifier from device list>
python3 mac-computer-use/tests/check-device-live.py --device "$ID" --build-dir "$D" --action audit
python3 mac-computer-use/tests/check-device-live.py --device "$ID" --build-dir "$D" --action screenshot --image "$D/start.jpg"
eyebuild rm device-live-check
```

`check-device-live.py` also accepts `list`, `allow`, `release`, `tap`, `swipe`, `button`, `key`, `type` and `view`
with `--args '<JSON>'`. The offline checks of the same code run in `scripts/check.sh`.

## Network run, 2026-11-14

Same phone with the cable removed (transport `localNetwork`, tunnel connected). The phone's owner was also using it
by hand during the run, so some steps could not be judged and were not repeated.

| Check | Result |
| --- | --- |
| `list` shows the network transport; `allow`; `screenshot` | Passed; first screenshot of a process 2.7 s, later about 1.9–2.1 s (USB: about 1 s) |
| Home | 2 of 2 |
| Swipe | 5 of 5 |
| Tap (Search button) | 2 of 2, each on the first try |
| Digit entry and delete | Entry 2 of 2 rounds (5 of 5 characters), delete 5 of 5 in one round |
| Volume up and down | 3 of 3 |
| `release`, then `allow` again | Screenshot refused after release; first input after re-allow took effect |
| First input of a new process | 14 of 14 took effect on the first try |
| `view` | Opened the device page in Device Hub without changing the Mac's front app |
| Barrier answer, median | button 72 ms, tap 55 ms, swipe 24 ms, key 12 ms |

Not checked over the network: folder first tap, raising a tunnel that was down, a Wi-Fi drop and recovery, a locked
phone, landscape. The Mac's front app was unchanged across all 26 input steps.

