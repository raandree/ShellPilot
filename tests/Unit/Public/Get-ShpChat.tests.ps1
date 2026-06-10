BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Get-ShpChat' {
    AfterEach {
        InModuleScope $script:moduleName { $script:ShpChat = @() }
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'Get-ShpChat' -Module $script:moduleName | Should -Not -BeNullOrEmpty
    }

    It 'Returns nothing when no conversation has started' {
        @(Get-ShpChat).Count | Should -Be 0
    }

    It 'Returns the stored conversation turns' {
        InModuleScope $script:moduleName {
            $script:ShpChat = @(
                [pscustomobject]@{ role = 'user';      content = 'hi' }
                [pscustomobject]@{ role = 'assistant'; content = 'hello' }
            )
        }
        $chat = @(Get-ShpChat)
        $chat.Count      | Should -Be 2
        $chat[0].role    | Should -Be 'user'
        $chat[1].content | Should -Be 'hello'
    }
}
