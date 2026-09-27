---
paths:
  - "**/*.{sh,bash}"
  - "**/*.{ps1,psm1,psd1}"
---

# Shell & Scripting Standards (RFC 2119)

1. **Bash:** Script headers MUST include `set -euo pipefail`. ALWAYS double-quote variables (`"$VAR"`). Use `[[ ... ]]` for test conditions.
2. **PowerShell:** Script headers MUST include `$ErrorActionPreference = 'Stop'`. Explicitly invoke child processes with `-NoProfile`.
