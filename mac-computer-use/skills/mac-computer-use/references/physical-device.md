# Physical iPhone, iPad and Apple Watch

The `device` tool operates physical iPhones, iPads and paired Apple Watches connected to this Mac. App UI automation
uses the locally signed **MacPilot Runner** over XCTest (`XCUIApplication`: `xctestStart` through `xctestStop`), and
`screenshot` captures one still frame over CoreDevice without starting a live screen-sharing stream. Neither
Accessibility nor Screen Recording permission is needed on the Mac, and the Mac's pointer, keyboard and front window
are never touched.

`mac-cu` never opens or uses Xcode's Device Hub. Live Device Hub screen sharing (`avconferenced`) sets
`UIScreen.isCaptured` on iOS/iPadOS and blanks physical hardware camera buffers (`Y=0, UV=128`); keeping physical
device workflows on XCTest UI automation and one-frame CoreDevice screenshots preserves live hardware camera input.

Simulators use the `simulator` tool (and `simulator-pilot` for app launch, logs and test data); web views on a USB
device use `webinspector`.

## Signed XCTest runner (`XCUIAutomation`) for iPhone, iPad and Apple Watch

Use a paired, unlocked device with Developer Mode enabled. On the first UI test after a reboot, iOS/iPadOS shows an
**Enable UI Automation** prompt on the device requiring Touch ID, Face ID or passcode (or enable **Settings >
Developer > Enable UI Automation**). Connect an iPhone or iPad over USB, or select the paired
Apple Watch in Xcode. Use Xcode and a local development signing identity with a provisioning profile valid for the
device. From the skill directory, prepare the runner once and keep the output directory available for later sessions:

```sh
python3 scripts/physical-xctest/prepare.py --platform iOS --output "/path/to/build" --team "$DEVELOPMENT_TEAM"
```

For Apple Watch, pass `--platform watchOS`. Each platform has its own registration (`physical-xctest.json` for iOS and
iPadOS universal `TARGETED_DEVICE_FAMILY = "1,2"`, and `watch-xctest.json` for watchOS). iPhone and iPad use an
authenticated USB loopback socket over `usbmuxd` and work in both portrait and landscape orientations. Apple Watch
exchanges authenticated commands in the runner's data container over the paired CoreDevice file service. Each command
checks the lock state through CoreDevice.

Preparation builds **MacPilot Runner** locally with the MacPilot icon. The first `xctestStart` uses `xcodebuild
test-without-building` to install and launch the runner on the selected device. Rebuild after changing Xcode, adding a
new physical device to your team provisioning profile, or updating the runner.

Use the same MCP connection for these `device` calls. Replace `DEVICE_UUID` with the CoreDevice identifier from
`device list`, and poll `xctestStatus` until it returns `ready`:

```jsonl
{"action":"allow","device":"DEVICE_UUID"}
{"action":"xctestStart","device":"DEVICE_UUID","app":"BUNDLE_ID"}
{"action":"xctestStatus","device":"DEVICE_UUID"}
{"action":"xctestActivate","device":"DEVICE_UUID"}
{"action":"xctestDescribe","device":"DEVICE_UUID"}
{"action":"xctestStop","device":"DEVICE_UUID"}
{"action":"release"}
```

 Omit `app` in `xctestStart` for transport checks (`xctestPing`). Only `xctestActivate` explicitly launches or brings
that app to the foreground. `xctestDescribe` returns a bounded accessibility tree (`depth`, `type`, `identifier`,
`label`, `enabled`, `value`). Pass an exact accessibility identifier in `target` or an exact accessibility label in
`label` for `xctestWait`, `xctestTap` or `xctestType`. `xctestWait` accepts `seconds` from `0` to `10`. `xctestTap`
requires one hittable match. `xctestType` accepts `text` up to 200 characters in one plain text field. After input,
check the effect with `xctestWait`, `xctestDescribe` or `screenshot`. Stop the session if delivery is uncertain. A
runner expires after 120 seconds without commands or 15 minutes in total.

## Platform scope

- **Physical iPad:** `list`, `allow`, `release`, `screenshot` (portrait and landscape), signed USB XCTest UI
  automation (`xctestStart`…`xctestStop`), and [sensor replay](sensor-replay.md). Raw CoreDevice HID coordinate/key/button
  actions are refused on iPad; use XCTest element actions instead.
- **Physical iPhone:** `list`, `allow`, `release`, signed USB XCTest UI automation (`xctestStart`…`xctestStop`),
  [sensor replay](sensor-replay.md), and portrait `screenshot` plus CoreDevice HID `tap`, `swipe`, `key`, `type` and
  `button` (USB or paired same-network Wi-Fi).
- **Physical Apple Watch:** `list`, `allow`, `release`, signed watchOS XCTest UI automation
  (`xctestStart`…`xctestStop`), [sensor replay](sensor-replay.md), and `screenshot`, `tap` or `swipe` in the returned
  image's point coordinates. Wake the watch if a capture is black. Hardware keyboard, iPhone buttons and Digital Crown
  HID are unavailable on Watch.

## Actions

| Action | Parameters | What it does |
| --- | --- | --- |
| `list` | | Physical iPhones, iPads and Apple Watches known to Xcode, with connection state, transport (USB or network), OS and whether allowed. Adds a line when the faster in-process CoreDevice path is off. |
| `allow` | `device` | Allows the device (UUID only, never name) for this mac-cu connection. Allowing another device ends the previous session. |
| `release` | | Withdraws the permission and ends any active device or XCTest session owned by this connection. |
| `screenshot` | `device` | One still JPEG frame over CoreDevice (portrait or landscape on iPad; portrait on iPhone; upright on Watch). Allowed while locked. |
| `xctestStart` | `device`, `app`? | Starts the prepared signed XCTest runner on the allowed USB iPhone/iPad or paired Apple Watch. |
| `xctestStatus` | `device` | Returns `starting` or `ready` after verifying the runner's authenticated handshake. |
| `xctestPing` | `device` | Authenticated round-trip check without touching any target app. |
| `xctestActivate` | `device` | Launches or brings the bound `app` to the foreground. |
| `xctestDescribe` | `device` | Bounded accessibility snapshot of the foreground target app. |
| `xctestWait` | `device`, `target` \| `label`, `seconds`? | Waits up to `seconds` (0–10, default 3) for a matching element. |
| `xctestTap` | `device`, `target` \| `label` | Taps the unique hittable matching element via `XCUIElement.tap()`. |
| `xctestType` | `device`, `target` \| `label`, `text` | Focuses the unique plain text field and types up to 200 characters via `XCUIElement.typeText(_:)`. |
| `xctestStop` | `device` | Stops the XCTest session and waits for runner exit. |
| `tap` | `device`, `x`, `y`, `seconds`? | Portrait iPhone / Watch CoreDevice HID touch, held `seconds` (0.02–10, default 0.05). |
| `swipe` | `device`, `x`, `y`, `to_x`, `to_y`, `seconds`? | Portrait iPhone / Watch CoreDevice HID drag over `seconds` (default 0.3). |
| `key` | `device`, `key` | Portrait iPhone US-layout HID key or chord (`return`, `delete`, `tab`, `space`, `escape`, arrows, `cmd+a`, …). |
| `type` | `device`, `text` | Portrait iPhone US-layout HID keys, up to 200 characters per call. |
| `button` | `device`, `button`, `seconds`? | Portrait iPhone `home`, `lock` (`side`), `volumeUp`, `volumeDown`. |

## Refusals and CoreDevice notes

- A device that is not allowed, or a name instead of an identifier, is refused.
- Input and XCTest commands are refused while the device requires a passcode. Unlock the device yourself; `mac-cu`
  never enters a passcode.
- Coordinate HID on iPhone requires portrait orientation; `key` and `type` send US-layout HID key codes (for non-US
  text or landscape apps, use `xctestType`).
- `mac-cu` links CoreDevice weakly and checks its symbols and protocol types once per process. When Xcode differs or is
  absent, screenshots and lock checks fall back to `devicectl` (slower) and `list` says why.
