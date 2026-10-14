<#
.SYNOPSIS
    Installs this hub's Codex requirements: admin-enforced policy that no user or project setting can weaken.
.DESCRIPTION
    Codex reads requirements.toml from an administrator-only location and enforces it over every user, project and
    session setting. This script renders managed/codex-requirements.toml, copies this hub's Bash guard into a
    hooks directory beside it, and writes both:
      - Windows:       %ProgramData%\OpenAI\Codex\requirements.toml  (guard in ...\Codex\hooks\)
      - Linux and WSL: /etc/codex/requirements.toml                  (guard in /etc/codex/hooks/)
    The requirements limit approvals and sandbox modes, deny reads of secrets, forbid the common hook-bypass and
    push-to-main commands, and run the guard as a managed PreToolUse hook on every Bash call. Codex treats a hook
    that errors or times out as a failed hook rather than a blocked command, so the hook runs PowerShell by its
    absolute path and the command rules repeat the most common bypasses without a script.
    %ProgramData% lets ordinary users create files in new folders, unlike Program Files, so on Windows the
    installer replaces the Codex folder's permissions with administrators-and-SYSTEM write, users read.
    Scope: the Codex CLI and local Codex work. The Codex IDE extension does not read requirements.
.PARAMETER DestinationPath
    Write requirements.toml here instead of the operating system location (tests). The guard goes to a hooks
    folder beside it, and folder permissions are left as they are.
.PARAMETER Remove
    Delete the requirements file and the installed guard copy.
.PARAMETER Verify
    Change nothing; check the installed requirements and report each check, then exit 1 if any failed. It needs no
    administrator rights: the requirements equal what this hub would install now, the hook runs the guard copy,
    that copy is byte-identical to the hub's guard, and only administrators can change the files or their folders.
.EXAMPLE
    sudo ~/.local/bin/pwsh -NoProfile -File ./Install-CodexRequirements.ps1
.EXAMPLE
    pwsh -NoProfile -File ./Install-CodexRequirements.ps1 -Verify
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [string]$DestinationPath,
    [switch]$Remove,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'MachinePolicy.ps1')

$DefaultUnixDir = '/etc/codex'
function Get-DefaultWindowsDir {
    [OutputType([string])]
    param()
    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    # A string, not Join-Path: on Linux and macOS this renders the Windows default, and Join-Path would reject C:.
    return "$($programData.TrimEnd('\'))\OpenAI\Codex"
}

function Get-RenderedCodexRequirement {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$HubRoot,
        [Parameter(Mandatory = $true)][string]$HooksDir
    )
    # The file carries both platforms' hook commands; the one for this machine points at the real install, the
    # other at that platform's default location.
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    if ($IsWindows) {
        $winDir = $HooksDir; $winPwsh = $pwsh
        $unixDir = "$DefaultUnixDir/hooks"; $unixPwsh = '/usr/bin/pwsh'
    } else {
        $unixDir = $HooksDir; $unixPwsh = $pwsh
        $winDir = "$(Get-DefaultWindowsDir)\hooks"; $winPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }
    $text = [System.IO.File]::ReadAllText((Join-Path $HubRoot 'managed' 'codex-requirements.toml')) -replace "`r`n", "`n"
    $text = $text.Replace('__HOOKS_DIR_UNIX__', $unixDir).Replace('__HOOKS_DIR_WINDOWS__', $winDir)
    $text = $text.Replace('__PWSH_UNIX__', $unixPwsh).Replace('__PWSH_WINDOWS__', $winPwsh)
    $text = $text.Replace('__GUARD_UNIX__', "$unixDir/agent-bash-guard.ps1").Replace('__GUARD_WINDOWS__', "$($winDir.TrimEnd('\'))\agent-bash-guard.ps1")
    return $text.TrimEnd("`n") + "`n"
}

function Set-AdministratorOnlyAcl {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path)
    # Protected (no inheritance from %ProgramData%): SYSTEM and Administrators full control, Users read and execute.
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($entry[0])
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, $entry[1], $inherit, $none, 'Allow'))
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Restrict write access to administrators')) { Set-Acl -LiteralPath $Path -AclObject $acl }
}

$target = if ($DestinationPath) { [System.IO.Path]::GetFullPath($DestinationPath) } elseif ($IsWindows) { Join-Path (Get-DefaultWindowsDir) 'requirements.toml' } else { "$DefaultUnixDir/requirements.toml" }
$baseDir = Split-Path -Parent $target
$hooksDir = Join-Path $baseDir 'hooks'
$guardSource = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1')).Path
$guardTarget = Join-Path $hooksDir 'agent-bash-guard.ps1'

if ($Verify) {
    # Read-only: never writes, so it runs without administrator rights and ignores -WhatIf/-Confirm.
    $checks = [System.Collections.Generic.List[pscustomobject]]::new()
    function Add-Check { param([string]$Name, [bool]$Passed, [string]$Detail) $checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail }) }

    $hubCommit = "$(git -C $PSScriptRoot rev-parse HEAD 2>$null)".Trim()
    $hubDirty = @(git -C $PSScriptRoot status --porcelain -- template/scripts/guardrails/agent-bash-guard.ps1 managed/codex-requirements.toml 2>$null)
    Add-Check 'Hub clone matches its commit (guard and requirements template unmodified)' ($hubCommit -and $hubDirty.Count -eq 0) $(if (-not $hubCommit) { 'not a git clone' } elseif ($hubDirty) { "uncommitted: $($hubDirty -join '; ')" } else { $hubCommit })

    $present = Test-Path -LiteralPath $target
    Add-Check 'Requirements installed' $present $target
    $guardPresent = Test-Path -LiteralPath $guardTarget
    Add-Check 'Guard copy installed in the managed hooks folder' $guardPresent $guardTarget

    $guardHash = if ($guardPresent) { (Get-FileHash -LiteralPath $guardTarget -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
    $hubGuardHash = (Get-FileHash -LiteralPath $guardSource -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Check 'Guard copy is byte-identical to the hub guard' ($guardPresent -and $guardHash -eq $hubGuardHash) $(if (-not $guardPresent) { 'missing' } elseif ($guardHash -eq $hubGuardHash) { "sha256 $guardHash" } else { "installed $guardHash, hub ${hubGuardHash}: re-run the installer elevated" })

    if ($present) {
        $installed = [System.IO.File]::ReadAllText($target) -replace "`r`n", "`n"
        $expected = Get-RenderedCodexRequirement -HubRoot $PSScriptRoot -HooksDir $hooksDir
        Add-Check 'Requirements equal what this hub installs now' ($installed -eq $expected) $(if ($installed -eq $expected) { 'approvals, sandbox, secret reads, command rules and hook current' } else { 'differs: re-run the installer elevated' })
        $key = if ($IsWindows) { 'command_windows' } else { 'command' }
        $hookLine = [regex]::Match($installed, "(?m)^$key = '(.*)'$").Groups[1].Value
        $runsCopy = $hookLine -and $hookLine.Contains("""$guardTarget""")
        Add-Check 'Managed hook runs the installed guard copy' $runsCopy $(if ($hookLine) { $hookLine } else { 'no guard hook found' })
    }

    foreach ($path in @($target, $guardTarget, $hooksDir, $baseDir)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $acl = Test-AdministratorOnlyWrite -Path $path
        Add-Check "Only administrators can change $path" $acl.Passed $acl.Detail
    }

    $failed = @($checks | Where-Object { -not $_.Passed }).Count
    $checks.Add([pscustomobject]@{ Check = 'SUMMARY'; Passed = ($failed -eq 0); Detail = "$($checks.Count - $failed)/$($checks.Count) passed; hub $hubCommit; guard sha256 $guardHash" })
    $checks
    if ($failed -gt 0) {
        # exit ends the script before PowerShell formats pipeline output; render the report first.
        Write-Host ($checks | Format-Table -AutoSize -Wrap | Out-String -Width 220)
        exit 1
    }
    return
}

if ($Remove) {
    if (-not (Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $guardTarget)) { return [pscustomobject]@{ Path = $target; Action = 'absent' } }
    if (-not $PSCmdlet.ShouldProcess($target, 'Remove Codex requirements and the installed guard')) { return [pscustomobject]@{ Path = $target; Action = 'would-remove' } }
    # Requirements first: they would otherwise point a pinned hook at a missing script.
    foreach ($path in @($target, $guardTarget)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    return [pscustomobject]@{ Path = $target; Action = 'removed' }
}

$content = Get-RenderedCodexRequirement -HubRoot $PSScriptRoot -HooksDir $hooksDir
if (-not $PSCmdlet.ShouldProcess($target, 'Install Codex requirements')) {
    return [pscustomobject]@{ Path = $target; Action = 'would-install' }
}

try {
    if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
    if ($IsWindows -and -not $DestinationPath) { Set-AdministratorOnlyAcl -Path $baseDir -Confirm:$false }
    # Guard first, requirements second: the pinned hook never points at a guard that is not in place.
    Copy-Item -LiteralPath $guardSource -Destination $guardTarget -Force
    [System.IO.File]::WriteAllText($target, $content, [System.Text.UTF8Encoding]::new($false))
} catch [System.UnauthorizedAccessException], [System.IO.IOException] {
    throw "Cannot write $target ($($_.Exception.Message)). Run as administrator: 'sudo pwsh -NoProfile -File $PSCommandPath' on Linux, or an elevated PowerShell on Windows."
}
Write-Information "Installed Codex requirements at $target with the guard at $guardTarget." -InformationAction Continue
return [pscustomobject]@{ Path = $target; Guard = $guardTarget; Action = 'installed' }
