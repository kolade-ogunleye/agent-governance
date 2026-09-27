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

    It 'allows commits on a detached HEAD during rebase or bisect (plan defect 8)' -Skip {
        git -C $Repo checkout --quiet --detach
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
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

    It 'does not treat files merely containing "test" in their name as tests (plan defect 8)' -Skip {
        git -C $Repo rm --quiet src/latest.js
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

    It 'runs every detected stack in a polyglot repository (plan defect 8)' -Skip {
        [System.IO.File]::WriteAllText((Join-Path $Repo 'package.json'), '{ "scripts": { "test": "x" } }')
        [System.IO.File]::WriteAllText((Join-Path $Repo 'pyproject.toml'), "[project]`nname = 'fixture'`n")
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
        Join-Path $Repo '.ran-npm' | Should -Exist
        Join-Path $Repo '.ran-pytest' | Should -Exist
    }
}
