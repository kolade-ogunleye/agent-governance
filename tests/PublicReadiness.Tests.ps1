BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $script:Workflows = @(Get-ChildItem (Join-Path $RepoRoot '.github' 'workflows') -Filter '*.yml' | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Text = [System.IO.File]::ReadAllText($_.FullName) }
        })
}

# The hub is meant to be public: anyone can open a pull request, and workflow logs are public.
Describe 'Public readiness of the hub workflows' {
    It 'pins every action in <Name> to a full commit SHA' -ForEach @(
        Get-ChildItem (Join-Path $PSScriptRoot '..' '.github' 'workflows') -Filter '*.yml' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        foreach ($uses in [regex]::Matches([System.IO.File]::ReadAllText($Path), '(?m)^\s+(?:-\s+)?uses:\s+(\S+)')) {
            $ref = $uses.Groups[1].Value
            if ($ref.StartsWith('./')) { continue }
            $ref | Should -Match '@[0-9a-f]{40}$' -Because "$Name uses $ref"
        }
    }

    It 'never uses pull_request_target, which runs fork code with secrets' {
        foreach ($w in $Workflows) { $w.Text | Should -Not -Match '(?m)^\s+pull_request_target\s*:' -Because $w.Name }
    }

    It 'gives every workflow a read-only default token' {
        foreach ($w in $Workflows) { $w.Text | Should -Match '(?m)^permissions:\s*\n\s+contents: read' -Because $w.Name }
    }

    It 'scans the workflows with CodeQL only where it is free (a public repository)' {
        $codeql = ($Workflows | Where-Object Name -eq 'codeql.yml').Text
        $codeql | Should -Match 'languages: actions'
        $codeql | Should -Match "if: \$\{\{ !github\.event\.repository\.private \}\}"
        $codeql | Should -Match 'security-events: write'
        # A scheduled event has no repository payload, so the private check would not hold there.
        $codeql | Should -Not -Match '(?m)^\s+schedule:'
    }
}

Describe 'Public readiness of the hub documentation' {
    It 'does not describe the private fleet repositories'' technology stacks in the README diagram' {
        $readme = Get-Content (Join-Path $RepoRoot 'README.md') -Raw
        $readme | Should -Not -Match 'WordPress / PHP / npm'
        $readme | Should -Not -Match 'Ansible / PowerShell IaC'
    }
}
