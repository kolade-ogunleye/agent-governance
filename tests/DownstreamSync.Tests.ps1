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

    It 'with -InstallFormatter, installs the repository''s locked formatter without install scripts' {
        $seed = Join-Path $TestDrive ("seed-" + [guid]::NewGuid().ToString('N'))
        git clone --quiet $Down.Bare $seed
        git -C $seed config user.email 'seed@example.invalid'
        git -C $seed config user.name 'Seed'
        Add-FixtureCommit -RepoPath $seed -Files @{
            'package.json'      = '{ "name": "fixture", "devDependencies": { "prettier": "3.9.8" } }'
            'package-lock.json' = '{ "lockfileVersion": 3 }'
            '.gitignore'        = "node_modules/`n"
        }
        git -C $seed push --quiet origin main
        $npmLog = Join-Path $TestDrive ("npm-" + [guid]::NewGuid().ToString('N') + '.log')
        New-CommandShim -Directory $ShimDir -Name 'npm' -MarkerPath $npmLog

        & $SyncScript -RepoPath $Down.Clone -InstallFormatter -DryRun 6>$null 3>$null | Out-Null

        (Get-Content $npmLog -Raw) | Should -Match '^ci --ignore-scripts'
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

Describe 'Invoke-DownstreamSync.ps1 pull request nudges' {
    BeforeAll {
        # A scripted gh: `pr create` prints the new URL, `pr list` without --head reports older open sync
        # pull requests, and `label create` fails when GH_SHIM_LABEL_FAILS is set.
        $script:NudgeShimDir = Join-Path $TestDrive 'gh-nudge-shim'
        New-Item -ItemType Directory -Path $NudgeShimDir | Out-Null
        $impl = @'
$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath $env:GH_SHIM_LOG -Value ($args -join ' ')
if ($args[0] -eq 'label' -and $env:GH_SHIM_LABEL_FAILS) { exit 1 }
if ($args[0] -eq 'pr' -and $args[1] -eq 'create') { Write-Output 'https://github.com/octo/example/pull/12'; exit 0 }
if ($args[0] -eq 'pr' -and $args[1] -eq 'list' -and $args -notcontains '--head') {
    Write-Output '[{"number":7,"headRefName":"chore/agent-governance-sync-0000000"},{"number":9,"headRefName":"feat/unrelated"}]'
    exit 0
}
exit 0
'@
        [System.IO.File]::WriteAllText((Join-Path $NudgeShimDir 'gh-impl.ps1'), $impl)
        if ($IsWindows) {
            [System.IO.File]::WriteAllText((Join-Path $NudgeShimDir 'gh.ps1'), "& '$((Join-Path $NudgeShimDir 'gh-impl.ps1'))' @args`nexit `$LASTEXITCODE`n")
        } else {
            $sh = Join-Path $NudgeShimDir 'gh'
            [System.IO.File]::WriteAllText($sh, "#!/bin/sh`nexec pwsh -NoProfile -File '$((Join-Path $NudgeShimDir 'gh-impl.ps1'))' `"`$@`"`n")
            chmod +x $sh
        }
    }

    BeforeEach {
        $script:Down = New-DownstreamClone
        $script:GhLog = Join-Path $TestDrive ("gh-" + [guid]::NewGuid().ToString('N') + '.log')
        $script:Saved = @{ PATH = $env:PATH; GH_SHIM_LOG = $env:GH_SHIM_LOG; GH_SHIM_LABEL_FAILS = $env:GH_SHIM_LABEL_FAILS }
        $env:PATH = $NudgeShimDir + [System.IO.Path]::PathSeparator + $env:PATH
        $env:GH_SHIM_LOG = $GhLog
    }

    AfterEach {
        foreach ($k in $Saved.Keys) { [Environment]::SetEnvironmentVariable($k, $Saved[$k]) }
    }

    It 'labels the pull request and assigns it to the token owner' {
        & $SyncScript -RepoPath $Down.Clone 6>$null 3>$null | Out-Null

        $log = Get-Content $GhLog -Raw
        $log | Should -Match 'label create agent-governance --force'
        $log | Should -Match '(?s)pr create .*--assignee @me --label agent-governance'
    }

    It 'closes only older sync pull requests, pointing them at the new one' {
        $result = & $SyncScript -RepoPath $Down.Clone 6>$null 3>$null

        $result.Superseded | Should -Be @(7)
        $log = Get-Content $GhLog -Raw
        $log | Should -Match 'pr list --state open --limit 100 --json number,headRefName'
        $log | Should -Match 'pr close 7 --delete-branch --comment Superseded by #12'
        $log | Should -Not -Match 'pr close 9'
        $LASTEXITCODE | Should -Be 0
    }

    It 'still opens the pull request, unlabelled, when the label cannot be created' {
        $env:GH_SHIM_LABEL_FAILS = '1'

        $result = & $SyncScript -RepoPath $Down.Clone -WarningVariable warnings 6>$null 3>$null

        $result.Action | Should -Be 'opened'
        ($warnings -join "`n") | Should -Match 'without it'
        Get-Content $GhLog -Raw | Should -Not -Match '--label'
    }
}

Describe 'Downstream sync workflow and fleet list' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $HubRoot '.github' 'workflows' 'downstream-sync.yml'
        $script:Workflow = Get-Content $WorkflowPath -Raw
        $script:PlanStep = Join-Path $TestDrive 'validate-fleet.ps1'
        [System.IO.File]::WriteAllText($PlanStep, (Get-WorkflowStepScript -WorkflowPath $WorkflowPath -StepName 'Validate the fleet list'))

        function Invoke-PlanStep {
            param([Parameter(Mandatory = $true)][string]$Fleet)
            $outputs = Join-Path $TestDrive ("outputs-" + [guid]::NewGuid().ToString('N'))
            $saved = @{ FLEET = $env:FLEET; HUB_REPOSITORY = $env:HUB_REPOSITORY; GITHUB_OUTPUT = $env:GITHUB_OUTPUT }
            $env:FLEET = $Fleet; $env:HUB_REPOSITORY = 'octo/agent-governance'; $env:GITHUB_OUTPUT = $outputs
            try {
                $out = (& pwsh -NoProfile -File $PlanStep 2>&1) -join "`n"
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out; Outputs = $(if (Test-Path $outputs) { Get-Content $outputs -Raw } else { '' }) }
            } finally {
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
        }
    }

    It 'mints the sync App token with workflows: write, since every sync updates the pinned gate workflow' {
        $syncMint = [regex]::Match($Workflow, '(?s)permission-contents: write.*?permission-metadata: read').Value
        $syncMint | Should -Match 'permission-workflows: write'
    }

    # Owner-approved 2026-10-11: fleet.json moved to the private operations repository, which passes the list in.
    It 'accepts a fleet list of owner/name repositories and derives the hub name' {
        $r = Invoke-PlanStep -Fleet '["octo/one","octo/two.site"]'
        $r.ExitCode | Should -Be 0
        $r.Outputs | Should -Match 'repositories=\[\{"full":"octo/one","name":"one"\},\{"full":"octo/two.site","name":"two.site"\}\]'
        $r.Outputs | Should -Match 'hub_name=agent-governance'
    }

    It 'rejects a fleet entry that is not owner/name (<Case>)' -ForEach @(
        @{ Case = 'bare name'; Fleet = '["one"]' }
        @{ Case = 'extra path segment'; Fleet = '["octo/one/two"]' }
        @{ Case = 'shell metacharacters'; Fleet = '["octo/one;whoami"]' }
        @{ Case = 'empty list'; Fleet = '[]' }
    ) {
        (Invoke-PlanStep -Fleet $Fleet).ExitCode | Should -Not -Be 0
    }

    It 'rejects a repository listed twice (GitHub names are case-insensitive)' {
        $r = Invoke-PlanStep -Fleet '["octo/one","Octo/One"]'
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'Duplicate fleet entry'
    }

    It 'passes the fleet list to the script through env, never interpolated' {
        $Workflow | Should -Match 'FLEET: \$\{\{ inputs\.fleet \}\}'
        $Workflow | Should -Not -Match 'run:[^\n]*\$\{\{ inputs\.fleet'
    }

    # Owner-approved 2026-10-11: called by the private operations repository at a pinned release commit.
    It 'runs only when called (workflow_call), from the caller''s main, at the calling hub commit' {
        $Workflow | Should -Match '(?m)^  workflow_call:'
        $Workflow | Should -Not -Match '(?m)^\s+(pull_request|pull_request_target|push|schedule|workflow_dispatch):'
        $Workflow | Should -Match "github\.ref == 'refs/heads/main'"
        $Workflow | Should -Match 'Invoke-DownstreamSync\.ps1 -RepoPath downstream -InstallFormatter'
        $Workflow | Should -Match 'ref: \$\{\{ job\.workflow_sha \}\}'
        $Workflow | Should -Not -Match 'secrets: inherit'
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
