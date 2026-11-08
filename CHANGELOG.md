# Changelog

## Unreleased

- Improve simulator control responsiveness by separating bounded display/angle observation from ordered HID delivery and safe hinge motion. Apply successfully delivered Duo host rotations immediately, admit subsequent controls after delivery/motion, reject stale observations, and skip hinge movement only for a freshly verified same target. Structured setter results explicitly distinguish delivered motion from pending guest confirmation.
- Add a standalone, mock-only [LCD design preview](docs/design/lcd-preview.md) with a guarded finite-lifetime launcher for UI/UX work, separate from the installed app and real simulator data.

- Fix visible iPhone Duo rotation: rotate the live device surface and model mask even when the guest cover stays rot0. Keep host presentation separate from guest orientation, preserve it across fold/app/input-connection changes, and use matching pointer, accessibility, screenshot, guide and preview transforms. Confirm the actual displayed surface before reporting visible rotation. Preserve compact toolbars and the integrated hinge slider.
- Prepare mac-computer-use 1.29.3 for local delivery; simulator-pilot remains 1.8.2. Marketplace publication is separate.

- Tighten native toolbar spacing: content-fit right actions, 60×44pt inline bottom items, compact popovers and resolved legacy-scroller sizing to prevent clipped icons. Preserve keyboard/AX focus, exact angle retry and persistent rotation feedback.

- Fix floating simulator preview dragging with event-based screen anchors instead of late performDrag; retain manual placement through layout updates and guard the real panel event regression under the native watchdog.

- Implement the approved native simulator LCD toolbars with grouped Liquid Glass surfaces, a right action column and bottom task row, while keeping the LCD opaque. Use one hinge slider for exact 0°/90°/180° ticks and arbitrary 1° angles; gate unsupported capabilities with visible reasons.

- Add an interactive LCD toolbar design proposal with a single right-hand column and bottom row, direct clockwise rotation, a single fine-angle hinge slider with clickable 0°/90°/180° detents, and a feature-entry classification based on Apple's Device Hub documentation.
- Prepare mac-computer-use 1.29.0 and simulator-pilot 1.8.2; publication and installed app updates remain separate steps.
- Make the simulator LCD window follow drag events directly from its visible **⠿ 이동**/device capsule. Preserve guest screen input and focus mode, clean up interrupted drags, and verify real borderless-window frame changes with guarded local AppKit events.
- Add a native **시뮬레이터 관리…** menu in mac-cu to list all devices and usage records, create compatible devices, download/import Apple runtimes, and boot a selected UDID into the existing LCD window.
- Verify actual inventory after mutations, distinguish specialized runtimes, block claimed devices and keep existing devices/data on failure or cancellation. Run long operations off the main thread with bounded output, timeout and cancellation limited to their child process group.
- Add backend, subprocess and native manager UI regression checks; document preparation separately from test app builds, installation, launch and logs.
- Apply interface-first UI design to simulator management: separate device/creation/runtime tabs, place confirmed state and actions beside the selected device, add search/state filters and distinct empty/no-match recovery, preserve failed creation drafts, and keep operation feedback outside scrolling pages. Add inline name admission, keyboard field/picker routes, runtime compatibility display and boot-in-progress waiting without duplicate boot commands.
- Finish the native design with a structured selection card, accent-colored primary actions, Control-Tab/Control-Shift-Tab task switching, and tested runtime-consent Return cancellation with focus restoration. Make the watchdog interruption test wait for actual monitoring instead of a startup-time assumption.
- Prevent recursive GUI entry in production-based test apps: preserve permission-helper dispatch, reject inherited test entry and run both LCD/manager harnesses with a parent deadline, exact executable instance budget and owned-process cleanup. Document and test the native-check safety rules.
## 1.0.0 — 2026-11-08

- Extract Mac Computer Use and Simulator Pilot into the independent Mac Pilot repository with their relevant Git history and preserved local development data.
- Deliver canonical packages directly through Codex and Claude Code `mac-pilot` marketplaces; retain manifest-relative setup, user Keychain and existing macOS permissions.
- Release mac-computer-use 1.27.0 with native borderless LCD windows, draggable handles, detachable sidebar modules, focus mode and OpenAI Decisions settings.
- Show actual synthetic connection requests, validated results, timing and errors in Settings without exposing API keys or authentication headers.
- Release simulator-pilot 1.8.1 with the independent installation source and public verification guidance.
- Make gesture checks reproducible from a clean checkout by packaging the required synthetic test helpers under tests/.
