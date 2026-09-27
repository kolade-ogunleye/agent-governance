# scripts/guardrails/verify-governance.ps1
# Verifies managed governance files against .agent-governance.lock and, with -HubTemplate,
# against the hub template at the locked version. In CI, run the hub's own copy of this script
# against the caller repository: a repo-local copy could itself have been tampered with.
[CmdletBinding()]
param(
    [string]$HubTemplate
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Get-NormalizedHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    # Line-ending normalized so a CRLF checkout does not read as tampering.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-NormalizedText -Path $Path))
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$repoRoot = "$(git rev-parse --show-toplevel 2>$null)".Trim()
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

$lockPath = Join-Path $repoRoot '.agent-governance.lock'
if (-not (Test-Path -LiteralPath $lockPath)) {
    if ($HubTemplate) {
        [Console]::Error.WriteLine('Governance integrity check requires .agent-governance.lock.')
        exit 1
    }
    Write-Host "ℹ️ No .agent-governance.lock found; run Sync-AgentGovernance to create one."
    exit 0
}

$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$problems = [System.Collections.Generic.List[string]]::new()

if ($lock.version -ne 1 -or $lock.files -isnot [pscustomobject] -or @($lock.files.PSObject.Properties).Count -eq 0) {
    [Console]::Error.WriteLine('Invalid governance lock: expected version 1 and a nonempty files object.')
    exit 1
}

# Derive required entries from trusted inputs, never from the caller-controlled lock alone.
$trusted = @{}
$generated = @{}
if ($HubTemplate) {
    if (-not (Test-Path -LiteralPath (Join-Path $HubTemplate 'AGENTS.md') -PathType Leaf)) {
        [Console]::Error.WriteLine('Invalid hub template: AGENTS.md is missing.')
        exit 1
    }
    foreach ($name in @('AGENTS.md', 'lefthook.yml')) {
        $source = Join-Path $HubTemplate $name
        if (Test-Path -LiteralPath $source -PathType Leaf) { $trusted[$name] = $source }
    }
    if ($trusted.ContainsKey('lefthook.yml')) {
        $trusted['.github/copilot-instructions.md'] = Join-Path $HubTemplate 'AGENTS.md'
        $generated['CLAUDE.md'] = '@AGENTS.md'
    }
    foreach ($directory in @('.agents/rules', 'scripts/guardrails')) {
        $sourceDirectory = Join-Path $HubTemplate $directory
        if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -File) {
                $trusted["$directory/$($file.Name)"] = $file.FullName
                if ($directory -eq '.agents/rules') { $trusted[".claude/rules/$($file.Name)"] = $file.FullName }
            }
        }
    }
    foreach ($name in @($trusted.Keys) + @($generated.Keys)) {
        if (-not $lock.files.PSObject.Properties[$name]) { $problems.Add("missing required lock entry: $name") }
    }
}

foreach ($entry in $lock.files.PSObject.Properties) {
    $rel = $entry.Name
    # The lock is repository content, so it is untrusted input: no absolute paths or traversal.
    if ([System.IO.Path]::IsPathRooted($rel) -or $rel -match '(^|[\\/])\.\.([\\/]|$)' -or $rel -match ':' -or [string]::IsNullOrWhiteSpace($rel)) {
        $problems.Add("unsafe path in lock: $rel")
        continue
    }

    $full = Join-Path $repoRoot $rel
    if ([string]$entry.Value -notmatch '^[0-9a-fA-F]{64}$') {
        $problems.Add("invalid hash in lock: $rel")
        continue
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $problems.Add("missing managed file: $rel")
        continue
    }

    if ((Get-NormalizedHash -Path $full) -ne [string]$entry.Value) {
        $problems.Add("modified since last sync (lock mismatch): $rel")
    }

    if ($HubTemplate) {
        if ($generated.ContainsKey($rel) -and (Get-NormalizedText $full).Trim() -cne $generated[$rel]) {
            $problems.Add("differs from the generated tool entry point: $rel")
        }
        $hubFile = $trusted[$rel]
        if ($hubFile) {
            $matchesHub = if ($rel.EndsWith('.md')) {
                # Downstream formatters may reflow markdown; compare whitespace-collapsed text.
                ((Get-NormalizedText $hubFile) -replace '\s+', ' ').Trim() -ceq ((Get-NormalizedText $full) -replace '\s+', ' ').Trim()
            } else {
                (Get-NormalizedHash -Path $hubFile) -eq (Get-NormalizedHash -Path $full)
            }
            if (-not $matchesHub) {
                $problems.Add("differs from the hub template at the locked version: $rel")
            }
        }
    }
}

if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine("❌ [BLOCK] Governance integrity check failed:")
    foreach ($p in $problems) { [Console]::Error.WriteLine("   - $p") }
    [Console]::Error.WriteLine("👉 Re-run Sync-AgentGovernance from the hub instead of editing managed files directly.")
    exit 1
}

Write-Host "✔️ Governance files match the lock$(if ($HubTemplate) { ' and the hub template' })."
exit 0
