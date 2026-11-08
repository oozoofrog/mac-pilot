# Changelog

## Unreleased

## 1.0.0 — 2026-11-08

- Extract Mac Computer Use and Simulator Pilot into the independent Mac Pilot repository with their relevant Git history and preserved local development data.
- Deliver canonical packages directly through Codex and Claude Code `mac-pilot` marketplaces; retain manifest-relative setup, user Keychain and existing macOS permissions.
- Release mac-computer-use 1.27.0 with native borderless LCD windows, draggable handles, detachable sidebar modules, focus mode and OpenAI Decisions settings.
- Show actual synthetic connection requests, validated results, timing and errors in Settings without exposing API keys or authentication headers.
- Release simulator-pilot 1.8.1 with the independent installation source and public verification guidance.
- Make gesture checks reproducible from a clean checkout by packaging the required synthetic test helpers under tests/.
