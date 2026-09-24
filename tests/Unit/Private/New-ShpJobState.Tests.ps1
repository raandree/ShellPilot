BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpJobState' {
    AfterEach {
        InModuleScope $script:moduleName {
            Clear-ShpToolPolicy
            Clear-ShpRedactionPolicy
            Clear-ShpContext
            Unregister-ShpTool -All -ErrorAction SilentlyContinue
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpJobState' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'Carries the whole tool policy, including its trust profile and coverage' {
        InModuleScope $script:moduleName {
            Set-ShpToolPolicy -TrustProfile RestrictedUnattended -Rule @('Url(https://docs.example.com/**)')

            $state = New-ShpJobState -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi' } -ModulePath 'C:/module/ShellPilot.psd1'

            $state.ToolPolicy.TrustProfile | Should -BeExactly 'RestrictedUnattended'
            $state.ToolPolicy.Coverage | Should -Be @('Read', 'Write', 'Shell', 'Url', 'Mcp', 'Tool')
            ($state.ToolPolicy.Rule | Where-Object Kind -eq 'Url').Value | Should -BeExactly 'https://docs.example.com/**'
        }
    }

    It 'Carries no policy when the caller set none, so a job is no stricter than its caller' {
        InModuleScope $script:moduleName {
            $state = New-ShpJobState -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi' } -ModulePath 'C:/module/ShellPilot.psd1'

            $state.ToolPolicy | Should -BeNullOrEmpty
            $state.RedactionPolicy | Should -BeNullOrEmpty
        }
    }

    It 'Copies the session context rather than sharing it with a job in flight' {
        InModuleScope $script:moduleName {
            Set-ShpContext -TimeoutSec 42

            $state = New-ShpJobState -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi' } -ModulePath 'C:/module/ShellPilot.psd1'
            Set-ShpContext -TimeoutSec 99

            $state.Context.TimeoutSec | Should -Be 42
        }
    }

    It 'Carries the registered user tools, and none when they are disabled' {
        InModuleScope $script:moduleName {
            $null = Register-ShpTool -Command Get-Random

            $enabled = New-ShpJobState -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi' } -ModulePath 'C:/m.psd1'
            $disabled = New-ShpJobState -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi'; DisableUserTools = $true } -ModulePath 'C:/m.psd1'

            $enabled.ToolCommand | Should -Contain 'Get-Random'
            $disabled.ToolCommand | Should -BeNullOrEmpty
        }
    }
}
