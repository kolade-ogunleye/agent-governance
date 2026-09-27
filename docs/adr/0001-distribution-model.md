# ADR 0001: Keep the PowerShell sync engine; do not adopt Copier yet

- Status: Accepted
- Date: 2026-09-27

## Context

The hub distributes governance files into many repositories. The original engine overwrote managed files and archived custom content only on the first sync, which lost team edits made later (plan defect 7). Copier was considered because `copier update` performs a three-way merge between the previous template version, the new template version, and local edits.

## Decision

Keep `Sync-AgentGovernance.ps1` as the distribution mechanism and close the data-loss gap with the lock manifest instead of adopting Copier now.

- Each sync writes `.agent-governance.lock` with the hub commit and a normalized SHA-256 digest per managed file.
- On the next sync, a managed file whose digest no longer matches the lock was edited by the team, so its content is archived to `docs/LEGACY-AGENT-NOTES.md` before replacement.
- Team-owned files (`PROJECT.md`, `.claude/settings.json`, `.gemini/settings.json`) are created only when absent and never overwritten.

## Consequences

- No new runtime dependency: the engine needs only PowerShell 7 and Git, which every governed repository already uses. Copier would add Python and Copier to every workstation and CI image, which the dependency gate in `AGENTS.md` requires approving separately.
- Team edits to managed files are preserved, but by archiving rather than merging. A reviewer must fold archived notes back into `PROJECT.md` by hand.
- The template stays plain files with no Jinja syntax, so the hub dogfoods it directly.

## Revisit when

- More than a few repositories need per-repository variations of managed files, where true three-way merging would save review time.
- Templated values beyond the generated `PROJECT.md` become necessary.
