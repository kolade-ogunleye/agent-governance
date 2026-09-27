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

    It 'allows .env.example, which the canonical .gitignore explicitly permits (plan defect 8)' -Skip {
        [System.IO.File]::WriteAllText((Join-Path $Repo '.env.example'), "API_URL=`n")
        git -C $Repo add .env.example
        (Invoke-Guardrail -ScriptPath $Guard -RepoPath $Repo).ExitCode | Should -Be 0
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

        # Shim runners record that they were invoked, so no real toolchain is needed.
        $script:ShimDir = Join-Path $TestDrive ("shims-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $ShimDir | Out-Null
        foreach ($tool in @('npm', 'pytest')) {
            $marker = Join-Path $Repo ".ran-$tool"
            if ($IsWindows) {
                [System.IO.File]::WriteAllText((Join-Path $ShimDir "$tool.ps1"), "New-Item -ItemType File -Path '$marker' -Force | Out-Null`nexit 0`n")
            } else {
                $shim = Join-Path $ShimDir $tool
                [System.IO.File]::WriteAllText($shim, "#!/bin/sh`ntouch '$marker'`nexit 0`n")
                chmod +x $shim
            }
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
