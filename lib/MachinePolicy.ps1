# Shared by the machine-policy installers (Install-ClaudeManagedSettings.ps1, Install-CodexRequirements.ps1).
$ErrorActionPreference = 'Stop'

function Test-AdministratorOnlyWrite {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    # True when only administrators can modify $Path. A directory a user can write lets that user replace a file
    # inside it, so callers check the directory as well as the files.
    if ($IsWindows) {
        # By SID, so the check does not depend on the display language: SYSTEM, Administrators, TrustedInstaller.
        $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        # Only bits that allow a change: WriteData/CreateFiles, AppendData, WriteExtendedAttributes,
        # DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions, TakeOwnership, and the generic
        # GENERIC_ALL and GENERIC_WRITE bits. Modify and FullControl include these; read-and-execute does not.
        $writeMask = 2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288 -bor 0x10000000 -bor 0x40000000
        $writers = foreach ($rule in (Get-Acl -LiteralPath $Path).Access) {
            if ($rule.AccessControlType -ne 'Allow' -or -not ([long]$rule.FileSystemRights -band $writeMask)) { continue }
            # An inherit-only entry applies to children, not to this item.
            if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            $sid = try { $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { "$($rule.IdentityReference)" }
            if ($sid -notin $trusted) { "$($rule.IdentityReference)" }
        }
        $writers = @($writers | Sort-Object -Unique)
        return [pscustomobject]@{ Passed = ($writers.Count -eq 0); Detail = $(if ($writers) { "also writable by: $($writers -join ', ')" } else { 'administrators only' }) }
    }
    $owner = if ($IsMacOS) { "$(& stat -f '%u' $Path)".Trim() } else { "$(& stat -c '%u' $Path)".Trim() }
    $mode = [System.IO.File]::GetUnixFileMode($Path)
    $looseBits = [System.IO.UnixFileMode]'GroupWrite, OtherWrite'
    $problems = @()
    if ($owner -ne '0') { $problems += "owner uid $owner, not root" }
    if ($mode -band $looseBits) { $problems += "group or other can write ($mode)" }
    return [pscustomobject]@{ Passed = ($problems.Count -eq 0); Detail = $(if ($problems) { $problems -join '; ' } else { 'root only' }) }
}
