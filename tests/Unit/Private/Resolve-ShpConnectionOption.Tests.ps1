BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpConnectionOption' {
    BeforeEach { InModuleScope $script:moduleName { Clear-ShpContext } }
    AfterEach  { InModuleScope $script:moduleName { Clear-ShpContext } }

    Context 'Resolution order' {
        It 'Falls back to the built-in defaults when nothing is set' {
            InModuleScope $script:moduleName {
                $c = Resolve-ShpConnectionOption

                # 0 means "no explicit timeout": the shared HttpClient is built
                # with an infinite timeout so a streamed turn is not cut off.
                $c.TimeoutSec                | Should -Be 0
                $c.MaxRetryCount             | Should -Be $script:DefaultMaxRetryCount
                $c.RetryDelaySec             | Should -Be $script:DefaultRetryDelaySec
                $c.NetworkOutageToleranceSec | Should -Be $script:DefaultNetworkOutageToleranceSec
            }
        }

        It 'Prefers the session context over the built-in defaults' {
            InModuleScope $script:moduleName {
                Set-ShpContext -TimeoutSec 11 -MaxRetryCount 7 -RetryDelaySec 5 -NetworkOutageToleranceSec 90

                $c = Resolve-ShpConnectionOption

                $c.TimeoutSec                | Should -Be 11
                $c.MaxRetryCount             | Should -Be 7
                $c.RetryDelaySec             | Should -Be 5
                $c.NetworkOutageToleranceSec | Should -Be 90
            }
        }

        It 'Prefers an explicit parameter over the session context' {
            InModuleScope $script:moduleName {
                Set-ShpContext -TimeoutSec 11 -MaxRetryCount 7 -RetryDelaySec 5 -NetworkOutageToleranceSec 90

                $c = Resolve-ShpConnectionOption -TimeoutSec 1 -MaxRetryCount 2 -RetryDelaySec 3 -NetworkOutageToleranceSec 4

                $c.TimeoutSec                | Should -Be 1
                $c.MaxRetryCount             | Should -Be 2
                $c.RetryDelaySec             | Should -Be 3
                $c.NetworkOutageToleranceSec | Should -Be 4
            }
        }

        It 'Resolves each option independently' {
            InModuleScope $script:moduleName {
                Set-ShpContext -MaxRetryCount 7

                $c = Resolve-ShpConnectionOption -TimeoutSec 1

                $c.TimeoutSec    | Should -Be 1                                   # parameter
                $c.MaxRetryCount | Should -Be 7                                   # context
                $c.RetryDelaySec | Should -Be $script:DefaultRetryDelaySec         # default
            }
        }
    }

    Context 'Zero is a value, not an omission' {
        It 'Keeps an explicit zero rather than reading it as "not supplied"' {
            InModuleScope $script:moduleName {
                Set-ShpContext -MaxRetryCount 7 -RetryDelaySec 5 -NetworkOutageToleranceSec 90

                # 0 retries, 0 backoff and 0 outage tolerance are all meaningful
                # settings - an evaluation harness pins them for determinism.
                $c = Resolve-ShpConnectionOption -MaxRetryCount 0 -RetryDelaySec 0 -NetworkOutageToleranceSec 0

                $c.MaxRetryCount             | Should -Be 0
                $c.RetryDelaySec             | Should -Be 0
                $c.NetworkOutageToleranceSec | Should -Be 0
            }
        }

        It 'Keeps a session-context zero rather than falling through to the default' {
            InModuleScope $script:moduleName {
                Set-ShpContext -MaxRetryCount 0 -RetryDelaySec 0 -NetworkOutageToleranceSec 0

                $c = Resolve-ShpConnectionOption

                $c.MaxRetryCount             | Should -Be 0
                $c.RetryDelaySec             | Should -Be 0
                $c.NetworkOutageToleranceSec | Should -Be 0
            }
        }
    }
}
