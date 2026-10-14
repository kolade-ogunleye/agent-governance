BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Adapter = Join-Path $RepoRoot 'template' 'scripts' 'guardrails' 'copilot-pretooluse.ps1'
    $script:HookFile = Join-Path $RepoRoot 'template' '.github' 'hooks' 'agent-governance.json'

    function Invoke-Adapter {
        param([Parameter(Mandatory = $true)][string]$Json)
        $out = ($Json | & pwsh -NoProfile -File $Adapter 2>&1) -join "`n"
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    function ConvertTo-CopilotPayload {
        param([string]$Tool = 'bash', [string]$Command, [switch]$ArgsAsString)
        $toolArgs = @{ command = $Command }
        $argsValue = if ($ArgsAsString) { $toolArgs | ConvertTo-Json -Compress } else { $toolArgs }
        return (@{ sessionId = 's'; timestamp = 1704614400000; cwd = '/tmp'; toolName = $Tool; toolArgs = $argsValue } | ConvertTo-Json -Compress)
    }
}

Describe 'Copilot preToolUse adapter for the Bash guard' {
    It 'denies a blocked <Tool> command with exit 2 and a Copilot deny decision (toolArgs as <Form>)' -ForEach @(
        @{ Tool = 'bash'; Command = 'git commit --no-verify -m wip'; Form = 'object'; AsString = $false }
        @{ Tool = 'bash'; Command = 'git commit --no-verify -m wip'; Form = 'JSON string'; AsString = $true }
        @{ Tool = 'bash'; Command = 'git push origin main'; Form = 'object'; AsString = $false }
        @{ Tool = 'powershell'; Command = '$env:LEFTHOOK = "0"; git commit -m wip'; Form = 'object'; AsString = $false }
    ) {
        $r = Invoke-Adapter -Json (ConvertTo-CopilotPayload -Tool $Tool -Command $Command -ArgsAsString:$AsString)
        $r.ExitCode | Should -Be 2
        $decision = $r.Output | ConvertFrom-Json
        $decision.permissionDecision | Should -Be 'deny'
        $decision.permissionDecisionReason | Should -Match 'Agent Governance'
    }

    It 'allows an ordinary <Tool> command silently' -ForEach @(
        @{ Tool = 'bash'; Command = 'git status' }
        @{ Tool = 'powershell'; Command = 'Get-ChildItem' }
    ) {
        $r = Invoke-Adapter -Json (ConvertTo-CopilotPayload -Tool $Tool -Command $Command)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
    }

    It 'leaves non-shell tools alone' {
        (Invoke-Adapter -Json '{"toolName":"edit","toolArgs":{"path":"a.txt"}}').ExitCode | Should -Be 0
    }

    It 'fails closed when it cannot read the payload or the command (<Case>)' -ForEach @(
        @{ Case = 'not JSON'; Json = 'not json' }
        @{ Case = 'shell call without a command'; Json = '{"toolName":"bash","toolArgs":{"cmd":"git status"}}' }
        @{ Case = 'unparseable string arguments'; Json = '{"toolName":"bash","toolArgs":"{not json"}' }
    ) {
        $r = Invoke-Adapter -Json $Json
        $r.ExitCode | Should -Be 2
        ($r.Output | ConvertFrom-Json).permissionDecision | Should -Be 'deny'
    }
}

Describe 'Copilot hook file shipped to every repository' {
    It 'runs the adapter from the repository root for bash and powershell tools only' {
        $hook = Get-Content $HookFile -Raw | ConvertFrom-Json
        $hook.version | Should -Be 1
        $entry = @($hook.hooks.preToolUse)
        $entry.Count | Should -Be 1
        $entry[0].matcher | Should -Be '^(bash|powershell)$'
        $entry[0].type | Should -Be 'command'
        $entry[0].bash | Should -Match 'git rev-parse --show-toplevel.*scripts/guardrails/copilot-pretooluse\.ps1'
        $entry[0].powershell | Should -Match 'git rev-parse --show-toplevel.*scripts/guardrails/copilot-pretooluse\.ps1'
        $entry[0].timeoutSec | Should -BeLessOrEqual 60
    }

    It 'is installed by the sync, recorded in the lock, and protected from agent edits' {
        . (Join-Path $RepoRoot 'Sync-AgentGovernance.ps1')
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'copilot-repo')
        Sync-AgentGovernance -RepoPath $repo 6>$null 3>$null | Out-Null
        $installed = Join-Path $repo '.github' 'hooks' 'agent-governance.json'
        $installed | Should -Exist
        (Get-FileHash $installed).Hash | Should -Be (Get-FileHash $HookFile).Hash
        (Get-Content (Join-Path $repo '.agent-governance.lock') -Raw | ConvertFrom-Json).files.'.github/hooks/agent-governance.json' | Should -Not -BeNullOrEmpty
        Join-Path $repo 'scripts' 'guardrails' 'copilot-pretooluse.ps1' | Should -Exist
        foreach ($settings in 'template/.claude/settings.json', 'managed/claude-code-managed-settings.json') {
            @((Get-Content (Join-Path $RepoRoot $settings) -Raw | ConvertFrom-Json).permissions.deny) | Should -Contain 'Edit(/.github/hooks/agent-governance.json)'
        }
    }
}
