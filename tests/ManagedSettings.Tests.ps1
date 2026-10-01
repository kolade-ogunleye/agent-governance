BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Installer = Join-Path $RepoRoot 'Install-ClaudeManagedSettings.ps1'
    $script:Managed = Get-Content (Join-Path $RepoRoot 'managed' 'claude-code-managed-settings.json') -Raw | ConvertFrom-Json
    $script:Project = Get-Content (Join-Path $RepoRoot 'template' '.claude' 'settings.json') -Raw | ConvertFrom-Json
}

Describe 'Claude Code managed settings template' {
    It 'is strict JSON' {
        { Get-Content (Join-Path $RepoRoot 'managed' 'claude-code-managed-settings.json') -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'carries exactly the deny rules of the project template (no drift between the two layers)' {
        @($Managed.permissions.deny) | Should -Be @($Project.permissions.deny)
    }

    It 'carries the same sandbox policy as the project template' {
        ($Managed.sandbox | ConvertTo-Json -Depth 12) | Should -Be ($Project.sandbox | ConvertTo-Json -Depth 12)
    }

    It 'turns off bypass mode, which only a managed source can lock' {
        $Managed.permissions.disableBypassPermissionsMode | Should -Be 'disable'
    }

    It 'wires the guard hook in exec form with a placeholder the installer renders' {
        $hook = @(@($Managed.hooks.PreToolUse)[0].hooks)[0]
        $hook.command | Should -Be 'pwsh'
        $hook.args | Should -Contain '__HUB_GUARD__'
    }
}

Describe 'Install-ClaudeManagedSettings.ps1' {
    It 'renders the absolute path of the hub guard and writes the file to -DestinationPath' {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'managed-settings.json'
        $result = & $Installer -DestinationPath $dest -Confirm:$false 6>$null
        $result.Action | Should -Be 'installed'
        $json = Get-Content $dest -Raw | ConvertFrom-Json
        $hookArgs = @(@(@($json.hooks.PreToolUse)[0].hooks)[0].args)
        $hookArgs | Should -Not -Contain '__HUB_GUARD__'
        $guard = $hookArgs | Where-Object { $_ -like '*agent-bash-guard.ps1' }
        $guard | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($guard) | Should -BeTrue
        $guard | Should -Exist
        @($json.permissions.deny) | Should -Be @($Project.permissions.deny)
    }

    It 'writes nothing under -WhatIf' {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'managed-settings.json'
        $result = & $Installer -DestinationPath $dest -WhatIf
        $result.Action | Should -Be 'would-install'
        $dest | Should -Not -Exist
    }

    It 'removes an installed file with -Remove and reports an absent one' {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'managed-settings.json'
        & $Installer -DestinationPath $dest -Confirm:$false 6>$null | Out-Null
        (& $Installer -DestinationPath $dest -Remove -Confirm:$false).Action | Should -Be 'removed'
        $dest | Should -Not -Exist
        (& $Installer -DestinationPath $dest -Remove -Confirm:$false).Action | Should -Be 'absent'
    }

    It 'targets the documented operating-system location by default' {
        $text = Get-Content $Installer -Raw
        $text | Should -Match '/etc/claude-code/managed-settings\.json'
        $text | Should -Match '/Library/Application Support/ClaudeCode/managed-settings\.json'
        $text | Should -Match "ClaudeCode' 'managed-settings\.json'"
    }
}

Describe 'Test-ToolchainFreshness.ps1' {
    BeforeAll { $script:Freshness = Join-Path $RepoRoot 'Test-ToolchainFreshness.ps1' }

    It 'reads every pinned tool version from the workflows and PROJECT.md' {
        $latest = Join-Path $TestDrive 'latest.json'
        [System.IO.File]::WriteAllText($latest, '{"pester":"0.0.1","psscriptanalyzer":"0.0.1","prettier":"0.0.1","gitleaks":"0.0.1","lefthook":"0.0.1"}')
        $rows = @(& $Freshness -RepoRoot $RepoRoot -LatestJson $latest 6>$null)
        ($rows | ForEach-Object Tool | Sort-Object) | Should -Be @('gitleaks', 'lefthook', 'pester', 'prettier', 'psscriptanalyzer')
        foreach ($r in $rows) { $r.Pinned | Should -Match '^[0-9]+(\.[0-9]+)+$'; $r.Status | Should -Be 'current' }
    }

    It 'flags a stale pin, warns, and fails only with -FailOnStale' {
        $latest = Join-Path $TestDrive 'latest-stale.json'
        [System.IO.File]::WriteAllText($latest, '{"pester":"99.0.0","psscriptanalyzer":"0.0.1","prettier":"0.0.1","gitleaks":"0.0.1","lefthook":"0.0.1"}')
        $out = & pwsh -NoProfile -File $Freshness -RepoRoot $RepoRoot -LatestJson $latest 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match '::warning::pester is pinned'
        & pwsh -NoProfile -File $Freshness -RepoRoot $RepoRoot -LatestJson $latest -FailOnStale *> $null
        $LASTEXITCODE | Should -Be 1
    }

    It 'reports unknown when a latest version is unavailable, without failing' {
        $latest = Join-Path $TestDrive 'latest-partial.json'
        [System.IO.File]::WriteAllText($latest, '{"pester":"0.0.1"}')
        $rows = @(& $Freshness -RepoRoot $RepoRoot -LatestJson $latest 6>$null)
        ($rows | Where-Object Tool -eq 'gitleaks').Status | Should -Be 'unknown'
    }
}
