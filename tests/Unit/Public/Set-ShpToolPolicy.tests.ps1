BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ShpToolPolicy' {
    AfterEach { Clear-ShpToolPolicy }

    Context 'Command surface' {
        It 'Should export the policy cmdlets' {
            foreach ($name in 'Set-ShpToolPolicy', 'Get-ShpToolPolicy', 'Clear-ShpToolPolicy') {
                Get-Command -Name $name -Module $script:moduleName | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should support ShouldProcess, because it changes what the model may reach' {
            (Get-Command -Name 'Set-ShpToolPolicy').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context 'Parsing' {
        It 'Accepts the documented rule kinds' {
            Set-ShpToolPolicy -Rule @('Read(C:/repo/**)', 'Write(C:/repo/out/**)', 'Shell(git status)', '!Read(C:/repo/.git/**)')

            $policy = Get-ShpToolPolicy
            $policy.Rule.Count | Should -Be 4
            @($policy.Rule | Where-Object { $_.Deny }).Count | Should -Be 1
        }

        It 'Refuses an unknown rule kind rather than ignoring it' {
            # Fail closed at the point of definition: a policy that silently
            # dropped a rule it did not understand would be more permissive than
            # the caller believes.
            { Set-ShpToolPolicy -Rule @('Read(C:/repo/**)', 'Sudo(*)') } | Should -Throw '*Sudo*'
        }

        It 'Refuses a malformed rule rather than ignoring it' {
            { Set-ShpToolPolicy -Rule @('Read C:/repo/**') } | Should -Throw
            { Set-ShpToolPolicy -Rule @('Read(')            } | Should -Throw
            { Set-ShpToolPolicy -Rule @('Read()')           } | Should -Throw
        }

        It 'Leaves the previous policy untouched when the new one is refused' {
            Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')
            { Set-ShpToolPolicy -Rule @('Nope(*)') } | Should -Throw

            (Get-ShpToolPolicy).Rule.Count | Should -Be 1
        }

        It 'Reports no policy until one is set' {
            Clear-ShpToolPolicy
            Get-ShpToolPolicy | Should -BeNullOrEmpty
        }
    }

    Context 'Loading from a file' {
        It 'Loads rules from an explicitly supplied file' {
            $file = Join-Path $TestDrive 'policy.txt'
            @('# comment', '', 'Read(C:/repo/**)', 'Shell(git status)') | Set-Content -LiteralPath $file

            Set-ShpToolPolicy -Path $file

            (Get-ShpToolPolicy).Rule.Count | Should -Be 2
        }

        It 'Refuses a file it cannot parse rather than falling back to permissive' {
            $file = Join-Path $TestDrive 'bad.txt'
            @('Read(C:/repo/**)', 'garbage line') | Set-Content -LiteralPath $file

            { Set-ShpToolPolicy -Path $file } | Should -Throw
            Get-ShpToolPolicy | Should -BeNullOrEmpty
        }

        It 'Refuses a missing file' {
            { Set-ShpToolPolicy -Path (Join-Path $TestDrive 'no-such-file.txt') } | Should -Throw
        }
    }

    Context 'Clearing' {
        It 'Restores the unrestricted default' {
            Set-ShpToolPolicy -Rule @('Read(C:/repo/**)')
            Clear-ShpToolPolicy

            Get-ShpToolPolicy | Should -BeNullOrEmpty
        }
    }
}
