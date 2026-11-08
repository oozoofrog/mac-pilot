# AGENTS.md

- Modify the canonical `mac-computer-use/` and `simulator-pilot/` packages directly; both marketplaces point to these directories. There is no `plugins/` mirror.
- Use the skill-creator workflow for material skill changes. Keep trigger wording consistent across SKILL.md, manifests, UI metadata and README.md; keep long guidance in references/.
- Preserve manifest-relative setup resources, original attribution, user profiles, Keychain entries, captures and simulator data.
- Do not include credentials, private service configuration, generated executables, browser profiles or local development evidence in Git or release archives. Do not reproduce removed identifiers in docs or commit messages.
- Run `python3 scripts/validate_distribution.py` and native checks appropriate to changed functionality. Document actual checks and remaining limits. Run foreground desktop checks serially on an unlocked desktop and keep input guards.
- Update CHANGELOG.md for user-visible changes. Version both host manifests together; update marketplace versions and README.md when releasing a package.
- Commit/push/publish only within the user's authorized scope. Verify remote main, tags, release asset hashes and catalog content after publishing. Keep local installation separate from marketplace publication and fresh-session exposure.
