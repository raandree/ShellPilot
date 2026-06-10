BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpTodoList' {
    It 'Coerces an unknown status to not-started' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @([pscustomobject]@{ id = 1; title = 'Step'; status = 'bananas' })
            $r[0].status | Should -Be 'not-started'
        }
    }

    It 'Keeps the three valid statuses' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @(
                [pscustomobject]@{ id = 1; title = 'A'; status = 'completed' }
                [pscustomobject]@{ id = 2; title = 'B'; status = 'in-progress' }
                [pscustomobject]@{ id = 3; title = 'C'; status = 'not-started' }
            )
            $r[0].status | Should -Be 'completed'
            $r[1].status | Should -Be 'in-progress'
            $r[2].status | Should -Be 'not-started'
        }
    }

    It 'Demotes every in-progress after the first to not-started (first wins)' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @(
                [pscustomobject]@{ id = 1; title = 'A'; status = 'in-progress' }
                [pscustomobject]@{ id = 2; title = 'B'; status = 'in-progress' }
                [pscustomobject]@{ id = 3; title = 'C'; status = 'in-progress' }
            )
            @($r | Where-Object status -eq 'in-progress').Count | Should -Be 1
            $r[0].status | Should -Be 'in-progress'
            $r[1].status | Should -Be 'not-started'
            $r[2].status | Should -Be 'not-started'
        }
    }

    It 'Drops items with empty or whitespace titles' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @(
                [pscustomobject]@{ id = 1; title = '   '; status = 'not-started' }
                [pscustomobject]@{ id = 2; title = ''; status = 'not-started' }
                [pscustomobject]@{ id = 3; title = 'Keep'; status = 'not-started' }
            )
            @($r).Count | Should -Be 1
            $r[0].title  | Should -Be 'Keep'
        }
    }

    It 'Trims a title and caps it at 200 characters' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @(
                [pscustomobject]@{ id = 1; title = ('  ' + ('x' * 250) + '  '); status = 'not-started' }
            )
            $r[0].title.Length | Should -Be 200
        }
    }

    It 'Preserves input order' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @(
                [pscustomobject]@{ id = 10; title = 'first'; status = 'not-started' }
                [pscustomobject]@{ id = 20; title = 'second'; status = 'not-started' }
                [pscustomobject]@{ id = 30; title = 'third'; status = 'not-started' }
            )
            $r[0].title | Should -Be 'first'
            $r[1].title | Should -Be 'second'
            $r[2].title | Should -Be 'third'
        }
    }

    It 'Keeps a valid positive-integer id' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @([pscustomobject]@{ id = 42; title = 'keep id'; status = 'not-started' })
            $r[0].id | Should -Be 42
        }
    }

    It 'Assigns sequential 1-based ids when missing or non-positive' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @(
                [pscustomobject]@{ title = 'no id'; status = 'not-started' }
                [pscustomobject]@{ id = 0; title = 'zero id'; status = 'not-started' }
                [pscustomobject]@{ id = -5; title = 'negative id'; status = 'not-started' }
            )
            $r[0].id | Should -Be 1
            $r[1].id | Should -Be 2
            $r[2].id | Should -Be 3
        }
    }

    It 'Tolerates $null input and returns an empty array' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject $null
            @($r).Count | Should -Be 0
        }
    }

    It 'Tolerates an empty array' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @()
            @($r).Count | Should -Be 0
        }
    }

    It 'Returns normalised items carrying id, title and status members' {
        InModuleScope $script:moduleName {
            $r = ConvertTo-ShpTodoList -InputObject @([pscustomobject]@{ id = 1; title = 'A'; status = 'completed' })
            $names = $r[0].PSObject.Properties.Name
            $names | Should -Contain 'id'
            $names | Should -Contain 'title'
            $names | Should -Contain 'status'
        }
    }
}
