# Changelog

## Unreleased

- Recognize current simulator backlight readback so an active display is available to LCD and input workflows when `devicectl` omits the older active flag.

- Improve the LCD's related tool flows while preserving the compact connected-glass toolbar, opaque LCD and directional rotation. Environment controls display backend-confirmed values, pending requests and retry; View exposes window state and size directly. Input/location retain drafts and show local feedback. Inspection opens directly with labeled fields, guide capture and persistent results; report images, recovery and recent activity share the same result content. Coordinate transient close/Escape/focus, prevent keyboard forwarding from taking focus out of a form, and remove overlapping Watch inspection controls. Preserve manager/preview workflows while clarifying stale inventory, settings drafts and preview names. Prepare mac-computer-use 1.30.0 for local delivery only.

- Remove the standalone LCD design preview app, scenario/feedback UI and runner. Keep the production LCD as the implementation and verification path, preserve existing user feedback, and migrate directional-turn/chrome-restoration regressions into the finite native selfcheck harness. Explicitly lay out and display a newly opened LCD before its first capture. Production live floating previews remain available. Prepare mac-computer-use 1.29.8 for local delivery.

- Animate delivered simulator turns with signed clockwise/counterclockwise travel, continuous bounded retargeting and a physical-top bezel mark. Keep the common container and its layout space while temporarily hiding upper/right/lower controls during the body/LCD turn; restore controls after the final layout settles and reject stale restoration callbacks. Keep capture/guest AX at committed host geometry and guard moving desktop input; fade instead of rotating with Reduce Motion. Preserve ordered HID delivery and asynchronous observation, including the host/guest distinction on Phone and Duo. Prepare mac-computer-use 1.29.7 for local delivery only.

- Simplify the attached simulator toolbars to 44pt icons with tooltips and accessibility names. Remove the persistent ready/response footer, move response history and the last result into menus, and retain visible progress/failure indicators on the fixed device menu.

- Correct the simulator’s raised grip and toolbar silhouette: put the opaque LCD inside a regular-glass enclosure and merge that enclosure with all three raised control surfaces in one window and one shared container. Inset the top/bottom attachments to form shoulders and remove the separate capsule rims at the joins. Keep the cross-arrow grip and independent menu at 44pt, retain scrolling and guest input, and record preview source/binary hashes for build identification. Extend the joining caps into the enclosure so no pinched neck or open notch remains between body and toolbar. Prepare mac-computer-use 1.29.6 for local delivery; publication remains separate.

- Attach the simulator's glass action and task toolbars to the fitted device body, align its movable handle with that body, and keep compact controls scrollable without covering the LCD. The initial 1.29.4 placement alone did not produce a joined silhouette.
- Improve simulator control responsiveness by separating bounded display/angle observation from ordered HID delivery and safe hinge motion. Apply successfully delivered Duo host rotations immediately, admit subsequent controls after delivery/motion, reject stale observations, and skip hinge movement only for a freshly verified same target. Structured setter results explicitly distinguish delivered motion from pending guest confirmation.

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
