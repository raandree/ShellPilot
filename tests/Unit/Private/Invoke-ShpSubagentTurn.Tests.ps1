BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpSubagentTurn' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Invoke-ShpSubagentTurn' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Invoke-ShpSubagentTurn' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'The nested turn it dispatches' {
        It 'Should run with a clean context and never write back to the Session chat' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{
                        History = $History; HistoryBound = ($null -ne $History)
                        NonInteractive = [bool]$NonInteractive; DisableUserPrompts = [bool]$DisableUserPrompts
                        AsJob = [bool]$AsJob; DisableStreaming = [bool]$DisableStreaming
                    }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @('read_file'); MaxToolIterations = 4; MaxBudgetUSD = 0.02
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                }

                $script:seen.HistoryBound | Should -BeTrue
                @($script:seen.History).Count | Should -Be 0
                $script:seen.NonInteractive | Should -BeTrue
                $script:seen.DisableUserPrompts | Should -BeTrue
                $script:seen.DisableStreaming | Should -BeTrue
                $script:seen.AsJob | Should -BeFalse
            }
        }

        It 'Should pass the attenuated tool set, budget and trace through' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{
                        Tool = $Tool; MaxToolIterations = $MaxToolIterations; MaxBudgetUSD = $MaxBudgetUSD
                        TraceParent = $TraceParent; DisableTerminal = [bool]$DisableTerminal
                        AppendSystemPrompt = $AppendSystemPrompt
                    }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @('read_file', 'grep_files'); MaxToolIterations = 7; MaxBudgetUSD = 0.05
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                    DisableTerminal = $true; SystemPrompt = 'Only read.'
                }

                @($script:seen.Tool) | Should -Be @('read_file', 'grep_files')
                $script:seen.MaxToolIterations | Should -Be 7
                $script:seen.MaxBudgetUSD | Should -Be 0.05
                $script:seen.DisableTerminal | Should -BeTrue
                $script:seen.AppendSystemPrompt | Should -BeExactly 'Only read.'
                $script:seen.TraceParent | Should -BeExactly '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
            }
        }

        It 'Should pass no credential of any kind' {
            InModuleScope $script:moduleName {
                # Structural first: the child turn has no parameter that could
                # carry a key or a token by value at all.
                @((Get-Command -Name 'Invoke-Shp').Parameters.Keys) | Should -Not -Contain 'ApiKey'
                @((Get-Command -Name 'Invoke-Shp').Parameters.Keys) | Should -Not -Contain 'GitHubToken'

                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{ TokenPath = $TokenPath; ApiBase = $ApiBase }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @('read_file'); MaxToolIterations = 1
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                    ApiKey = 'secret'; GitHubToken = 'ghp_x'; TokenPath = 'C:\creds\token'
                }

                $script:seen.TokenPath | Should -BeNullOrEmpty
                $script:seen.ApiBase | Should -BeNullOrEmpty
            }
        }

        It 'Should never leave a switch on that the request did not set' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{
                        AllowPrivateNetwork = [bool]$AllowPrivateNetwork
                        DisableRedaction = [bool]$DisableRedaction
                        DisableFileAccess = [bool]$DisableFileAccess
                    }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @('read_file'); MaxToolIterations = 1
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                }

                $script:seen.AllowPrivateNetwork | Should -BeFalse
                $script:seen.DisableRedaction | Should -BeFalse
                $script:seen.DisableFileAccess | Should -BeFalse
            }
        }
    }

    Context 'An explicitly empty tool set' {
        It 'Should offer the child no tool at all rather than widening back to every one' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{ Bound = ($null -ne $Tool); Tool = $Tool }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @(); ToolBound = $true; MaxToolIterations = 1
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                }

                $script:seen.Bound | Should -BeTrue
                @($script:seen.Tool).Count | Should -Be 0
            }
        }

        It 'Should leave the tool selection unbound when the request never bound one' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{ Bound = ($null -ne $Tool) }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; MaxToolIterations = 1
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                }

                $script:seen.Bound | Should -BeFalse
            }
        }
    }

    Context 'The controls it inherits' {
        It 'Should run the child under the inherited Tool policy, decision control, contract and backend' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{
                        ToolPolicy = $ToolPolicy; ToolCallControl = $ToolCallControl
                        ExecutionContract = $ExecutionContract; ApiBase = $ApiBase
                        ContractBound = ($null -ne $ExecutionContract)
                    }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $policy = [pscustomobject]@{ PSTypeName = 'ShellPilot.ToolPolicy'; SchemaVersion = 1; TrustProfile = 'Legacy'; Coverage = @('Read'); Rule = @(); Source = '(inline)' }
                $control = @{ PreToolCall = { param($Request) @{ Decision = 'allow' } } }
                $contract = { param($Request) @{ Outcome = 'Executed'; Result = '{}' } }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @('read_file'); ToolBound = $true; MaxToolIterations = 1
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                    ToolPolicy = $policy; ToolCallControl = $control; ExecutionContract = $contract
                    ApiBase = 'https://alt.example/v1'
                }

                $script:seen.ToolPolicy | Should -Be $policy
                $script:seen.ToolCallControl | Should -Be $control
                $script:seen.ContractBound | Should -BeTrue
                $script:seen.ExecutionContract | Should -BeOfType [scriptblock]
                $script:seen.ApiBase | Should -BeExactly 'https://alt.example/v1'
            }
        }

        It 'Should bind no control the request did not carry' {
            InModuleScope $script:moduleName {
                $script:seen = $null
                Mock Invoke-Shp {
                    $script:seen = [pscustomobject]@{
                        PolicyBound = ($null -ne $ToolPolicy)
                        ControlBound = ($null -ne $ToolCallControl)
                        ContractBound = ($null -ne $ExecutionContract)
                        ApiBaseBound = (-not [string]::IsNullOrEmpty($ApiBase))
                    }
                    [pscustomobject]@{ Content = 'ok' }
                }

                $null = Invoke-ShpSubagentTurn -Request @{
                    Prompt = 'go'; Tool = @('read_file'); MaxToolIterations = 1
                    TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                }

                $script:seen.PolicyBound | Should -BeFalse
                $script:seen.ControlBound | Should -BeFalse
                $script:seen.ContractBound | Should -BeFalse
                $script:seen.ApiBaseBound | Should -BeFalse
            }
        }
    }

    Context 'The deadline it runs under' {
        It 'Should hand the nested turn the cancellation signal and the tree deadline' {
            InModuleScope $script:moduleName {
                $source = [System.Threading.CancellationTokenSource]::new()
                try {
                    $script:seen = $null
                    Mock Invoke-Shp {
                        $script:seen = [pscustomobject]@{
                            Token = $CancellationToken; Deadline = $Deadline
                            DeadlineBound = ($Deadline -gt [datetime]::MinValue)
                        }
                        [pscustomobject]@{ Content = 'ok' }
                    }

                    $deadline = [datetime]::UtcNow.AddSeconds(30)
                    $null = Invoke-ShpSubagentTurn -Request @{
                        Prompt = 'go'; Tool = @('read_file'); MaxToolIterations = 1
                        TraceParent = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
                        CancellationToken = $source.Token; Deadline = $deadline
                    }

                    $script:seen.DeadlineBound | Should -BeTrue
                    $script:seen.Deadline | Should -Be $deadline
                    $script:seen.Token.GetType().Name | Should -BeExactly 'CancellationToken'
                } finally {
                    $source.Dispose()
                }
            }
        }
    }
}
