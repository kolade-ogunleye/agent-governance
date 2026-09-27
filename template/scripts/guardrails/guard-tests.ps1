# scripts/guardrails/guard-tests.ps1
# Deterministic Pre-Commit Test Anti-Tampering Guard

$ErrorActionPreference = 'Stop'

# Test files by ecosystem convention, matched on the repo-relative path (forward slashes).
$testPathPatterns = @(
    '(^|/)(tests?|__tests__|specs?)/',
    '\.(test|spec)\.[^/]+$',
    '(^|/)test_[^/]+\.py$',
    '_test\.(py|go)$',
    '\.Tests\.ps1$',
    # Case-sensitive so 'Contest.java' is not a test; '-match' is otherwise case-insensitive.
    '(?-i)(^|/)[^/]+Tests?\.(java|kt|cs)$'
)
function Test-IsTestPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($pattern in $testPathPatterns) {
        if ($Path -match $pattern) { return $true }
    }
    return $false
}

# Markers that disable an existing test: JS/TS, pytest/unittest, Go, Rust, Pester.
# Anchored at statement start so markers quoted inside string data are not counted.
$skipMarkerPattern = '^\s*((it|test|describe)\.skip\s*\(|x(it|test|describe)\s*\(|@pytest\.mark\.skip|@unittest\.skip|t\.Skip(Now)?\s*\(|#\[ignore\]|It\s.*\s-Skip\b)'

$violations = [System.Collections.Generic.List[string]]::new()

# 1. Deleted tests, and tests renamed to a non-test path (rename detection enabled explicitly)
foreach ($entry in @(git --no-pager diff --cached --name-status -M --diff-filter=DR)) {
    if (-not $entry) { continue }
    $fields = $entry -split "`t"
    if ($fields[0] -eq 'D' -and (Test-IsTestPath $fields[1])) {
        $violations.Add("deleted test file: $($fields[1])")
    } elseif ($fields[0] -like 'R*' -and (Test-IsTestPath $fields[1]) -and -not (Test-IsTestPath $fields[2])) {
        $violations.Add("test file moved out of the test suite: $($fields[1]) -> $($fields[2])")
    }
}

# 2. Skip markers newly added to existing (modified) test files; new test files may start skipped.
foreach ($path in @(git --no-pager diff --cached --name-only --diff-filter=M)) {
    if (-not $path -or -not (Test-IsTestPath $path)) { continue }
    $added = 0
    $removed = 0
    foreach ($line in @(git --no-pager diff --cached -U0 -- $path)) {
        if ($line.StartsWith('+++') -or $line.StartsWith('---')) { continue }
        if ($line.StartsWith('+') -and $line.Substring(1) -match $skipMarkerPattern) { $added++ }
        elseif ($line.StartsWith('-') -and $line.Substring(1) -match $skipMarkerPattern) { $removed++ }
    }
    if ($added -gt $removed) {
        $violations.Add("skip marker added to existing test: $path")
    }
}

if ($violations.Count -gt 0) {
    [Console]::Error.WriteLine("❌ [BLOCK] Test anti-tampering policy violated:")
    foreach ($v in $violations) { [Console]::Error.WriteLine("   - $v") }
    [Console]::Error.WriteLine("👉 Validate changes by adding new tests; do not delete, relocate out of the suite, or skip existing ones.")
    exit 1
}

exit 0
