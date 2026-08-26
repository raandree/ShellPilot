BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Write-ShpEvent' {
    BeforeAll {
        $script:eventRoot = Join-Path -Path $TestDrive -ChildPath 'events'
        $null = New-Item -Path $script:eventRoot -ItemType Directory -Force
    }

    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Write-ShpEvent' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Write-ShpEvent' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'The record envelope' {
        It 'Should stamp schemaVersion, sequence, an ISO 8601 UTC timestamp and the type' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'envelope.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $false }
                Write-ShpEvent -State $state -Type 'turn.start' -Data @{ model = 'test-model' }
            }

            $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $record.schemaVersion | Should -Be 1
            $record.sequence      | Should -Be 1
            $record.type          | Should -Be 'turn.start'
            $record.data.model    | Should -Be 'test-model'
            # Round-trips as a UTC instant rather than a local one.
            [datetimeoffset]::Parse($record.timestamp).Offset.TotalMinutes | Should -Be 0
        }

        # A truncated file has to stay parseable up to its last complete line,
        # which is only true if every line is one complete append.
        It 'Should append one complete line per event and leave every line valid JSON' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'lines.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $false }
                foreach ($i in 1..5) { Write-ShpEvent -State $state -Type 'usage' -Data @{ iteration = $i } }
            }

            $lines = @(Get-Content -LiteralPath $path)
            $lines.Count | Should -Be 5
            foreach ($line in $lines) { { $line | ConvertFrom-Json } | Should -Not -Throw }
        }

        It 'Should issue strictly increasing sequence numbers and report the last one on the state' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'sequence.jsonl'
            $lastSequence = InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $false }
                foreach ($i in 1..4) { Write-ShpEvent -State $state -Type 'usage' -Data @{ iteration = $i } }
                $state['Sequence']
            }

            $sequences = @(Get-Content -LiteralPath $path | ConvertFrom-Json | Select-Object -ExpandProperty sequence)
            $sequences | Should -Be @(1, 2, 3, 4)
            $lastSequence | Should -Be 4
        }

        # The schema contract is one FLAT record per line, and it is what makes
        # value-level redaction sufficient.
        It 'Should keep scalar data fields and drop anything that is not one' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'scalars.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $false }
                Write-ShpEvent -State $state -Type 'todo' -Data ([ordered]@{
                        total    = 3
                        current  = 'Step one'
                        done     = $false
                        todoList = @([pscustomobject]@{ id = 1 })
                        nested   = @{ a = 1 }
                    })
            }

            $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $record.data.total   | Should -Be 3
            $record.data.current | Should -Be 'Step one'
            $record.data.done    | Should -BeFalse
            $record.data.PSObject.Properties.Name | Should -Not -Contain 'todoList'
            $record.data.PSObject.Properties.Name | Should -Not -Contain 'nested'
        }
    }

    Context 'Redaction' {
        It 'Should redact a secret in a string field through the shared seam' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'redacted.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $true }
                Write-ShpEvent -State $state -Type 'tool.result' -Data @{ preview = 'token=ghp_1234567890abcdefghijklmnopqrstuvwxyz done' }
            }

            $raw = Get-Content -LiteralPath $path -Raw
            $raw | Should -Not -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
            $raw | Should -Match ([regex]::Escape('[redacted:github-token]'))
            { $raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'Should leave the value verbatim when the state turns redaction off' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'verbatim.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $false }
                Write-ShpEvent -State $state -Type 'tool.result' -Data @{ preview = 'token=ghp_1234567890abcdefghijklmnopqrstuvwxyz done' }
            }

            Get-Content -LiteralPath $path -Raw | Should -Match 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
        }

        # Applying the patterns to the serialised line instead of the values
        # would let a multi-line pattern replace the structural characters
        # between two fields and cut the document in half.
        It 'Should keep the line parseable when a pattern spans two fields' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'crossfield.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $true }
                Write-ShpEvent -State $state -Type 'tool.result' -Data ([ordered]@{
                        head = '-----BEGIN PRIVATE KEY-----'
                        tail = '-----END PRIVATE KEY-----'
                    })
            }

            $raw = Get-Content -LiteralPath $path -Raw
            { $raw | ConvertFrom-Json } | Should -Not -Throw
            ($raw | ConvertFrom-Json).data.tail | Should -Be '-----END PRIVATE KEY-----'
        }
    }

    Context 'Sinks and failure' {
        It "Should write to the Information stream when the path is '-'" {
            $records = InModuleScope $script:moduleName {
                $state = @{ Enabled = $true; Path = '-'; Sequence = 0; Redact = $false }
                Write-ShpEvent -State $state -Type 'final' -Data @{ finishReason = 'stop' } -InformationVariable info
                $info
            }

            $tagged = @($records | Where-Object { $_.Tags -contains 'ShpEvent' })
            $tagged | Should -Not -BeNullOrEmpty
            ($tagged[0].MessageData | ConvertFrom-Json).type | Should -Be 'final'
        }

        It 'Should write nothing once the state is disabled' {
            $path = Join-Path -Path $script:eventRoot -ChildPath 'disabled.jsonl'
            InModuleScope $script:moduleName -Parameters @{ Path = $path } {
                param($Path)

                $state = @{ Enabled = $false; Path = $Path; Sequence = 0; Redact = $false }
                Write-ShpEvent -State $state -Type 'final' -Data @{ finishReason = 'stop' }
            }

            Test-Path -LiteralPath $path | Should -BeFalse
        }

        # A log sink must not throw away a turn that has already been billed.
        It 'Should warn once and disable the stream when a write fails' {
            $directoryAsPath = $script:eventRoot
            $warnings = InModuleScope $script:moduleName -Parameters @{ Path = $directoryAsPath } {
                param($Path)

                $state = @{ Enabled = $true; Path = $Path; Sequence = 0; Redact = $false }
                Write-ShpEvent -State $state -Type 'final' -Data @{ a = 1 } -WarningVariable first -WarningAction SilentlyContinue
                Write-ShpEvent -State $state -Type 'final' -Data @{ a = 2 } -WarningVariable second -WarningAction SilentlyContinue

                [pscustomobject]@{ First = @($first).Count; Second = @($second).Count; Enabled = $state['Enabled'] }
            }

            $warnings.First   | Should -Be 1
            $warnings.Second  | Should -Be 0
            $warnings.Enabled | Should -BeFalse
        }
    }
}
