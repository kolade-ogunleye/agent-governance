BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:HubRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:SyncScript = Join-Path $HubRoot 'Invoke-DownstreamSync.ps1'

    function New-DownstreamClone {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates disposable fixtures inside Pester TestDrive only.')]
        param()
        # A downstream repository with a local bare origin, cloned as CI would check it out.
        $name = [guid]::NewGuid().ToString('N')
        $bare = Join-Path $TestDrive "$name-origin.git"
        $seed = New-TestRepo -Path (Join-Path $TestDrive "$name-seed")
        git init --quiet --bare --initial-branch=main $bare
        git -C $bare config gc.auto 0
        git -C $seed remote add origin $bare
        git -C $seed push --quiet origin main
        $clone = Join-Path $TestDrive "$name-clone"
        git clone --quiet $bare $clone
        git -C $clone config user.email 'sync@example.invalid'
        git -C $clone config user.name 'Sync'
        git -C $clone config commit.gpgsign false
        return [pscustomobject]@{ Clone = $clone; Bare = $bare }
    }
}

AfterAll {
    Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
}

Describe 'Invoke-DownstreamSync.ps1' {
    BeforeEach {
        $script:Down = New-DownstreamClone
        $script:ShimDir = Join-Path $TestDrive ("shims-" + [guid]::NewGuid().ToString('N'))
        $script:GhLog = Join-Path $TestDrive ("gh-" + [guid]::NewGuid().ToString('N') + '.log')
        New-CommandShim -Directory $ShimDir -Name 'gh' -MarkerPath $GhLog
        $script:OriginalPath = $env:PATH
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
        $script:HubShort = "$(git -C $HubRoot rev-parse --short=7 HEAD)".Trim()
    }

    AfterEach {
        $env:PATH = $OriginalPath
    }

    It 'pushes a uniquely named sync branch and opens a pull request' {
        $result = & $SyncScript -RepoPath $Down.Clone 6>$null 3>$null

        $result.Action | Should -Be 'opened'
        $result.Branch | Should -Be "chore/agent-governance-sync-$HubShort"
        (git -C $Down.Bare branch --list "chore/agent-governance-sync-$HubShort") | Should -Not -BeNullOrEmpty
        Get-Content $GhLog -Raw | Should -Match "pr create .*--head chore/agent-governance-sync-$HubShort"
    }

    It 'reports up-to-date and opens nothing when the default branch already matches the hub' {
        & $SyncScript -RepoPath $Down.Clone 6>$null 3>$null | Out-Null
        git -C $Down.Bare update-ref refs/heads/main "refs/heads/chore/agent-governance-sync-$HubShort"
        [System.IO.File]::Delete($GhLog)
        git -C $Down.Clone fetch --quiet origin

        $result = & $SyncScript -RepoPath $Down.Clone 6>$null 3>$null

        $result.Action | Should -Be 'up-to-date'
        $GhLog | Should -Not -Exist
    }

    It 'with -DryRun, commits locally but pushes nothing and opens no pull request' {
        $result = & $SyncScript -RepoPath $Down.Clone -DryRun 6>$null 3>$null

        $result.Action | Should -Be 'would-open'
        (git -C $Down.Bare branch --list 'chore/agent-governance-sync-*') | Should -BeNullOrEmpty
        $GhLog | Should -Not -Exist
    }

    It 'branches from the latest default branch, ignoring a stale local chore/agent-governance' {
        git -C $Down.Clone checkout --quiet -b chore/agent-governance
        Add-FixtureCommit -RepoPath $Down.Clone -Files @{ 'stale.txt' = "stale`n" }
        git -C $Down.Clone checkout --quiet main

        $result = & $SyncScript -RepoPath $Down.Clone 6>$null 3>$null

        $result.Action | Should -Be 'opened'
        (git -C $Down.Bare ls-tree -r --name-only "chore/agent-governance-sync-$HubShort") | Should -Not -Contain 'stale.txt'
    }
}

Describe 'Downstream sync workflow and fleet list' {
    BeforeAll {
        $script:Workflow = Get-Content (Join-Path $HubRoot '.github' 'workflows' 'downstream-sync.yml') -Raw
        $script:Fleet = Get-Content (Join-Path $HubRoot 'fleet.json') -Raw | ConvertFrom-Json
    }

    It 'lists owner/name repositories only' {
        @($Fleet.repositories).Count | Should -BeGreaterThan 0
        foreach ($r in $Fleet.repositories) { $r | Should -Match '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' }
    }

    It 'runs only on the schedule or manual dispatch from main' {
        $Workflow | Should -Match '(?m)^\s+schedule:'
        $Workflow | Should -Match '(?m)^\s+workflow_dispatch:'
        $Workflow | Should -Not -Match '(?m)^\s+(pull_request|pull_request_target|push):'
        $Workflow | Should -Match "github\.ref == 'refs/heads/main'"
    }

    It 'skips with a warning when the sync token is absent' {
        $Workflow | Should -Match 'AGENT_GOVERNANCE_SYNC_TOKEN'
        $Workflow | Should -Match '::warning::'
    }

    It 'pins every action to a full commit SHA' {
        foreach ($uses in [regex]::Matches($Workflow, '(?m)^\s+uses:\s+(\S+)')) {
            $uses.Groups[1].Value | Should -Match '@[0-9a-f]{40}$'
        }
    }
}
