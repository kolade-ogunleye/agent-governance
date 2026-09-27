BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $realHub = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    # A fake hub: a copy of the engine and template in its own repository, whose origin looks like
    # GitHub for fetching while pushes go to a local bare repository (so remote-tracking refs exist).
    $script:HubRoot = Join-Path $TestDrive 'fake-hub'
    $script:HubRemote = Join-Path $TestDrive 'fake-hub-remote.git'
    New-Item -ItemType Directory -Path $HubRoot | Out-Null
    Copy-Item (Join-Path $realHub 'Sync-AgentGovernance.ps1') $HubRoot
    Copy-Item (Join-Path $realHub 'template') $HubRoot -Recurse
    git init --quiet --bare --initial-branch=main $HubRemote
    # No background auto-gc: a detached gc can hold object files open while Pester removes TestDrive.
    git -C $HubRemote config gc.auto 0
    git -C $HubRoot init --quiet --initial-branch=main
    git -C $HubRoot config gc.auto 0
    git -C $HubRoot config user.email 'hub@example.invalid'
    git -C $HubRoot config user.name 'Hub'
    git -C $HubRoot config commit.gpgsign false
    git -C $HubRoot remote add origin 'https://github.com/octo/fake-hub.git'
    git -C $HubRoot config remote.origin.pushurl $HubRemote
    git -C $HubRoot add -A
    git -C $HubRoot -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: fake hub'
    git -C $HubRoot push --quiet origin main

    . (Join-Path $HubRoot 'Sync-AgentGovernance.ps1')

    function Get-CallerWorkflowText {
        param([Parameter(Mandatory = $true)][string]$RepoPath)
        $path = Join-Path $RepoPath '.github/workflows/agent-governance.yml'
        if (Test-Path -LiteralPath $path) { return [System.IO.File]::ReadAllText($path) }
        return $null
    }
}

AfterAll {
    # Git writes object files read-only on Windows; clear the flag so Pester can delete TestDrive.
    foreach ($root in @($HubRoot, $HubRemote)) {
        Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    }
}

Describe 'Managed Claude Code settings propagation' {
    BeforeAll {
        function Publish-HubSettingsChange {
            # A newer hub version of the settings template, committed and pushed.
            $template = Join-Path $HubRoot 'template/.claude/settings.json'
            $json = Get-Content $template -Raw | ConvertFrom-Json
            $json | Add-Member -NotePropertyName 'cleanupPeriodDays' -NotePropertyValue 30 -Force
            # LF only: ConvertTo-Json emits CRLF on Windows, which the template's eol=lf rule rejects.
            [System.IO.File]::WriteAllText($template, ((($json | ConvertTo-Json -Depth 10) -replace "`r`n", "`n") + "`n"))
            git -C $HubRoot -c core.hooksPath=.git/no-hooks commit --quiet -am 'feat: settings v2'
            if ($LASTEXITCODE -ne 0) { throw 'Fake hub settings commit failed.' }
            git -C $HubRoot push --quiet origin main
            if ($LASTEXITCODE -ne 0) { throw 'Fake hub push failed.' }
            # Guard against a vacuous pass: the engine must see a clean, pushed hub.
            "$(git -C $HubRoot status --porcelain -- template)".Trim() | Should -BeNullOrEmpty
        }
    }

    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:SettingsPath = Join-Path $Repo '.claude/settings.json'
        $script:HubBaseline = "$(git -C $HubRoot rev-parse HEAD)".Trim()
    }

    AfterEach {
        # Undo the published v2 locally and on the fake remote, so later tests see the baseline hub.
        git -C $HubRoot reset --quiet --hard $HubBaseline
        git -C $HubRoot push --quiet --force origin main
    }

    It 'updates an unmodified engine-written settings file to the newer hub version' {
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null
        Publish-HubSettingsChange

        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        (Get-Content $SettingsPath -Raw | ConvertFrom-Json).cleanupPeriodDays | Should -Be 30
    }

    It 'updates a settings file that matches an earlier hub version even without a lock entry' {
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null
        $lockPath = Join-Path $Repo '.agent-governance.lock'
        $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
        $lock.files.PSObject.Properties.Remove('.claude/settings.json')
        [System.IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 5))
        Publish-HubSettingsChange

        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        (Get-Content $SettingsPath -Raw | ConvertFrom-Json).cleanupPeriodDays | Should -Be 30
    }

    It 'keeps a team-edited settings file and warns' {
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null
        $edited = (Get-Content $SettingsPath -Raw | ConvertFrom-Json)
        $edited | Add-Member -NotePropertyName 'model' -NotePropertyValue 'team-choice' -Force
        [System.IO.File]::WriteAllText($SettingsPath, ($edited | ConvertTo-Json -Depth 10) + "`n")
        Publish-HubSettingsChange

        $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

        $after = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        $after.model | Should -Be 'team-choice'
        $after.PSObject.Properties['cleanupPeriodDays'] | Should -BeNullOrEmpty
        ($warnings -join "`n") | Should -Match 'settings\.json'
    }
}

Describe 'Managed governance-gate caller workflow' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:HubHead = "$(git -C $HubRoot rev-parse HEAD)".Trim()
    }

    It 'pins the gate to the pushed hub commit and hub repository' {
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        $text = Get-CallerWorkflowText -RepoPath $Repo
        $text | Should -Match '(?m)^# Managed by agent-governance'
        $text | Should -Match ([regex]::Escape("uses: octo/fake-hub/.github/workflows/governance-gate.yml@$HubHead"))
        $text | Should -Match '(?m)^\s+hub_repository: octo/fake-hub$'
        $text | Should -Not -Match '__[A-Z_]+__'
    }

    It 'passes the generated workflow to the repository''s Prettier' {
        # node_modules is ignored in real repositories; untracked, it would trip the sync's safety gate.
        Add-FixtureCommit -RepoPath $Repo -Files @{ '.gitignore' = "node_modules/`n" }
        $binDir = Join-Path $Repo 'node_modules/.bin'
        $log = Join-Path $TestDrive ("prettier-" + [guid]::NewGuid().ToString('N') + '.log')
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        if ($IsWindows) { [System.IO.File]::WriteAllText((Join-Path $binDir 'prettier.cmd'), "@echo %* >> `"$log`"`r`n@exit /b 0`r`n") }
        else { [System.IO.File]::WriteAllText((Join-Path $binDir 'prettier'), "#!/bin/sh`necho `"`$*`" >> '$log'`n"); chmod +x (Join-Path $binDir 'prettier') }

        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        (Get-Content $log -Raw) | Should -Match '\.github/workflows/agent-governance\.yml'
    }

    It 'records the workflow in the lock so tampering is detected' {
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        $lock = Get-Content (Join-Path $Repo '.agent-governance.lock') -Raw | ConvertFrom-Json
        $lock.files.'.github/workflows/agent-governance.yml' | Should -Match '^[0-9a-f]{64}$'
    }

    It 'targets the repository''s default branch' {
        git -C $Repo update-ref refs/remotes/origin/master HEAD
        git -C $Repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        (Get-CallerWorkflowText -RepoPath $Repo) | Should -Match '(?m)^\s+branches: \[master\]$'
    }

    It 'never replaces an unmanaged workflow with the same name' {
        Add-FixtureCommit -RepoPath $Repo -Files @{ '.github/workflows/agent-governance.yml' = "name: Team owned`non: push`njobs: {}`n" }

        $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

        (Get-CallerWorkflowText -RepoPath $Repo) | Should -BeExactly "name: Team owned`non: push`njobs: {}`n"
        ($warnings -join "`n") | Should -Match 'unmanaged'
    }

    It 'updates the pin after the hub advances and is pushed' {
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null
        git -C $HubRoot -c core.hooksPath=.git/no-hooks commit --quiet --allow-empty -m 'chore: advance hub'
        git -C $HubRoot push --quiet origin main
        $newHead = "$(git -C $HubRoot rev-parse HEAD)".Trim()

        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null

        (Get-CallerWorkflowText -RepoPath $Repo) | Should -Match ([regex]::Escape("@$newHead"))
    }

    Context 'when the pin would not be fetchable' {
        AfterEach {
            git -C $HubRoot checkout --quiet -- template
            git -C $HubRoot reset --quiet --hard origin/main
        }

        It 'skips with a warning when the hub commit is not pushed' {
            git -C $HubRoot -c core.hooksPath=.git/no-hooks commit --quiet --allow-empty -m 'chore: local only'

            $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

            Get-CallerWorkflowText -RepoPath $Repo | Should -BeNullOrEmpty
            ($warnings -join "`n") | Should -Match 'not pushed'
        }

        It 'skips with a warning when the hub template has uncommitted changes' {
            [System.IO.File]::AppendAllText((Join-Path $HubRoot 'template/lefthook.yml'), "# local edit`n")

            $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

            Get-CallerWorkflowText -RepoPath $Repo | Should -BeNullOrEmpty
            ($warnings -join "`n") | Should -Match 'uncommitted changes'
        }
    }
}
