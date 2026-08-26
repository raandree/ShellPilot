BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpRedactionPolicy' {
    AfterEach { Clear-ShpRedactionPolicy }

    It 'Returns nothing when no custom policy has been set' {
        Get-ShpRedactionPolicy | Should -BeNullOrEmpty
    }

    It 'Returns the rule set applied by Set-ShpRedactionPolicy' {
        Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'

        $policy = Get-ShpRedactionPolicy

        $policy.Rule.Count | Should -Be 1
        $policy.Rule[0].Name | Should -Be 'InternalToken'
        $policy.Source | Should -Be '(inline)'
    }

    It 'Reports the file source when loaded from a policy file' {
        $file = Join-Path $TestDrive 'redaction-policy.txt'
        'InternalToken(itk_[A-Za-z0-9]{10,})' | Set-Content -LiteralPath $file

        Set-ShpRedactionPolicy -Path $file

        (Get-ShpRedactionPolicy).Source | Should -Exist
    }
}
