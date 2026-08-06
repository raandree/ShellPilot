BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpPriceEntry' {
    BeforeEach {
        InModuleScope $script:moduleName { $script:ShpUnpricedModelWarned.Clear() }
    }

    It 'Resolves a known model case-insensitively and reports it priced' {
        InModuleScope $script:moduleName {
            $r = Resolve-ShpPriceEntry -ModelName 'Claude-Opus-5'
            $r.Priced        | Should -BeTrue
            $r.Key           | Should -Be 'claude-opus-5'
            $r.Pricing.Input | Should -Be 5.00
        }
    }

    It 'Prefers the first candidate that exists in the price table' {
        InModuleScope $script:moduleName {
            # The service reports a name that is not a table key; the requested
            # id still prices the call, and Key names the entry actually used.
            $r = Resolve-ShpPriceEntry -ModelName 'claude-opus-5-20260801', 'claude-opus-5'
            $r.Priced | Should -BeTrue
            $r.Key    | Should -Be 'claude-opus-5'
        }
    }

    It 'Falls through an empty server-reported name to the requested model' {
        InModuleScope $script:moduleName {
            $r = Resolve-ShpPriceEntry -ModelName '', 'claude-opus-5'
            $r.Priced | Should -BeTrue
            $r.Key    | Should -Be 'claude-opus-5'
        }
    }

    It 'Keeps the attempted key and no rate when nothing matches' {
        InModuleScope $script:moduleName {
            $r = Resolve-ShpPriceEntry -ModelName 'totally-unknown-model' -WarningAction SilentlyContinue
            $r.Priced  | Should -BeFalse
            $r.Pricing | Should -BeNullOrEmpty
            # Without this the caller cannot say WHICH key missed.
            $r.Key     | Should -Be 'totally-unknown-model'
        }
    }

    It 'Warns once per unknown model, not once per round-trip' {
        InModuleScope $script:moduleName {
            # A Turn is a loop, so this runs once per tool iteration; a warning
            # per iteration would be noise the caller learns to ignore.
            $warnings = @(
                for ($i = 0; $i -lt 10; $i++) {
                    Resolve-ShpPriceEntry -ModelName 'looping-unknown-model' 3>&1 |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
                }
            )
            $warnings.Count      | Should -Be 1
            [string]$warnings[0] | Should -BeLike '*looping-unknown-model*'
        }
    }

    It 'Warns separately for each distinct unknown model' {
        InModuleScope $script:moduleName {
            $warnings = @(
                foreach ($name in 'unknown-one', 'unknown-two', 'unknown-one') {
                    Resolve-ShpPriceEntry -ModelName $name 3>&1 |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
                }
            )
            $warnings.Count | Should -Be 2
        }
    }

    It 'Never warns for a model that has a rate' {
        InModuleScope $script:moduleName {
            $warnings = @(
                Resolve-ShpPriceEntry -ModelName 'claude-opus-5' 3>&1 |
                    Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            )
            $warnings.Count | Should -Be 0
        }
    }
}
