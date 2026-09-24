BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Restore-ShpChat' {
    BeforeEach {
        $script:storeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-restore-{0}" -f [guid]::NewGuid().ToString('N'))
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

    It 'Loads the newest checkpoint into the Session chat' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $null = Save-ShpChat -Path $Store
            Clear-ShpChat

            $report = Restore-ShpChat -Path $Store

            @($script:ShpChat) | Should -HaveCount 2
            $script:ShpChat[0].content | Should -BeExactly 'first question'
            $script:ShpChatModel | Should -BeExactly 'gpt-4.1'
            $report.Turns | Should -Be 2
        }
    }

    It 'Loads a named checkpoint instead of the newest' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $first = Save-ShpChat -Path $Store
            $script:ShpChat += [pscustomobject]@{ role = 'user'; content = 'second question' }
            $script:ShpChat += [pscustomobject]@{ role = 'assistant'; content = 'second answer' }
            $null = Save-ShpChat -Path $Store

            $null = Restore-ShpChat -Path $Store -CheckpointId $first.CheckpointId

            @($script:ShpChat) | Should -HaveCount 2
        }
    }

    It 'Rolls back along the checkpoint chain' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $null = Save-ShpChat -Path $Store
            $script:ShpChat += [pscustomobject]@{ role = 'user'; content = 'second question' }
            $script:ShpChat += [pscustomobject]@{ role = 'assistant'; content = 'second answer' }
            $null = Save-ShpChat -Path $Store

            $report = Restore-ShpChat -Path $Store -Rollback 1

            @($script:ShpChat) | Should -HaveCount 2
            $report.Turns | Should -Be 2
        }
    }

    It 'Forks a new line from an older checkpoint without rewriting history' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $first = Save-ShpChat -Path $Store
            $script:ShpChat += [pscustomobject]@{ role = 'user'; content = 'second question' }
            $script:ShpChat += [pscustomobject]@{ role = 'assistant'; content = 'second answer' }
            $null = Save-ShpChat -Path $Store

            $restore = Restore-ShpChat -Path $Store -CheckpointId $first.CheckpointId -Fork
            $script:ShpChat += [pscustomobject]@{ role = 'user'; content = 'a different second question' }
            $script:ShpChat += [pscustomobject]@{ role = 'assistant'; content = 'a different second answer' }
            $forked = Save-ShpChat -Path $Store

            $restore.Forked | Should -BeTrue
            $onDisk = Get-Content -LiteralPath $Store -Raw | ConvertFrom-Json
            @($onDisk.checkpoints) | Should -HaveCount 3
            $forked.ParentCheckpointId | Should -BeExactly $first.CheckpointId
            @($onDisk.checkpoints | Where-Object { $_.parentId -eq $first.CheckpointId }) | Should -HaveCount 2
        }
    }

    It 'Never replays an interrupted Tool call, and surfaces it instead' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $script:ShpChatSideEffectLedger = [System.Collections.Generic.List[object]]::new()
            $script:ShpChatSideEffectLedger.Add([pscustomobject]@{ Tool = 'write_file'; Origin = 'BuiltIn'; Server = ''; Execution = 'Native'; RunId = 'run-y'; TurnId = 'turn-y' })
            $null = Save-ShpChat -Path $Store -WarningAction SilentlyContinue
            Clear-ShpChat

            $report = Restore-ShpChat -Path $Store -WarningAction SilentlyContinue

            $report.UncertainSideEffects | Should -HaveCount 1
            $report.UncertainSideEffects[0].tool | Should -BeExactly 'write_file'
            $report.UncertainSideEffects[0].runId | Should -BeExactly 'run-y'
            foreach ($turn in $script:ShpChat) { [string]$turn.role | Should -Not -BeExactly 'tool' }
        }
    }

    It 'Changes nothing under -WhatIf' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $null = Save-ShpChat -Path $Store
            Clear-ShpChat

            $null = Restore-ShpChat -Path $Store -WhatIf

            @($script:ShpChat) | Should -HaveCount 0
        }
    }

    It 'Refuses a store that is missing' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
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

    It 'Refuses a schema version it does not implement' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            Set-Content -LiteralPath $Store -Value (@{ schemaVersion = 99; revision = 1; checkpoints = @() } | ConvertTo-Json -Depth 6)

            { Restore-ShpChat -Path $Store } | Should -Throw '*schema version*'
        }
    }

    It 'Refuses an unreadable store rather than treating it as absent' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            Set-Content -LiteralPath $Store -Value 'this is not json {{{'

            { Restore-ShpChat -Path $Store } | Should -Throw '*could not be read*'
        }
    }
}
