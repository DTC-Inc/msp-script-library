#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for get-server-lifecycle-audit.ps1
    Repo path: oem-dell/tests/get-server-lifecycle-audit.Tests.ps1
    Structural validation only - parses the script via the AST and checks the
    shippable-script invariants. Does NOT execute the collection logic or mock
    CIM/CDXML cmdlets (Get-PhysicalDisk/Get-Tpm/Confirm-SecureBootUEFI are not
    cleanly mockable in Pester 5; live integration is validated on a real server).
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\get-server-lifecycle-audit.ps1')).Path
    $script:Raw = Get-Content -Path $script:ScriptPath -Raw
    $parseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$parseErrors)
    $script:ParseErrors = $parseErrors
}

Describe 'get-server-lifecycle-audit shippable-script invariants' {

    It 'parses with no syntax errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'has a comment-based help SYNOPSIS' {
        $script:Raw | Should -Match '\.SYNOPSIS'
    }

    It 'sets $ErrorActionPreference to Stop' {
        $script:Raw | Should -Match "ErrorActionPreference\s*=\s*'Stop'"
    }

    It 'declares no mandatory parameters (would hang an unattended RMM run)' {
        # match the attribute form only, not prose mentions of "mandatory"
        $script:Raw | Should -Not -Match '\[Parameter\([^)]*Mandatory'
    }

    It 'defines the Get-DTCServerLifecycleAudit function' {
        $fn = $script:Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DTCServerLifecycleAudit' },
            $true)
        $fn | Should -Not -BeNullOrEmpty
    }

    It 'guards the main block so dot-sourcing for tests does not execute it' {
        $script:Raw | Should -Match "MyInvocation\.InvocationName -ne '\.'"
    }
}
