BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Guard = Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1'

    function ConvertTo-HookPayload {
        param([Parameter(Mandatory = $true)][string]$Command, [string]$Tool = 'Bash')
        return (@{ hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress)
    }
}

Describe 'agent-bash-guard.ps1 (Claude Code PreToolUse hook)' {
    It 'blocks: <Command>' -ForEach @(
        @{ Command = 'git commit --no-verify -m "wip"' }
        @{ Command = 'git commit -nm "wip"' }
        @{ Command = 'git push --no-verify origin feat/x' }
        @{ Command = 'LEFTHOOK=0 git commit -m "wip"' }
        @{ Command = '$env:LEFTHOOK = "0"; git commit -m "wip"' }
        @{ Command = 'lefthook install' }
        @{ Command = 'npx lefthook uninstall' }
        @{ Command = 'git config core.hooksPath /tmp/empty' }
        @{ Command = 'git -c core.hooksPath=/dev/null commit -m "wip"' }
        @{ Command = 'git push origin main' }
        @{ Command = 'git push -u origin HEAD:master' }
        @{ Command = 'git status && git commit --no-verify -m "x"' }
    ) {
        $result = Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $Command)
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'Agent Governance'
    }

    It 'allows: <Command>' -ForEach @(
        @{ Command = 'git status' }
        @{ Command = 'git commit -m "fix -n and --no-verify parsing"' }
        @{ Command = 'git commit --amend --no-edit' }
        @{ Command = 'git push -u origin feat/maintenance-window' }
        @{ Command = 'git config --local core.hooksPath' }
        @{ Command = 'npm test' }
    ) {
        (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $Command)).ExitCode | Should -Be 0
    }

    It 'treats heredoc bodies as data (e.g. a commit message that names blocked flags)' {
        $command = "git commit -q -F - <<'EOF'`nfeat: block LEFTHOOK=0 and lefthook install`n`nAlso --no-verify.`nEOF`ngit log -1"
        (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $command)).ExitCode | Should -Be 0
    }

    It 'still inspects commands that follow a heredoc' {
        $command = "cat <<EOF > notes.txt`nhello`nEOF`ngit commit --no-verify -m x"
        (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $command)).ExitCode | Should -Be 2
    }

    It 'applies the same policy to the PowerShell tool' {
        $result = Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload -Command 'git commit --no-verify -m x' -Tool 'PowerShell')
        $result.ExitCode | Should -Be 2
    }

    It 'reports an unreadable payload as a non-blocking hook error (exit 1)' {
        (Invoke-HookScript -ScriptPath $Guard -InputText 'not json').ExitCode | Should -Be 1
    }
}

Describe 'Claude Code settings template' {
    BeforeAll {
        $script:SettingsPath = Join-Path $RepoRoot 'template' '.claude' 'settings.json'
        $script:Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    }

    It 'is strict JSON' {
        { Get-Content $SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'denies Read and Edit of <Pattern>' -ForEach @(
        @{ Pattern = '.env' }, @{ Pattern = '.env.*' }, @{ Pattern = '*.pem' }, @{ Pattern = '*.key' }, @{ Pattern = 'id_ed25519' }
    ) {
        $Settings.permissions.deny | Should -Contain "Read($Pattern)"
        $Settings.permissions.deny | Should -Contain "Edit($Pattern)"
    }

    It 'carves .env.example out of the deny rules after the rule it narrows' {
        $deny = @($Settings.permissions.deny)
        $deny.IndexOf('Read(!.env.example)') | Should -BeGreaterThan $deny.IndexOf('Read(.env.*)')
    }

    It 'wires the Bash guard as a PreToolUse hook for Bash and PowerShell in exec form' {
        $entry = @($Settings.hooks.PreToolUse)[0]
        $entry.matcher | Should -Be 'Bash|PowerShell'
        $hook = @($entry.hooks)[0]
        $hook.type | Should -Be 'command'
        $hook.command | Should -Be 'pwsh'
        $hook.args | Should -Contain '${CLAUDE_PROJECT_DIR}/scripts/guardrails/agent-bash-guard.ps1'
    }
}

Describe 'Governance gate workflow' {
    BeforeAll {
        $script:Gate = Get-Content (Join-Path $RepoRoot '.github' 'workflows' 'governance-gate.yml') -Raw
    }

    It 'defines secret-scan, branch-policy, and integrity jobs' {
        foreach ($job in @('secret-scan', 'branch-policy', 'integrity')) {
            $Gate | Should -Match "(?m)^  ${job}:\s*$"
        }
    }

    It 'validates the locked hub commit as a full SHA before using it as a checkout ref' {
        $Gate | Should -Match "\^\[0-9a-f\]\{40\}\$"
        $Gate | Should -Match 'ref: \$\{\{ steps\.lock\.outputs\.commit \}\}'
    }

    It 'runs the hub''s own verifier copy, not the caller''s' {
        $Gate | Should -Match 'run: \./_governance_hub/template/scripts/guardrails/verify-governance\.ps1 -HubTemplate \./_governance_hub/template'
    }

    It 'never interpolates caller-controlled values directly into run scripts' {
        foreach ($block in [regex]::Matches($Gate, '(?ms)^\s+run: \|\n(.*?)(?=^\s{6}- |\z)')) {
            $block.Groups[1].Value | Should -Not -Match '\$\{\{\s*(inputs\.|github\.head_ref)'
        }
    }

    It 'pins every action to a full commit SHA' {
        foreach ($uses in [regex]::Matches($Gate, '(?m)^\s+uses:\s+(\S+)')) {
            $uses.Groups[1].Value | Should -Match '@[0-9a-f]{40}$'
        }
    }
}

Describe 'Default-branch ruleset' {
    BeforeAll {
        $script:RulesetPath = Join-Path $RepoRoot 'rulesets' 'default-branch-protection.json'
        $script:Ruleset = Get-Content $RulesetPath -Raw | ConvertFrom-Json
    }

    It 'targets the default branch and is actively enforced' {
        $Ruleset.target | Should -Be 'branch'
        $Ruleset.enforcement | Should -Be 'active'
        $Ruleset.conditions.ref_name.include | Should -Contain '~DEFAULT_BRANCH'
    }

    It 'requires pull requests and forbids deletion and force-push' {
        $types = @($Ruleset.rules | ForEach-Object type)
        $types | Should -Contain 'pull_request'
        $types | Should -Contain 'deletion'
        $types | Should -Contain 'non_fast_forward'
    }
}

Describe 'Set-GovernanceRuleset.ps1' {
    BeforeEach {
        $script:ShimDir = Join-Path $TestDrive ("shims-" + [guid]::NewGuid().ToString('N'))
        $script:GhLog = Join-Path $TestDrive ("gh-" + [guid]::NewGuid().ToString('N') + '.log')
        New-CommandShim -Directory $ShimDir -Name 'gh' -MarkerPath $GhLog
        $script:OriginalPath = $env:PATH
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
    }

    AfterEach {
        $env:PATH = $OriginalPath
    }

    It 'makes no GitHub API calls under -WhatIf' {
        & (Join-Path $RepoRoot 'Set-GovernanceRuleset.ps1') -Repository 'octo/example' -WhatIf 6>$null
        $GhLog | Should -Not -Exist
    }

    It 'rejects a malformed repository name' {
        { & (Join-Path $RepoRoot 'Set-GovernanceRuleset.ps1') -Repository 'not a repo' -WhatIf } | Should -Throw
    }
}
