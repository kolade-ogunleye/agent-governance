BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    . (Join-Path $RepoRoot 'Test-GateProvenance.ps1')
    $script:Hub = 'octo/agent-governance'
    $script:Pr = [pscustomobject]@{ number = 7; head = [pscustomobject]@{ sha = 'c' * 40 } }
    $script:GateRef = [pscustomobject]@{ path = "$Hub/.github/workflows/governance-gate.yml@$('a' * 40)"; sha = 'a' * 40 }

    function Get-FakeRun {
        param([string]$Path = '.github/workflows/agent-governance.yml', [object[]]$References = @($GateRef), [hashtable]$Jobs)
        [pscustomobject]@{
            id = Get-Random; path = $Path; referenced_workflows = $References
            jobs = @($Jobs.GetEnumerator() | ForEach-Object { [pscustomobject]@{ name = $_.Key; conclusion = $_.Value } })
        }
    }
    $script:GenuineJobs = @{ 'governance / secret-scan' = 'success'; 'governance / integrity' = 'success'; 'governance / branch-policy' = 'success' }

    # The caller template at this hub commit, rendered the way Sync-AgentGovernance renders it.
    $script:HubCommit = "$(git -C $RepoRoot rev-parse HEAD)".Trim()
    $script:Rendered = (Get-Content (Join-Path $RepoRoot 'template' '.github' 'workflows' 'agent-governance.yml') -Raw).
        Replace('__HUB_REPOSITORY__', $Hub).Replace('__HUB_COMMIT__', $HubCommit).Replace('__DEFAULT_BRANCH__', 'main')
    function Get-CallerFinding {
        param([string]$Content)
        @(Get-CallerWorkflowFinding -PullRequest $Pr -Content $Content -Hub $Hub -HubPath $RepoRoot -DefaultBranch 'main')
    }
}

Describe 'Gate provenance: which run produced the required checks' {
    It 'accepts the required jobs from the caller workflow that calls the hub gate at a commit SHA' {
        @(Get-GateProvenanceFinding -PullRequest $Pr -Runs @(Get-FakeRun -Jobs $GenuineJobs) -Hub $Hub).Count | Should -Be 0
    }

    It 'reports a job with a required name from another workflow as spoofed' {
        $spoof = Get-FakeRun -Path '.github/workflows/ci.yml' -References @() -Jobs @{ 'governance / integrity' = 'success' }
        $f = @(Get-GateProvenanceFinding -PullRequest $Pr -Runs @((Get-FakeRun -Jobs $GenuineJobs), $spoof) -Hub $Hub)
        $f.Kind | Should -Be 'spoofed'
        $f.Job | Should -Be 'governance / integrity'
    }

    It 'reports the caller workflow as spoofed when it no longer calls the hub gate (<Case>)' -ForEach @(
        @{ Case = 'no reusable workflow'; Refs = @() }
        @{ Case = 'a fork of the gate'; Refs = @([pscustomobject]@{ path = "evil/agent-governance/.github/workflows/governance-gate.yml@$('a' * 40)" }) }
        @{ Case = 'the gate at a branch, not a SHA'; Refs = @([pscustomobject]@{ path = 'octo/agent-governance/.github/workflows/governance-gate.yml@main' }) }
    ) {
        $f = @(Get-GateProvenanceFinding -PullRequest $Pr -Runs @(Get-FakeRun -References $Refs -Jobs $GenuineJobs) -Hub $Hub)
        @($f | Where-Object Kind -eq 'spoofed').Count | Should -Be 2
    }

    It 'reports a required job that never passed in a genuine run as missing, not spoofed' {
        $jobs = @{ 'governance / secret-scan' = 'success'; 'governance / integrity' = 'failure' }
        $f = @(Get-GateProvenanceFinding -PullRequest $Pr -Runs @(Get-FakeRun -Jobs $jobs) -Hub $Hub)
        $f.Kind | Should -Be 'missing'
        $f.Job | Should -Be 'governance / integrity'
    }

    It 'reports both required jobs as missing when a pull request has no runs' {
        @(Get-GateProvenanceFinding -PullRequest $Pr -Runs @() -Hub $Hub | Where-Object Kind -eq 'missing').Count | Should -Be 2
    }
}

Describe 'Gate provenance: the caller workflow equals the hub template' {
    It 'accepts the caller exactly as the sync renders it' {
        (Get-CallerFinding -Content $Rendered).Count | Should -Be 0
    }

    It 'accepts the caller re-indented by a formatter (CRLF and blank lines too)' {
        $reformatted = (($Rendered -split "`n") | ForEach-Object { $_ -replace '^( +)', '$1$1' }) -join "`r`n"
        (Get-CallerFinding -Content ($reformatted + "`r`n`r`n")).Count | Should -Be 0
    }

    It 'reports the caller as tampered when <Case>' -ForEach @(
        @{ Case = 'a job is added beside the gate'; Edit = { param($t) $t.TrimEnd() + "`n  spoof:`n    name: governance / integrity`n    runs-on: ubuntu-latest`n    steps:`n      - run: exit 0`n" } }
        @{ Case = 'the gate job is renamed'; Edit = { param($t) $t.Replace("`n  governance:`n", "`n  real:`n") } }
        @{ Case = 'the gate input is pointed at another hub'; Edit = { param($t) $t.Replace("hub_repository: $Hub", 'hub_repository: evil/hub') } }
        @{ Case = 'the gate is not called at all'; Edit = { "name: Agent Governance`non: pull_request`njobs: {}`n" } }
        @{ Case = 'the pin names a commit the hub does not have'; Edit = { param($t) $t.Replace($HubCommit, 'f' * 40) } }
    ) {
        $f = Get-CallerFinding -Content (& $Edit $Rendered)
        $f.Kind | Should -Be 'tampered'
    }
}

Describe 'Gate provenance audit in the fleet workflow' {
    BeforeAll {
        $script:Workflow = Get-Content (Join-Path $RepoRoot '.github' 'workflows' 'downstream-sync.yml') -Raw
    }

    It 'runs the audit per fleet repository with a read-only App token that can read Actions runs' {
        $job = [regex]::Match($Workflow, '(?ms)^  provenance-audit:.*?(?=^  [a-z-]+:\s*$|\z)').Value
        $job | Should -Not -BeNullOrEmpty
        $job | Should -Match 'permission-actions: read'
        $job | Should -Match 'permission-contents: read'
        $job | Should -Match 'permission-pull-requests: read'
        $job | Should -Not -Match 'permission-[a-z-]+: write'
        $job | Should -Match 'fetch-depth: 0'
        $job | Should -Match 'Test-GateProvenance\.ps1 -Repository'
    }
}
