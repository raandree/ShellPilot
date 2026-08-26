BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # This resolver reads nothing BUT the environment, so a runner that already
    # sets CI would otherwise decide every case in this file.
    $script:savedEnv = @{}
    foreach ($name in 'CI', 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI') {
        $script:savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($name in @($script:savedEnv.Keys)) {
        if ($null -ne $script:savedEnv[$name]) {
            Set-Item -LiteralPath "Env:$name" -Value $script:savedEnv[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpCiProfile' {
    BeforeEach {
        Remove-Item -LiteralPath 'Env:CI' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI' -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item -LiteralPath 'Env:CI' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI' -ErrorAction SilentlyContinue
    }

    Context 'CI detection' {
        It 'Reports <Value> as CI: <Expected>' -ForEach @(
            @{ Value = 'true';  Expected = $true }
            @{ Value = '1';     Expected = $true }
            @{ Value = 'True';  Expected = $true }
            @{ Value = 'azure'; Expected = $true }
            @{ Value = 'false'; Expected = $false }
            @{ Value = '0';     Expected = $false }
            @{ Value = 'off';   Expected = $false }
            @{ Value = '';      Expected = $false }
        ) {
            $env:CI = $Value

            InModuleScope $script:moduleName -Parameters @{ Expected = $Expected } {
                param($Expected)
                (Resolve-ShpCiProfile).IsCI | Should -Be $Expected
            }
        }

        It 'Treats an unrecognised value as CI so an unfamiliar runner is gated rather than waved through' {
            $env:CI = 'jenkins-2'

            InModuleScope $script:moduleName {
                (Resolve-ShpCiProfile).IsCI | Should -BeTrue
            }
        }

        It 'Reports no CI when the variable is absent entirely' {
            InModuleScope $script:moduleName {
                (Resolve-ShpCiProfile).IsCI | Should -BeFalse
            }
        }
    }

    Context 'Non-interactive resolution' {
        It 'Turns unattended mode on for a CI runner that did not ask' {
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile
                $resolved.NonInteractive       | Should -BeTrue
                $resolved.NonInteractiveSource | Should -Be 'CIEnvironment'
            }
        }

        It 'Lets an explicit -NonInteractive:$false override the CI detection' {
            # Binding, not truthiness: $false is a real answer here, and reading it
            # as "not supplied" would make the switch impossible to turn off.
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile -NonInteractive $false
                $resolved.NonInteractive       | Should -BeFalse
                $resolved.NonInteractiveSource | Should -Be 'Parameter'
            }
        }

        It 'Honours an explicit -NonInteractive off a runner' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile -NonInteractive $true
                $resolved.NonInteractive       | Should -BeTrue
                $resolved.NonInteractiveSource | Should -Be 'Parameter'
            }
        }

        It 'Leaves unattended mode off when nothing asks for it' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile
                $resolved.NonInteractive       | Should -BeFalse
                $resolved.NonInteractiveSource | Should -Be 'Default'
            }
        }
    }

    Context 'Copilot backend gate' {
        It 'Refuses the Copilot backend in CI, with an error naming the opt-out' {
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile
                $resolved.CopilotBackendAllowedInCI | Should -BeFalse
                $resolved.BackendGateError          | Should -Not -BeNullOrEmpty
                $resolved.BackendGateError.FullyQualifiedErrorId | Should -Be 'ShpCopilotBackendInCi'
                $resolved.BackendGateError.Exception.Message     | Should -BeLike '*SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI*'
                $resolved.BackendGateError.Exception.Message     | Should -BeLike '*SHELLPILOT_API_BASE*'
            }
        }

        It 'Permits the Copilot backend in CI once the opt-out is set' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'true'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile
                $resolved.CopilotBackendAllowedInCI | Should -BeTrue
                $resolved.BackendGateError          | Should -BeNullOrEmpty
            }
        }

        It 'Does not accept a falsy opt-out value' {
            $env:CI = 'true'
            $env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI = 'false'

            InModuleScope $script:moduleName {
                (Resolve-ShpCiProfile).CopilotBackendAllowedInCI | Should -BeFalse
            }
        }

        It 'Permits an alternative backend in CI without any opt-out' {
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile -ApiBase 'https://models.example/v1'
                $resolved.CopilotBackendAllowedInCI | Should -BeTrue
                $resolved.BackendGateError          | Should -BeNullOrEmpty
            }
        }

        It 'Leaves the Copilot backend alone off a runner' {
            InModuleScope $script:moduleName {
                $resolved = Resolve-ShpCiProfile
                $resolved.CopilotBackendAllowedInCI | Should -BeTrue
                $resolved.BackendGateError          | Should -BeNullOrEmpty
            }
        }

        It 'Gates on CI itself, not on the resolved unattended mode' {
            # -NonInteractive:$false says "there is a person here", which is not the
            # same claim as "this entitlement may be spent by a machine".
            $env:CI = 'true'

            InModuleScope $script:moduleName {
                (Resolve-ShpCiProfile -NonInteractive $false).CopilotBackendAllowedInCI | Should -BeFalse
            }
        }
    }
}
