BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpHttpRequest' {
    It 'Exposes a mandatory Uri parameter' {
        InModuleScope $script:moduleName {
            $cmd = Get-Command -Name Invoke-ShpHttpRequest
            $cmd.Parameters['Uri'].Attributes.Mandatory | Should -Contain $true
        }
    }

    It 'Reuses the shared HttpClient across requests instead of constructing one per call' {
        InModuleScope $script:moduleName {
            $script:ShpHttpClient = $null
            # A relative URI makes SendAsync fail fast (no BaseAddress) with no
            # network I/O, but only after the shared client has been obtained - so
            # the module-scoped client is created once and reused on the next call.
            try { Invoke-ShpHttpRequest -Uri 'relative/one' -Body '{}' } catch { }
            $firstClient = $script:ShpHttpClient
            try { Invoke-ShpHttpRequest -Uri 'relative/two' -Body '{}' } catch { }
            $secondClient = $script:ShpHttpClient

            $firstClient | Should -Not -BeNullOrEmpty
            [object]::ReferenceEquals($firstClient, $secondClient) | Should -BeTrue
        }
    }
}
