#requires -Version 5.1
<#
.SYNOPSIS
    Builds fat (self-contained) PowerShell scripts from modular sources in src/.

.DESCRIPTION
    Walks the SourceRoot recursively, finds every .ps1 file, processes any
    `# %INCLUDE <path-relative-to-repo-root>` marker lines by inlining the
    referenced file's content in place of the marker, and writes the resulting
    fat script to the matching relative path under OutputRoot.

    Marker syntax:

        # %INCLUDE oem-shared/lib/oem-manufacturer-detect.ps1
        # %INCLUDE oem-dell/lib/dell-detection.ps1

    Recursive includes are NOT supported in V1. Lib files cannot themselves
    contain `# %INCLUDE` markers ... the build will fail loudly if it sees one.

.PARAMETER RepoRoot
    Repository root directory. Used to resolve include paths.

.PARAMETER SourceRoot
    Directory containing modular source .ps1 files. Typically <RepoRoot>/src.

.PARAMETER OutputRoot
    Directory where fat scripts will be written. The directory is created if
    it does not exist; existing files at the same path are overwritten.

.PARAMETER StripSrcPrefix
    If set, the leading "src/" segment is stripped from the output path so
    `src/oem-dell/dell-configure.ps1` becomes `oem-dell/dell-configure.ps1`
    in the output. Default: $true.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $SourceRoot,
    [Parameter(Mandatory)] [string] $OutputRoot,
    [bool] $StripSrcPrefix = $true
)

$ErrorActionPreference = 'Stop'

function Expand-Includes {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [switch] $IsIncluded
    )

    $content = Get-Content -Path $Path -Raw
    if ($null -eq $content) { $content = '' }
    $lines = $content -split "`r?`n"
    $output = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in $lines) {
        if ($line -match '^\s*#\s*%INCLUDE\s+(.+?)\s*$') {
            if ($IsIncluded) {
                throw "Recursive %INCLUDE detected in '$Path'. Lib files cannot contain `# %INCLUDE` markers in V1."
            }
            $rel = $matches[1].Trim()
            $includePath = Join-Path -Path $RepoRoot -ChildPath $rel
            if (-not (Test-Path -LiteralPath $includePath)) {
                throw "Include not found: '$rel' (resolved to '$includePath'), referenced from '$Path'."
            }
            $inlined = Expand-Includes -Path $includePath -RepoRoot $RepoRoot -IsIncluded
            $output.Add("# === inlined from $rel ===")
            foreach ($l in ($inlined -split "`r?`n")) {
                $output.Add($l)
            }
            $output.Add("# === end inline ===")
        } else {
            $output.Add($line)
        }
    }

    return ($output -join "`n")
}

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    throw "SourceRoot '$SourceRoot' does not exist."
}

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
}

$sourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter '*.ps1' -File
$built = 0

foreach ($file in $sourceFiles) {
    $relFromRepo = $file.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
    $relFromRepo = $relFromRepo -replace '\\','/'

    $outRel = $relFromRepo
    if ($StripSrcPrefix -and $outRel -match '^src/(.+)$') {
        $outRel = $matches[1]
    }

    $outPath = Join-Path -Path $OutputRoot -ChildPath ($outRel -replace '/','\')
    $outDir = Split-Path -Path $outPath -Parent
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }

    $fat = Expand-Includes -Path $file.FullName -RepoRoot $RepoRoot
    Set-Content -LiteralPath $outPath -Value $fat -Encoding UTF8 -NoNewline:$false

    Write-Host "built: $relFromRepo -> $outRel"
    $built++
}

Write-Host "fat-script build complete: $built file(s)."
