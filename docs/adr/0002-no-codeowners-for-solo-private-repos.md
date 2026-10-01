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

## Update 2026-10-01: the account is on GitHub Pro

The plan premise above no longer holds: the account moved to GitHub Pro, where rulesets, branch protection and CODEOWNERS all apply to private repositories. The weekly fleet workflow has since applied the default-branch ruleset to the hub (verified on 2026-10-01) and applies it to every fleet repository. The decision itself is unchanged because the second condition still holds: with one maintainer, a required code-owner review would block every pull request they open. The hub-managed files remain protected by the governance gate's integrity job, which the ruleset now requires.

## Revisit when

- A second maintainer joins. The plan already supports code owners for private repositories.
