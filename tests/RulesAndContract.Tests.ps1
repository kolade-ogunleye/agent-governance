BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RulesDir = Join-Path $RepoRoot 'template' '.agents' 'rules'
    $script:Contract = Join-Path $RepoRoot 'template' 'AGENTS.md'

    function Get-FrontmatterPath {
        param([Parameter(Mandatory = $true)][string]$Path)
        # Returns the globs listed under a leading YAML 'paths:' key, or an empty array.
        $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
        # Callers wrap the result in @(...); an empty result then counts as 0.
        if ($text -notmatch '(?s)\A---\n(.*?)\n---\n') { return }
        [regex]::Matches($Matches[1], '(?m)^\s+-\s+"([^"]+)"\s*$') | ForEach-Object { $_.Groups[1].Value }
    }
}

Describe 'Path-scoped rules (progressive disclosure)' {
    It 'ships a language rule file for <Language>' -ForEach @(
        @{ Language = 'typescript' }, @{ Language = 'python' }, @{ Language = 'sql' },
        @{ Language = 'rust' }, @{ Language = 'go' }, @{ Language = 'shell' }
    ) {
        Join-Path $RulesDir "lang-$Language.md" | Should -Exist
    }

    It '<_> declares paths frontmatter so Claude loads it only for matching files' -ForEach @(
        'lang-typescript.md', 'lang-python.md', 'lang-sql.md', 'lang-rust.md', 'lang-go.md', 'lang-shell.md'
    ) {
        @(Get-FrontmatterPath -Path (Join-Path $RulesDir $_)).Count | Should -BeGreaterThan 0
    }

    It '<_> has no paths frontmatter, so it always applies' -ForEach @('languages.md', 'security-performance.md') {
        @(Get-FrontmatterPath -Path (Join-Path $RulesDir $_)).Count | Should -Be 0
    }

    It 'keeps the always-loaded languages.md index short' {
        @(Get-Content (Join-Path $RulesDir 'languages.md')).Count | Should -BeLessOrEqual 20
    }

    It 'indexes every language rule file, and every indexed file exists' {
        $index = Get-Content (Join-Path $RulesDir 'languages.md') -Raw
        $referenced = @([regex]::Matches($index, 'lang-[a-z]+\.md') | ForEach-Object Value | Sort-Object -Unique)
        $shipped = @(Get-ChildItem $RulesDir -Filter 'lang-*.md' | ForEach-Object Name | Sort-Object)
        $referenced | Should -Be $shipped
    }

    It 'scopes TypeScript rules to TypeScript and JavaScript sources' {
        $globs = @(Get-FrontmatterPath -Path (Join-Path $RulesDir 'lang-typescript.md'))
        ($globs -join ' ') | Should -Match '\.\{?ts'
    }
}

Describe 'Universal contract (template/AGENTS.md)' {
    It 'keeps the title line the engine uses to recognise earlier managed versions' {
        (Get-Content $Contract -TotalCount 1) | Should -BeExactly '# Repository Agent Operating Contract (RFC 2119)'
    }

    It 'stays within the 80-line budget the README promises' {
        @(Get-Content $Contract).Count | Should -BeLessOrEqual 80
    }

    It 'references only rule files that exist' {
        $refs = [regex]::Matches((Get-Content $Contract -Raw), '\.agents/rules/([A-Za-z0-9_.-]+\.md)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($ref in $refs) { Join-Path $RulesDir $ref | Should -Exist }
    }

    It 'forbids bypassing or editing the managed guardrails' {
        $text = Get-Content $Contract -Raw
        $text | Should -Match '--no-verify'
        $text | Should -Match 'scripts/guardrails/'
    }

    It 'no longer halts on the agent''s own in-progress changes' {
        (Get-Content $Contract -Raw) | Should -Match 'did not make'
    }

    It 'is mirrored exactly by the hub''s own AGENTS.md and Copilot copy' {
        $expected = Get-Content $Contract -Raw
        Get-Content (Join-Path $RepoRoot 'AGENTS.md') -Raw | Should -BeExactly $expected
        Get-Content (Join-Path $RepoRoot '.github' 'copilot-instructions.md') -Raw | Should -BeExactly $expected
        (Get-Content (Join-Path $RepoRoot 'CLAUDE.md') -Raw).Trim() | Should -BeExactly '@AGENTS.md'
    }
}

Describe 'check-drift.ps1 rule coverage' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:Hub = Join-Path $TestDrive ("hub-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $Hub '.agents/rules') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Repo '.agents/rules') -Force | Out-Null
        $script:OriginalHub = $env:AGENT_GOVERNANCE_HUB
        $env:AGENT_GOVERNANCE_HUB = $Hub
    }

    AfterEach {
        $env:AGENT_GOVERNANCE_HUB = $OriginalHub
    }

    It 'reports drift in a rule file the hub added after the script was written' {
        [System.IO.File]::WriteAllText((Join-Path $Hub '.agents/rules/lang-zig.md'), "# Zig`n`nUse errdefer.`n")
        [System.IO.File]::WriteAllText((Join-Path $Repo '.agents/rules/lang-zig.md'), "# Zig`n`nOld rule.`n")
        $guard = Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'check-drift.ps1'
        (Invoke-Guardrail -ScriptPath $guard -RepoPath $Repo).Output | Should -Match 'drifted from the Central Hub'
    }
}
