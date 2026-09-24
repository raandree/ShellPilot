BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpNormalizedUrl' {
    Context 'Normal form' {
        It 'Normalises <Url> to <Expected>' -ForEach @(
            @{ Url = 'http://Example.COM/a'; Expected = 'http://example.com/a' }
            @{ Url = 'https://example.com'; Expected = 'https://example.com/' }
            @{ Url = 'https://example.com:443/x'; Expected = 'https://example.com/x' }
            @{ Url = 'http://example.com:80/'; Expected = 'http://example.com/' }
            @{ Url = 'https://example.com:8443/x'; Expected = 'https://example.com:8443/x' }
            @{ Url = 'https://example.com/a?token=secret#frag'; Expected = 'https://example.com/a' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Url = $Url; Expected = $Expected } {
                param($Url, $Expected)
                $normalised = ConvertTo-ShpNormalizedUrl -Url $Url
                $normalised.Ok | Should -BeTrue
                $normalised.Url | Should -BeExactly $Expected
            }
        }
    }

    Context 'Evasion' {
        It 'Collapses <Url>, so a traversal cannot reach outside an allowed prefix' -ForEach @(
            @{ Url = 'https://example.com/public/../admin'; Expected = 'https://example.com/admin' }
            @{ Url = 'https://example.com/public/%2e%2e/admin'; Expected = 'https://example.com/admin' }
            @{ Url = 'https://example.com/public/./sub'; Expected = 'https://example.com/public/sub' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Url = $Url; Expected = $Expected } {
                param($Url, $Expected)
                (ConvertTo-ShpNormalizedUrl -Url $Url).Url | Should -BeExactly $Expected
            }
        }

        It 'Maps a Unicode host onto its punycode form, so one host has one name' {
            InModuleScope $script:moduleName {
                # Written as an escape so this file stays ASCII: the host is
                # b-u-umlaut-c-h-e-r.example.
                $unicodeHost = 'https://b{0}cher.example/a' -f [char]0x00FC
                $unicode = ConvertTo-ShpNormalizedUrl -Url $unicodeHost
                $punycode = ConvertTo-ShpNormalizedUrl -Url 'https://xn--bcher-kva.example/a'

                $unicode.Url | Should -BeExactly $punycode.Url
            }
        }
    }

    Context 'Fails closed' {
        It 'Refuses <Url> because <Because>' -ForEach @(
            @{ Url = '/relative/path'; Because = 'it is not absolute' }
            @{ Url = 'file:///etc/passwd'; Because = 'only http and https are matched' }
            @{ Url = 'ftp://example.com/a'; Because = 'only http and https are matched' }
            @{ Url = 'https://user:pw@example.com/a'; Because = 'userinfo smuggles a credential past the host check' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Url = $Url } {
                param($Url)
                $normalised = ConvertTo-ShpNormalizedUrl -Url $Url
                $normalised.Ok | Should -BeFalse
                $normalised.Reason | Should -Not -BeNullOrEmpty
                $normalised.Url | Should -BeNullOrEmpty
            }
        }

        It 'Never returns the credential it refused' {
            InModuleScope $script:moduleName {
                $normalised = ConvertTo-ShpNormalizedUrl -Url 'https://user:hunter2@example.com/a'
                ($normalised | Out-String) | Should -Not -Match 'hunter2'
            }
        }
    }
}
