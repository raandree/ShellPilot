BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Select-ShpModel' {
    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpDefaults.Model           = $null
            $script:ShpDefaults.ReasoningEffort = $null
            $script:ShpDefaults.MaxOutputTokens = $null
        }
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'Select-ShpModel' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Sets the default model' {
        Select-ShpModel -Model 'claude-opus-4.8'
        InModuleScope $script:moduleName { $script:ShpDefaults.Model | Should -Be 'claude-opus-4.8' }
    }

    It 'Sets the model, effort, and output cap together' {
        Select-ShpModel -Model 'gpt-5.5' -ReasoningEffort high -MaxOutputTokens 4000
        InModuleScope $script:moduleName {
            $script:ShpDefaults.Model           | Should -Be 'gpt-5.5'
            $script:ShpDefaults.ReasoningEffort | Should -Be 'high'
            $script:ShpDefaults.MaxOutputTokens | Should -Be 4000
        }
    }

    It 'Accepts the model from the pipeline by property name' {
        [pscustomobject]@{ Id = 'gemini-3.1-pro' } | Select-ShpModel
        InModuleScope $script:moduleName { $script:ShpDefaults.Model | Should -Be 'gemini-3.1-pro' }
    }

    It 'Returns the defaults object with -PassThru' {
        $result = Select-ShpModel -Model 'gpt-5.5' -PassThru
        $result.Model | Should -Be 'gpt-5.5'
    }

    It 'Clears all defaults with -Clear' {
        Select-ShpModel -Model 'gpt-5.5' -ReasoningEffort max -MaxOutputTokens 999
        Select-ShpModel -Clear
        InModuleScope $script:moduleName {
            $script:ShpDefaults.Model           | Should -BeNullOrEmpty
            $script:ShpDefaults.ReasoningEffort | Should -BeNullOrEmpty
            $script:ShpDefaults.MaxOutputTokens | Should -BeNullOrEmpty
        }
    }

    It 'Validates -ReasoningEffort against the known effort levels' {
        $validateSet = (Get-Command -Name 'Select-ShpModel').Parameters['ReasoningEffort'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet.ValidValues | Should -Contain 'max'
    }

    It 'Requires a model in the Set parameter set' {
        (Get-Command -Name 'Select-ShpModel').Parameters['Model'].Attributes.Mandatory | Should -Contain $true
    }
}
