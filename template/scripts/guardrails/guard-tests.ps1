$deleted = git --no-pager diff --cached --diff-filter=D --name-only | Where-Object { $_ -match '(test|spec)' }
if ($deleted) {
    [Console]::Error.WriteLine("❌ [BLOCK] Deletion of test files is strictly forbidden: " + ($deleted -join ', '))
    exit 1
}
exit 0
