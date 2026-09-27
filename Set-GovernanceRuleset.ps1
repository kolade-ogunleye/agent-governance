<#
.SYNOPSIS
    Applies the server-side default-branch ruleset to a GitHub repository.
.DESCRIPTION
    Server-side rulesets are the non-bypassable enforcement layer: unlike local git hooks,
    they cannot be skipped with --no-verify. Creates the ruleset, or updates the existing
    ruleset of the same name so repeated runs are idempotent. Requires an authenticated
    GitHub CLI with admin rights on the repository. Rulesets on private repositories
    require a GitHub plan that supports them.
.PARAMETER Repository
    Target repository in owner/name form.
.PARAMETER RulesetPath
    Ruleset definition (GitHub REST API body). Defaults to rulesets/default-branch-protection.json.
.EXAMPLE
    ./Set-GovernanceRuleset.ps1 -Repository octo/example -WhatIf
    Shows what would be applied without calling the GitHub API.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$Repository,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RulesetPath = (Join-Path $PSScriptRoot 'rulesets' 'default-branch-protection.json')
)

$ErrorActionPreference = 'Stop'

$definition = Get-Content -LiteralPath $RulesetPath -Raw | ConvertFrom-Json
$name = [string]$definition.name
if (-not $name) { throw "Ruleset definition '$RulesetPath' has no name." }

if (-not $PSCmdlet.ShouldProcess($Repository, "Apply ruleset '$name'")) {
    return
}

$existingJson = & gh api "repos/$Repository/rulesets"
if ($LASTEXITCODE -ne 0) { throw "Listing rulesets for $Repository failed (gh exit $LASTEXITCODE)." }
$existing = @($existingJson | ConvertFrom-Json) | Where-Object { $_.name -eq $name } | Select-Object -First 1

if ($existing) {
    & gh api --method PUT "repos/$Repository/rulesets/$($existing.id)" --input $RulesetPath | Out-Null
    $verb = 'Updated'
} else {
    & gh api --method POST "repos/$Repository/rulesets" --input $RulesetPath | Out-Null
    $verb = 'Created'
}
if ($LASTEXITCODE -ne 0) { throw "Applying ruleset '$name' to $Repository failed (gh exit $LASTEXITCODE)." }

Write-Information "$verb ruleset '$name' on $Repository." -InformationAction Continue
