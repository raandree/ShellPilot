BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Read-ShpBoundedHttpContent' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Read-ShpBoundedHttpContent' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Read-ShpBoundedHttpContent' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Reading a reply under a byte cap' {
        It 'Should return a body that fits the cap exactly' {
            InModuleScope $script:moduleName {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('x' * 64)
                $stream = [System.IO.MemoryStream]::new($bytes)
                try {
                    $bounded = Read-ShpBoundedHttpContent -Stream $stream -MaxByte 64

                    $bounded.Ok | Should -BeTrue
                    $bounded.ByteCount | Should -Be 64
                    $bounded.Body | Should -BeExactly ('x' * 64)
                } finally {
                    $stream.Dispose()
                }
            }
        }

        It 'Should stop reading one byte past the cap instead of buffering the reply' {
            InModuleScope $script:moduleName {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('x' * 200000)
                $stream = [System.IO.MemoryStream]::new($bytes)
                try {
                    $bounded = Read-ShpBoundedHttpContent -Stream $stream -MaxByte 1024

                    $bounded.Ok | Should -BeFalse
                    $bounded.Reason | Should -Match '1024'
                    $bounded.Body | Should -BeNullOrEmpty
                    $stream.Position | Should -Be 1025
                } finally {
                    $stream.Dispose()
                }
            }
        }

        It 'Should decode the reply as UTF-8' {
            InModuleScope $script:moduleName {
                $text = '{"result":"caf' + [string][char]0x00E9 + '"}'
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                $stream = [System.IO.MemoryStream]::new($bytes)
                try {
                    $bounded = Read-ShpBoundedHttpContent -Stream $stream -MaxByte 4096

                    $bounded.Ok | Should -BeTrue
                    $bounded.Body | Should -BeExactly $text
                    $bounded.ByteCount | Should -Be $bytes.Length
                } finally {
                    $stream.Dispose()
                }
            }
        }

        It 'Should return an empty body for an empty reply' {
            InModuleScope $script:moduleName {
                $stream = [System.IO.MemoryStream]::new([byte[]]@())
                try {
                    $bounded = Read-ShpBoundedHttpContent -Stream $stream -MaxByte 4096

                    $bounded.Ok | Should -BeTrue
                    $bounded.ByteCount | Should -Be 0
                    $bounded.Body | Should -BeExactly ''
                } finally {
                    $stream.Dispose()
                }
            }
        }

        It 'Should stop at the cap when the reply arrives in small chunks' {
            InModuleScope $script:moduleName {
                # A stream that hands back one byte at a time is the shape an
                # event stream arrives in; the cap has to hold there too.
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('y' * 5000)
                $inner = [System.IO.MemoryStream]::new($bytes)
                $stream = [System.IO.BufferedStream]::new($inner, 1)
                try {
                    $bounded = Read-ShpBoundedHttpContent -Stream $stream -MaxByte 100

                    $bounded.Ok | Should -BeFalse
                    $bounded.ByteCount | Should -Be 101
                } finally {
                    $stream.Dispose()
                }
            }
        }
    }
}
