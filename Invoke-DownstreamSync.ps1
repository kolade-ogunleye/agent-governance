<#
.SYNOPSIS
    Re-syncs one downstream repository from this hub and opens (or updates) a pull request.
.DESCRIPTION
    Used by .github/workflows/downstream-sync.yml, and runnable locally. Works on a clone whose origin is the
    downstream repository: branches from the latest default branch, runs Sync-AgentGovernance with
    -BranchAndCommit, renames the branch to chore/agent-governance-sync-<hub-sha> (unique per hub version, so
    stale governance branches never collide), then pushes and opens a pull request with the gh CLI.
.PARAMETER RepoPath
    Clone of the downstream repository (origin must point at it).
.PARAMETER DryRun
    Sync and commit locally, but push nothing and open no pull request.
.PARAMETER Assignee
    Who the pull request is assigned to, so it shows under the owner's assigned pull requests (default @me:
    the account that owns the sync token).
.PARAMETER InstallFormatter
    When the repository declares Prettier but it is not installed (typical in CI), install the repository's
    own locked dependencies first (npm ci / pnpm install --frozen-lockfile, both with --ignore-scripts), so
    sync formats governed files the way the repository's format check expects.
.OUTPUTS
    An object with Action (opened, updated, up-to-date, would-open), Branch, and Superseded (older sync pull
    requests closed in favour of this one).
.NOTES
    Nudges: every sync pull request carries the agent-governance label and an assignee, and older open sync
    pull requests are closed with a pointer to the new one, so only one is ever waiting for review.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [switch]$DryRun,
    [string]$Assignee = '@me',
    [switch]$InstallFormatter
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sync-AgentGovernance.ps1')

function Install-RepositoryFormatter {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $manifest = Join-Path $Repo 'package.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return }
    $pkg = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    $declared = ($pkg.devDependencies -and $pkg.devDependencies.PSObject.Properties['prettier']) -or
        ($pkg.dependencies -and $pkg.dependencies.PSObject.Properties['prettier'])
    if (-not $declared -or (Test-Path (Join-Path $Repo 'node_modules' '.bin' 'prettier*'))) { return }

    Push-Location $Repo
    try {
        # Locked versions only, and no package install scripts.
        if ((Test-Path 'package-lock.json') -and (Get-Command npm -ErrorAction SilentlyContinue)) {
            & npm ci --ignore-scripts --no-audit --no-fund
        } elseif ((Test-Path 'pnpm-lock.yaml') -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
            & pnpm install --frozen-lockfile --ignore-scripts
        } else {
            Write-Warning 'Prettier is declared but no supported lockfile/package manager is available; governed files will not be formatted.'
            return
        }
        if ($LASTEXITCODE -ne 0) { Write-Warning "Installing the repository formatter failed (exit $LASTEXITCODE); governed files may not be formatted." }
    } finally {
        Pop-Location
    }
}

$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$hubSha = "$(git -C $PSScriptRoot rev-parse HEAD)".Trim()
$defaultBranch = "$(git -C $repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/', ''
if (-not $defaultBranch) { $defaultBranch = 'main' }
$syncBranch = "chore/agent-governance-sync-$($hubSha.Substring(0, 7))"

& git -C $repo fetch --quiet origin
if ($LASTEXITCODE -ne 0) { throw "git fetch failed for $repo" }
# Always start from the latest default branch; -B discards any stale local governance branch.
& git -C $repo checkout --quiet -B chore/agent-governance "origin/$defaultBranch"
if ($LASTEXITCODE -ne 0) { throw "Could not branch from origin/$defaultBranch" }

if ($InstallFormatter) { Install-RepositoryFormatter -Repo $repo }
Sync-AgentGovernance -RepoPath $repo -BranchAndCommit

$ahead = [int]"$(git -C $repo rev-list --count "origin/$defaultBranch..HEAD")".Trim()
if ($ahead -eq 0) {
    return [pscustomobject]@{ Action = 'up-to-date'; Branch = $null; Superseded = @() }
}
& git -C $repo branch --quiet -M $syncBranch
if ($DryRun) {
    return [pscustomobject]@{ Action = 'would-open'; Branch = $syncBranch; Superseded = @() }
}

& git -C $repo push --quiet --force-with-lease -u origin $syncBranch
if ($LASTEXITCODE -ne 0) { throw "Push of $syncBranch failed" }

$syncLabel = 'agent-governance'
$existing = "$(& gh pr list --head $syncBranch --state open --json number --jq '.[0].number' 2>$null)".Trim()
if ($existing) {
    return [pscustomobject]@{ Action = 'updated'; Branch = $syncBranch; Superseded = @() }
}

# The label is a nudge, not a requirement: a token that cannot manage labels still opens the pull request.
& gh label create $syncLabel --force --color '5319E7' --description 'Automated governance sync from the agent-governance hub' *> $null
$labelArgs = if ($LASTEXITCODE -eq 0) { @('--label', $syncLabel) } else { Write-Warning "Could not create the '$syncLabel' label; opening the pull request without it."; @() }
$global:LASTEXITCODE = 0

$body = "Automated re-sync from agent-governance at $hubSha.`n`nReview the diff; the Agent Governance check verifies managed files against the hub at this commit. Merge within 30 days: the check warns when the pinned hub commit is 30 days old and fails at 90."
$prUrl = "$(& gh pr create --base $defaultBranch --head $syncBranch --title "chore(governance): sync from hub $($hubSha.Substring(0, 7))" --body $body --assignee $Assignee @labelArgs)".Trim()
if ($LASTEXITCODE -ne 0) { throw "Opening the pull request for $syncBranch failed" }
$prRef = if ($prUrl -match '/pull/(\d+)') { "#$($Matches[1])" } else { $syncBranch }

# Only the newest sync is worth reviewing; close older ones so they cannot be merged out of order.
$superseded = [System.Collections.Generic.List[int]]::new()
$openJson = "$(& gh pr list --state open --limit 100 --json 'number,headRefName' 2>$null)".Trim()
if ($LASTEXITCODE -eq 0 -and $openJson) {
    foreach ($pr in @($openJson | ConvertFrom-Json)) {
        if ($pr.headRefName -like 'chore/agent-governance-sync-*' -and $pr.headRefName -ne $syncBranch) {
            & gh pr close $pr.number --delete-branch --comment "Superseded by $prRef (a newer sync from the agent-governance hub)."
            if ($LASTEXITCODE -eq 0) { $superseded.Add([int]$pr.number) } else { Write-Warning "Could not close superseded pull request #$($pr.number)." }
        }
    }
}
$global:LASTEXITCODE = 0
return [pscustomobject]@{ Action = 'opened'; Branch = $syncBranch; Superseded = $superseded.ToArray() }
