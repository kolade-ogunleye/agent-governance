$ErrorActionPreference = 'Stop'

# The governance hook block the engine installs fails closed for detected agent sessions when Lefthook is
# missing, and fixtures in this suite commit through that hook. Running the suite from inside an agent session
# (every Claude Code session sets CLAUDECODE) must not change the results, so the markers are cleared for this
# test process. The detection itself is covered by AgentSessionGate.Tests.ps1, which sets a marker deliberately.
foreach ($marker in @('CLAUDECODE', 'CLAUDE_CODE', 'AI_AGENT', 'AGENT_ROLE', 'GEMINI_CLI', 'CODEX_AGENT', 'COPILOT_AGENT')) {
    if (Test-Path -LiteralPath "env:$marker") { Remove-Item -LiteralPath "env:$marker" }
}

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

    # A stand-in executable that optionally records its arguments (one invocation per line),
    # so tests need no real toolchain.
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if ($IsWindows) {
        $body = if ($MarkerPath) { "Add-Content -Path '$MarkerPath' -Value (`$args -join ' ')`n" } else { '' }
        [System.IO.File]::WriteAllText((Join-Path $Directory "$Name.ps1"), $body + "exit $ExitCode`n")
    } else {
        $body = if ($MarkerPath) { "echo `"`$*`" >> '$MarkerPath'`n" } else { '' }
        $shim = Join-Path $Directory $Name
        [System.IO.File]::WriteAllText($shim, "#!/bin/sh`n" + $body + "exit $ExitCode`n")
        chmod +x $shim
    }
}

function Get-WorkflowStepScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$WorkflowPath,
        [Parameter(Mandatory = $true)][string]$StepName
    )
    # Returns the dedented `run: |` block of the named step, so tests execute the shipped script itself.
    $lines = Get-Content -LiteralPath $WorkflowPath
    $step = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match "^\s+- name: $([regex]::Escape($StepName))\s*$" })
    if ($step -lt 0) { throw "Step '$StepName' not found in $WorkflowPath" }
    $runIdx = $step + 1
    while ($lines[$runIdx] -notmatch '^\s+run: \|\s*$') { $runIdx++ }
    $indent = ($lines[$runIdx + 1] -replace '^(\s*).*', '$1').Length
    $body = [System.Collections.Generic.List[string]]::new()
    for ($i = $runIdx + 1; $i -lt $lines.Count -and ($lines[$i] -eq '' -or ($lines[$i] -replace '^(\s*).*', '$1').Length -ge $indent); $i++) {
        $body.Add($(if ($lines[$i].Length -ge $indent) { $lines[$i].Substring($indent) } else { '' }))
    }
    return ($body -join "`n").TrimEnd() + "`n"
}

function Get-TestBash {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Git's own bash on Windows (a bare 'bash' may resolve to WSL, which cannot open Windows paths); system bash elsewhere.
    if (-not $IsWindows) { return 'bash' }
    # git.exe may live in <Git>\cmd or <Git>\mingw64\bin; walk up to the Git root that has bin\bash.exe.
    $dir = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source
    while ($dir -and -not (Test-Path (Join-Path $dir 'bin' 'bash.exe'))) { $dir = Split-Path -Parent $dir }
    if (-not $dir) { throw 'Git for Windows bash.exe not found.' }
    return (Join-Path $dir 'bin' 'bash.exe')
}

function Invoke-HookScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText
    )

    # Mirrors how Claude Code invokes a command hook: JSON payload on stdin.
    $output = $InputText | & pwsh -NoProfile -File $ScriptPath 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join "`n")
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
