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

    Context 'plan Phase 2 regressions' {
        It 'adds *.key to an existing .gitignore that already lists *.keystore (plan defect 4)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.gitignore' = "*.keystore`n" }

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.gitignore')) | Should -Contain '*.key'
        }

        It 'adds a missing .gitattributes rule even when a longer rule contains it as a substring (plan defect 4)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.gitattributes' = "*.md text eol=lf diff=markdown`n" }

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.gitattributes')) | Should -Contain '*.md text eol=lf'
        }

        It 'recognises Claude Code (CLAUDECODE) in the agent hook gate (plan defect 1)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`nexit 0`n" }
            git -C $Repo config --local core.hooksPath .githooks

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw) | Should -Match '\$CLAUDECODE'
        }

        It 'preserves a custom .github/copilot-instructions.md (plan defect 7)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.github/copilot-instructions.md' = "# Copilot: prefer Result types`n" }

            Invoke-QuietSync -RepoPath $Repo

            $legacy = Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md'
            $legacy | Should -Exist
            (Get-Content $legacy -Raw) | Should -Match 'prefer Result types'
        }

        It 'preserves custom AGENTS.md and CLAUDE.md content together, once each (plan defect 7)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{
                'AGENTS.md' = "# Team rules`nUse tabs.`n"
                'CLAUDE.md' = "# Claude notes`nRun make check.`n"
            }

            Invoke-QuietSync -RepoPath $Repo

            $legacy = Get-Content (Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md') -Raw
            $legacy | Should -Match 'Use tabs\.'
            $legacy | Should -Match 'Run make check\.'
            ([regex]::Matches($legacy, 'Use tabs\.')).Count | Should -Be 1
        }

        It 'appends newly found custom instructions to an existing legacy archive (plan defect 7)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{
                'docs/LEGACY-AGENT-NOTES.md'      = "# Legacy`nOld note.`n"
                '.github/copilot-instructions.md' = "# Copilot: prefer Result types`n"
            }

            Invoke-QuietSync -RepoPath $Repo

            $legacy = Get-Content (Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md') -Raw
            $legacy | Should -Match 'Old note\.'
            $legacy | Should -Match 'prefer Result types'
        }

        It 'does not archive an earlier hub version of the governance contract (plan defect 7)' {
            $olderContract = (Get-Content (Join-Path $HubDir 'AGENTS.md') -Raw) + "`n## 9. RETIRED SECTION`n"
            Add-FixtureCommit -RepoPath $Repo -Files @{ 'AGENTS.md' = $olderContract }

            Invoke-QuietSync -RepoPath $Repo

            Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md' | Should -Not -Exist
        }

        It 'installs a fail-closed gate in the default hooks path that survives a commit (plan defect 2)' {
            Invoke-QuietSync -RepoPath $Repo -BranchAndCommit

            $hook = Get-Content (Join-Path $Repo '.git/hooks/pre-commit') -Raw
            $hook | Should -Match '# >>> agent-governance'
            $hook | Should -Match 'lefthook run pre-commit --no-auto-install'
            $hook | Should -Match '\$CLAUDECODE'
        }

        It 'replaces a Lefthook-generated hook instead of appending to it (plan defect 2)' {
            $hooksDir = Join-Path $Repo '.git/hooks'
            [System.IO.File]::WriteAllText((Join-Path $hooksDir 'pre-commit'), "#!/bin/sh`ncall_lefthook()`n{`n  lefthook `"`$@`"`n}`n`ncall_lefthook run `"pre-commit`" `"`$@`"`n")

            Invoke-QuietSync -RepoPath $Repo

            $hook = Get-Content (Join-Path $hooksDir 'pre-commit') -Raw
            $hook | Should -Not -Match 'call_lefthook'
            $hook | Should -Match '# >>> agent-governance'
        }

        It 'keeps user hook lines that follow a legacy governance block and leaves exactly one block (plan defect 7)' {
            $legacyBlock = @(
                '# Chained by Agent Governance (Lefthook + Gitleaks)'
                'if command -v lefthook >/dev/null 2>&1; then'
                '  lefthook run pre-commit || exit 1'
                'else'
                '  echo "missing" >&2'
                '  if [ -n "$AGENT_ROLE" ]; then'
                '    exit 1'
                '  fi'
                'fi'
            ) -join "`n"
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`necho before-block`n$legacyBlock`necho after-block`nexit 0`n" }
            git -C $Repo config --local core.hooksPath .githooks

            Invoke-QuietSync -RepoPath $Repo

            $hook = Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw
            $hook | Should -Match 'echo before-block'
            $hook | Should -Match 'echo after-block'
            $hook | Should -Not -Match '# Chained by Agent Governance'
            ([regex]::Matches($hook, '# >>> agent-governance')).Count | Should -Be 1
        }

        It 'produces an identical hook when re-synced (plan defect 7)' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`necho existing-check`nexit 0`n" }
            git -C $Repo config --local core.hooksPath .githooks
            Invoke-QuietSync -RepoPath $Repo
            $first = Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw
            $firstDefault = Get-Content (Join-Path $Repo '.githooks/pre-push') -Raw

            Invoke-QuietSync -RepoPath $Repo

            Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw | Should -BeExactly $first
            Get-Content (Join-Path $Repo '.githooks/pre-push') -Raw | Should -BeExactly $firstDefault
        }
    }
}
