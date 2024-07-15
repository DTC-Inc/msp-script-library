# Define the end of life dates for extended support for various Windows Server versions
$endOfLifeDates = @{
    "Windows Server 2003" = "2015-07-14"
    "Windows Server 2008" = "2020-01-14"
    "Windows Server 2008 R2" = "2020-01-14"
    "Windows Server 2012" = "2023-10-10"
    "Windows Server 2012 R2" = "2023-10-10"
    "Windows Server 2016" = "2027-01-12"
    "Windows Server 2019" = "2029-01-09"
    "Windows Server 2022" = "2031-10-14"
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
if ($osName -match "Windows Server") {
    Write-Output "Detected Windows Server OS: $osName"
    $isEOL = Check-EndOfLife -osName $osName
    Write-Output "Has the OS reached end of life: $isEOL"
} else {
    Write-Output "This script is designed for Windows Server operating systems only."
}

