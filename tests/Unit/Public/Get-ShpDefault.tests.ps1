BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpDefault' {
    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpDefaults.Model           = $null
            $script:ShpDefaults.ReasoningEffort = $null
            $script:ShpDefaults.MaxOutputTokens = $null
        }
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpDefault' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Returns null members when nothing is set' {
        $d = Get-ShpDefault
        $d.Model           | Should -BeNullOrEmpty
        $d.ReasoningEffort | Should -BeNullOrEmpty
        $d.MaxOutputTokens | Should -BeNullOrEmpty
    }

    It 'Reflects what Select-ShpModel set' {
        Select-ShpModel -Model 'claude-opus-4.8' -ReasoningEffort medium
        $d = Get-ShpDefault
        $d.Model           | Should -Be 'claude-opus-4.8'
        $d.ReasoningEffort | Should -Be 'medium'
    }
}
