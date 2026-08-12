BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Clear-ShpToolPolicy' {
    AfterEach { Clear-ShpToolPolicy }

    It 'Should be exported by the module' {
        Get-Command -Name 'Clear-ShpToolPolicy' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should support ShouldProcess, because clearing widens what the model may reach' {
        (Get-Command -Name 'Clear-ShpToolPolicy').Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'Returns the tools to unrestricted' {
        Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')
        Get-ShpToolPolicy | Should -Not -BeNullOrEmpty

        Clear-ShpToolPolicy

        Get-ShpToolPolicy | Should -BeNullOrEmpty
        InModuleScope $script:moduleName {
            (Test-ShpToolAccess -Tool 'run_command' -Command 'anything at all').Allowed | Should -BeTrue
        }
    }

    It 'Leaves the policy in place under -WhatIf' {
        Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')

        Clear-ShpToolPolicy -WhatIf

        Get-ShpToolPolicy | Should -Not -BeNullOrEmpty
    }

    It 'Is safe to run when no policy is set' {
        Clear-ShpToolPolicy
        { Clear-ShpToolPolicy } | Should -Not -Throw
    }
}
