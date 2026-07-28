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
            Mock Test-ShpUrlSafe { @{ Allowed = $true; Reason = ''; Uri = [uri]'https://example.com' } }
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
            Mock Test-ShpUrlSafe { @{ Allowed = $true; Reason = ''; Uri = [uri]'https://bad.example' } }
            Mock Invoke-WebRequest { throw 'boom' }
            $obj = Invoke-FetchUrlTool -Url 'https://bad.example' | ConvertFrom-Json
            $obj.error | Should -Match 'boom'
        }
    }

    It 'Refuses a blocked URL without issuing a request' {
        InModuleScope $script:moduleName {
            Mock Invoke-WebRequest { throw 'the request must never be made' }
            $obj = Invoke-FetchUrlTool -Url 'http://169.254.169.254/latest/meta-data/' | ConvertFrom-Json
            $obj.error | Should -Match 'Blocked'
            $obj.error | Should -Match 'link-local'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
    }

    It 'Refuses a non-http scheme' {
        InModuleScope $script:moduleName {
            Mock Invoke-WebRequest { throw 'the request must never be made' }
            $obj = Invoke-FetchUrlTool -Url 'file:///C:/Windows/win.ini' | ConvertFrom-Json
            $obj.error | Should -Match 'Blocked'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
    }

    It 'Re-checks the target of a redirect and refuses a private one' {
        InModuleScope $script:moduleName {
            # Only the first hop is treated as public; the redirect target falls
            # through to the real guard, which rejects the metadata address.
            Mock Test-ShpUrlSafe -ParameterFilter { $Url -eq 'https://public.example/go' } {
                @{ Allowed = $true; Reason = ''; Uri = [uri]$Url }
            }
            Mock Test-ShpUrlSafe {
                @{ Allowed = $false; Reason = 'a link-local address (cloud metadata range)'; Uri = $null }
            }
            Mock Invoke-WebRequest {
                [pscustomobject]@{
                    Content    = ''
                    StatusCode = 302
                    Headers    = @{ Location = 'http://169.254.169.254/latest/meta-data/' }
                }
            }
            $obj = Invoke-FetchUrlTool -Url 'https://public.example/go' | ConvertFrom-Json
            $obj.error | Should -Match 'Blocked'
            $obj.url   | Should -Match '169\.254\.169\.254'
            # One request for the first hop, none for the blocked target.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }
    }

    It 'Follows a redirect whose target is also public' {
        InModuleScope $script:moduleName {
            Mock Test-ShpUrlSafe { @{ Allowed = $true; Reason = ''; Uri = [uri]$Url } }
            $script:hop = 0
            Mock Invoke-WebRequest {
                $script:hop++
                if ($script:hop -eq 1) {
                    [pscustomobject]@{ Content = ''; StatusCode = 302; Headers = @{ Location = 'https://other.example/final' } }
                } else {
                    [pscustomobject]@{ Content = '<p>done</p>'; StatusCode = 200; Headers = @{ 'Content-Type' = 'text/html' } }
                }
            }
            $obj = Invoke-FetchUrlTool -Url 'https://public.example/go' | ConvertFrom-Json
            $obj.status | Should -Be 200
            $obj.text   | Should -Match 'done'
            $obj.url    | Should -Be 'https://other.example/final'
        }
    }

    It 'Allows a private address when the caller opts in' {
        InModuleScope $script:moduleName {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Content = '<p>intranet</p>'; StatusCode = 200; Headers = @{ 'Content-Type' = 'text/html' } }
            }
            $obj = Invoke-FetchUrlTool -Url 'http://10.1.2.3/status' -AllowPrivateNetwork | ConvertFrom-Json
            $obj.status | Should -Be 200
            $obj.text   | Should -Match 'intranet'
        }
    }
}
