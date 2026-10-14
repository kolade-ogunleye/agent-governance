# GitHub Copilot preToolUse hook: runs agent-bash-guard.ps1 on Copilot's shell tool calls.
# Copilot sends { toolName, toolArgs } (toolArgs an object, or a JSON string in some versions); the guard reads
# Claude Code's { tool_name, tool_input.command }. This adapter translates, and answers Copilot with
# { permissionDecision: "deny", permissionDecisionReason } and exit 2 when the guard blocks.
# Copilot denies the tool call on any non-zero exit, so an unreadable payload fails closed here too.
$ErrorActionPreference = 'Stop'

function Write-Deny {
    param([Parameter(Mandatory = $true)][string]$Reason)
    [Console]::Out.WriteLine((@{ permissionDecision = 'deny'; permissionDecisionReason = $Reason } | ConvertTo-Json -Compress))
    exit 2
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch {
    Write-Deny "agent-governance: unreadable Copilot hook payload ($($_.Exception.Message))."
}

$tool = [string]$payload.toolName
$shell = switch -Regex ($tool) { '^(?i)bash$' { 'Bash' } '^(?i)powershell$' { 'PowerShell' } default { $null } }
if (-not $shell) { exit 0 }

$toolArgs = $payload.toolArgs
if ($toolArgs -is [string]) {
    try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { Write-Deny "agent-governance: unreadable $tool arguments." }
}
$command = [string]$toolArgs.command
# A shell call whose command this adapter cannot find is denied, not allowed: a silent pass would hide a change in
# Copilot's payload behind every command running unchecked.
if (-not $command) { Write-Deny "agent-governance: could not read the $tool command to check it; tell the user the Copilot hook needs updating." }

$guard = Join-Path $PSScriptRoot 'agent-bash-guard.ps1'
$guardInput = @{ tool_name = $shell; tool_input = @{ command = $command } } | ConvertTo-Json -Compress
$stderr = Join-Path ([System.IO.Path]::GetTempPath()) ("copilot-guard-" + [guid]::NewGuid().ToString('N') + '.txt')
try {
    $guardInput | & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) -NoProfile -File $guard 2> $stderr | Out-Null
    $code = $LASTEXITCODE
    $message = if (Test-Path -LiteralPath $stderr) { ((Get-Content -LiteralPath $stderr -Raw) ?? '').Trim() } else { '' }
} finally {
    Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
}
if ($code -eq 0) { exit 0 }
Write-Deny $(if ($message) { $message } else { "agent-governance: the command guard failed (exit $code); the command was not run." })
