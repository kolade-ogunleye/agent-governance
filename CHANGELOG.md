# Changelog

All notable changes to the hub are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and releases carry semantic version tags (`v1.3.0` is the latest). Downstream repositories pin the hub by commit SHA, so each entry also records the date it reached `main`. When the Unreleased section ships, rename it to the new version (the next minor after `v1.3.0` is `v1.4.0`), add a fresh empty Unreleased heading above it, and tag the merge commit.

## Unreleased

### Fixed

- Downstream sync with the GitHub App: the installation token now requests `workflows: write`, and the runbook lists the Workflows permission. Without it GitHub refuses every sync push, because each sync updates the pinned gate in `.github/workflows/agent-governance.yml`.

### Security

- Governance gate: the required `integrity` check now fails when a governed repository cannot fetch its hub (for example, a missing or expired `AGENT_GOVERNANCE_HUB_TOKEN` for a private hub). It previously logged a warning, skipped verification and still reported success.
- Machine policy: the installer copies the Bash guard into the administrator-only managed-settings directory and points the policy at that copy. The policy previously ran the guard from the user-writable hub clone, so an agent working in the hub (or anything running as the user) could weaken the guard that machine policy enforces. Re-run the installer elevated after a hub release that changes the guard.
- Bash guard: quoting is parsed per shell, from the hook's `tool_name` and from each nested shell's name. Single-quoted text no longer counts as a command substitution, and PowerShell backticks count as escapes rather than substitutions, so prose such as `git commit -m 'Document $(...)'` or a `Write-Host` string with an escaped newline is no longer blocked; `$(...)` and bash backticks inside double quotes are still inspected. Policy eval: +2 blocked, +3 allowed (47 blocked / 28 allowed / 2 accepted misses). Raised by review on homelab #22 and infosec #47.
- Pre-push audit: reviewed, expiring exceptions for npm advisories that have no fixed release (`.audit-exceptions.json`: GHSA id, reason, expiry at most 90 days ahead). Excepted advisories are still reported on every push; malformed or expired entries, unattributable npm failures and every advisory without an entry block. Repositories without the file behave as before.
- Bash guard: nested shell payloads are now inspected when `cmd.exe` takes slash switches before `/c` (`cmd.exe /d /s /c "..."`) and when a double-quoted payload contains escaped quotes (`\"` or PowerShell `` `" ``), which previously ended the capture early and hid the rest of the command. Only the escapes the target shell removes are decoded (bash keeps `'` inside double quotes), `/` switches apply to `cmd` only (case-insensitive), nested shells named inside quoted prose such as a commit message are ignored, and a nested shell inside a nested shell is inspected. The guard's accepted-miss note now names the hub ADR, which downstream repositories do not carry. The policy eval adds 6 blocked and 4 allowed scenarios (45 blocked / 25 allowed / 2 accepted misses).

### Documentation

- README: per-repository sandbox hosts go in `.claude/settings.local.json` (list settings merge across files), keeping the managed `.claude/settings.json` unmodified.

## 1.3.0 - 2026-10-01

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
