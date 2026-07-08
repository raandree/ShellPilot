BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpHttpClient' {
    It 'Returns the same shared HttpClient instance on repeated calls' {
        InModuleScope $script:moduleName {
            $script:ShpHttpClient = $null
            $first  = Get-ShpHttpClient
            $second = Get-ShpHttpClient
            $first | Should -BeOfType ([System.Net.Http.HttpClient])
            [object]::ReferenceEquals($first, $second) | Should -BeTrue
        }
    }

    It 'Configures the shared client for streaming with no overall timeout' {
        InModuleScope $script:moduleName {
            $script:ShpHttpClient = $null
            $client = Get-ShpHttpClient
            $client.Timeout | Should -Be ([System.Threading.Timeout]::InfiniteTimeSpan)
        }
    }
}
