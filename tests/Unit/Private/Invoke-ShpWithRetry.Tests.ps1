BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    # Stand-in for the module's shared HttpClient, so the classifier can be
    # exercised against the error Invoke-ShpHttpRequest really raises rather
    # than against a hand-built exception. See Invoke-ShpHttpRequest.Tests.ps1.
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

Describe 'Invoke-ShpWithRetry' {
    It 'Returns the script block result on success' {
        InModuleScope $script:moduleName {
            Invoke-ShpWithRetry -ScriptBlock { 42 } | Should -Be 42
        }
    }

    It 'Does not retry a non-retryable error' {
        InModuleScope $script:moduleName {
            $script:retryCalls = 0
            { Invoke-ShpWithRetry -ScriptBlock { $script:retryCalls++; throw 'nope' } -MaxRetryCount 3 -RetryDelaySec 0 } | Should -Throw
            $script:retryCalls | Should -Be 1
        }
    }

    It 'Retries up to MaxRetryCount when the predicate says so' {
        InModuleScope $script:moduleName {
            $script:retryCalls = 0
            { Invoke-ShpWithRetry -ScriptBlock { $script:retryCalls++; throw 'transient' } -MaxRetryCount 2 -RetryDelaySec 0 -RetryOn { $true } } | Should -Throw
            $script:retryCalls | Should -Be 3
        }
    }

    It 'Succeeds after a transient failure clears' {
        InModuleScope $script:moduleName {
            $script:retryCalls = 0
            $r = Invoke-ShpWithRetry -RetryDelaySec 0 -RetryOn { $true } -ScriptBlock {
                $script:retryCalls++
                if ($script:retryCalls -lt 2) { throw 'transient' }
                'ok'
            }
            $r | Should -Be 'ok'
            $script:retryCalls | Should -Be 2
        }
    }

    Context 'Network-outage tolerance' {
        It 'Retries a connection-level failure and succeeds within the budget' {
            InModuleScope $script:moduleName {
                $script:connCalls = 0
                $r = Invoke-ShpWithRetry -RetryDelaySec 0 -NetworkOutageToleranceSec 30 -ScriptBlock {
                    $script:connCalls++
                    if ($script:connCalls -lt 3) {
                        throw [System.Net.Http.HttpRequestException]::new('Temporary failure in name resolution')
                    }
                    'ok'
                }
                $r | Should -Be 'ok'
                $script:connCalls | Should -Be 3
            }
        }

        It 'Rethrows a connection-level failure once the outage budget elapses' {
            InModuleScope $script:moduleName {
                $script:connCalls = 0
                # Deterministic clock: 0s at the first three failures (within the
                # 30s budget), then 31s at the fourth (past it) - so the call
                # rides out the outage three times and then gives up, with no
                # real waiting.
                $script:elapsedQueue = [System.Collections.Generic.Queue[double]]::new()
                @(0, 10, 20, 31) | ForEach-Object { $script:elapsedQueue.Enqueue([double]$_) }
                $provider = { $script:elapsedQueue.Dequeue() }
                {
                    Invoke-ShpWithRetry -RetryDelaySec 0 -NetworkOutageToleranceSec 30 -ElapsedProvider $provider -ScriptBlock {
                        $script:connCalls++
                        throw [System.Net.Http.HttpRequestException]::new('Connection refused')
                    }
                } | Should -Throw
                $script:connCalls | Should -Be 4
            }
        }

        It 'Does not tolerate an outage when the budget is zero' {
            InModuleScope $script:moduleName {
                $script:connCalls = 0
                {
                    Invoke-ShpWithRetry -RetryDelaySec 0 -NetworkOutageToleranceSec 0 -ScriptBlock {
                        $script:connCalls++
                        throw [System.Net.Http.HttpRequestException]::new('Connection refused')
                    }
                } | Should -Throw
                $script:connCalls | Should -Be 1
            }
        }

        It 'Retries a SocketException as a connection-level outage' {
            InModuleScope $script:moduleName {
                $script:connCalls = 0
                $r = Invoke-ShpWithRetry -RetryDelaySec 0 -NetworkOutageToleranceSec 30 -ScriptBlock {
                    $script:connCalls++
                    if ($script:connCalls -lt 2) {
                        throw [System.Net.Sockets.SocketException]::new()
                    }
                    'ok'
                }
                $r | Should -Be 'ok'
                $script:connCalls | Should -Be 2
            }
        }

        It 'Does not treat a non-connection error as an outage' {
            InModuleScope $script:moduleName {
                $script:connCalls = 0
                {
                    Invoke-ShpWithRetry -RetryDelaySec 0 -NetworkOutageToleranceSec 30 -ScriptBlock {
                        $script:connCalls++
                        throw [System.InvalidOperationException]::new('a real bug, not an outage')
                    }
                } | Should -Throw
                $script:connCalls | Should -Be 1
            }
        }
    }

    Context 'Classification of a real Invoke-ShpHttpRequest failure' {
        AfterEach {
            InModuleScope $script:moduleName { $script:ShpHttpClient = $null }
        }

        It 'Still retries a 429 raised by Invoke-ShpHttpRequest now that its message carries the response body' {
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"message":"rate limited, retry later"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                $options = @{ Method = 'Post'; Uri = 'https://api.example/chat/completions'; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpHttpRequest @p }
                } | Should -Throw
            }

            # One initial attempt plus MaxRetryCount retries: the status-code
            # classification survived the message change.
            $client.CallCount | Should -Be 3
        }

        It 'Still refuses to retry a 400 raised by Invoke-ShpHttpRequest' {
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"code":"unsupported_api_for_model"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                $options = @{ Method = 'Post'; Uri = 'https://api.example/chat/completions'; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpHttpRequest @p }
                } | Should -Throw
            }

            $client.CallCount | Should -Be 1
        }

        It 'Hands the structured error detail through to the caller when it gives up' {
            # The wrapper rethrows with a bare `throw`. Invoke-Shp reads
            # $_.ErrorDetails.Message and can branch on $_.TargetObject.ErrorCode,
            # so both have to survive that rethrow or the structured access is
            # only reachable by calling the sender directly.
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"message":"nope","code":"unsupported_api_for_model"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                $options = @{ Method = 'Post'; Uri = 'https://api.example/chat/completions'; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpHttpRequest @p }
                } | Should -Throw -PassThru
            }

            ($err.ErrorDetails.Message | ConvertFrom-Json).error.code | Should -Be 'unsupported_api_for_model'
            $err.TargetObject.ErrorCode | Should -Be 'unsupported_api_for_model'
            $err.TargetObject.StatusCode | Should -Be 400
            $err.Exception.Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::BadRequest)
        }
    }
}
