BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop

    if (-not ('ShellPilot.Tests.ThrowingHttpContent' -as [type])) {
        Add-Type -TypeDefinition @'
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;

namespace ShellPilot.Tests
{
    public sealed class ThrowingHttpContent : HttpContent
    {
        public bool Disposed { get; private set; }

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext context)
        {
            return Task.FromException(new IOException("response body read failed"));
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }

        protected override void Dispose(bool disposing)
        {
            Disposed = true;
            base.Dispose(disposing);
        }
    }
}
'@
    }

    # Stand-in for the module's shared HttpClient, so the classifier can be
    # exercised against the error Invoke-ShpHttpRequest really raises rather
    # than against a hand-built exception. See Invoke-ShpHttpRequest.Tests.ps1.
    function New-ShpFakeHttpClient {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Responder
        )

        $client = [pscustomobject]@{ CallCount = 0; Responder = $Responder; LastRequest = $null }
        $client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($request, $cancelToken)
            $this.CallCount++
            $this.LastRequest = $request
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

    # Invoke-ShpBatch runs several callers concurrently, so a purely
    # deterministic backoff synchronises: every worker refused by the same 429
    # would sleep an identical duration and re-fire together, recreating the
    # burst that caused the refusal.
    Context 'Backoff jitter' {
        It 'Keeps a zero retry delay at exactly zero' {
            InModuleScope $script:moduleName {
                Mock Start-Sleep { }

                $script:retryCalls = 0
                { Invoke-ShpWithRetry -ScriptBlock { $script:retryCalls++; throw 'transient' } -MaxRetryCount 2 -RetryDelaySec 0 -RetryOn { $true } } | Should -Throw

                $script:retryCalls | Should -Be 3
                Should -Invoke Start-Sleep -Times 0 -Exactly
            }
        }

        It 'Keeps each jittered delay between half and all of the exponential backoff' {
            InModuleScope $script:moduleName {
                $script:sleptFor = @()
                Mock Start-Sleep { $script:sleptFor += $Seconds }

                $script:retryCalls = 0
                { Invoke-ShpWithRetry -ScriptBlock { $script:retryCalls++; throw 'transient' } -MaxRetryCount 3 -RetryDelaySec 4 -RetryOn { $true } } | Should -Throw

                @($script:sleptFor).Count | Should -Be 3
                # Attempt n backs off 4 * 2^(n-1): 4, 8, 16.
                $script:sleptFor[0] | Should -BeGreaterOrEqual 2; $script:sleptFor[0] | Should -BeLessOrEqual 4
                $script:sleptFor[1] | Should -BeGreaterOrEqual 4; $script:sleptFor[1] | Should -BeLessOrEqual 8
                $script:sleptFor[2] | Should -BeGreaterOrEqual 8; $script:sleptFor[2] | Should -BeLessOrEqual 16
            }
        }

        It 'Does not produce the same delay on every run' {
            InModuleScope $script:moduleName {
                Mock Start-Sleep { $script:sleptFor += $Seconds }

                $observed = foreach ($run in 1..12) {
                    $script:sleptFor = @()
                    $script:retryCalls = 0
                    try {
                        Invoke-ShpWithRetry -ScriptBlock { $script:retryCalls++; throw 'transient' } -MaxRetryCount 1 -RetryDelaySec 8 -RetryOn { $true }
                    } catch {
                        # expected - the point is the delay, not the outcome
                    }
                    $script:sleptFor[0]
                }

                (@($observed) | Sort-Object -Unique).Count | Should -BeGreaterThan 1
            }
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

    Context 'Classification of a real Invoke-ShpStreamRequest failure' {
        AfterEach {
            InModuleScope $script:moduleName { $script:ShpHttpClient = $null }
        }

        It 'Does not retry a 400 raised by Invoke-ShpStreamRequest' {
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"code":"model_max_prompt_tokens_exceeded"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                $script:elapsedQueue = [System.Collections.Generic.Queue[double]]::new()
                @(0, 31) | ForEach-Object { $script:elapsedQueue.Enqueue([double]$_) }
                $provider = { $script:elapsedQueue.Dequeue() }
                $options = @{ Uri = 'https://api.example/chat/completions'; Headers = @{}; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -NetworkOutageToleranceSec 30 -ElapsedProvider $provider -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpStreamRequest @p }
                } | Should -Throw -PassThru
            }

            $client.CallCount | Should -Be 1
            $err.TargetObject.StatusCode | Should -Be 400
        }

        It 'Preserves a 400 and disposes resources when reading the error body fails' {
            $content = [ShellPilot.Tests.ThrowingHttpContent]::new()
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                $response.Content = $content
                $response
            }.GetNewClosure()
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                $script:elapsedQueue = [System.Collections.Generic.Queue[double]]::new()
                @(0, 31) | ForEach-Object { $script:elapsedQueue.Enqueue([double]$_) }
                $provider = { $script:elapsedQueue.Dequeue() }
                $options = @{ Uri = 'https://api.example/chat/completions'; Headers = @{}; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -NetworkOutageToleranceSec 30 -ElapsedProvider $provider -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpStreamRequest @p }
                } | Should -Throw -PassThru
            }

            $client.CallCount | Should -Be 1
            $err.Exception | Should -BeOfType ([System.Net.Http.HttpRequestException])
            $err.TargetObject.StatusCode | Should -Be 400
            $content.Disposed | Should -BeTrue
            $requestContentError = {
                $client.LastRequest.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            } | Should -Throw -PassThru
            $requestContentError.Exception.InnerException |
                Should -BeOfType ([System.ObjectDisposedException])
        }

        It 'Retries a 429 raised by Invoke-ShpStreamRequest up to MaxRetryCount' {
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
                $options = @{ Uri = 'https://api.example/chat/completions'; Headers = @{}; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -NetworkOutageToleranceSec 0 -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpStreamRequest @p }
                } | Should -Throw -PassThru
            }

            $client.CallCount | Should -Be 3
            $err.TargetObject.StatusCode | Should -Be 429
        }

        It 'Retries a 503 raised by Invoke-ShpStreamRequest up to MaxRetryCount' {
            $responder = {
                param($request)
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::ServiceUnavailable)
                $response.Content = [System.Net.Http.StringContent]::new('{"error":{"message":"temporarily unavailable"}}', [System.Text.Encoding]::UTF8, 'application/json')
                $response
            }
            $client = New-ShpFakeHttpClient -Responder $responder

            $err = InModuleScope $script:moduleName -Parameters @{ Client = $client } {
                param($Client)
                $script:ShpHttpClient = $Client
                $options = @{ Uri = 'https://api.example/chat/completions'; Headers = @{}; Body = '{}' }
                {
                    Invoke-ShpWithRetry -MaxRetryCount 2 -RetryDelaySec 0 -NetworkOutageToleranceSec 0 -ArgumentList $options -ScriptBlock { param($p) Invoke-ShpStreamRequest @p }
                } | Should -Throw -PassThru
            }

            $client.CallCount | Should -Be 3
            $err.TargetObject.StatusCode | Should -Be 503
        }
    }
}
