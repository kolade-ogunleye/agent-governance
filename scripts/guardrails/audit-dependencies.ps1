# scripts/guardrails/audit-dependencies.ps1
# Deterministic Pre-Push Supply Chain Vulnerability Auditor

$ErrorActionPreference = 'Stop'
$vulnerabilitiesFound = $false

function Write-AuditSkip {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("⚠️ [Audit SKIPPED] $Message")
}

# 1. Node.js Manifest Audit
if (Test-Path "package.json") {
    if (Test-Path "pnpm-lock.yaml") {
        Write-Host "🔍 Auditing Node.js dependencies via pnpm..."
        & pnpm audit --audit-level=high
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } elseif (Test-Path "package-lock.json") {
        Write-Host "🔍 Auditing Node.js dependencies via npm..."
        & npm audit --audit-level=high
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } elseif (Test-Path "yarn.lock") {
        if (Test-Path ".yarnrc.yml") {
            # Yarn Berry (2+): non-zero exit when advisories at or above --severity are reported.
            Write-Host "🔍 Auditing Node.js dependencies via yarn npm audit..."
            & yarn npm audit --all --recursive --severity high
            if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
        } else {
            # Yarn classic: --level only filters output; the exit code is a severity bitmask
            # (1 info, 2 low, 4 moderate, 8 high, 16 critical), so block on the high/critical bits.
            Write-Host "🔍 Auditing Node.js dependencies via yarn audit..."
            & yarn audit --level high
            if (($LASTEXITCODE -band 24) -ne 0) { $vulnerabilitiesFound = $true }
        }
    }
}

# 1b. Go Module Audit
if (Test-Path "go.mod") {
    if (Get-Command "govulncheck" -ErrorAction SilentlyContinue) {
        Write-Host "🔍 Auditing Go dependencies via govulncheck..."
        & govulncheck ./...
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } else {
        Write-AuditSkip "go.mod detected but govulncheck is not installed."
    }
}

# 1c. PHP Composer Audit (lock file, high and critical only; abandoned packages are reported, not blocking)
if (Test-Path "composer.lock") {
    if (Get-Command "composer" -ErrorAction SilentlyContinue) {
        Write-Host "🔍 Auditing PHP dependencies via composer audit..."
        & composer audit --locked --ignore-severity low --ignore-severity medium --abandoned=report
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } else {
        Write-AuditSkip "composer.lock detected but composer is not installed."
    }
}

# 2. Python Manifest Audit — always against the project's own dependencies, never the auditor's environment
$hasPyproject = Test-Path "pyproject.toml"
$hasRequirements = Test-Path "requirements.txt"
if ($hasPyproject -or $hasRequirements) {
    # Re-wrapped because an if-expression unrolls a one-element array into a bare string.
    $pipAudit = @(
        if (Get-Command "pip-audit" -ErrorAction SilentlyContinue) { "pip-audit" }
        elseif (Get-Command "uvx" -ErrorAction SilentlyContinue) { "uvx", "pip-audit" }
    )

    if ($pipAudit.Count -eq 0) {
        Write-AuditSkip "Python manifest detected but neither pip-audit nor uvx is installed."
    } else {
        $auditExe = $pipAudit[0]
        $auditPrefix = @($pipAudit | Select-Object -Skip 1)
        $exportPath = $null
        try {
            if ((Test-Path "uv.lock") -and (Get-Command "uv" -ErrorAction SilentlyContinue)) {
                # Fully pinned lock export: no resolution needed, so pip is not invoked at all.
                $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("uv-export-" + [guid]::NewGuid().ToString('N') + ".txt")
                Write-Host "🔍 Auditing locked Python dependencies (uv.lock) via pip-audit..."
                & uv export --format requirements.txt --frozen --no-emit-project -o $exportPath
                if ($LASTEXITCODE -ne 0) { throw "uv export failed (exit $LASTEXITCODE)" }
                & $auditExe @auditPrefix -r $exportPath --no-deps --disable-pip
            } elseif ($hasRequirements) {
                Write-Host "🔍 Auditing Python requirements.txt via pip-audit..."
                & $auditExe @auditPrefix -r requirements.txt
            } else {
                Write-Host "🔍 Auditing local Python project via pip-audit..."
                & $auditExe @auditPrefix .
            }
            if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
        } finally {
            if ($exportPath -and (Test-Path $exportPath)) { Remove-Item -LiteralPath $exportPath -Force }
        }
    }
}

# 3. Rust Manifest Audit
if (Test-Path "Cargo.lock") {
    if (Get-Command "cargo-audit" -ErrorAction SilentlyContinue) {
        Write-Host "🔍 Auditing Rust dependencies via cargo audit..."
        & cargo audit
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } else {
        Write-AuditSkip "Cargo.lock detected but cargo-audit is not installed."
    }
}

if ($vulnerabilitiesFound) {
    [Console]::Error.WriteLine("❌ [BLOCK] High or critical vulnerabilities detected in project dependencies!")
    [Console]::Error.WriteLine("👉 Resolve security advisories or update vulnerable packages before pushing.")
    exit 1
}

Write-Host "✔️ Supply-chain security audit completed."
exit 0
