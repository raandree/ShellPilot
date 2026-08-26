BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ShpRedactionPolicy' {
    AfterEach { Clear-ShpRedactionPolicy }

    Context 'Command surface' {
        It 'Should export the redaction policy cmdlets' {
            foreach ($name in 'Set-ShpRedactionPolicy', 'Get-ShpRedactionPolicy', 'Clear-ShpRedactionPolicy') {
                Get-Command -Name $name -Module $script:moduleName | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should support ShouldProcess, because it changes what a call redacts' {
            (Get-Command -Name 'Set-ShpRedactionPolicy').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context 'Parsing' {
        It 'Accepts the documented Name(Pattern) rule shape' {
            Set-ShpRedactionPolicy -Rule @('InternalToken(itk_[A-Za-z0-9]{10,})', 'Ticket(TCK-[0-9]{4,})')

            $policy = Get-ShpRedactionPolicy
            $policy.Rule.Count | Should -Be 2
            ($policy.Rule | Where-Object Name -eq 'InternalToken').Pattern | Should -Be 'itk_[A-Za-z0-9]{10,}'
        }

        It 'Derives the placeholder from the rule name' {
            Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'

            (Get-ShpRedactionPolicy).Rule[0].Replacement | Should -Be '[redacted:InternalToken]'
        }

        It 'Refuses a rule that is not Name(Pattern) rather than ignoring it' {
            { Set-ShpRedactionPolicy -Rule @('NotARule') } | Should -Throw
            { Set-ShpRedactionPolicy -Rule @('(missing-name)') } | Should -Throw
        }

        It 'Refuses a rule whose pattern does not compile as a regex' {
            { Set-ShpRedactionPolicy -Rule 'Bad(itk_[)' } | Should -Throw
        }

        It 'Leaves the previous policy untouched when the new one is refused' {
            Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'
            { Set-ShpRedactionPolicy -Rule 'Bad(itk_[)' } | Should -Throw

            (Get-ShpRedactionPolicy).Rule.Count | Should -Be 1
        }

        It 'Reports no custom policy until one is set' {
            Clear-ShpRedactionPolicy
            Get-ShpRedactionPolicy | Should -BeNullOrEmpty
        }
    }

    Context 'Loading from a file' {
        It 'Loads rules from an explicitly supplied file' {
            $file = Join-Path $TestDrive 'redaction-policy.txt'
            @('# comment', '', 'InternalToken(itk_[A-Za-z0-9]{10,})') | Set-Content -LiteralPath $file

            Set-ShpRedactionPolicy -Path $file

            (Get-ShpRedactionPolicy).Rule.Count | Should -Be 1
        }

        It 'Refuses a missing file' {
            { Set-ShpRedactionPolicy -Path (Join-Path $TestDrive 'no-such-file.txt') } | Should -Throw
        }
    }

    Context 'Clearing' {
        It 'Restores only-built-in-patterns after Clear-ShpRedactionPolicy' {
            Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'
            Clear-ShpRedactionPolicy

            Get-ShpRedactionPolicy | Should -BeNullOrEmpty
        }
    }
}
