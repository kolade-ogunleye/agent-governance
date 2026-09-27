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

---

## 3. Key Directories & Architecture Map

- `template/`: The source-of-truth governance assets deployed to downstream repositories.
  - `template/AGENTS.md`: Canonical lean operating contract (<80 lines).
  - `template/.agents/rules/`: Always-loaded `languages.md` index and `security-performance.md`, plus path-scoped `lang-*.md` rules.
  - `template/scripts/guardrails/`: Deterministic security scripts executed by Lefthook.
  - `template/lefthook.yml`: Deterministic hook configuration.
  - `template/.github/workflows/agent-governance.yml`: Caller workflow for the governance gate; sync renders it with the hub repository and pushed hub commit.
  - `template/.claude/settings.json`: Claude Code secret deny rules + PreToolUse Bash guard (deployed only when a repo has none).
- `Sync-AgentGovernance.ps1`: The orchestration and reconciliation engine.
- `Set-GovernanceRuleset.ps1` + `rulesets/`: Server-side default-branch ruleset (non-bypassable layer). Dry-run first: `./Set-GovernanceRuleset.ps1 -Repository owner/name -WhatIf`.
- `.github/workflows/governance-gate.yml`: Reusable CI gate (full-history Gitleaks, PR branch policy, lock integrity against the hub; optional `hub_token` secret for a private hub) for downstream repositories to call by commit SHA.
- `tests/`: Pester suite for the engine, guardrails, and enforcement layers.
- `docs/adr/`: Architecture decision records (e.g. `0001-distribution-model.md`: why the sync engine is kept over Copier).
- `WORKING.md`: Ephemeral session continuity ledger (local working memory, shielded from git).
- `.agents/state/`: Branch-grounded state archive for multi-branch session persistence.
