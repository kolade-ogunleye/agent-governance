<#
.SYNOPSIS
    Sync-AgentGovernance - Enterprise Multi-Agent Governance Distribution Engine
.DESCRIPTION
    Idempotently deploys and updates canonical multi-agent governance, deterministic
    guardrails (Lefthook + Gitleaks), automated drift detection, and Progressive Disclosure rules.
    Intelligently reconciles existing hooks (.githooks, .husky, core.hooksPath), auto-detects
    polyglot tech stacks, preserves legacy agent instructions non-destructively, provides
    actionable fallback warnings with an agent hard-gate, and supports automated fleet-wide
    safe branching and committing.
.PARAMETER Action
    Optional positional command: 'sync' (default), 'audit', 'status', or 'help'.
.PARAMETER RepoPath
    The target repository path to initialize or update. Defaults to current directory.
.PARAMETER All
    If specified, scans and safely audits/updates all git repositories in C:\Users\omokolade\GitHub.
.PARAMETER AuditOnly
    Inspects and reports status without making any file changes.
.PARAMETER BranchAndCommit
    Automatically checks out a chore/agent-governance branch and commits governance baselines across clean repositories.
.PARAMETER Help
    Displays the formatted CLI reference manual.
.EXAMPLE
    Sync-AgentGovernance
    Syncs current repository with Central Governance Hub.
.EXAMPLE
    Sync-AgentGovernance -All -AuditOnly
    Audits all repositories in C:\Users\omokolade\GitHub.
.EXAMPLE
    Sync-AgentGovernance audit -a
    Short subcommand syntax for fleet-wide audit.
.EXAMPLE
    Sync-AgentGovernance -h
    Displays detailed help and CLI reference.
#>
function Sync-AgentGovernance {
    [CmdletBinding(DefaultParameterSetName = 'Standard')]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('sync', 'audit', 'status', 'help', '')]
        [string]$Action = 'sync',

        [Parameter()]
        [Alias('r', 'Path')]
        [string]$RepoPath = (Get-Location).Path,

        [Parameter()]
        [Alias('a')]
        [switch]$All,

        [Parameter()]
        [Alias('m')]
        [switch]$AuditOnly,

        [Parameter()]
        [Alias('c')]
        [switch]$BranchAndCommit,

        [Parameter()]
        [Alias('h', '?')]
        [switch]$Help
    )

    function Show-HelpManual {
        Write-Host @"

══════════════════════════════════════════════════════════════════════════════
 🛡️  AGENT GOVERNANCE DISTRIBUTION ENGINE (CLI REFERENCE)
══════════════════════════════════════════════════════════════════════════════

SYNOPSIS:
    Sync-AgentGovernance [[-Action] <sync|audit|status|help>]
                         [-RepoPath|-r <path>]
                         [-All|-a]
                         [-AuditOnly|-m]
                         [-BranchAndCommit|-c]
                         [-Help|-h|-?]

SUBCOMMANDS:
    sync                 Idempotently synchronizes governance, hooks, and rules. (Default)
    audit                Audits repository governance status without writing any files.
    status               Displays Central Hub health, active templates, and version info.
    help                 Displays this comprehensive manual.

PARAMETERS:
    -RepoPath, -r <path> Target repository path. Defaults to current working directory.
    -All, -a             Scans and operates across ALL git repos in C:\Users\omokolade\GitHub.
    -AuditOnly, -m       Inspects and reports status without making changes.
    -BranchAndCommit, -c Safely branches to chore/agent-governance and auto-commits
                         governance baselines on clean repositories.
    -Help, -h, -?        Displays this command-line reference.

EXAMPLES:
    # 1. Sync current repository:
    Sync-AgentGovernance

    # 2. Display short help:
    Sync-AgentGovernance -h

    # 3. Fleet-wide audit (short & long forms):
    Sync-AgentGovernance audit -a
    Sync-AgentGovernance -All -AuditOnly

    # 4. Synchronize specific repository with auto-branching:
    Sync-AgentGovernance -r "C:\Users\omokolade\GitHub\content-estate" -c

    # 5. Check central hub status:
    Sync-AgentGovernance status

══════════════════════════════════════════════════════════════════════════════
"@ -ForegroundColor Cyan
    }

    if ($Help -or ($Action -eq 'help')) {
        Show-HelpManual
        return
    }

    if ($Action -eq 'audit') {
        $AuditOnly = $true
    }

    # Locate Central Hub (Prioritize development repo, then user home junction)
    $hubCandidates = @(
        "C:\Users\omokolade\GitHub\agent-governance\template",
        (Join-Path $env:USERPROFILE ".agent-governance\template")
    )
    $hubDir = $null
    foreach ($candidate in $hubCandidates) {
        if (Test-Path $candidate) {
            $hubDir = $candidate
            break
        }
    }

    if (-not $hubDir) {
        Write-Error "Central governance template directory not found in: $($hubCandidates -join ', ')"
        return
    }

    if ($Action -eq 'status') {
        Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "🛡️  Central Governance Hub Status" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "Hub Location:   $hubDir" -ForegroundColor White
        Write-Host "Engine Script:  $PSCommandPath" -ForegroundColor White
        Write-Host "Lefthook Tool:  $(if (Get-Command lefthook -ErrorAction SilentlyContinue) { (Get-Command lefthook).Source } else { 'Not installed' })" -ForegroundColor Yellow
        Write-Host "Gitleaks Tool:  $(if (Get-Command gitleaks -ErrorAction SilentlyContinue) { (Get-Command gitleaks).Source } else { 'Not installed' })" -ForegroundColor Yellow

        $rules = Get-ChildItem -Path (Join-Path $hubDir ".agents\rules") -File -ErrorAction SilentlyContinue
        Write-Host "`nActive Rules ($($rules.Count)): " -ForegroundColor DarkGray
        foreach ($r in $rules) { Write-Host "  • $($r.Name)" -ForegroundColor DarkGray }

        $guards = Get-ChildItem -Path (Join-Path $hubDir "scripts\guardrails") -File -ErrorAction SilentlyContinue
        Write-Host "Active Guardrails ($($guards.Count)): " -ForegroundColor DarkGray
        foreach ($g in $guards) { Write-Host "  • $($g.Name)" -ForegroundColor DarkGray }
        Write-Host ""
        return
    }

    function Detect-ProjectStack {
        param([string]$targetDir, [string]$repoName)

        $types = [System.Collections.Generic.List[string]]::new()
        $frameworks = [System.Collections.Generic.List[string]]::new()
        $packageManagers = [System.Collections.Generic.List[string]]::new()
        $runbook = [ordered]@{}

        # 1. WordPress / PHP
        if ((Test-Path (Join-Path $targetDir "composer.json")) -or (Test-Path (Join-Path $targetDir "wp-content"))) {
            $types.Add("WordPress / PHP")
            $frameworks.Add("WordPress")
            $packageManagers.Add("composer")
            $runbook["PHP Lint"] = "vendor/bin/phpcs (or php -l on staged files)"
            if (Test-Path (Join-Path $targetDir "phpstan.neon.dist")) {
                $runbook["PHP Static Analysis"] = "vendor/bin/phpstan analyse"
            }
        }

        # 2. Node.js / JavaScript / TypeScript
        $pkgPath = Join-Path $targetDir "package.json"
        if (Test-Path $pkgPath) {
            $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($pkg) {
                $pm = "npm"
                if (Test-Path (Join-Path $targetDir "pnpm-lock.yaml")) {
                    $pm = "pnpm"
                    $types.Add("Node.js / Web (pnpm)")
                    $packageManagers.Add("pnpm")
                } elseif (Test-Path (Join-Path $targetDir "yarn.lock")) {
                    $pm = "yarn"
                    $types.Add("Node.js / Web (yarn)")
                    $packageManagers.Add("yarn")
                } else {
                    $types.Add("Node.js / Web (npm)")
                    $packageManagers.Add("npm")
                }

                if ($pkg.scripts) {
                    if ($pkg.scripts.PSObject.Properties['dev']) { $runbook["Dev Server"] = "$pm run dev" }
                    if ($pkg.scripts.PSObject.Properties['build']) { $runbook["Build"] = "$pm run build" }
                    if ($pkg.scripts.PSObject.Properties['build:theme-assets']) { $runbook["Build Theme Assets"] = "$pm run build:theme-assets" }
                    if ($pkg.scripts.PSObject.Properties['lint']) { $runbook["Node Lint"] = "$pm run lint" }
                    if ($pkg.scripts.PSObject.Properties['test']) { $runbook["Node Tests"] = "$pm test" }
                    if ($pkg.scripts.PSObject.Properties['test:contracts']) { $runbook["Contract Tests"] = "$pm run test:contracts" }
                }
            }
        }

        # 3. Python
        if ((Test-Path (Join-Path $targetDir "pyproject.toml")) -or (Test-Path (Join-Path $targetDir "requirements.txt")) -or (Test-Path (Join-Path $targetDir "requirements-dev.txt"))) {
            $pyEnv = if (Test-Path (Join-Path $targetDir "uv.lock")) { "uv" } else { "pip" }
            $types.Add("Python ($pyEnv)")
            $packageManagers.Add($pyEnv)
            $runbook["Python Tests"] = if ($pyEnv -eq "uv") { "uv run pytest" } else { "pytest" }
            $runbook["Python Lint"] = if ($pyEnv -eq "uv") { "uv run ruff check" } else { "ruff check" }
            if (Test-Path (Join-Path $targetDir "Makefile")) {
                $runbook["Make Targets"] = "make test / make lint (see Makefile)"
            }
        }

        # 4. Ansible / Infrastructure / PowerShell
        $hasAnsible = (Test-Path (Join-Path $targetDir "ansible")) -or (Test-Path (Join-Path $targetDir ".ansible-lint"))
        $hasPowerShell = (Get-ChildItem -Path $targetDir -Filter "*.ps1" -Depth 1 -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasAnsible -or $hasPowerShell) {
            $types.Add("Infrastructure as Code (Ansible / PowerShell)")
            if ($hasAnsible) {
                $frameworks.Add("Ansible")
                $runbook["Ansible Lint"] = "ansible-lint"
                if (Test-Path (Join-Path $targetDir ".yamllint")) {
                    $runbook["YAML Lint"] = "yamllint ."
                }
            }
            if ($hasPowerShell) {
                $runbook["PowerShell Analyzer"] = "Invoke-ScriptAnalyzer -Path . -Recurse"
            }
        }

        # 5. Rust
        if (Test-Path (Join-Path $targetDir "Cargo.toml")) {
            $types.Add("Rust")
            $packageManagers.Add("cargo")
            $runbook["Rust Tests"] = "cargo test"
            $runbook["Rust Clippy"] = "cargo clippy"
        }

        # 6. Go
        if (Test-Path (Join-Path $targetDir "go.mod")) {
            $types.Add("Go")
            $packageManagers.Add("go")
            $runbook["Go Tests"] = "go test ./..."
            $runbook["Go Lint"] = "golangci-lint run"
        }

        # 7. Docker
        if ((Test-Path (Join-Path $targetDir "docker-compose.yml")) -or (Test-Path (Join-Path $targetDir "Dockerfile"))) {
            $frameworks.Add("Docker / Compose")
            $runbook["Docker Compose"] = "docker compose up -d"
        }

        if ($types.Count -eq 0) {
            $types.Add("General / Multi-purpose")
        }

        return @{
            Name = $repoName
            PrimaryStack = ($types -join " + ")
            Frameworks = ($frameworks -join ", ")
            PackageManagers = ($packageManagers -join ", ")
            Runbook = $runbook
        }
    }

    function Reconcile-GitHooks {
        param([string]$targetDir)

        $localHooksPath = (git -C $targetDir --no-pager config --local core.hooksPath)
        $hookDir = $null
        $isCustomHookPath = $false

        if ($localHooksPath) {
            $isCustomHookPath = $true
            if ([System.IO.Path]::IsPathRooted($localHooksPath)) {
                $fullTarget = (Resolve-Path $targetDir).Path
                if ($localHooksPath.StartsWith($fullTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hookDir = $localHooksPath
                } else {
                    Write-Warning "  ⚠️ core.hooksPath points OUTSIDE this repo ($localHooksPath)."
                    Write-Warning "     Localizing hooksPath to .githooks inside $targetDir to avoid cross-repo pollution."
                    git -C $targetDir config --local core.hooksPath .githooks
                    $hookDir = Join-Path $targetDir ".githooks"
                }
            } else {
                $hookDir = Join-Path $targetDir $localHooksPath
            }
        } else {
            $hookDir = Join-Path $targetDir ".git\hooks"
        }

        if (-not (Test-Path $hookDir)) {
            New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
        }

        function Inject-ChainBlock {
            param(
                [string]$hookFilePath,
                [string]$lefthookCmd,
                [string]$hookName
            )

            $chainCode = @"
# Chained by Agent Governance ($hookName)
if command -v lefthook >/dev/null 2>&1; then
  $lefthookCmd || exit 1
else
  echo "⚠️  [Agent Governance] 'lefthook' is not installed or not in PATH." >&2
  echo "   Install with: winget install evilmartians.lefthook (Windows) or brew install lefthook (macOS/Linux)" >&2
  if [ -n "`$AGENT_ROLE" ] || [ -n "`$CLAUDE_CODE" ] || [ -n "`$GEMINI_CLI" ] || [ -n "`$CODEX_AGENT" ] || [ -n "`$COPILOT_AGENT" ]; then
    echo "❌ [Security Gate] Agent session detected without active Lefthook guardrails. Commit blocked." >&2
    exit 1
  fi
fi
"@

            if (Test-Path $hookFilePath) {
                $raw = Get-Content $hookFilePath -Raw
                $cleaned = $raw -replace '(?s)\r?\n# Chained by Agent Governance.*', ''
                $cleaned = $cleaned.TrimEnd()

                $lines = [System.Collections.Generic.List[string]]($cleaned -split "`r?`n")
                $terminalExitIdx = -1

                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    $trimmed = $lines[$i].Trim()
                    if ($trimmed -eq "exit 0") {
                        $terminalExitIdx = $i
                        break
                    }
                    elseif ($trimmed -ne "") {
                        break
                    }
                }

                if ($terminalExitIdx -ge 0) {
                    $lines.Insert($terminalExitIdx, $chainCode.Trim("`r`n"))
                    $finalScript = ($lines -join "`n") + "`n"
                } else {
                    $finalScript = $cleaned + "`n`n" + $chainCode.Trim("`r`n") + "`n"
                }
            } else {
                $finalScript = "#!/bin/sh`nset -e`n`n" + $chainCode.Trim("`r`n") + "`n`nexit 0`n"
            }

            $finalScript = $finalScript -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($hookFilePath, $finalScript, [System.Text.UTF8Encoding]::new($false))
        }

        $preCommitFile = Join-Path $hookDir "pre-commit"
        $prePushFile = Join-Path $hookDir "pre-push"

        Inject-ChainBlock -hookFilePath $preCommitFile -lefthookCmd "lefthook run pre-commit" -hookName "Lefthook + Gitleaks"
        Inject-ChainBlock -hookFilePath $prePushFile -lefthookCmd "lefthook run pre-push" -hookName "Supply-Chain & Test Audit"

        if ($isCustomHookPath) {
            Write-Host "  🔗 Chained Lefthook inside custom hooks ($hookDir) before terminal exit 0" -ForegroundColor Green
        } else {
            if (Get-Command lefthook -ErrorAction SilentlyContinue) {
                & lefthook install >$null 2>&1
            }
            Write-Host "  ✔️ Lefthook Git hooks active in $hookDir" -ForegroundColor Green
        }
    }

    function Sync-SingleRepo {
        param([string]$targetDir)

        $resolvedDir = (Resolve-Path $targetDir).Path
        $repoName = Split-Path -Leaf $resolvedDir

        Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "📦 Repository: $repoName" -ForegroundColor Cyan
        Write-Host "   Path: $resolvedDir" -ForegroundColor DarkGray
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

        # 1. Verify Git repository
        if (-not (Test-Path (Join-Path $resolvedDir ".git"))) {
            Write-Warning "Skipped: Not a Git repository (no .git folder found)."
            return
        }

        Push-Location $resolvedDir
        try {
            # 2. Safety Gate: Check for uncommitted work in project code
            $status = (git --no-pager status --porcelain)
            if ($status) {
                $modifiedLines = ($status -split "`r?`n") | Where-Object { $_.Trim() }
                $nonGovChanges = $modifiedLines | Where-Object { 
                    $_ -notmatch '^\?\?\s+(\.agents|\.claude|\.gemini|\.github|AGENTS\.md|CLAUDE\.md|PROJECT\.md|lefthook\.yml|scripts/guardrails|\.claudeignore|\.codexignore)' -and
                    $_ -notmatch '^ M \.gitignore' -and
                    $_ -notmatch '^ M (\.githooks|\.husky|\.git/hooks)'
                }
                if ($nonGovChanges) {
                    Write-Warning "⚠️ SKIPPED: Repository has uncommitted changes in project code:"
                    $nonGovChanges | Select-Object -First 3 | ForEach-Object { Write-Warning "   $_" }
                    Write-Warning "   Stash or commit before syncing."
                    return
                }
            }

            if ($AuditOnly) {
                $hasAgents = Test-Path (Join-Path $resolvedDir "AGENTS.md")
                $hasLefthook = Test-Path (Join-Path $resolvedDir "lefthook.yml")
                $hasProject = Test-Path (Join-Path $resolvedDir "PROJECT.md")
                $localHooksPath = (git --no-pager config --local core.hooksPath)
                Write-Host "Audit Status:"
                Write-Host "  - AGENTS.md:        $hasAgents"
                Write-Host "  - lefthook.yml:     $hasLefthook"
                Write-Host "  - PROJECT.md:       $hasProject"
                Write-Host "  - core.hooksPath:   $(if ($localHooksPath) { $localHooksPath } else { '.git/hooks (default)' })"
                return
            }

            Write-Host "⚡ Reconciling governance and guardrails..." -ForegroundColor Green

            # 3. Create target directories
            $agentsRulesDir = Join-Path $resolvedDir ".agents\rules"
            $scriptsDir = Join-Path $resolvedDir "scripts\guardrails"
            $githubDir = Join-Path $resolvedDir ".github"
            $claudeDir = Join-Path $resolvedDir ".claude"
            $geminiDir = Join-Path $resolvedDir ".gemini"
            $docsDir = Join-Path $resolvedDir "docs"

            New-Item -ItemType Directory -Path $agentsRulesDir -Force | Out-Null
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $githubDir -Force | Out-Null
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            New-Item -ItemType Directory -Path $geminiDir -Force | Out-Null

            # 4. Handle Legacy Instructions
            $existingAgentsPath = Join-Path $resolvedDir "AGENTS.md"
            $existingClaudePath = Join-Path $resolvedDir "CLAUDE.md"
            $templateAgentsContent = (Get-Content (Join-Path $hubDir "AGENTS.md") -Raw).Trim()
            $hasPreservedLegacy = $false

            if (Test-Path $existingAgentsPath) {
                $currentContent = (Get-Content $existingAgentsPath -Raw).Trim()
                if ($currentContent -and ($currentContent -ne $templateAgentsContent)) {
                    New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
                    $backupPath = Join-Path $docsDir "LEGACY-AGENT-NOTES.md"
                    if (-not (Test-Path $backupPath)) {
                        Set-Content -Path $backupPath -Value $currentContent -Encoding utf8
                        $hasPreservedLegacy = $true
                        Write-Host "  🛡️ Preserved pre-existing custom AGENTS.md into docs/LEGACY-AGENT-NOTES.md"
                    }
                }
            } elseif (Test-Path $existingClaudePath) {
                $currentClaude = (Get-Content $existingClaudePath -Raw).Trim()
                if ($currentClaude -and ($currentClaude -ne $templateAgentsContent)) {
                    New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
                    $backupPath = Join-Path $docsDir "LEGACY-AGENT-NOTES.md"
                    if (-not (Test-Path $backupPath)) {
                        Set-Content -Path $backupPath -Value $currentClaude -Encoding utf8
                        $hasPreservedLegacy = $true
                        Write-Host "  🛡️ Preserved pre-existing custom CLAUDE.md into docs/LEGACY-AGENT-NOTES.md"
                    }
                }
            }

            # 5. Copy canonical rules and scripts from Hub
            Copy-Item (Join-Path $hubDir "AGENTS.md") (Join-Path $resolvedDir "AGENTS.md") -Force
            Copy-Item (Join-Path $hubDir "lefthook.yml") (Join-Path $resolvedDir "lefthook.yml") -Force
            Copy-Item (Join-Path $hubDir ".agents\rules\*") $agentsRulesDir -Force
            Copy-Item (Join-Path $hubDir "scripts\guardrails\*") $scriptsDir -Force

            # 6. Auto-detect stack & generate rich PROJECT.md if missing or unpopulated
            $targetProjectFile = Join-Path $resolvedDir "PROJECT.md"
            $shouldGenerateProject = $true
            if (Test-Path $targetProjectFile) {
                $existingProject = Get-Content $targetProjectFile -Raw
                if (-not ($existingProject -match '<e\.g\.,' -or $existingProject -match '<project-name>')) {
                    $shouldGenerateProject = $false
                    Write-Host "  ✔️ Preserved existing customized PROJECT.md"
                }
            }

            if ($shouldGenerateProject) {
                $stack = Detect-ProjectStack -targetDir $resolvedDir -repoName $repoName
                $pMd = [System.Collections.Generic.List[string]]::new()
                $pMd.Add("# Project Specification & Architecture: $($stack.Name)")
                $pMd.Add("")
                $pMd.Add("This file defines repository-specific architecture, runbooks, and conventions.")
                $pMd.Add("It is consulted by coding agents alongside the universal operating contract (`AGENTS.md`).")
                $pMd.Add("")

                if ((Test-Path (Join-Path $docsDir "LEGACY-AGENT-NOTES.md")) -or $hasPreservedLegacy) {
                    $pMd.Add("---")
                    $pMd.Add("")
                    $pMd.Add("## 0. Legacy & Historical Agent Instructions")
                    $pMd.Add("> [!NOTE]")
                    $pMd.Add("> Pre-existing custom repository instructions were archived to [`docs/LEGACY-AGENT-NOTES.md`](docs/LEGACY-AGENT-NOTES.md).")
                    $pMd.Add("> Agents MUST consult this document for historical architectural context, design decisions, and domain conventions.")
                    $pMd.Add("")
                }

                $pMd.Add("---")
                $pMd.Add("")
                $pMd.Add("## 1. Project Overview & Tech Stack")
                $pMd.Add("* **Repository Name:** $($stack.Name)")
                $pMd.Add("* **Detected Stack:** $($stack.PrimaryStack)")
                $pMd.Add("* **Frameworks / Platforms:** $(if ($stack.Frameworks) { $stack.Frameworks } else { 'Standard / Native' })")
                $pMd.Add("* **Package Manager(s):** $(if ($stack.PackageManagers) { $stack.PackageManagers } else { 'None detected' })")
                $pMd.Add("")
                $pMd.Add("---")
                $pMd.Add("")
                $pMd.Add("## 2. Development Runbook & Commands")

                if ($stack.Runbook.Count -gt 0) {
                    foreach ($key in $stack.Runbook.Keys) {
                        $val = $stack.Runbook[$key]
                        $pMd.Add("* **$($key):** " + '`' + $val + '`')
                    }
                } else {
                    $pMd.Add("* Document local start, lint, and test commands here.")
                }

                $pMd.Add("")
                $pMd.Add("---")
                $pMd.Add("")
                $pMd.Add("## 3. Key Directories & Architecture Map")
                $pMd.Add("* Standard repository layout. Consult existing source tree for module structure.")

                Set-Content -Path $targetProjectFile -Value ($pMd -join "`r`n") -Encoding utf8
                Write-Host "  ✔️ Auto-detected stack ($($stack.PrimaryStack)) and generated tailored PROJECT.md"
            }

            # 7. Intra-repo hard links for agent pointers
            $targetAgents = Join-Path $resolvedDir "AGENTS.md"
            New-Item -ItemType HardLink -Path (Join-Path $resolvedDir "CLAUDE.md") -Target $targetAgents -Force | Out-Null
            New-Item -ItemType HardLink -Path (Join-Path $githubDir "copilot-instructions.md") -Target $targetAgents -Force | Out-Null

            # 8. Merge .gitignore rules non-destructively
            $targetGitignore = Join-Path $resolvedDir ".gitignore"
            if (Test-Path $targetGitignore) {
                $existingIgnore = Get-Content $targetGitignore -Raw
                $hubIgnore = Get-Content (Join-Path $hubDir ".gitignore") -Raw
                $missingEntries = @()
                foreach ($line in ($hubIgnore -split "`r?`n")) {
                    $trimmed = $line.Trim()
                    if ($trimmed -and -not ($trimmed.StartsWith("#")) -and -not ($existingIgnore -match [regex]::Escape($trimmed))) {
                        $missingEntries += $trimmed
                    }
                }
                if ($missingEntries.Count -gt 0) {
                    Add-Content -Path $targetGitignore -Value ("`n# Added by Agent Governance`n" + ($missingEntries -join "`n"))
                    Write-Host "  ✔️ Added $($missingEntries.Count) missing shield rules to .gitignore"
                }
            } else {
                Copy-Item (Join-Path $hubDir ".gitignore") $targetGitignore -Force
                Write-Host "  ✔️ Initialized .gitignore from canonical shield"
            }

            New-Item -ItemType HardLink -Path (Join-Path $resolvedDir ".claudeignore") -Target $targetGitignore -Force | Out-Null
            New-Item -ItemType HardLink -Path (Join-Path $resolvedDir ".codexignore") -Target $targetGitignore -Force | Out-Null

            # 9. Directory junctions for native tool auto-injection
            $claudeRules = Join-Path $claudeDir "rules"
            $geminiRules = Join-Path $geminiDir "rules"
            if (-not (Test-Path $claudeRules)) {
                New-Item -ItemType Junction -Path $claudeRules -Target $agentsRulesDir -Force | Out-Null
            }
            if (-not (Test-Path $geminiRules)) {
                New-Item -ItemType Junction -Path $geminiRules -Target $agentsRulesDir -Force | Out-Null
            }

            # 10. Intelligent Git Hook Reconciliation
            Reconcile-GitHooks -targetDir $resolvedDir

            # 11. Optional Safe Branching and Conventional Commits
            if ($BranchAndCommit) {
                $govStatus = (git --no-pager status --porcelain)
                if ($govStatus) {
                    $currentBranch = (git --no-pager branch --show-current)
                    if ($currentBranch -in @("main", "master") -or $currentBranch -notmatch '^(feat|fix|patch|hotfix|refactor|chore|test)/') {
                        $branchExists = (git --no-pager branch --list "chore/agent-governance")
                        if ($branchExists) {
                            git checkout chore/agent-governance 2>$null | Out-Null
                        } else {
                            git checkout -b chore/agent-governance 2>$null | Out-Null
                        }
                    }

                    $stageItems = @(
                        "AGENTS.md", "CLAUDE.md", "PROJECT.md", "lefthook.yml",
                        ".agents", ".claude", ".gemini", ".github",
                        ".gitignore", ".claudeignore", ".codexignore",
                        "scripts/guardrails", "docs/LEGACY-AGENT-NOTES.md"
                    )
                    foreach ($item in $stageItems) {
                        if (Test-Path (Join-Path $resolvedDir $item)) {
                            git add -- $item
                        }
                    }
                    if (Test-Path (Join-Path $resolvedDir ".githooks")) {
                        git add -- .githooks
                    }

                    $staged = (git --no-pager diff --cached --name-only)
                    if ($staged) {
                        git commit -m "chore(governance): install unified agent contract and deterministic guardrails" | Out-Null
                        Write-Host "  ✅ Auto-committed governance baseline to branch: $(git --no-pager branch --show-current)" -ForegroundColor Green
                    }
                }
            }

            Write-Host "  🎉 $repoName is fully governed, reconciled, and armored!" -ForegroundColor Green
        } finally {
            Pop-Location
        }
    }

    if ($All) {
        $githubRoot = "C:\Users\omokolade\GitHub"
        $repos = Get-ChildItem -Path $githubRoot -Directory | Where-Object { $_.Name -ne "agent-governance" }
        Write-Host "🚀 Running Sync-AgentGovernance across $($repos.Count) repositories..." -ForegroundColor Magenta
        foreach ($repo in $repos) {
            Sync-SingleRepo -targetDir $repo.FullName
        }
    } else {
        Sync-SingleRepo -targetDir $RepoPath
    }
}
