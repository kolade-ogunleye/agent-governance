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
    # echo arguments) and is blanked so flags merely mentioned in it are not counted, unless it embeds a command
    # substitution: "$(git rev-parse --git-dir)/hooks/x" is a path, and its inner command runs.
    $unquote = { param($m) $inner = $m.Groups[1].Value; if ($inner -match '^[^\s;&|]*$' -or $inner -match '\$\(|`') { $inner } else { '""' } }
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

# Hook scripts live in .git/hooks or in the directory core.hooksPath names (.githooks, .husky, ...), which the
# sync engine chains the governance gate into. A write, deletion, mode change or directory change there
# disables the gate without any flag, so those are matched at directory level.
$hookDirs = [System.Collections.Generic.List[string]]::new()
$hookDirs.Add('(?:\.git|--git-dir\)?)[\\/]hooks')
$hookDirs.Add('--git-path\s+hooks')
$hookDirs.Add('\.githooks')
$hookDirs.Add('\.husky')
try {
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $configured = "$(& git config --get core.hooksPath 2>$null)".Trim()
        if ($LASTEXITCODE -eq 0 -and $configured) { $hookDirs.Add([regex]::Escape($configured.TrimEnd('/', '\'))) }
    }
} catch {
    # The default hook directories stay guarded; a failed lookup must never disable the check.
    $configured = $null
}
$hookDir = '(?:' + ($hookDirs -join '|') + ')(?=[\\/\s;&|)]|$)'
# Commands that create, replace, remove or re-mode files, and directory changes (a later relative write would
# name no hook path). PowerShell cmdlets and their aliases included.
$writers = 'rm|rmdir|unlink|mv|cp|tee|chmod|chattr|ln|install|truncate|dd|cd|pushd|sed\s+-i\S*|' +
    'Remove-Item|Move-Item|Copy-Item|Rename-Item|Set-Content|Add-Content|Clear-Content|Out-File|New-Item|Set-Location|Push-Location|' +
    'ri|del|erase|rd|mi|move|cpi|copy|rni|ren|sc|ac|clc|ni|sl|chdir'

$rules = [ordered]@{
    # Git accepts any unambiguous abbreviation of a long option, so --no-verif (and longer) is --no-verify.
    'git --no-verify skips the governance hooks'                             = "\bgit\b$seg\s--no-verif\w*"
    # Only git commit's argument-less short flags can precede -n in a cluster; -m<msg> glues a value (-mnew is a message).
    'git commit -n skips the governance hooks'                               = "\bgit\b$seg\bcommit\b$seg\s-[apzseiovq]*n[A-Za-z]*\b"
    'a shell variable holding a hook-bypass flag hides it from review'       = '(?:^|[\s;&|(])\$?\w+\s*=\s*["'']?--no-verif'
    'LEFTHOOK=0 / LEFTHOOK_EXCLUDE disables the governance hooks'            = '\bLEFTHOOK(_EXCLUDE)?\s*=|\benv:LEFTHOOK'
    'lefthook install/uninstall replaces the fail-closed governance gate'    = '\blefthook\s+(install|uninstall)\b'
    'overriding core.hooksPath redirects git away from governance hooks'     = "\bcore\.hooksPath\s*=|\bgit\b$seg\bconfig\b$seg\bcore\.hooksPath\s+[^\s;&|]|\bgit\b$seg\bconfig\b$seg\b(?:--)?unset(?:-all)?\s+core\.hooksPath"
    # GIT_CONFIG_COUNT/KEY_n/VALUE_n, GIT_CONFIG_PARAMETERS, GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM inject
    # configuration (core.hooksPath included) without a visible -c.
    'GIT_CONFIG_* environment overrides redirect git configuration'          = '\bGIT_CONFIG_(?:COUNT|KEY_\d+|VALUE_\d+|PARAMETERS|GLOBAL|SYSTEM)\s*=|\benv:GIT_CONFIG_'
    'pushing directly to main/master bypasses review'                        = "\bgit\b$seg\bpush\b$seg(?:\s\+?|:|refs/heads/)(?:main|master)(?=$|[\s;&|:])"
    'writing to the git hooks directory disables the governance gate'        = "(?:>>?|\b(?:$writers)\b)$seg$hookDir"
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
