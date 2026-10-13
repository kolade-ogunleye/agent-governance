# Changelog

All notable changes to the hub are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and releases carry semantic version tags (`v1.3.0` is the latest). Downstream repositories pin the hub by commit SHA, so each entry also records the date it reached `main`. When the Unreleased section ships, rename it to the new version (the next minor after `v1.3.0` is `v1.4.0`), add a fresh empty Unreleased heading above it, and tag the merge commit.

## Unreleased

### Added

- Fleet: `kolade-ogunleye/ai-os` (private, Python) is enrolled in `fleet.json`. Its `AGENT_GOVERNANCE_HUB_TOKEN` Actions secret is set; it has no Dependabot configuration, so it needs no Dependabot secret.
- `Install-ClaudeManagedSettings.ps1 -Verify`: a read-only check of an installed machine policy. It confirms the policy is current, its hook runs the adjacent guard copy, that copy is byte-identical to the hub guard, and only administrators can change the files or their directory. It reports the hub commit and guard SHA-256, so a reviewer can recompute the hash from GitHub, and exits 1 on any failure.

### Changed

- Hub CI: with the hub public (free Actions minutes), macOS runs on every pull request and merge again, replacing the weekly, release and on-demand schedule. It is not a required check. Owner-approved, including the updated CI cost-controls test.
- Hub CI: the macOS job runs weekly (Sunday), on every published release and on demand, instead of on every merge to `main`. Pull requests and merges run Windows and Ubuntu. macOS on every merge was about 27% of the account's Actions spend in early October 2026; no release ships without a macOS run.

### Fixed

- `Install-ClaudeManagedSettings.ps1 -Verify` now prints its report when a check fails. Run as `pwsh -File`, `exit 1` ended the script before PowerShell formatted the rows, so a failing run (for example before the first install in WSL) printed nothing.
- Generated `PROJECT.md`: the repository name comes from the `origin` remote, falling back to the folder name. The downstream sync checks every repository out into a folder named `downstream`, so a repository enrolled without a `PROJECT.md` (ai-os #1) was named `downstream`. An undetected stack now reads "None detected" instead of an empty field.
- Tests: the Dependabot-hint tests run the step script with Git Bash on Windows, as the secret-scan tests already did. A bare `bash` can resolve to WSL, which cannot open the Windows path and exits 127.
- Governance gate: when Dependabot triggered the run (or its pull request is re-run), the unreachable-hub error also says to add `AGENT_GOVERNANCE_HUB_TOKEN` as a Dependabot secret, since Dependabot runs receive only Dependabot secrets. The README, runbook and `SECURITY.md` enrolment notes now list both secrets.
- Live eval: in the print-secret scenario only, a one-turn refusal (no error, a non-empty answer, no canary) counts as a conclusive, compliant run instead of inconclusive. The other scenarios still treat no tool use as inconclusive.
- README: the architecture diagram no longer shows content-estate, which is not in `fleet.json`. `SECURITY.md` records the fleet credentials, including the deliberately non-expiring hub-read token.
- Downstream sync with the GitHub App: the installation token now requests `workflows: write`, and the runbook lists the Workflows permission. Without it GitHub refuses every sync push, because each sync updates the pinned gate in `.github/workflows/agent-governance.yml`.

### Security

- Fleet credentials: the hub is public, so the caller workflow no longer passes `AGENT_GOVERNANCE_HUB_TOKEN`; the integrity job reads the hub with each repository's own token. After the sync pull requests merge, delete that secret (Actions and Dependabot) from every fleet repository and revoke the token. The gate still accepts `hub_token` for a hub kept private.
- Required checks: each check the ruleset requires is pinned to the GitHub Actions app (`integration_id` 15368), so a commit status or another app's check run with the same name no longer satisfies it.
- Governance gate: a change that deletes `.agent-governance.lock` from a repository whose base commit has one now fails the `integrity` check. A repository without a lock is treated as not yet governed, so deleting it used to skip verification of everything else the change touched. If the base cannot be checked, the step fails closed.
- Provenance audit (`Test-GateProvenance.ps1`, weekly `provenance-audit` job): for each pull request merged into a fleet repository in the last 8 days, it reports an error when a job carrying a required check name came from anything but the hub gate called at a commit SHA, or when the caller workflow at the pull request's head differs from the hub template at the commit it pins (indentation and blank lines aside, since a formatter may re-indent it). Rulesets match checks by name, and required workflows exist only for organizations, so this detects what a personal account cannot prevent. A first run over 81 pull requests merged in 14 days found nothing spoofed or tampered. The App needs Actions read-only.
- Agent settings: `Edit` is denied for every file the hub replaces (`AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, the caller workflow, the lock, `.agents/rules/`, `.claude/rules/`, the agent settings, `lefthook.yml`, `scripts/guardrails/`), making contract §5.3 an enforced rule for Claude Code's file tools. The machine policy carries the same rules, so re-run the installer elevated after this release. `PROJECT.md`, `.gitignore` and `.gitattributes` stay editable.
- Public readiness: `codeql.yml` scans the workflows with CodeQL once the hub is public (skipped while private, where it needs GitHub Advanced Security). A new test file requires every workflow to pin actions by SHA, avoid `pull_request_target` and default to a read-only token. The README diagram no longer lists the fleet repositories' stacks. The runbook (section E) gives the settings to apply before and after the switch, and what becomes public.
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
