BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $script:Installer = Join-Path $RepoRoot 'Install-AntigravityPermissions.ps1'
    $script:Rules = @((Get-Content (Join-Path $RepoRoot 'managed' 'antigravity-permissions.json') -Raw | ConvertFrom-Json).deny)
    # Antigravity anchors regex command rules to the whole command line.
    $script:CommandRegexes = @($Rules | Where-Object { $_ -like 'command(regex:*' } | ForEach-Object { '^(?:' + $_.Substring(14, $_.Length - 15) + ')$' })

    function Get-SettingFixture {
        param([string]$Json)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) 'settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) | Out-Null
        if ($null -ne $Json) { [System.IO.File]::WriteAllText($path, $Json) }
        return $path
    }
    function Test-Blocked { param([string]$Command) return [bool]($CommandRegexes | Where-Object { $Command -match $_ }) }
}

Describe 'Antigravity deny rules' {
    It 'blocks the bypass and push-to-main command: <Command>' -ForEach @(
        @{ Command = 'git commit --no-verify -m wip' }
        @{ Command = 'git push --no-verif origin feat/x' }
        @{ Command = 'cd app && git commit --no-verify' }
        @{ Command = 'LEFTHOOK=0 git commit -m wip' }
        @{ Command = 'LEFTHOOK_EXCLUDE=detect-secrets git commit -m wip' }
        @{ Command = 'npx lefthook install' }
        @{ Command = 'lefthook uninstall' }
        @{ Command = 'git config core.hooksPath /dev/null' }
        @{ Command = 'git -c core.hookspath=/tmp commit -m x' }
        @{ Command = 'GIT_CONFIG_COUNT=1 git commit -m x' }
        @{ Command = 'git push origin main' }
        @{ Command = 'git push -u origin HEAD:master' }
        @{ Command = 'git push origin +main' }
        @{ Command = 'git push origin refs/heads/main' }
    ) {
        Test-Blocked -Command $Command | Should -BeTrue
    }

    It 'leaves ordinary commands alone: <Command>' -ForEach @(
        @{ Command = 'git status' }
        @{ Command = 'git commit -m "verify the build"' }
        @{ Command = 'git push origin feat/main-menu' }
        @{ Command = 'git push -u origin fix/remaining-master-list' }
        @{ Command = 'npm test' }
    ) {
        Test-Blocked -Command $Command | Should -BeFalse
    }

    It 'denies reads of credential directories and writes to every file the hub manages' {
        foreach ($dir in '.ssh', '.aws', '.gnupg') { $Rules | Should -Contain "read_file(__HOME__/$dir)" }
        foreach ($managed in '.git/hooks/', 'scripts/guardrails/', '.agents/rules/', '.github/hooks/agent-governance.json', '.github/workflows/agent-governance.yml', '.agent-governance.lock', 'lefthook.yml', 'AGENTS.md') {
            $Rules | Should -Contain "write_file($managed)"
        }
    }
}

Describe 'Install-AntigravityPermissions.ps1' {
    It 'merges the rules into existing settings without touching anything else, and is idempotent' {
        $path = Get-SettingFixture -Json '{"theme":"dark","permissions":{"allow":["command(git)"],"ask":["command(*)"],"deny":["command(rm -rf)"]}}'
        & $Installer -SettingsPath $path -Confirm:$false | Out-Null
        & $Installer -SettingsPath $path -Confirm:$false | Out-Null
        $s = Get-Content $path -Raw | ConvertFrom-Json
        $s.theme | Should -Be 'dark'
        @($s.permissions.allow) | Should -Be @('command(git)')
        @($s.permissions.ask) | Should -Be @('command(*)')
        @($s.permissions.deny) | Should -Contain 'command(rm -rf)'
        @($s.permissions.deny).Count | Should -Be ($Rules.Count + 1)
        $userHome = ([Environment]::GetFolderPath('UserProfile')) -replace '\\', '/'
        @($s.permissions.deny) | Should -Contain "read_file($userHome/.ssh)"
        @($s.permissions.deny | Where-Object { $_ -like '*__HOME__*' }).Count | Should -Be 0
    }

    It 'creates the settings file when there is none' {
        $path = Get-SettingFixture
        (& $Installer -SettingsPath $path -Confirm:$false).Action | Should -Be 'installed'
        @((Get-Content $path -Raw | ConvertFrom-Json).permissions.deny).Count | Should -Be $Rules.Count
    }

    It 'verifies: exit 1 with rules missing, success once installed' {
        $path = Get-SettingFixture -Json '{}'
        $null = & $Installer -SettingsPath $path -Verify 6>$null
        $LASTEXITCODE | Should -Be 1
        & $Installer -SettingsPath $path -Confirm:$false | Out-Null
        $rows = @(& $Installer -SettingsPath $path -Verify 6>$null)
        ($rows | Where-Object Rule -eq 'SUMMARY').Present | Should -BeTrue
    }

    It 'removes only its own rules' {
        $path = Get-SettingFixture -Json '{"permissions":{"deny":["command(rm -rf)"]}}'
        & $Installer -SettingsPath $path -Confirm:$false | Out-Null
        & $Installer -SettingsPath $path -Remove -Confirm:$false | Out-Null
        @((Get-Content $path -Raw | ConvertFrom-Json).permissions.deny) | Should -Be @('command(rm -rf)')
    }

    It 'refuses to overwrite a settings file it cannot parse' {
        $path = Get-SettingFixture -Json '{ not json'
        { & $Installer -SettingsPath $path -Confirm:$false } | Should -Throw '*Cannot parse*'
        [System.IO.File]::ReadAllText($path) | Should -Be '{ not json'
    }
}
