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

    # Owner-approved 2026-10-10: macOS moved from every merge to weekly, releases and on demand (cost).
    It 'runs the macOS job only weekly, on releases and on demand, and does not require it on pull requests' {
        $HubCi | Should -Match "\(github\.event_name == 'schedule' \|\| github\.event_name == 'release' \|\| github\.event_name == 'workflow_dispatch'\) && '\[`"windows-latest`", `"ubuntu-latest`", `"macos-latest`"\]' \|\| '\[`"windows-latest`", `"ubuntu-latest`"\]'"
        $Fleet | Should -Not -Match "verify \(macos-latest\)'"
    }

    It 'schedules the weekly macOS run and triggers on published releases and manual dispatch' {
        $HubCi | Should -Match '(?m)^  schedule:\s*\n\s+- cron: "\d+ \d+ \* \* 0"'
        $HubCi | Should -Match '(?m)^  release:\s*\n\s+types: \[published\]'
        $HubCi | Should -Match '(?m)^  workflow_dispatch:'
    }

    It 'does not put macOS on a pull request or merge to main' {
        $HubCi | Should -Not -Match "github\.event_name == 'push' &&"
        $HubCi | Should -Not -Match "github\.event_name == 'pull_request' &&"
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

Describe 'agent-bash-guard.ps1 bypass variants (red-team 2026-10-01)' {
    It 'blocks: <Command>' -ForEach @(
        @{ Command = "git commit '--no-verify' -m wip" }
        @{ Command = 'git commit "--no-verify" -m wip' }
        @{ Command = 'git commit --no-verif -m wip' }
        @{ Command = 'sh -c "git commit --no-verify -m wip"' }
        @{ Command = "bash -lc 'cd app && git commit --no-verify'" }
        @{ Command = 'pwsh -Command "git commit --no-verify -m wip"' }
        @{ Command = 'eval "git commit --no-verify"' }
        @{ Command = 'F=--no-verify; git commit $F -m wip' }
        @{ Command = "`$flag = '--no-verify'; git commit `$flag -m wip" }
        @{ Command = "git -c 'core.hooksPath=/dev/null' commit -m wip" }
        @{ Command = 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m wip' }
        @{ Command = "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' git commit -m wip" }
        @{ Command = 'git config --unset core.hooksPath' }
        @{ Command = 'git config unset core.hooksPath' }
        @{ Command = 'git push origin HEAD:refs/heads/main' }
        @{ Command = "git push origin 'main'" }
        @{ Command = 'git push origin +main' }
        @{ Command = 'git push --force-with-lease origin HEAD:master' }
        @{ Command = 'printf "#!/bin/sh\nexit 0" > .git/hooks/pre-commit; git commit -m wip' }
        @{ Command = 'echo exit 0 >> .githooks/pre-push' }
        @{ Command = 'rm .git/hooks/pre-commit && git commit -m wip' }
        @{ Command = 'chmod -x .git/hooks/pre-commit' }
        @{ Command = 'cp /tmp/empty .husky/pre-commit' }
        @{ Command = "Set-Content .git\hooks\pre-commit 'exit 0'" }
        @{ Command = 'Remove-Item .git/hooks/pre-push' }
        @{ Command = 'Set-Item env:LEFTHOOK 0; git commit -m wip' }
        @{ Command = 'export LEFTHOOK_EXCLUDE=detect-secrets; git commit -m wip' }
    ) {
        $result = Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $Command)
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'Agent Governance'
    }

    It 'allows: <Command>' -ForEach @(
        @{ Command = 'git commit -m fix' }
        @{ Command = 'git commit -m "nit"' }
        @{ Command = 'git commit -m "docs: explain core.hooksPath and GIT_CONFIG_COUNT"' }
        @{ Command = 'git push -u origin feat/main-menu' }
        @{ Command = 'git push origin maintenance' }
        @{ Command = 'git push origin main-line' }
        @{ Command = 'git log --oneline -n 5' }
        @{ Command = 'cat .git/hooks/pre-commit' }
        @{ Command = 'git config --get core.hooksPath' }
        @{ Command = 'sh -c "npm test && git status"' }
        @{ Command = 'grep -rn hooksPath docs/' }
    ) {
        (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $Command)).ExitCode | Should -Be 0
    }

    It 'names the accepted misses so the limits of a text check stay documented' {
        $guard = Get-Content $Guard -Raw
        $guard | Should -Match 'Accepted misses'
        Join-Path $RepoRoot 'docs' 'adr' '0003-command-guard-defence-in-depth.md' | Should -Exist
    }

    It 'blocks hook-directory tampering in the form: <Command>' -ForEach @(
        @{ Command = 'cd .git/hooks && printf "exit 0" > pre-commit' }
        @{ Command = 'echo exit 0 > "$(git rev-parse --git-dir)/hooks/pre-commit"' }
        @{ Command = 'echo exit 0 | tee .githooks/pre-commit' }
        @{ Command = 'rm -rf .git/hooks' }
        @{ Command = 'Rename-Item .git/hooks/pre-commit pre-commit.off' }
        @{ Command = 'ri .git/hooks/pre-push' }
        @{ Command = 'GIT_CONFIG_GLOBAL=/tmp/evil.gitconfig git commit -m wip' }
        @{ Command = '$env:GIT_CONFIG_GLOBAL = "C:\evil.gitconfig"; git commit -m wip' }
    ) {
        (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $Command)).ExitCode | Should -Be 2
    }

    It 'still allows the look-alike: <Command>' -ForEach @(
        @{ Command = 'git commit -mnew-feature' }
        @{ Command = 'git commit -m "$(date +%F) nightly build"' }
        @{ Command = 'ls -la .git/hooks' }
        @{ Command = 'head -n 5 .githooks/pre-commit' }
        @{ Command = 'git -C .git/hooks status' }
    ) {
        (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload $Command)).ExitCode | Should -Be 0
    }

    It 'guards a custom core.hooksPath directory of the repository it runs in' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        git -C $repo config core.hooksPath tooling/hooks
        Push-Location $repo
        try {
            (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload 'cp /tmp/empty tooling/hooks/pre-commit')).ExitCode | Should -Be 2
            (Invoke-HookScript -ScriptPath $Guard -InputText (ConvertTo-HookPayload 'cat tooling/hooks/pre-commit')).ExitCode | Should -Be 0
        } finally { Pop-Location }
    }
}

Describe 'Claude Code settings template: PowerShell and Edit coverage' {
    BeforeAll {
        $script:Deny = @((Get-Content (Join-Path $RepoRoot 'template' '.claude' 'settings.json') -Raw | ConvertFrom-Json).permissions.deny)
    }

    It 'mirrors every Bash deny rule for the PowerShell tool' {
        foreach ($rule in ($Deny | Where-Object { $_ -like 'Bash(*' })) {
            $Deny | Should -Contain ('PowerShell(' + $rule.Substring(5))
        }
    }

    It 'denies the Edit tool on hook directories (<_>)' -ForEach @('Edit(.git/hooks/**)', 'Edit(.githooks/**)', 'Edit(.husky/**)') {
        $Deny | Should -Contain $_
    }

    It 'covers the GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM file overrides' {
        $Deny | Should -Contain 'Bash(*GIT_CONFIG_GLOBAL=*)'
        $Deny | Should -Contain 'Bash(*GIT_CONFIG_SYSTEM=*)'
    }
}

Describe 'Claude Code settings template: native deny rules and sandbox hardening' {
    BeforeAll {
        $script:Settings = Get-Content (Join-Path $RepoRoot 'template' '.claude' 'settings.json') -Raw | ConvertFrom-Json
        $script:Deny = @($Settings.permissions.deny)
    }

    It 'backs the hook with a native Bash deny rule for <Rule>' -ForEach @(
        @{ Rule = 'Bash(*--no-verif*)' }
        @{ Rule = 'Bash(*LEFTHOOK=*)' }
        @{ Rule = 'Bash(*lefthook install*)' }
        @{ Rule = 'Bash(*core.hooksPath=*)' }
        @{ Rule = 'Bash(git config *core.hooksPath *)' }
        @{ Rule = 'Bash(*GIT_CONFIG_COUNT=*)' }
        @{ Rule = 'Bash(git push * main)' }
        @{ Rule = 'Bash(git push *:main)' }
        @{ Rule = 'Bash(git push *refs/heads/main*)' }
        @{ Rule = 'Bash(git push * master)' }
        @{ Rule = 'Bash(*>*.git/hooks/*)' }
        @{ Rule = 'Bash(rm *.git/hooks/*)' }
    ) {
        $Deny | Should -Contain $Rule
    }

    It 'pre-allows the package registries the contract names, so sandboxed installs do not prompt' {
        foreach ($domain in @('github.com', 'registry.npmjs.org', 'pypi.org', 'files.pythonhosted.org', 'crates.io', 'proxy.golang.org')) {
            $Settings.sandbox.network.allowedDomains | Should -Contain $domain
        }
    }

    It 'denies cloud credentials to sandboxed commands (files and environment variables)' {
        @($Settings.sandbox.credentials.files | ForEach-Object path) | Should -Contain '~/.aws/credentials'
        @($Settings.sandbox.credentials.envVars | ForEach-Object name) | Should -Contain 'AWS_SECRET_ACCESS_KEY'
        foreach ($entry in @($Settings.sandbox.credentials.files) + @($Settings.sandbox.credentials.envVars)) { $entry.mode | Should -Be 'deny' }
    }

    It 'keeps GH_TOKEN usable inside the sandbox (the contract asks agents to run gh pr list)' {
        @($Settings.sandbox.credentials.envVars | ForEach-Object name) | Should -Not -Contain 'GH_TOKEN'
        @($Settings.sandbox.credentials.envVars | ForEach-Object name) | Should -Not -Contain 'GITHUB_TOKEN'
    }

    It 'leaves the unsandboxed retry escape hatch on its prompting default (no silent lockout)' {
        $Settings.sandbox.PSObject.Properties['allowUnsandboxedCommands'] | Should -BeNullOrEmpty
    }
}

Describe 'Governance gate integrity fails closed on an unreachable hub' {
    BeforeAll {
        $script:GatePath = Join-Path $RepoRoot '.github' 'workflows' 'governance-gate.yml'
        $script:Gate = Get-Content $GatePath -Raw
        $script:UnreachableStep = Join-Path $TestDrive 'unreachable.sh'
        [System.IO.File]::WriteAllText($UnreachableStep, (Get-WorkflowStepScript -WorkflowPath $GatePath -StepName 'Fail on an unreachable hub'))
    }

    It 'fails the required check, with an error naming the missing token, when the hub cannot be fetched' {
        $script = (Get-Content -LiteralPath $UnreachableStep -Raw) -split "`n" | Where-Object { $_.Trim() }
        $script[0] | Should -Match '^echo "::error::Could not fetch \$\{HUB_REPOSITORY\} at the locked commit.*AGENT_GOVERNANCE_HUB_TOKEN'
        $script[-1].Trim() | Should -BeExactly 'exit 1'
    }

    It 'tells a Dependabot-triggered run, and only that run, to add the Dependabot secret' -ForEach @(
        @{ Case = 'Dependabot actor'; Actor = 'dependabot[bot]'; Author = ''; Hint = $true }
        @{ Case = 'a re-run of a Dependabot pull request'; Actor = 'octocat'; Author = 'dependabot[bot]'; Hint = $true }
        @{ Case = 'a person'; Actor = 'octocat'; Author = 'octocat'; Hint = $false }
    ) {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { throw 'bash is required to run the workflow step script' }
        $saved = @{ HUB_REPOSITORY = $env:HUB_REPOSITORY; ACTOR = $env:ACTOR; PR_AUTHOR = $env:PR_AUTHOR }
        $env:HUB_REPOSITORY = 'octo/hub'; $env:ACTOR = $Actor; $env:PR_AUTHOR = $Author
        try {
            $out = (& $bash.Source $UnreachableStep 2>&1) -join "`n"
            $LASTEXITCODE | Should -Be 1
            if ($Hint) { $out | Should -Match 'Settings > Secrets and variables > Dependabot' } else { $out | Should -Not -Match 'Dependabot' }
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
    }

    It 'passes the actor and pull request author through env, never interpolated into the script' {
        $Gate | Should -Match 'ACTOR: \$\{\{ github\.actor \}\}'
        $Gate | Should -Match 'PR_AUTHOR: \$\{\{ github\.event\.pull_request\.user\.login \}\}'
        (Get-Content -LiteralPath $UnreachableStep -Raw) | Should -Not -Match '\$\{\{'
    }

    It 'runs exactly when a governed downstream repository could not fetch its hub' {
        $Gate | Should -Match "- name: Fail on an unreachable hub\s+#[^\n]*\n(?:\s+#[^\n]*\n)*\s+if: steps\.lock\.outputs\.present == 'true' && steps\.lock\.outputs\.is_hub != 'true' && steps\.hub\.outcome != 'success'"
        $Gate | Should -Not -Match '::warning::Could not fetch'
    }
}

Describe 'Governance gate hub mode (the hub dogfoods its own lock)' {
    BeforeAll {
        $script:GatePath = Join-Path $RepoRoot '.github' 'workflows' 'governance-gate.yml'
        $script:Gate = Get-Content $GatePath -Raw
        $script:LockStep = Join-Path $TestDrive 'read-lock.ps1'
        [System.IO.File]::WriteAllText($LockStep, (Get-WorkflowStepScript -WorkflowPath $GatePath -StepName 'Read locked hub commit'))

        function Invoke-LockStep {
            param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$IsHub)
            $outputs = Join-Path $TestDrive ("outputs-" + [guid]::NewGuid().ToString('N'))
            $saved = @{ IS_HUB = $env:IS_HUB; GITHUB_OUTPUT = $env:GITHUB_OUTPUT }
            $env:IS_HUB = $IsHub; $env:GITHUB_OUTPUT = $outputs
            Push-Location $Dir
            try {
                $out = & pwsh -NoProfile -File $LockStep 2>&1
                $written = if (Test-Path $outputs) { Get-Content $outputs -Raw } else { '' }
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n"); Outputs = $written }
            } finally {
                Pop-Location
                $env:IS_HUB = $saved.IS_HUB; $env:GITHUB_OUTPUT = $saved.GITHUB_OUTPUT
            }
        }
    }

    It 'detects the hub from the job context, never from a caller-supplied input' {
        $Gate | Should -Match 'IS_HUB: \$\{\{ github\.repository == job\.workflow_repository \}\}'
    }

    It 'fails closed when the hub itself has no lock' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        $r = Invoke-LockStep -Dir $dir -IsHub 'true'
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'must carry its own \.agent-governance\.lock'
    }

    It 'still only notices a missing lock for a downstream caller' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        $r = Invoke-LockStep -Dir $dir -IsHub 'false'
        $r.ExitCode | Should -Be 0
        $r.Outputs | Should -Match 'present=false'
        $r.Outputs | Should -Match 'is_hub=false'
    }

    It 'reads the locked commit for either caller' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir '.agent-governance.lock'), ('{"version":1,"hub":{"commit":"' + ('a' * 40) + '"},"files":{}}'))
        $r = Invoke-LockStep -Dir $dir -IsHub 'true'
        $r.ExitCode | Should -Be 0
        $r.Outputs | Should -Match 'present=true'
        $r.Outputs | Should -Match 'is_hub=true'
        $r.Outputs | Should -Match ('commit=' + ('a' * 40))
    }

    It 'skips the hub checkout, pin and freshness steps for the hub and verifies against its own template' {
        $Gate | Should -Match "(?m)^\s+id: hub\s*\n\s+if: steps\.lock\.outputs\.present == 'true' && steps\.lock\.outputs\.is_hub != 'true'"
        $Gate | Should -Match "Check hub pin consistency and freshness\s*\n(?:\s+#[^\n]*\n)*\s+if: [^\n]*is_hub != 'true'"
        $Gate | Should -Match "if: steps\.lock\.outputs\.present == 'true' && steps\.lock\.outputs\.is_hub == 'true'\s*\n\s+shell: pwsh\s*\n(?:\s+#[^\n]*\n)*\s+run: \./template/scripts/guardrails/verify-governance\.ps1 -HubTemplate \./template"
    }

    It 'accepts Dependabot branches server-side, where no local hook ever runs' {
        $Gate | Should -Match '\|dependabot\)/'
    }
}
