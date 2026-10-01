<#
.SYNOPSIS
    Reports pinned tool versions that are behind their latest release (advisory).
.DESCRIPTION
    Reads the versions pinned in this hub (Pester, PSScriptAnalyzer and Prettier from .github/workflows/ci.yml,
    Gitleaks from .github/workflows/governance-gate.yml, Lefthook from PROJECT.md), looks up each project's
    latest GitHub release with the gh CLI, and writes a table to the console and to GITHUB_STEP_SUMMARY when set.
    Each stale pin is reported as a workflow warning. The script exits 0 unless -FailOnStale is given; Dependabot
    does not cover these pins, so this is the weekly nudge that keeps them current.
.PARAMETER RepoRoot
    Hub checkout to read the pins from. Defaults to the directory containing this script.
.PARAMETER LatestJson
    A JSON file of latest versions keyed by tool name (pester, psscriptanalyzer, prettier, gitleaks, lefthook),
    used instead of the GitHub API (tests, air-gapped runs).
.PARAMETER FailOnStale
    Exit 1 when any pin is behind.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RepoRoot = $PSScriptRoot,
    [string]$LatestJson,
    [switch]$FailOnStale
)

$ErrorActionPreference = 'Stop'

function Get-PinnedToolVersion {
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$Root)
    $ci = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'ci.yml') -Raw
    $gate = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'governance-gate.yml') -Raw
    $project = Get-Content -LiteralPath (Join-Path $Root 'PROJECT.md') -Raw
    $pins = @{}
    foreach ($pair in @(@('pester', 'PESTER_VERSION'), @('psscriptanalyzer', 'PSSA_VERSION'), @('prettier', 'PRETTIER_VERSION'))) {
        if ($ci -match "(?m)^\s+$($pair[1]):\s*`"([0-9][0-9.]*)`"") { $pins[$pair[0]] = $Matches[1] }
    }
    if ($gate -match '(?m)^\s+GITLEAKS_VERSION:\s*"([0-9][0-9.]*)"') { $pins['gitleaks'] = $Matches[1] }
    if ($project -match 'Lefthook \(v([0-9][0-9.]*)\)') { $pins['lefthook'] = $Matches[1] }
    return $pins
}

function Get-LatestToolVersion {
    [OutputType([hashtable])]
    param([string]$FromJson)
    if ($FromJson) {
        $table = @{}
        foreach ($p in (Get-Content -LiteralPath $FromJson -Raw | ConvertFrom-Json).PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
        return $table
    }
    $repos = @{
        pester           = 'pester/Pester'
        psscriptanalyzer = 'PowerShell/PSScriptAnalyzer'
        prettier         = 'prettier/prettier'
        gitleaks         = 'gitleaks/gitleaks'
        lefthook         = 'evilmartians/lefthook'
    }
    $latest = @{}
    foreach ($tool in $repos.Keys) {
        $tag = "$(& gh api "repos/$($repos[$tool])/releases/latest" --jq '.tag_name' 2>$null)".Trim()
        $global:LASTEXITCODE = 0
        if ($tag -match '([0-9]+(?:\.[0-9]+)+)') { $latest[$tool] = $Matches[1] } else { $latest[$tool] = $null }
    }
    return $latest
}

function Compare-ToolVersion {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Pinned, [AllowNull()][string]$Latest)
    if (-not $Latest) { return 'unknown' }
    $p = [version]$Pinned
    $l = [version]$Latest
    if ($p -ge $l) { return 'current' }
    return 'stale'
}

$pins = Get-PinnedToolVersion -Root $RepoRoot
$latest = Get-LatestToolVersion -FromJson $LatestJson
$rows = foreach ($tool in ($pins.Keys | Sort-Object)) {
    [pscustomobject]@{ Tool = $tool; Pinned = $pins[$tool]; Latest = $latest[$tool]; Status = (Compare-ToolVersion -Pinned $pins[$tool] -Latest $latest[$tool]) }
}

$rows | Format-Table -AutoSize | Out-String | Write-Host
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @('## Toolchain freshness', '', '| Tool | Pinned | Latest | Status |', '| :-- | :-- | :-- | :-- |')
    foreach ($r in $rows) { $md += "| $($r.Tool) | $($r.Pinned) | $($r.Latest) | $($r.Status) |" }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}
$stale = @($rows | Where-Object Status -eq 'stale')
foreach ($r in $stale) { Write-Host "::warning::$($r.Tool) is pinned at $($r.Pinned); the latest release is $($r.Latest)." }

if ($FailOnStale -and $stale.Count -gt 0) { exit 1 }
$rows
