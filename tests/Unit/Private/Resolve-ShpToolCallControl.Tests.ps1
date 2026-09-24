[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A control fixture must accept the typed request even when the case under test deliberately ignores it.')]
param()

BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpToolCallControl' {
    Context 'Accepted shapes' {
        It 'Accepts a scriptblock for either phase and defaults to failing closed' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }

                $control.SchemaVersion | Should -Be 1
                $control.FailPosture | Should -BeExactly 'Closed'
                $control.HasPre | Should -BeTrue
                $control.HasPost | Should -BeFalse
            }
        }

        It 'Accepts a command name, so a control can travel to a worker by reference' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{ PostToolCall = 'Get-Random' }

                $control.HasPost | Should -BeTrue
                $control.PolicyId | Should -BeExactly ''
            }
        }

        It 'Carries an explicit fail posture and policy identifier' {
            InModuleScope $script:moduleName {
                $control = Resolve-ShpToolCallControl -Control @{
                    PreToolCall = { }
                    FailPosture = 'Open'
                    PolicyId = 'contoso-v3'
                }

                $control.FailPosture | Should -BeExactly 'Open'
                $control.PolicyId | Should -BeExactly 'contoso-v3'
            }
        }
    }

    Context 'Fails closed on a control it cannot understand' {
        It 'Refuses a control with no hook at all' {
            InModuleScope $script:moduleName {
                { Resolve-ShpToolCallControl -Control @{ FailPosture = 'Closed' } } | Should -Throw '*PreToolCall*'
            }
        }

        It 'Refuses an unknown member rather than ignoring it' {
            InModuleScope $script:moduleName {
                { Resolve-ShpToolCallControl -Control @{ PreToolCall = { }; Sudo = $true } } | Should -Throw '*Sudo*'
            }
        }

        It 'Refuses a schema version it does not implement' {
            InModuleScope $script:moduleName {
                { Resolve-ShpToolCallControl -Control @{ SchemaVersion = 99; PreToolCall = { } } } | Should -Throw '*99*'
            }
        }

        It 'Refuses an unknown fail posture' {
            InModuleScope $script:moduleName {
                { Resolve-ShpToolCallControl -Control @{ PreToolCall = { }; FailPosture = 'Maybe' } } | Should -Throw
            }
        }

        It 'Refuses a hook that is neither a scriptblock nor a resolvable command' {
            InModuleScope $script:moduleName {
                { Resolve-ShpToolCallControl -Control @{ PreToolCall = 42 } } | Should -Throw
                { Resolve-ShpToolCallControl -Control @{ PreToolCall = 'No-SuchCommandExistsHere' } } | Should -Throw
            }
        }

        It 'Refuses a policy identifier that is not a bounded plain string' {
            InModuleScope $script:moduleName {
                { Resolve-ShpToolCallControl -Control @{ PreToolCall = { }; PolicyId = ('x' * 200) } } | Should -Throw
            }
        }
    }
}
