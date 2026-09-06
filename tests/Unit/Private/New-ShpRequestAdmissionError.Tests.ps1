BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpRequestAdmissionError' {
    It 'includes only reservation totals from trusted state' {
        InModuleScope $script:moduleName {
            $budget = @{
                RequestCount = 2
                ReservedTokens = 84
                ReservedCostUSD = [decimal]0.001
                Secret = 'budget-secret-canary-9162'
            }
            $failure = New-ShpRequestAdmissionError -Code 'ShpRequestCostLimit' -Message 'Cost refused.' -Budget $budget
            $failure | Should -BeOfType ([System.Management.Automation.ErrorRecord])
            $failure.TargetObject.RequestCount | Should -Be 2
            $failure.TargetObject.ReservedTokens | Should -Be 84
            @($failure.TargetObject.PSObject.Properties.Name) | Should -HaveCount 3
            ($failure.TargetObject | ConvertTo-Json) | Should -Not -Match 'budget-secret-canary-9162'
        }
    }

    It 'does not invent a reservation for an early refusal' {
        InModuleScope $script:moduleName {
            $failure = New-ShpRequestAdmissionError -Code 'ShpRequestCountUnavailable' -Message 'Count unavailable.'
            $failure.FullyQualifiedErrorId | Should -BeExactly 'ShpRequestCountUnavailable'
            $failure.TargetObject | Should -BeNullOrEmpty
        }
    }
}
