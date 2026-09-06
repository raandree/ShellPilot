BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-GrepFilesTool' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root 'top.ps1') -Value @('first', 'needle here', 'third')
        Set-Content -LiteralPath (Join-Path $script:root 'notes.md') -Value @('needle in markdown')
        Set-Content -LiteralPath (Join-Path $script:root 'sub/inner.ps1') -Value @('a', 'b', 'c', 'needle deep')
    }

    AfterEach { InModuleScope $script:moduleName { Clear-ShpToolPolicy } }

    It 'Returns the file, the line number and the matching line only' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'needle' -Include '**/*.ps1' | ConvertFrom-Json

            $obj.count | Should -Be 2

            $top = @($obj.matches) | Where-Object { $_.path -match 'top\.ps1' } | Select-Object -First 1
            $top.line | Should -Be 2
            $top.text | Should -Be 'needle here'
            # The whole file is read_file's job; grep_files returns the line.
            $top.text | Should -Not -Match 'first'

            $inner = @($obj.matches) | Where-Object { $_.path -match 'inner\.ps1' } | Select-Object -First 1
            $inner.line | Should -Be 4
        }
    }

    It 'Searches every file under the root when no Include is given' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'needle' | ConvertFrom-Json

            $obj.count | Should -Be 3
            ($obj.matches.path -join ';') | Should -Match 'notes\.md'
        }
    }

    It 'Returns an empty match list rather than an error when nothing matches' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'haystack-only' | ConvertFrom-Json

            $obj.count | Should -Be 0
            $obj.error | Should -BeNullOrEmpty
        }
    }

    It 'Returns an error envelope for a pattern that is not a valid regex' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GrepFilesTool -Path $Root -Pattern '(unclosed' | ConvertFrom-Json

            $obj.error | Should -Not -BeNullOrEmpty
        }
    }

    It 'Returns an error envelope when the search root does not exist' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GrepFilesTool -Path (Join-Path $Root 'no-such-dir') -Pattern 'needle' | ConvertFrom-Json

            $obj.error | Should -Not -BeNullOrEmpty
        }
    }

    It 'Caps the number of matches and says the result was capped' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'needle' -MaxResult 1 | ConvertFrom-Json

            $obj.count     | Should -Be 1
            $obj.truncated | Should -BeTrue
        }
    }

    It 'Caps a very long matching line with a truncation marker' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            Set-Content -LiteralPath (Join-Path $Root 'wide.txt') -Value ('needle' + ('x' * 5000))

            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'needle' -Include '*.txt' -MaxLineChars 20 | ConvertFrom-Json

            $obj.count             | Should -Be 1
            $obj.matches[0].text   | Should -Match 'truncated'
            $obj.matches[0].text.Length | Should -BeLessThan 200
        }
    }

    It 'Excludes a file the tool policy does not allow, and does not do it silently' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            $resolvedRoot = Resolve-ShpRealPath -Path $Root
            Set-ShpToolPolicy -Rule @(('Read({0}/sub/**)' -f $resolvedRoot))

            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'needle' | ConvertFrom-Json

            $obj.count            | Should -Be 1
            $obj.excludedByPolicy | Should -Be 2
            ($obj.matches.path -join ';') | Should -Match 'inner\.ps1'
            ($obj.matches.path -join ';') | Should -Not -Match 'top\.ps1'
        }
    }

    It 'Reports no exclusions when no policy is set' {
        InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
            param($Root)
            Clear-ShpToolPolicy
            $obj = Invoke-GrepFilesTool -Path $Root -Pattern 'needle' | ConvertFrom-Json

            $obj.excludedByPolicy | Should -Be 0
        }
    }
}
