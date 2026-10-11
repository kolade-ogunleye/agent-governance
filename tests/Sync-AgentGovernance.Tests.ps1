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

# Exercise legacy junctions on Windows and equivalent directory symlinks on Unix.
Describe 'Sync-AgentGovernance' {
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

    It 'names PROJECT.md after the origin remote, not the checkout folder (<Url>)' -ForEach @(
        @{ Url = 'https://github.com/octo/ai-os.git' }
        @{ Url = 'https://github.com/octo/ai-os' }
        @{ Url = 'git@github.com:octo/ai-os.git' }
        @{ Url = 'https://github.com/octo/ai-os/' }
    ) {
        git -C $Repo remote add origin $Url

        Invoke-QuietSync -RepoPath $Repo

        $project = Get-Content (Join-Path $Repo 'PROJECT.md') -Raw
        $project | Should -Match '(?m)^# Project Specification & Architecture: ai-os$'
        $project | Should -Match '(?m)^- \*\*Repository Name:\*\* ai-os$'
    }

    It 'names PROJECT.md after the checkout folder when there is no origin remote' {
        Invoke-QuietSync -RepoPath $Repo

        (Get-Content (Join-Path $Repo 'PROJECT.md') -Raw) | Should -Match "(?m)^- \*\*Repository Name:\*\* $([regex]::Escape((Split-Path -Leaf $Repo)))$"
    }

    It 'says no stack was detected instead of leaving the field empty' {
        Invoke-QuietSync -RepoPath $Repo

        $project = Get-Content (Join-Path $Repo 'PROJECT.md') -Raw
        $project | Should -Match '(?m)^- \*\*Detected Stack:\*\* None detected'
        $project | Should -Not -Match '(?m)^- \*\*Detected Stack:\*\*\s*$'
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

    Context 'tracked hook directories in fresh clones' {
        It 'updates tracked .githooks when the clone has no local core.hooksPath' {
            $legacy = "#!/bin/sh`necho team-check`n# Chained by Agent Governance (Lefthook + Gitleaks)`nif command -v lefthook >/dev/null 2>&1; then`n  lefthook run pre-commit || exit 1`nelse`n  echo missing >&2`n  if [ -n `"`$AGENT_ROLE`" ]; then`n    exit 1`n  fi`nfi`nexit 0`n"
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = $legacy }

            Invoke-QuietSync -RepoPath $Repo -BranchAndCommit

            $hook = Get-Content (Join-Path $Repo '.githooks/pre-commit') -Raw
            $hook | Should -Match '# >>> agent-governance'
            $hook | Should -Match 'echo team-check'
            @(git -C $Repo diff --name-only HEAD~1 HEAD) | Should -Contain '.githooks/pre-commit'
        }
    }

    Context 'hooks action' {
        It 'installs only the git gate, leaving staged work and tracked files untouched' {
            # A repository synced long ago: Lefthook's own hook, and work in progress staged.
            [System.IO.File]::WriteAllText((Join-Path $Repo '.git/hooks/pre-commit'), "#!/bin/sh`ncall_lefthook run `"pre-commit`" `"`$@`"`n")
            [System.IO.File]::WriteAllText((Join-Path $Repo 'wip.txt'), "work in progress`n")
            git -C $Repo add wip.txt

            Sync-AgentGovernance hooks -RepoPath $Repo 6>$null 3>$null

            (Get-Content (Join-Path $Repo '.git/hooks/pre-commit') -Raw) | Should -Match '# >>> agent-governance'
            @(git -C $Repo diff --cached --name-only) | Should -Be @('wip.txt')
            Join-Path $Repo 'AGENTS.md' | Should -Not -Exist
        }

        It 'refuses to edit hooks that git tracks, and says how to update them' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.githooks/pre-commit' = "#!/bin/sh`necho team-check`nexit 0`n" }
            git -C $Repo config --local core.hooksPath .githooks

            $warnings = Sync-AgentGovernance hooks -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

            ($warnings -join "`n") | Should -Match 'tracked'
            git -C $Repo status --porcelain | Should -BeNullOrEmpty
        }

        It 'warns and does nothing outside a git repository' {
            $plain = Join-Path $TestDrive ("plain-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $plain | Out-Null

            $warnings = Sync-AgentGovernance hooks -RepoPath $plain 6>$null 3>&1 | ForEach-Object { "$_" }

            ($warnings -join "`n") | Should -Match 'not a git repository'
        }
    }

    Context 'downstream formatting' {
        It 'warns when Prettier is configured but not installed' {
            Add-FixtureCommit -RepoPath $Repo -Files @{
                'package.json'      = '{ "name": "fixture", "devDependencies": { "prettier": "3.9.8" } }'
                '.prettierrc.json'  = '{ "tabWidth": 4 }'
            }

            $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

            ($warnings -join "`n") | Should -Match 'Prettier is configured in this repository but not installed'
        }

        It 'formats the governed files with the repository''s own Prettier when installed' {
            # node_modules is ignored in real repositories; untracked, it would trip the sync's safety gate.
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.prettierrc.json' = '{ "tabWidth": 4 }'; '.gitignore' = "node_modules/`n" }
            $binDir = Join-Path $Repo 'node_modules/.bin'
            $log = Join-Path $TestDrive ("prettier-" + [guid]::NewGuid().ToString('N') + '.log')
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null
            if ($IsWindows) { [System.IO.File]::WriteAllText((Join-Path $binDir 'prettier.cmd'), "@echo %* >> `"$log`"`r`n@exit /b 0`r`n") }
            else { [System.IO.File]::WriteAllText((Join-Path $binDir 'prettier'), "#!/bin/sh`necho `"`$*`" >> '$log'`n"); chmod +x (Join-Path $binDir 'prettier') }

            $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

            (Get-Content $log -Raw) | Should -Match '--write .*AGENTS\.md'
            ($warnings -join "`n") | Should -Not -Match 'not installed'
        }
    }

    Context 'Codex and Gemini agent settings' {
        It 'installs the Codex and Gemini settings templates when absent' {
            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.codex/config.toml') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir '.codex/config.toml') -Raw)
            (Get-Content (Join-Path $Repo '.gemini/settings.json') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir '.gemini/settings.json') -Raw)
        }

        It 'upgrades the Gemini settings an earlier engine wrote inline' {
            $legacy = "{`n  `"context`": {`n    `"fileName`": [`"AGENTS.md`", `"GEMINI.md`"]`n  }`n}`n"
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.gemini/settings.json' = $legacy }

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.gemini/settings.json') -Raw | ConvertFrom-Json).tools.confirmationRequired | Should -Not -BeNullOrEmpty
        }

        It 'keeps team-edited Codex settings' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.codex/config.toml' = "model = `"team-choice`"`n" }

            Invoke-QuietSync -RepoPath $Repo

            Get-Content (Join-Path $Repo '.codex/config.toml') -Raw | Should -BeExactly "model = `"team-choice`"`n"
        }

        It 'records managed agent settings in the lock' {
            Invoke-QuietSync -RepoPath $Repo

            $lock = Get-Content (Join-Path $Repo '.agent-governance.lock') -Raw | ConvertFrom-Json
            foreach ($rel in @('.claude/settings.json', '.gemini/settings.json', '.codex/config.toml')) {
                $lock.files.$rel | Should -Match '^[0-9a-f]{64}$'
            }
        }
    }

    Context 'rollout findings' {
        It 'installs the governance gate in a linked worktree (hooks live in the common git dir)' {
            $worktree = Join-Path $TestDrive ("wt-" + [guid]::NewGuid().ToString('N'))
            git -C $Repo worktree add -q -b chore/worktree-sync $worktree
            (Get-Item -LiteralPath (Join-Path $worktree '.git') -Force).PSIsContainer | Should -BeFalse

            Invoke-QuietSync -RepoPath $worktree

            Join-Path $worktree 'AGENTS.md' | Should -Exist
            (Get-Content (Join-Path $Repo '.git/hooks/pre-commit') -Raw) | Should -Match '# >>> agent-governance'
        }

        Context 'line endings stored as CRLF despite eol=lf' {
            BeforeEach {
                # A CRLF file committed before .gitattributes existed, then eol=lf added: the fresh-clone state.
                [System.IO.File]::WriteAllBytes((Join-Path $Repo 'legacy.ps1'), [System.Text.Encoding]::UTF8.GetBytes("Write-Output 1`r`nWrite-Output 2`r`n"))
                git -C $Repo -c core.autocrlf=false add legacy.ps1
                git -C $Repo -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: add crlf file'
                [System.IO.File]::WriteAllText((Join-Path $Repo '.gitattributes'), "* text=auto eol=lf`n")
                git -C $Repo add .gitattributes
                git -C $Repo -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: require lf'
                # Rewrite identical bytes so git re-inspects the file and reports the phantom modification.
                [System.IO.File]::WriteAllBytes((Join-Path $Repo 'legacy.ps1'), [System.IO.File]::ReadAllBytes((Join-Path $Repo 'legacy.ps1')))
            }

            It 'does not treat line-ending-only drift as uncommitted project work' {
                Invoke-QuietSync -RepoPath $Repo

                Join-Path $Repo 'AGENTS.md' | Should -Exist
            }

            It 'with -BranchAndCommit, renormalizes in its own content-neutral commit' {
                Invoke-QuietSync -RepoPath $Repo -BranchAndCommit

                (git -C $Repo -c core.quotepath=off ls-files --eol -- legacy.ps1) | Should -Match '^i/lf\s'
                @(git -C $Repo log --format=%s -2) | Should -Contain 'chore: renormalize line endings to match .gitattributes'
                git -C $Repo status --porcelain | Should -BeNullOrEmpty
            }

            It 'without -BranchAndCommit, warns and leaves the index untouched' {
                $warnings = Sync-AgentGovernance -RepoPath $Repo 6>$null 3>&1 | ForEach-Object { "$_" }

                ($warnings -join "`n") | Should -Match 'renormalize'
                (git -C $Repo -c core.quotepath=off ls-files --eol -- legacy.ps1) | Should -Match '^i/crlf\s'
            }
        }
    }

    Context 'plan Phase 6 progressive disclosure' {
        It 'deploys every path-scoped language rule to .agents/rules and .claude/rules' {
            Invoke-QuietSync -RepoPath $Repo

            foreach ($rule in (Get-ChildItem (Join-Path $HubDir '.agents/rules') -Filter 'lang-*.md')) {
                Join-Path $Repo ".agents/rules/$($rule.Name)" | Should -Exist
                (Get-Content (Join-Path $Repo ".claude/rules/$($rule.Name)") -Raw) | Should -BeExactly (Get-Content $rule.FullName -Raw)
            }
        }
    }

    Context 'plan Phase 5 distribution' {
        It 'writes CLAUDE.md as an @AGENTS.md import instead of a hard link' {
            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo 'CLAUDE.md') -Raw).Trim() | Should -BeExactly '@AGENTS.md'
        }

        It 're-syncs before the first commit, when the engine-created .gitignore is still untracked' {
            Invoke-QuietSync -RepoPath $Repo
            Remove-Item -LiteralPath (Join-Path $Repo 'lefthook.yml')

            Invoke-QuietSync -RepoPath $Repo

            Join-Path $Repo 'lefthook.yml' | Should -Exist
        }

        It 'migrates legacy hard links without writing through them into AGENTS.md' {
            Invoke-QuietSync -RepoPath $Repo
            foreach ($linked in @('CLAUDE.md', '.github/copilot-instructions.md')) {
                Remove-Item -LiteralPath (Join-Path $Repo $linked)
                New-Item -ItemType HardLink -Path (Join-Path $Repo $linked) -Target (Join-Path $Repo 'AGENTS.md') | Out-Null
            }

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo 'AGENTS.md') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir 'AGENTS.md') -Raw)
            (Get-Content (Join-Path $Repo 'CLAUDE.md') -Raw).Trim() | Should -BeExactly '@AGENTS.md'
            (Get-Content (Join-Path $Repo '.github/copilot-instructions.md') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir 'AGENTS.md') -Raw)
        }

        It 'writes .github/copilot-instructions.md as an independent copy of the contract' {
            Invoke-QuietSync -RepoPath $Repo
            $copilot = Join-Path $Repo '.github/copilot-instructions.md'
            $before = Get-Content $copilot -Raw
            $before | Should -BeExactly (Get-Content (Join-Path $Repo 'AGENTS.md') -Raw)

            [System.IO.File]::AppendAllText((Join-Path $Repo 'AGENTS.md'), "extra`n")

            Get-Content $copilot -Raw | Should -BeExactly $before
        }

        It 'installs Claude rules as real files, replacing a legacy junction without touching canonical rules' {
            Invoke-QuietSync -RepoPath $Repo
            $claudeRules = Join-Path $Repo '.claude/rules'
            [System.IO.Directory]::Delete($claudeRules, $true)
            $linkKind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $linkKind -Path $claudeRules -Target (Join-Path $Repo '.agents/rules') | Out-Null

            Invoke-QuietSync -RepoPath $Repo

            (Get-Item $claudeRules -Force).LinkType | Should -BeNullOrEmpty
            Join-Path $claudeRules 'languages.md' | Should -Exist
            Join-Path $Repo '.agents/rules/languages.md' | Should -Exist
        }

        It 'removes a legacy .gemini/rules junction and points Gemini CLI at AGENTS.md' {
            New-Item -ItemType Directory -Path (Join-Path $Repo '.agents/rules') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $Repo '.gemini') -Force | Out-Null
            $linkKind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $linkKind -Path (Join-Path $Repo '.gemini/rules') -Target (Join-Path $Repo '.agents/rules') | Out-Null

            Invoke-QuietSync -RepoPath $Repo

            Join-Path $Repo '.gemini/rules' | Should -Not -Exist
            Join-Path $Repo '.agents/rules/languages.md' | Should -Exist
            $gemini = Get-Content (Join-Path $Repo '.gemini/settings.json') -Raw | ConvertFrom-Json
            $gemini.context.fileName | Should -Contain 'AGENTS.md'
        }

        It 'never overwrites an existing .gemini/settings.json' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.gemini/settings.json' = '{ "theme": "custom" }' }

            Invoke-QuietSync -RepoPath $Repo

            Get-Content (Join-Path $Repo '.gemini/settings.json') -Raw | Should -BeExactly '{ "theme": "custom" }'
        }

        It 'does not create undocumented .claudeignore or .codexignore files' {
            Invoke-QuietSync -RepoPath $Repo

            Join-Path $Repo '.claudeignore' | Should -Not -Exist
            Join-Path $Repo '.codexignore' | Should -Not -Exist
        }

        It 'records a SHA-256 lock entry for every managed file' {
            Invoke-QuietSync -RepoPath $Repo

            $lock = Get-Content (Join-Path $Repo '.agent-governance.lock') -Raw | ConvertFrom-Json
            foreach ($rel in @('AGENTS.md', 'CLAUDE.md', 'lefthook.yml', 'scripts/guardrails/protect-main.ps1', '.agents/rules/languages.md')) {
                $lock.files.$rel | Should -BeExactly (Get-FileHash -Algorithm SHA256 (Join-Path $Repo $rel)).Hash.ToLowerInvariant()
            }
            $lock.hub.commit | Should -Match '^[0-9a-f]{40}$'
        }

        It 'archives team edits to the managed contract that the lock did not record' {
            Invoke-QuietSync -RepoPath $Repo
            git -C $Repo add -A
            git -C $Repo -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: first sync'
            [System.IO.File]::AppendAllText((Join-Path $Repo 'AGENTS.md'), "`n## 9. TEAM RULE`nNever deploy on Fridays.`n")
            git -C $Repo -c core.hooksPath=.git/no-hooks commit --quiet -am 'docs: team rule'

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo 'docs/LEGACY-AGENT-NOTES.md') -Raw) | Should -Match 'Never deploy on Fridays\.'
            (Get-Content (Join-Path $Repo 'AGENTS.md') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir 'AGENTS.md') -Raw)
        }

        It 'with -WhatIf, writes nothing and lists the planned changes' {
            $messages = Sync-AgentGovernance -RepoPath $Repo -WhatIf 6>&1 3>$null | ForEach-Object { "$_" }

            Join-Path $Repo 'AGENTS.md' | Should -Not -Exist
            git -C $Repo status --porcelain | Should -BeNullOrEmpty
            ($messages -join "`n") | Should -Match 'create\s+AGENTS\.md'
        }

        It 'with -All, syncs every repository under -FleetRoot' {
            $fleet = Join-Path $TestDrive ("fleet-" + [guid]::NewGuid().ToString('N'))
            $a = New-TestRepo -Path (Join-Path $fleet 'alpha')
            $b = New-TestRepo -Path (Join-Path $fleet 'beta')

            Sync-AgentGovernance -All -FleetRoot $fleet 6>$null 3>$null

            Join-Path $a 'AGENTS.md' | Should -Exist
            Join-Path $b 'AGENTS.md' | Should -Exist
        }
    }

    Context 'plan Phase 4 agent-native enforcement' {
        It 'deploys the Claude Code settings template when the repo has none' {
            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.claude/settings.json') -Raw) | Should -BeExactly (Get-Content (Join-Path $HubDir '.claude/settings.json') -Raw)
            Join-Path $Repo 'scripts/guardrails/agent-bash-guard.ps1' | Should -Exist
        }

        It 'never overwrites an existing project .claude/settings.json' {
            Add-FixtureCommit -RepoPath $Repo -Files @{ '.claude/settings.json' = '{ "model": "custom" }' }

            Invoke-QuietSync -RepoPath $Repo

            (Get-Content (Join-Path $Repo '.claude/settings.json') -Raw) | Should -BeExactly '{ "model": "custom" }'
        }
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
