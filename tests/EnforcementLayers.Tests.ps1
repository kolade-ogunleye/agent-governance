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

    It 'enables the OS sandbox without auto-approving sandboxed commands' {
        $Settings.sandbox.enabled | Should -BeTrue
        $Settings.sandbox.autoAllowBashIfSandboxed | Should -BeFalse
    }

    It 'keeps the sandbox warn-and-continue on unsupported platforms such as native Windows' {
        $Settings.sandbox.PSObject.Properties['failIfUnavailable'] | Should -BeNullOrEmpty
    }

    It 'denies sandboxed reads of <_>' -ForEach @('~/.ssh', '~/.aws', '~/.gnupg', '~/.config/gh', '~/.git-credentials', './**/.env') {
        $Settings.sandbox.filesystem.denyRead | Should -Contain $_
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

Describe 'Governance gate secret-scan range selection' {
    BeforeAll {
        # Extract the shipped run block of the "Scan for secrets" step, so the test exercises the real script.
        $script:ScanScript = Join-Path $TestDrive 'scan-for-secrets.sh'
        [System.IO.File]::WriteAllText($ScanScript, (Get-WorkflowStepScript -WorkflowPath (Join-Path $RepoRoot '.github' 'workflows' 'governance-gate.yml') -StepName 'Scan for secrets'))

        # Git's own bash on Windows (a bare 'bash' may resolve to WSL); system bash elsewhere.
        $script:Bash = 'bash'
        if ($IsWindows) {
            # git.exe may live in <Git>\cmd or <Git>\mingw64\bin; walk up to the Git root that has bin\bash.exe.
            $dir = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source
            while ($dir -and -not (Test-Path (Join-Path $dir 'bin' 'bash.exe'))) { $dir = Split-Path -Parent $dir }
            if (-not $dir) { throw 'Git for Windows bash.exe not found.' }
            $script:Bash = Join-Path $dir 'bin' 'bash.exe'
        }

        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive 'scan-repo')
        Add-FixtureCommit -RepoPath $Repo -Files @{ 'a.txt' = "a`n" }
        Add-FixtureCommit -RepoPath $Repo -Files @{ 'b.txt' = "b`n" }
        $script:Shas = @(git -C $Repo rev-list --reverse HEAD)

        $script:ShimDir = Join-Path $TestDrive 'scan-shims'
        New-Item -ItemType Directory -Path $ShimDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $ShimDir 'gitleaks'), "#!/bin/sh`necho `"`$*`" > `"`$GITLEAKS_ARGS_FILE`"`n")

        function Invoke-ScanStep {
            param([hashtable]$EventEnv)
            $argsFile = Join-Path $TestDrive ("args-" + [guid]::NewGuid().ToString('N') + '.txt')
            $saved = @{}
            $vars = @{ EVENT_NAME = ''; FULL_HISTORY = 'false'; PR_BASE_SHA = ''; PR_HEAD_SHA = ''; PUSH_BEFORE_SHA = ''; PUSH_AFTER_SHA = '' }
            foreach ($k in $EventEnv.Keys) { $vars[$k] = $EventEnv[$k] }
            $vars['GITLEAKS_ARGS_FILE'] = $argsFile
            foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
            $shimPosix = if ($IsWindows) { & $Bash -c "cygpath -u '$ShimDir'" } else { $ShimDir }
            Push-Location $Repo
            try {
                & $Bash -c "export PATH='${shimPosix}':`"`$PATH`"; chmod +x '${shimPosix}/gitleaks'; bash '$(if ($IsWindows) { & $Bash -c "cygpath -u '$ScanScript'" } else { $ScanScript })'" | Out-Null
                $exit = $LASTEXITCODE
            } finally {
                Pop-Location
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
            return [pscustomobject]@{ ExitCode = $exit; Args = (Get-Content $argsFile -Raw -ErrorAction SilentlyContinue) }
        }
    }

    It 'scans only the pull request range' {
        $r = Invoke-ScanStep @{ EVENT_NAME = 'pull_request'; PR_BASE_SHA = $Shas[0]; PR_HEAD_SHA = $Shas[2] }
        $r.ExitCode | Should -Be 0
        $r.Args | Should -Match ([regex]::Escape("--log-opts=$($Shas[0])..$($Shas[2])"))
    }

    It 'scans only the pushed range' {
        $r = Invoke-ScanStep @{ EVENT_NAME = 'push'; PUSH_BEFORE_SHA = $Shas[1]; PUSH_AFTER_SHA = $Shas[2] }
        $r.Args | Should -Match ([regex]::Escape("--log-opts=$($Shas[1])..$($Shas[2])"))
    }

    It 'falls back to full history when <Case>' -ForEach @(
        @{ Case = 'a new branch is pushed (zero before-SHA)'; Env = @{ EVENT_NAME = 'push'; PUSH_BEFORE_SHA = ('0' * 40) } }
        @{ Case = 'the before-SHA is missing after a force-push'; Env = @{ EVENT_NAME = 'push'; PUSH_BEFORE_SHA = ('a' * 40) } }
        @{ Case = 'the run is scheduled'; Env = @{ EVENT_NAME = 'schedule' } }
        @{ Case = 'full_history_secret_scan is requested'; Env = @{ EVENT_NAME = 'pull_request'; FULL_HISTORY = 'true' } }
        @{ Case = 'a SHA value is malformed'; Env = @{ EVENT_NAME = 'pull_request'; PR_BASE_SHA = '$(touch pwned)'; PR_HEAD_SHA = 'x;touch pwned' } }
    ) {
        if ($Env.ContainsKey('PUSH_BEFORE_SHA')) { $Env['PUSH_AFTER_SHA'] = $Shas[2] }
        if ($Env['EVENT_NAME'] -eq 'pull_request' -and -not $Env.ContainsKey('PR_BASE_SHA')) { $Env['PR_BASE_SHA'] = $Shas[0]; $Env['PR_HEAD_SHA'] = $Shas[2] }
        $r = Invoke-ScanStep $Env
        $r.ExitCode | Should -Be 0
        $r.Args | Should -Not -Match '--log-opts'
        $r.Args | Should -Match '^git --no-banner --redact --exit-code 1 \.'
        Join-Path $Repo 'pwned' | Should -Not -Exist
    }
}

Describe 'Governance gate hub pin consistency and freshness' {
    BeforeAll {
        $script:CheckScript = Join-Path $TestDrive 'check-hub-pin.ps1'
        [System.IO.File]::WriteAllText($CheckScript, (Get-WorkflowStepScript -WorkflowPath (Join-Path $RepoRoot '.github' 'workflows' 'governance-gate.yml') -StepName 'Check hub pin consistency and freshness'))

        function New-HubCheckout {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates disposable fixtures inside Pester TestDrive only.')]
            param([int]$AgeDays)
            # A checkout whose HEAD commit is $AgeDays old, standing in for _governance_hub.
            $dir = Join-Path $TestDrive ("hub-" + [guid]::NewGuid().ToString('N'))
            New-TestRepo -Path $dir | Out-Null
            $date = [DateTimeOffset]::UtcNow.AddDays(-$AgeDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $env:GIT_COMMITTER_DATE = $date; $env:GIT_AUTHOR_DATE = $date
            try { git -C $dir -c core.hooksPath=.git/no-hooks commit --quiet --allow-empty -m 'chore: dated' }
            finally { $env:GIT_COMMITTER_DATE = $null; $env:GIT_AUTHOR_DATE = $null }
            return [pscustomobject]@{ Dir = $dir; Sha = "$(git -C $dir rev-parse HEAD)".Trim() }
        }

        function Invoke-PinCheck {
            param([string]$HubDir, [string]$LockCommit, [string]$GateSha, [string]$WarnDays = '30', [string]$FailDays = '90')
            $vars = @{ HUB_DIR = $HubDir; LOCK_COMMIT = $LockCommit; GATE_SHA = $GateSha; WARN_DAYS = $WarnDays; FAIL_DAYS = $FailDays }
            $saved = @{}
            foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
            try {
                $out = & pwsh -NoProfile -File $CheckScript 2>&1
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
            } finally {
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
        }
    }

    It 'passes when the lock matches the gate pin and the hub commit is fresh' {
        $hub = New-HubCheckout -AgeDays 2
        (Invoke-PinCheck -HubDir $hub.Dir -LockCommit $hub.Sha -GateSha $hub.Sha).ExitCode | Should -Be 0
    }

    It 'fails when the lock commit differs from the gate pin (downgrade or partial edit)' {
        $hub = New-HubCheckout -AgeDays 2
        $r = Invoke-PinCheck -HubDir $hub.Dir -LockCommit $hub.Sha -GateSha ('b' * 40)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'does not match the gate pin'
    }

    It 'warns but passes when the hub commit is older than the warning age' {
        $hub = New-HubCheckout -AgeDays 45
        $r = Invoke-PinCheck -HubDir $hub.Dir -LockCommit $hub.Sha -GateSha $hub.Sha
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '::warning::'
    }

    It 'fails when the hub commit is older than the failure age' {
        $hub = New-HubCheckout -AgeDays 120
        $r = Invoke-PinCheck -HubDir $hub.Dir -LockCommit $hub.Sha -GateSha $hub.Sha
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'older than 90 days'
    }

    It 'skips the pin comparison when the gate runs from a local path (no SHA available)' {
        $hub = New-HubCheckout -AgeDays 2
        (Invoke-PinCheck -HubDir $hub.Dir -LockCommit $hub.Sha -GateSha '').ExitCode | Should -Be 0
    }
}

Describe 'Codex and Gemini agent settings templates' {
    It 'pins Codex to the workspace-write sandbox with on-request approvals' {
        $toml = Get-Content (Join-Path $RepoRoot 'template' '.codex' 'config.toml') -Raw
        $toml | Should -Match '(?m)^sandbox_mode = "workspace-write"$'
        $toml | Should -Match '(?m)^approval_policy = "on-request"$'
        $toml | Should -Not -Match 'danger-full-access'
    }

    It 'points Gemini CLI at AGENTS.md and forces confirmation for <_>' -ForEach @(
        'run_shell_command(git push)', 'run_shell_command(git commit --no-verify)', 'run_shell_command(lefthook)'
    ) {
        $gemini = Get-Content (Join-Path $RepoRoot 'template' '.gemini' 'settings.json') -Raw | ConvertFrom-Json
        $gemini.context.fileName | Should -Contain 'AGENTS.md'
        $gemini.tools.confirmationRequired | Should -Contain $_
    }

    It 'leaves the Gemini sandbox unset (its behaviour without a container runtime is undocumented)' {
        $gemini = Get-Content (Join-Path $RepoRoot 'template' '.gemini' 'settings.json') -Raw | ConvertFrom-Json
        $gemini.tools.PSObject.Properties['sandbox'] | Should -BeNullOrEmpty
    }
}

Describe 'CI cost controls (Actions minutes)' {
    BeforeAll {
        $script:HubCi = Get-Content (Join-Path $RepoRoot '.github' 'workflows' 'ci.yml') -Raw
        $script:Caller = Get-Content (Join-Path $RepoRoot 'template' '.github' 'workflows' 'agent-governance.yml') -Raw
        $script:Fleet = Get-Content (Join-Path $RepoRoot '.github' 'workflows' 'downstream-sync.yml') -Raw
    }

    It 'runs hub CI once per pull request push (no duplicate branch-push trigger)' {
        $HubCi | Should -Match '(?ms)^  push:\s*\n\s+branches: \[main\]\s*$'
        $HubCi | Should -Not -Match 'feat/\*'
    }

    It 'cancels superseded pull request runs in <Name>' -ForEach @(@{ Name = 'hub CI'; Key = 'HubCi' }, @{ Name = 'the downstream gate caller'; Key = 'Caller' }) {
        $text = (Get-Variable -Name $Key -Scope Script).Value
        $text | Should -Match '(?m)^concurrency:'
        $text | Should -Match "cancel-in-progress: \`$\{\{ github\.event_name == 'pull_request' \}\}"
    }

    It 'runs the macOS job only after merge, and does not require it on pull requests' {
        $HubCi | Should -Match "github\.event_name == 'push' && '\[`"windows-latest`", `"ubuntu-latest`", `"macos-latest`"\]' \|\| '\[`"windows-latest`", `"ubuntu-latest`"\]'"
        $Fleet | Should -Not -Match "verify \(macos-latest\)'"
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
