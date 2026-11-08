# Development and releases

Canonical packages live at the repository root and are delivered without duplicate mirrors. Update the two host manifests for each changed package, matching marketplace versions and README.md, and record user-visible changes in CHANGELOG.md.

```sh
python3 scripts/validate_distribution.py
bash scripts/check.sh
```

The native check script runs Swift type checks, Decisions mock/UI checks and gesture checks. Foreground checks require an unlocked interactive Mac and run serially. The [device-window procedure](mac-cu-device-window-validation.md) covers isolated live checks. Never shutdown/reset a shared device or bypass protected-input failures.

Follow [native check safety](native-check-safety.md) before launching test apps or previews. The shared native runners preserve the permission helper, prove rejected/inherited routes before opening the UI, and enforce parent deadlines and exact executable instance limits. A preview must keep its parent watchdog running; its default lifetime is 30 minutes.

After reviewing and committing main:

```sh
python3 scripts/package_release.py --output dist
```

The packager reads only Git-tracked files under the two package directories and rejects runtime/user-state paths. It emits per-package zip archives, SHA256SUMS and release.json with the source commit and package versions. Do not add ignored local development data to the index.

Push main and a reviewed project tag, publish the generated assets, then read back remote main, catalog entries, tag and release asset hashes. Source archive verification does not establish installed/enabled status, fresh-session skill exposure or native app behavior.
