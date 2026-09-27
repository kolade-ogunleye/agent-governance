# 🛡️ Agent Governance

> **Enterprise-Grade Multi-Agent Governance, Deterministic Guardrails, and Context Architecture for Autonomous AI Coding Agents.**

`agent-governance` establishes a synchronized hub-and-spoke governance engine across software repositories. It enforces RFC 2119 operational contracts, deterministic pre-commit/pre-push guardrails (via Lefthook and Gitleaks), Progressive Disclosure domain constraints, and automated hub-to-repo drift detection—without token bloat or attention degradation.

---

## 🏛️ Architecture Overview

```mermaid
flowchart TD
    Hub["🏛️ Central Governance Hub<br>(agent-governance)"] -->|Sync-AgentGovernance| R1["📦 infosecbyomokolade.com<br>(WordPress / PHP / npm)"]
    Hub -->|Sync-AgentGovernance| R2["📦 content-estate<br>(Python uv / Node pnpm)"]
    Hub -->|Sync-AgentGovernance| R3["📦 hybrid-network-security<br>(Ansible / PowerShell IaC)"]
    Hub -->|Sync-AgentGovernance| RN["📦 Other Repositories..."]

    subgraph HubContent["Canonical Assets & Engine"]
        T_AGENTS["AGENTS.md (Universal Contract <80 lines)"]
        T_RULES[".agents/rules/ (Progressive Disclosure)"]
        T_GUARDS["scripts/guardrails/ (Lefthook + Gitleaks)"]
        T_ENGINE["Sync-AgentGovernance.ps1 (Reconciliation Engine)"]
    end

    subgraph Guardrails["Deterministic Execution Plane"]
        G_MAIN["protect-main (Branch semantic state machine)"]
        G_SECRETS["detect-secrets (Gitleaks real-time scanning)"]
        G_TESTS["guard-tests (Anti-tampering test protector)"]
        G_DRIFT["check-drift (Hub vs Repo SHA256 sync check)"]
        G_SUPPLY["audit-dependencies (Lockfile-aware CVE audit)"]
        G_RUNNER["run-tests (Lockfile-aware test runner)"]
    end
```

---

## 🚀 Quickstart & CLI Reference

The engine is loaded into your PowerShell profile (`$PROFILE`) and provides rich subcommands and short parameter switches.

### CLI Syntax:

```powershell
Sync-AgentGovernance [[-Action] <sync|audit|status|help>]
                     [-RepoPath|-r <path>]
                     [-All|-a]
                     [-AuditOnly|-m]
                     [-BranchAndCommit|-c]
                     [-Help|-h|-?]
```

### Subcommands & Common Commands:

| Command                            | Short Alias                             | Description                                                           |
| :--------------------------------- | :-------------------------------------- | :-------------------------------------------------------------------- |
| `Sync-AgentGovernance`             | `Sync-AgentGovernance sync`             | Reconciles governance in current directory.                           |
| `Sync-AgentGovernance -h`          | `Sync-AgentGovernance help`             | Displays the interactive CLI reference manual.                        |
| `Sync-AgentGovernance status`      | —                                       | Inspects Central Hub health, active rules, and guardrails.            |
| `Sync-AgentGovernance audit -a`    | `Sync-AgentGovernance -All -AuditOnly`  | Performs a read-only audit across all repositories.                   |
| `Sync-AgentGovernance -r <dir> -c` | `Sync-AgentGovernance -BranchAndCommit` | Syncs target repo, branches to `chore/agent-governance`, and commits. |
| `Sync-AgentGovernance -a -c`       | —                                       | Fleet-wide safe sync and automated commit across all clean repos.     |

---

## ⚡ Core Capabilities

### 1. The Lean Universal Contract & Dual-Contract Layering

- Root [`AGENTS.md`](template/AGENTS.md) is kept ultra-lean (<80 lines) to prevent context diffusion and token exhaustion.
- **Precedence:** Universal operating rules (branch semantics, conventional commits, secret shielding, test anti-tampering) hold absolute veto power.
- **Domain Memory:** Pre-existing custom agent instructions in existing repositories are automatically archived into `docs/LEGACY-AGENT-NOTES.md` and cited as mandatory domain logic in `PROJECT.md`.

### 2. Intelligent Git Hook Chaining

- Detects custom `core.hooksPath` configurations (e.g. `.githooks/` or `.husky/`).
- Scans backward from terminal `exit 0` statements and inserts Lefthook chains non-destructively.
- Automatically resolves external hook paths to keep repositories strictly isolated.

### 3. Automated Hub Drift Detection

- Pre-commit checks SHA256 hashes of local rules against the Central Hub.
- If updates are committed to `agent-governance`, downstream repositories immediately notify developers:
  ```
  ⚡ [Agent Governance] Local repository rules have drifted from the Central Hub.
     Run 'Sync-AgentGovernance' to synchronize with latest corporate standards.
  ```

### 4. Lockfile-Aware Polyglot Detection

- Inspects repository manifests (`package.json`, `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`, `pyproject.toml`, `uv.lock`, `Cargo.toml`, `go.mod`, `ansible/`, `*.ps1`).
- Tailors `PROJECT.md` runbooks and executes exact project-native package managers during supply-chain audits and test runs.

### 5. Session Continuity & Write-Ahead Ledgers (`WORKING.md`)

- Solves multi-agent context loss, turn compaction, and context-window degradation without polluting commit logs.
- Ephemeral task ledgers (`WORKING.md`) track pre-flight branch/HEAD hashes, verification commands, and `next_action` checkpoints.
- Strict git shielding (`.gitignore` + `protect-main.ps1`) prevents `WORKING.md` from ever being committed to source control.
- Completed tasks archive ephemeral state before removal, keeping permanent handover invariant intact.

### 6. Anti-Regression Triad Hierarchy

- Synchronizes permanent institutional memory alongside lean universal contracts.
- Categorizes repository knowledge into three distinct precedence tiers in `PROJECT.md` Section 0:
  1. `[!IMPORTANT]` **Operational Handover Spec:** (`HANDOVER.md` / `docs/CURRENT-STATE.md`) authoritative system architecture and domain models.
  2. `[!WARNING]` **Anti-Regression Lessons Learned:** (`LESSONS_LEARNED.md` / `TRAPS.md`) real-world architectural traps and hard-won postmortems.
  3. `[!NOTE]` **Archived Legacy Agent Instructions:** (`docs/LEGACY-AGENT-NOTES.md`) preserved instructions prior to governance adoption.

---

## 📄 License

MIT License.
