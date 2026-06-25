## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail (defaults to "No Description")
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "tsprint-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ($null -eq $Description -or $Description -eq "") {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

<#
.SYNOPSIS
    Silently uninstall TSPrint Client.

.DESCRIPTION
    • Looks for the vendor-supplied Inno Setup uninstaller (unins000.exe).
    • Falls back to the uninstall string in the registry if the path isn’t found.
    • If TSPrint was deployed with Chocolatey, optionally calls choco uninstall.
    • Runs everything with /SILENT so no UI appears and no reboot is triggered.
#>

$TryChocolatey = $False

function Invoke-Uninstaller ($uninstallCmd) {
    if (-not $uninstallCmd) { return $false }

    # Split quoted path + arguments that may come from the registry
    $regex = '^(?:")?([^"]+?\.exe)(?:")?\s*(.*)$'
    if ($uninstallCmd -match $regex) {
        $exe  = $matches[1]
        $args = if ($matches[2]) { $matches[2] } else { '/SILENT' }
        Write-Verbose "Running: `"$exe`" $args"
        Start-Process -FilePath $exe -ArgumentList $args -Wait
        return $true
    }
    return $false
}

# 1) Try the standard install folders first
$guessPaths = @(
    "${env:ProgramFiles(x86)}\TerminalWorks\TSPrint Client\unins000.exe",
    "${env:ProgramFiles}\TerminalWorks\TSPrint Client\unins000.exe",
    "${env:ProgramFiles(x86)}\TerminalWorks\TSPrint\unins000.exe",
    "${env:ProgramFiles}\TerminalWorks\TSPrint\unins000.exe"
)
$uninstallFound = $guessPaths |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if ($uninstallFound) {
    Invoke-Uninstaller "`"$uninstallFound`" /SILENT"
    return
}

# 2) Fall back to the registry (both 32- and 64-bit views)
$regQuery = Get-ItemProperty HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* ,
                             HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* |
            Where-Object { $_.DisplayName -like 'TSPrint Client*' -or $_.DisplayName -like 'TSPrint*' } |
            Select-Object -ExpandProperty UninstallString -First 1

if (Invoke-Uninstaller $regQuery) { return }

# 3) If requested, try Chocolatey
if ($TryChocolatey -and (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host 'Attempting to uninstall via Chocolatey…'
    choco uninstall tsprintclient -y
    return
}

Write-Warning 'TSPrint Client was not detected on this system.'


Stop-Transcript
