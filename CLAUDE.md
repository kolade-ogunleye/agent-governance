# Repository Agent Operating Contract (RFC 2119)

## 1. PRE-FLIGHT VERIFICATION & SEMANTIC STATE MACHINE

1. **Branch Isolation & Intent Categorization:** You MUST NOT commit directly to `main` or `master`.
   - Run `git branch --show-current`.
   - **Idempotency Rule:** If the current branch already matches an allowed semantic prefix (`feat/`, `fix/`, `patch/`, `hotfix/`, `refactor/`, `chore/`, `test/`), REMAIN on that branch.
   - **Branching Rule:** If on `main`, `master`, or an unclassified branch, you MUST categorize the task intent and checkout an appropriately prefixed branch before modifying any file:
     - Bug fix / defect / regression: `git checkout -b fix/<task-slug>`
     - Urgent hotfix / security patch: `git checkout -b patch/<task-slug>`
     - New feature / capability: `git checkout -b feat/<task-slug>`
     - Refactoring (no behavior change): `git checkout -b refactor/<task-slug>`
     - Maintenance / tooling / dependencies: `git checkout -b chore/<task-slug>`
     - Test-only additions / fixes: `git checkout -b test/<task-slug>`
2. **Synchronized Conventional Commits:** All commit messages MUST strictly reflect the task type using Conventional Commits 1.0.0 format: `<type>(<optional-scope>): <description>`.
3. **Tree Cleanliness:** You MUST run `git status --porcelain`. If output is non-empty from uncommitted work, you MUST HALT and request user instruction to stash or commit.
4. **Guardrail Check:** Ensure the git `pre-commit` hook contains the `# >>> agent-governance` block. If missing, run `Sync-AgentGovernance`. You MUST NOT run `lefthook install`, which replaces the fail-closed governance gate.

## 2. ADVERSARIAL RED-TEAM INVERSION (BEFORE ANY CODE EDIT)

Before modifying any files or presenting your plan, you MUST adopt a **Devil's Advocate Auditor** persona and document:

- **Failure Mode 1:** One concrete boundary condition or edge case (nulls, empty states, race conditions) that could break this implementation.
- **Failure Mode 2:** One scenario where callers, integrations, or downstream consumers could silently break.
- **Rollback & Blast Radius:** The exact command to revert this change cleanly if it fails in production.
- _Notice:_ Superficial self-praise ("the plan has zero risk") is strictly forbidden.

## 3. PROJECT CONTEXT & LAYERED ARCHITECTURE

1. **Project Specification:** Before undertaking work, you MUST read `PROJECT.md` at the repository root for repository-specific architecture, tech stack, build commands, and test targets.
2. **Precedence & Dual-Contract:** Universal operating rules in this contract ALWAYS take absolute precedence over repository-specific instructions in case of conflict. However, domain instructions (e.g. in `PROJECT.md`, `HANDOVER.md`, `LESSONS_LEARNED.md`, or `docs/LEGACY-AGENT-NOTES.md`) retain authoritative control over application business logic, domain models, workflows, and task sequencing. Agents MUST cite both universal standards and domain-specific notes in their implementation plan.

## 4. PROGRESSIVE DISCLOSURE & MANDATORY CITATION GATE

Before generating, modifying, or refactoring code in any language, you MUST load the relevant domain rules and cite their specific requirements in your plan:

- **Language Standards:** Read and cite `.agents/rules/languages.md` (strict type safety, zero `any`, `dataclasses`/`pydantic`, 100% parameterized SQL, async non-blocking I/O).
- **Security & Performance:** Read and cite `.agents/rules/security-performance.md` (untrusted data-plane quarantine, latest stable/LTS packages only, anti-hallucination grounding, memory streaming, $O(n)$ algorithmic baseline).

## 5. DEPENDENCY & TEST INTEGRITY (ANTI-TAMPERING)

1. **Test Anti-Tampering:** You MUST NOT delete existing test files, comment out assertions, or alter expected values in existing baseline tests to force a pass. Bug fixes and features MUST be validated by adding _new_ assertions and test cases.
2. **Dependency Gate:** You MUST NOT install global binaries (`npm -g`, `pip install --user`). You may propose project dev-dependencies (`pnpm add -D`, `uv add --dev`), but you MUST update lockfiles and obtain explicit user approval before network installation.

## 6. SECURITY & CONTEXT BOUNDARIES

1. **Scope Limit:** All operations MUST remain strictly within this repository root. NEVER inspect or access `~/.ssh`, `~/.aws`, `~/.gnupg`, or parent directories.
2. **Secret Shield:** NEVER read, edit, print, or commit `.env*`, private keys (`.pem`, `.key`, `.id_*`), certificates, or tokens.

## 7. DEFINITION OF DONE (MANDATORY GATE)

Before declaring any task complete, you MUST execute and report the output of:

1. `git diff --stat` — verify only requested files were touched.
2. Linters & Type Checks (e.g., `pnpm run lint` / `ruff check` / `tsc --noEmit`) — 0 errors required.
3. Unit & Integration Tests (e.g., `pnpm test` / `pytest`) — 100% pass required.

## 8. SESSION CONTINUITY & WRITE-AHEAD CHECKPOINTING (RFC 2119)

1. **Pre-Flight Ledger Grounding:** At the start of every session, the agent MUST inspect the repository root for `WORKING.md`.
   - **Branch & Head Validation:** Compare `active_branch` and `base_commit` against `git branch --show-current` and `git rev-parse --short HEAD`.
   - **Branch Divergence Handling:** If `active_branch` does not match the current branch, archive `WORKING.md` to `.agents/state/<active_branch>.md` and restore `.agents/state/<current_branch>.md` (or initialize a fresh ledger).
   - **Stale State Handling:** If `base_commit` does not match current `HEAD`, verify uncommitted working tree state before taking action.
2. **Write-Ahead Ledger Updates:** For any multi-step task (>2 operations), the agent MUST maintain and update `WORKING.md` before pausing turns, switching major implementation phases, or when quota exhaustion is possible:
   - Document completed milestones with passing verification commands.
   - Record exact in-flight file state and uncommitted changes.
   - Record the precise `next_action` command for the successor agent.
3. **Definition of Done Cleanup:** Upon successfully passing all lint/test gates and completing the task, the agent MUST remove `WORKING.md` (or mark `session_status: COMPLETED` and archive it) so stale state does not persist into future tasks.
4. **Permanent Handover Invariant:** Permanent, committed architecture documentation (e.g., `HANDOVER.md`, `docs/CURRENT-STATE.md` indexed in `PROJECT.md`) MUST NEVER be confused with or overwritten by ephemeral task ledgers. Only `WORKING.md` serves as the local, task-scoped checkpoint.
