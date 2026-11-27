# Mac Pilot

Mac desktop automation and iOS Simulator workflows for Codex and Claude Code. This independent repository owns the `mac-computer-use` and `simulator-pilot` packages.

English | [한국어](README.ko.md)

## Install

```sh
codex plugin marketplace add oozoofrog/mac-pilot --ref main
codex plugin add mac-computer-use@mac-pilot
codex plugin add simulator-pilot@mac-pilot
codex plugin list --json
```

For Claude Code:

```text
/plugin marketplace add oozoofrog/mac-pilot
/plugin install mac-computer-use@mac-pilot
/plugin install simulator-pilot@mac-pilot
```

Installing the Plugin alone does not register mac-cu MCP. Follow [installation and migration](docs/installation.md), run setup from the installed **complete package**, grant the relevant macOS permissions and start a fresh agent session. Existing Keychain items, application permissions, captures, profiles and simulator data are preserved.

## Packages

| Package | Version | Scope |
| --- | --- | --- |
| [Mac Computer Use](mac-computer-use/skills/mac-computer-use/SKILL.md) | 1.38.0 | Mac apps, browsers, web views, native simulator screen controls, physical device XCTest UI automation / input and sensor timeline replay |
| [Simulator Pilot](simulator-pilot/skills/simulator-pilot/SKILL.md) | 1.10.1 | Simulator app launch, logs, test data and change verification |

`mac-computer-use`: Operate Mac apps, browser pages, iOS web views, and physical iPhones, iPads and Apple Watch with the mac-cu MCP server. Use for desktop UI tasks without a better API or CLI, web view inspection, XCTest UI automation, input and screenshots on connected iPhones, iPads or paired Apple Watch, or mac-cu setup, modes and simulator preparation. Route iOS Simulator app launch, logs, test data and change verification through simulator-pilot.

`simulator-pilot`: Use for iOS Simulator app launch, logs, screen interaction, test data and change verification. Use mac-computer-use for screen controls; follow the project build instructions for compilation. Excludes Mac desktop/browser/web view tasks and account signup.

The native simulator LCD has an opaque screen, draggable device handle, right and bottom Liquid Glass toolbars and focus mode. [Device controls](mac-computer-use/skills/mac-computer-use/references/device-window.md) keep guest input separate from window movement. OpenAI Decisions judgments use a Keychain-backed API key. Menu-bar Settings shows the actual synthetic connection-check request, validated response, elapsed time and failures without exposing credentials.

The LCD inspector supports explicit accessibility refresh, qualified actions and string editing with restore. **3D 뷰 검사** opens a separate textured UIKit hierarchy with typed hidden/alpha edits and restore. Support is limited to the qualified runtime and debuggable app entries; SwiftUI hosting textures can omit text and shapes. See [inspection and support limits](docs/simulator-inspector.md).

For physical iPhones, iPads and paired Apple Watch, `device` drives foreground apps with the locally signed **MacPilot Runner** over XCTest UI automation (`XCUIApplication`: activation, accessibility snapshots, waits, taps and text entry) and captures one-frame CoreDevice screenshots without starting screen sharing or opening Xcode Device Hub. On portrait iPhones and Apple Watch, `device` also sends CoreDevice HID touches (and iPhone US-layout keys and buttons) without moving the Mac's pointer or using its keyboard. Devices are allowed one at a time by identifier, and input is refused while a passcode is required. See [physical devices](mac-computer-use/skills/mac-computer-use/references/physical-device.md) for verified connections and limits.

Opted-in iOS and watchOS test apps that embed `MacPilotSensorReplay` can receive synchronized microphone PCM, camera frames, motion, location and workout timelines through `sensor_replay` on booted simulators and allowed physical devices (including iPad). See [sensor replay](mac-computer-use/skills/mac-computer-use/references/sensor-replay.md) for setup and verified platform scope.

Use **시뮬레이터 관리…** in the mac-cu menu bar or app menu to prepare runtimes, create compatible devices and start a selected device in the LCD. See [simulator preparation](mac-computer-use/skills/mac-computer-use/references/simulator-preparation.md). Downloads and local DMG imports require an explicit selection in that screen; app builds, installation, launch and logs remain Simulator Pilot workflows.

The manager separates devices, creation and runtimes into task tabs, puts actual state and controls beside the selected device, and preserves creation drafts and readback recovery after failures. The [interactive interface design](docs/design/simulator-manager.html) uses example data and performs no device operations.

## Development and release

Each top-level package is also its marketplace delivery directory; no `plugins/` mirror is needed. Keep manifest-relative resources together.

```sh
python3 scripts/validate_distribution.py
bash scripts/check.sh
python3 scripts/package_release.py --output dist
```

Native checks require a Mac with Xcode. Foreground UI checks run serially on an unlocked desktop. Repository checks, a published catalog, installed/enabled Plugins, fresh-session tool descriptions and verified runtime behavior are separate evidence. See [release procedure](docs/releasing.md) and [native validation evidence](docs/mac-cu-device-window-validation.md).

Project-specific app schemes in Simulator Pilot must be adapted to the target project. Original attribution and the [upstream MIT license](mac-computer-use/skills/mac-computer-use/LICENSE) are retained; see [notices](NOTICE.md).
