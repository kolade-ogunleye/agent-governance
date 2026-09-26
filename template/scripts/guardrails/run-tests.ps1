# scripts/guardrails/run-tests.ps1
# Deterministic Pre-Push Test Runner

if (Test-Path "package.json") {
    Write-Host "🧪 Running Node.js test suite..."
    if (Test-Path "pnpm-lock.yaml") {
        & pnpm test
    } elseif (Test-Path "yarn.lock") {
        & yarn test
    } else {
        & npm test
    }
    exit $LASTEXITCODE
}

if ((Test-Path "pyproject.toml") -or (Test-Path "pytest.ini")) {
    Write-Host "🧪 Running Python test suite..."
    if (Test-Path "uv.lock") {
        & uv run pytest
    } else {
        & pytest
    }
    exit $LASTEXITCODE
}

if (Test-Path "Cargo.toml") {
    Write-Host "🧪 Running Rust test suite..."
    & cargo test
    exit $LASTEXITCODE
}

# No testable manifest present yet
exit 0
