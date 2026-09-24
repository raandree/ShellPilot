BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Read-ShpChatStore' {
    BeforeEach {
        $script:storeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-read-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:storeDirectory -Force
        $script:storePath = Join-Path $script:storeDirectory 'session.json'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:storeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns a store it recognises' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Set-Content -LiteralPath $StorePath -Value (@{ schemaVersion = 1; revision = 3; checkpoints = @() } | ConvertTo-Json -Depth 6)

            $store = Read-ShpChatStore -Path $StorePath

            $store.revision | Should -Be 3
        }
    }

    It 'Throws for a missing store' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            { Read-ShpChatStore -Path $StorePath } | Should -Throw '*not found*'
        }
    }

    It 'Returns null for a missing store only when the caller allows it' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Read-ShpChatStore -Path $StorePath -AllowMissing | Should -BeNullOrEmpty
        }
    }

    It 'Refuses an unparseable store rather than treating it as absent' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Set-Content -LiteralPath $StorePath -Value 'not json {{{'

            { Read-ShpChatStore -Path $StorePath } | Should -Throw '*could not be read*'
            { Read-ShpChatStore -Path $StorePath -AllowMissing } | Should -Throw '*could not be read*'
        }
    }

    It 'Refuses a schema version it does not implement, and never migrates it' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Set-Content -LiteralPath $StorePath -Value (@{ schemaVersion = 42; revision = 1; checkpoints = @() } | ConvertTo-Json -Depth 6)

            { Read-ShpChatStore -Path $StorePath } | Should -Throw '*schema version 42*'
        }
    }

    It 'Refuses a store with no schema version' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Set-Content -LiteralPath $StorePath -Value (@{ revision = 1; checkpoints = @() } | ConvertTo-Json -Depth 6)

            { Read-ShpChatStore -Path $StorePath } | Should -Throw '*no schema version*'
        }
    }

    It 'Refuses a store with no checkpoint list' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Set-Content -LiteralPath $StorePath -Value (@{ schemaVersion = 1; revision = 1 } | ConvertTo-Json -Depth 6)

            { Read-ShpChatStore -Path $StorePath } | Should -Throw '*no checkpoints*'
        }
    }

    It 'Refuses a directory named where a store should be' {
        InModuleScope $script:moduleName -Parameters @{ Directory = $script:storeDirectory } {
            param($Directory)
            { Read-ShpChatStore -Path $Directory } | Should -Throw '*not found*'
        }
    }
}
