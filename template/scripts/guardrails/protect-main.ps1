# scripts/guardrails/protect-main.ps1
# Deterministic Pre-Commit Branch Policy & Session Ledger Shield

$ErrorActionPreference = 'Stop'

# 1. Hard block: ephemeral session state ledgers never enter version control, on any branch
$stagedWorking = @(git --no-pager diff --cached --name-only --diff-filter=ACMR) | Where-Object { $_ -eq "WORKING.md" -or $_ -match '^\.agents/state/' }
if ($stagedWorking) {
    [Console]::Error.WriteLine("❌ [BLOCK] Ephemeral session ledger '$($stagedWorking -join ', ')' cannot be committed.")
    [Console]::Error.WriteLine("👉 Session continuity ledgers must remain strictly local working memory: git restore --staged <path>")
    exit 1
}

# Empty on a detached HEAD (rebase, bisect, cherry-pick sequences); those commits land on no branch.
$branch = "$(git --no-pager branch --show-current)".Trim()
if (-not $branch) { exit 0 }

# 2. Block direct commits to protected trunk branches
if ($branch -in @('main', 'master')) {
    [Console]::Error.WriteLine("❌ [BLOCK] Direct commits to '$branch' are strictly forbidden.")
    [Console]::Error.WriteLine("👉 Switch to a semantic branch: git checkout -b (feat|fix|patch|hotfix|refactor|chore|test)/<task-slug>")
    exit 1
}

# 3. Hard regex enforcement: branch MUST match semantic taxonomy (nested segments allowed)
$semanticRegex = '^(?i)(feat|fix|patch|hotfix|refactor|chore|test)/[a-z0-9._-]+(/[a-z0-9._-]+)*$'
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

exit 0
