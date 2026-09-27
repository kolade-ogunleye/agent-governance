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
}
