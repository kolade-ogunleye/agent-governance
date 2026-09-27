# check-markdown.ps1 - Markdown & Line-Ending Guardrail (RFC 2119)
# Validates LF line endings and zero-BOM UTF-8 on markdown files (Prettier formatting is checked in CI).

$ErrorActionPreference = 'Stop'

$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { exit 0 }

# Find modified or staged markdown files
$stagedFiles = (git -C $repoRoot diff --cached --name-only --diff-filter=ACM 2>$null) -split "`r?`n" | Where-Object { $_ -match '\.md$' -or $_ -match '\.template$' }

if (-not $stagedFiles -or $stagedFiles.Count -eq 0 -or ($stagedFiles.Count -eq 1 -and [string]::IsNullOrWhiteSpace($stagedFiles[0]))) {
    # If no staged markdown, check all tracked markdown files in small repos, or skip
    $mdFiles = Get-ChildItem -Path $repoRoot -Filter "*.md" -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|vendor)[\\/]' }
} else {
    $mdFiles = $stagedFiles | ForEach-Object {
        $p = Join-Path $repoRoot $_
        if (Test-Path $p) { Get-Item $p }
    }
}

$hasErrors = $false

foreach ($file in $mdFiles) {
    if (-not $file -or -not (Test-Path $file.FullName)) { continue }

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Host "❌ [Markdown Guard] $($file.Name) contains UTF-8 BOM. UTF-8 without BOM required." -ForegroundColor Red
        $hasErrors = $true
    }

    # Check for CRLF bytes (0x0D followed by 0x0A)
    for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
        if ($bytes[$i] -eq 0x0D -and $bytes[$i + 1] -eq 0x0A) {
            Write-Host "❌ [Markdown Guard] $($file.Name) contains CRLF line endings. Unix LF (\n) required." -ForegroundColor Red
            $hasErrors = $true
            break
        }
    }
}

if ($hasErrors) {
    Write-Host "`n⚠️ Re-save as UTF-8 without BOM with LF line endings (e.g. 'npx prettier --write <file>' or 'git add --renormalize .')." -ForegroundColor Yellow
    exit 1
}

exit 0
