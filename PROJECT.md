# Project Specification & Architecture: agent-governance

This repository maintains the canonical multi-agent governance standards, deterministic guardrails, and distribution automation for all software repositories.

---

## 1. Project Overview & Tech Stack

- **Repository Name:** agent-governance
- **Detected Stack:** PowerShell Distribution Engine + Shell Hook Wrappers + Markdown Domain Specs
- **Primary Tools:** Lefthook (v2.1.14), Gitleaks (v8.30.1), PowerShell 7+
- **Target Platforms:** Windows, Linux, macOS (plain-file distribution; legacy NTFS link migration on Windows)

---

## 2. Development Runbook & Commands

- **Inspect Hub Status:** `Sync-AgentGovernance status`
- **Run CLI Help:** `Sync-AgentGovernance -h`
- **Test All Downstream Repos (Dry-Run):** `Sync-AgentGovernance audit -a`
- **Validate Guardrail Scripts:** `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`
- **Run Test Suite:** `Invoke-Pester ./tests` (Pester 6.2.0; legacy links use junctions on Windows and symlinks on Unix)
- **Preview Distribution:** `Sync-AgentGovernance -RepoPath <path> -WhatIf`
- **Verify Distributed Integrity:** `pwsh -NoProfile -File scripts/guardrails/verify-governance.ps1` (see README for trusted-template verification)
- **Refresh the Hub's Own Lock (after editing `template/`):** `Sync-AgentGovernance -RepoPath .` from the hub root, then commit the root copies and `.agent-governance.lock`
- **Run the Policy-Coverage Eval:** `pwsh -NoProfile -File evals/Invoke-PolicyEval.ps1`
- **Install Machine-Level Claude Code Policy:** `sudo pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1` (preview with `-WhatIf`)
- **Check Pinned Tool Versions:** `./Test-ToolchainFreshness.ps1` (needs `gh`; pass `-LatestJson` offline)

---

## 3. Key Directories & Architecture Map

- `template/`: The source-of-truth governance assets deployed to downstream repositories.
  - `template/AGENTS.md`: Canonical lean operating contract (<80 lines).
  - `template/.agents/rules/`: Always-loaded `languages.md` index and `security-performance.md`, plus path-scoped `lang-*.md` rules.
  - `template/scripts/guardrails/`: Deterministic security scripts executed by Lefthook.
  - `template/lefthook.yml`: Deterministic hook configuration.
  - `template/.github/workflows/agent-governance.yml`: Caller workflow for the governance gate; sync renders it with the hub repository and pushed hub commit.
  - `template/.codex/config.toml`, `template/.gemini/settings.json`: Codex and Gemini CLI agent settings (managed while unmodified).
  - `template/.claude/settings.json`: Claude Code secret deny rules, native Bash deny rules for hook-bypass forms, OS sandbox (registry allowlist, credential denies) and the PreToolUse Bash guard (managed while unmodified).
- `Sync-AgentGovernance.ps1`: The orchestration and reconciliation engine. Run against the hub root itself to refresh the hub's root copies and `.agent-governance.lock` (no caller workflow is written for the hub).
- `.agent-governance.lock` (hub root): The hub's own lock; the governance gate verifies the root copies against `template/` with it and fails when it is missing.
- `managed/claude-code-managed-settings.json` + `Install-ClaudeManagedSettings.ps1`: Machine-level Claude Code policy (same deny rules and sandbox as the template, guard hook pointed at the hub's copy, bypass mode off) installed to the OS managed-settings location.
- `Invoke-DownstreamSync.ps1` + `.github/workflows/downstream-sync.yml`: reusable workflow that a private operations repository calls weekly, with the fleet list and pinned to a hub release commit, to open re-sync pull requests, apply rulesets, audit gate provenance and report toolchain freshness (a GitHub App via the `app_client_id` input and `AGENT_GOVERNANCE_APP_PRIVATE_KEY` secret, else `AGENT_GOVERNANCE_SYNC_TOKEN`).
- `Test-ToolchainFreshness.ps1`: Compares the pinned Pester, PSScriptAnalyzer, Prettier, Gitleaks and Lefthook versions with the latest releases (advisory; `-FailOnStale` to gate).
- `Set-GovernanceRuleset.ps1` + `rulesets/`: Server-side default-branch ruleset (non-bypassable layer). Dry-run first: `./Set-GovernanceRuleset.ps1 -Repository owner/name -WhatIf`.
- `.github/workflows/governance-gate.yml`: Reusable CI gate (Gitleaks, PR branch policy, lock integrity against the hub; hub mode when the caller is the hub itself; optional `hub_token` secret for a private hub) for downstream repositories to call by commit SHA.
- `.github/dependabot.yml`: Weekly updates for the SHA-pinned GitHub Actions.
- `tests/`: Pester suite for the engine, guardrails, enforcement layers, hub dogfooding, agent-session gate and managed settings.
- `evals/`: Policy-coverage eval (deterministic, in CI via `tests/Evals.Tests.ps1`; 36 blocked / 19 allowed scenarios including the 2026-10-01 red-team variants) and an opt-in, sandbox-only live agent eval.
- `docs/adr/`: Architecture decision records (`0001`: sync engine over Copier; `0002`: no CODEOWNERS for a solo maintainer, updated for GitHub Pro; `0003`: defence in depth for the command guard).
- `SECURITY.md`, `CHANGELOG.md`: Vulnerability reporting policy and the dated change log.
- `docs/runbooks/opt-in-rollout.md`: Machine-policy install, GitHub App setup and fleet follow-up, with a prompt for a local agent.
- `WORKING.md`: Ephemeral session continuity ledger (local working memory, shielded from git).
- `.agents/state/`: Branch-grounded state archive for multi-branch session persistence.
