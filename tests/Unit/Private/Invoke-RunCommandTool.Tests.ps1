BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-RunCommandTool' {
    It 'Returns stdout and a zero exit code for a successful command' {
        InModuleScope $script:moduleName {
            $obj = Invoke-RunCommandTool -Command 'Write-Output 12345' | ConvertFrom-Json
            $obj.exitCode | Should -Be 0
            $obj.stdout   | Should -Match '12345'
        }
    }

    It 'Reports a non-zero exit code' {
        InModuleScope $script:moduleName {
            $obj = Invoke-RunCommandTool -Command 'exit 3' | ConvertFrom-Json
            $obj.exitCode | Should -Be 3
        }
    }

    It 'Returns an error envelope for an invalid working directory' {
        InModuleScope $script:moduleName {
            $obj = Invoke-RunCommandTool -Command 'Write-Output hi' -WorkingDirectory 'C:\does\not\exist\zzz_shp_test' | ConvertFrom-Json
            $obj.error | Should -Not -BeNullOrEmpty
        }
    }
}
