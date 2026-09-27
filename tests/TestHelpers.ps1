$ErrorActionPreference = 'Stop'

function New-TestRepo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates disposable fixtures inside Pester TestDrive only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Branch = 'main'
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    git -C $Path init --quiet --initial-branch=$Branch
    git -C $Path config user.email 'fixture@example.invalid'
    git -C $Path config user.name 'Fixture'
    git -C $Path config commit.gpgsign false
    [System.IO.File]::WriteAllText((Join-Path $Path 'README.md'), "# fixture`n")
    git -C $Path add README.md
    # Fixture setup commit must not run any machine-level hooks.
    git -C $Path -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: init fixture'
    return (Resolve-Path $Path).Path
}

function Add-FixtureCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Files
    )

    foreach ($relPath in $Files.Keys) {
        $full = Join-Path $RepoPath $relPath
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [System.IO.File]::WriteAllText($full, [string]$Files[$relPath])
        git -C $RepoPath add -- $relPath
    }
    git -C $RepoPath -c core.hooksPath=.git/no-hooks commit --quiet -m 'chore: add fixture files'
}

function New-CommandShim {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates disposable fixtures inside Pester TestDrive only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$ExitCode = 0,
        [string]$MarkerPath
    )

    # A stand-in executable that optionally records its invocation, so tests need no real toolchain.
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if ($IsWindows) {
        $body = if ($MarkerPath) { "New-Item -ItemType File -Path '$MarkerPath' -Force | Out-Null`n" } else { '' }
        [System.IO.File]::WriteAllText((Join-Path $Directory "$Name.ps1"), $body + "exit $ExitCode`n")
    } else {
        $body = if ($MarkerPath) { "touch '$MarkerPath'`n" } else { '' }
        $shim = Join-Path $Directory $Name
        [System.IO.File]::WriteAllText($shim, "#!/bin/sh`n" + $body + "exit $ExitCode`n")
        chmod +x $shim
    }
}

function Invoke-Guardrail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    Push-Location $RepoPath
    try {
        $output = & pwsh -NoProfile -File $ScriptPath 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output -join "`n")
        }
    } finally {
        Pop-Location
    }
}
