BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}
Describe 'Invoke-FetchUrlTool' {
    It 'Strips markup and returns a JSON envelope' {
        InModuleScope $script:moduleName {
            Mock Invoke-WebRequest {
                [pscustomobject]@{
                    Content    = '<html><head><style>.x{}</style></head><body><h1>Hi</h1><script>evil()</script><p>There</p></body></html>'
                    StatusCode = 200
                    Headers    = @{ 'Content-Type' = 'text/html' }
                }
            }
            $obj = Invoke-FetchUrlTool -Url 'https://example.com' | ConvertFrom-Json
            $obj.status | Should -Be 200
            $obj.text   | Should -Match 'Hi'
            $obj.text   | Should -Match 'There'
            $obj.text   | Should -Not -Match 'evil'
            $obj.text   | Should -Not -Match '<'
        }
    }

    It 'Returns an error envelope when the request fails' {
        InModuleScope $script:moduleName {
            Mock Invoke-WebRequest { throw 'boom' }
            $obj = Invoke-FetchUrlTool -Url 'https://bad.example' | ConvertFrom-Json
            $obj.error | Should -Match 'boom'
        }
    }
}
