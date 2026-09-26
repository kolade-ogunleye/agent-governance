# Project Specification & Architecture: agent-governance

This repository maintains the canonical multi-agent governance standards, deterministic guardrails, and distribution automation for all software repositories.

---

## 1. Project Overview & Tech Stack

- **Repository Name:** agent-governance
- **Detected Stack:** PowerShell Distribution Engine + Shell Hook Wrappers + Markdown Domain Specs
- **Primary Tools:** Lefthook (v2.1.14), Gitleaks (v8.30.1), PowerShell 7+
- **Target Platforms:** Windows (NTFS Hardlinks & Junctions), Linux, macOS (Git Bash / POSIX sh)

---

## 2. Development Runbook & Commands

- **Inspect Hub Status:** `Sync-AgentGovernance status`
- **Run CLI Help:** `Sync-AgentGovernance -h`
- **Test All Downstream Repos (Dry-Run):** `Sync-AgentGovernance audit -a`
- **Validate Guardrail Scripts:** `Invoke-ScriptAnalyzer -Path . -Recurse`

---

## 3. Key Directories & Architecture Map

- `template/`: The source-of-truth governance assets deployed to downstream repositories.
  - `template/AGENTS.md`: Canonical lean operating contract (<80 lines).
  - `template/.agents/rules/`: Progressive Disclosure domain rules (`languages.md`, `security-performance.md`).
  - `template/scripts/guardrails/`: Deterministic security scripts executed by Lefthook.
  - `template/lefthook.yml`: Deterministic hook configuration.
- `Sync-AgentGovernance.ps1`: The orchestration and reconciliation engine.
- `WORKING.md`: Ephemeral session continuity ledger (local working memory, shielded from git).
- `.agents/state/`: Branch-grounded state archive for multi-branch session persistence.
