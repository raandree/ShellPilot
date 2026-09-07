BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpBoundedHttpRequest' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:attempts = 0
            $script:client = [pscustomobject]@{ Calls = 0; Body = '{"input_tokens":12}'; Status = 200 }
            $script:client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
                param($Request, $Completion, $Cancellation)
                $this.Calls++
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$this.Status)
                $response.Content = [Net.Http.StringContent]::new($this.Body)
                $response.Headers.TryAddWithoutValidation('Authorization', 'response-secret-canary') | Out-Null
                [System.Threading.Tasks.Task]::FromResult($response)
            }
            $script:parameters = @{
                Client = $script:client
                Uri = [uri]'https://api.enterprise.githubcopilot.com/v1/messages/count_tokens'
                Method = 'POST'
                Headers = @{ Authorization = 'Bearer header-secret-canary' }
                Body = '{"model":"claude-haiku-4.5"}'
                MaxRequestBytes = 1024
                MaxResponseBytes = 128
                TimeoutSeconds = 2
                ReserveAttempt = { $script:attempts++ }
            }
        }
    }

    It 'returns bounded JSON without forwarding response authorization headers' {
        InModuleScope $script:moduleName {
            $response = Invoke-ShpBoundedHttpRequest @script:parameters
            ($response.Content | ConvertFrom-Json).input_tokens | Should -Be 12
            $script:attempts | Should -Be 1
            $script:client.Calls | Should -Be 1
            ($response | ConvertTo-Json -Depth 8) | Should -Not -Match 'secret-canary'
        }
    }

    It 'refuses an unapproved destination <Address> before reserving or sending' -ForEach @(
        @{ Address = 'https://api.enterprise.githubcopilot.com.evil.example/v1/messages/count_tokens' }
        @{ Address = 'http://api.enterprise.githubcopilot.com/v1/messages/count_tokens' }
        @{ Address = 'https://api.enterprise.githubcopilot.com:444/v1/messages/count_tokens' }
        @{ Address = 'https://api.enterprise.githubcopilot.com/other' }
        @{ Address = 'https://user@api.enterprise.githubcopilot.com/models' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Address = $Address } {
            param($Address)
            $script:parameters.Uri = [uri]$Address
            $failure = { Invoke-ShpBoundedHttpRequest @script:parameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpBoundedRequestRefused'
            $script:client.Calls | Should -Be 0
            $script:attempts | Should -Be 0
        }
    }

    It 'refuses an oversized request before dispatch' {
        InModuleScope $script:moduleName {
            $script:parameters.Body = 'x' * 1025
            $failure = { Invoke-ShpBoundedHttpRequest @script:parameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpBoundedRequestRefused'
            $script:client.Calls | Should -Be 0
        }
    }

    It 'refuses an oversized response without returning partial data' {
        InModuleScope $script:moduleName {
            $script:client.Body = 'x' * 129
            $failure = { Invoke-ShpBoundedHttpRequest @script:parameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpBoundedResponseRefused'
            $script:client.Calls | Should -Be 1
        }
    }

    It 'does not follow or retry a redirect response' {
        InModuleScope $script:moduleName {
            $script:client.Status = 302
            $failure = { Invoke-ShpBoundedHttpRequest @script:parameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpBoundedResponseRefused'
            $script:client.Calls | Should -Be 1
            $script:attempts | Should -Be 1
        }
    }

    It 'refuses a cancelled operation before reserving or sending' {
        InModuleScope $script:moduleName {
            $cancellation = [System.Threading.CancellationTokenSource]::new()
            try {
                $cancellation.Cancel()
                $script:parameters.CancellationToken = $cancellation.Token
                $failure = { Invoke-ShpBoundedHttpRequest @script:parameters } | Should -Throw -PassThru
                $failure.FullyQualifiedErrorId | Should -Match '^ShpBoundedRequestCancelled'
                $script:client.Calls | Should -Be 0
                $script:attempts | Should -Be 0
            } finally { $cancellation.Dispose() }
        }
    }

    It 'does not disclose reservation errors or headers' {
        InModuleScope $script:moduleName {
            $script:parameters.ReserveAttempt = { throw 'reservation-secret-canary' }
            $failure = { Invoke-ShpBoundedHttpRequest @script:parameters } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpBoundedRequestRefused'
            ($failure | Out-String) | Should -Not -Match 'secret-canary'
            $script:client.Calls | Should -Be 0
        }
    }
}
