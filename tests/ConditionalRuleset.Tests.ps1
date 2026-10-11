BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RulesetScript = Join-Path $RepoRoot 'Set-GovernanceRuleset.ps1'

    # A scripted `gh` that answers like the GitHub API in a given mode (GH_SHIM_MODE):
    #   unavailable   - plan has no rulesets (403 "Upgrade to GitHub Pro")
    #   unauthorized  - token lacks admin rights
    #   no-workflow   - rulesets available; the gate workflow is not on the default branch
    #   with-workflow - rulesets available; the gate workflow is on the default branch
    #   existing      - as with-workflow, and a same-named ruleset already exists (id 42)
    $script:ShimDir = Join-Path $TestDrive 'gh-shim'
    New-Item -ItemType Directory -Path $ShimDir | Out-Null
    $impl = @'
$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath $env:GH_SHIM_LOG -Value ($args -join ' ')
$mode = $env:GH_SHIM_MODE
$method = if ($args -contains '--method') { $args[[array]::IndexOf($args, '--method') + 1] } else { 'GET' }
$path = @($args | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^-' })[0]
if ($args -contains '--input') { Copy-Item -LiteralPath $args[[array]::IndexOf($args, '--input') + 1] -Destination "$($env:GH_SHIM_LOG).$method.json" }
if ($path -match '/rulesets$' -and $method -eq 'GET') {
    if ($mode -eq 'unavailable') { Write-Output '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'; exit 1 }
    if ($mode -eq 'unauthorized') { Write-Output '{"message":"Resource not accessible by personal access token","status":"403"}'; exit 1 }
    if ($mode -eq 'existing') { Write-Output '[{"id":42,"name":"agent-governance: protect default branch"}]'; exit 0 }
    Write-Output '[]'; exit 0
}
if ($path -match '/contents/\.github/workflows/agent-governance\.yml') {
    if ($mode -in @('with-workflow', 'existing')) { Write-Output '{"name":"agent-governance.yml"}'; exit 0 }
    Write-Output '{"message":"Not Found","status":"404"}'; exit 1
}
if ($path -match '^repos/[^/]+/[^/]+$') { Write-Output 'main'; exit 0 }
exit 0
'@
    [System.IO.File]::WriteAllText((Join-Path $ShimDir 'gh-impl.ps1'), $impl)
    if ($IsWindows) {
        [System.IO.File]::WriteAllText((Join-Path $ShimDir 'gh.ps1'), "& '$((Join-Path $ShimDir 'gh-impl.ps1'))' @args`nexit `$LASTEXITCODE`n")
    } else {
        $sh = Join-Path $ShimDir 'gh'
        [System.IO.File]::WriteAllText($sh, "#!/bin/sh`nexec pwsh -NoProfile -File '$((Join-Path $ShimDir 'gh-impl.ps1'))' `"`$@`"`n")
        chmod +x $sh
    }

    function Invoke-RulesetScript {
        param([string]$Mode, [hashtable]$ExtraParams = @{})
        $log = Join-Path $TestDrive ("gh-" + [guid]::NewGuid().ToString('N') + '.log')
        $saved = @{ PATH = $env:PATH; GH_SHIM_MODE = $env:GH_SHIM_MODE; GH_SHIM_LOG = $env:GH_SHIM_LOG }
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
        $env:GH_SHIM_MODE = $Mode
        $env:GH_SHIM_LOG = $log
        try {
            $warnings = $null
            $result = & $RulesetScript -Repository 'octo/example' -Confirm:$false @ExtraParams -WarningVariable warnings 3>$null 6>$null
            $exit = $LASTEXITCODE
            return [pscustomobject]@{ Result = $result; Warnings = ($warnings -join "`n"); Log = $log; ExitCode = $exit }
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }
}

Describe 'Set-GovernanceRuleset.ps1 conditional enforcement' {
    It 'falls back without failing when the plan has no rulesets' {
        $r = Invoke-RulesetScript -Mode 'unavailable'
        $r.Result.Status | Should -Be 'unavailable'
        $r.Warnings | Should -Match 'not available on this plan'
        # GitHub's pwsh step wrapper exits with $LASTEXITCODE, so a handled fallback must leave it at 0.
        $r.ExitCode | Should -Be 0
        "$($r.Log).POST.json" | Should -Not -Exist
    }

    It 'falls back without failing when the token lacks admin rights' {
        $r = Invoke-RulesetScript -Mode 'unauthorized'
        $r.Result.Status | Should -Be 'unauthorized'
        $r.Warnings | Should -Match 'Administration'
        $r.ExitCode | Should -Be 0
        "$($r.Log).POST.json" | Should -Not -Exist
    }

    It 'requires the gate checks once the gate workflow is on the default branch' {
        $r = Invoke-RulesetScript -Mode 'with-workflow'
        $r.Result.Status | Should -Be 'applied'
        $body = Get-Content "$($r.Log).POST.json" -Raw | ConvertFrom-Json
        $checks = ($body.rules | Where-Object type -eq 'required_status_checks').parameters.required_status_checks.context
        $checks | Should -Contain 'governance / secret-scan'
        $checks | Should -Contain 'governance / integrity'
        ($body.rules | Where-Object type -eq 'required_status_checks').parameters.strict_required_status_checks_policy | Should -BeFalse
    }

    It 'accepts each required check only from the GitHub Actions app, not from a commit status or another app' {
        $r = Invoke-RulesetScript -Mode 'with-workflow'
        $body = Get-Content "$($r.Log).POST.json" -Raw | ConvertFrom-Json
        $required = @(($body.rules | Where-Object type -eq 'required_status_checks').parameters.required_status_checks)
        $required.Count | Should -Be 2
        foreach ($check in $required) { $check.integration_id | Should -Be 15368 }
    }

    It 'pins explicitly supplied checks to the GitHub Actions app too' {
        $r = Invoke-RulesetScript -Mode 'no-workflow' -ExtraParams @{ RequiredCheck = @('verify (ubuntu-latest)') }
        $body = Get-Content "$($r.Log).POST.json" -Raw | ConvertFrom-Json
        ($body.rules | Where-Object type -eq 'required_status_checks').parameters.required_status_checks.integration_id | Should -Be 15368
    }

    It 'applies without required checks (no deadlock) while the gate workflow is not yet on the default branch' {
        $r = Invoke-RulesetScript -Mode 'no-workflow'
        $r.Result.Status | Should -Be 'applied-without-checks'
        $body = Get-Content "$($r.Log).POST.json" -Raw | ConvertFrom-Json
        @($body.rules | Where-Object type -eq 'required_status_checks').Count | Should -Be 0
        @($body.rules | Where-Object type -eq 'pull_request').Count | Should -Be 1
    }

    It 'updates an existing same-named ruleset instead of creating a duplicate' {
        $r = Invoke-RulesetScript -Mode 'existing'
        $r.Result.Action | Should -Be 'updated'
        Get-Content $r.Log -Raw | Should -Match 'api --method PUT repos/octo/example/rulesets/42'
        "$($r.Log).POST.json" | Should -Not -Exist
    }

    It 'uses explicitly supplied required checks (for the hub''s own job names)' {
        $r = Invoke-RulesetScript -Mode 'no-workflow' -ExtraParams @{ RequiredCheck = @('verify (ubuntu-latest)') }
        $body = Get-Content "$($r.Log).POST.json" -Raw | ConvertFrom-Json
        ($body.rules | Where-Object type -eq 'required_status_checks').parameters.required_status_checks.context | Should -Be 'verify (ubuntu-latest)'
    }
}

Describe 'Fleet workflow enforces rulesets conditionally' {
    BeforeAll {
        $script:Workflow = Get-Content (Join-Path $RepoRoot '.github' 'workflows' 'downstream-sync.yml') -Raw
    }

    It 'applies the ruleset to each fleet repository and to the hub, without prompting' {
        $Workflow | Should -Match 'Set-GovernanceRuleset\.ps1 -Repository \$env:REPOSITORY -Confirm:\$false'
        $Workflow | Should -Match 'Set-GovernanceRuleset\.ps1 -Repository \$env:HUB_REPOSITORY -Confirm:\$false -RequiredCheck'
    }
}
