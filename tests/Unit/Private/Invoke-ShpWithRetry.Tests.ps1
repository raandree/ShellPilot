BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
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
}
