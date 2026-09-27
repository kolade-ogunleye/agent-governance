BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Verifier = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/guardrails/verify-governance.ps1')).Path
}

Describe 'Distribution failure reporting' {
    BeforeAll { . (Join-Path $PSScriptRoot '../Sync-AgentGovernance.ps1') }

    It 'localizes a relative hook path that escapes the target repository' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $outside = Join-Path $TestDrive 'outside-hooks'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'pre-commit'), "#!/bin/sh`n# untouched`n")
        git -C $repo config core.hooksPath ../outside-hooks
        Sync-AgentGovernance -RepoPath $repo 6>$null 3>$null
        git -C $repo config core.hooksPath | Should -Be '.githooks'
        Get-Content (Join-Path $outside 'pre-commit') -Raw | Should -BeExactly "#!/bin/sh`n# untouched`n"
    }

    It 'throws when a user hook rejects the baseline commit and preserves staged changes' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $hooks = Join-Path $repo '.githooks'
        New-Item -ItemType Directory -Path $hooks | Out-Null
        Add-FixtureCommit -RepoPath $repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`nexit 1`n" }
        if (-not $IsWindows) { & chmod +x (Join-Path $hooks 'pre-commit') }
        git -C $repo config core.hooksPath .githooks
        { Sync-AgentGovernance -RepoPath $repo -BranchAndCommit 6>$null } | Should -Throw '*Governance commit failed*'
        git -C $repo log -1 --format=%s | Should -Be 'chore: add fixture files'
        git -C $repo diff --cached --name-only | Should -Contain '.agent-governance.lock'
    }
}

Describe 'Trusted governance verification' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Hub = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Hub | Out-Null
        [IO.File]::WriteAllText((Join-Path $Hub 'AGENTS.md'), "# Contract`n")
        Copy-Item (Join-Path $Hub 'AGENTS.md') $Repo
        $script:LockPath = Join-Path $Repo '.agent-governance.lock'
        $script:Manifest = @{ version = 1; files = @{ 'AGENTS.md' = (Get-FileHash (Join-Path $Repo 'AGENTS.md')).Hash.ToLowerInvariant() } }
    }

    It 'rejects an empty manifest' {
        $Manifest.files = @{}
        $Manifest | ConvertTo-Json -Depth 5 | Set-Content $LockPath
        (Invoke-Guardrail -ScriptPath $Verifier -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'rejects unsupported manifest versions' {
        $Manifest.version = 99
        $Manifest | ConvertTo-Json -Depth 5 | Set-Content $LockPath
        (Invoke-Guardrail -ScriptPath $Verifier -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'rejects a missing lock in trusted verification mode' {
        Push-Location $Repo
        try {
            & pwsh -NoProfile -File $Verifier -HubTemplate $Hub 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally { Pop-Location }
    }

    It 'rejects omitted canonical files even if remaining lock entries are valid' {
        [IO.File]::WriteAllText((Join-Path $Hub 'lefthook.yml'), "pre-commit: {} `n")
        $Manifest | ConvertTo-Json -Depth 5 | Set-Content $LockPath
        Push-Location $Repo
        try {
            & pwsh -NoProfile -File $Verifier -HubTemplate $Hub 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally { Pop-Location }
    }

    It 'rejects a nonexistent trusted template' {
        $Manifest | ConvertTo-Json -Depth 5 | Set-Content $LockPath
        Push-Location $Repo
        try {
            & pwsh -NoProfile -File $Verifier -HubTemplate (Join-Path $Hub 'missing') 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally { Pop-Location }
    }
}
