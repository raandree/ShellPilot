BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpToolPolicy' {
    AfterEach { Clear-ShpToolPolicy }

    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpToolPolicy' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Returns nothing while the tools are unrestricted' {
        Clear-ShpToolPolicy
        Get-ShpToolPolicy | Should -BeNullOrEmpty
    }

    It 'Returns the parsed rules and where they came from' {
        Set-ShpToolPolicy -Rule @('Read(C:/repo/**)', '!Shell(git push)')

        $policy = Get-ShpToolPolicy
        $policy.Source           | Should -Be '(inline)'
        $policy.Rule.Count       | Should -Be 2
        $policy.Rule[0].Kind     | Should -Be 'Read'
        $policy.Rule[1].Kind     | Should -Be 'Shell'
        $policy.Rule[1].Deny     | Should -BeTrue
    }

    It 'Names the file a policy was loaded from, so a run can be audited' {
        $file = Join-Path $TestDrive 'audit-policy.txt'
        'Shell(git status)' | Set-Content -LiteralPath $file

        Set-ShpToolPolicy -Path $file

        (Get-ShpToolPolicy).Source | Should -BeLike '*audit-policy.txt'
    }
}
