# Simulator LCD and toolbar validation

## Implemented scope

The LCD keeps an opaque framebuffer inside a common regular-glass enclosure with attached grip, action column and compact task row. Controls use 44pt targets, tooltips and accessibility names; overflow remains scrollable. The fixed device menu exposes progress/failure and response history. See [material and motion decisions](design/simulator-toolbar-hig.md).

Delivered orientation requests carry signed quarter turns, including wraparound and reversal. Host presentation remains distinct from observed guest orientation. During motion, chrome is hidden, disabled and excluded from accessibility without losing layout space; generation checks prevent stale restoration. Reduce Motion uses a fade. Capture, input and guest accessibility retain committed geometry. Fold, resize, closure and failed delivery cancel presentation safely.

Environment controls distinguish confirmed, unknown, pending, mismatch and retry states. View shows current window choices. Input/location retain drafts, validate submission and report local status. Inspection opens directly with labeled fields, guide capture, persistent text/images, activity and recovery. Transient presentations coordinate Escape and focus. Settings retain visible drafts; preparation labels last-known inventory; floating previews retain real device content and accessible names. Current display readback normalizes backlight state when the older active flag is absent.

The standalone LCD design app and feedback/scenario runner were retired. Existing feedback was preserved. Rotation regressions now use the finite native selfcheck harness with synthetic surfaces; production floating previews remain available.

## Checks performed

- Earlier full repository checks passed distribution/safety tests, production and simulator-pilot Swift typechecks, settings/preparation, slider/host adapters, toolbar/gesture/docking, LCD movement, floating preview, occlusion, browser probe and icon checks.
- Rotation regressions covered signed wrap, Phone and Duo projections, reverse/burst retargeting, bounded completion, synthetic surface pixels, input/AX suppression, cancellation, reduced motion and final geometry. Production helper dispatch, unknown/inherited entry rejection and watchdog cleanup were checked before GUI launch.
- State regressions covered unknown/pending/mismatch/retry, nonpreset text sizes, keyboard state, coordinate boundaries and invalid drafts, Watch layout, persistent results and stale activity rejection. Concurrent display readback and backlight normalization checks passed.
- The final isolated toolbar interaction, window movement, floating presentation, settings and preparation checks passed serially under watchdogs. An initial LCD attempt stopped before opening a window because display readback lacked the older active flag; normalization corrected that path.
- Final guarded production LCD verification passed environment readback, environment-to-input switching, unsent drafts, keyboard-checkbox focus/restoration, Escape, View, direct inspection and actual guide capture in persistent results. Compact task geometry and opaque LCD checks passed. Earlier transition assertions were resolved by waiting for native popover animation in the harness; production source was unchanged. Owned test processes returned to zero and the claim was released.
- The canonical 1.30.0 app was installed and restarted. Source/binary hashes, strict signing, disk/running versions and Accessibility/Screen Recording permissions were verified. A settled installed LCD screenshot was inspected. Profiles, Keychain and simulator data were preserved. Installation is separate from publication.

## Remaining limits

Final checks use programmatic AppKit actions, not physical pointer/keyboard or VoiceOver. Earlier production rotation evidence belongs to 1.29.8; final 1.30.0 LCD verification deliberately skipped rotation. Live fold/disconnect/failure, every device/material combination, multi-display movement, real recording/save-picker completion and arbitrary long-result navigation remain unverified. Nested scrolling, small image previews and partially visible activity remain usability limits. Mock cancellation does not prove live service failure behavior.

Raw logs, screenshots, recordings, device identifiers, hashes and installation receipts remain local and are excluded from Git and release archives. No new full native/GUI run is required solely to commit the already validated source.
