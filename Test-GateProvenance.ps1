<#
.SYNOPSIS
    Audits recently merged pull requests in a governed repository: were the required governance checks produced
    by the real hub gate?
.DESCRIPTION
    A ruleset requires status checks by name, and GitHub does not record which workflow file produced a check of
    a given name. A pull request could replace .github/workflows/agent-governance.yml with jobs that only carry
    the gate's job names. Required workflows, which would prevent that, exist only for organizations.
    This audit detects it after the fact, from outside the governed repository. For each pull request merged into
    the default branch within -SinceDays, it reads every workflow run for the pull request's head commit and
    classifies each job carrying a required check name:
      - genuine: the run's workflow is .github/workflows/agent-governance.yml and it called
        <hub>/.github/workflows/governance-gate.yml at a full commit SHA;
      - spoofed: any other run produced a job with a required name. This is an error;
      - missing: no successful genuine job for a required name. A warning, since a pull request merged before
        the ruleset required the checks has none.
    A genuine run alone is not enough: the caller could keep the gate under another job id and add a fake job with
    the gate's name beside it. So the caller workflow at the head commit must also equal the hub's template at the
    commit it pins, rendered as the sync renders it; anything else is reported as tampered (an error).
    Needs a token with Actions: read, Contents: read and Pull requests: read on the repository, and a clone of the
    hub with full history (-HubPath).
.PARAMETER Repository
    Governed repository, owner/name.
.PARAMETER HubRepository
    The hub whose gate is genuine.
.PARAMETER HubPath
    A clone of the hub with full history, used to render the expected caller workflow at any pinned commit.
.PARAMETER SinceDays
    Audit pull requests merged within this many days. The weekly fleet run uses 8, a day of overlap.
.EXAMPLE
    ./Test-GateProvenance.ps1 -Repository kolade-ogunleye/ai-os
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$Repository,

    [ValidatePattern('^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$HubRepository = 'kolade-ogunleye/agent-governance',

    [string]$HubPath = $PSScriptRoot,

    [ValidateRange(1, 90)]
    [int]$SinceDays = 8
)

$ErrorActionPreference = 'Stop'

$RequiredJobNames = @('governance / secret-scan', 'governance / integrity')
$CallerWorkflowPath = '.github/workflows/agent-governance.yml'

function Test-GenuineGateRun {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Hub
    )
    if ("$($Run.path)" -ne $CallerWorkflowPath) { return $false }
    $gatePattern = '^' + [regex]::Escape("$Hub/.github/workflows/governance-gate.yml@") + '[0-9a-f]{40}$'
    return [bool](@($Run.referenced_workflows) | Where-Object { "$($_.path)" -match $gatePattern })
}

function Get-GateProvenanceFinding {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$PullRequest,
        # Workflow runs for the head commit, each with a .jobs array (name, conclusion).
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Runs,
        [Parameter(Mandatory = $true)][string]$Hub
    )
    $genuinePassed = @{}
    foreach ($run in $Runs) {
        $genuine = Test-GenuineGateRun -Run $run -Hub $Hub
        foreach ($job in @($run.jobs)) {
            if ("$($job.name)" -notin $RequiredJobNames) { continue }
            if (-not $genuine) {
                [pscustomobject]@{
                    PullRequest = $PullRequest.number; Kind = 'spoofed'; Job = $job.name
                    Detail      = "run $($run.id) of '$($run.path)' produced '$($job.name)' without calling $Hub's governance-gate.yml"
                }
            } elseif ($job.conclusion -eq 'success') {
                $genuinePassed[$job.name] = $true
            }
        }
    }
    foreach ($name in $RequiredJobNames) {
        if (-not $genuinePassed[$name]) {
            [pscustomobject]@{
                PullRequest = $PullRequest.number; Kind = 'missing'; Job = $name
                Detail      = "no successful '$name' job from the hub gate on head $($PullRequest.head.sha)"
            }
        }
    }
}

function Get-CallerWorkflowFinding {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$PullRequest,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Hub,
        [Parameter(Mandatory = $true)][string]$HubPath,
        [Parameter(Mandatory = $true)][string]$DefaultBranch
    )
    # Returns a 'tampered' finding unless $Content is exactly the hub template, at the commit it pins, rendered
    # the way Sync-AgentGovernance renders it.
    $content = $Content -replace "`r`n", "`n"
    $pin = [regex]::Match($content, '(?m)^\s+uses:\s*' + [regex]::Escape($Hub) + '/\.github/workflows/governance-gate\.yml@([0-9a-f]{40})\s*$')
    $detail = $null
    if (-not $pin.Success) {
        $detail = "the caller workflow at head $($PullRequest.head.sha) does not call $Hub's governance-gate.yml at a full commit SHA"
    } else {
        $commit = $pin.Groups[1].Value
        $template = (& git -C $HubPath show "${commit}:template/.github/workflows/agent-governance.yml" 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $template) {
            $detail = "the caller pins hub commit $commit, which has no caller template in $Hub"
        } else {
            $expected = $template.Replace('__HUB_REPOSITORY__', $Hub).Replace('__HUB_COMMIT__', $commit).Replace('__DEFAULT_BRANCH__', $DefaultBranch)
            # Indentation and blank lines are ignored: a repository's formatter may re-indent YAML (Prettier with
            # tabWidth 4), and adding a job, a step or a name takes new lines, which this still catches.
            $normalize = { param($text) ((($text -replace "`r`n", "`n") -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n" }
            if ((& $normalize $content) -cne (& $normalize $expected)) {
                $detail = "the caller workflow at head $($PullRequest.head.sha) differs from the hub template at $commit"
            }
        }
    }
    if ($detail) { [pscustomobject]@{ PullRequest = $PullRequest.number; Kind = 'tampered'; Job = $null; Detail = $detail } }
}

function Invoke-GhText {
    param([Parameter(Mandatory = $true)][string]$Endpoint)
    $text = (& gh api $Endpoint -H 'Accept: application/vnd.github.raw' 2>&1) -join "`n"
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $text }
}

function Invoke-GhJson {
    param([Parameter(Mandatory = $true)][string]$Endpoint)
    $text = (& gh api $Endpoint 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "gh api $Endpoint failed: $text" }
    return ($text | ConvertFrom-Json)
}

# Dot-sourced by the tests for the functions above; run as a script for the audit.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Repository) { throw '-Repository is required.' }

$since = [DateTimeOffset]::UtcNow.AddDays(-$SinceDays)
$defaultBranch = (Invoke-GhJson -Endpoint "repos/$Repository").default_branch
$pulls = @(Invoke-GhJson -Endpoint "repos/$Repository/pulls?state=closed&base=$defaultBranch&sort=updated&direction=desc&per_page=100") |
    Where-Object { $_.merged_at -and [DateTimeOffset]::Parse($_.merged_at) -ge $since }

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($pr in $pulls) {
    $runs = @((Invoke-GhJson -Endpoint "repos/$Repository/actions/runs?head_sha=$($pr.head.sha)&per_page=100").workflow_runs)
    foreach ($run in $runs) {
        # filter=all includes every attempt, so a spoofed first attempt is not hidden by a genuine re-run.
        $jobs = @((Invoke-GhJson -Endpoint "repos/$Repository/actions/runs/$($run.id)/jobs?filter=all&per_page=100").jobs)
        $run | Add-Member -NotePropertyName jobs -NotePropertyValue $jobs -Force
    }
    foreach ($f in @(Get-GateProvenanceFinding -PullRequest $pr -Runs $runs -Hub $HubRepository)) { $findings.Add($f) }

    # Only for pull requests whose head carries the caller at all; older ones are reported as missing above.
    $caller = Invoke-GhText -Endpoint "repos/$Repository/contents/.github/workflows/agent-governance.yml?ref=$($pr.head.sha)"
    if ($caller.Exit -eq 0) {
        foreach ($f in @(Get-CallerWorkflowFinding -PullRequest $pr -Content $caller.Text -Hub $HubRepository -HubPath $HubPath -DefaultBranch $defaultBranch)) { $findings.Add($f) }
    } elseif ($caller.Text -notmatch 'HTTP 404') {
        throw "Could not read the caller workflow of $Repository at $($pr.head.sha): $($caller.Text)"
    }
}

foreach ($f in $findings) {
    $level = if ($f.Kind -in 'spoofed', 'tampered') { 'error' } else { 'warning' }
    Write-Host "::${level}::${Repository} #$($f.PullRequest): $($f.Kind) - $($f.Detail)"
}
$count = { param($kind) @($findings | Where-Object Kind -eq $kind).Count }
$errors = (& $count 'spoofed') + (& $count 'tampered')
$summary = "${Repository}: $(@($pulls).Count) pull request(s) merged in $SinceDays days audited; $(& $count 'spoofed') spoofed, $(& $count 'tampered') tampered, $(& $count 'missing') missing."
Write-Host $summary
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "- $summary" }
if ($errors -gt 0) { exit 1 }
