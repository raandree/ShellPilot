BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-GlobFilesTool' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'sub/deep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root 'top.ps1') -Value 'top'
        Set-Content -LiteralPath (Join-Path $script:root 'notes.md') -Value 'notes'
        Set-Content -LiteralPath (Join-Path $script:root 'sub/inner.ps1') -Value 'inner'
        Set-Content -LiteralPath (Join-Path $script:root 'sub/deep/deepest.ps1') -Value 'deepest'
    }

    AfterEach { InModuleScope $script:moduleName { Clear-ShpToolPolicy } }

    It 'Finds files at any depth with ** and reports how many matched' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '**/*.ps1' | ConvertFrom-Json

            $obj.count     | Should -Be 3
            $obj.truncated | Should -BeFalse
            ($obj.matches -join ';') | Should -Match 'top\.ps1'
            ($obj.matches -join ';') | Should -Match 'inner\.ps1'
            ($obj.matches -join ';') | Should -Match 'deepest\.ps1'
            ($obj.matches -join ';') | Should -Not -Match 'notes\.md'
        }
    }

    It 'Keeps a single * inside one segment' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '*.ps1' | ConvertFrom-Json

            $obj.count | Should -Be 1
            ($obj.matches -join ';') | Should -Match 'top\.ps1'
        }
    }

    It 'Returns an empty match list rather than an error when nothing matches' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '**/*.nomatch' | ConvertFrom-Json

            $obj.count   | Should -Be 0
            $obj.error   | Should -BeNullOrEmpty
        }
    }

    It 'Returns an error envelope when the search root does not exist' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GlobFilesTool -Path (Join-Path $Root 'no-such-dir') -Pattern '*' | ConvertFrom-Json

            $obj.error | Should -Not -BeNullOrEmpty
        }
    }

    It 'Refuses an absolute pattern rather than searching somewhere else' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            # The search root decides where to look; an absolute pattern would
            # silently move the search outside the root the policy just cleared.
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '/etc/*' | ConvertFrom-Json

            $obj.error | Should -Match 'relative'
        }
    }

    It 'Caps the number of matches and says the result was capped' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '**/*.ps1' -MaxResult 2 | ConvertFrom-Json

            $obj.count     | Should -Be 2
            $obj.truncated | Should -BeTrue
        }
    }

    It 'Caps the returned characters and says the result was capped' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '**/*.ps1' -MaxChars 1 | ConvertFrom-Json

            $obj.count     | Should -BeLessThan 3
            $obj.truncated | Should -BeTrue
        }
    }

    It 'Excludes a hit the tool policy does not allow, and does not do it silently' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            # A glob rooted at an allowed directory can still match a path no
            # Read rule covers, so every hit is checked - not just the root.
            $resolvedRoot = Resolve-ShpRealPath -Path $Root
            Set-ShpToolPolicy -Rule @(('Read({0}/sub/**)' -f $resolvedRoot))

            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '**/*.ps1' | ConvertFrom-Json

            $obj.count            | Should -Be 2
            $obj.excludedByPolicy | Should -Be 1
            ($obj.matches -join ';') | Should -Not -Match 'top\.ps1'
        }
    }

    It 'Reports no exclusions when no policy is set' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            Clear-ShpToolPolicy
            $obj = Invoke-GlobFilesTool -Path $Root -Pattern '**/*.ps1' | ConvertFrom-Json

            $obj.excludedByPolicy | Should -Be 0
        }
    }
}
