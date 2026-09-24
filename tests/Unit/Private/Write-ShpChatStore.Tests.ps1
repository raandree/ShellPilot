BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Write-ShpChatStore' {
    BeforeEach {
        $script:storeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-write-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:storeDirectory -Force
        $script:storePath = Join-Path $script:storeDirectory 'session.json'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:storeDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Writes a store that reads back unchanged' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath } {
            param($StorePath)
            Write-ShpChatStore -Path $StorePath -Store ([ordered]@{ schemaVersion = 1; revision = 2; checkpoints = @(@{ id = 'a' }) })

            $store = Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json
            $store.schemaVersion | Should -Be 1
            $store.revision | Should -Be 2
            $store.checkpoints[0].id | Should -BeExactly 'a'
        }
    }

    It 'Replaces an existing store atomically, leaving no temporary file' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath; Directory = $script:storeDirectory } {
            param($StorePath, $Directory)
            Write-ShpChatStore -Path $StorePath -Store ([ordered]@{ schemaVersion = 1; revision = 1; checkpoints = @() })
            Write-ShpChatStore -Path $StorePath -Store ([ordered]@{ schemaVersion = 1; revision = 2; checkpoints = @() })

            @(Get-ChildItem -LiteralPath $Directory -File) | Should -HaveCount 1
            (Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json).revision | Should -Be 2
        }
    }

    It 'Refuses a directory that does not exist rather than creating one' {
        InModuleScope $script:moduleName -Parameters @{ Directory = $script:storeDirectory } {
            param($Directory)
            $missing = Join-Path (Join-Path $Directory 'absent') 'session.json'

            { Write-ShpChatStore -Path $missing -Store ([ordered]@{ schemaVersion = 1 }) } |
                Should -Throw '*does not exist*'
            Test-Path -LiteralPath (Join-Path $Directory 'absent') | Should -BeFalse
        }
    }

    It 'Leaves the previous store intact and removes the temporary file when the move fails' {
        InModuleScope $script:moduleName -Parameters @{ StorePath = $script:storePath; Directory = $script:storeDirectory } {
            param($StorePath, $Directory)
            Write-ShpChatStore -Path $StorePath -Store ([ordered]@{ schemaVersion = 1; revision = 1; checkpoints = @() })
            Mock Move-Item { throw 'the volume is read-only' }

            { Write-ShpChatStore -Path $StorePath -Store ([ordered]@{ schemaVersion = 1; revision = 2; checkpoints = @() }) } |
                Should -Throw '*nothing was changed*'
            (Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json).revision | Should -Be 1
            @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.tmp') | Should -HaveCount 0
        }
    }
}
