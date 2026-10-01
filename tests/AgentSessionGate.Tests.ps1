BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '..' 'Sync-AgentGovernance.ps1')
}

Describe 'Engine-installed git gate in an agent session' {
    BeforeEach {
        $script:Repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Sync-AgentGovernance -RepoPath $Repo 6>$null 3>$null
        git -C $Repo checkout --quiet -b feat/gate
        [System.IO.File]::WriteAllText((Join-Path $Repo 'work.txt'), "work`n")
        git -C $Repo add work.txt
        # A PATH with git and the shell but no lefthook: the fail-closed branch of the hook block.
        $dirs = [System.Collections.Generic.List[string]]::new()
        foreach ($exe in @('git', 'sh')) {
            $cmd = Get-Command $exe -ErrorAction SilentlyContinue
            if ($cmd) { $dirs.Add((Split-Path -Parent $cmd.Source)) }
        }
        foreach ($d in @('/usr/bin', '/bin')) { if (Test-Path $d) { $dirs.Add($d) } }
        $script:MinimalPath = ($dirs | Select-Object -Unique) -join [System.IO.Path]::PathSeparator
        $script:SavedPath = $env:PATH
        $script:SavedMarker = $env:CLAUDECODE
    }

    AfterEach {
        $env:PATH = $SavedPath
        if ($null -eq $SavedMarker) { Remove-Item env:CLAUDECODE -ErrorAction SilentlyContinue } else { $env:CLAUDECODE = $SavedMarker }
    }

    It 'blocks a commit when an agent marker is set and Lefthook is missing (fail closed)' -Skip:$IsWindows {
        $env:PATH = $MinimalPath
        if (Get-Command lefthook -ErrorAction SilentlyContinue) { Set-ItResult -Skipped -Because 'lefthook is installed in a system directory on this machine' }
        $env:CLAUDECODE = '1'

        $out = git -C $Repo commit --quiet -m 'feat: try' 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'Agent session detected without active Lefthook guardrails'
        "$(git -C $Repo log --oneline)".Trim() | Should -Not -Match 'feat: try'
    }

    It 'warns and lets a human commit through when Lefthook is missing (fail open for people)' -Skip:$IsWindows {
        $env:PATH = $MinimalPath
        if (Get-Command lefthook -ErrorAction SilentlyContinue) { Set-ItResult -Skipped -Because 'lefthook is installed in a system directory on this machine' }
        Remove-Item env:CLAUDECODE -ErrorAction SilentlyContinue

        $out = git -C $Repo commit --quiet -m 'feat: human' 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match "'lefthook' is not installed"
    }
}
