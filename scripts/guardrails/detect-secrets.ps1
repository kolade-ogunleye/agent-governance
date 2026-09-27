# scripts/guardrails/detect-secrets.ps1
# Deterministic Pre-Commit Secret Gate (fail-closed)

$ErrorActionPreference = 'Stop'

# Added, copied, modified, or renamed paths only; deleting a committed secret must stay possible.
$stagedFiles = @(git --no-pager diff --cached --name-only --diff-filter=ACMR) | Where-Object { $_ }
if ($stagedFiles.Count -eq 0) { exit 0 }

# 1. Sensitive file names (matched against the file name, mirroring the canonical .gitignore shield)
$allowedTemplates = @('.env.example', '.env.sample', '.env.template')
$sensitiveNamePatterns = @(
    '^\.env(\..+)?$',
    '\.(pem|key|p12|pfx|keystore|jks)$',
    '^id_(rsa|dsa|ecdsa|ed25519)$',
    '^credentials(\.[A-Za-z0-9]+)?$'
)

$blocked = foreach ($path in $stagedFiles) {
    $name = [System.IO.Path]::GetFileName($path)
    if ($name -in $allowedTemplates) { continue }
    foreach ($pattern in $sensitiveNamePatterns) {
        if ($name -match $pattern) { $path; break }
    }
}

if ($blocked) {
    [Console]::Error.WriteLine("❌ [BLOCK] Sensitive or secret file pattern detected in staged files: " + ($blocked -join ', '))
    exit 1
}

# 2. Deep content scan via Gitleaks (mandatory: an unavailable scanner is a failed scan)
if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("❌ [BLOCK] gitleaks is not installed, so staged content cannot be scanned for secrets.")
    [Console]::Error.WriteLine("👉 Install: winget install Gitleaks.Gitleaks (Windows) or brew install gitleaks (macOS/Linux)")
    exit 1
}

& gitleaks git --staged --no-banner --redact
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("❌ [BLOCK] Gitleaks detected potential secrets in staged changes (exit $LASTEXITCODE).")
    exit 1
}

exit 0
