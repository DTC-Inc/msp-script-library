# Define the end of life dates for extended support for various Windows Desktop versions
$endOfLifeDates = @{
    "Windows XP" = "2014-04-08"
    "Windows Vista" = "2017-04-11"
    "Windows 7" = "2020-01-14"
    "Windows 8" = "2016-01-12"
    "Windows 8.1" = "2023-01-10"
    "Windows 10" = "2025-10-14"
    "Windows 11" = "2031-10-14"  # Assuming hypothetical end of life date
}

# Function to get the OS name
function Get-OSName {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    return $os.Caption
}

# Function to check if the OS has reached end of life
function Check-EndOfLife {
    param (
        [string]$osName
    )

    $hasReachedEndOfLife = $false

    foreach ($key in $endOfLifeDates.Keys) {
        if ($osName -like "*$key*") {
            $endDate = [datetime]$endOfLifeDates[$key]
            $currentDate = Get-Date
            if ($currentDate -gt $endDate) {
                Write-Output "$osName has reached end of life for extended support on $endDate."
                $hasReachedEndOfLife = $true
            } else {
                Write-Output "$osName is still under extended support until $endDate."
                $hasReachedEndOfLife = $false
            }
            return $hasReachedEndOfLife
        }
    }
    Write-Output "Operating system $osName is not recognized or does not have end of life information."
    return $hasReachedEndOfLife
}

# Main script
$osName = Get-OSName
if ($osName -match "Windows") {
    Write-Output "Detected Windows Desktop OS: $osName"
    $isEOL = Check-EndOfLife -osName $osName
    Write-Output "Has the OS reached end of life: $isEOL"
} else {
    Write-Output "This script is designed for Windows Desktop operating systems only."
}
