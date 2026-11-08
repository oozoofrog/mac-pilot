# Simulator preparation validation

The native preparation manager uses the existing production backend and LCD route. Task tabs separate inventory, device creation and runtime preparation. Selection details distinguish actual state, last-known inventory, runtime and usage; filtering clears a hidden selection. Drafts survive refresh and recoverable failures. Runtime installation retains explicit consequence and cancellation controls.

## Checks performed

- The full repository check passed during implementation, including distribution/safety tests, production Swift typechecks, preparation backend/UI and Decisions checks, and existing gesture/docking suites.
- Guarded native checks exercised empty/no-match states, retained drafts, compact scrolling, tab focus and wrapping, consent cancellation with no installer command, and focus return.
- Earlier live checks covered device creation, cold boot, LCD framebuffer/capture, registry cleanup and claim blocking/release. These lifecycle checks preceded the tab redesign; the redesigned create/start routes used injected backends.
- The final isolated preparation window check passed serially under its watchdog as part of the 1.30.0 verification. Owned test processes and temporary claims were cleaned up.

## Remaining limits

Physical keyboard/touch, VoiceOver, multiple displays, actual runtime download/import, installer cancellation, Apple login/licensing, disk-space failures and native file picking remain unverified. An earlier live reopen stopped at its foreground guard before the action was sent. The guard was retained.

Generated apps, captures, logs, device identifiers and installation receipts remain local and are excluded from Git and release archives. Source checks, global app installation and marketplace publication are separate operations.
