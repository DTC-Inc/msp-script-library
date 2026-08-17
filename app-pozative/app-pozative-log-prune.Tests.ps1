Describe "app-pozative-log-prune" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "app-pozative-log-prune.ps1"

        function Invoke-Prune {
            param([hashtable]$EnvVars)
            foreach ($k in $EnvVars.Keys) { Set-Item -Path "env:$k" -Value $EnvVars[$k] }
            try {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptPath *>&1 | Out-Null
                return $LASTEXITCODE
            } finally {
                foreach ($k in $EnvVars.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
            }
        }
    }

    Context "Happy path" {
        It "deletes aged logs, keeps recent logs, honors exclusions and root-file protection" {
            $root = Join-Path $TestDrive "Pozative"
            New-Item -Path "$root\SyncLogFile" -ItemType Directory -Force | Out-Null
            New-Item -Path "$root\DTX_Helper" -ItemType Directory -Force | Out-Null

            $oldLog   = "$root\SyncLogFile\old.txt"
            $newLog   = "$root\SyncLogFile\new.txt"
            $excluded = "$root\DTX_Helper\DentrixConnectionString.txt"
            $rootFile = "$root\ReadMe.txt"
            "x" | Set-Content $oldLog; "x" | Set-Content $newLog; "x" | Set-Content $excluded; "x" | Set-Content $rootFile
            (Get-Item $oldLog).LastWriteTime   = (Get-Date).AddDays(-30)
            (Get-Item $excluded).LastWriteTime = (Get-Date).AddDays(-30)
            (Get-Item $rootFile).LastWriteTime = (Get-Date).AddDays(-30)

            $exit = Invoke-Prune @{ PozativeLogPath = $root; RetentionDays = "14"; RMMScriptPath = "$TestDrive\rmm"; MinFreePercent = "0" }

            $exit | Should -Be 0
            Test-Path $oldLog   | Should -BeFalse
            Test-Path $newLog   | Should -BeTrue
            Test-Path $excluded | Should -BeTrue
            Test-Path $rootFile | Should -BeTrue
        }

        It "deletes nothing in dry-run mode" {
            $root = Join-Path $TestDrive "PozativeDry"
            New-Item -Path "$root\PaymentLogFile" -ItemType Directory -Force | Out-Null
            $oldLog = "$root\PaymentLogFile\old.txt"
            "x" | Set-Content $oldLog
            (Get-Item $oldLog).LastWriteTime = (Get-Date).AddDays(-30)

            $exit = Invoke-Prune @{ PozativeLogPath = $root; RetentionDays = "14"; DryRun = "1"; RMMScriptPath = "$TestDrive\rmm"; MinFreePercent = "0" }

            $exit | Should -Be 0
            Test-Path $oldLog | Should -BeTrue
        }
    }

    Context "Failure path" {
        It "exits 1 when the target path does not exist" {
            $exit = Invoke-Prune @{ PozativeLogPath = "$TestDrive\DoesNotExist"; RMMScriptPath = "$TestDrive\rmm" }
            $exit | Should -Be 1
        }

        It "exits 1 and deletes nothing when the target path is a volume root" {
            $exit = Invoke-Prune @{ PozativeLogPath = "C:\"; RMMScriptPath = "$TestDrive\rmm"; DryRun = "1" }
            $exit | Should -Be 1
        }
    }
}
