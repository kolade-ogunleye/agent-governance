# scripts/guardrails/audit-dependencies.ps1
# Deterministic Pre-Push Supply Chain Vulnerability Auditor

$ErrorActionPreference = 'Stop'
$vulnerabilitiesFound = $false

# 1. Node.js Manifest Audit
if (Test-Path "package.json") {
    Write-Host "🔍 Auditing Node.js dependencies..."
    if (Test-Path "pnpm-lock.yaml") {
        & pnpm audit --audit-level=high
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } elseif (Test-Path "package-lock.json") {
        & npm audit --audit-level=high
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    }
}

# 2. Python Manifest Audit
if ((Test-Path "pyproject.toml") -or (Test-Path "requirements.txt")) {
    if (Get-Command "pip-audit" -ErrorAction SilentlyContinue) {
        Write-Host "🔍 Auditing Python dependencies via pip-audit..."
        & pip-audit
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } elseif (Get-Command "uvx" -ErrorAction SilentlyContinue) {
        Write-Host "🔍 Auditing Python dependencies via uvx pip-audit..."
        & uvx pip-audit
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    }
}

# 3. Rust Manifest Audit
if (Test-Path "Cargo.lock") {
    if (Get-Command "cargo-audit" -ErrorAction SilentlyContinue) {
        Write-Host "🔍 Auditing Rust dependencies via cargo audit..."
        & cargo audit
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    }
}

if ($vulnerabilitiesFound) {
    [Console]::Error.WriteLine("❌ [BLOCK] High or critical vulnerabilities detected in project dependencies!")
    [Console]::Error.WriteLine("👉 Resolve security advisories or update vulnerable packages before pushing.")
    exit 1
}

Write-Host "✔️ Supply-chain security audit passed (0 vulnerabilities)."
exit 0
