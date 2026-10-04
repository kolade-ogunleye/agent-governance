BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:GuardDir = Join-Path $PSScriptRoot '..' 'template' 'scripts' 'guardrails'
}

Describe 'protect-main.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = Join-Path $GuardDir 'protect-main.ps1'
    }

    It 'blocks commits on main' {
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match "Direct commits to 'main'"
    }

    It 'allows a semantic branch' {
        git -C $Repo checkout --quiet -b feat/new-thing
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks an unclassified branch name' {
        git -C $Repo checkout --quiet -b wip-stuff
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'semantic branching policy'
    }

    It 'allows commits on a detached HEAD during rebase or bisect (plan defect 8)' {
        git -C $Repo checkout --quiet --detach
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'allows a nested semantic branch name (plan defect 8)' {
        git -C $Repo checkout --quiet -b feat/payments/refund-flow
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks a mixed-case prefix, as the server-side branch policy does (parity)' {
        git -C $Repo checkout --quiet -b Feat/mixed-case
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'semantic branching policy'
    }

    It 'allows a mixed-case slug after a lowercase prefix, as the server-side branch policy does (parity)' {
        git -C $Repo checkout --quiet -b feat/Add-Thing
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks a staged <Path> session ledger on a feature branch (plan defect 8)' -ForEach @(
        @{ Path = 'WORKING.md' }, @{ Path = '.agents/state/feat-x.md' }
    ) {
        git -C $Repo checkout --quiet -b feat/ledger
        $full = Join-Path $Repo $Path
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, "ledger`n")
        git -C $Repo add -f -- $Path
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Ephemeral session ledger'
    }

    It 'blocks a staged session ledger on a detached HEAD (plan defect 8)' {
        git -C $Repo checkout --quiet --detach
        [System.IO.File]::WriteAllText((Join-Path $Repo 'WORKING.md'), "ledger`n")
        git -C $Repo add -f WORKING.md
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }
}

Describe 'guard-tests.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Add-FixtureCommit -RepoPath $Repo -Files @{
            'tests/app.test.js' = "test('x', () => {});`n"
            'src/latest.js'     = "export const v = 1;`n"
            'src/app.js'        = "export const a = 1;`n"
        }
        $script:Guard = Join-Path $GuardDir 'guard-tests.ps1'
    }

    It 'blocks a staged deletion of a test file' {
        git -C $Repo rm --quiet tests/app.test.js
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'tests/app.test.js'
    }

    It 'allows a staged deletion of a non-test file' {
        git -C $Repo rm --quiet src/app.js
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'does not treat files merely containing "test" in their name as tests (plan defect 8)' {
        git -C $Repo rm --quiet src/latest.js
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks deleting a test identified by <Name> convention (plan defect 8)' -ForEach @(
        @{ Name = 'pytest prefix'; Path = 'pkg/test_models.py' }
        @{ Name = 'Go suffix'; Path = 'internal/store_test.go' }
        @{ Name = 'Pester suffix'; Path = 'scripts/Build.Tests.ps1' }
        @{ Name = '__tests__ directory'; Path = 'src/__tests__/button.jsx' }
        @{ Name = 'spec suffix'; Path = 'src/api.spec.ts' }
    ) {
        Add-FixtureCommit -RepoPath $Repo -Files @{ $Path = "placeholder`n" }
        git -C $Repo rm --quiet -- $Path
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'blocks renaming a test file out of the test suite (plan defect 8)' {
        New-Item -ItemType Directory -Path (Join-Path $Repo 'archive') | Out-Null
        git -C $Repo mv tests/app.test.js archive/app.js
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'tests/app.test.js'
    }

    It 'allows moving a test file within the test suite (plan defect 8)' {
        New-Item -ItemType Directory -Path (Join-Path $Repo 'tests/unit') | Out-Null
        git -C $Repo mv tests/app.test.js tests/unit/app.test.js
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks adding a skip marker to an existing test (<Marker>) (plan defect 8)' -ForEach @(
        @{ Marker = 'test.skip'; Line = "test.skip('y', () => {});" }
        @{ Marker = 'xit'; Line = "xit('y', () => {});" }
        @{ Marker = 'pytest.mark.skip'; Line = '@pytest.mark.skip(reason="flaky")' }
    ) {
        [System.IO.File]::AppendAllText((Join-Path $Repo 'tests/app.test.js'), "$Line`n")
        git -C $Repo add tests/app.test.js
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'skip'
    }

    It 'allows adding a new, ordinary assertion to an existing test' {
        [System.IO.File]::AppendAllText((Join-Path $Repo 'tests/app.test.js'), "test('z', () => { expect(1).toBe(1); });`n")
        git -C $Repo add tests/app.test.js
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'ignores skip markers that appear inside string data' {
        [System.IO.File]::AppendAllText((Join-Path $Repo 'tests/app.test.js'), "const fixture = `"test.skip('y', () => {});`";`n")
        git -C $Repo add tests/app.test.js
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks adding -Skip to an existing Pester test' {
        Add-FixtureCommit -RepoPath $Repo -Files @{ 'tests/Build.Tests.ps1' = "Describe 'x' {`n    It 'works' {`n        1 | Should -Be 1`n    }`n}`n" }
        [System.IO.File]::WriteAllText((Join-Path $Repo 'tests/Build.Tests.ps1'), "Describe 'x' {`n    It 'works' -Skip {`n        1 | Should -Be 1`n    }`n}`n")
        git -C $Repo add tests/Build.Tests.ps1
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'allows removing a skip marker from an existing test' {
        Add-FixtureCommit -RepoPath $Repo -Files @{ 'tests/flaky.test.js' = "test.skip('y', () => {});`n" }
        [System.IO.File]::WriteAllText((Join-Path $Repo 'tests/flaky.test.js'), "test('y', () => {});`n")
        git -C $Repo add tests/flaky.test.js
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }
}

Describe 'detect-secrets.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = Join-Path $GuardDir 'detect-secrets.ps1'

        # Default: a clean-scanning gitleaks stand-in, so filename rules are tested independently of the scanner.
        $script:ShimDir = Join-Path $TestDrive ("shims-" + [guid]::NewGuid().ToString('N'))
        New-CommandShim -Directory $ShimDir -Name 'gitleaks' -ExitCode 0
        $script:OriginalPath = $env:PATH
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
    }

    AfterEach {
        $env:PATH = $OriginalPath
    }

    It 'blocks a staged private key file by name' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'server.pem'), "placeholder`n")
        git -C $Repo add server.pem
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'server.pem'
    }

    It 'allows an ordinary staged file' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'notes.txt'), "hello`n")
        git -C $Repo add notes.txt
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'allows .env.example, which the canonical .gitignore explicitly permits (plan defect 8)' {
        [System.IO.File]::WriteAllText((Join-Path $Repo '.env.example'), "API_URL=`n")
        git -C $Repo add .env.example
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks a staged <Name> file by name' -ForEach @(
        @{ Name = '.env' }, @{ Name = '.env.production' }, @{ Name = 'id_ed25519' }, @{ Name = 'signing.p12' }, @{ Name = 'credentials.json' }
    ) {
        [System.IO.File]::WriteAllText((Join-Path $Repo $Name), "placeholder`n")
        git -C $Repo add -f -- $Name
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'allows <Name>, which only resembles a sensitive name (plan defect 8)' -ForEach @(
        @{ Name = 'src/environment.ts' }, @{ Name = 'id_ed25519.pub' }, @{ Name = 'docs/credential-rotation.md' }
    ) {
        $full = Join-Path $Repo $Name
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, "placeholder`n")
        git -C $Repo add -f -- $Name
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'allows deleting a previously committed key file' {
        Add-FixtureCommit -RepoPath $Repo -Files @{ 'old.pem' = "placeholder`n" }
        git -C $Repo rm --quiet old.pem
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'blocks when the content scanner reports a leak' {
        New-CommandShim -Directory $ShimDir -Name 'gitleaks' -ExitCode 1
        [System.IO.File]::WriteAllText((Join-Path $Repo 'notes.txt'), "hello`n")
        git -C $Repo add notes.txt
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Gitleaks'
    }

    It 'fails closed when gitleaks is not installed (plan Phase 2)' {
        # Keep only what the guardrail needs: git and pwsh, plus an empty shim directory.
        $emptyShims = Join-Path $TestDrive ("empty-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $emptyShims | Out-Null
        $gitDir = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $env:PATH = @($emptyShims, $gitDir, $PSHOME) -join [System.IO.Path]::PathSeparator
        if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
            Set-ItResult -Skipped -Because 'gitleaks shares a directory with git or pwsh on this machine'
            return
        }

        [System.IO.File]::WriteAllText((Join-Path $Repo 'notes.txt'), "hello`n")
        git -C $Repo add notes.txt
        $result = Invoke-Guardrail -ScriptPath (Resolve-Path $Guard).Path -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'gitleaks is not installed'
    }

    It 'blocks a real token-shaped secret using the installed gitleaks' {
        $env:PATH = $OriginalPath
        if (-not (Get-Command gitleaks -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'gitleaks is not installed on this machine'
            return
        }
        # Built at runtime so no token-shaped literal exists in this repository.
        $alphabet = [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        $token = 'ghp_' + -join (1..36 | ForEach-Object { $alphabet | Get-Random })
        [System.IO.File]::WriteAllText((Join-Path $Repo 'config.txt'), "github_token = `"$token`"`n")
        git -C $Repo add config.txt
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }
}

Describe 'check-markdown.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = Join-Path $GuardDir 'check-markdown.ps1'
    }

    It 'blocks staged markdown with CRLF line endings' {
        [System.IO.File]::WriteAllBytes((Join-Path $Repo 'doc.md'), [System.Text.Encoding]::UTF8.GetBytes("# a`r`nb`r`n"))
        git -C $Repo -c core.autocrlf=false -c core.safecrlf=false add doc.md
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'CRLF'
    }

    It 'blocks staged markdown with a UTF-8 BOM' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'doc.md'), "# a`n", [System.Text.UTF8Encoding]::new($true))
        git -C $Repo add doc.md
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'BOM'
    }

    It 'ignores git-ignored markdown (e.g. local session ledgers) when nothing is staged' {
        [System.IO.File]::WriteAllText((Join-Path $Repo '.gitignore'), "ledger/`n")
        New-Item -ItemType Directory -Path (Join-Path $Repo 'ledger') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $Repo 'ledger/notes.md'), [System.Text.Encoding]::UTF8.GetBytes("# a`r`nb`r`n"))
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'still checks tracked markdown when nothing is staged' {
        [System.IO.File]::WriteAllBytes((Join-Path $Repo 'README.md'), [System.Text.Encoding]::UTF8.GetBytes("# a`r`nb`r`n"))
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'allows staged LF markdown without BOM' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'doc.md'), "# a`nb`n")
        git -C $Repo add doc.md
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }
}

Describe 'run-tests.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = Join-Path $GuardDir 'run-tests.ps1'

        $script:ShimDir = Join-Path $TestDrive ("shims-" + [guid]::NewGuid().ToString('N'))
        foreach ($tool in @('npm', 'pytest')) {
            New-CommandShim -Directory $ShimDir -Name $tool -MarkerPath (Join-Path $Repo ".ran-$tool")
        }
        $script:OriginalPath = $env:PATH
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
    }

    AfterEach {
        $env:PATH = $OriginalPath
    }

    It 'runs the Node suite in a Node-only repository' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "scripts": { "test": "x" } }')
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        Join-Path $Repo '.ran-npm' | Should -Exist
    }

    It 'runs every detected stack in a polyglot repository (plan defect 8)' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "scripts": { "test": "x" } }')
        [System.IO.File]::WriteAllText((Join-Path $Repo 'pyproject.toml'), "[project]`nname = 'fixture'`n")
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        Join-Path $Repo '.ran-npm' | Should -Exist
        Join-Path $Repo '.ran-pytest' | Should -Exist
    }

    It 'still runs later suites when an earlier one fails, then fails overall (plan defect 8)' {
        New-CommandShim -Directory $ShimDir -Name 'npm' -ExitCode 1 -MarkerPath (Join-Path $Repo '.ran-npm')
        [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "scripts": { "test": "x" } }')
        [System.IO.File]::WriteAllText((Join-Path $Repo 'pyproject.toml'), "[project]`nname = 'fixture'`n")
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Node\.js'
        Join-Path $Repo '.ran-pytest' | Should -Exist
    }

    It 'skips a package.json without a test script' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "scripts": { "build": "x" } }')
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        Join-Path $Repo '.ran-npm' | Should -Not -Exist
    }

    It 'passes when no testable stack is present' {
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }
}

Describe 'verify-governance.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = (Resolve-Path (Join-Path $GuardDir 'verify-governance.ps1')).Path
        $script:Hub = Join-Path $TestDrive ("hub-" + [guid]::NewGuid().ToString('N'))
        foreach ($root in @($Repo, $Hub)) {
            New-Item -ItemType Directory -Path (Join-Path $root 'scripts/guardrails') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'scripts/guardrails/protect-main.ps1'), "exit 0`n")
            [System.IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'), "# Contract`n`nRule one.`n")
        }
        $files = [ordered]@{}
        foreach ($rel in @('AGENTS.md', 'scripts/guardrails/protect-main.ps1')) {
            $files[$rel] = (Get-FileHash -Algorithm SHA256 (Join-Path $Repo $rel)).Hash.ToLowerInvariant()
        }
        $lock = [ordered]@{ version = 1; hub = [ordered]@{ commit = ('a' * 40) }; files = $files }
        [System.IO.File]::WriteAllText((Join-Path $Repo '.agent-governance.lock'), ($lock | ConvertTo-Json -Depth 5))
    }

    It 'passes when every managed file matches the lock' {
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
    }

    It 'fails and names a managed file that no longer matches the lock' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'scripts/guardrails/protect-main.ps1'), "# weakened`nexit 0`n")
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'scripts/guardrails/protect-main\.ps1'
    }

    It 'fails when a managed file is missing' {
        Remove-Item -LiteralPath (Join-Path $Repo 'AGENTS.md')
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
    }

    It 'with -HubTemplate, catches a tampered script even when the lock was rewritten to match' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'scripts/guardrails/protect-main.ps1'), "# weakened`nexit 0`n")
        $lockPath = Join-Path $Repo '.agent-governance.lock'
        $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
        $lock.files.'scripts/guardrails/protect-main.ps1' = (Get-FileHash -Algorithm SHA256 (Join-Path $Repo 'scripts/guardrails/protect-main.ps1')).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 5))

        Push-Location $Repo
        try {
            $output = & pwsh -NoProfile -File $Guard -HubTemplate $Hub 2>&1
            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match 'differs from the hub'
        } finally {
            Pop-Location
        }
    }

    It 'with -HubTemplate, tolerates whitespace-only markdown reformatting' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'AGENTS.md'), "# Contract`n`n`nRule   one.`n")
        $lockPath = Join-Path $Repo '.agent-governance.lock'
        $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
        $lock.files.'AGENTS.md' = (Get-FileHash -Algorithm SHA256 (Join-Path $Repo 'AGENTS.md')).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 5))

        Push-Location $Repo
        try {
            & pwsh -NoProfile -File $Guard -HubTemplate $Hub 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Pop-Location
        }
    }

    It 'passes with a notice when the repository has no lock yet' {
        # -Force: PowerShell treats dotfiles as hidden on Linux and macOS.
        Remove-Item -LiteralPath (Join-Path $Repo '.agent-governance.lock') -Force
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'No \.agent-governance\.lock'
    }
}

Describe 'check-drift.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = Join-Path $GuardDir 'check-drift.ps1'
        $script:Hub = Join-Path $TestDrive ("hub-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Hub | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Hub 'AGENTS.md'), "# Contract`n`nRule one.`n")
        $script:OriginalHub = $env:AGENT_GOVERNANCE_HUB
        $env:AGENT_GOVERNANCE_HUB = $Hub
    }

    AfterEach {
        $env:AGENT_GOVERNANCE_HUB = $OriginalHub
    }

    It 'stays silent and non-blocking when the hub is absent' {
        $env:AGENT_GOVERNANCE_HUB = Join-Path $TestDrive 'no-such-hub'
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'reports drift without blocking when a governed file differs' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'AGENTS.md'), "# Contract`n`nRule two.`n")
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'drifted from the Central Hub'
    }

    It 'ignores whitespace-only markdown reformatting' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'AGENTS.md'), "# Contract`n`n`nRule   one.`n")
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).Output | Should -Not -Match 'drifted'
    }
}

Describe 'audit-dependencies.ps1' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Guard = Join-Path $GuardDir 'audit-dependencies.ps1'
        $script:ShimDir = Join-Path $TestDrive ("shims-" + [guid]::NewGuid().ToString('N'))
        foreach ($tool in @('pip-audit', 'uv', 'pnpm', 'npm')) {
            New-CommandShim -Directory $ShimDir -Name $tool -MarkerPath (Join-Path $Repo ".args-$tool")
        }
        $script:OriginalPath = $env:PATH
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
    }

    AfterEach {
        $env:PATH = $OriginalPath
    }

    It 'audits the locked dependencies of a uv project, not the auditor environment (plan defect 8)' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'pyproject.toml'), "[project]`nname = 'fixture'`n")
        [System.IO.File]::WriteAllText((Join-Path $Repo 'uv.lock'), "version = 1`n")

        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0

        Get-Content (Join-Path $Repo '.args-uv') -Raw | Should -Match '^export .*--format requirements\.txt.*--frozen'
        Get-Content (Join-Path $Repo '.args-pip-audit') -Raw | Should -Match '-r \S+ --no-deps --disable-pip'
    }

    It 'audits requirements.txt directly when present (plan defect 8)' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'requirements.txt'), "requests==2.32.3`n")
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        Get-Content (Join-Path $Repo '.args-pip-audit') -Raw | Should -Match '-r requirements\.txt'
    }

    It 'audits the local project path for a pyproject-only repository (plan defect 8)' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'pyproject.toml'), "[project]`nname = 'fixture'`n")
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        (Get-Content (Join-Path $Repo '.args-pip-audit') -Raw).Trim() | Should -BeExactly '.'
    }

    It 'blocks the push when pip-audit reports vulnerabilities' {
        New-CommandShim -Directory $ShimDir -Name 'pip-audit' -ExitCode 1
        [System.IO.File]::WriteAllText((Join-Path $Repo 'requirements.txt'), "requests==2.0.0`n")
        $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'vulnerabilities detected'
    }

    It 'audits a pnpm project with pnpm' {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "name": "fixture" }')
        [System.IO.File]::WriteAllText((Join-Path $Repo 'pnpm-lock.yaml'), "lockfileVersion: '9.0'`n")
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        Get-Content (Join-Path $Repo '.args-pnpm') -Raw | Should -Match '^audit --audit-level=high'
    }

    Context 'expiring npm audit exceptions (.audit-exceptions.json)' {
        BeforeAll {
            # A scripted npm: prints the JSON in NPM_SHIM_JSON and exits NPM_SHIM_EXIT, recording its arguments. The
            # report shape is real npm 11 output: an advisory object in the vulnerable package's "via", and a
            # transitive dependant that names it as a string.
            $script:NpmShimDir = Join-Path $TestDrive 'npm-shim'
            New-Item -ItemType Directory -Path $NpmShimDir -Force | Out-Null
            $impl = @'
Add-Content -LiteralPath $env:NPM_SHIM_LOG -Value ($args -join ' ')
if ($args -contains '--json') { Write-Output ([System.IO.File]::ReadAllText($env:NPM_SHIM_JSON)) }
exit [int]$env:NPM_SHIM_EXIT
'@
            [System.IO.File]::WriteAllText((Join-Path $NpmShimDir 'npm-impl.ps1'), $impl)
            if ($IsWindows) {
                [System.IO.File]::WriteAllText((Join-Path $NpmShimDir 'npm.ps1'), "& '$((Join-Path $NpmShimDir 'npm-impl.ps1'))' @args`nexit `$LASTEXITCODE`n")
            } else {
                $sh = Join-Path $NpmShimDir 'npm'
                [System.IO.File]::WriteAllText($sh, "#!/bin/sh`nexec pwsh -NoProfile -File '$((Join-Path $NpmShimDir 'npm-impl.ps1'))' `"`$@`"`n")
                chmod +x $sh
            }
            $script:BracesReport = '{"auditReportVersion":2,"vulnerabilities":{' +
                '"braces":{"name":"braces","severity":"high","via":[{"source":1240992,"name":"braces","severity":"high","url":"https://github.com/advisories/GHSA-vfj7-8cjw-p6xm"}]},' +
                '"fast-glob":{"name":"fast-glob","severity":"high","via":["micromatch"]}},"metadata":{"vulnerabilities":{"high":2,"critical":0}}}'
            $script:InExpiry = [datetime]::UtcNow.Date.AddDays(30).ToString('yyyy-MM-dd')
        }

        BeforeEach {
            $script:SavedNpm = @{ PATH = $env:PATH; NPM_SHIM_JSON = $env:NPM_SHIM_JSON; NPM_SHIM_EXIT = $env:NPM_SHIM_EXIT; NPM_SHIM_LOG = $env:NPM_SHIM_LOG }
            $env:PATH = $NpmShimDir + [System.IO.Path]::PathSeparator + $env:PATH
            $env:NPM_SHIM_LOG = Join-Path $Repo '.args-npm-shim'
            $env:NPM_SHIM_JSON = Join-Path $Repo '.npm-report.json'
            $env:NPM_SHIM_EXIT = '1'
            [System.IO.File]::WriteAllText($env:NPM_SHIM_JSON, $BracesReport)
            [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "name": "fixture" }')
            [System.IO.File]::WriteAllText((Join-Path $Repo 'package-lock.json'), '{ "lockfileVersion": 3 }')
            function Write-AuditExceptionFixture {
                param([string]$Json)
                [System.IO.File]::WriteAllText((Join-Path $Repo '.audit-exceptions.json'), $Json)
            }
        }

        AfterEach {
            foreach ($k in $SavedNpm.Keys) { [Environment]::SetEnvironmentVariable($k, $SavedNpm[$k]) }
        }

        It 'passes when every high or critical advisory has a current exception, and still reports it' {
            Write-AuditExceptionFixture "{ `"exceptions`": [ { `"id`": `"GHSA-vfj7-8cjw-p6xm`", `"reason`": `"No fixed release`", `"expires`": `"$InExpiry`" } ] }"
            $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Audit EXCEPTION\] braces \(high\).*excepted until'
            Get-Content $env:NPM_SHIM_LOG -Raw | Should -Match 'audit --json --audit-level=high'
        }

        It 'blocks an advisory that no exception covers' {
            Write-AuditExceptionFixture "{ `"exceptions`": [ { `"id`": `"GHSA-2222-3333-4444`", `"reason`": `"other`", `"expires`": `"$InExpiry`" } ] }"
            $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'braces \(high\).*GHSA-vfj7-8cjw-p6xm'
        }

        It 'blocks when the exception <Case>' -ForEach @(
            @{ Case = 'has expired'; Expires = '2020-01-01'; Message = 'expired on 2020-01-01' }
            @{ Case = 'is more than 90 days ahead'; Expires = '2099-01-01'; Message = 'more than 90 days ahead' }
            @{ Case = 'has a malformed date'; Expires = '31/10/2026'; Message = 'no expires date' }
        ) {
            Write-AuditExceptionFixture "{ `"exceptions`": [ { `"id`": `"GHSA-vfj7-8cjw-p6xm`", `"reason`": `"r`", `"expires`": `"$Expires`" } ] }"
            $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match ([regex]::Escape($Message))
        }

        It 'blocks an exception without a reason, a non-GHSA id, or an unreadable file' -ForEach @(
            @{ Json = "{ `"exceptions`": [ { `"id`": `"GHSA-vfj7-8cjw-p6xm`", `"reason`": `"  `", `"expires`": `"2026-10-31`" } ] }"; Message = 'has no reason' }
            @{ Json = "{ `"exceptions`": [ { `"id`": `"CVE-2024-1234`", `"reason`": `"r`", `"expires`": `"2026-10-31`" } ] }"; Message = 'not a GitHub advisory id' }
            @{ Json = '{ not json'; Message = 'not valid JSON' }
        ) {
            Write-AuditExceptionFixture $Json
            $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match $Message
        }

        It 'blocks when npm audit itself fails (no readable report, or an error object)' -ForEach @(
            @{ Report = 'npm ERR! network'; Message = 'no readable report' }
            @{ Report = '{"error":{"code":"ENOTFOUND","summary":"request to registry failed"}}'; Message = 'request to registry failed' }
        ) {
            [System.IO.File]::WriteAllText($env:NPM_SHIM_JSON, $Report)
            Write-AuditExceptionFixture "{ `"exceptions`": [ { `"id`": `"GHSA-vfj7-8cjw-p6xm`", `"reason`": `"r`", `"expires`": `"$InExpiry`" } ] }"
            $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match $Message
        }

        It 'leaves the human-readable npm audit unchanged when the repository has no exceptions file' {
            $result = Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo
            $result.ExitCode | Should -Be 1
            (Get-Content $env:NPM_SHIM_LOG -Raw).Trim() | Should -BeExactly 'audit --audit-level=high'
        }
    }

    Context 'yarn, Go, and composer coverage' {
        BeforeEach {
            foreach ($tool in @('yarn', 'govulncheck', 'composer')) {
                New-CommandShim -Directory $ShimDir -Name $tool -MarkerPath (Join-Path $Repo ".args-$tool")
            }
            [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "name": "fixture" }')
        }

        It 'blocks Yarn classic when the exit bitmask reports <Name> advisories' -ForEach @(
            @{ Name = 'HIGH'; Code = 8 }, @{ Name = 'CRITICAL'; Code = 16 }, @{ Name = 'LOW+HIGH'; Code = 10 }
        ) {
            New-CommandShim -Directory $ShimDir -Name 'yarn' -ExitCode $Code -MarkerPath (Join-Path $Repo '.args-yarn')
            [System.IO.File]::WriteAllText((Join-Path $Repo 'yarn.lock'), "# yarn lockfile v1`n")
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
            Get-Content (Join-Path $Repo '.args-yarn') -Raw | Should -Match '^audit'
        }

        It 'does not block Yarn classic for <Name>-only advisories' -ForEach @(
            @{ Name = 'INFO+LOW+MODERATE'; Code = 7 }, @{ Name = 'no'; Code = 0 }
        ) {
            New-CommandShim -Directory $ShimDir -Name 'yarn' -ExitCode $Code -MarkerPath (Join-Path $Repo '.args-yarn')
            [System.IO.File]::WriteAllText((Join-Path $Repo 'yarn.lock'), "# yarn lockfile v1`n")
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        }

        It 'uses yarn npm audit for Yarn Berry projects (.yarnrc.yml)' {
            [System.IO.File]::WriteAllText((Join-Path $Repo 'yarn.lock'), "__metadata:`n  version: 8`n")
            [System.IO.File]::WriteAllText((Join-Path $Repo '.yarnrc.yml'), "nodeLinker: node-modules`n")
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
            Get-Content (Join-Path $Repo '.args-yarn') -Raw | Should -Match '^npm audit --all --recursive --severity high'
        }

        It 'blocks Yarn Berry when it reports advisories at or above high' {
            New-CommandShim -Directory $ShimDir -Name 'yarn' -ExitCode 1
            [System.IO.File]::WriteAllText((Join-Path $Repo 'yarn.lock'), "__metadata:`n  version: 8`n")
            [System.IO.File]::WriteAllText((Join-Path $Repo '.yarnrc.yml'), "nodeLinker: node-modules`n")
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
        }

        It 'audits a Go module with govulncheck and blocks on findings' {
            [System.IO.File]::WriteAllText((Join-Path $Repo 'go.mod'), "module example.com/fixture`n")
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
            (Get-Content (Join-Path $Repo '.args-govulncheck') -Raw).Trim() | Should -BeExactly './...'

            New-CommandShim -Directory $ShimDir -Name 'govulncheck' -ExitCode 3
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
        }

        It 'audits composer.lock at high severity without failing on abandoned packages' {
            [System.IO.File]::WriteAllText((Join-Path $Repo 'composer.json'), '{ "name": "acme/fixture" }')
            [System.IO.File]::WriteAllText((Join-Path $Repo 'composer.lock'), '{ "packages": [] }')
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
            $argsText = Get-Content (Join-Path $Repo '.args-composer') -Raw
            $argsText | Should -Match '^audit --locked'
            $argsText | Should -Match '--ignore-severity low --ignore-severity medium'
            $argsText | Should -Match '--abandoned=report'

            New-CommandShim -Directory $ShimDir -Name 'composer' -ExitCode 1
            (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 1
        }
    }
}
