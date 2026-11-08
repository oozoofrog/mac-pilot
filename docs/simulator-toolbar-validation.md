# Simulator control verification

Run `python3 scripts/validate_distribution.py` and `bash scripts/check.sh` from the repository root. Follow [native check safety](native-check-safety.md) before any GUI test and run foreground checks serially.

The completed 1.29.3 implementation passed the full repository checks, production Swift typechecking, geometry and image rotation checks, guarded native toolbar interactions, and the headless production observation bridge regression. Controlled readers cover cancellation, stale-result rejection, bounded refresh coalescing, device isolation, synchronous supersession and replaced/current connection errors. Guarded device checks covered visible cover/inner turns, reverse turns, input/AX/capture/preview transforms, duplicate admission and restoration. An initial mock event failure did not reproduce in the instrumented repetition or subsequent full suite.

Command completion distinguishes safe local delivery from guest confirmation. Independent observation must not hold the ordered HID lane; a fresh same-target hinge observation is required to skip motion. Host presentation and guest orientation remain separate. Native recordings retain guest orientation.

## Limits

Programmatic AppKit events do not establish physical pointer or VoiceOver acceptance. Cross-display dragging, real recording/save-picker completion, live preview freshness and contrast across arbitrary desktops remain separate acceptance checks. The standalone mock preview cannot establish production device behavior or performance. Its automated GUI/design acceptance and later body-attached toolbar changes are outside the 1.29.3 completed scope. Raw logs, captures, measurements and installation receipts stay outside Git and release archives.
