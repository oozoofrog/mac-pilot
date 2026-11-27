# Physical XCTest sessions

## Decision

MacPilot needs interactive commands while a UI test is running. Use an owned XCTest UI Testing Bundle with no target application in its scheme. Build with Xcode. Start the signed product with xcodebuild test-without-building. The host selects the matching wired usbmuxd entry by hardware UDID. The runner listens on IPv4 loopback at a per-session port. One USB stream carries all commands. A fresh AES-GCM key from the private Xcode configuration authenticates both directions. Live video and coordinate HID remain available through the existing device tool.

Appium runs WebDriverAgent on the device as an HTTP server that dispatches requests to XCTest. MacPilot needs the same ability to issue successive commands during a UI test. The built-in Xcode tools cover installation and execution, so the MacPilot transport adds no external library. [Appium WebDriverAgent architecture](https://appium.github.io/appium-xcuitest-driver/v4/wda-custom-server/) · [Apple command-line test execution](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)

## iPhone and iPad observable contract

1. Preparation MUST produce signed iPhoneOS test products (`TARGETED_DEVICE_FAMILY = "1,2"`) outside the repository. Only a successful preparation may replace the pointer to the prepared run configuration. No signing credentials or personal team identifiers belong in the package.
2. After device allow, xctestStart MUST bind one wired physical iPhone or iPad, one MCP connection and an optional target bundle ID. Resolve the Xcode destination from the hardware UDID of that exact CoreDevice identifier. Start MUST NOT launch a target app. Omit the target for a transport-only session.
3. Start returns a starting state. xctestStatus checks an explicit ready record from the current runner. A running xcodebuild process alone does not establish readiness. xctestPing MUST round-trip a command and a correlated reply. It MUST NOT inspect or interact with any target app.
4. With an explicit foreground target, xctestDescribe reads a bounded element snapshot. xctestWait finds an exact accessibility identifier. xctestTap requires exactly one matching, hittable element. Query or tap MUST fail when the target is absent or in the background. A tap reply reports dispatch. To verify an outcome, issue a separate wait or describe.
5. Commands MUST be serialized. Bind each record to a fresh session ID and a strictly increasing sequence number. On ambiguous transport failure, stop the session and report uncertain delivery. Never retry an input. A malformed or partial request MUST NOT execute. Stop, release, owner disconnect and idle expiry end the owned test. The runner MUST have a finite lifetime even after host failure.
6. Keep the established device allow and lock guards. Stop and release MUST work after disconnect or lock. Other MCP clients MUST NOT take over an active runner. Existing HID commands retain their original behavior.
7. Only xctestActivate may explicitly bring the bound app forward or launch it. xctestType MUST accept only a uniquely identified, enabled plain text field in the foreground target. It focuses that field before typing up to 200 characters. A secure field MUST be refused. XCTest-reported interaction issues MUST produce a command error.
8. A returned configuration or command error MUST distinguish build/signing, runner exit, transport and target UI failures. CI and documentation MUST distinguish offline checks, SDK builds, live transport, and observed target UI effects.
9. Each direction MUST authenticate its records before parsing JSON. Bound the frame size before allocation. Only discovery before the authenticated ready record may retry a connection. A closed stream ends the session. Rebuild older prepared products before use.
10. The installed test host MUST use the MacPilot icon and the display name MacPilot Runner. Preserve the Xcode signing identity, entitlements and nested test bundle. Check the icon returned by the device for the installed bundle ID.

## Contradiction review

- An agent can decide the next command only while the runner persists. End-to-end suites that generate a test per command cannot satisfy this requirement.
- Starting an XCTest can change the device's visible system UI. A transport-only session never constructs a target XCUIApplication and never sends input.
- A usbmuxd device ID can change after reattachment. Match the wired hardware UDID during discovery. After readiness, use only the authenticated stream.
- XCTest element existence alone permits ambiguous matches. Check uniqueness and foreground state for input. Avoid long-lived element handles across UI changes.
- A transport timeout can follow successful execution. Treat a missing reply as uncertain, even if xcodebuild exits. Only status polling may repeat. End the session if an in-flight reply is lost.
- Local signing is separate from Xcode account administration. Preparation uses installed signing assets. Portal registration and device enrollment are separate operations.
- Xcode generates the outer test host. Resources in the test bundle do not register the host icon. Compile the shared artwork into the outer application and sign it with the same development identity and entitlements.

## Acceptance

| Capability | Verification |
| --- | --- |
| Preparation | Read the checked-in project with Xcode, build both SDK variants, inspect the signed physical runner and generated xctestrun. |
| Runner identity | Inspect the outer application signature, display name and compiled icon. Request the installed icon with devicectl. |
| Session lifecycle | Start on the selected iPhone, observe ready, ping twice, stop and verify the owned xcodebuild process exits. |
| Input isolation | A session without a target refuses UI operations. Wrong session/sequence or a partial record causes no action. |
| App control | On a test fixture, describe an identifier, tap it, then wait for a changed identifier. Also test missing, duplicate and background targets. |
| Distribution | Test the installed mac-cu tool schema, preserve existing signing identity and permissions, and run the distribution validator. |

## Qualification

With Xcode 27.2, the installed mac-cu daemon drove a transport-only session on a wired iPhone 14 Pro running iOS 27.2.1. Two commands returned pong. The runner rejected an app query without a target. A second MCP connection could neither stop nor release the active session. The owner stopped it and Xcode exited successfully. The earlier mailbox prototype also expired after inactivity. The release socket test interrupted a pending reply. The host reported uncertain delivery and refused the next command. The device reported zero remaining runner processes. Its installed-app record reported MacPilot Runner. The generated icon from the device showed the MacPilot artwork.

The simulator fixture verified activation, a bounded element query, a tap followed by a changed identifier, and typing followed by a changed label. It also checked secure-field refusal, ambiguous and missing identifiers, a terminated target, partial requests, wrong session IDs, wrong sequence numbers and replay. The release build also drove the dedicated fixture on the physical iPhone over USB. It activated the app, observed Draft, tapped Save, waited for Saved, and typed MacPilot USB. The updated echo label and a screen capture showed the result. A duplicate identifier and a secure field were refused. The fixture was removed after the check.

## Direct USB transport investigation

Xcode 27.2 (27B48) ships a `devicectl` launcher that selects the CoreDevice 651.31 executable. Its arm64e Mach-O imports `remoteFileTransfer`, `TransferFilesProtocol.send(to:from:)`, `receive(from:to:)`, and the `FileServicePath` initializer. These are private Swift interfaces. A standalone Mac process obtained the capability for the selected iPhone and used the signed runner's app data container. With the installed runner unchanged, it read the ready record, sent two pings, verified both replies by session and sequence, and stopped the test. This removes the CLI subprocess from the mailbox transport.

A second development-signed test opened a TCP listener on the iPhone's IPv4 loopback interface. The Mac selected the wired entry for the known hardware UDID and called the existing `Usbmux.connect` implementation. Two ordered pings and their authenticated replies crossed one open stream. The session secret and port were passed to the runner through its Xcode test configuration. The test contained no target application or UI commands. Xcode then ran the original signed product and its original transport passed again.

Release 1.4.0 uses the CoreDevice inventory from device allowance to resolve the selected hardware UDID. It opens only the matching wired usbmuxd connection. Before each command, it checks the lock requirement through the in-process CoreDevice session. An interrupted reply terminates the session with uncertain delivery. No command or response file is copied.

## Paired Apple Watch sessions

Use the same `device allow` and `xctestStart` through `xctestStop` API on a paired Apple Watch. Prepare the signed watchOS product with `prepare.py --platform watchOS --team TEAM --output BUILD_ROOT`. Preparation MUST retain the separate iPhone registration. Start MUST bind the selected watch, MCP owner and optional target app. The runner MUST use XCUIApplication for foreground activation, snapshots, waits, element taps and text entry. Send exactly one selector for element operations. Use `target` for an exact identifier or `label` for an exact accessibility label. Input MUST require exactly one match. No input may use coordinate HID as a fallback.

The iPhone uses USB loopback. watchOS restricts low-level networking, and the paired watch has its own Xcode destination. For the watch, exchange authenticated, sequence-bound records in the development-signed runner's own session directory using Xcode's device file service. Start one test per session. Reject incomplete records before dispatch. A missing reply after submission MUST end the session with uncertain delivery. Stop and idle expiry release the runner. Verify an authenticated ping and a visible postcondition after an element tap on the selected physical watch.

[Apple watchOS UI testing](https://developer.apple.com/documentation/watchos-apps/setting-up-tests-for-your-watchos-app) · [Apple watchOS networking restrictions](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)
