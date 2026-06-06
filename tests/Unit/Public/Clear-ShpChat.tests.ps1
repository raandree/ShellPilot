BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Clear-ShpChat' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Clear-ShpChat' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Empties the stored conversation' {
        InModuleScope $script:moduleName {
            $script:ShpChat = @([pscustomobject]@{ role = 'user'; content = 'hi' })
        }
        Clear-ShpChat
        @(Get-ShpChat).Count | Should -Be 0
    }

    It 'Supports -WhatIf without clearing' {
        InModuleScope $script:moduleName {
            $script:ShpChat = @([pscustomobject]@{ role = 'user'; content = 'hi' })
        }
        Clear-ShpChat -WhatIf
        @(Get-ShpChat).Count | Should -Be 1
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }
}
