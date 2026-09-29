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
    If specified, scans and safely audits/updates every git repository directly under -FleetRoot.
.PARAMETER FleetRoot
    Directory whose child git repositories -All operates on. Defaults to $env:AGENT_GOVERNANCE_FLEET_ROOT,
    else the directory that contains this hub repository.
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
    Audits all repositories under the fleet root.
.EXAMPLE
    Sync-AgentGovernance -RepoPath ../my-service -WhatIf
    Lists the files a sync would create or update, without writing anything.
.EXAMPLE
    Sync-AgentGovernance audit -a
    Short subcommand syntax for fleet-wide audit.
.EXAMPLE
    Sync-AgentGovernance -h
    Displays detailed help and CLI reference.
#>
function Sync-AgentGovernance {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'BranchAndCommit', Justification = 'Read by the nested Sync-SingleRepo through dynamic scope.')]
    [CmdletBinding(DefaultParameterSetName = 'Standard', SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('sync', 'audit', 'status', 'hooks', 'help', '')]
        [string]$Action = 'sync',

        [Parameter()]
        [Alias('r', 'Path')]
        [string]$RepoPath = (Get-Location).Path,

        [Parameter()]
        [Alias('a')]
        [switch]$All,

        [Parameter()]
        [string]$FleetRoot,

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

    function Set-Utf8LfContent {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Every caller runs after the ShouldProcess gate in Sync-SingleRepo.')]
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,
            [Parameter(Mandatory = $true)]
            [string]$Content
        )
        $normalized = ($Content -replace "\r\n", "`n").TrimEnd("`n") + "`n"
        [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
    }

    function Get-MissingEntry {
        [OutputType([string[]])]
        param(
            [AllowEmptyString()]
            [string]$ExistingText,
            [Parameter(Mandatory = $true)]
            [string]$CanonicalText
        )
        # Exact, whitespace-trimmed line comparison: a substring match would treat '*.key' as present
        # whenever '*.keystore' exists, silently dropping secret-shield rules.
        $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($line in ($ExistingText -split "`r?`n")) { [void]$present.Add($line.Trim()) }

        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($CanonicalText -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith("#") -and $present.Add($trimmed)) {
                $missing.Add($trimmed)
            }
        }
        return , $missing.ToArray()
    }

    function Get-NormalizedHash {
        [OutputType([string])]
        param([Parameter(Mandatory = $true)][string]$Path)
        # Line-ending normalized (matches verify-governance.ps1) so CRLF checkouts hash identically.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"))
        return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }

    function Get-ManagedFile {
        [OutputType([pscustomobject[]])]
        param([Parameter(Mandatory = $true)][string]$HubDir)
        # Files the engine owns downstream: Target is repo-relative (forward slashes); Source is the hub
        # file to copy, or $null when the engine generates the content (Content).
        $managed = [System.Collections.Generic.List[pscustomobject]]::new()
        $managed.Add([pscustomobject]@{ Target = 'AGENTS.md'; Source = (Join-Path $HubDir 'AGENTS.md'); Content = $null })
        $managed.Add([pscustomobject]@{ Target = 'CLAUDE.md'; Source = $null; Content = "@AGENTS.md`n" })
        $managed.Add([pscustomobject]@{ Target = '.github/copilot-instructions.md'; Source = (Join-Path $HubDir 'AGENTS.md'); Content = $null })
        $managed.Add([pscustomobject]@{ Target = 'lefthook.yml'; Source = (Join-Path $HubDir 'lefthook.yml'); Content = $null })
        foreach ($rule in Get-ChildItem -Path (Join-Path $HubDir '.agents' 'rules') -File) {
            $managed.Add([pscustomobject]@{ Target = ".agents/rules/$($rule.Name)"; Source = $rule.FullName; Content = $null })
            $managed.Add([pscustomobject]@{ Target = ".claude/rules/$($rule.Name)"; Source = $rule.FullName; Content = $null })
        }
        foreach ($guard in Get-ChildItem -Path (Join-Path $HubDir 'scripts' 'guardrails') -File) {
            $managed.Add([pscustomobject]@{ Target = "scripts/guardrails/$($guard.Name)"; Source = $guard.FullName; Content = $null })
        }
        return , $managed.ToArray()
    }

    function Get-PlannedChange {
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)][string]$TargetDir,
            [Parameter(Mandatory = $true)][string]$HubDir
        )
        $plan = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ManagedFile -HubDir $HubDir)) {
            $targetPath = Join-Path $TargetDir $file.Target
            $desired = if ($file.Source) { [System.IO.File]::ReadAllText($file.Source) } else { $file.Content }
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                $plan.Add("create  $($file.Target)")
            } elseif (([System.IO.File]::ReadAllText($targetPath) -replace "`r`n", "`n") -ne ($desired -replace "`r`n", "`n")) {
                $plan.Add("update  $($file.Target)")
            }
        }
        foreach ($optional in @('PROJECT.md', '.claude/settings.json', '.gemini/settings.json', '.codex/config.toml', '.agent-governance.lock')) {
            if (-not (Test-Path -LiteralPath (Join-Path $TargetDir $optional))) { $plan.Add("create  $optional") }
        }
        $caller = Get-CallerWorkflow -HubDir $HubDir -RepoDir $TargetDir
        if ($caller.Content) {
            $callerPath = Join-Path $TargetDir '.github' 'workflows' 'agent-governance.yml'
            if (-not (Test-Path -LiteralPath $callerPath)) { $plan.Add("create  .github/workflows/agent-governance.yml") }
            elseif (([System.IO.File]::ReadAllText($callerPath) -replace "`r`n", "`n") -ne $caller.Content) { $plan.Add("update  .github/workflows/agent-governance.yml") }
        } else {
            $plan.Add("skip    .github/workflows/agent-governance.yml ($($caller.Reason))")
        }
        $eol = Get-EolRenormalizeCandidate -RepoDir $TargetDir
        if ($eol.Count -gt 0) { $plan.Add("renormalize line endings in $($eol.Count) file(s)") }
        $plan.Add("merge   .gitignore / .gitattributes (missing canonical entries only)")
        $plan.Add("chain   git pre-commit / pre-push hooks")
        return , $plan.ToArray()
    }

    function Get-EolRenormalizeCandidate {
        [OutputType([string[]])]
        param([Parameter(Mandatory = $true)][string]$RepoDir)
        # Tracked files stored with CRLF (or mixed) although .gitattributes requires eol=lf. Fresh clones
        # show these as modified until they are renormalized.
        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($line in @(git -C $RepoDir -c core.quotepath=off ls-files --eol)) {
            $parts = "$line" -split "`t", 2
            if ($parts.Count -eq 2 -and $parts[0] -match '^i/(crlf|mixed)\s' -and $parts[0] -match '\beol=lf\b') {
                $candidates.Add($parts[1])
            }
        }
        return , $candidates.ToArray()
    }

    function Test-EolOnlyChange {
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)][string]$RepoDir,
            [Parameter(Mandatory = $true)][string]$Path
        )
        # True when the working-tree difference consists only of line-ending changes.
        & git -C $RepoDir -c core.quotepath=off diff --quiet --ignore-cr-at-eol -- $Path 2>$null
        return ($LASTEXITCODE -eq 0)
    }

    function Get-CallerWorkflow {
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)][string]$HubDir,
            [Parameter(Mandatory = $true)][string]$RepoDir
        )
        # Renders the managed caller workflow pinned to the hub commit. Returns Content = $null plus a
        # Reason when the pin would not be fetchable by downstream CI.
        $hubRepoRoot = Split-Path -Parent $HubDir
        $commit = "$(git -C $hubRepoRoot rev-parse HEAD 2>$null)".Trim()
        if ($commit -notmatch '^[0-9a-f]{40}$') { return [pscustomobject]@{ Content = $null; Reason = 'the hub is not a git checkout' } }
        $templateChanges = "$(git -C $hubRepoRoot status --porcelain -- template 2>$null)".Trim()
        if ($templateChanges) {
            return [pscustomobject]@{ Content = $null; Reason = 'the hub template has uncommitted changes' }
        }
        $remoteBranches = "$(git -C $hubRepoRoot branch -r --contains $commit 2>$null)".Trim()
        if (-not $remoteBranches) {
            return [pscustomobject]@{ Content = $null; Reason = "hub commit $($commit.Substring(0, 7)) is not pushed" }
        }
        $originUrl = "$(git -C $hubRepoRoot remote get-url origin 2>$null)".Trim()
        if ($originUrl -notmatch 'github\.com[:/]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(\.git)?/?$') {
            return [pscustomobject]@{ Content = $null; Reason = 'the hub origin is not a GitHub repository' }
        }
        $hubRepository = "$($Matches[1])/$($Matches[2])"
        $defaultBranch = "$(git -C $RepoDir symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/', ''
        if ($defaultBranch -notmatch '^[A-Za-z0-9._/-]+$') { $defaultBranch = 'main' }

        $template = [System.IO.File]::ReadAllText((Join-Path $HubDir '.github' 'workflows' 'agent-governance.yml'))
        $content = $template.Replace('__HUB_REPOSITORY__', $hubRepository).Replace('__HUB_COMMIT__', $commit).Replace('__DEFAULT_BRANCH__', $defaultBranch)
        return [pscustomobject]@{ Content = $content; Reason = $null }
    }

    function Test-MatchesHubHistory {
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)][string]$HubDir,
            [Parameter(Mandatory = $true)][string]$TemplateRelativePath,
            [Parameter(Mandatory = $true)][string]$FilePath
        )
        # True when the file equals any committed hub version of the template: the engine wrote it and
        # nobody has edited it since, so replacing it with the current version loses nothing.
        $hubRepoRoot = Split-Path -Parent $HubDir
        $gitPath = "template/$TemplateRelativePath"
        $target = Get-NormalizedHash -Path $FilePath
        foreach ($commit in @(git -C $hubRepoRoot log --format=%H -- $gitPath 2>$null)) {
            $content = (@(git -C $hubRepoRoot show "${commit}:$gitPath" 2>$null) -join "`n") + "`n"
            if ($LASTEXITCODE -ne 0) { continue }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes(($content -replace "`r`n", "`n"))
            if ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -eq $target) {
                return $true
            }
        }
        return $false
    }

    function Sync-ManagedToolFile {
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)][string]$HubDir,
            [Parameter(Mandatory = $true)][string]$RepoDir,
            [Parameter(Mandatory = $true)][string]$RelativePath,
            [AllowNull()][object]$PreviousLock,
            [string[]]$LegacyContent = @()
        )
        # Agent settings are managed while unmodified: installed when absent, updated when they match the
        # lock, any committed hub version, or content an earlier engine wrote; a team-edited file is kept.
        $source = Join-Path $HubDir $RelativePath
        $target = Join-Path $RepoDir $RelativePath
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item $source $target
            return [pscustomobject]@{ Managed = $true; Action = 'installed' }
        }
        $current = Get-NormalizedHash -Path $target
        if ($current -eq (Get-NormalizedHash -Path $source)) {
            return [pscustomobject]@{ Managed = $true; Action = 'current' }
        }
        $locked = if ($PreviousLock) { [string]$PreviousLock.files.$RelativePath } else { '' }
        $legacyHashes = foreach ($legacy in $LegacyContent) {
            [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                    [System.Text.Encoding]::UTF8.GetBytes(($legacy -replace "`r`n", "`n")))).ToLowerInvariant()
        }
        $unmodified = ($locked -and $locked -eq $current) -or ($legacyHashes -contains $current) -or
            (Test-MatchesHubHistory -HubDir $HubDir -TemplateRelativePath $RelativePath -FilePath $target)
        if (-not $unmodified) {
            return [pscustomobject]@{ Managed = $false; Action = 'kept' }
        }
        Remove-Item -LiteralPath $target -Force
        Copy-Item $source $target
        return [pscustomobject]@{ Managed = $true; Action = 'updated' }
    }

    function Show-HelpManual {
        Write-Host @"

══════════════════════════════════════════════════════════════════════════════
 🛡️  AGENT GOVERNANCE DISTRIBUTION ENGINE (CLI REFERENCE)
══════════════════════════════════════════════════════════════════════════════

SYNOPSIS:
    Sync-AgentGovernance [[-Action] <sync|audit|status|hooks|help>]
                         [-RepoPath|-r <path>]
                         [-All|-a]
                         [-AuditOnly|-m]
                         [-BranchAndCommit|-c]
                         [-Help|-h|-?]

SUBCOMMANDS:
    sync                 Idempotently synchronizes governance, hooks, and rules. (Default)
    audit                Audits repository governance status without writing any files.
    hooks                Installs only the local git gate (safe with uncommitted work).
    status               Displays Central Hub health, active templates, and version info.
    help                 Displays this comprehensive manual.

PARAMETERS:
    -RepoPath, -r <path> Target repository path. Defaults to current working directory.
    -All, -a             Scans and operates across ALL git repos under -FleetRoot.
    -FleetRoot <path>    Parent directory for -All (default: `$env:AGENT_GOVERNANCE_FLEET_ROOT or the hub's parent).
    -WhatIf              Lists planned file changes per repository without writing anything.
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
    Sync-AgentGovernance -r ../content-estate -c

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

    # Locate Central Hub (template beside this script, then the per-user hub location)
    $hubCandidates = @(
        (Join-Path $PSScriptRoot "template"),
        (Join-Path $HOME ".agent-governance" "template")
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

    function Get-ProjectStack {
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
                    if ($pkg.scripts.PSObject.Properties['format']) { $runbook["Code Format"] = "$pm run format" }
                    elseif ($pkg.scripts.PSObject.Properties['format:check']) { $runbook["Format Check"] = "$pm run format:check" }
                    elseif ($pkg.scripts.PSObject.Properties['prettier']) { $runbook["Prettier Check"] = "$pm run prettier" }
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

        # 8. Operational Handover & Architecture Document Detection
        $handoverCandidates = @(
            "HANDOVER.md",
            "docs/CURRENT-STATE.md",
            "docs/RELEASE-HANDOFF.md",
            "docs/OPERATIONS.md",
            "CURRENT-STATE.md",
            "docs/HANDOVER.md",
            "docs/ARCHITECTURE.md"
        )
        $detectedHandover = $null
        foreach ($candidate in $handoverCandidates) {
            $candidatePath = Join-Path $targetDir $candidate
            if (Test-Path $candidatePath) {
                $detectedHandover = $candidate
                break
            }
        }

        # 9. Lessons Learned & Anti-Regression Document Detection
        $lessonsCandidates = @(
            "LESSONS_LEARNED.md",
            "docs/LESSONS_LEARNED.md",
            "LESSONS-LEARNED.md",
            "docs/LESSONS-LEARNED.md",
            "TRAPS.md",
            "docs/TRAPS.md"
        )
        $detectedLessons = $null
        foreach ($candidate in $lessonsCandidates) {
            $candidatePath = Join-Path $targetDir $candidate
            if (Test-Path $candidatePath) {
                $detectedLessons = $candidate
                break
            }
        }

        return @{
            Name = $repoName
            PrimaryStack = ($types -join " + ")
            Frameworks = ($frameworks -join ", ")
            PackageManagers = ($packageManagers -join ", ")
            Runbook = $runbook
            OperationalHandover = $detectedHandover
            LessonsLearned = $detectedLessons
        }
    }

    function Sync-GitHook {
        param([string]$targetDir)

        $localHooksPath = (git -C $targetDir --no-pager config --local core.hooksPath)
        $hookDir = $null
        $isCustomHookPath = $false

        if ($localHooksPath) {
            $isCustomHookPath = $true
            $fullTarget = (Resolve-Path $targetDir).Path
            $candidate = [System.IO.Path]::GetFullPath($localHooksPath, $fullTarget)
            $relative = [System.IO.Path]::GetRelativePath($fullTarget, $candidate)
            if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.([\\/]|$)') {
                Write-Warning "  ⚠️ core.hooksPath points OUTSIDE this repo ($localHooksPath)."
                Write-Warning "     Localizing hooksPath to .githooks inside $targetDir to avoid cross-repo pollution."
                git -C $targetDir config --local core.hooksPath .githooks
                if ($LASTEXITCODE -ne 0) { throw 'Failed to localize core.hooksPath.' }
                $hookDir = Join-Path $targetDir '.githooks'
            } else {
                $hookDir = $candidate
            }
        } elseif (@(git -C $targetDir ls-files -- .githooks/pre-commit .githooks/pre-push 2>$null).Count -gt 0) {
            # core.hooksPath is local config and is not cloned: a fresh clone of a repository that versions its
            # hooks in .githooks still has to update those tracked files (and use them from now on).
            $isCustomHookPath = $true
            git -C $targetDir config --local core.hooksPath .githooks
            if ($LASTEXITCODE -ne 0) { throw 'Failed to set core.hooksPath to the tracked .githooks.' }
            $hookDir = Join-Path (Resolve-Path $targetDir).Path '.githooks'
        } else {
            # Worktree-safe: in a linked worktree .git is a file and hooks live in the common git dir.
            $hookDir = "$(git -C $targetDir rev-parse --path-format=absolute --git-path hooks)".Trim()
            if ($LASTEXITCODE -ne 0 -or -not $hookDir) { throw 'Could not resolve the git hooks directory.' }
        }

        if (-not (Test-Path $hookDir)) {
            New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
        }

        function Add-GovernanceHookBlock {
            param(
                [string]$hookFilePath,
                [string]$lefthookCmd,
                [string]$hookName
            )

            # --no-auto-install stops Lefthook from regenerating (and thereby deleting) this fail-closed gate.
            # Agent markers: CLAUDECODE / AI_AGENT are set by Claude Code; the rest are conventional opt-ins.
            $chainCode = @"
# >>> agent-governance ($hookName) >>>
if command -v lefthook >/dev/null 2>&1; then
  $lefthookCmd --no-auto-install || exit 1
else
  echo "⚠️  [Agent Governance] 'lefthook' is not installed or not in PATH." >&2
  echo "   Install with: winget install evilmartians.lefthook (Windows) or brew install lefthook (macOS/Linux)" >&2
  if [ -n "`$CLAUDECODE" ] || [ -n "`$AI_AGENT" ] || [ -n "`$AGENT_ROLE" ] || [ -n "`$CLAUDE_CODE" ] || [ -n "`$GEMINI_CLI" ] || [ -n "`$CODEX_AGENT" ] || [ -n "`$COPILOT_AGENT" ]; then
    echo "❌ [Security Gate] Agent session detected without active Lefthook guardrails. Commit blocked." >&2
    exit 1
  fi
fi
# <<< agent-governance <<<
"@
            $chainCode = ($chainCode -replace "`r`n", "`n").Trim("`n")

            $baseScript = "#!/bin/sh`nset -e`n`nexit 0`n"
            if (Test-Path $hookFilePath) {
                $raw = [System.IO.File]::ReadAllText($hookFilePath) -replace "`r`n", "`n"
                # A Lefthook-generated hook would run Lefthook twice (and fails open when it is missing); replace it.
                if ($raw -notmatch '(?m)^call_lefthook run ') {
                    $baseScript = $raw
                }
            }

            # Remove only governance-owned blocks: the current marked format and the legacy unmarked format,
            # which always ended with the nested "  fi" / "fi" pair. User lines around them are kept.
            $cleaned = [regex]::Replace($baseScript, '(?ms)^# >>> agent-governance .*?^# <<< agent-governance <<<\n?', '')
            $cleaned = [regex]::Replace($cleaned, '(?s)# Chained by Agent Governance[^\n]*\n.*?\n  fi\nfi\n?', '')
            $cleaned = ($cleaned -replace "\n{3,}", "`n`n").TrimEnd()

            $lines = [System.Collections.Generic.List[string]]($cleaned -split "`n")
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
                $lines.Insert($terminalExitIdx, $chainCode)
                $finalScript = ($lines -join "`n") + "`n"
            } else {
                $finalScript = $cleaned + "`n`n" + $chainCode + "`n"
            }

            [System.IO.File]::WriteAllText($hookFilePath, $finalScript, [System.Text.UTF8Encoding]::new($false))
            if (-not $IsWindows) {
                # Git silently ignores non-executable hooks on POSIX systems.
                & chmod +x $hookFilePath
            }
        }

        $preCommitFile = Join-Path $hookDir "pre-commit"
        $prePushFile = Join-Path $hookDir "pre-push"

        Add-GovernanceHookBlock -hookFilePath $preCommitFile -lefthookCmd "lefthook run pre-commit" -hookName "Lefthook + Gitleaks"
        Add-GovernanceHookBlock -hookFilePath $prePushFile -lefthookCmd "lefthook run pre-push" -hookName "Supply-Chain & Test Audit"

        # 'lefthook install' is deliberately not run: it would replace these fail-closed hooks with its own.
        if ($isCustomHookPath) {
            Write-Host "  🔗 Chained Lefthook inside custom hooks ($hookDir) before terminal exit 0" -ForegroundColor Green
        } else {
            Write-Host "  ✔️ Governance-gated Lefthook hooks active in $hookDir" -ForegroundColor Green
        }
    }

    function Invoke-DownstreamFormatting {
        param([string]$targetDir)

        # Includes the generated gate workflow: sync rewrites it each run, so only the engine can keep it formatted.
        $governedFiles = @(
            "AGENTS.md", "CLAUDE.md", "PROJECT.md", "WORKING.md",
            "docs/LEGACY-AGENT-NOTES.md", ".github/copilot-instructions.md",
            ".github/workflows/agent-governance.yml"
        ) | Where-Object { Test-Path (Join-Path $targetDir $_) }

        if ($governedFiles.Count -eq 0) { return }
        $prettierConfigured = [bool](Get-ChildItem -LiteralPath $targetDir -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\.prettierrc' -or $_.Name -match '^prettier\.config\.' })

        # 1. Local Prettier binary in node_modules
        $localPrettierCmd = Join-Path $targetDir "node_modules\.bin\prettier.cmd"
        $localPrettierSh = Join-Path $targetDir "node_modules\.bin\prettier"
        $prettierExe = if (Test-Path $localPrettierCmd) { $localPrettierCmd } elseif (Test-Path $localPrettierSh) { $localPrettierSh } else { $null }

        if ($prettierExe) {
            try {
                Push-Location $targetDir
                try {
                    & $prettierExe --write $governedFiles 2>$null | Out-Null
                    Write-Host "  ✨ Formatted governed files with local Prettier" -ForegroundColor Green
                    return
                } finally {
                    Pop-Location
                }
            } catch {
                # Non-blocking fallback to npx below
                Write-Verbose "Local Prettier failed in ${targetDir}: $($_.Exception.Message)"
            }
        }

        # 2. Local npx strictly without remote installation
        if (Test-Path (Join-Path $targetDir "package.json")) {
            $hasPkgPrettier = $false
            try {
                $pkgRaw = Get-Content (Join-Path $targetDir "package.json") -Raw | ConvertFrom-Json
                if (($pkgRaw.devDependencies -and $pkgRaw.devDependencies.PSObject.Properties['prettier']) -or
                    ($pkgRaw.dependencies -and $pkgRaw.dependencies.PSObject.Properties['prettier'])) {
                    $hasPkgPrettier = $true
                }
            } catch {
                Write-Verbose "Unreadable package.json in ${targetDir}; skipping npx Prettier: $($_.Exception.Message)"
            }

            if ($hasPkgPrettier -and (Get-Command npx -ErrorAction SilentlyContinue)) {
                try {
                    Push-Location $targetDir
                    try {
                        & npx --no-install prettier --write $governedFiles 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  ✨ Formatted governed files with local Prettier (npx offline)" -ForegroundColor Green
                            return
                        }
                    } finally {
                        Pop-Location
                    }
                } catch {
                    # Non-blocking: governed files stay unformatted
                    Write-Verbose "npx Prettier failed in ${targetDir}: $($_.Exception.Message)"
                }
            }
            if ($hasPkgPrettier) { $prettierConfigured = $true }
        }

        if ($prettierConfigured) {
            Write-Warning "Prettier is configured in this repository but not installed, so governed files were not formatted and its format check may fail. Install dependencies (e.g. npm ci) and re-run the sync."
        }
    }

    function Sync-SingleRepo {
        param([string]$targetDir)

        if (-not (Test-Path $targetDir)) {
            Write-Warning "Target path does not exist: $targetDir"
            return
        }

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
                    $_ -notmatch '^\?\?\s+(\.agents|\.claude|\.codex|\.gemini|\.github|\.gitattributes|\.gitignore|AGENTS\.md|CLAUDE\.md|PROJECT\.md|WORKING\.md|lefthook\.yml|scripts/|docs/LEGACY-AGENT-NOTES\.md|\.agent-governance\.lock)' -and
                    $_ -notmatch '^ M (\.gitignore|\.gitattributes)' -and
                    $_ -notmatch '^ M (\.githooks|\.husky|\.git/hooks)' -and
                    # Line-ending-only drift (CRLF stored despite eol=lf) is renormalized by the sync, not project work.
                    -not ($_ -match '^ M (.+)$' -and (Test-EolOnlyChange -RepoDir $resolvedDir -Path $Matches[1].Trim('"')))
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

            if (-not $PSCmdlet.ShouldProcess($resolvedDir, "Apply governance baseline")) {
                foreach ($change in (Get-PlannedChange -TargetDir $resolvedDir -HubDir $hubDir)) {
                    Write-Host "  [WhatIf] $change" -ForegroundColor DarkYellow
                }
                if ($BranchAndCommit) { Write-Host "  [WhatIf] commit  on branch chore/agent-governance" -ForegroundColor DarkYellow }
                return
            }

            Write-Host "⚡ Reconciling governance and guardrails..." -ForegroundColor Green

            # 2.5 Branch Isolation: If BranchAndCommit is requested, isolate branch before modifying any files
            if ($BranchAndCommit) {
                $currentBranch = (git --no-pager branch --show-current).Trim()
                if ($currentBranch -in @("main", "master") -or $currentBranch -notmatch '^(feat|fix|patch|hotfix|refactor|chore|test)/') {
                    $branchExists = (git --no-pager branch --list "chore/agent-governance")
                    if ($branchExists) {
                        git checkout chore/agent-governance 2>$null | Out-Null
                    } else {
                        git checkout -b chore/agent-governance 2>$null | Out-Null
                    }
                    if ($LASTEXITCODE -ne 0) { throw 'Governance branch checkout failed; no files were changed.' }
                    Write-Host "  🌿 Checked out branch: $(git --no-pager branch --show-current)" -ForegroundColor Cyan
                }
            }

            # 3. Create target directories
            $agentsRulesDir = Join-Path $resolvedDir ".agents\rules"
            $agentsStateDir = Join-Path $resolvedDir ".agents\state"
            $scriptsDir = Join-Path $resolvedDir "scripts\guardrails"
            $githubDir = Join-Path $resolvedDir ".github"
            $claudeDir = Join-Path $resolvedDir ".claude"
            $geminiDir = Join-Path $resolvedDir ".gemini"
            $docsDir = Join-Path $resolvedDir "docs"

            New-Item -ItemType Directory -Path $agentsRulesDir -Force | Out-Null
            New-Item -ItemType Directory -Path $agentsStateDir -Force | Out-Null
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $githubDir -Force | Out-Null
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            New-Item -ItemType Directory -Path $geminiDir -Force | Out-Null

            # 4. Preserve every custom instruction file before governance overwrites or relinks it
            $templateAgentsContent = ((Get-Content (Join-Path $hubDir "AGENTS.md") -Raw) -replace "`r`n", "`n").Trim()
            # Earlier hub versions of the managed contract share its title line; they are replaced, not archived.
            $contractTitle = ($templateAgentsContent -split "`n")[0].Trim()
            $legacyPath = Join-Path $docsDir "LEGACY-AGENT-NOTES.md"
            $legacyContent = if (Test-Path $legacyPath) { (Get-Content $legacyPath -Raw) -replace "`r`n", "`n" } else { "" }
            $lockPath = Join-Path $resolvedDir ".agent-governance.lock"
            $previousLock = if (Test-Path $lockPath) { Get-Content $lockPath -Raw | ConvertFrom-Json } else { $null }
            $archivedContents = [System.Collections.Generic.HashSet[string]]::new()
            $archiveSections = [System.Collections.Generic.List[string]]::new()
            $hasPreservedLegacy = $false

            foreach ($instructionFile in @("AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md")) {
                $instructionPath = Join-Path $resolvedDir $instructionFile
                if (-not (Test-Path $instructionPath)) { continue }
                $content = ([string](Get-Content $instructionPath -Raw) -replace "`r`n", "`n").Trim()
                if (-not $content -or $content -eq $templateAgentsContent -or $content -eq '@AGENTS.md') { continue }
                if ($content.StartsWith($contractTitle)) {
                    # A managed contract is replaced unless the lock proves the team edited it after the last sync.
                    $lockedHash = if ($previousLock) { [string]$previousLock.files.$instructionFile } else { '' }
                    if (-not $lockedHash -or $lockedHash -eq (Get-NormalizedHash -Path $instructionPath)) { continue }
                }
                # Hard-linked copies share content, and earlier syncs may already hold it.
                if ($legacyContent.Contains($content) -or -not $archivedContents.Add($content)) { continue }

                $archiveSections.Add(("## Archived from ``{0}```n`n{1}" -f $instructionFile, $content))
                Write-Host "  🛡️ Preserved pre-existing custom $instructionFile into docs/LEGACY-AGENT-NOTES.md"
            }

            if ($archiveSections.Count -gt 0) {
                New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
                $legacyHeader = if ($legacyContent.Trim()) {
                    $legacyContent.TrimEnd()
                } else {
                    "# Legacy Agent Notes`n`nInstructions that existed before Agent Governance managed these files, preserved verbatim."
                }
                Set-Utf8LfContent -Path $legacyPath -Content ($legacyHeader + "`n`n" + ($archiveSections -join "`n`n"))
                $hasPreservedLegacy = $true
            }

            # 5. Copy canonical rules and scripts from Hub.
            # Delete-then-copy: legacy syncs hard-linked CLAUDE.md and copilot-instructions.md to AGENTS.md,
            # and writing through a hard link would silently rewrite every linked name.
            foreach ($rootFile in @("AGENTS.md", "lefthook.yml")) {
                $dest = Join-Path $resolvedDir $rootFile
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
                Copy-Item (Join-Path $hubDir $rootFile) $dest
            }
            Copy-Item (Join-Path $hubDir ".agents\rules\*") $agentsRulesDir -Force
            Copy-Item (Join-Path $hubDir "scripts\guardrails\*") $scriptsDir -Force

            # 5b. Agent-native enforcement: Claude Code (deny rules, OS sandbox, Bash guard), Codex (sandbox,
            # approvals), Gemini CLI (AGENTS.md context, confirmations). Managed while unmodified.
            # The Gemini JSON an earlier engine wrote inline counts as an engine version, not a team edit.
            $legacyGeminiSettings = "{`n  `"context`": {`n    `"fileName`": [`"AGENTS.md`", `"GEMINI.md`"]`n  }`n}`n"
            $managedToolFiles = [System.Collections.Generic.List[string]]::new()
            foreach ($toolFile in @('.claude/settings.json', '.gemini/settings.json', '.codex/config.toml')) {
                $legacy = if ($toolFile -eq '.gemini/settings.json') { @($legacyGeminiSettings) } else { @() }
                $result = Sync-ManagedToolFile -HubDir $hubDir -RepoDir $resolvedDir -RelativePath $toolFile -PreviousLock $previousLock -LegacyContent $legacy
                switch ($result.Action) {
                    'installed' { Write-Host "  ✔️ Installed agent settings: $toolFile" }
                    'updated' { Write-Host "  ✔️ Updated unmodified $toolFile to the current hub version" }
                    'kept' { Write-Warning "Kept team-edited $toolFile; merge template/$toolFile into it for the current agent guardrails." }
                }
                if ($result.Managed) { $managedToolFiles.Add($toolFile) }
            }

            # 5c. Server-side gate: managed caller workflow pinned to a pushed, clean hub commit.
            # A same-named file without the managed marker belongs to the team and is never replaced.
            $callerWorkflowPath = Join-Path $githubDir "workflows" "agent-governance.yml"
            $callerWorkflow = Get-CallerWorkflow -HubDir $hubDir -RepoDir $resolvedDir
            $callerIsManaged = -not (Test-Path -LiteralPath $callerWorkflowPath) -or
                ([System.IO.File]::ReadAllText($callerWorkflowPath) -match '(?m)^# Managed by agent-governance')
            if (-not $callerIsManaged) {
                Write-Warning "Kept existing unmanaged .github/workflows/agent-governance.yml; rename it to let the sync manage the governance gate."
            } elseif (-not $callerWorkflow.Content) {
                Write-Warning "Did not update .github/workflows/agent-governance.yml: $($callerWorkflow.Reason). Push the hub and re-sync."
            } else {
                New-Item -ItemType Directory -Path (Split-Path -Parent $callerWorkflowPath) -Force | Out-Null
                Set-Utf8LfContent -Path $callerWorkflowPath -Content $callerWorkflow.Content
                Write-Host "  ✔️ Pinned governance gate workflow to the hub commit (.github/workflows/agent-governance.yml)"
            }

            # 6. Auto-detect stack & generate rich PROJECT.md if missing or unpopulated
            $targetProjectFile = Join-Path $resolvedDir "PROJECT.md"
            $shouldGenerateProject = $true
            if (Test-Path $targetProjectFile) {
                $existingProject = Get-Content $targetProjectFile -Raw
                if (-not ($existingProject -match '<e\.g\.,' -or $existingProject -match '<project-name>')) {
                    $shouldGenerateProject = $false

                    # Reconcile Section 0 if missing and operational handover / lessons learned exist
                    if ($existingProject -notmatch '## 0\.\s+Operational Context') {
                        $stack = Get-ProjectStack -targetDir $resolvedDir -repoName $repoName
                        $hasLegacy = (Test-Path (Join-Path $docsDir "LEGACY-AGENT-NOTES.md")) -or $hasPreservedLegacy
                        $hasHandover = [bool]$stack.OperationalHandover
                        $hasLessons = [bool]$stack.LessonsLearned

                        if ($hasHandover -or $hasLessons -or $hasLegacy) {
                            $sec0 = [System.Collections.Generic.List[string]]::new()
                            $sec0.Add("## 0. Operational Context & Historical Directives")
                            $sec0.Add("")
                            if ($hasHandover) {
                                $sec0.Add("> [!IMPORTANT]")
                                $sec0.Add(("> Authoritative production architecture and live operational state is documented in [``{0}``]({0})." -f $stack.OperationalHandover))
                                $sec0.Add("> Coding agents MUST consult this document for domain invariants, service tiers, and deployment conventions.")
                                $sec0.Add("")
                            }
                            if ($hasLessons) {
                                $sec0.Add("> [!WARNING]")
                                $sec0.Add(("> Critical domain traps and anti-regression directives are documented in [``{0}``]({0})." -f $stack.LessonsLearned))
                                $sec0.Add("> Agents MUST verify implementation plans against these lessons before proposing code or configuration changes.")
                                $sec0.Add("")
                            }
                            if ($hasLegacy) {
                                $sec0.Add("> [!NOTE]")
                                $sec0.Add("> Pre-existing custom repository instructions were archived to [`docs/LEGACY-AGENT-NOTES.md`](docs/LEGACY-AGENT-NOTES.md).")
                                $sec0.Add("> Agents MUST consult this document for historical architectural context, design decisions, and domain conventions.")
                                $sec0.Add("")
                            }
                            $sec0.Add("---")
                            $sec0.Add("")
                            $sec0Block = ($sec0 -join "`n") + "`n"

                            if ($existingProject -match '(?m)^## 1\.') {
                                $updatedProject = $existingProject -replace '(?m)^## 1\.', ($sec0Block + "## 1.")
                            } else {
                                $updatedProject = $existingProject.TrimEnd() + "`n`n" + $sec0Block
                            }
                            Set-Utf8LfContent -Path $targetProjectFile -Content $updatedProject
                            Write-Host "  ✔️ Reconciled Section 0 Triad Hierarchy into existing PROJECT.md" -ForegroundColor Green
                        } else {
                            Write-Host "  ✔️ Preserved existing customized PROJECT.md"
                        }
                    } else {
                        Write-Host "  ✔️ Preserved existing customized PROJECT.md"
                    }
                }
            }

            if ($shouldGenerateProject) {
                $stack = Get-ProjectStack -targetDir $resolvedDir -repoName $repoName
                $pMd = [System.Collections.Generic.List[string]]::new()
                $pMd.Add("# Project Specification & Architecture: $($stack.Name)")
                $pMd.Add("")
                $pMd.Add("This file defines repository-specific architecture, runbooks, and conventions.")
                $pMd.Add("It is consulted by coding agents alongside the universal operating contract (`AGENTS.md`).")
                $pMd.Add("")

                $hasLegacy = (Test-Path (Join-Path $docsDir "LEGACY-AGENT-NOTES.md")) -or $hasPreservedLegacy
                $hasHandover = [bool]$stack.OperationalHandover
                $hasLessons = [bool]$stack.LessonsLearned

                if ($hasHandover -or $hasLessons -or $hasLegacy) {
                    $pMd.Add("---")
                    $pMd.Add("")
                    $pMd.Add("## 0. Operational Context & Historical Directives")
                    $pMd.Add("")

                    if ($hasHandover) {
                        $pMd.Add("> [!IMPORTANT]")
                        $pMd.Add(("> Authoritative production architecture and live operational state is documented in [``{0}``]({0})." -f $stack.OperationalHandover))
                        $pMd.Add("> Coding agents MUST consult this document for domain invariants, service tiers, and deployment conventions.")
                        $pMd.Add("")
                    }

                    if ($hasLessons) {
                        $pMd.Add("> [!WARNING]")
                        $pMd.Add(("> Critical domain traps and anti-regression directives are documented in [``{0}``]({0})." -f $stack.LessonsLearned))
                        $pMd.Add("> Agents MUST verify implementation plans against these lessons before proposing code or configuration changes.")
                        $pMd.Add("")
                    }

                    if ($hasLegacy) {
                        $pMd.Add("> [!NOTE]")
                        $pMd.Add("> Pre-existing custom repository instructions were archived to [`docs/LEGACY-AGENT-NOTES.md`](docs/LEGACY-AGENT-NOTES.md).")
                        $pMd.Add("> Agents MUST consult this document for historical architectural context, design decisions, and domain conventions.")
                        $pMd.Add("")
                    }
                }

                $pMd.Add("---")
                $pMd.Add("")
                $pMd.Add("## 1. Project Overview & Tech Stack")
                $pMd.Add("")
                $pMd.Add("- **Repository Name:** $($stack.Name)")
                $pMd.Add("- **Detected Stack:** $($stack.PrimaryStack)")
                $pMd.Add("- **Frameworks / Platforms:** $(if ($stack.Frameworks) { $stack.Frameworks } else { 'Standard / Native' })")
                $pMd.Add("- **Package Manager(s):** $(if ($stack.PackageManagers) { $stack.PackageManagers } else { 'None detected' })")
                $pMd.Add("")
                $pMd.Add("---")
                $pMd.Add("")
                $pMd.Add("## 2. Development Runbook & Commands")
                $pMd.Add("")

                if ($stack.Runbook.Count -gt 0) {
                    foreach ($key in $stack.Runbook.Keys) {
                        $val = $stack.Runbook[$key]
                        $pMd.Add("- **$($key):** " + '`' + $val + '`')
                    }
                } else {
                    $pMd.Add("- Document local start, lint, and test commands here.")
                }

                $pMd.Add("")
                $pMd.Add("---")
                $pMd.Add("")
                $pMd.Add("## 3. Key Directories & Architecture Map")
                $pMd.Add("")
                $pMd.Add("- Standard repository layout. Consult existing source tree for module structure.")
                $pMd.Add("- `WORKING.md`: Ephemeral session continuity ledger (local working memory, shielded from git).")
                $pMd.Add("- `.agents/state/`: Branch-grounded state archive for multi-branch session persistence.")

                Set-Utf8LfContent -Path $targetProjectFile -Content ($pMd -join "`n")
                Write-Host "  ✔️ Auto-detected stack ($($stack.PrimaryStack)) and generated tailored PROJECT.md"
            }

            # 7. Per-tool instruction entry points as plain files (hard links do not survive git checkouts).
            # Claude Code expands the @AGENTS.md import; Copilot Chat needs a real copy.
            $claudeEntry = Join-Path $resolvedDir "CLAUDE.md"
            if (Test-Path -LiteralPath $claudeEntry) { Remove-Item -LiteralPath $claudeEntry -Force }
            Set-Utf8LfContent -Path $claudeEntry -Content "@AGENTS.md"
            $copilotEntry = Join-Path $githubDir "copilot-instructions.md"
            if (Test-Path -LiteralPath $copilotEntry) { Remove-Item -LiteralPath $copilotEntry -Force }
            Copy-Item (Join-Path $hubDir "AGENTS.md") $copilotEntry

            # 8. Merge .gitignore rules non-destructively
            $targetGitignore = Join-Path $resolvedDir ".gitignore"
            if (Test-Path $targetGitignore) {
                $existingIgnore = [string](Get-Content $targetGitignore -Raw)
                $hubIgnore = Get-Content (Join-Path $hubDir ".gitignore") -Raw
                $missingEntries = Get-MissingEntry -ExistingText $existingIgnore -CanonicalText $hubIgnore
                if ($missingEntries.Count -gt 0) {
                    $newIgnore = $existingIgnore.TrimEnd() + "`n`n# Added by Agent Governance`n" + ($missingEntries -join "`n") + "`n"
                    Set-Utf8LfContent -Path $targetGitignore -Content $newIgnore
                    Write-Host "  ✔️ Added $($missingEntries.Count) missing shield rules to .gitignore"
                }
            } else {
                Copy-Item (Join-Path $hubDir ".gitignore") $targetGitignore -Force
                Write-Host "  ✔️ Initialized .gitignore from canonical shield"
            }

            # 9. Merge .gitattributes non-destructively
            $targetGitattrs = Join-Path $resolvedDir ".gitattributes"
            $hubGitattrs = Join-Path $hubDir ".gitattributes"
            if (Test-Path $hubGitattrs) {
                if (Test-Path $targetGitattrs) {
                    $existingAttrs = [string](Get-Content $targetGitattrs -Raw)
                    $hubAttrs = Get-Content $hubGitattrs -Raw
                    $missingAttrs = Get-MissingEntry -ExistingText $existingAttrs -CanonicalText $hubAttrs
                    if ($missingAttrs.Count -gt 0) {
                        $newAttrs = $existingAttrs.TrimEnd() + "`n`n# Added by Agent Governance`n" + ($missingAttrs -join "`n") + "`n"
                        Set-Utf8LfContent -Path $targetGitattrs -Content $newAttrs
                        Write-Host "  ✔️ Added $($missingAttrs.Count) missing attributes to .gitattributes"
                    }
                } else {
                    Copy-Item $hubGitattrs $targetGitattrs -Force
                    Write-Host "  ✔️ Initialized .gitattributes from canonical shield"
                }
            }


            # 10. Tool-native wiring with real files (junctions are Windows-only and fragile in git).
            $claudeRules = Join-Path $claudeDir "rules"
            $geminiRules = Join-Path $geminiDir "rules"
            foreach ($legacyLink in @($claudeRules, $geminiRules)) {
                $linkItem = Get-Item -LiteralPath $legacyLink -Force -ErrorAction SilentlyContinue
                # Captured before deletion: LinkType is evaluated lazily and reads $null afterwards.
                $linkType = if ($linkItem) { [string]$linkItem.LinkType } else { '' }
                if ($linkType) {
                    # Non-recursive delete removes only the link, never the canonical .agents/rules behind it.
                    [System.IO.Directory]::Delete($legacyLink, $false)
                    Write-Host "  ✔️ Removed legacy $($linkType.ToLower()) $([System.IO.Path]::GetRelativePath($resolvedDir, $legacyLink))"
                }
            }
            New-Item -ItemType Directory -Path $claudeRules -Force | Out-Null
            Copy-Item (Join-Path $hubDir ".agents" "rules" "*") $claudeRules -Force
            # Gemini CLI reads AGENTS.md through .gemini/settings.json (step 5b); it has no rules directory.

            # 11. Intelligent Git Hook Reconciliation
            Sync-GitHook -targetDir $resolvedDir

            # 12. Scoped Downstream Formatter Execution
            Invoke-DownstreamFormatting -targetDir $resolvedDir

            # 12b. Lock manifest: hub version + normalized SHA-256 of every managed file (sorted, deterministic)
            $hubRepoRoot = Split-Path -Parent $hubDir
            $hubCommit = "$(git -C $hubRepoRoot rev-parse HEAD 2>$null)".Trim()
            $hubDirty = [bool]"$(git -C $hubRepoRoot status --porcelain -- template 2>$null)".Trim()
            $lockFiles = [ordered]@{}
            foreach ($file in (Get-ManagedFile -HubDir $hubDir | Sort-Object Target)) {
                $managedPath = Join-Path $resolvedDir $file.Target
                if (Test-Path -LiteralPath $managedPath -PathType Leaf) {
                    $lockFiles[$file.Target] = Get-NormalizedHash -Path $managedPath
                }
            }
            foreach ($toolFile in $managedToolFiles) {
                $lockFiles[$toolFile] = Get-NormalizedHash -Path (Join-Path $resolvedDir $toolFile)
            }
            if ((Test-Path -LiteralPath $callerWorkflowPath) -and ([System.IO.File]::ReadAllText($callerWorkflowPath) -match '(?m)^# Managed by agent-governance')) {
                $lockFiles['.github/workflows/agent-governance.yml'] = Get-NormalizedHash -Path $callerWorkflowPath
            }
            $lockDocument = [ordered]@{
                version = 1
                hub     = [ordered]@{ commit = $(if ($hubCommit) { $hubCommit } else { $null }); dirty = $hubDirty }
                files   = $lockFiles
            }
            # Put digests on their own indented lines: paths such as detect-secrets.ps1 are
            # labels, not credential assignments. Keep the scanner enabled for the entire file.
            $lockJson = ($lockDocument | ConvertTo-Json -Depth 5) -replace '(: )"([0-9a-f]{64})"', ":`n      `"`$2`""
            Set-Utf8LfContent -Path $lockPath -Content $lockJson

            # 12c. Line endings: files stored with CRLF although .gitattributes requires LF.
            $eolCandidates = Get-EolRenormalizeCandidate -RepoDir $resolvedDir
            if ($eolCandidates.Count -gt 0 -and -not $BranchAndCommit) {
                Write-Warning "$($eolCandidates.Count) tracked file(s) are stored with CRLF although .gitattributes requires LF. Normalize them in their own commit: git add --renormalize . && git commit -m 'chore: renormalize line endings to match .gitattributes'"
            }

            # 13. Optional Safe Conventional Commits
            if ($BranchAndCommit) {
                if ($eolCandidates.Count -gt 0) {
                    # Content-neutral, separate commit so the governance diff stays reviewable.
                    $pathspecFile = [System.IO.Path]::GetTempFileName()
                    try {
                        [System.IO.File]::WriteAllText($pathspecFile, ($eolCandidates -join "`0") + "`0")
                        git -c core.quotepath=off add --renormalize --pathspec-from-file=$pathspecFile --pathspec-file-nul
                        if ($LASTEXITCODE -ne 0) { throw 'Failed to stage line-ending renormalization.' }
                    } finally {
                        Remove-Item -LiteralPath $pathspecFile -Force -ErrorAction SilentlyContinue
                    }
                    git --no-pager diff --cached --quiet --ignore-cr-at-eol
                    if ($LASTEXITCODE -ne 0) {
                        git reset -q
                        throw 'Renormalization staged content changes beyond line endings; nothing was committed.'
                    }
                    git commit -m "chore: renormalize line endings to match .gitattributes" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Line-ending renormalization commit failed; changes remain staged for review.' }
                    Write-Host "  ✅ Committed line-ending renormalization for $($eolCandidates.Count) file(s)" -ForegroundColor Green
                }

                $govStatus = (git --no-pager status --porcelain)
                if ($govStatus) {

                    $stageItems = @(
                        "AGENTS.md", "CLAUDE.md", "PROJECT.md", "lefthook.yml",
                        ".agents", ".claude", ".gemini", ".github",
                        ".gitignore", ".gitattributes", ".agent-governance.lock", ".codex",
                        "scripts/guardrails", "docs/LEGACY-AGENT-NOTES.md"
                    )
                    foreach ($item in $stageItems) {
                        if (Test-Path (Join-Path $resolvedDir $item)) {
                            git add -- $item
                            if ($LASTEXITCODE -ne 0) { throw "Failed to stage governance path: $item" }
                        }
                    }
                    if (Test-Path (Join-Path $resolvedDir ".githooks")) {
                        git add -- .githooks
                        if ($LASTEXITCODE -ne 0) { throw 'Failed to stage governance hooks.' }
                    }

                    $staged = (git --no-pager diff --cached --name-only)
                    if ($staged) {
                        git commit -m "chore(governance): install unified agent contract and deterministic guardrails" | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw 'Governance commit failed; changes remain staged for review.' }
                        Write-Host "  ✅ Auto-committed governance baseline to branch: $(git --no-pager branch --show-current)" -ForegroundColor Green
                    }
                }
            }

            Write-Host "  🎉 $repoName is fully governed, reconciled, and armored!" -ForegroundColor Green
        } finally {
            Pop-Location
        }
    }

    # 'hooks': install only the local git gate. Hooks are not versioned, so a merged governance PR never
    # installs them; this touches nothing git tracks and is therefore safe on a tree with work in progress.
    function Install-GovernanceHook {
        param([Parameter(Mandatory = $true)][string]$targetDir)
        $gitDir = "$(git -C $targetDir rev-parse --git-dir 2>$null)".Trim()
        if (-not $gitDir) {
            Write-Warning "Skipped: $targetDir is not a git repository."
            return
        }
        # Versioned hooks (e.g. .githooks) are part of the repository: changing them here would leave an
        # uncommitted edit, possibly on main. They are updated through the hub's sync pull requests instead.
        $root = "$(git -C $targetDir rev-parse --show-toplevel)".Trim()
        $configured = "$(git -C $root config --local core.hooksPath 2>$null)".Trim()
        $hookRel = if ($configured) { [System.IO.Path]::GetRelativePath($root, [System.IO.Path]::GetFullPath($configured, $root)) } else { '.githooks' }
        $trackedHooks = if ($hookRel -notmatch '^\.\.([\\/]|$)' -and -not [System.IO.Path]::IsPathRooted($hookRel)) {
            @(git -C $root ls-files -- "$hookRel/pre-commit" "$hookRel/pre-push" 2>$null)
        } else { @() }
        if ($trackedHooks.Count -gt 0) {
            Write-Warning "Skipped: $root keeps its hooks in the tracked '$hookRel' directory, so updating them is a versioned change. Merge the hub's sync pull request (or run a full Sync-AgentGovernance on a branch) to update them."
            return
        }
        if (-not $PSCmdlet.ShouldProcess($targetDir, "Install governance git hooks")) { return }
        Sync-GitHook -targetDir $root
    }

    if ($All) {
        if (-not $FleetRoot) {
            $FleetRoot = if ($env:AGENT_GOVERNANCE_FLEET_ROOT) { $env:AGENT_GOVERNANCE_FLEET_ROOT } else { Split-Path -Parent $PSScriptRoot }
        }
        $hubRepoRoot = (Resolve-Path (Split-Path -Parent $hubDir)).Path
        $repos = Get-ChildItem -Path $FleetRoot -Directory |
            Where-Object { (Test-Path (Join-Path $_.FullName ".git")) -and $_.FullName -ne $hubRepoRoot }
        Write-Host "🚀 Running Sync-AgentGovernance across $($repos.Count) repositories..." -ForegroundColor Magenta
        foreach ($repo in $repos) {
            if ($Action -eq 'hooks') { Install-GovernanceHook -targetDir $repo.FullName } else { Sync-SingleRepo -targetDir $repo.FullName }
        }
    } elseif ($Action -eq 'hooks') {
        Install-GovernanceHook -targetDir $RepoPath
    } else {
        Sync-SingleRepo -targetDir $RepoPath
    }
}
