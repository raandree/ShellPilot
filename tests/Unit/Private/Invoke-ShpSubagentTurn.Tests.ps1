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
}
