BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '..' 'Sync-AgentGovernance.ps1')
    $script:HubDir = Join-Path $PSScriptRoot '..' 'template'

    function Invoke-QuietSync {
        param(
            [Parameter(Position = 0)][string]$Action = 'sync',
            [Parameter(Mandatory = $true)][string]$RepoPath,
            [switch]$BranchAndCommit
        )
        # The engine is chatty via Write-Host (information stream 6); keep test output readable.
        Sync-AgentGovernance -Action $Action -RepoPath $RepoPath -BranchAndCommit:$BranchAndCommit 6>$null 3>$null
    }
}

# The engine creates NTFS junctions for .claude/rules and .gemini/rules, which are Windows-only
# until plan Phase 5 replaces them. Guardrail tests cover the cross-platform surface meanwhile.
Describe 'Sync-AgentGovernance' -Skip:(-not $IsWindows) {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }

    It 'deploys the canonical contract and rule files' {
        Invoke-QuietSync -RepoPath $Repo

        (Get-Content (Join-Path $Repo 'AGENTS.md') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir 'AGENTS.md') -Raw)
        Join-Path $Repo '.agents/rules/languages.md' | Should -Exist
        Join-Path $Repo '.agents/rules/security-performance.md' | Should -Exist
        Join-Path $Repo 'scripts/guardrails/protect-main.ps1' | Should -Exist
        Join-Path $Repo 'lefthook.yml' | Should -Exist
    }

    It 'generates PROJECT.md from the detected pnpm stack' {
        Add-FixtureCommit -RepoPath $Repo -Files @{
            'package.json'   = '{ "name": "fixture", "scripts": { "test": "vitest", "lint": "eslint ." } }'
            'pnpm-lock.yaml' = "lockfileVersion: '9.0'`n"
        }

        Invoke-QuietSync -RepoPath $Repo

        $project = Get-Content (Join-Path $Repo 'PROJECT.md') -Raw
        $project | Should -Match 'Node\.js / Web \(pnpm\)'
        $project | Should -Match '`pnpm test`'
        $project | Should -Match '`pnpm run lint`'
    }

    It 'archives a pre-existing custom AGENTS.md before replacing it' {
        Add-FixtureCommit -RepoPath $Repo -Files @{ 'AGENTS.md' = "# Custom team rules`nUse tabs.`n" }

        Invoke-QuietSync -RepoPath $Repo

        (Get-Content (Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md') -Raw) | Should -Match 'Use tabs\.'
        (Get-Content (Join-Path $Repo 'PROJECT.md') -Raw) | Should -Match 'LEGACY-AGENT-NOTES\.md'
    }

    It 'skips a repository with uncommitted project changes' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'app.js'), "console.log(1);`n")

        Invoke-QuietSync -RepoPath $Repo

        Join-Path $Repo 'AGENTS.md' | Should -Not -Exist
    }

    It 'writes nothing in audit mode' {
        Invoke-QuietSync audit -RepoPath $Repo

        Join-Path $Repo 'AGENTS.md' | Should -Not -Exist
        git -C $Repo status --porcelain | Should -BeNullOrEmpty
    }

    It 'chains the governance block before a terminal exit 0 in a custom hooksPath' {
        Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`necho existing-check`nexit 0`n" }
        git -C $Repo config --local core.hooksPath .githooks

        Invoke-QuietSync -RepoPath $Repo

        $hook = Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw
        $hook | Should -Match 'echo existing-check'
        $hook | Should -Match 'lefthook run pre-commit'
        $hook.IndexOf('lefthook run pre-commit') | Should -BeLessThan $hook.LastIndexOf('exit 0')
    }

    It 'is idempotent: a second sync leaves no further changes' {
        Invoke-QuietSync -RepoPath $Repo
        git -C $Repo add -A
        git -C $Repo -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: first sync'

        Invoke-QuietSync -RepoPath $Repo

        git -C $Repo status --porcelain | Should -BeNullOrEmpty
    }

    It 'with -BranchAndCommit, commits the baseline on chore/agent-governance and leaves main untouched' {
        $mainHead = git -C $Repo rev-parse main

        Invoke-QuietSync -RepoPath $Repo -BranchAndCommit

        git -C $Repo branch --show-current | Should -Be 'chore/agent-governance'
        git -C $Repo rev-parse main | Should -Be $mainHead
        git -C $Repo log -1 --format=%s | Should -Be 'chore(governance): install unified agent contract and deterministic guardrails'
    }

    Context 'known defects (enabled as each plan phase lands)' {
        It 'adds *.key to an existing .gitignore that already lists *.keystore (plan defect 4)' -Skip {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.gitignore' = "*.keystore`n" }

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.gitignore')) | Should -Contain '*.key'
        }

        It 'recognises Claude Code (CLAUDECODE) in the agent hook gate (plan defect 1)' -Skip {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`nexit 0`n" }
            git -C $Repo config --local core.hooksPath .githooks

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw) | Should -Match '\$CLAUDECODE'
        }

        It 'preserves a custom .github/copilot-instructions.md (plan defect 7)' -Skip {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.github/copilot-instructions.md' = "# Copilot: prefer Result types`n" }

            Invoke-QuietSync -RepoPath $Repo

            $legacy = Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md'
            $legacy | Should -Exist
            (Get-Content $legacy -Raw) | Should -Match 'prefer Result types'
        }
    }
}
