# scripts/guardrails/agent-bash-guard.ps1
# Claude Code PreToolUse hook (Bash / PowerShell tools): blocks commands that bypass or disable governance guardrails.
# Exit 2 blocks the tool call and shows stderr to the agent; exit 1 is a non-blocking hook error.
# Best-effort string check: it inspects the command text the agent wrote, not what a program will do at run time.
# Accepted misses (documented in docs/adr/0003-command-guard-defence-in-depth.md): commands read from files or
# generated at run time, and shell variables expanded by the shell. The native permissions.deny rules in
# .claude/settings.json match the same text independently, and the server-side gate remains the backstop.

$ErrorActionPreference = 'Stop'

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $command = [string]$payload.tool_input.command
} catch {
    [Console]::Error.WriteLine("agent-bash-guard: unreadable hook payload: $($_.Exception.Message)")
    exit 1
}
if (-not $command) { exit 0 }

function Get-TextWithoutHeredocBody {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Text)
    # Heredoc bodies (commit messages via -F -) are data. They go first: their bodies may contain unbalanced quotes.
    return ($Text -replace '(?s)<<-?\s*([''"]?)(\w+)\1(?<line>[^\n]*)\n.*?\n[ \t]*\2[ \t]*(?=\n|$)', '<<$2${line}')
}

function ConvertTo-InspectableText {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Text)
    # A quoted single word keeps its content: quotes do not change what reaches git ('--no-verify' is the flag),
    # so they must not hide it from the matcher. Quoted text containing whitespace is prose (commit messages,
    # echo arguments) and is blanked so flags merely mentioned in it are not counted.
    $unquote = { param($m) $inner = $m.Groups[1].Value; if ($inner -match '^[^\s;&|]*$') { $inner } else { '""' } }
    $text = [regex]::Replace($Text, '"((?:[^"\\]|\\.)*)"', $unquote)
    return [regex]::Replace($text, "'([^']*)'", $unquote)
}

$stripped = Get-TextWithoutHeredocBody -Text $command
$texts = [System.Collections.Generic.List[string]]::new()
$texts.Add((ConvertTo-InspectableText -Text $stripped))
# Commands handed to a nested shell (sh -c "...", pwsh -Command "...", eval "...") are inspected as commands.
$nested = '(?s)\b(?:sh|bash|zsh|dash|ksh|busybox|pwsh|powershell|cmd)(?:\.exe)?\b(?:\s+-[^\s"'']*)*?\s+(?:-[A-Za-z]*c|-Command|-e|/c)\s*(["''])(.*?)\1|\beval\s+(["''])(.*?)\3'
foreach ($m in [regex]::Matches($stripped, $nested)) {
    $inner = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[4].Value }
    if ($inner) { $texts.Add((ConvertTo-InspectableText -Text (Get-TextWithoutHeredocBody -Text $inner))) }
}

# One shell segment: stops at command separators and pipes.
$seg = '[^;&|\n]*'
$hookFile = '(?:\.git[\\/]hooks|\.githooks|\.husky)[\\/](?:pre-commit|pre-push)\b'
$rules = [ordered]@{
    # Git accepts any unambiguous abbreviation of a long option, so --no-verif (and longer) is --no-verify.
    'git --no-verify skips the governance hooks'                             = "\bgit\b$seg\s--no-verif\w*"
    'git commit -n skips the governance hooks'                               = "\bgit\b$seg\bcommit\b$seg\s-[A-Za-z]*n[A-Za-z]*\b"
    'a shell variable holding a hook-bypass flag hides it from review'       = '(?:^|[\s;&|(])\$?\w+\s*=\s*["'']?--no-verif'
    'LEFTHOOK=0 / LEFTHOOK_EXCLUDE disables the governance hooks'            = '\bLEFTHOOK(_EXCLUDE)?\s*=|\benv:LEFTHOOK'
    'lefthook install/uninstall replaces the fail-closed governance gate'    = '\blefthook\s+(install|uninstall)\b'
    'overriding core.hooksPath redirects git away from governance hooks'     = "\bcore\.hooksPath\s*=|\bgit\b$seg\bconfig\b$seg\bcore\.hooksPath\s+[^\s;&|]|\bgit\b$seg\bconfig\b$seg\b(?:--)?unset(?:-all)?\s+core\.hooksPath"
    'GIT_CONFIG_* environment overrides redirect git configuration'          = '\bGIT_CONFIG_(?:COUNT|KEY_\d+|VALUE_\d+|PARAMETERS)\s*=|\benv:GIT_CONFIG_(?:COUNT|KEY_\d+|VALUE_\d+|PARAMETERS)'
    'pushing directly to main/master bypasses review'                        = "\bgit\b$seg\bpush\b$seg(?:\s\+?|:|refs/heads/)(?:main|master)(?=$|[\s;&|:])"
    'overwriting or removing a git hook file disables the governance gate'   = "(?:>>?|\b(?:rm|mv|cp|tee|chmod|truncate|install|ln|dd|sed\s+-i\S*|Set-Content|Out-File|Remove-Item|Move-Item|Copy-Item|Clear-Content|Add-Content|New-Item)\b)$seg$hookFile"
}

$violations = [System.Collections.Generic.List[string]]::new()
foreach ($reason in $rules.Keys) {
    foreach ($text in $texts) {
        if ($text -match $rules[$reason]) { $violations.Add($reason); break }
    }
}

if ($violations.Count -gt 0) {
    [Console]::Error.WriteLine("❌ [Agent Governance] Command blocked: " + ($violations -join '; ') + ".")
    [Console]::Error.WriteLine("👉 Governance guardrails must not be bypassed. Fix the underlying hook failure, or ask the user to act.")
    exit 2
}

exit 0
