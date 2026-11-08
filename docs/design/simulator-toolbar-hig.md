# Native simulator toolbar material decisions

Apple documentation and AppKit SDK declarations inform the translation of the approved [interactive design](simulator-toolbar.html) into AppKit.

- Keep the LCD and device body opaque. Glass belongs to the host control layer. Use one regular glass surface for the right toolbar and one for the bottom toolbar, with plain controls inside. Regular glass protects label legibility over arbitrary desktops; the clear variant is intended for media backgrounds. [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- Avoid glass on glass. A batching container is not an additional glass surface; use zero spacing for static sibling toolbars so proximity does not merge them. Native popovers supply their own presentation, with plain form content. [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/), [AppKit container spacing](https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview/spacing)
- Let AppKit handle window activation and glass adaptation. Use semantic label colors, visible focus, text/checkmarks alongside color, and selective state tint. Re-resolve custom layer colors when appearance changes. Preserve a solid fallback for Reduce Transparency and stronger outlines for Increase Contrast. Host settings never change guest settings implicitly. [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [NSVisualEffectView.state](https://developer.apple.com/documentation/appkit/nsvisualeffectview/state-swift.property)
- Open one transient presentation at a time. Enter its first appropriate control; Escape returns focus to the opener. Preserve unsubmitted drafts. Anchor bottom popovers above the toolbar. Use native alerts/sheets for warnings and explicit target/consequence/cancel confirmation; management and settings have separate windows. Respect Reduce Motion for custom transitions and popover animation. [Apple HIG: Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers), [NSWorkspace accessibility preferences](https://developer.apple.com/documentation/appkit/nsworkspace)
- The hinge has one semantic slider, exact integrated 0°/90°/180° ticks and free 1° adjustment. The 90° tick is a Mac Pilot design requirement. A tick click must not impose snapping on adjacent drag angles. Confirmed state remains distinct from draft/pending/error state.

## SDK verification

`AppKit.framework/Headers/NSGlassEffectView.h` declares `NSGlassEffectView`, regular/clear styles, `contentView`, corner radius and tint from macOS 26; `effectIsInteractive` is macOS 27+, default false. Only assignment through `contentView` guarantees placement inside the effect. `NSGlassEffectContainerView` and its spacing property are declared in the same header. The pre-26 fallback uses `NSVisualEffectView` with window activity tracking. Availability guards must retain support for older systems.

Official API references: [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), [contentView](https://developer.apple.com/documentation/appkit/nsglasseffectview/contentview), [effectIsInteractive](https://developer.apple.com/documentation/appkit/nsglasseffectview/effectisinteractive).

## Evidence boundary

Source/SDK review establishes API availability and intended hierarchy. Runtime checks must separately cover bounds, hit separation, keyboard/focus, draft/error lifecycle, active/inactive and light/dark appearance. Automated AppKit events do not establish physical pointer, VoiceOver speech or cross-display interaction.
