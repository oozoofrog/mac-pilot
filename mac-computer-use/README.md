# Mac Computer Use

Operate Mac apps, browser pages, iOS web views, and physical iPhones, iPads and Apple Watch with the mac-cu MCP server. Use for desktop UI tasks without a better API or CLI, web view inspection, XCTest UI automation, input and screenshots on connected iPhones, iPads or paired Apple Watch, or mac-cu setup, modes and simulator preparation. Route iOS Simulator app launch, logs, test data and change verification through simulator-pilot.

The native simulator LCD keeps content opaque and groups actions in right and bottom Liquid Glass toolbars. See [device window controls](skills/mac-computer-use/references/device-window.md) for the single hinge slider, input, inspection and capability availability.

For physical iPhones, iPads and paired Apple Watch, select a UUID with `device allow` to run signed XCTest UI automation (`MacPilot Runner`), capture one-frame screenshots or (on portrait iPhone and Watch) send CoreDevice HID input without opening Xcode Device Hub; see [physical devices](skills/mac-computer-use/references/physical-device.md). Opted-in iOS and watchOS test apps that link `MacPilotSensorReplay` can receive synchronized microphone, camera, motion, location and workout timelines through `sensor_replay`; see [sensor replay](skills/mac-computer-use/references/sensor-replay.md).

See [skill and setup](skills/mac-computer-use/SKILL.md) and [installation](skills/mac-computer-use/README.md).

The source package preserves the supplied layout, author and MIT attribution. This directory is the installable package; there is no duplicate distribution mirror. Releases omit generated executables, caches, development evidence and private runtime state.
