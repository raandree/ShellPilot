BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpContextReport' {
    It 'Lists every canonical source, in order, even when nothing was supplied' {
        InModuleScope $script:moduleName {
            $report = New-ShpContextReport -Source @()

            @($report.Sources.Name) | Should -Be @(
                'System', 'Instructions', 'SkillCatalog', 'SkillBodies',
                'ToolSchemas', 'Attachments', 'SessionChat', 'Prompt', 'ToolResults')
            $report.EstimatedTokens | Should -Be 0
        }
    }

    It 'Names the one estimator it applied' {
        InModuleScope $script:moduleName {
            (New-ShpContextReport -Source @()).Estimator | Should -BeExactly 'ConvertTo-ShpTokenCount'
        }
    }

    It 'Reconciles the total with the sum of the known rows' {
        InModuleScope $script:moduleName {
            $report = New-ShpContextReport -Source @(
                @{ Name = 'Prompt'; Text = ('alpha ' * 100) }
                @{ Name = 'SessionChat'; Text = @(('beta ' * 50), ('gamma ' * 50)); ItemCount = 2 }
                @{ Name = 'ToolResults'; Tokens = 42; Chars = 168; ItemCount = 1 }
            )

            $known = @($report.Sources | Where-Object { $_.Known })
            $report.EstimatedTokens | Should -Be ($known | Measure-Object -Property EstimatedTokens -Sum).Sum
            ($report.Sources | Where-Object { $_.Name -eq 'ToolResults' }).EstimatedTokens | Should -Be 42
        }
    }

    It 'Reports an unsizable row as null with a reason rather than as zero' {
        InModuleScope $script:moduleName {
            $report = New-ShpContextReport -Source @(
                @{ Name = 'Attachments'; Known = $false; Detail = 'one image is tokenized by the provider'; ItemCount = 1 }
            )

            $row = $report.Sources | Where-Object { $_.Name -eq 'Attachments' }
            $row.EstimatedTokens | Should -BeNullOrEmpty
            $row.Chars | Should -BeNullOrEmpty
            $row.ItemCount | Should -Be 1
            $report.Unknown | Should -Contain 'Attachments'
        }
    }

    It 'Refuses a source name that is not part of the contract' {
        InModuleScope $script:moduleName {
            { New-ShpContextReport -Source @(@{ Name = 'Reasoning'; Text = 'x' }) } |
                Should -Throw '*is not a Context report source*'
        }
    }

    It 'Refuses a source with no name' {
        InModuleScope $script:moduleName {
            { New-ShpContextReport -Source @(@{ Text = 'x' }) } | Should -Throw '*must carry a Name*'
        }
    }

    It 'Reports remaining budget only when the guard is enabled' {
        InModuleScope $script:moduleName {
            $bounded = New-ShpContextReport -Source @(@{ Name = 'Prompt'; Text = 'hi' }) -ContextBudget 1000
            $bounded.RemainingTokens | Should -Be (1000 - $bounded.EstimatedTokens)
            $bounded.FitsBudget | Should -BeTrue

            $unbounded = New-ShpContextReport -Source @(@{ Name = 'Prompt'; Text = 'hi' }) -ContextBudget 0
            $unbounded.RemainingTokens | Should -BeNullOrEmpty
            $unbounded.FitsBudget | Should -BeNullOrEmpty
        }
    }

    It 'Says a composition does not fit when it exceeds the budget' {
        InModuleScope $script:moduleName {
            $report = New-ShpContextReport -Source @(@{ Name = 'Prompt'; Text = ('word ' * 500) }) -ContextBudget 10

            $report.FitsBudget | Should -BeFalse
            $report.RemainingTokens | Should -BeLessThan 0
        }
    }

    It 'Carries the deferred figures it was given' {
        InModuleScope $script:moduleName {
            $report = New-ShpContextReport -Source @() -DeferredToolLoading -DeferredToolCount 3 -DeferredToolSchemaTokens 120

            $report.DeferredToolLoading | Should -BeTrue
            $report.DeferredToolCount | Should -Be 3
            $report.DeferredToolSchemaTokens | Should -Be 120
        }
    }
}
