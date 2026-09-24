BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpUrlPattern' {
    Context 'Compilation' {
        It 'Matches <Url> against <Glob>: <Expected>' -ForEach @(
            @{ Glob = 'https://example.com/**'; Url = 'https://example.com/'; Expected = $true }
            @{ Glob = 'https://example.com/**'; Url = 'https://example.com/deep/page'; Expected = $true }
            @{ Glob = 'https://example.com/**'; Url = 'https://evil.example.com/'; Expected = $false }
            @{ Glob = 'https://example.com/**'; Url = 'https://example.com.evil/'; Expected = $false }
            @{ Glob = 'https://example.com/docs/*'; Url = 'https://example.com/docs/a'; Expected = $true }
            @{ Glob = 'https://example.com/docs/*'; Url = 'https://example.com/docs/a/b'; Expected = $false }
            @{ Glob = 'https://example.com/only'; Url = 'https://example.com/only'; Expected = $true }
            @{ Glob = 'https://example.com/only'; Url = 'https://example.com/only/more'; Expected = $false }
            @{ Glob = 'https://EXAMPLE.com/**'; Url = 'https://example.com/a'; Expected = $true }
            @{ Glob = 'http://example.com/**'; Url = 'https://example.com/a'; Expected = $false }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Glob = $Glob; Url = $Url; Expected = $Expected } {
                param($Glob, $Url, $Expected)
                $pattern = ConvertTo-ShpUrlPattern -Glob $Glob
                ($Url -match $pattern) | Should -Be $Expected
            }
        }

        It 'Keeps the path case-sensitive, because a URL path is not a file path' {
            InModuleScope $script:moduleName {
                $pattern = ConvertTo-ShpUrlPattern -Glob 'https://example.com/Docs/**'
                ('https://example.com/Docs/a' -match $pattern) | Should -BeTrue
                ('https://example.com/docs/a' -match $pattern) | Should -BeFalse
            }
        }
    }

    Context 'Fails closed' {
        It 'Refuses <Glob>' -ForEach @(
            @{ Glob = 'example.com/**' }
            @{ Glob = 'ftp://example.com/**' }
            @{ Glob = 'https:///**' }
            @{ Glob = 'https://user:pw@example.com/**' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Glob = $Glob } {
                param($Glob)
                $failure = $null
                try { $null = ConvertTo-ShpUrlPattern -Glob $Glob } catch { $failure = $_ }
                $failure | Should -Not -BeNullOrEmpty
            }
        }
    }
}
