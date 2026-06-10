BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Read-ShpUserInput' {
    It 'Returns the answer when the console provides one' {
        InModuleScope $script:moduleName {
            Mock Write-Host {}
            Mock Read-Host { 'blue' }
            $obj = Read-ShpUserInput -Question 'Which colour?' | ConvertFrom-Json
            $obj.answered | Should -BeTrue
            $obj.answer   | Should -Be 'blue'
            $obj.question | Should -Be 'Which colour?'
        }
    }

    It 'Reports it could not get an answer when the console is unavailable' {
        InModuleScope $script:moduleName {
            Mock Write-Host {}
            Mock Read-Host { throw 'Windows PowerShell is in NonInteractive mode.' }
            $obj = Read-ShpUserInput -Question 'Which colour?' | ConvertFrom-Json
            $obj.answered | Should -BeFalse
            $obj.error    | Should -Not -BeNullOrEmpty
        }
    }
}
