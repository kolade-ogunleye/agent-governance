<#
.SYNOPSIS
    Applies the server-side default-branch ruleset to a GitHub repository when the plan supports it.
.DESCRIPTION
    Server-side rulesets are the non-bypassable enforcement layer: unlike local git hooks, they cannot be
    skipped with --no-verify. Enforcement is conditional, so the same command is safe everywhere:
      - Plan without rulesets (e.g. private repositories on GitHub Free): warns and returns 'unavailable';
        the CI gate, agent settings, and local hooks remain the enforcement.
      - Token without admin rights: warns and returns 'unauthorized'.
      - Otherwise creates the ruleset, or updates the same-named one (idempotent). The governance gate's
        checks become required only once .github/workflows/agent-governance.yml is on the default branch;
        requiring them earlier would deadlock the pull request that adds the workflow.
.PARAMETER Repository
    Target repository in owner/name form.
.PARAMETER RulesetPath
    Ruleset definition (GitHub REST API body). Defaults to rulesets/default-branch-protection.json.
.PARAMETER RequiredCheck
    Status check contexts to require instead of the automatic governance-gate checks (e.g. for the hub).
.PARAMETER NoRequiredChecks
    Never add required status checks.
.EXAMPLE
    ./Set-GovernanceRuleset.ps1 -Repository octo/example -WhatIf
    Shows what would be applied without calling the GitHub API.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$Repository,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RulesetPath = (Join-Path $PSScriptRoot 'rulesets' 'default-branch-protection.json'),

    [string[]]$RequiredCheck,

    [switch]$NoRequiredChecks
)

$ErrorActionPreference = 'Stop'

# The GitHub Actions app on github.com: every workflow job's check run carries this app id.
$GitHubActionsAppId = 15368

function Invoke-GhApi {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]]$GhArgs)
    $output = & gh api @GhArgs 2>&1
    $exit = $LASTEXITCODE
    # Handled here; a stale non-zero $LASTEXITCODE would fail CI steps (GitHub's pwsh wrapper exits with it).
    $global:LASTEXITCODE = 0
    return [pscustomobject]@{ Exit = $exit; Text = ($output -join "`n") }
}

function Get-DenialStatus {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text -match 'Upgrade to GitHub Pro|make this repository public') { return 'unavailable' }
    if ($Text -match 'Resource not accessible|Must have admin rights|"status":\s*"403"') { return 'unauthorized' }
    return ''
}

$definition = Get-Content -LiteralPath $RulesetPath -Raw | ConvertFrom-Json
$name = [string]$definition.name
if (-not $name) { throw "Ruleset definition '$RulesetPath' has no name." }

if (-not $PSCmdlet.ShouldProcess($Repository, "Apply ruleset '$name'")) {
    return [pscustomobject]@{ Repository = $Repository; Status = 'would-apply'; Action = $null; RequiredChecks = @() }
}

$listing = Invoke-GhApi -GhArgs @("repos/$Repository/rulesets")
if ($listing.Exit -ne 0) {
    switch (Get-DenialStatus -Text $listing.Text) {
        'unavailable' {
            Write-Warning "Rulesets are not available on this plan for $Repository (private repositories need GitHub Pro, Team, or Enterprise). Enforcement continues through the CI gate, agent settings, and local hooks."
            return [pscustomobject]@{ Repository = $Repository; Status = 'unavailable'; Action = $null; RequiredChecks = @() }
        }
        'unauthorized' {
            Write-Warning "The token cannot manage rulesets on $Repository; grant it the 'Administration: Read and write' repository permission. Skipping."
            return [pscustomobject]@{ Repository = $Repository; Status = 'unauthorized'; Action = $null; RequiredChecks = @() }
        }
        default { throw "Listing rulesets for $Repository failed: $($listing.Text)" }
    }
}

$checks = @()
if ($NoRequiredChecks) {
    $checks = @()
} elseif ($RequiredCheck) {
    $checks = @($RequiredCheck)
} else {
    $defaultBranch = (Invoke-GhApi -GhArgs @("repos/$Repository", '--jq', '.default_branch')).Text.Trim()
    $workflow = Invoke-GhApi -GhArgs @("repos/$Repository/contents/.github/workflows/agent-governance.yml?ref=$defaultBranch")
    if ($workflow.Exit -eq 0) {
        $checks = @('governance / secret-scan', 'governance / integrity')
    } else {
        Write-Warning "The governance gate workflow is not on $Repository's default branch yet; applying the ruleset without required checks. Re-run after the sync pull request merges."
    }
}

$rules = [System.Collections.Generic.List[object]]::new()
foreach ($rule in $definition.rules) { if ($rule.type -ne 'required_status_checks') { $rules.Add($rule) } }
if ($checks.Count -gt 0) {
    $rules.Add([pscustomobject]@{
            type       = 'required_status_checks'
            parameters = [pscustomobject]@{
                strict_required_status_checks_policy = $false
                # Pinned to the GitHub Actions app: a commit status or a check run that another app or a token
                # posts under the same name does not satisfy the rule.
                required_status_checks               = @($checks | ForEach-Object { [pscustomobject]@{ context = $_; integration_id = $GitHubActionsAppId } })
            }
        })
}
$definition.rules = $rules.ToArray()

$bodyPath = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($bodyPath, ($definition | ConvertTo-Json -Depth 10))
    $existing = @($listing.Text | ConvertFrom-Json) | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($existing) {
        $apply = Invoke-GhApi -GhArgs @('--method', 'PUT', "repos/$Repository/rulesets/$($existing.id)", '--input', $bodyPath)
        $action = 'updated'
    } else {
        $apply = Invoke-GhApi -GhArgs @('--method', 'POST', "repos/$Repository/rulesets", '--input', $bodyPath)
        $action = 'created'
    }
} finally {
    Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
}

if ($apply.Exit -ne 0) {
    if ((Get-DenialStatus -Text $apply.Text) -eq 'unauthorized') {
        Write-Warning "The token cannot manage rulesets on $Repository; grant it the 'Administration: Read and write' repository permission. Skipping."
        return [pscustomobject]@{ Repository = $Repository; Status = 'unauthorized'; Action = $null; RequiredChecks = @() }
    }
    throw "Applying ruleset '$name' to $Repository failed: $($apply.Text)"
}

$status = if ($checks.Count -gt 0) { 'applied' } else { 'applied-without-checks' }
Write-Information "$action ruleset '$name' on $Repository ($status)." -InformationAction Continue
return [pscustomobject]@{ Repository = $Repository; Status = $status; Action = $action; RequiredChecks = $checks }
