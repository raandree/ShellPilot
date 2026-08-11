BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Stand-in for the module's shared HttpClient. Invoke-ShpHttpRequest only
    # calls SendAsync(...).GetAwaiter().GetResult(), so a script method returning
    # a completed Task over a real HttpResponseMessage drives the whole buffered
    # path - including the real IsSuccessStatusCode and body read - with no
    # network. Assigning it to $script:ShpHttpClient is enough, because
    # Get-ShpHttpClient returns that cached instance when it is set. The
    # responder must build its response from .NET types alone and be closed over
    # with GetNewClosure(): it runs from the module's session state, where a
    # function defined in this test file is not resolvable.
    function New-ShpFakeHttpClient {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Responder
        )

        $client = [pscustomobject]@{ CallCount = 0; Responder = $Responder }
        $client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($request, $cancelToken)
            $this.CallCount++
            [System.Threading.Tasks.Task]::FromResult((& $this.Responder $request))
        }
        $client
    }
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpHttpRequest' {
    It 'Exposes a mandatory Uri parameter' {
        InModuleScope $script:moduleName {
            $cmd = Get-Command -Name Invoke-ShpHttpRequest
            $cmd.Parameters['Uri'].Attributes.Mandatory | Should -Contain $true
        }
    }

    It 'Reuses the shared HttpClient across requests instead of constructing one per call' {
        InModuleScope $script:moduleName {
            $script:ShpHttpClient = $null
            # A relative URI makes SendAsync fail fast (no BaseAddress) with no
            # network I/O, but only after the shared client has been obtained - so
            # the module-scoped client is created once and reused on the next call.
            try { Invoke-ShpHttpRequest -Uri 'relative/one' -Body '{}' } catch { }
            $firstClient = $script:ShpHttpClient
            try { Invoke-ShpHttpRequest -Uri 'relative/two' -Body '{}' } catch { }
            $secondClient = $script:ShpHttpClient

            $firstClient | Should -Not -BeNullOrEmpty
            [object]::ReferenceEquals($firstClient, $secondClient) | Should -BeTrue
        }
    }

    Context 'Non-success responses' {
        AfterEach {
            InModuleScope $script:moduleName { $script:ShpHttpClient = $null }
        }

        It 'Puts the service error body into the raised error so the caller can read what was refused' {
            $body = '{"error":{"message":"model \"gpt-5.5\" is not accessible via the /chat/completions endpoint","code":"unsupported_api_for_model"}}'
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpHttpRequest -Uri 'https://api.example/chat/completions' -Body '{}' } | Should -Throw -PassThru
            }

            $err.Exception.Message | Should -BeLike '*unsupported_api_for_model*'
            $err.Exception.Message | Should -BeLike '*not accessible via the /chat/completions endpoint*'
            $err.Exception.Message | Should -BeLike '*400 (Bad Request)*'
        }

        It 'Keeps raising HttpResponseException with the live response so the retry classifier still sees the status' {
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"message":"rate limited"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpHttpRequest -Uri 'https://api.example/chat/completions' -Body '{}' } | Should -Throw -PassThru
            }

            $err.Exception | Should -BeOfType ([Microsoft.PowerShell.Commands.HttpResponseException])
            $err.Exception.Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::TooManyRequests)
        }

        It 'Bounds an oversized error body and marks the truncation' {
            $body = 'x' * 20000
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::InternalServerError)
                $response.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'text/html')
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpHttpRequest -Uri 'https://api.example/chat/completions' -Body '{}' } | Should -Throw -PassThru
            }

            $err.Exception.Message.Length | Should -BeLessThan 5000
            # -BeLike would read the square brackets as a character class.
            $err.Exception.Message | Should -Match ([regex]::Escape('...[truncated, original 20000 chars]'))
        }

        It 'Leaves the message unchanged when the service returns an empty body' {
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadGateway)
                $response.Content = [System.Net.Http.StringContent]::new('', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpHttpRequest -Uri 'https://api.example/chat/completions' -Body '{}' } | Should -Throw -PassThru
            }

            $err.Exception.Message | Should -BeExactly 'Response status code does not indicate success: 502 (Bad Gateway).'
        }
    }
}
