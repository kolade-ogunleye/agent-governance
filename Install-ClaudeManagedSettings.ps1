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
.EXAMPLE
    sudo pwsh -NoProfile -File ./Install-ClaudeManagedSettings.ps1
.EXAMPLE
    ./Install-ClaudeManagedSettings.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [string]$DestinationPath,
    [switch]$Remove
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

$target = if ($DestinationPath) { $DestinationPath } else { Get-ManagedSettingsPath }
$guardSource = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'template' 'scripts' 'guardrails' 'agent-bash-guard.ps1')).Path
$guardTarget = Join-Path ([System.IO.Path]::GetFullPath((Split-Path -Parent ([System.IO.Path]::GetFullPath($target))))) 'agent-bash-guard.ps1'

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
