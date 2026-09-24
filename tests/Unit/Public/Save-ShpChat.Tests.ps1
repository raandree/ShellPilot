BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Session chat persistence and resume' {
    BeforeEach {
        $script:storeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-chat-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:storeDirectory -Force
        $script:storePath = Join-Path $script:storeDirectory 'session.json'
        InModuleScope $script:moduleName {
            Clear-ShpChat
            Clear-ShpContext
            Clear-ShpRedactionPolicy
            $script:ShpChat = @(
                [pscustomobject]@{ role = 'user'; content = 'first question' }
                [pscustomobject]@{ role = 'assistant'; content = 'first answer' }
            )
            $script:ShpChatModel = 'gpt-4.1'
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:storeDirectory -Recurse -Force -ErrorAction SilentlyContinue
        InModuleScope $script:moduleName { Clear-ShpChat; Clear-ShpContext; Clear-ShpRedactionPolicy }
    }

    Context 'Command surface' {
        It 'Exports the save, resume and inspect cmdlets' {
            foreach ($name in 'Save-ShpChat', 'Restore-ShpChat', 'Get-ShpChatCheckpoint') {
                Get-Command -Name $name -Module $script:moduleName | Should -Not -BeNullOrEmpty
            }
        }

        It 'Requires an explicit path everywhere, and never defaults one' {
            foreach ($name in 'Save-ShpChat', 'Restore-ShpChat', 'Get-ShpChatCheckpoint') {
                (Get-Command $name).Parameters['Path'].Attributes.Mandatory | Should -Contain $true
            }
        }
    }

    Context 'Saving a checkpoint' {
        It 'Writes a versioned store the caller named, and nowhere else' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath; Directory = $script:storeDirectory } {
                param($Store, $Directory)
                $checkpoint = Save-ShpChat -Path $Store

                Test-Path -LiteralPath $Store | Should -BeTrue
                @(Get-ChildItem -LiteralPath $Directory -File) | Should -HaveCount 1
                $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                $onDisk.schemaVersion | Should -Be 1
                $onDisk.revision | Should -Be 1
                @($onDisk.checkpoints) | Should -HaveCount 1
                $onDisk.checkpoints[0].id | Should -BeExactly $checkpoint.CheckpointId
                $onDisk.checkpoints[0].turns | Should -HaveCount 2
                $onDisk.checkpoints[0].model | Should -BeExactly 'gpt-4.1'
                $onDisk.checkpoints[0].parentId | Should -BeNullOrEmpty
            }
        }

        It 'Redacts the conversation on the way to disk' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $secret = 'ghp_' + ('c' * 36)
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = "use $secret please" }
                    [pscustomobject]@{ role = 'assistant'; content = 'done' }
                )

                $null = Save-ShpChat -Path $Store

                $raw = Get-Content -LiteralPath $Store -Raw
                $raw | Should -Not -Match $secret
                $raw | Should -Match '\[redacted:github-token\]'
            }
        }

        It 'Appends a second checkpoint and chains it to the first' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $first = Save-ShpChat -Path $Store
                $script:ShpChat += [pscustomobject]@{ role = 'user'; content = 'second question' }
                $script:ShpChat += [pscustomobject]@{ role = 'assistant'; content = 'second answer' }
                $second = Save-ShpChat -Path $Store

                $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                @($onDisk.checkpoints) | Should -HaveCount 2
                $onDisk.revision | Should -Be 2
                $second.ParentCheckpointId | Should -BeExactly $first.CheckpointId
            }
        }

        It 'Leaves no temporary file behind' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath; Directory = $script:storeDirectory } {
                param($Store, $Directory)
                $null = Save-ShpChat -Path $Store

                @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.tmp') | Should -HaveCount 0
            }
        }

        It 'Refuses to persist a conversation holding an unanswered Tool call' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = 'do it' }
                    [pscustomobject]@{ role = 'tool'; content = '{"partial":true}' }
                )

                { Save-ShpChat -Path $Store } | Should -Throw '*durable*'
                Test-Path -LiteralPath $Store | Should -BeFalse
            }
        }

        It 'Refuses an empty conversation rather than writing an empty checkpoint' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                Clear-ShpChat

                { Save-ShpChat -Path $Store } | Should -Throw '*empty*'
                Test-Path -LiteralPath $Store | Should -BeFalse
            }
        }

        It 'Records the side effects of an incomplete Turn for manual recovery' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $script:ShpChatSideEffectLedger = [System.Collections.Generic.List[object]]::new()
                $script:ShpChatSideEffectLedger.Add([pscustomobject]@{ Tool = 'run_command'; Origin = 'BuiltIn'; Server = ''; Execution = 'Native'; RunId = 'run-x'; TurnId = 'turn-x' })

                $checkpoint = Save-ShpChat -Path $Store -WarningAction SilentlyContinue

                $checkpoint.UncertainSideEffects | Should -HaveCount 1
                $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                $onDisk.checkpoints[0].uncertainSideEffects[0].tool | Should -BeExactly 'run_command'
                $onDisk.checkpoints[0].uncertainSideEffects[0].runId | Should -BeExactly 'run-x'
            }
        }
    }

    Context 'Refusals' {
        It 'Refuses a store whose schema version it does not implement' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                Set-Content -LiteralPath $Store -Value (@{ schemaVersion = 99; revision = 1; checkpoints = @() } | ConvertTo-Json -Depth 6)

                { Restore-ShpChat -Path $Store } | Should -Throw '*schema version*'
                { Get-ShpChatCheckpoint -Path $Store } | Should -Throw '*schema version*'
                { Save-ShpChat -Path $Store } | Should -Throw '*schema version*'
            }
        }

        It 'Refuses an unreadable store rather than treating it as absent' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                Set-Content -LiteralPath $Store -Value 'this is not json {{{'

                { Restore-ShpChat -Path $Store } | Should -Throw '*could not be read*'
                { Save-ShpChat -Path $Store } | Should -Throw '*could not be read*'
            }
        }

        It 'Refuses a store that is missing' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $null = $Store  # used inside the assertion scriptblock below
                { Restore-ShpChat -Path $Store } | Should -Throw '*not found*'
            }
        }

        It 'Refuses an unknown checkpoint id' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $null = Save-ShpChat -Path $Store

                { Restore-ShpChat -Path $Store -CheckpointId 'nope' } | Should -Throw '*nope*'
            }
        }

        It 'Refuses a rollback past the beginning of the chain' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $null = Save-ShpChat -Path $Store

                { Restore-ShpChat -Path $Store -Rollback 5 } | Should -Throw '*checkpoint*'
            }
        }

        It 'Detects a store another writer advanced under it' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $null = Save-ShpChat -Path $Store
                $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                $onDisk.revision = 7
                Set-Content -LiteralPath $Store -Value ($onDisk | ConvertTo-Json -Depth 20)

                { Save-ShpChat -Path $Store } | Should -Throw '*changed*'
            }
        }

        It 'Appends anyway when the caller accepts the conflict' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $null = Save-ShpChat -Path $Store
                $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                $onDisk.revision = 7
                Set-Content -LiteralPath $Store -Value ($onDisk | ConvertTo-Json -Depth 20)

                $null = Save-ShpChat -Path $Store -Force

                $reloaded = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                @($reloaded.checkpoints) | Should -HaveCount 2
                $reloaded.revision | Should -Be 8
            }
        }
    }

    Context 'Invoke-Shp flow' {
        It 'Offers a save path on Invoke-Shp' {
            (Get-Command Invoke-Shp).Parameters.Keys | Should -Contain 'SaveChatPath'
        }

        It 'Refuses an ambiguous combination before any credential work' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                $null = $Store  # used inside the assertion scriptblock below
                Mock Get-ShpSessionToken { throw 'no credential work may happen before the refusal' }
                Mock Resolve-ShpOAuthToken { throw 'no credential work may happen before the refusal' }

                { Invoke-Shp -Prompt 'hi' -Model 'gpt-4.1' -SaveChatPath $Store -AsJob } |
                    Should -Throw '*-AsJob*'
                { Invoke-Shp -Prompt 'hi' -Model 'gpt-4.1' -SaveChatPath $Store -History @() } |
                    Should -Throw '*-History*'
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            }
        }

        It 'Refuses the same combination on a Batch, where a Session chat does not exist' {
            (Get-Command Invoke-ShpBatch).Parameters.Keys | Should -Not -Contain 'SaveChatPath'
        }

        It 'Checkpoints the conversation after a successful Turn' {
            InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
                param($Store)
                Clear-ShpChat
                Mock Get-ShpSessionToken {
                    [pscustomobject]@{ token = 'session-fixture'; expires_at = 0; endpoints = @{ api = 'https://api.example' } }
                }
                Mock Invoke-ShpHttpRequest {
                    $payload = @{
                        model = 'gpt-4.1'
                        choices = @(@{ message = @{ role = 'assistant'; content = 'ready' }; finish_reason = 'stop' })
                        usage = @{ prompt_tokens = 4; completion_tokens = 1 }
                    }
                    [pscustomobject]@{ Content = ($payload | ConvertTo-Json -Depth 10 -Compress); Headers = @{} }
                }

                $null = Invoke-Shp -Prompt 'Say ready.' -Model 'gpt-4.1' -SaveChatPath $Store `
                    -MaxOutputTokens 32 -MaxContextWindowTokens 0 -DisableStreaming -DisableBrowsing `
                    -DisableFileAccess -DisableTerminal -DisableUserPrompts -DisableTodoList `
                    -DisableProgressEvents -NoAutomaticRetry -TimeoutSec 5 -NetworkOutageToleranceSec 0

                $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
                @($onDisk.checkpoints) | Should -HaveCount 1
                @($onDisk.checkpoints[0].turns) | Should -HaveCount 2
                $onDisk.checkpoints[0].turns[1].content | Should -BeExactly 'ready'
            }
        }
    }
}
