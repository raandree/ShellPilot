BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpModelName' {
    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpModelName' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Should expose a -Refresh switch parameter' {
        (Get-Command -Name 'Get-ShpModelName').Parameters['Refresh'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
    }

    It 'Populates the cache, reuses it, and refetches on -Refresh' {
        InModuleScope $script:moduleName {
            $script:ModelNameCache = $null
            Mock Get-ShpModel {
                [pscustomobject]@{ Id = 'model-b' }, [pscustomobject]@{ Id = 'model-a' }
            }

            $first = Get-ShpModelName
            $first    | Should -Contain 'model-a'
            $first[0] | Should -Be 'model-a'   # sorted
            Should -Invoke Get-ShpModel -Times 1 -Exactly

            $null = Get-ShpModelName            # served from cache
            Should -Invoke Get-ShpModel -Times 1 -Exactly

            $null = Get-ShpModelName -Refresh   # forces a refetch
            Should -Invoke Get-ShpModel -Times 2 -Exactly
        }
    }
}
