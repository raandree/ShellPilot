BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpSubagentBudget' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpSubagentBudget' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpSubagentBudget' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'A root budget' {
        It 'Should open a tree ledger at depth zero' {
            InModuleScope $script:moduleName {
                $budget = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxChildUSD = 0.25; MaxDepth = 2; MaxFanOut = 3 }

                $budget.Ok | Should -BeTrue
                $budget.Depth | Should -Be 0
                $budget.Tree.MaxTotalUSD | Should -Be 1.0
                $budget.Tree.SpentUSD | Should -Be 0
            }
        }
    }

    Context 'Depth, fan-out and concurrency' {
        It 'Should refuse a child past the depth cap' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxDepth = 1 }
                $child = New-ShpSubagentBudget -Parent $root
                $child.Ok | Should -BeTrue

                $grandChild = New-ShpSubagentBudget -Parent $child
                $grandChild.Ok | Should -BeFalse
                $grandChild.Reason | Should -Match 'depth'
            }
        }

        It 'Should refuse a child past the fan-out cap for one parent' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxDepth = 3; MaxFanOut = 2 }

                (New-ShpSubagentBudget -Parent $root).Ok | Should -BeTrue
                (New-ShpSubagentBudget -Parent $root).Ok | Should -BeTrue
                $third = New-ShpSubagentBudget -Parent $root
                $third.Ok | Should -BeFalse
                $third.Reason | Should -Match 'fan-out|children'
            }
        }

        It 'Should refuse a child past the tree-wide concurrency cap' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxDepth = 3; MaxFanOut = 10; MaxConcurrency = 1 }
                $first = New-ShpSubagentBudget -Parent $root
                $first.Ok | Should -BeTrue

                $second = New-ShpSubagentBudget -Parent $root
                $second.Ok | Should -BeFalse
                $second.Reason | Should -Match 'concurren'
            }
        }
    }

    Context 'The tree budget is shared, not split' {
        It 'Should give a child no more than the tree has left' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 0.10; MaxChildUSD = 1.0; MaxDepth = 3; MaxFanOut = 5 }
                $root.Tree.SpentUSD = 0.09

                $child = New-ShpSubagentBudget -Parent $root
                $child.Ok | Should -BeTrue
                $child.MaxCostUSD | Should -BeLessOrEqual 0.01
            }
        }

        It 'Should cap a child at the per-child limit even when the tree has more' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 10.0; MaxChildUSD = 0.05; MaxDepth = 3; MaxFanOut = 5 }
                $child = New-ShpSubagentBudget -Parent $root
                $child.MaxCostUSD | Should -Be 0.05
            }
        }

        It 'Should refuse a child once the tree budget is exhausted' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 0.10; MaxDepth = 3; MaxFanOut = 5 }
                $root.Tree.SpentUSD = 0.10

                $child = New-ShpSubagentBudget -Parent $root
                $child.Ok | Should -BeFalse
                $child.Reason | Should -Match 'budget'
            }
        }

        It 'Should share one ledger so a grandchild cannot recover budget by splitting' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxDepth = 3; MaxFanOut = 5 }
                $child = New-ShpSubagentBudget -Parent $root
                $grandChild = New-ShpSubagentBudget -Parent $child

                $grandChild.Tree | Should -Be $root.Tree
                $grandChild.Tree.SpentUSD = 0.4
                $root.Tree.SpentUSD | Should -Be 0.4
            }
        }

        It 'Should refuse a child that asks for more than the parent may spend' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxChildUSD = 0.10; MaxDepth = 3; MaxFanOut = 5 }
                $child = New-ShpSubagentBudget -Parent $root -Requested @{ MaxCostUSD = 5.0 }

                $child.Ok | Should -BeFalse
                $child.Reason | Should -Match 'more than'
            }
        }
    }

    Context 'Duration' {
        It 'Should inherit a deadline no later than the parent deadline' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxDepth = 3; MaxFanOut = 5; MaxDurationSec = 10 }
                $child = New-ShpSubagentBudget -Parent $root -Requested @{ MaxDurationSec = 600 }

                $child.Ok | Should -BeTrue
                $child.Deadline | Should -BeLessOrEqual $root.Deadline
            }
        }

        It 'Should refuse a child once the tree deadline has passed' {
            InModuleScope $script:moduleName {
                $root = New-ShpSubagentBudget -Limit @{ MaxTotalUSD = 1.0; MaxDepth = 3; MaxFanOut = 5; MaxDurationSec = 60 }
                $root.Tree.Deadline = [datetime]::UtcNow.AddSeconds(-1)

                $child = New-ShpSubagentBudget -Parent $root
                $child.Ok | Should -BeFalse
                $child.Reason | Should -Match 'deadline|duration'
            }
        }
    }
}
