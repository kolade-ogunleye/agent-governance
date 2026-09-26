$branch = (git --no-pager branch --show-current).Trim()

# 1. Block direct commits to protected trunk branches
if ($branch -in @('main', 'master')) {
    [Console]::Error.WriteLine("❌ [BLOCK] Direct commits to '$branch' are strictly forbidden.")
    [Console]::Error.WriteLine("👉 Switch to a semantic branch: git checkout -b (feat|fix|patch|hotfix|refactor|chore|test)/<task-slug>")
    exit 1
}

# 2. Hard regex enforcement: branch MUST match semantic taxonomy
$semanticRegex = '^(?i)(feat|fix|patch|hotfix|refactor|chore|test)/[a-z0-9._-]+$'
if ($branch -notmatch $semanticRegex) {
    [Console]::Error.WriteLine("❌ [BLOCK] Branch '$branch' violates the repository semantic branching policy.")
    [Console]::Error.WriteLine("👉 Allowed prefixes: feat/, fix/, patch/, hotfix/, refactor/, chore/, test/")
    [Console]::Error.WriteLine("👉 Examples:")
    [Console]::Error.WriteLine("   - Bug fix:   git checkout -b fix/issue-slug")
    [Console]::Error.WriteLine("   - Patch:     git checkout -b patch/hotfix-slug")
    [Console]::Error.WriteLine("   - Feature:   git checkout -b feat/feature-slug")
    [Console]::Error.WriteLine("   - Refactor:  git checkout -b refactor/cleanup-slug")
    [Console]::Error.WriteLine("   - Tooling:   git checkout -b chore/config-slug")
    exit 1
}

# 3. Hard block: Never allow ephemeral session state ledgers into protected branches
$stagedWorking = (git --no-pager diff --cached --name-only 2>$null) -split "`r?`n" | Where-Object { $_ -eq "WORKING.md" -or $_ -match '^\.agents/state/' }
if ($stagedWorking) {
    if ($branch -in @('main', 'master')) {
        [Console]::Error.WriteLine("❌ [BLOCK] Ephemeral session ledger '$($stagedWorking -join ', ')' cannot be committed to $branch.")
        [Console]::Error.WriteLine("👉 Session continuity ledgers must remain strictly local working memory.")
        exit 1
    }
}

exit 0
