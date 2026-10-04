# Security Policy

## Scope

This repository distributes the agent operating contract, guardrail scripts, CI gate and agent settings to the governed repositories. A weakness here propagates to every downstream repository on the next sync, so reports are treated as high priority.

## Reporting a vulnerability

- Use GitHub's private vulnerability reporting on this repository (Security tab, "Report a vulnerability"). If that option is not enabled, open a draft security advisory or contact the maintainer through the GitHub profile; do not open a public issue for a security problem.
- Include the affected file, the commit SHA you tested, and a reproduction. For guard or hook bypasses, the exact command text the agent would write is the most useful evidence.

## What counts

- A way for an agent to commit, push or disable hooks that the documented enforcement layers claim to block, other than the accepted misses listed in `docs/adr/0003-command-guard-defence-in-depth.md`.
- A way to make a downstream repository pass the governance gate's integrity job with tampered managed files.
- Secret exposure through the sync workflow, the eval harnesses, or the generated files.

## Supported versions

Only the `main` branch is maintained. Downstream repositories pin the hub by commit SHA; the integrity job warns when the pin is 30 days behind the hub and fails at 90 days, so a fix reaches the fleet through the weekly sync pull requests within that window.

## Credentials

- **Fleet sync:** a GitHub App (`AGENT_GOVERNANCE_APP_CLIENT_ID` variable, `AGENT_GOVERNANCE_APP_PRIVATE_KEY` secret, hub only). Each job mints a short-lived installation token scoped to one repository and to the permissions it needs, revoked when the job ends.
- **Hub read access for the integrity job:** a fine-grained personal access token, `AGENT_GOVERNANCE_HUB_TOKEN` in each fleet repository, with Contents read-only on this repository only. It is **deliberately non-expiring** (owner decision, 2026-10-04): a leak exposes only this repository's source, which holds no secrets, and an expired token would fail every fleet repository's required check. Rotate it if it may have leaked, or if its scope ever needs widening. The integrity job fails, rather than skipping verification, when the token is missing or invalid.

## Hardening expectations for contributors

- Pin every GitHub Action to a full commit SHA and every downloaded tool to a version and checksum.
- Never interpolate caller-controlled values (branch names, inputs, lock contents) into workflow scripts; pass them through environment variables.
- Add a scenario to `evals/policy-scenarios.json` for every new guard rule, with a look-alike legitimate command beside it.
