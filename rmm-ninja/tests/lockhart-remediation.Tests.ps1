<#
.SYNOPSIS
  Pester tests for lockhart-remediation.ps1
.NOTES
  Repo:    dtc-inc/msp-script-library
  Path:    rmm-ninja/tests/lockhart-remediation.Tests.ps1
  Target:  Pester 5+
  Run:     Invoke-Pester -Path .\rmm-ninja\tests\
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\lockhart-remediation.ps1')).Path
    if (-not (Test-Path $script:ScriptPath)) { throw "Script under test not found: $script:ScriptPath" }
    # Fast-run args for child invocations that proceed past the short-circuits
    $script:FastArgs = @('-SampleSeconds','1','-NetTestTimeoutMs','500','-DnsTimeoutMs','500','-MinUptimeMinutes','0')
}

Describe 'lockhart-remediation.ps1 - structural' {
    It 'parses without syntax errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help with required sections' {
        $help = Get-Help $script:ScriptPath -Full -ErrorAction SilentlyContinue
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
        $help.Parameters.Parameter.Count | Should -BeGreaterThan 0
    }

    It 'declares all required parameters with safe defaults' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty
        $mandatory = $paramBlock.Parameters | Where-Object {
            $_.Attributes.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' -and $_.Argument.Value -eq $true }
        }
        $mandatory | Should -BeNullOrEmpty -Because 'NinjaOne runs unattended; mandatory params would hang the agent'
    }

    It 'sets ErrorActionPreference = Stop' {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match "\`$ErrorActionPreference\s*=\s*'Stop'"
    }

    It 'contains the RMM variable declaration block (template section 1)' {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match "## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM"
    }

    It 'reads RMM checkbox variables via $env: (CLAUDE.md convention)' {
        $content = Get-Content $script:ScriptPath -Raw
        $content | Should -Match "Test-RmmFlag 'ForceDisruptiveRepairs'"
        $content | Should -Match "Test-RmmFlag 'ClearStateAndExit'"
    }
}

Describe 'lockhart-remediation.ps1 - HV0 host exclusion (failure-path)' {
    It 'exits 0 with HypervisorSkip when COMPUTERNAME matches ^HV0' {
        $originalName = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = 'HV01-TESTPATTERN'
            $output = & pwsh -NoProfile -File $script:ScriptPath 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'HypervisorSkip'
        } finally {
            $env:COMPUTERNAME = $originalName
        }
    }

    It 'exits 0 with HypervisorSkip when COMPUTERNAME is HV0-{servicetag}' {
        $originalName = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = 'HV0-ABC1234'
            $output = & pwsh -NoProfile -File $script:ScriptPath 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'HypervisorSkip'
        } finally {
            $env:COMPUTERNAME = $originalName
        }
    }

    It 'does NOT skip when COMPUTERNAME merely contains HV0 (e.g. SERVER-HV0)' {
        $originalName = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = 'SERVER-HV0'
            $output = & pwsh -NoProfile -File $script:ScriptPath @($script:FastArgs) 2>&1
            ($output -join "`n") | Should -Not -Match 'HypervisorSkip'
        } finally {
            $env:COMPUTERNAME = $originalName
        }
    }
}

Describe 'lockhart-remediation.ps1 - RMM environment variable binding' {
    It 'honors $env:ClearStateAndExit=1 (NinjaOne checkbox path) without a CLI switch' {
        $stateFiles = @(
            'C:\DTC\lockhart_autoremediation.json',
            'C:\ProgramData\DTC\lockhart_autoremediation.json'
        )
        # Back up any real state, then seed sentinels
        $backups = @{}
        foreach ($f in $stateFiles) {
            if (Test-Path $f) { $backups[$f] = Get-Content $f -Raw }
            $dir = Split-Path $f -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            '{"ConsecutiveAttempts":2,"LastResult":"TestSentinel","History":[]}' | Set-Content -Path $f -Force
        }
        try {
            $env:ClearStateAndExit = '1'
            $output = & pwsh -NoProfile -File $script:ScriptPath 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'StateCleared'
        } finally {
            Remove-Item Env:\ClearStateAndExit -ErrorAction SilentlyContinue
            foreach ($f in $stateFiles) {
                if ($backups.ContainsKey($f)) { $backups[$f] | Set-Content -Path $f -Force }
                else { Remove-Item $f -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

Describe 'lockhart-remediation.ps1 - happy-path (NotApplicable on host without Lockhart)' {
    It 'exits 0 with NotApplicable when Lockhart service does not exist' {
        $lockhartInstalled = $null -ne (Get-CimInstance Win32_Service -Filter "Name='Lockhart'" -ErrorAction SilentlyContinue)
        if ($lockhartInstalled) {
            Set-ItResult -Skipped -Because 'Lockhart is installed on this test host; cannot validate NotApplicable path here'
        }
        $output = & pwsh -NoProfile -File $script:ScriptPath @($script:FastArgs) 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'NotApplicable'
    }
}