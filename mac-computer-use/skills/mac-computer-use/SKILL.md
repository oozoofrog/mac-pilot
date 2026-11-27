---
name: mac-computer-use
description: Operate Mac apps, browser pages, iOS web views, and physical iPhones, iPads and Apple Watch with the mac-cu MCP server. Use for desktop UI tasks without a better API or CLI, web view inspection, XCTest UI automation, input and screenshots on connected iPhones, iPads or paired Apple Watch, or mac-cu setup, modes and simulator preparation. Route iOS Simulator app launch, logs, test data and change verification through simulator-pilot.
---

# Mac Computer Use for Claude Code and Codex

`mac-cu` (`scripts/mac-cu-src`) is an MCP server in this skill. It needs no other app.

- Apps: it reads the front window of an app as a numbered accessibility tree and operates it with
  the accessibility API and input events sent to the app's process, so the app stays in the
  background. Mouse events name the target window and the point in it: the user's pointer does not
  move, and background windows (also Chrome) take clicks and drags.
- Web pages: it runs JavaScript in a tab, through Apple Events in the user's own browser, through the
  mac-cu Chrome extension in the user's own Chrome (as Claude in Chrome does), or through the Chrome
  DevTools Protocol in a separate Chrome.
- iOS Simulator: it reads the front app of a booted simulator as an accessibility tree, and sends
  touches, keys and buttons as HID events, so the Simulator window can stay in the background or be
  closed. It needs no other tool (no AXe or idb).
- iOS web views: it connects to the Web Inspector of booted simulators and USB devices without
  Safari, and inspects WKWebView and Safari pages.
- Physical iPhones, iPads and Apple Watch: select a device UUID with `device allow`, then operate
  apps through the locally signed MacPilot Runner over XCTest (`XCUIApplication`: `xctestStart`
  through `xctestStop`) on USB iPhones, USB iPads and paired Apple Watch, and capture one-frame
  screenshots (`screenshot`) without starting screen sharing or opening Xcode Device Hub. On
  portrait iPhones and Apple Watch, coordinate touches (and iPhone US-layout keys and buttons) also
  go over CoreDevice HID without touching the Mac's pointer or keyboard. Connected devices can also
  receive `sensor_replay` fixtures. See [physical device](references/physical-device.md).

## 1. Setup check

- If the mac-cu tools `get_app_state`, `act`, `browser`, `simulator`, `webinspector`, `device`, `sensor_replay` and `decide` are available, go to step 2. Claude Code
  names them `mcp__mac-cu__*`; Codex can show them as `mcp__mac_cu__*`.
- If not, run the setup script. Replace `<SKILL_DIR>` with the folder that holds this SKILL.md, and
  `<AGENT>` with the agent that runs you: `claude` (Claude Code) or `codex` (Codex):

  ```bash
  python3 "<SKILL_DIR>/scripts/setup.py" --agent <AGENT>
  ```

  It builds `mac-cu.app` (in `~/Library/Application Support/mac-cu`, signed with the user's Apple
  Development identity when there is one) and the focus glow with `swiftc`, and registers `mac-cu` in
  that agent. For Claude Code it also checks that the server connects and adds the focus glow hooks.
  In Codex, the script writes `~/.codex/config.toml`: if the sandbox blocks it, ask to run it outside
  the sandbox. Then tell the user to restart the agent (Claude Code: close and reopen; Codex: start a
  new chat): MCP tools load at startup. If it stops, show the user its message; it says what is missing.

  mac-cu runs as a menu bar app (one for all sessions): the first call starts it, and it stays until
  the user quits it in the menu. The menu shows the version, each session and what it does now, the
  permissions, the modes, and shows manual update guidance. While a simulator LCD window is open, mac-cu also appears in the Dock with its bundled app icon; clicking its Dock icon restores the most recently used LCD window. The borderless LCD has an opaque device body, a drag capsule with a device menu, and right/bottom control toolbars; see [device window controls](references/device-window.md). Closing the last LCD window returns mac-cu to menu-bar-only operation. After a plugin update, the next call quits
  the old app and starts the new one by itself.

**Permissions.** mac-cu.app itself (not the app that runs the agent) needs Accessibility for apps and
Screen Recording for window screenshots (`screenshot`, decide `picture`). `simulator`,
`webinspector`, `device` and `sensor_replay` need neither permission. When one is missing, mac-cu asks macOS, opens its page in System Settings
and shows a panel below it with the mac-cu icon: the user drags the icon into the list. To check both
again and show the guides (no build), the user or the agent runs:

```bash
python3 "<SKILL_DIR>/scripts/setup.py" --permissions
```

The menu bar menu shows both permissions too, and opens the guide for a missing one. After Screen
Recording is on, macOS can ask to quit and reopen mac-cu: the user quits it in the menu bar, and the
next call starts it again.

**Simulator preparation.** Menu bar or app menu **시뮬레이터 관리…** lists all devices, creates compatible devices, downloads/imports runtimes and starts a selected device in the native LCD. Read [simulator preparation](references/simulator-preparation.md) for confirmations, claim guards and cancellation. App builds, installation, launch and logs continue through Simulator Pilot.

## 2. Approval

The first time mac-cu uses an app in a session (also a browser, and the devtools Chrome), mac-cu
shows its own dialog *Allow mac-cu to use "App"?* (not a question in the client, so it shows in
every client). An approval holds until the session ends. If the result says the user did not allow
it, or did not answer in 3 minutes, stop and tell the user; do not work around it. **Always Allow** in the dialog
allows the app in later sessions too: mac-cu writes it to
`~/Library/Application Support/mac-cu/always-allow.txt`, which a plugin update keeps. Apps listed there
or in `always-allow.txt` in the skill folder (one app name or bundle ID per line) are not asked about.

## Operating the selected target

For microphone, camera, motion, location or workout fixtures in a developer-controlled test app, use [sensor replay](references/sensor-replay.md).

Read [operations](references/operations.md) for desktop apps, browser engines, Simulator input,
iOS web views, modes and troubleshooting. For a physical iPhone, iPad or Apple Watch, read [physical device](references/physical-device.md):
allow it by identifier, drive foreground apps with the signed XCTest runner (`xctestStart`…`xctestStop`), and confirm visual state with a fresh `screenshot` or `xctestDescribe` tree. Do not open or use Xcode Device Hub (its live screen sharing blanks physical cameras on iOS/iPadOS). Use only the target the user requested; confirm the
result with a fresh tree or screenshot. Prefer a command, API or dedicated tool when available.
For Simulator app launch, logs, test data and checking a change, use `simulator-pilot` with this
server's `simulator` tool. Risky mutations require the user's task authorization.

The optional `decide`, `pick` and verify paths use OpenAI Decisions and require an API key;
they are not prerequisites for local AX/HID inspection. Screen or app data sent for a judgment
leaves the machine; use these paths only with the user's authorization.
Plugin updates are manual in this distribution: update the selected Plugin through its host,
then rerun its installed `scripts/setup.py` and start a new session.
