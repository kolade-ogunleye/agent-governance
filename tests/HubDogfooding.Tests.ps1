BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $realHub = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    # A disposable copy of the hub (engine + template) that is itself a git repository with a GitHub-looking
    # origin, so the engine can be pointed at its own root the way maintainers run it on the real hub.
    $script:HubRoot = Join-Path $TestDrive 'self-hub'
    New-Item -ItemType Directory -Path $HubRoot | Out-Null
    Copy-Item (Join-Path $realHub 'Sync-AgentGovernance.ps1') $HubRoot
    Copy-Item (Join-Path $realHub 'template') $HubRoot -Recurse
    [System.IO.File]::WriteAllText((Join-Path $HubRoot 'PROJECT.md'), "# Project Specification & Architecture: self-hub`n`n## 1. Project Overview & Tech Stack`n`n- hub`n")
    git -C $HubRoot init --quiet --initial-branch=main
    git -C $HubRoot config gc.auto 0
    git -C $HubRoot config user.email 'hub@example.invalid'
    git -C $HubRoot config user.name 'Hub'
    git -C $HubRoot config commit.gpgsign false
    git -C $HubRoot remote add origin 'https://github.com/octo/self-hub.git'
    git -C $HubRoot add -A
    git -C $HubRoot -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: hub baseline'

    . (Join-Path $HubRoot 'Sync-AgentGovernance.ps1')
}

AfterAll {
    Get-ChildItem -LiteralPath $HubRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
}

Describe 'Syncing the hub repository itself (dogfooding)' {
    It 'mirrors the template into the root copies and writes the lock, without a caller workflow' {
        $warnings = Sync-AgentGovernance -RepoPath $HubRoot 6>$null 3>&1 | ForEach-Object { "$_" }

        Join-Path $HubRoot '.agent-governance.lock' | Should -Exist
        Join-Path $HubRoot '.github/workflows/agent-governance.yml' | Should -Not -Exist
        (Get-Content (Join-Path $HubRoot 'AGENTS.md') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubRoot 'template/AGENTS.md') -Raw)
        $lock = Get-Content (Join-Path $HubRoot '.agent-governance.lock') -Raw | ConvertFrom-Json
        $lock.files.'AGENTS.md' | Should -Match '^[0-9a-f]{64}$'
        $lock.files.'scripts/guardrails/agent-bash-guard.ps1' | Should -Match '^[0-9a-f]{64}$'
        ($warnings -join "`n") | Should -Not -Match 'agent-governance\.yml'
    }

    It 'passes the trusted verification the CI gate runs for the hub (template as the trusted source)' {
        Sync-AgentGovernance -RepoPath $HubRoot 6>$null 3>$null
        Push-Location $HubRoot
        try {
            & pwsh -NoProfile -File (Join-Path $HubRoot 'template/scripts/guardrails/verify-governance.ps1') -HubTemplate (Join-Path $HubRoot 'template') 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally { Pop-Location }
    }

    It 'treats uncommitted template edits as the content to mirror, not as unrelated project work' {
        $templateLefthook = Join-Path $HubRoot 'template/lefthook.yml'
        $original = Get-Content $templateLefthook -Raw
        try {
            [System.IO.File]::WriteAllText($templateLefthook, $original + "# hub edit under test`n")
            $warnings = Sync-AgentGovernance -RepoPath $HubRoot 6>$null 3>&1 | ForEach-Object { "$_" }

            ($warnings -join "`n") | Should -Not -Match 'SKIPPED'
            (Get-Content (Join-Path $HubRoot 'lefthook.yml') -Raw) | Should -Match 'hub edit under test'
            (Get-Content (Join-Path $HubRoot '.agent-governance.lock') -Raw | ConvertFrom-Json).hub.dirty | Should -BeTrue
        } finally {
            [System.IO.File]::WriteAllText($templateLefthook, $original)
            Sync-AgentGovernance -RepoPath $HubRoot 6>$null 3>$null
        }
    }

    It 'still skips the hub when unrelated project files are modified' {
        $engine = Join-Path $HubRoot 'Sync-AgentGovernance.ps1'
        $original = Get-Content $engine -Raw
        try {
            [System.IO.File]::WriteAllText($engine, $original + "# unrelated edit`n")
            $warnings = Sync-AgentGovernance -RepoPath $HubRoot 6>$null 3>&1 | ForEach-Object { "$_" }
            ($warnings -join "`n") | Should -Match 'SKIPPED'
        } finally {
            [System.IO.File]::WriteAllText($engine, $original)
        }
    }

    It 'lists the caller workflow as skipped for the hub in -WhatIf' {
        $plan = Sync-AgentGovernance -RepoPath $HubRoot -WhatIf 6>&1 | ForEach-Object { "$_" }
        ($plan -join "`n") | Should -Match 'skip\s+\.github/workflows/agent-governance\.yml \(the hub dogfoods'
    }
}

Describe 'The real hub carries a current lock' {
    It 'has .agent-governance.lock at the repository root' {
        Join-Path $realHub '.agent-governance.lock' | Should -Exist
    }

    It 'verifies against its own template, exactly as the CI gate runs it' {
        Push-Location $realHub
        try {
            $out = & pwsh -NoProfile -File (Join-Path $realHub 'template/scripts/guardrails/verify-governance.ps1') -HubTemplate (Join-Path $realHub 'template') 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        } finally { Pop-Location }
    }
}
