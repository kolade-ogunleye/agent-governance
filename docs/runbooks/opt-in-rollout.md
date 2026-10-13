# Runbook: opt-in rollout (machine policy, GitHub App, fleet follow-up)

Three steps are deliberately not automated by the hub: two need a human's administrator rights or browser session, one needs a decision about timing. This runbook gives the exact commands for each, and a prompt to hand to a coding agent running on a workstation with a clone of the hub.

## A. Machine-level Claude Code policy (every workstation)

The installer copies this hub's Bash guard into the managed-settings directory, renders `managed/claude-code-managed-settings.json` with the absolute path of that copy, and writes it beside the guard. Only an administrator can write that directory, so neither the policy nor the guard it runs can be changed by an agent or by anything running as you. A guard change in the hub reaches this machine only when you re-run the installer elevated; do that after each hub release that changes `template/scripts/guardrails/agent-bash-guard.ps1`.

| Platform    | Command (from the hub clone)                                                       |
| :---------- | :--------------------------------------------------------------------------------- |
| Linux, WSL2 | `sudo pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1`                   |
| macOS       | `sudo pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1`                   |
| Windows     | Elevated PowerShell 7: `pwsh -NoProfile -File .\Install-ClaudeManagedSettings.ps1` |

Preview with `-WhatIf`, remove with `-Remove`. Verify inside Claude Code with `/status`: the `Setting sources` line names the managed file. On WSL2, Windows-side policy takes precedence when both exist (`wslInheritsWindowsSettings`), so install on the side where Claude Code runs.

### Verify an installed policy (anyone, no administrator rights)

```powershell
pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1 -Verify
```

It changes nothing, prints one row per check, and exits 1 if any check fails:

- the policy is installed, and equals what this hub would install now;
- its hook runs the guard copy beside it;
- that copy is byte-identical to this hub's guard;
- only administrators can change the policy, the guard, or their directory. On Windows that means SYSTEM, Administrators and TrustedInstaller, checked by SID. On Linux and macOS it means root, with no group or other write.

The summary row names the hub commit and the guard's SHA-256. Run it after every hub release that changes `template/scripts/guardrails/agent-bash-guard.ps1`: a failing identity check means re-run the installer elevated.

**For a reviewer who cannot see the workstation:** ask the owner for the `-Verify` output, then check three things yourself.

1. The summary says `9/9 passed`, and the first row shows the hub clone unmodified.
2. The hub commit is on `main`, and is the release you expect.
3. The guard hash matches GitHub's copy at that commit:

   ```bash
   gh api "repos/<owner>/agent-governance/contents/template/scripts/guardrails/agent-bash-guard.ps1?ref=<hub commit>"      -H "Accept: application/vnd.github.raw" | sha256sum
   ```

The first two rely on the output being honest. The third is independent: the guard on the machine is byte-for-byte the reviewed guard at a known commit. The output is evidence the owner supplies, not an attestation. A reviewer who needs stronger assurance can watch it run, for example in a screen share.

What the policy enforces that a project file cannot: bypass mode is off, the deny rules and the guard hook cannot be removed by `.claude/settings.local.json`, and the guard runs from an administrator-only copy rather than the repository's or the hub clone's.

## B. GitHub App for the fleet sync (replaces the personal access token)

### Human steps (browser)

1. GitHub → Settings → Developer settings → GitHub Apps → New GitHub App.
2. Name: `agent-governance-sync` (any unused name). Homepage URL: the hub repository URL. Webhook: untick Active.
3. Repository permissions: Contents (Read and write), Workflows (Read and write: every sync updates the pinned gate in `.github/workflows/agent-governance.yml`, and GitHub refuses that push without it), Pull requests (Read and write), Issues (Read and write, for the label and assignee), Administration (Read and write, for rulesets), Actions (Read-only, for the weekly provenance audit of merged pull requests), Metadata (Read, selected automatically). After adding a permission to an existing App, accept the updated permissions on its installation (Settings → Applications → Installed GitHub Apps → Configure).
4. "Where can this GitHub App be installed?": Only on this account. Create the app.
5. On the app page, note the **Client ID**. Under Private keys, Generate a private key; a `.pem` file downloads.
6. Install App → your account → Only select repositories → the hub and every repository in the operations repository's fleet list.

### Agent-runnable steps (gh CLI, authenticated as the account owner)

```powershell
# <client-id> is the value from step 5; <path-to-pem> the downloaded key. The App credentials live in the private
# operations repository, which calls the hub's reusable sync workflow (section F).
gh variable set AGENT_GOVERNANCE_APP_CLIENT_ID --repo kolade-ogunleye/governance-ops --body "<client-id>"
gh secret set AGENT_GOVERNANCE_APP_PRIVATE_KEY --repo kolade-ogunleye/governance-ops < "<path-to-pem>"

# Prove the App path works: run the sync on demand and read the step "Resolve the sync credential" (source=app).
gh workflow run sync.yml --repo kolade-ogunleye/governance-ops
gh run watch --repo kolade-ogunleye/governance-ops
```

Delete the downloaded `.pem` once the secret is stored. The fleet repositories need no hub credential: the hub is public, and the integrity job reads it with each repository's own token. (A private hub would need a read-only `AGENT_GOVERNANCE_HUB_TOKEN` passed as the gate's `hub_token`, stored as an Actions secret and, where Dependabot runs, as a Dependabot secret.)

## C. Fleet follow-up after a hub change merges

1. The fleet receives hub changes only through a release (section F). After the release bump merges in `governance-ops`, dispatch its sync (`gh workflow run sync.yml --repo <owner>/governance-ops`) or wait for the Monday run; one pull request per fleet repository opens.
2. Review and merge each sync pull request within 30 days (the integrity job warns at 30 and fails at 90).
3. Confirm enforcement: `./Set-GovernanceRuleset.ps1 -Repository <owner/name> -WhatIf`, or `gh api repos/<owner/name>/rulesets`. On GitHub Pro the ruleset applies to private repositories.
4. Install the local git gate in each clone that has none: `Sync-AgentGovernance hooks -RepoPath <clone>`.

## E. Making the hub public (engine public, operations private)

Actions minutes are free on public repositories, and a public hub needs no read token in the fleet. Operations stay private: the fleet list, the sync and the provenance audit move to a private `governance-ops` repository. A public repository's workflow logs are public, and GitHub disables its scheduled workflows after 60 days without commits; neither affects a private repository.

What becomes public, permanently (forks and caches outlive a switch back): the engine, templates, guard and its accepted misses, the eval scenarios, and the full history and pull request threads, including older mentions of the fleet repositories' names and stacks. Nothing in the history is a secret (full-history Gitleaks scan, 2026-10-11) and commit emails are GitHub no-reply addresses.

Before the switch (private repositories accept these):

```powershell
gh api --method PUT repos/<owner>/agent-governance/vulnerability-alerts
gh api --method PUT repos/<owner>/agent-governance/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```

Switch: Settings → General → Danger Zone → Change visibility → Public.

After the switch (public repositories only):

```powershell
# Workflows on pull requests from forks wait for approval, whoever opens them.
gh api --method PUT repos/<owner>/agent-governance/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
gh api --method PUT repos/<owner>/agent-governance/private-vulnerability-reporting
gh api --method PATCH repos/<owner>/agent-governance --input - <<'EOF'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
EOF
```

`.github/workflows/codeql.yml` (code scanning of the workflows) starts running by itself once the repository is public; while private it skips.

## F. Releases and the operations repository

The fleet moves only when the hub releases. The private `governance-ops` repository holds the fleet list and a weekly caller pinned to a release commit:

```yaml
# governance-ops/.github/workflows/sync.yml
on:
  schedule: [{ cron: "43 5 * * 1" }]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  sync:
    uses: <owner>/agent-governance/.github/workflows/downstream-sync.yml@<release-commit-sha> # v1.4.0
    with:
      fleet: '["<owner>/repo-one", "<owner>/repo-two"]'
      app_client_id: ${{ vars.AGENT_GOVERNANCE_APP_CLIENT_ID }}
    secrets:
      AGENT_GOVERNANCE_APP_PRIVATE_KEY: ${{ secrets.AGENT_GOVERNANCE_APP_PRIVATE_KEY }}
```

The private key is passed by name, never with `secrets: inherit`, and only to a reviewed release commit: a change merged to the hub's `main` does not run with it until a release is cut and the pin bump is merged in `governance-ops`. Runs, logs and audit findings stay private there.

Cutting a release (every two weeks, or at once for a security fix):

1. Rename `## Unreleased` in `CHANGELOG.md` to `## X.Y.Z - <date>` and add a fresh empty `## Unreleased` above it; merge that pull request.
2. `gh release create vX.Y.Z --target <merge-commit-sha> --title vX.Y.Z --notes-file <that section>`.
3. In `governance-ops`, bump the pinned SHA and its `# vX.Y.Z` comment (Dependabot for `github-actions` proposes it) and merge; the next run opens one sync pull request per fleet repository.

A security fix is a patch release (`vX.Y.Z+1`) cut immediately, not held for the next train.

## D. Prompt for a local agent

Paste the following to a coding agent that runs on a workstation with the hub cloned and `gh` authenticated. It cannot do the browser steps in B; it stops and asks for the Client ID and the key path.

```text
Read docs/runbooks/opt-in-rollout.md in this repository and carry out sections A, B (agent-runnable steps) and C.
Section A: print the exact installer command for this operating system and ask me to run it with administrator
rights, unless you already run elevated; then verify by asking me for the output of /status in Claude Code.
Section B: ask me for the GitHub App Client ID and the path to the downloaded private key, set the repository
variable and secret with gh exactly as the runbook shows, dispatch downstream-sync.yml, wait for it, and show me
the "Resolve the sync credential" step output. Do not delete AGENT_GOVERNANCE_SYNC_TOKEN until I confirm that
step printed source=app. Delete the .pem file when the secret is stored.
Section C: list the sync pull requests the run opened and the ruleset status of every repository in the fleet list.
Report each step with the command you ran and its result.
```
