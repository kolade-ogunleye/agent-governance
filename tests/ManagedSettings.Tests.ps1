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

    It 'runs a byte-identical copy of the hub guard installed beside the policy, not the user-writable hub clone' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dest = Join-Path $dir 'managed-settings.json'
        $result = & $Installer -DestinationPath $dest -Confirm:$false 6>$null
        $installedGuard = Join-Path $dir 'agent-bash-guard.ps1'
        $result.Guard | Should -Be $installedGuard
        $installedGuard | Should -Exist
        (Get-FileHash $installedGuard).Hash | Should -Be (Get-FileHash (Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1')).Hash
        $hookArgs = @(@(@((Get-Content $dest -Raw | ConvertFrom-Json).hooks.PreToolUse)[0].hooks)[0].args)
        $hookArgs | Should -Contain $installedGuard
        ($hookArgs -join ' ') | Should -Not -Match ([regex]::Escape((Join-Path $RepoRoot 'template')))
    }

    It 'removes the installed guard with the policy, and writes neither under -WhatIf' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dest = Join-Path $dir 'managed-settings.json'
        & $Installer -DestinationPath $dest -WhatIf | Out-Null
        (Join-Path $dir 'agent-bash-guard.ps1') | Should -Not -Exist
        & $Installer -DestinationPath $dest -Confirm:$false 6>$null | Out-Null
        (& $Installer -DestinationPath $dest -Remove -Confirm:$false).Action | Should -Be 'removed'
        $dest | Should -Not -Exist
        (Join-Path $dir 'agent-bash-guard.ps1') | Should -Not -Exist
    }

    Context '-Verify (read-only check of an installed policy)' {
        BeforeAll {
            function Invoke-Verify {
                param([Parameter(Mandatory = $true)][string]$Dest)
                $rows = & $Installer -DestinationPath $Dest -Verify 6>$null
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Rows = @($rows) }
            }
            function Get-CheckRow {
                param($Result, [string]$Like)
                return @($Result.Rows | Where-Object { $_.Check -like $Like })
            }
        }

        BeforeEach {
            $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Dest = Join-Path $Dir 'managed-settings.json'
        }

        It 'passes every content check on a fresh install, and fails the administrator-only checks on a user-writable folder' {
            & $Installer -DestinationPath $Dest -Confirm:$false 6>$null | Out-Null
            $r = Invoke-Verify -Dest $Dest
            foreach ($like in @('Policy installed', 'Guard copy installed*', 'Guard copy is byte-identical*', 'Policy equals*', 'Policy hook runs*')) {
                (Get-CheckRow $r $like).Passed | Should -BeTrue -Because $like
            }
            # TestDrive is writable by the current user, which -Verify must report.
            @(Get-CheckRow $r 'Only administrators can change*').Count | Should -Be 3
            @(Get-CheckRow $r 'Only administrators can change*' | Where-Object Passed).Count | Should -Be 0
            (Get-CheckRow $r 'SUMMARY').Passed | Should -BeFalse
            $r.ExitCode | Should -Be 1
        }

        It 'reports the hub commit and the guard SHA-256 a reviewer can recompute' {
            & $Installer -DestinationPath $Dest -Confirm:$false 6>$null | Out-Null
            $summary = (Get-CheckRow (Invoke-Verify -Dest $Dest) 'SUMMARY').Detail
            $hubGuard = (Get-FileHash (Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
            $summary | Should -Match "guard sha256 $hubGuard"
            $summary | Should -Match "hub $("$(git -C $RepoRoot rev-parse HEAD)".Trim())"
        }

        It 'fails the identity check when the installed guard differs from the hub guard' {
            & $Installer -DestinationPath $Dest -Confirm:$false 6>$null | Out-Null
            [System.IO.File]::AppendAllText((Join-Path $Dir 'agent-bash-guard.ps1'), "exit 0`n")
            $row = Get-CheckRow (Invoke-Verify -Dest $Dest) 'Guard copy is byte-identical*'
            $row.Passed | Should -BeFalse
            $row.Detail | Should -Match 're-run the installer elevated'
        }

        It 'fails when the policy hook runs a guard other than the installed copy' {
            & $Installer -DestinationPath $Dest -Confirm:$false 6>$null | Out-Null
            $hubGuard = Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1'
            $text = [System.IO.File]::ReadAllText($Dest).Replace(((Join-Path $Dir 'agent-bash-guard.ps1') | ConvertTo-Json).Trim('"'), ($hubGuard | ConvertTo-Json).Trim('"'))
            [System.IO.File]::WriteAllText($Dest, $text)
            $r = Invoke-Verify -Dest $Dest
            (Get-CheckRow $r 'Policy hook runs*').Passed | Should -BeFalse
            (Get-CheckRow $r 'Policy equals*').Passed | Should -BeFalse
        }

        It 'reports a missing install and writes nothing' {
            $r = Invoke-Verify -Dest $Dest
            (Get-CheckRow $r 'Policy installed').Passed | Should -BeFalse
            (Get-CheckRow $r 'Guard copy installed*').Passed | Should -BeFalse
            $r.ExitCode | Should -Be 1
            $Dir | Should -Not -Exist
        }

        It 'prints the report when it fails as a separate process, not only when it passes' {
            # The documented command is pwsh -File; exit used to end it before the table was formatted.
            $out = (& pwsh -NoProfile -File $Installer -DestinationPath $Dest -Verify 2>&1) -join "`n"
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'Policy installed\s+False'
            $out | Should -Match 'SUMMARY\s+False'
        }
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
