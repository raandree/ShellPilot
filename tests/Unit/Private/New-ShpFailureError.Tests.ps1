BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpFailureError' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpFailureError' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpFailureError' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    # The id is a published contract a CI script branches on, so it is pinned
    # here as data rather than being re-derived from the implementation.
    Context 'The condition-to-error-id map' {
        It 'Should map <Condition> to <ExpectedId> in category <ExpectedCategory>' -ForEach @(
            @{ Condition = 'BudgetExceeded';     ExpectedId = 'ShpBudgetExceeded';     ExpectedCategory = 'LimitsExceeded' }
            @{ Condition = 'Truncated';          ExpectedId = 'ShpTruncated';          ExpectedCategory = 'LimitsExceeded' }
            @{ Condition = 'ToolIterationLimit'; ExpectedId = 'ShpToolIterationLimit'; ExpectedCategory = 'LimitsExceeded' }
            @{ Condition = 'NoContent';          ExpectedId = 'ShpNoContent';          ExpectedCategory = 'InvalidResult' }
            @{ Condition = 'SchemaMismatch';     ExpectedId = 'ShpSchemaMismatch';     ExpectedCategory = 'InvalidData' }
        ) {
            InModuleScope $script:moduleName -Parameters $_ {
                param($Condition, $ExpectedId, $ExpectedCategory)

                $record = New-ShpFailureError -Condition $Condition -Message 'something went wrong'

                $record | Should -BeOfType ([System.Management.Automation.ErrorRecord])
                $record.FullyQualifiedErrorId  | Should -Be $ExpectedId
                $record.CategoryInfo.Category  | Should -Be $ExpectedCategory
            }
        }

        It 'Should accept only the five documented conditions' {
            InModuleScope $script:moduleName {
                { New-ShpFailureError -Condition 'Whatever' -Message 'x' } | Should -Throw
            }
        }
    }

    Context 'The message and the payload' {
        It 'Should use the supplied message verbatim' {
            InModuleScope $script:moduleName {
                $record = New-ShpFailureError -Condition 'Truncated' -Message 'the reply was cut off at 4 tokens'
                $record.Exception.Message | Should -Be 'the reply was cut off at 4 tokens'
            }
        }

        It 'Should refuse an empty message, because the caller has to state the observed value' {
            InModuleScope $script:moduleName {
                { New-ShpFailureError -Condition 'Truncated' -Message '' } | Should -Throw
            }
        }

        # A -FailOn stop is a completed, billed turn. Handing the result over is
        # what lets a catch block report what the abandoned call cost.
        It 'Should carry the result on TargetObject' {
            InModuleScope $script:moduleName {
                $turnResult = [pscustomobject]@{ PSTypeName = 'ShellPilot.Result'; CostUSD = 30.0; Content = 'half an ans' }

                $record = New-ShpFailureError -Condition 'BudgetExceeded' -Message 'over cap' -Result $turnResult

                @($record.TargetObject.PSObject.TypeNames) | Should -Contain 'ShellPilot.Result'
                $record.TargetObject.CostUSD | Should -Be 30.0
            }
        }

        It 'Should leave TargetObject empty when no result was built' {
            InModuleScope $script:moduleName {
                $record = New-ShpFailureError -Condition 'ToolIterationLimit' -Message 'loop exhausted'
                $record.TargetObject | Should -BeNullOrEmpty
            }
        }
    }
}
