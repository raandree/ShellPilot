BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Clear-ShpUsage' {
    AfterEach {
        InModuleScope $script:moduleName { $script:ShpUsageLog = [System.Collections.Generic.List[pscustomobject]]::new() }
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'Clear-ShpUsage' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Empties the usage log' {
        InModuleScope $script:moduleName {
            $script:ShpUsageLog.Add([pscustomobject]@{ Model = 'm'; PromptTokens = 1; CompletionTokens = 1; TotalTokens = 2; CostUSD = 0; Credits = 0 })
            @($script:ShpUsageLog).Count | Should -Be 1
            Clear-ShpUsage
            @($script:ShpUsageLog).Count | Should -Be 0
        }
    }
}
