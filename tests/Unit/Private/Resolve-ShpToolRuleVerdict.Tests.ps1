BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpToolRuleVerdict' {
    AfterEach { InModuleScope $script:moduleName { Clear-ShpToolPolicy } }

    It 'Allows a target one rule of the kind covers' {
        InModuleScope $script:moduleName {
            Set-ShpToolPolicy -Rule @('Tool(load_skill)')

            (Resolve-ShpToolRuleVerdict -Kind 'Tool' -Target 'load_skill' -Subject 'tool').Allowed | Should -BeTrue
        }
    }

    It 'Lets a deny beat an allow whatever order they were written in' {
        InModuleScope $script:moduleName {
            Set-ShpToolPolicy -Rule @('!Tool(ask_user)', 'Tool(*)')

            $verdict = Resolve-ShpToolRuleVerdict -Kind 'Tool' -Target 'ask_user' -Subject 'tool'
            $verdict.Allowed | Should -BeFalse
            $verdict.Reason | Should -Match '!Tool\(ask_user\)'
        }
    }

    It 'Ignores rules of a different kind' {
        InModuleScope $script:moduleName {
            Set-ShpToolPolicy -Rule @('Mcp(files/*)', 'Tool(load_skill)')

            (Resolve-ShpToolRuleVerdict -Kind 'Tool' -Target 'files/read' -Subject 'tool').Allowed | Should -BeFalse
        }
    }

    It 'Denies a target no rule of the kind matches, and names the target' {
        InModuleScope $script:moduleName {
            Set-ShpToolPolicy -Rule @('Tool(load_skill)')

            $verdict = Resolve-ShpToolRuleVerdict -Kind 'Tool' -Target 'run_anything' -Subject 'tool'
            $verdict.Allowed | Should -BeFalse
            $verdict.Target | Should -BeExactly 'run_anything'
            $verdict.Reason | Should -Match 'run_anything'
        }
    }
}
