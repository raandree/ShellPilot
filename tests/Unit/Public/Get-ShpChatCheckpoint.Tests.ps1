BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpChatCheckpoint' {
    BeforeEach {
        $script:storeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-list-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:storeDirectory -Force
        $script:storePath = Join-Path $script:storeDirectory 'session.json'
        InModuleScope $script:moduleName {
            Clear-ShpChat
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
        InModuleScope $script:moduleName { Clear-ShpChat; Clear-ShpRedactionPolicy }
    }

    It 'Lists checkpoints oldest first, without touching the Session chat' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $first = Save-ShpChat -Path $Store -Label 'before the refactor'
            $script:ShpChat += [pscustomobject]@{ role = 'user'; content = 'second question' }
            $script:ShpChat += [pscustomobject]@{ role = 'assistant'; content = 'second answer' }
            $second = Save-ShpChat -Path $Store
            Clear-ShpChat

            $checkpoints = @(Get-ShpChatCheckpoint -Path $Store)

            $checkpoints | Should -HaveCount 2
            $checkpoints[0].CheckpointId | Should -BeExactly $first.CheckpointId
            $checkpoints[0].Label | Should -BeExactly 'before the refactor'
            $checkpoints[0].Turns | Should -Be 2
            $checkpoints[0].Model | Should -BeExactly 'gpt-4.1'
            $checkpoints[0].Sha256 | Should -Match '^[0-9a-f]{64}$'
            $checkpoints[1].CheckpointId | Should -BeExactly $second.CheckpointId
            $checkpoints[1].ParentCheckpointId | Should -BeExactly $first.CheckpointId
            @($script:ShpChat) | Should -HaveCount 0
        }
    }

    It 'Reports uncertain side effects without replaying or clearing them' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $script:ShpChatSideEffectLedger = [System.Collections.Generic.List[object]]::new()
            $script:ShpChatSideEffectLedger.Add([pscustomobject]@{ Tool = 'run_command'; Origin = 'BuiltIn'; Server = ''; Execution = 'Native'; RunId = 'run-z'; TurnId = 'turn-z' })
            $null = Save-ShpChat -Path $Store -WarningAction SilentlyContinue

            $checkpoints = @(Get-ShpChatCheckpoint -Path $Store)

            $checkpoints[0].UncertainSideEffects | Should -HaveCount 1
            $checkpoints[0].UncertainSideEffects[0].tool | Should -BeExactly 'run_command'
        }
    }

    It 'Leaves the store byte-identical, because listing is not an event' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            $null = Save-ShpChat -Path $Store
            $before = Get-Content -LiteralPath $Store -Raw

            $null = Get-ShpChatCheckpoint -Path $Store

            (Get-Content -LiteralPath $Store -Raw) | Should -BeExactly $before
        }
    }

    It 'Refuses a missing store rather than returning nothing' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            { Get-ShpChatCheckpoint -Path $Store } | Should -Throw '*not found*'
        }
    }

    It 'Refuses a schema version it does not implement' {
        InModuleScope $script:moduleName -Parameters @{ Store = $script:storePath } {
            param($Store)
            Set-Content -LiteralPath $Store -Value (@{ schemaVersion = 99; revision = 1; checkpoints = @() } | ConvertTo-Json -Depth 6)

            { Get-ShpChatCheckpoint -Path $Store } | Should -Throw '*schema version*'
        }
    }
}
