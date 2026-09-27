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
    git -C $HubRoot init --quiet --initial-branch=main
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
