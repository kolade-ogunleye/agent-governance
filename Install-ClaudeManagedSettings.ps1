<#
.SYNOPSIS
    Installs this hub's Claude Code managed settings: policy that no project, user or local file can override.
.DESCRIPTION
    Project settings (.claude/settings.json) are the agent's own working copy: a local settings file can turn
    hooks off with disableAllHooks, and an agent can write that file. Managed settings sit above every other
    level. This script copies this hub's Bash guard next to the policy, renders
    managed/claude-code-managed-settings.json with the absolute path of that copy (hooks run in exec form, so the
    path must be literal) and writes both to the operating system's managed-settings directory:
      - Linux and WSL: /etc/claude-code/managed-settings.json
      - macOS:         /Library/Application Support/ClaudeCode/managed-settings.json
      - Windows:       C:\Program Files\ClaudeCode\managed-settings.json
    Writing there needs administrator rights (sudo on Linux and macOS, an elevated prompt on Windows), and so
    does changing either file afterwards: the guard the policy runs cannot be edited by an agent or by anything
    running as the user, unlike the hub clone. A guard update reaches this machine only when the installer is
    re-run, which is the deliberate, elevated step.
    Claude Code reads the file at startup and reloads it when it changes; `/status` shows the managed source.
.PARAMETER DestinationPath
    Write the rendered file here instead of the operating system location (tests, custom runner images).
.PARAMETER Remove
    Delete the managed settings file and the installed guard copy instead of installing them.
.PARAMETER Verify
    Change nothing; check the installed policy and report each check, then exit 1 if any failed. It needs no
    administrator rights. Checks: the policy exists and equals what this hub would install now (same deny rules,
    sandbox and hook); its hook runs the guard copy beside it; that copy is byte-identical to this hub's guard;
    and only administrators (Windows: SYSTEM, Administrators, TrustedInstaller; Linux and macOS: root, no
    group or other write) can change the policy, the guard or their directory. The report names the hub commit
    and the guard's SHA-256, so a reviewer without access to this machine can recompute the hash of
    template/scripts/guardrails/agent-bash-guard.ps1 at that commit and compare.
.EXAMPLE
    sudo pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1
.EXAMPLE
    ./Install-ClaudeManagedSettings.ps1 -WhatIf
.EXAMPLE
    pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1 -Verify
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [string]$DestinationPath,
    [switch]$Remove,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

function Get-ManagedSettingsPath {
    [OutputType([string])]
    param()
    if ($IsWindows) { return (Join-Path $env:ProgramFiles 'ClaudeCode' 'managed-settings.json') }
    if ($IsMacOS) { return '/Library/Application Support/ClaudeCode/managed-settings.json' }
    return '/etc/claude-code/managed-settings.json'
}

function Get-RenderedManagedPolicy {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$HubRoot, [Parameter(Mandatory = $true)][string]$GuardPath)
    # The installed copy of the guard is the one every repository on this machine is checked against: a
    # repository-local copy, or the hub clone's, could be edited by the agent it is meant to constrain.
    $guard = $GuardPath
    $template = Get-Content -LiteralPath (Join-Path $HubRoot 'managed' 'claude-code-managed-settings.json') -Raw | ConvertFrom-Json
    foreach ($entry in $template.hooks.PreToolUse) {
        foreach ($hook in $entry.hooks) {
            $hook.args = @($hook.args | ForEach-Object { if ($_ -eq '__HUB_GUARD__') { $guard } else { $_ } })
        }
    }
    return ((($template | ConvertTo-Json -Depth 12) -replace "`r`n", "`n").TrimEnd("`n") + "`n")
}

function Test-AdministratorOnlyWrite {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    # True when only administrators can modify $Path. A directory a user can write lets that user replace a file
    # inside it, so callers check the directory as well as the files.
    if ($IsWindows) {
        # By SID, so the check does not depend on the display language: SYSTEM, Administrators, TrustedInstaller.
        $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        # Only bits that allow a change: WriteData/CreateFiles, AppendData, WriteExtendedAttributes,
        # DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership, and the generic
        # GENERIC_ALL and GENERIC_WRITE bits. Modify and FullControl include these; read-and-execute does not.
        $writeMask = 2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288 -bor 0x10000000 -bor 0x40000000
        $writers = foreach ($rule in (Get-Acl -LiteralPath $Path).Access) {
            if ($rule.AccessControlType -ne 'Allow' -or -not ([long]$rule.FileSystemRights -band $writeMask)) { continue }
            # An inherit-only entry applies to children, not to this item.
            if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            $sid = try { $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { "$($rule.IdentityReference)" }
            if ($sid -notin $trusted) { "$($rule.IdentityReference)" }
        }
        $writers = @($writers | Sort-Object -Unique)
        return [pscustomobject]@{ Passed = ($writers.Count -eq 0); Detail = $(if ($writers) { "also writable by: $($writers -join ', ')" } else { 'administrators only' }) }
    }
    $owner = if ($IsMacOS) { "$(& stat -f '%u' $Path)".Trim() } else { "$(& stat -c '%u' $Path)".Trim() }
    $mode = [System.IO.File]::GetUnixFileMode($Path)
    $looseBits = [System.IO.UnixFileMode]'GroupWrite, OtherWrite'
    $problems = @()
    if ($owner -ne '0') { $problems += "owner uid $owner, not root" }
    if ($mode -band $looseBits) { $problems += "group or other can write ($mode)" }
    return [pscustomobject]@{ Passed = ($problems.Count -eq 0); Detail = $(if ($problems) { $problems -join '; ' } else { 'root only' }) }
}

$target = if ($DestinationPath) { $DestinationPath } else { Get-ManagedSettingsPath }
$guardSource = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1')).Path
$guardTarget = Join-Path ([System.IO.Path]::GetFullPath((Split-Path -Parent ([System.IO.Path]::GetFullPath($target))))) 'agent-bash-guard.ps1'

if ($Verify) {
    # Read-only: never writes, so it runs without administrator rights and ignores -WhatIf/-Confirm.
    $checks = [System.Collections.Generic.List[pscustomobject]]::new()
    function Add-Check { param([string]$Name, [bool]$Passed, [string]$Detail) $checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail }) }

    $hubCommit = "$(git -C $PSScriptRoot rev-parse HEAD 2>$null)".Trim()
    $hubDirty = @(git -C $PSScriptRoot status --porcelain -- template/scripts/guardrails/agent-bash-guard.ps1 managed/claude-code-managed-settings.json 2>$null)
    Add-Check 'Hub clone matches its commit (guard and policy template unmodified)' ($hubCommit -and $hubDirty.Count -eq 0) $(if (-not $hubCommit) { 'not a git clone' } elseif ($hubDirty) { "uncommitted: $($hubDirty -join '; ')" } else { $hubCommit })

    $policyPresent = Test-Path -LiteralPath $target
    Add-Check 'Policy installed' $policyPresent $target
    $guardPresent = Test-Path -LiteralPath $guardTarget
    Add-Check 'Guard copy installed beside the policy' $guardPresent $guardTarget

    $guardHash = if ($guardPresent) { (Get-FileHash -LiteralPath $guardTarget -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
    $hubGuardHash = (Get-FileHash -LiteralPath $guardSource -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Check 'Guard copy is byte-identical to the hub guard' ($guardPresent -and $guardHash -eq $hubGuardHash) $(if (-not $guardPresent) { 'missing' } elseif ($guardHash -eq $hubGuardHash) { "sha256 $guardHash" } else { "installed $guardHash, hub ${hubGuardHash}: re-run the installer elevated" })

    if ($policyPresent) {
        $installed = ([System.IO.File]::ReadAllText($target) -replace "`r`n", "`n")
        $expected = Get-RenderedManagedPolicy -HubRoot $PSScriptRoot -GuardPath $guardTarget
        Add-Check 'Policy equals what this hub installs now' ($installed -eq $expected) $(if ($installed -eq $expected) { 'deny rules, sandbox and hook current' } else { 'differs: re-run the installer elevated' })
        $hookPaths = @(try { (($installed | ConvertFrom-Json).hooks.PreToolUse | ForEach-Object { $_.hooks } | ForEach-Object { $_.args }) | Where-Object { $_ -like '*agent-bash-guard.ps1' } } catch { @() })
        $pointsAtCopy = $hookPaths.Count -gt 0 -and @($hookPaths | Where-Object { $_ -ne $guardTarget }).Count -eq 0
        Add-Check 'Policy hook runs the installed guard copy' $pointsAtCopy $(if ($hookPaths) { $hookPaths -join ', ' } else { 'no guard hook found' })
    }

    foreach ($path in @($target, $guardTarget, (Split-Path -Parent $guardTarget))) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $acl = Test-AdministratorOnlyWrite -Path $path
        Add-Check "Only administrators can change $path" $acl.Passed $acl.Detail
    }

    $failed = @($checks | Where-Object { -not $_.Passed }).Count
    $checks.Add([pscustomobject]@{ Check = 'SUMMARY'; Passed = ($failed -eq 0); Detail = "$($checks.Count - $failed)/$($checks.Count) passed; hub $hubCommit; guard sha256 $guardHash" })
    $checks
    if ($failed -gt 0) {
        # exit ends the script before PowerShell formats pipeline output, so under -File a failing run would print
        # nothing; render the report to the console first.
        Write-Host ($checks | Format-Table -AutoSize -Wrap | Out-String -Width 220)
        exit 1
    }
    return
}

if ($Remove) {
    if (-not (Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $guardTarget)) { return [pscustomobject]@{ Path = $target; Action = 'absent' } }
    if (-not $PSCmdlet.ShouldProcess($target, 'Remove Claude Code managed settings and the installed guard')) { return [pscustomobject]@{ Path = $target; Action = 'would-remove' } }
    # Policy first: a policy left without its guard would point a required hook at a missing script.
    foreach ($path in @($target, $guardTarget)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    return [pscustomobject]@{ Path = $target; Action = 'removed' }
}

$content = Get-RenderedManagedPolicy -HubRoot $PSScriptRoot -GuardPath $guardTarget
if (-not $PSCmdlet.ShouldProcess($target, 'Install Claude Code managed settings')) {
    return [pscustomobject]@{ Path = $target; Action = 'would-install' }
}

$directory = Split-Path -Parent $target
try {
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    # Guard first, policy second: the policy never points at a guard that is not in place.
    Copy-Item -LiteralPath $guardSource -Destination $guardTarget -Force
    [System.IO.File]::WriteAllText($target, $content, [System.Text.UTF8Encoding]::new($false))
} catch [System.UnauthorizedAccessException], [System.IO.IOException] {
    throw "Cannot write $target ($($_.Exception.Message)). Run as administrator: 'sudo pwsh -NoProfile -File $PSCommandPath' on Linux and macOS, or an elevated PowerShell on Windows."
}
Write-Information "Installed Claude Code managed settings at $target with the guard at $guardTarget. Run /status inside Claude Code to confirm the managed source." -InformationAction Continue
return [pscustomobject]@{ Path = $target; Guard = $guardTarget; Action = 'installed' }
