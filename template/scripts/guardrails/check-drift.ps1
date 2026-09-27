# check-drift.ps1 - Automated Hub Drift Detection (RFC 2119 Non-blocking)
# Checks if local repository governance files are in sync with Central Hub.

$ErrorActionPreference = 'Stop'

try {
    # AGENT_GOVERNANCE_HUB overrides the default hub location; $HOME is cross-platform (USERPROFILE is Windows-only).
    $hubDir = if ($env:AGENT_GOVERNANCE_HUB) { $env:AGENT_GOVERNANCE_HUB } else { Join-Path $HOME ".agent-governance" "template" }
    if (-not (Test-Path $hubDir)) {
        # Central Hub not present on this machine (e.g., CI/CD or foreign workstation); skip silently.
        exit 0
    }

    $repoRoot = "$(git rev-parse --show-toplevel 2>$null)".Trim()
    if (-not $repoRoot) { exit 0 }

    $criticalFiles = @(
        "AGENTS.md",
        "lefthook.yml",
        ".agents/rules/languages.md",
        ".agents/rules/security-performance.md",
        "scripts/guardrails/agent-bash-guard.ps1",
        "scripts/guardrails/check-drift.ps1",
        "scripts/guardrails/check-markdown.ps1",
        "scripts/guardrails/protect-main.ps1",
        "scripts/guardrails/detect-secrets.ps1",
        "scripts/guardrails/guard-tests.ps1",
        "scripts/guardrails/audit-dependencies.ps1",
        "scripts/guardrails/run-tests.ps1"
    )

    $hasDrift = $false

    foreach ($relPath in $criticalFiles) {
        $hubFile = Join-Path $hubDir $relPath
        $repoFile = Join-Path $repoRoot $relPath

        if ((Test-Path $hubFile) -and (Test-Path $repoFile)) {
            $hubRaw = Get-Content -Path $hubFile -Raw
            $repoRaw = Get-Content -Path $repoFile -Raw

            if ($hubRaw -eq $repoRaw) {
                continue
            }

            # For markdown files, compare semantic content ignoring downstream formatting whitespace
            if ($relPath.EndsWith(".md")) {
                $hubNorm = ($hubRaw -replace '\s+', ' ').Trim()
                $repoNorm = ($repoRaw -replace '\s+', ' ').Trim()
                if ($hubNorm -eq $repoNorm) {
                    continue
                }
            }

            $hasDrift = $true
            break
        }
    }

    if ($hasDrift) {
        Write-Host "`n⚡ [Agent Governance] Local repository rules have drifted from the Central Hub." -ForegroundColor Yellow
        Write-Host "   Run 'Sync-AgentGovernance' to synchronize with latest corporate standards.`n" -ForegroundColor DarkGray
    }
} catch {
    # Drift detection is advisory: an unexpected error must never block a commit.
    [Console]::Error.WriteLine("⚠️ [Agent Governance] Drift check skipped: $($_.Exception.Message)")
}

exit 0
