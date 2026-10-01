<#
.SYNOPSIS
    Deterministic policy-coverage eval for the agent governance contract.
.DESCRIPTION
    Replays contract-forbidden agent actions (expected: block) and look-alike legitimate work (expected:
    allow) against the real enforcement layers: the Claude Code PreToolUse Bash guard and the pre-commit
    guardrail scripts. Reports the catch rate and false-positive rate and exits 1 on any mismatch, so CI can
    gate on it. It measures the enforcement machinery, not model behaviour; see Invoke-LiveAgentEval.ps1.
    A scenario flagged accepted_miss is a forbidden action the layer is documented not to catch (ADR 0003): it
    is excluded from the catch rate and passes only while it is still missed, so a guard change that catches it
    must also drop the flag and update the documentation.
.PARAMETER ScenarioPath
    Scenario catalogue (JSON). Defaults to policy-scenarios.json beside this script.
.PARAMETER GuardDir
    Guardrail scripts under test. Defaults to the hub template's scripts/guardrails.
.PARAMETER OutputPath
    Optional path for a JSON results report.
#>
[CmdletBinding()]
param(
    [string]$ScenarioPath = (Join-Path $PSScriptRoot 'policy-scenarios.json'),
    [string]$GuardDir = (Join-Path $PSScriptRoot '..' 'template' 'scripts' 'guardrails'),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Invoke-Pwsh {
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [string]$StdIn)
    if ($PSBoundParameters.ContainsKey('StdIn')) { $StdIn | & pwsh -NoProfile -File $ScriptPath *> $null }
    else { & pwsh -NoProfile -File $ScriptPath *> $null }
    return $LASTEXITCODE
}

function Write-FixtureFile {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][hashtable]$Files)
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $Root $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, [string]$Files[$rel])
    }
}

function ConvertTo-Hashtable {
    [OutputType([hashtable])]
    param([AllowNull()][object]$Object)
    $table = @{}
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $table[$p.Name] = $p.Value } }
    return $table
}

function Invoke-GitScenario {
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][object]$Scenario, [Parameter(Mandatory = $true)][string]$WorkRoot)
    $repo = Join-Path $WorkRoot $Scenario.id
    git init --quiet --initial-branch=main $repo
    git -C $repo config user.email 'eval@example.invalid'
    git -C $repo config user.name 'Eval'
    git -C $repo config commit.gpgsign false
    git -C $repo config gc.auto 0
    Write-FixtureFile -Root $repo -Files @{ 'README.md' = "# eval`n" }
    Write-FixtureFile -Root $repo -Files (ConvertTo-Hashtable $Scenario.committed)
    git -C $repo add -A
    git -C $repo -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: eval baseline'

    $branch = if ($Scenario.branch) { [string]$Scenario.branch } else { 'feat/eval' }
    if ($branch -ne 'main') { git -C $repo checkout --quiet -b $branch }

    $stage = ConvertTo-Hashtable $Scenario.stage
    Write-FixtureFile -Root $repo -Files $stage
    foreach ($rel in $stage.Keys) { git -C $repo add -f -- $rel }
    if ($Scenario.delete) { git -C $repo rm --quiet -- $Scenario.delete }
    if ($Scenario.move) {
        New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $repo $Scenario.move[1])) -Force | Out-Null
        git -C $repo mv $Scenario.move[0] $Scenario.move[1]
    }
    $append = ConvertTo-Hashtable $Scenario.append
    foreach ($rel in $append.Keys) {
        [System.IO.File]::AppendAllText((Join-Path $repo $rel), [string]$append[$rel])
        git -C $repo add -- $rel
    }

    Push-Location $repo
    try { return Invoke-Pwsh -ScriptPath (Join-Path $GuardDir "$($Scenario.layer).ps1") }
    finally { Pop-Location }
}

$catalogue = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("policy-eval-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot | Out-Null

# detect-secrets fails closed without gitleaks; the eval targets its file-name rules, so a clean stub stands in.
$shimDir = Join-Path $workRoot '.shims'
New-Item -ItemType Directory -Path $shimDir | Out-Null
if ($IsWindows) { [System.IO.File]::WriteAllText((Join-Path $shimDir 'gitleaks.ps1'), "exit 0`n") }
else { [System.IO.File]::WriteAllText((Join-Path $shimDir 'gitleaks'), "#!/bin/sh`nexit 0`n"); & chmod +x (Join-Path $shimDir 'gitleaks') }
$originalPath = $env:PATH
$env:PATH = $shimDir + [System.IO.Path]::PathSeparator + $env:PATH

$results = [System.Collections.Generic.List[pscustomobject]]::new()
try {
    foreach ($scenario in $catalogue.scenarios) {
        $exit = if ($scenario.layer -eq 'bash-guard') {
            $tool = if ($scenario.tool) { [string]$scenario.tool } else { 'Bash' }
            $payload = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = @{ command = [string]$scenario.command } } | ConvertTo-Json -Compress
            Invoke-Pwsh -ScriptPath (Join-Path $GuardDir 'agent-bash-guard.ps1') -StdIn $payload
        } else {
            Invoke-GitScenario -Scenario $scenario -WorkRoot $workRoot
        }
        # The Bash guard signals a block with exit 2 (Claude Code's contract); guardrail scripts with any non-zero.
        $blocked = if ($scenario.layer -eq 'bash-guard') { $exit -eq 2 } else { $exit -ne 0 }
        $actual = if ($blocked) { 'block' } else { 'allow' }
        $acceptedMiss = [bool]$scenario.accepted_miss
        $results.Add([pscustomobject]@{
                Id = $scenario.id; Contract = $scenario.contract; Layer = $scenario.layer
                Expected = $scenario.expect; Actual = $actual; AcceptedMiss = $acceptedMiss
                Pass = $(if ($acceptedMiss) { $actual -eq 'allow' } else { $actual -eq $scenario.expect })
            })
    }
} finally {
    $env:PATH = $originalPath
    Get-ChildItem -LiteralPath $workRoot -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$mustBlock = @($results | Where-Object { $_.Expected -eq 'block' -and -not $_.AcceptedMiss })
$mustAllow = @($results | Where-Object Expected -eq 'allow')
$acceptedMisses = @($results | Where-Object AcceptedMiss)
$caught = @($mustBlock | Where-Object Pass).Count
$falsePositives = @($mustAllow | Where-Object { -not $_.Pass }).Count
$summary = [pscustomobject]@{
    Scenarios         = $results.Count
    CatchRate         = if ($mustBlock.Count) { [Math]::Round($caught / $mustBlock.Count, 4) } else { 1 }
    FalsePositiveRate = if ($mustAllow.Count) { [Math]::Round($falsePositives / $mustAllow.Count, 4) } else { 0 }
    Caught            = "$caught/$($mustBlock.Count)"
    FalsePositives    = "$falsePositives/$($mustAllow.Count)"
    AcceptedMisses    = "$(@($acceptedMisses | Where-Object Pass).Count)/$($acceptedMisses.Count)"
    Failures          = @($results | Where-Object { -not $_.Pass } | ForEach-Object {
            if ($_.AcceptedMiss) { "$($_.Id) (accepted miss is now blocked; remove accepted_miss from the catalogue and update ADR 0003)" }
            else { "$($_.Id) (expected $($_.Expected), got $($_.Actual))" }
        })
}

$results | Format-Table Id, Contract, Layer, Expected, Actual, AcceptedMiss, Pass -AutoSize | Out-String -Width 160 | Write-Information -InformationAction Continue
Write-Information "Catch rate: $($summary.Caught) ($($summary.CatchRate * 100)%); false positives: $($summary.FalsePositives) ($($summary.FalsePositiveRate * 100)%); accepted misses still missed: $($summary.AcceptedMisses)" -InformationAction Continue
if ($OutputPath) { [pscustomobject]@{ Summary = $summary; Results = $results } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM }

if ($summary.Failures.Count -gt 0) {
    foreach ($f in $summary.Failures) { Write-Information "MISMATCH: $f" -InformationAction Continue }
    exit 1
}
exit 0
