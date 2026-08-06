Describe 'ConvertFrom-RstCliOutput' {

    BeforeAll {
        # Pull the parser out via AST so the script itself never executes.
        $scriptPath = Join-Path $PSScriptRoot 'intel-raid-health-monitor.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $fn = $ast.Find({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'ConvertFrom-RstCliOutput'
        }, $true)
        if (-not $fn) { throw "ConvertFrom-RstCliOutput not found in $scriptPath" }
        . ([scriptblock]::Create($fn.Extent.Text))

        $script:healthy = @(
            'Name: Volume0'
            'Raid Level: 1'
            'Size: 2654 GB'
            'StripeSize: 64 KB'
            'Num Disks: 2'
            'State: Normal'
            'System: True'
            'Initialized: True'
            'Cache Policy: Off'
            ''
            'ID: 0-1-0-0'
            'Type: Disk'
            'Disk Type: SATA'
            'State: Normal'
            'Size: 2794 GB'
            'System Disk: False'
            'Usage: Array member'
            'Serial Number: <SERIAL1>'
            'Model: <MODEL>'
            ''
            'ID: 0-3-0-0'
            'Type: Disk'
            'Disk Type: SATA'
            'State: Normal'
            'Size: 2794 GB'
            'System Disk: False'
            'Usage: Array member'
            'Serial Number: <SERIAL2>'
            'Model: <MODEL>'
        )

        # The reason the parser is block-scoped. A line-level match on "State:" cannot
        # distinguish a volume state from a member-disk state, so a failed disk would
        # hide behind a healthy-looking line elsewhere in the output.
        $script:degraded = @(
            'Name: Volume0'
            'Raid Level: 1'
            'Size: 2654 GB'
            'Num Disks: 2'
            'State: Degraded'
            'System: True'
            ''
            'ID: 0-1-0-0'
            'Type: Disk'
            'State: Normal'
            'Usage: Array member'
            'Serial Number: <SERIAL1>'
            'Model: <MODEL>'
            ''
            'ID: 0-3-0-0'
            'Type: Disk'
            'State: Failed'
            'Usage: Array member'
            'Serial Number: <SERIAL2>'
            'Model: <MODEL>'
        )
    }

    Context 'Healthy RAID 1 volume' {
        It 'finds exactly one volume' {
            (ConvertFrom-RstCliOutput -OutputLines $script:healthy).Volumes.Count | Should -Be 1
        }
        It 'finds exactly two disks' {
            (ConvertFrom-RstCliOutput -OutputLines $script:healthy).Disks.Count | Should -Be 2
        }
        It 'reads volume name, RAID level and state' {
            $p = ConvertFrom-RstCliOutput -OutputLines $script:healthy
            $p.Volumes[0].Name      | Should -Be 'Volume0'
            $p.Volumes[0].RaidLevel | Should -Be '1'
            $p.Volumes[0].State     | Should -Be 'Normal'
        }
        It 'reads disk IDs in order' {
            $p = ConvertFrom-RstCliOutput -OutputLines $script:healthy
            $p.Disks[0].Id | Should -Be '0-1-0-0'
            $p.Disks[1].Id | Should -Be '0-3-0-0'
        }
    }

    Context 'Degraded volume with one failed member' {
        It 'attributes Degraded to the volume' {
            (ConvertFrom-RstCliOutput -OutputLines $script:degraded).Volumes[0].State | Should -Be 'Degraded'
        }
        It 'keeps the healthy member healthy' {
            $p = ConvertFrom-RstCliOutput -OutputLines $script:degraded
            ($p.Disks | Where-Object { $_.Id -eq '0-1-0-0' }).State | Should -Be 'Normal'
        }
        It 'attributes Failed to the correct disk' {
            $p = ConvertFrom-RstCliOutput -OutputLines $script:degraded
            ($p.Disks | Where-Object { $_.Id -eq '0-3-0-0' }).State | Should -Be 'Failed'
        }
        It 'does not collapse states across blocks' {
            $p = ConvertFrom-RstCliOutput -OutputLines $script:degraded
            @($p.Disks | Where-Object { $_.State -eq 'Failed' }).Count | Should -Be 1
        }
    }

    Context 'Malformed and empty input' {
        It 'returns empty collections for no input' {
            $p = ConvertFrom-RstCliOutput -OutputLines @()
            $p.Volumes.Count | Should -Be 0
            $p.Disks.Count   | Should -Be 0
        }
        It 'ignores non key-value noise' {
            $p = ConvertFrom-RstCliOutput -OutputLines @('garbage', '', 'more garbage')
            $p.Volumes.Count | Should -Be 0
            $p.Disks.Count   | Should -Be 0
        }
    }
}
