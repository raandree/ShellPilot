BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpStreamRequest' {
    It 'Exposes mandatory Uri, Headers and Body parameters' {
        InModuleScope $script:moduleName {
            $cmd = Get-Command -Name Invoke-ShpStreamRequest
            $cmd.Parameters['Uri'].Attributes.Mandatory     | Should -Contain $true
            $cmd.Parameters['Headers'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['Body'].Attributes.Mandatory    | Should -Contain $true
        }
    }

    It 'Throws for an invalid request URI without hitting the network' {
        InModuleScope $script:moduleName {
            { Invoke-ShpStreamRequest -Uri 'not a uri' -Headers @{ Authorization = 'Bearer x' } -Body '{}' } |
                Should -Throw
        }
    }
}
