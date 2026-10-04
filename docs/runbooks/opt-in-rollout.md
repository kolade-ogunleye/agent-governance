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
3. Repository permissions: Contents (Read and write), Workflows (Read and write: every sync updates the pinned gate in `.github/workflows/agent-governance.yml`, and GitHub refuses that push without it), Pull requests (Read and write), Issues (Read and write, for the label and assignee), Administration (Read and write, for rulesets), Metadata (Read, selected automatically).
4. "Where can this GitHub App be installed?": Only on this account. Create the app.
5. On the app page, note the **Client ID**. Under Private keys, Generate a private key; a `.pem` file downloads.
6. Install App → your account → Only select repositories → the hub and every repository in `fleet.json`.

### Agent-runnable steps (gh CLI, authenticated as the account owner)

```powershell
# From the hub clone. <client-id> is the value from step 5; <path-to-pem> the downloaded key.
gh variable set AGENT_GOVERNANCE_APP_CLIENT_ID --repo kolade-ogunleye/agent-governance --body "<client-id>"
gh secret set AGENT_GOVERNANCE_APP_PRIVATE_KEY --repo kolade-ogunleye/agent-governance < "<path-to-pem>"

# Prove the App path works before retiring the token: run the sync on demand and read the step
# "Resolve the sync credential", which prints source=app.
gh workflow run downstream-sync.yml --repo kolade-ogunleye/agent-governance
gh run watch --repo kolade-ogunleye/agent-governance

# Then retire the personal access token: delete the secret here and revoke the token in
# Settings → Developer settings → Personal access tokens.
gh secret delete AGENT_GOVERNANCE_SYNC_TOKEN --repo kolade-ogunleye/agent-governance
```

Delete the downloaded `.pem` once the secret is stored. The `AGENT_GOVERNANCE_HUB_TOKEN` secret in each fleet repository (read-only access to the private hub for the integrity job) is unchanged by this step.

## C. Fleet follow-up after a hub change merges

1. Dispatch the sync (`gh workflow run downstream-sync.yml`) or wait for the Monday run; one pull request per fleet repository opens.
2. Review and merge each sync pull request within 30 days (the integrity job warns at 30 and fails at 90).
3. Confirm enforcement: `./Set-GovernanceRuleset.ps1 -Repository <owner/name> -WhatIf`, or `gh api repos/<owner/name>/rulesets`. On GitHub Pro the ruleset applies to private repositories.
4. Install the local git gate in each clone that has none: `Sync-AgentGovernance hooks -RepoPath <clone>`.

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
Section C: list the sync pull requests the run opened and the ruleset status of every repository in fleet.json.
Report each step with the command you ran and its result.
```
