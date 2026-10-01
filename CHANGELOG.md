# Changelog

All notable changes to the hub are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and releases carry semantic version tags (`v1.2.1` is the latest). Downstream repositories pin the hub by commit SHA, so each entry also records the date it reached `main`. When the Unreleased section ships, rename it to the new version (the next minor after `v1.2.1` is `v1.3.0`) and tag the merge commit.

## Unreleased

### Security

- Bash guard: quoted flags, unambiguous abbreviations (`--no-verif`), nested shells, variable assignments, `GIT_CONFIG_*` overrides, every refspec form of the default branch, and hook-file writes are now blocked (`docs/adr/0003-command-guard-defence-in-depth.md`).
- Claude Code settings: native `permissions.deny` Bash rules back the hook, the sandbox pre-allows the package registries the contract names, and cloud credentials are denied to sandboxed commands.
- Managed settings: `managed/claude-code-managed-settings.json` and `Install-ClaudeManagedSettings.ps1` deploy the deny rules, the guard hook and the sandbox as a machine policy that no project or user file can override.
- Downstream sync can run with a GitHub App installation token (short-lived, scoped per repository, least-privilege permission inputs) instead of a personal access token.
- Bash guard: hook-directory tampering is matched at directory level (including the configured `core.hooksPath`, `$(git rev-parse --git-dir)/hooks` and `cd` into the directory), `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` are covered, and the project settings mirror every Bash deny rule for the PowerShell tool and deny the Edit tool on hook directories.

### Added

- The hub carries its own `.agent-governance.lock`; the governance gate verifies the hub's root copies against `template/` and fails when the lock is missing.
- Policy eval: 22 bypass scenarios and 13 look-alike legitimate commands, plus 2 documented accepted misses that fail the eval if a guard change starts catching them; the catalogue is now 39 blocked / 21 allowed / 2 accepted misses.
- Dependabot for GitHub Actions, a weekly toolchain-freshness report for the pinned tool versions, `SECURITY.md`, and this changelog.
- `docs/runbooks/opt-in-rollout.md`: the machine-policy install, GitHub App setup and fleet follow-up, with a prompt for a local agent.

### Changed

- `protect-main.ps1` matches the server-side branch policy exactly: lowercase prefix, any-case slug.
- The test suite clears agent-session markers for its own process and uses only the repository's own Prettier, so results no longer depend on the host.
- Server-side branch policy accepts `dependabot/*` branches.

## 2026-09-29

- Hooks-only `Sync-AgentGovernance hooks` action, tracked `.githooks` support, fewer Actions minutes, live-eval sessions that did not run are reported as inconclusive.

## 2026-09-28

- Conditional server-side rulesets with a safe fallback; downstream formatting with the repository's own Prettier.

## 2026-09-27

- Weekly automated re-sync pull requests, policy-coverage eval in CI, opt-in sandboxed live agent eval, Codex and Gemini CLI settings, parallel pre-commit guardrails.
