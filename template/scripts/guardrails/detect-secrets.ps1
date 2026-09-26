# 1. Pattern check on staged filenames
$stagedFiles = git --no-pager diff --cached --name-only
$sensitivePatterns = @('\.env', 'id_rsa', 'id_ed25519', '\.pem$', '\.key$', 'credential')
foreach ($pattern in $sensitivePatterns) {
    $matched = $stagedFiles | Where-Object { $_ -match $pattern }
    if ($matched) {
        [Console]::Error.WriteLine("❌ [BLOCK] Sensitive or secret file pattern detected in staged files: " + ($matched -join ', '))
        exit 1
    }
}

# 2. Deep content scan via Gitleaks
if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    gitleaks protect --staged --no-banner
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

exit 0
