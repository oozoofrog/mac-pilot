# Installation and migration

Register `oozoofrog/mac-pilot` from main and install only the packages you need, using the [README commands](../README.md#install). For a local checkout, use `codex plugin marketplace add "$PWD"` from this repository root and inspect the selected source before installing.

Previous `@oozoofrog-plugin` installations should be replaced by the corresponding `@mac-pilot` Plugin using the host's Plugin manager. Install one copy of each skill; do not leave duplicate active versions. A marketplace move alone does not remove existing installations or rewrite another account's configuration.

After installation, locate the installed package. Keep `mac-computer-use/` whole because setup reads `.claude-plugin/plugin.json` relative to the skill. Run:

```sh
python3 <INSTALLED_PACKAGE>/skills/mac-computer-use/scripts/setup.py --agent codex
# For Claude Code, use --agent claude.
```

The app remains at `~/Library/Application Support/mac-cu/mac-cu.app`, with its existing bundle ID and Keychain service. Setup preserves user allow lists and profiles. macOS can request app permissions or Keychain access when a signing identity changes; the user grants these through the native system UI. Do not reset permissions or copy the key into source files.

Simulator Pilot builds its Swift CLI into `~/.local/bin/sim-pilot`. Xcode and the target simulator runtime must already be installed. Screen interaction uses mac-cu's simulator tool (Xcode 27+). Follow [Simulator Pilot setup](../simulator-pilot/skills/simulator-pilot/SKILL.md) and project build instructions.

The local MCP app, enabled Plugin, installed skill path and fresh-session tool list are separate. Start a new chat after changing Plugins or MCP registration. Confirm the new installed skill path and `decide` tool's OpenAI description. Key-based Decisions connectivity can be checked with synthetic text; do not send private windows as a connection test.

After the installed app is replaced, an idle MCP stdio client must use the new executable for its next connection. The daemon must still verify the executable path of each peer. A restarted daemon starts a new device session. Select the device again before sending input. Clients started with an older build that reports `mac-cu could not reach its daemon` need one fresh MCP connection to load this recovery behavior.

## Local delivery after development

The workspace user has given standing authorization to build and replace the global mac-cu app after completed implementation work, so they can verify it. Complete isolated source/UI checks first; this is a delivery step, not a substitute for those checks.

Use the canonical setup build/signing implementation and keep its manifest-relative resources. Prepare and verify a staged app before stopping the installed daemon, back up the previous bundle outside Git, preserve the existing bundle/signing identity, then replace the app and gracefully restart it. When MCP already points at the stable global executable, an app-only replacement need not rewrite agent registrations, Plugin caches or browser configuration. Keep user profiles, allow lists, permissions, Keychain entries, captures and simulator data intact.

Read back both the installed bundle version and the running daemon's MCP version, check existing permissions, and confirm the manager's user-facing entry. Record the backup path and actual verification results. Local replacement does not imply a commit, push, marketplace release, updated Plugin cache or fresh-session skill exposure.
