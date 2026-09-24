BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Write-ShpToolResultSpill' {
    BeforeEach {
        $script:spillRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-spill-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:spillRoot -Force
    }
    AfterEach {
        Remove-Item -LiteralPath $script:spillRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Threshold' {
        It 'Leaves a result under the threshold untouched and writes nothing' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $result = Write-ShpToolResultSpill -Root $Root -Result 'small' -Tool 'read_file' `
                    -CallId 'call-1' -RunId 'run-1' -TurnId 'turn-1' -Iteration 1 -ThresholdChars 1000

                $result.Spilled | Should -BeFalse
                $result.Result | Should -BeExactly 'small'
                @(Get-ChildItem -LiteralPath $Root -File) | Should -HaveCount 0
            }
        }
    }

    Context 'Spilling' {
        It 'Writes the whole result and returns a bounded handle instead of it' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $payload = 'RESULT' * 5000

                $spill = Write-ShpToolResultSpill -Root $Root -Result $payload -Tool 'run_command' `
                    -CallId 'call-2' -RunId 'run-2' -TurnId 'turn-2' -Iteration 3 -ThresholdChars 1000

                $spill.Spilled | Should -BeTrue
                $spill.Result.Length | Should -BeLessThan $payload.Length
                $handle = $spill.Result | ConvertFrom-Json
                $handle.toolResultSpill.schemaVersion | Should -Be 1
                $handle.toolResultSpill.length | Should -Be $payload.Length
                $handle.toolResultSpill.sha256 | Should -Match '^[0-9a-f]{64}$'
                $handle.toolResultSpill.preview | Should -Not -BeNullOrEmpty
                Test-Path -LiteralPath $handle.toolResultSpill.path | Should -BeTrue

                $envelope = Get-Content -LiteralPath $handle.toolResultSpill.path -Raw | ConvertFrom-Json
                $envelope.schemaVersion | Should -Be 1
                $envelope.tool | Should -BeExactly 'run_command'
                $envelope.content | Should -BeExactly $payload
                $envelope.sha256 | Should -BeExactly $handle.toolResultSpill.sha256
            }
        }

        It 'Records a SHA-256 that matches the content it wrote' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $payload = 'HASHME' * 4000

                $spill = Write-ShpToolResultSpill -Root $Root -Result $payload -Tool 'read_file' `
                    -CallId 'call-3' -RunId 'run-3' -TurnId 'turn-3' -Iteration 1 -ThresholdChars 1000

                $envelope = Get-Content -LiteralPath ($spill.Result | ConvertFrom-Json).toolResultSpill.path -Raw | ConvertFrom-Json
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($envelope.content)
                $expected = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').ToLowerInvariant()
                $envelope.sha256 | Should -BeExactly $expected
            }
        }

        It 'Redacts a secret before it reaches the file' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $secret = 'ghp_' + ('b' * 36)
                $payload = ('padding ' * 4000) + $secret

                $spill = Write-ShpToolResultSpill -Root $Root -Result $payload -Tool 'fetch_url' `
                    -CallId 'call-4' -RunId 'run-4' -TurnId 'turn-4' -Iteration 1 -ThresholdChars 1000

                $raw = Get-Content -LiteralPath ($spill.Result | ConvertFrom-Json).toolResultSpill.path -Raw
                $raw | Should -Not -Match $secret
                $raw | Should -Match '\[redacted:github-token\]'
                $spill.Result | Should -Not -Match $secret
            }
        }

        It 'Writes atomically, leaving no temporary file behind' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $null = Write-ShpToolResultSpill -Root $Root -Result ('X' * 9000) -Tool 'read_file' `
                    -CallId 'call-5' -RunId 'run-5' -TurnId 'turn-5' -Iteration 1 -ThresholdChars 1000

                @(Get-ChildItem -LiteralPath $Root -File -Filter '*.tmp') | Should -HaveCount 0
                @(Get-ChildItem -LiteralPath $Root -File) | Should -HaveCount 1
            }
        }

        It 'Never prunes anything the caller wrote before' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                Set-Content -LiteralPath (Join-Path $Root 'caller-owned.txt') -Value 'keep me'

                $null = Write-ShpToolResultSpill -Root $Root -Result ('Y' * 9000) -Tool 'read_file' `
                    -CallId 'call-6' -RunId 'run-6' -TurnId 'turn-6' -Iteration 1 -ThresholdChars 1000

                Test-Path -LiteralPath (Join-Path $Root 'caller-owned.txt') | Should -BeTrue
            }
        }
    }

    Context 'Refusals' {
        It 'Refuses a root that does not exist rather than creating one' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $missing = Join-Path $Root 'not-created'

                { Write-ShpToolResultSpill -Root $missing -Result ('Z' * 9000) -Tool 'read_file' `
                        -CallId 'c' -RunId 'r' -TurnId 't' -Iteration 1 -ThresholdChars 1000 } |
                    Should -Throw '*does not exist*'
                Test-Path -LiteralPath $missing | Should -BeFalse
            }
        }

        It 'Refuses a root that is a file rather than a directory' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $file = Join-Path $Root 'a-file.txt'
                Set-Content -LiteralPath $file -Value 'x'

                { Write-ShpToolResultSpill -Root $file -Result ('Z' * 9000) -Tool 'read_file' `
                        -CallId 'c' -RunId 'r' -TurnId 't' -Iteration 1 -ThresholdChars 1000 } |
                    Should -Throw '*directory*'
            }
        }

        It 'Refuses an identifier that would escape the root' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $spill = Write-ShpToolResultSpill -Root $Root -Result ('Z' * 9000) -Tool '../../escape' `
                    -CallId '../../../etc/passwd' -RunId 'r/../..' -TurnId 't' -Iteration 1 -ThresholdChars 1000

                $written = ($spill.Result | ConvertFrom-Json).toolResultSpill.path
                $resolvedRoot = Resolve-ShpRealPath -Path $Root
                $written | Should -BeLike ("{0}*" -f $resolvedRoot)
                $written | Should -Not -Match '\.\.'
            }
        }

        It 'Refuses to overwrite an existing spill file' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                $spill = Write-ShpToolResultSpill -Root $Root -Result ('Z' * 9000) -Tool 'read_file' `
                    -CallId 'call-dup' -RunId 'run-dup' -TurnId 'turn-dup' -Iteration 1 -ThresholdChars 1000
                $path = ($spill.Result | ConvertFrom-Json).toolResultSpill.path
                $before = Get-Content -LiteralPath $path -Raw

                { Write-ShpToolResultSpill -Root $Root -Result ('Q' * 9000) -Tool 'read_file' `
                        -CallId 'call-dup' -RunId 'run-dup' -TurnId 'turn-dup' -Iteration 1 -ThresholdChars 1000 } |
                    Should -Throw '*already exists*'
                (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
            }
        }

        It 'Surfaces a write failure instead of falling back to truncation' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:spillRoot } {
                param($Root)
                Mock Move-Item { throw 'the volume is read-only' }

                { Write-ShpToolResultSpill -Root $Root -Result ('Z' * 9000) -Tool 'read_file' `
                        -CallId 'call-fail' -RunId 'run-fail' -TurnId 'turn-fail' -Iteration 1 -ThresholdChars 1000 } |
                    Should -Throw '*read-only*'
            }
        }
    }
}
