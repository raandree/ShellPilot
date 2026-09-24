BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpSpanId' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'New-ShpSpanId' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'New-ShpSpanId' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Identifier shape' {
        It 'Should return 16 lowercase hexadecimal characters' {
            InModuleScope $script:moduleName {
                $id = New-ShpSpanId -TraceId ('a' * 32) -Key 'turn'
                $id | Should -Match '^[0-9a-f]{16}$'
            }
        }

        It 'Should never return the all-zero span id, which the wire format reserves as invalid' {
            InModuleScope $script:moduleName {
                # Every key over a fixed trace must still round-trip to a usable id.
                foreach ($key in 1..64) {
                    (New-ShpSpanId -TraceId ('1' * 32) -Key "k$key") | Should -Not -Be '0000000000000000'
                }
            }
        }
    }

    Context 'Determinism, which is what makes a span correlatable without shared state' {
        It 'Should return the same id for the same trace and key' {
            InModuleScope $script:moduleName {
                $first = New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'iteration:3'
                $second = New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'iteration:3'
                $first | Should -BeExactly $second
            }
        }

        It 'Should return different ids for different keys in the same trace' {
            InModuleScope $script:moduleName {
                $turn = New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'turn'
                $iteration = New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'iteration:1'
                $turn | Should -Not -BeExactly $iteration
            }
        }

        It 'Should return different ids for the same key in different traces' {
            InModuleScope $script:moduleName {
                $one = New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'turn'
                $two = New-ShpSpanId -TraceId '00000000000000000000000000000001' -Key 'turn'
                $one | Should -Not -BeExactly $two
            }
        }

        It 'Should treat the trace id case-insensitively so an upper-case hex parent still correlates' {
            InModuleScope $script:moduleName {
                $lower = New-ShpSpanId -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -Key 'turn'
                $upper = New-ShpSpanId -TraceId '4BF92F3577B34DA6A3CE929D0E0E4736' -Key 'turn'
                $lower | Should -BeExactly $upper
            }
        }
    }

    Context 'Fail closed on a malformed trace id' {
        It 'Should refuse a trace id that is not 32 hexadecimal characters' {
            InModuleScope $script:moduleName {
                { New-ShpSpanId -TraceId 'not-a-trace' -Key 'turn' } | Should -Throw '*32 hexadecimal*'
            }
        }
    }
}
