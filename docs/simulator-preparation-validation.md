# Simulator preparation verification

Run `python3 scripts/validate_distribution.py` and `bash scripts/check.sh` from the repository root. Follow [native check safety](native-check-safety.md) before launching a native harness.

The completed manager passed backend/subprocess fixtures, production typechecking, guarded manager UI checks and the full repository suite. Coverage includes compatible runtime/model selection, name admission, claim blocking, cancellation/timeouts, bounded output, creation draft recovery, inventory readback, tab/search/selection behavior, keyboard field routes and confirmation Return cancellation with focus restoration. Guarded inventory-only checks exercised the actual device/runtime lists without creating devices or installing runtimes.

A prior harness removed production helper dispatch and recursively entered the GUI. The fixed runners preserve helper dispatch, reject inherited root entry, prove non-GUI routes first and enforce parent deadlines, exact executable budgets and owned-process cleanup. Six dedicated safety regressions passed.

## Limits

Actual runtime download/import, new-device creation, cold boot and manager-driven LCD opening were not exercised as part of inventory-only acceptance. Mock tests do not establish those live operations. Physical popup-menu operation, file picking, VoiceOver and touch remain separate checks. Local inventories, identifiers, screenshots, logs and installation receipts are excluded from Git and release archives.
