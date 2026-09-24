BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpToolNamePattern' {
    Context 'Tool names' {
        It 'Matches <Name> against <Glob>: <Expected>' -ForEach @(
            @{ Glob = 'manage_todo_list'; Name = 'manage_todo_list'; Expected = $true }
            @{ Glob = 'manage_todo_list'; Name = 'manage_todo_lists'; Expected = $false }
            @{ Glob = 'MANAGE_todo_list'; Name = 'manage_todo_list'; Expected = $true }
            @{ Glob = '*'; Name = 'anything_at_all'; Expected = $true }
            @{ Glob = 'read_*'; Name = 'read_file'; Expected = $true }
            @{ Glob = 'read_*'; Name = 'write_file'; Expected = $false }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Glob = $Glob; Name = $Name; Expected = $Expected } {
                param($Glob, $Name, $Expected)
                ($Name -match (ConvertTo-ShpToolNamePattern -Glob $Glob -Segment 1)) | Should -Be $Expected
            }
        }
    }

    Context 'MCP alias and tool' {
        It 'Matches <Name> against <Glob>: <Expected>' -ForEach @(
            @{ Glob = 'files/read'; Name = 'files/read'; Expected = $true }
            @{ Glob = 'files/read'; Name = 'other/read'; Expected = $false }
            @{ Glob = 'files/*'; Name = 'files/write'; Expected = $true }
            @{ Glob = 'files'; Name = 'files/write'; Expected = $true }
            @{ Glob = 'files'; Name = 'filesystem/write'; Expected = $false }
            @{ Glob = '*'; Name = 'files/write'; Expected = $true }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Glob = $Glob; Name = $Name; Expected = $Expected } {
                param($Glob, $Name, $Expected)
                ($Name -match (ConvertTo-ShpToolNamePattern -Glob $Glob -Segment 2)) | Should -Be $Expected
            }
        }

        It 'Never lets a wildcard cross the alias boundary' {
            InModuleScope $script:moduleName {
                $pattern = ConvertTo-ShpToolNamePattern -Glob 'files/*' -Segment 2
                ('files/read' -match $pattern) | Should -BeTrue
                ('files/sub/read' -match $pattern) | Should -BeFalse
                ('other/read' -match $pattern) | Should -BeFalse
            }
        }
    }

    Context 'Fails closed' {
        It 'Refuses more segments than the kind allows' {
            InModuleScope $script:moduleName {
                { ConvertTo-ShpToolNamePattern -Glob 'files/read' -Segment 1 } | Should -Throw
                { ConvertTo-ShpToolNamePattern -Glob 'files/read/extra' -Segment 2 } | Should -Throw
            }
        }

        It 'Refuses an empty segment or whitespace' {
            InModuleScope $script:moduleName {
                { ConvertTo-ShpToolNamePattern -Glob 'files/' -Segment 2 } | Should -Throw
                { ConvertTo-ShpToolNamePattern -Glob 'a tool' -Segment 1 } | Should -Throw
            }
        }
    }
}
