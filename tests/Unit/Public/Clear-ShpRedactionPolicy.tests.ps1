BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Clear-ShpRedactionPolicy' {
    It 'Should support ShouldProcess, because it narrows what gets redacted' {
        (Get-Command -Name 'Clear-ShpRedactionPolicy').Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'Removes the custom rule set' {
        Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'
        Clear-ShpRedactionPolicy

        Get-ShpRedactionPolicy | Should -BeNullOrEmpty
    }

    It 'Does nothing under -WhatIf' {
        Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'
        Clear-ShpRedactionPolicy -WhatIf

        Get-ShpRedactionPolicy | Should -Not -BeNullOrEmpty

        Clear-ShpRedactionPolicy
    }
}
