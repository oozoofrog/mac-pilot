# Physical iPhone: device

The `device` tool works on a physical iPhone connected to this Mac. It takes one-frame screenshots and sends taps,
swipes, keys, typed text and buttons. Input goes to the device over CoreDevice HID, so the Mac's pointer, keyboard
and front app are not touched. The tool needs neither the Accessibility nor the Screen Recording permission.

Simulators use the `simulator` tool (and `simulator-pilot` for app launch, logs and test data); web views on a USB
iPhone use `webinspector`. mac-cu has no window of its own for a physical device's screen: the user watches it in
Xcode's Device Hub (`view` below).

**Connection status:** verified over USB on an iPhone 14 Pro with iOS 27.2 (2026-11-14). Over the network
(cable removed, same Wi-Fi, same date) list, allow, screenshot, Home, volume, swipe, tap, digit entry and delete,
release and re-allow, and `view` worked; a screenshot took about 2 s instead of 1 s. Not checked over the network:
a Wi-Fi drop and recovery, and a locked phone.

## Requirements

- Xcode on this Mac. The device list comes from Xcode's `devicectl`, and input uses Xcode's private CoreDevice
  framework. Without Xcode, the tool refuses with a message to install or select Xcode.
- The iPhone is paired with this Mac (connected by cable, unlocked, **Trust** tapped). Over the network it must also
  be unlocked, with Wi-Fi on the same network as the Mac, and paired over USB before.
- The device is in portrait. Landscape or an unknown orientation is refused, screenshots included.

## Steps

1. `{"action": "list"}`: one line per iPhone, `identifier | name | state | transport | OS | allowed`.
2. `{"action": "allow", "device": "<identifier>"}`: allow the device the user named. Only the identifier (UUID) is
   accepted, never the name. One device at a time: allowing another one ends the previous device's session.
3. `{"action": "screenshot", "device": "<identifier>"}`: the size of the portrait screen in points and one JPEG
   frame. The pixels of the picture are the input coordinates (from the top left). It takes about one second.
4. Send input (table below). Before `key` or `type`, check in a screenshot that the text field shows a cursor.
5. Take a screenshot to check the result (see "Results" below).
6. `{"action": "release"}` when done. It ends the session; Device Hub stays as it is.

To let the user watch, call `{"action": "view", "device": "<identifier>"}`. It opens Device Hub at that device without
bringing it to the front (`"focus": true` brings it to the front). The screen of a physical device does not start by
itself: the user clicks **View Screen** in that window, or **Pair** first if it shows Pair. mac-cu never clicks in,
arranges or closes Device Hub, and agent input still goes through this tool.

## Actions

| Action | Parameters | What it does |
| --- | --- | --- |
| `list` | | iPhones known to Xcode, with connection state, transport (USB or network), OS and whether allowed. It adds a line when the faster in-process path is off (see below). |
| `allow` | `device` | Allows the device for this mac-cu server process. Refused when it is not paired or not reachable, with what to do. |
| `release` | | Withdraws the permission and ends the device session. |
| `screenshot` | `device` | One still frame. Allowed while the device is locked. |
| `tap` | `device`, `x`, `y`, `seconds`? | A touch at the point, held `seconds` (default 0.05). |
| `swipe` | `device`, `x`, `y`, `to_x`, `to_y`, `seconds`? | A drag from the first point to the second over `seconds` (default 0.3). |
| `key` | `device`, `key` | One key or chord: a US keyboard character, or `return`, `delete`, `tab`, `space`, `escape`, arrows (`up`, `down`, `left`, `right`), `home`, `end`, `pageup`, `pagedown`, `forwarddelete`, `f1`–`f12`, with modifiers `cmd`, `shift`, `alt`/`option`, `ctrl` (`cmd+a`). |
| `type` | `device`, `text` | Types up to 200 characters as hardware keys. Only characters of the US keyboard; other text is refused before anything is sent. Send longer text in parts. |
| `button` | `device`, `button`, `seconds`? | `home`, `lock` (same as `side`), `volumeUp`, `volumeDown`, held `seconds` (default 0.05). |
| `view` | `device`, `focus`? | Opens Device Hub at the device (above). It does not close Device Hub. |

`seconds` is 0.02 to 10. Coordinates must lie inside the portrait screen in points.

## Refusals

- A device that is not allowed, or a name instead of an identifier.
- Input while the device requires a passcode. The lock state is read before the connection opens and again right
  before sending. Unlock the device yourself; mac-cu never enters a passcode. A device without a passcode reports
  unlocked even on its lock screen, so input there is sent.
- Landscape or unknown orientation, coordinates outside the screen, `seconds` out of range, `type` over 200
  characters or with characters outside the US keyboard.

## Results

- `Sent <action>; the connection drained (barrier answered in N ms)` means the connection passed the events on. It
  does not confirm the device acted. Check the screen in a screenshot.
- `Submitted <action> … delivery is not confirmed` means the barrier was not answered (no reply within 2 seconds,
  an error reply or no barrier on the connection). Check the screen before sending again.
- A cancelled `type` stops between keys and says how many keys were sent.

## Known limits

- `key` and `type` send US-layout HID key codes. The device's hardware keyboard layout makes the characters: with a
  Korean layout, `h` arrives as `ㅗ`. Digits arrived unchanged in that layout. For letters, set the device's hardware
  keyboard layout to English (US).
- Keys go to whatever has focus on the device. If no text field has the cursor, they can reach another app.
- Screenshots take about one second each and are single frames, not a live view.
- The lock/side button and landscape were not tried on a device.
- Network connection: see "Connection status" above.

## In-process CoreDevice

mac-cu links CoreDevice weakly and checks its symbols and types once per process before using it. If the installed
Xcode differs, or Xcode is missing, the in-process path stays off: screenshots and device state then use `devicectl`
(slower), and `list` says why. mac-cu does not use the device video stream that needs Apple-only entitlements;
watching the screen goes through Device Hub.
