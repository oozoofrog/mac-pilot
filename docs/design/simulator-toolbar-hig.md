# Native simulator toolbar material decisions

Reviewed 2026-11-08 against current official Apple documentation and the installed macOS 27.2 SDK. These decisions translate the approved [interactive design](simulator-toolbar.html) into AppKit.

- Keep the LCD pixels and their backing opaque. A regular-glass enclosure provides a narrow common rim; the opaque interior and LCD are in its `contentView`, above the material. The top grip, right toolbar and bottom toolbar are sibling regular-glass surfaces with plain controls, all in the same window and the same merging container. There is no glass overlay on the guest display. Regular glass protects control legibility over arbitrary desktops. [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- Fit the raised controls to the device: inset the top handle and bottom row from the body corners to form shoulders, and start the right column below the upper corner. Overlap each joining cap into the enclosure by its corner radius plus 4pt; tangent capsules leave a visibly pinched neck even with container merging. Keep control content and hit coordinates outside the LCD. Use 44pt icon-only actions with tooltips and accessibility names. The bottom row has no idle status footer or dedicated response button; show the last result and response history in More, and mirror progress/failure on the fixed device menu so short windows cannot hide it. Preserve scrolling and a separate resize target. Inspect the rendered joins at Phone/Duo sizes and orientations rather than accepting touching frames as a connected design.
- The shared `NSGlassEffectContainerView` merges the enclosure and three control surfaces with 12pt proximity. Zero spacing only batches effects and cannot join an opaque `NSView` to glass. Keep independent toolbox/floating layouts at zero spacing. Avoid layered glass backgrounds; native popovers use their own presentation with plain form content. [AppKit container](https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview), [spacing](https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview/spacing), [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- Let AppKit handle window activation and glass adaptation. Use semantic label colors, visible focus, text/checkmarks alongside color, and selective state tint. Re-resolve custom layer colors when appearance changes. Preserve a solid fallback for Reduce Transparency and stronger outlines for Increase Contrast. Host settings never change guest settings implicitly. [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [NSVisualEffectView.state](https://developer.apple.com/documentation/appkit/nsvisualeffectview/state-swift.property)
- Open one transient presentation at a time. Enter its first appropriate control; Escape returns focus to the opener. Preserve unsubmitted drafts. Anchor bottom popovers above the toolbar. Use native alerts/sheets for warnings and explicit target/consequence/cancel confirmation; management and settings have separate windows. Respect Reduce Motion for custom transitions and popover animation. [Apple HIG: Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers), [NSWorkspace accessibility preferences](https://developer.apple.com/documentation/appkit/nsworkspace)
- The hinge has one semantic slider, exact integrated 0°/90°/180° ticks and free 1° adjustment. The 90° tick is a Mac Pilot design requirement. A tick click must not impose snapping on adjacent drag angles. Confirmed state remains distinct from draft/pending/error state.

## SDK verification

The macOS 27.2 SDK’s `AppKit.framework/Headers/NSGlassEffectView.h` declares `NSGlassEffectView`, regular/clear styles, `contentView`, corner radius and tint from macOS 26; `effectIsInteractive` is macOS 27+, default false. Only assignment through `contentView` guarantees placement inside the effect. `NSGlassEffectContainerView` and its spacing property are declared in the same header. The pre-26 fallback uses `NSVisualEffectView` with window activity tracking. Availability guards must retain support for older systems.

Official API references: [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), [contentView](https://developer.apple.com/documentation/appkit/nsglasseffectview/contentview), [effectIsInteractive](https://developer.apple.com/documentation/appkit/nsglasseffectview/effectisinteractive).

## Evidence boundary

Source/SDK review establishes API availability and intended hierarchy. Runtime checks must separately cover bounds, hit separation, keyboard/focus, draft/error lifecycle, active/inactive and light/dark appearance. Automated AppKit events do not establish physical pointer, VoiceOver speech or cross-display interaction. Actual checks and limits are recorded in [toolbar validation](../simulator-toolbar-validation.md).

### Directional rotation presentation (local 1.29.7)

Successful serialized delivery carries signed quarter turns to the window. Relative
clockwise/counterclockwise requests retain their sign through the 270°/0° boundary;
absolute choices resolve a shortest turn on the delivery lane (180° uses clockwise).
The requested host pose and observed guest framebuffer remain separate on Phone
and Duo. A guest acknowledgement is not a prerequisite for showing the turn.

The opaque LCD, body and attached controls remain in their common glass hierarchy.
During a turn, upper/right/lower controls and the resize handle are suppressed
without changing layout space. Only body/LCD/physical-top pixels enter the temporary
presentation in the same window, using a transparent envelope for swept corners.
A 0.46 s smooth turn includes a short final body blend; controls return over 0.12 s
after the final layout is stable. Hidden controls are disabled and hidden from AX;
restoration is generation-checked through reversals and interrupted fades. Repeated delivery retargets
the sampled angle with one timer and a bounded duration; complete accumulated
revolutions are discarded under a burst. The small bezel mark identifies the
physical top, including screens whose content does not establish an obvious top.

Desktop LCD pointer/key input and moving control hit testing are guarded during the
presentation. Captures, guest accessibility and the separate preview use committed
host geometry; they do not expose intermediate decorative coordinates. New display
identity/orientation, fold, failed delivery, live resize and closure cancel the
presentation and restore the real hierarchy. Captured presentation pixels are
memory-only and never become simulator input or saved guest captures.

[Apple HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
recommends purposeful, brief feedback and cancellation. AppKit's
[accessibilityDisplayShouldReduceMotion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)
provides the preference; it does not implement the transition. Reduce Motion uses
a short 0.14 s fade with the final orientation mark instead of a spatial turn.
The default and reduced transitions require separate rendered validation; the API's
presence is not evidence that the visual result meets the user's request.
