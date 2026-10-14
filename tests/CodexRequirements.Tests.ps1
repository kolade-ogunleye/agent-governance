BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $script:Installer = Join-Path $RepoRoot 'Install-CodexRequirements.ps1'
    $script:HubGuard = Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1'
    $script:Python = @('python3', 'python') | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1

    function Get-Rendered {
        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'requirements.toml'
        & $Installer -DestinationPath $dest -Confirm:$false 6>$null | Out-Null
        return [pscustomobject]@{ Path = $dest; Text = [System.IO.File]::ReadAllText($dest); Guard = Join-Path (Split-Path -Parent $dest) 'hooks' 'agent-bash-guard.ps1' }
    }
}

Describe 'Codex requirements (admin-enforced Codex policy)' {
    It 'renders valid TOML with every placeholder filled' {
        $r = Get-Rendered
        $r.Text | Should -Not -Match '__[A-Z_]+__'
        if (-not $Python) { throw 'Python 3.11+ (tomllib) is required to parse the rendered TOML.' }
        $out = (& $Python.Source -c "import sys, tomllib; tomllib.load(open(sys.argv[1], 'rb')); print('ok')" $r.Path 2>&1) -join "`n"
        $out | Should -Be 'ok'
    }

    It 'never allows running without approvals or without the sandbox' {
        $t = (Get-Rendered).Text
        $t | Should -Match '(?m)^allowed_approval_policies = \["untrusted", "on-request"\]$'
        $t | Should -Match '(?m)^allowed_sandbox_modes = \["read-only", "workspace-write"\]$'
        $settings = (($t -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $settings | Should -Not -Match 'danger-full-access"|"never"'
    }

    It 'pins hooks on and denies reads of secrets and credential directories' {
        $t = (Get-Rendered).Text
        $t | Should -Match '(?ms)^\[features\]\s*\n(?:#[^\n]*\n)*hooks = true'
        foreach ($p in '"/**/.env"', '"/**/*.pem"', '"/**/*.key"', '"~/.ssh"', '"~/.aws"', '"~/.gnupg"') { $t | Should -Match ([regex]::Escape($p)) }
    }

    It 'forbids the common bypass and push-to-main commands without relying on a script: <Name>' -ForEach @(
        @{ Name = 'git commit --no-verify'; Pattern = '{ token = "git" }, { token = "commit" }, { token = "--no-verify" }' }
        @{ Name = 'git commit -n'; Pattern = '{ token = "git" }, { token = "commit" }, { token = "-n" }' }
        @{ Name = 'git push --no-verify'; Pattern = '{ token = "git" }, { token = "push" }, { token = "--no-verify" }' }
        @{ Name = 'lefthook install/uninstall'; Pattern = '{ token = "lefthook" }, { any_of = ["install", "uninstall"] }' }
        @{ Name = 'core.hooksPath'; Pattern = '{ token = "git" }, { token = "config" }, { any_of = ["core.hooksPath", "core.hookspath"] }' }
        @{ Name = 'push to main'; Pattern = '{ token = "git" }, { token = "push" }, { token = "origin" }, { any_of = ["main", "master", "HEAD:main", "HEAD:master"] }' }
    ) {
        $t = (Get-Rendered).Text
        $line = ($t -split "`n") | Where-Object { $_.Contains($Pattern) }
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Match 'decision = "forbidden"'
    }

    It 'runs the installed guard copy on every Bash call, through PowerShell by absolute path' {
        $r = Get-Rendered
        $r.Text | Should -Match '(?m)^matcher = "\^Bash\$"$'
        $key = if ($IsWindows) { 'command_windows' } else { 'command' }
        $line = [regex]::Match($r.Text, "(?m)^$key = '(.*)'$").Groups[1].Value
        $line | Should -BeLike "*""$($r.Guard)""*"
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $line | Should -BeLike """$pwsh"" -NoProfile -File *"
        Test-Path -LiteralPath $r.Guard | Should -BeTrue
        (Get-FileHash $r.Guard).Hash | Should -Be (Get-FileHash $HubGuard).Hash
    }

    It 'blocks a Codex-shaped Bash payload with exit 2 (extra Codex fields are ignored)' {
        $payload = @{ session_id = 's'; turn_id = 't'; hook_event_name = 'PreToolUse'; model = 'gpt'; permission_mode = 'default'; tool_name = 'Bash'; tool_use_id = 'u'; tool_input = @{ command = 'git commit --no-verify -m wip' } } | ConvertTo-Json -Compress
        $null = $payload | & pwsh -NoProfile -File $HubGuard 2>&1
        $LASTEXITCODE | Should -Be 2
        $null = (@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = 'git status' } } | ConvertTo-Json -Compress) | & pwsh -NoProfile -File $HubGuard 2>&1
        $LASTEXITCODE | Should -Be 0
    }

    It 'previews without writing under -WhatIf' {
        $dest = Join-Path $TestDrive 'whatif' 'requirements.toml'
        (& $Installer -DestinationPath $dest -WhatIf 6>$null).Action | Should -Be 'would-install'
        Join-Path $TestDrive 'whatif' | Should -Not -Exist
    }

    It 'verifies content but reports a user-writable install as not administrator-only' {
        $r = Get-Rendered
        $rows = @(& $Installer -DestinationPath $r.Path -Verify 6>$null)
        $LASTEXITCODE | Should -Be 1
        foreach ($like in 'Requirements installed', 'Guard copy installed*', 'Guard copy is byte-identical*', 'Requirements equal*', 'Managed hook runs*') {
            ($rows | Where-Object { $_.Check -like $like }).Passed | Should -BeTrue -Because $like
        }
        @($rows | Where-Object { $_.Check -like 'Only administrators can change*' -and $_.Passed }).Count | Should -Be 0
    }

    It 'fails verification when the requirements were edited or the guard tampered with' {
        $r = Get-Rendered
        [System.IO.File]::WriteAllText($r.Path, ([System.IO.File]::ReadAllText($r.Path) -replace '"untrusted", "on-request"', '"never"'))
        [System.IO.File]::AppendAllText($r.Guard, "exit 0`n")
        $rows = @(& $Installer -DestinationPath $r.Path -Verify 6>$null)
        ($rows | Where-Object Check -like 'Requirements equal*').Passed | Should -BeFalse
        ($rows | Where-Object Check -like 'Guard copy is byte-identical*').Passed | Should -BeFalse
    }

    It 'removes the requirements and the guard copy' {
        $r = Get-Rendered
        (& $Installer -DestinationPath $r.Path -Remove -Confirm:$false 6>$null).Action | Should -Be 'removed'
        $r.Path | Should -Not -Exist
        $r.Guard | Should -Not -Exist
    }

    It 'locks the Windows install folder to administrators, since %ProgramData% lets users create files' {
        $text = Get-Content $Installer -Raw
        $text | Should -Match 'SetAccessRuleProtection\(\$true, \$false\)'
        $text | Should -Match "'S-1-5-32-545', 'ReadAndExecute'"
        $text | Should -Match 'if \(\$IsWindows -and -not \$DestinationPath\) \{ Set-AdministratorOnlyAcl'
    }
}
