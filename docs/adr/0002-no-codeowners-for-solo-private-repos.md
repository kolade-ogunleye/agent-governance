# ADR 0002: Do not ship CODEOWNERS while the fleet is solo-maintained and private on GitHub Free

- Status: Accepted
- Date: 2026-09-27

## Context

CODEOWNERS was considered as a way to require the hub owner's review for changes to hub-managed files (`scripts/guardrails/`, `.agents/rules/`, `lefthook.yml`, `.agent-governance.lock`, agent settings).

GitHub's documentation states that code owners are available in public repositories on GitHub Free, and in public and private repositories on GitHub Pro, Team, and Enterprise. The fleet is private on GitHub Free. Required code-owner review is also enforced only through a ruleset or branch protection, and a pull request author cannot approve their own pull request.

## Decision

Do not ship CODEOWNERS files from the hub for now.

## Consequences

- On the current plan a CODEOWNERS file would have no effect.
- After an upgrade, requiring code-owner review would block a sole maintainer from merging their own pull requests, so it must not be enabled until there is a second reviewer.
- Tampering with hub-managed files is detected instead by the governance gate's integrity job and the lock manifest.

## Revisit when

- A second maintainer joins, and the fleet is on a plan that supports code owners for private repositories.
