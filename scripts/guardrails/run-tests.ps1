# scripts/guardrails/run-tests.ps1
# Deterministic Pre-Push Test Runner (every detected stack runs; any failure blocks)

$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-Suite {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    Write-Host "🧪 Running $Label test suite..."
    try {
        & $Command
        if ($LASTEXITCODE -ne 0) { $failures.Add("$Label (exit $LASTEXITCODE)") }
    } catch {
        $failures.Add("$Label ($($_.Exception.Message))")
    }
}

# 1. Node.js (only when a test script is declared)
if (Test-Path "package.json") {
    $pkg = Get-Content "package.json" -Raw | ConvertFrom-Json
    if ($pkg.scripts -and $pkg.scripts.PSObject.Properties['test']) {
        if (Test-Path "pnpm-lock.yaml") {
            Invoke-Suite -Label "Node.js (pnpm)" -Command { & pnpm test }
        } elseif (Test-Path "yarn.lock") {
            Invoke-Suite -Label "Node.js (yarn)" -Command { & yarn test }
        } else {
            Invoke-Suite -Label "Node.js (npm)" -Command { & npm test }
        }
    }
}

# 2. Python
if ((Test-Path "pyproject.toml") -or (Test-Path "pytest.ini")) {
    if (Test-Path "uv.lock") {
        Invoke-Suite -Label "Python (uv)" -Command { & uv run pytest }
    } else {
        Invoke-Suite -Label "Python" -Command { & pytest }
    }
}

# 3. Rust
if (Test-Path "Cargo.toml") {
    Invoke-Suite -Label "Rust" -Command { & cargo test }
}

# 4. Go
if (Test-Path "go.mod") {
    Invoke-Suite -Label "Go" -Command { & go test ./... }
}

# 5. PowerShell (Pester)
if ((Test-Path "tests") -and (Get-ChildItem -Path "tests" -Filter "*.Tests.ps1" -Recurse -File | Select-Object -First 1)) {
    Invoke-Suite -Label "PowerShell (Pester)" -Command { & pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -CI" }
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("❌ [BLOCK] Test suites failed: " + ($failures -join '; '))
    exit 1
}

exit 0
