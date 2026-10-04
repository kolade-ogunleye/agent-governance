# scripts/guardrails/audit-dependencies.ps1
# Deterministic Pre-Push Supply Chain Vulnerability Auditor

$ErrorActionPreference = 'Stop'
$vulnerabilitiesFound = $false

function Write-AuditSkip {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("⚠️ [Audit SKIPPED] $Message")
}

# Reviewed, expiring exceptions for advisories that have no fixed release yet (.audit-exceptions.json, owned and
# committed by the repository): { "exceptions": [ { "id": "GHSA-xxxx-xxxx-xxxx", "reason": "...", "expires":
# "YYYY-MM-DD" } ] }. Each entry suppresses only that advisory, only until it expires, and at most 90 days ahead.
# A malformed file or entry, or an expired one, blocks the push. Supported for npm (package-lock.json).
$exceptionFile = '.audit-exceptions.json'
$maxExceptionDays = 90
$exceptions = @{}
$hasExceptionFile = Test-Path -LiteralPath $exceptionFile
if ($hasExceptionFile) {
    $exceptionErrors = [System.Collections.Generic.List[string]]::new()
    try {
        $exceptionDoc = Get-Content -LiteralPath $exceptionFile -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $exceptionDoc = $null
        $exceptionErrors.Add("not valid JSON: $($_.Exception.Message)")
    }
    $today = [datetime]::UtcNow.Date
    foreach ($entry in @($exceptionDoc.exceptions | Where-Object { $null -ne $_ })) {
        $id = "$($entry.id)".Trim()
        $expiry = [datetime]::MinValue
        if ($id -notmatch '^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$') { $exceptionErrors.Add("'$id' is not a GitHub advisory id (GHSA-xxxx-xxxx-xxxx)"); continue }
        if (-not "$($entry.reason)".Trim()) { $exceptionErrors.Add("$id has no reason"); continue }
        if (-not [datetime]::TryParseExact("$($entry.expires)", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$expiry)) {
            $exceptionErrors.Add("$id has no expires date in YYYY-MM-DD form"); continue
        }
        if ($expiry -lt $today) { $exceptionErrors.Add("$id expired on $($entry.expires): update the package or renew the exception after review"); continue }
        if ($expiry -gt $today.AddDays($maxExceptionDays)) { $exceptionErrors.Add("$id expires more than $maxExceptionDays days ahead ($($entry.expires))"); continue }
        $exceptions[$id.ToLowerInvariant()] = $entry
    }
    if ($null -ne $exceptionDoc -and @($exceptionDoc.exceptions).Count -eq 0) { $exceptionErrors.Add('no "exceptions" entries') }
    foreach ($problem in $exceptionErrors) { [Console]::Error.WriteLine("❌ [Audit] ${exceptionFile}: $problem") }
    if ($exceptionErrors.Count -gt 0) { $vulnerabilitiesFound = $true }
}

function Test-NpmAuditWithException {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][hashtable]$Exception
    )
    # True when every high or critical advisory npm reports is covered by a current exception. Advisories are the
    # object entries in each package's "via"; string entries name the vulnerable dependency they come through.
    try {
        if (-not $Json.Trim()) { throw 'empty output' }
        $report = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("❌ [Audit] npm audit returned no readable report (exit $ExitCode).")
        return $false
    }
    if ($report.error) {
        [Console]::Error.WriteLine("❌ [Audit] npm audit failed: $($report.error.summary)")
        return $false
    }
    $blocking = [System.Collections.Generic.List[string]]::new()
    $suppressed = [System.Collections.Generic.List[string]]::new()
    if ($report.vulnerabilities) {
        foreach ($package in $report.vulnerabilities.PSObject.Properties) {
            foreach ($via in @($package.Value.via)) {
                if ($via -is [string] -or "$($via.severity)" -notin @('high', 'critical')) { continue }
                $ghsa = if ("$($via.url)" -match '(GHSA(?:-[a-z0-9]{4}){3})') { $Matches[1].ToLowerInvariant() } else { '' }
                $label = "$($via.name) ($($via.severity)) $($via.url)"
                if ($ghsa -and $Exception.ContainsKey($ghsa)) { $suppressed.Add("$label, excepted until $($Exception[$ghsa].expires)") } else { $blocking.Add($label) }
            }
        }
    }
    foreach ($item in ($suppressed | Sort-Object -Unique)) { [Console]::Error.WriteLine("⚠️ [Audit EXCEPTION] $item") }
    foreach ($item in ($blocking | Sort-Object -Unique)) { [Console]::Error.WriteLine("❌ [Audit] $item") }
    # npm exits non-zero at --audit-level=high only for high or critical findings; one this parser could not
    # attribute to an advisory blocks rather than passing unexamined.
    if ($blocking.Count -gt 0) { return $false }
    if ($ExitCode -ne 0 -and $suppressed.Count -eq 0) {
        [Console]::Error.WriteLine("❌ [Audit] npm audit failed (exit $ExitCode) without a high or critical advisory this hook could read.")
        return $false
    }
    return $true
}

# 1. Node.js Manifest Audit
if (Test-Path "package.json") {
    if (Test-Path "pnpm-lock.yaml") {
        Write-Host "🔍 Auditing Node.js dependencies via pnpm..."
        if ($hasExceptionFile) { Write-AuditSkip "$exceptionFile applies to npm only; pnpm advisories are not excepted." }
        & pnpm audit --audit-level=high
        if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
    } elseif (Test-Path "package-lock.json") {
        Write-Host "🔍 Auditing Node.js dependencies via npm..."
        if ($exceptions.Count -gt 0) {
            $npmJson = (& npm audit --json --audit-level=high 2>$null) -join "`n"
            $npmExit = $LASTEXITCODE
            if (-not (Test-NpmAuditWithException -Json $npmJson -ExitCode $npmExit -Exception $exceptions)) { $vulnerabilitiesFound = $true }
        } else {
            & npm audit --audit-level=high
            if ($LASTEXITCODE -ne 0) { $vulnerabilitiesFound = $true }
        }
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
    [Console]::Error.WriteLine("👉 Resolve security advisories or update vulnerable packages before pushing. An advisory with no fixed release can be excepted, after review and until a date at most $maxExceptionDays days ahead, in $exceptionFile (npm).")
    exit 1
}

Write-Host "✔️ Supply-chain security audit completed."
exit 0
