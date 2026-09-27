# scripts/guardrails/agent-bash-guard.ps1
# Claude Code PreToolUse hook (Bash / PowerShell tools): blocks commands that bypass or disable governance guardrails.
# Exit 2 blocks the tool call and shows stderr to the agent; exit 1 is a non-blocking hook error.
# This is a best-effort string check; the server-side ruleset remains the non-bypassable control.

$ErrorActionPreference = 'Stop'

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $command = [string]$payload.tool_input.command
} catch {
    [Console]::Error.WriteLine("agent-bash-guard: unreadable hook payload: $($_.Exception.Message)")
    exit 1
}
if (-not $command) { exit 0 }

# Heredoc bodies and quoted text (commit messages, echo arguments) are data, not flags.
# Heredocs go first: their bodies may contain unbalanced quotes.
$unquoted = $command -replace '(?s)<<-?\s*([''"]?)(\w+)\1(?<line>[^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|$)', '<<$2${line}'
$unquoted = $unquoted -replace '"(?:[^"\\]|\\.)*"', '""' -replace "'[^']*'", "''"

# One shell segment: stops at command separators and pipes.
$seg = '[^;&|\n]*'
$rules = [ordered]@{
    'git --no-verify skips the governance hooks'                          = "\bgit\b$seg\s--no-verify\b"
    'git commit -n skips the governance hooks'                            = "\bgit\b$seg\bcommit\b$seg\s-[A-Za-z]*n[A-Za-z]*\b"
    'LEFTHOOK=0 / LEFTHOOK_EXCLUDE disables the governance hooks'         = '\bLEFTHOOK(_EXCLUDE)?\s*=|\$env:LEFTHOOK'
    'lefthook install/uninstall replaces the fail-closed governance gate' = '\blefthook\s+(install|uninstall)\b'
    'overriding core.hooksPath redirects git away from governance hooks'  = "-c\s*core\.hooksPath=|\bgit\b$seg\bconfig\b$seg\bcore\.hooksPath\s+[^\s;&|]"
    'pushing directly to main/master bypasses review'                     = "\bgit\b$seg\bpush\b$seg(\s|:)(main|master)\b"
}

$violations = foreach ($reason in $rules.Keys) {
    if ($unquoted -match $rules[$reason]) { $reason }
}

if ($violations) {
    [Console]::Error.WriteLine("❌ [Agent Governance] Command blocked: " + ($violations -join '; ') + ".")
    [Console]::Error.WriteLine("👉 Governance guardrails must not be bypassed. Fix the underlying hook failure, or ask the user to act.")
    exit 2
}

exit 0
