<#
.SYNOPSIS
    Merges this hub's deny rules for Google Antigravity (agy) into the user's Antigravity CLI settings.
.DESCRIPTION
    Antigravity evaluates permissions as deny > ask > allow from ~/.gemini/antigravity-cli/settings.json. This
    script adds managed/antigravity-permissions.json's deny rules (hook bypasses, hook-path and git-config
    overrides, pushes to main, credential directories, and writes to the files the hub manages) to that file's
    permissions.deny list. Every other setting and rule is kept.
    Antigravity documents no administrator-enforced policy, so this is a user-level file: it constrains the agent,
    which treats files outside the workspace as ask-by-default, but not someone editing it by hand. The
    server-side gate and the provenance audit remain the backstop. The Antigravity app keeps its rules in
    Settings > General > Permission Settings; -Verify prints the list to paste there.
.PARAMETER SettingsPath
    The settings file to update (default: ~/.gemini/antigravity-cli/settings.json).
.PARAMETER Remove
    Remove this hub's rules, leaving the rest of the file.
.PARAMETER Verify
    Change nothing; report whether every rule is present and exit 1 if any is missing.
.EXAMPLE
    pwsh -NoProfile -File ./Install-AntigravityPermissions.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
[OutputType([pscustomobject])]
param(
    [string]$SettingsPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gemini' 'antigravity-cli' 'settings.json'),
    [switch]$Remove,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

function Get-HubDenyRule {
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$HubRoot)
    # Antigravity normalizes Windows paths to forward slashes.
    $userHome = ([Environment]::GetFolderPath('UserProfile')) -replace '\\', '/'
    $rules = (Get-Content -LiteralPath (Join-Path $HubRoot 'managed' 'antigravity-permissions.json') -Raw | ConvertFrom-Json).deny
    return @($rules | ForEach-Object { $_.Replace('__HOME__', $userHome) })
}

function Read-Setting {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    $text = [System.IO.File]::ReadAllText($Path)
    if (-not $text.Trim()) { return [pscustomobject]@{} }
    try { return ($text | ConvertFrom-Json) } catch { throw "Cannot parse $Path as JSON; fix or move it, then re-run. ($($_.Exception.Message))" }
}

$rules = Get-HubDenyRule -HubRoot $PSScriptRoot
$settings = Read-Setting -Path $SettingsPath
$current = @(if ($settings.PSObject.Properties['permissions'] -and $settings.permissions.PSObject.Properties['deny']) { $settings.permissions.deny } else { @() })

if ($Verify) {
    $missing = @($rules | Where-Object { $_ -notin $current })
    $rows = @(foreach ($r in $rules) { [pscustomobject]@{ Rule = $r; Present = ($r -in $current) } })
    $rows
    $summary = [pscustomobject]@{ Rule = 'SUMMARY'; Present = ($missing.Count -eq 0) }
    $summary
    if ($missing.Count -gt 0) {
        Write-Host ($rows | Format-Table -AutoSize -Wrap | Out-String -Width 220)
        Write-Host "$($missing.Count) of $($rules.Count) rules missing from $SettingsPath. Run the installer; for the Antigravity app, add them under Settings > General > Permission Settings."
        exit 1
    }
    return
}

$updated = if ($Remove) { @($current | Where-Object { $_ -notin $rules }) } else { @($current) + @($rules | Where-Object { $_ -notin $current }) }
$action = if ($Remove) { 'removed' } else { 'installed' }
if (-not $PSCmdlet.ShouldProcess($SettingsPath, "Antigravity deny rules: $action")) { return [pscustomobject]@{ Path = $SettingsPath; Action = "would-$action" } }

if (-not $settings.PSObject.Properties['permissions']) { $settings | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) }
if ($settings.permissions.PSObject.Properties['deny']) { $settings.permissions.deny = $updated } else { $settings.permissions | Add-Member -NotePropertyName deny -NotePropertyValue $updated }
New-Item -ItemType Directory -Path (Split-Path -Parent $SettingsPath) -Force | Out-Null
[System.IO.File]::WriteAllText($SettingsPath, (($settings | ConvertTo-Json -Depth 20) -replace "`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
return [pscustomobject]@{ Path = $SettingsPath; Action = $action; Rules = $rules.Count }
