BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Same stand-in the buffered sender's tests use. Invoke-ShpStreamRequest
    # calls SendAsync($request, HttpCompletionOption), so the second parameter
    # binds the completion option here and is simply unused. See
    # Invoke-ShpHttpRequest.Tests.ps1 for why the responder must be closed over.
    function New-ShpFakeHttpClient {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Responder
        )

        $client = [pscustomobject]@{ CallCount = 0; Responder = $Responder }
        $client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($request, $completionOption)
            $this.CallCount++
            [System.Threading.Tasks.Task]::FromResult((& $this.Responder $request))
        }
        $client
    }
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpStreamRequest' {
    It 'Exposes mandatory Uri, Headers and Body parameters' {
        InModuleScope $script:moduleName {
            $cmd = Get-Command -Name Invoke-ShpStreamRequest
            $cmd.Parameters['Uri'].Attributes.Mandatory     | Should -Contain $true
            $cmd.Parameters['Headers'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['Body'].Attributes.Mandatory    | Should -Contain $true
        }
    }

    It 'Throws for an invalid request URI without hitting the network' {
        InModuleScope $script:moduleName {
            { Invoke-ShpStreamRequest -Uri 'not a uri' -Headers @{ Authorization = 'Bearer x' } -Body '{}' } |
                Should -Throw
        }
    }

    Context 'Non-success responses' {
        AfterEach {
            InModuleScope $script:moduleName { $script:ShpHttpClient = $null }
        }

        It 'Bounds an oversized error body and marks the truncation' {
            # A 5xx from an intermediate proxy is a whole HTML page, and this
            # sender put it into the message whole - the buffered sender has been
            # capped since the body was first surfaced.
            $body = 'x' * 20000
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadGateway)
                $response.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'text/html')
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpStreamRequest -Uri 'https://api.example/chat/completions' -Headers @{ Authorization = 'Bearer x' } -Body '{}' } | Should -Throw -PassThru
            }

            $err.Exception.Message.Length | Should -BeLessThan 5000
            # -BeLike would read the square brackets as a character class.
            $err.Exception.Message | Should -Match ([regex]::Escape('...[truncated, original 20000 chars]'))
        }

        It 'Leaves the message wording and a short body unchanged' {
            # The wording differs from the buffered sender on purpose: this
            # exception carries no response, so the URI and status exist only in
            # the text. Bounding the body must not converge the two shapes.
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"code":"unsupported_api_for_model"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpStreamRequest -Uri 'https://api.example/chat/completions' -Headers @{ Authorization = 'Bearer x' } -Body '{}' } | Should -Throw -PassThru
            }

            $err.Exception | Should -BeOfType ([System.Net.Http.HttpRequestException])
            $err.Exception.Message | Should -BeExactly 'Copilot streaming request to ''https://api.example/chat/completions'' failed with status 400: {"error":{"code":"unsupported_api_for_model"}}'
        }

        It 'Carries the same structured error detail as the buffered sender' {
            # Streaming is the Invoke-Shp default, so without this the common path
            # is the one where a caller still has to regex an exception string.
            # It also puts the status somewhere programmatic for the first time:
            # HttpRequestException carries no response.
            $body = '{"error":{"message":"store is not supported","code":"unsupported_value","param":"store"}}'
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
                { Invoke-ShpStreamRequest -Uri 'https://api.example/chat/completions' -Headers @{ Authorization = 'Bearer x' } -Body '{}' } | Should -Throw -PassThru
            }

            ($err.ErrorDetails.Message | ConvertFrom-Json).error.code | Should -Be 'unsupported_value'
            $err.TargetObject.StatusCode | Should -Be 400
            $err.TargetObject.ErrorCode  | Should -Be 'unsupported_value'
            $err.TargetObject.Param      | Should -Be 'store'
            $err.TargetObject.RequestUri | Should -Be 'https://api.example/chat/completions'
            $err.FullyQualifiedErrorId   | Should -Be 'ShpStreamRequestFailed,Invoke-ShpStreamRequest'
            # The exception type remains caller-visible. Invoke-ShpWithRetry reads
            # TargetObject.StatusCode before the type, while a transport exception
            # with no structured status remains a connection-level outage.
            $err.Exception | Should -BeOfType ([System.Net.Http.HttpRequestException])
        }

        It 'Explains a gateway 413, which says only "Request Entity Too Large"' {
            # The gateway refuses on BYTES, before the model, so no token count
            # explains it and its body names neither the size sent nor the size
            # allowed. Both have to come from this side.
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::RequestEntityTooLarge)
                $response.Content = [System.Net.Http.StringContent]::new('Request Entity Too Large', [System.Text.Encoding]::UTF8, 'text/plain')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder
            $body = '{"x":"' + ('y' * 1000) + '"}'

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client; Body = $body } {
                param($Client, $Body)
                $script:ShpHttpClient = $Client
                { Invoke-ShpStreamRequest -Uri 'https://api.example/chat/completions' -Headers @{ Authorization = 'Bearer x' } -Body $Body } | Should -Throw -PassThru
            }

            $err.ErrorDetails.Message | Should -BeLike '*Request Entity Too Large*'
            $err.ErrorDetails.Message | Should -BeLike '*1,008 bytes*'
            $err.ErrorDetails.Message | Should -BeLike '*5,242,880*'
            $err.ErrorDetails.Message | Should -BeLike '*images*'
            $err.TargetObject.StatusCode | Should -Be 413
        }

        It 'Leaves a token-overflow 413 to speak for itself' {
            # The other 413 is the model's context window and carries a JSON error
            # object that already names the cause; byte advice would misdirect.
            $body = '{"error":{"message":"prompt token count exceeds the limit","code":"model_max_prompt_tokens_exceeded"}}'
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::RequestEntityTooLarge)
                $response.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                { Invoke-ShpStreamRequest -Uri 'https://api.example/chat/completions' -Headers @{ Authorization = 'Bearer x' } -Body '{}' } | Should -Throw -PassThru
            }

            $err.ErrorDetails.Message | Should -Not -BeLike '*base64*'
            ($err.ErrorDetails.Message | ConvertFrom-Json).error.code | Should -Be 'model_max_prompt_tokens_exceeded'
        }
    }
}
