BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ShpJsonSchema' {
    Context 'Conformance, not parseability' {
        It 'Accepts an object that satisfies its declared shape' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","required":["level","path"],"properties":{"level":{"type":"string","enum":["error","warning"]},"path":{"type":"string"},"line":{"type":"integer"}}}'
                $instance = '{"level":"error","path":"src/a.ps1","line":12}' | ConvertFrom-Json

                $verdict = Test-ShpJsonSchema -Schema $schema -InputObject $instance

                $verdict.Supported | Should -BeTrue
                $verdict.Valid | Should -BeTrue
                $verdict.Error | Should -BeNullOrEmpty
            }
        }

        It 'Rejects a well-formed object that is missing a required member' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","required":["level","path"],"properties":{"level":{"type":"string"},"path":{"type":"string"}}}'
                $instance = '{"level":"error"}' | ConvertFrom-Json

                $verdict = Test-ShpJsonSchema -Schema $schema -InputObject $instance

                $verdict.Supported | Should -BeTrue
                $verdict.Valid | Should -BeFalse
                ($verdict.Error -join ' ') | Should -Match 'path'
            }
        }

        It 'Rejects a member of the wrong declared type' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","properties":{"line":{"type":"integer"}}}'
                $instance = '{"line":"twelve"}' | ConvertFrom-Json

                (Test-ShpJsonSchema -Schema $schema -InputObject $instance).Valid | Should -BeFalse
            }
        }

        It 'Rejects a value outside its declared enum' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","properties":{"level":{"enum":["error","warning"]}}}'
                $instance = '{"level":"catastrophe"}' | ConvertFrom-Json

                (Test-ShpJsonSchema -Schema $schema -InputObject $instance).Valid | Should -BeFalse
            }
        }

        It 'Enforces <Keyword>' -ForEach @(
            @{ Keyword = 'minimum'; Schema = '{"type":"integer","minimum":5}'; Json = '3'; Valid = $false }
            @{ Keyword = 'maximum'; Schema = '{"type":"integer","maximum":5}'; Json = '3'; Valid = $true }
            @{ Keyword = 'minLength'; Schema = '{"type":"string","minLength":3}'; Json = '"ab"'; Valid = $false }
            @{ Keyword = 'maxLength'; Schema = '{"type":"string","maxLength":3}'; Json = '"abcd"'; Valid = $false }
            @{ Keyword = 'pattern'; Schema = '{"type":"string","pattern":"^v[0-9]+$"}'; Json = '"v12"'; Valid = $true }
            @{ Keyword = 'pattern rejection'; Schema = '{"type":"string","pattern":"^v[0-9]+$"}'; Json = '"release"'; Valid = $false }
            @{ Keyword = 'minItems'; Schema = '{"type":"array","minItems":2}'; Json = '[1]'; Valid = $false }
            @{ Keyword = 'maxItems'; Schema = '{"type":"array","maxItems":2}'; Json = '[1,2,3]'; Valid = $false }
            @{ Keyword = 'items'; Schema = '{"type":"array","items":{"type":"integer"}}'; Json = '[1,"two"]'; Valid = $false }
            @{ Keyword = 'additionalProperties false'; Schema = '{"type":"object","properties":{"a":{}},"additionalProperties":false}'; Json = '{"a":1,"b":2}'; Valid = $false }
            @{ Keyword = 'const'; Schema = '{"const":"fixed"}'; Json = '"other"'; Valid = $false }
            @{ Keyword = 'null type'; Schema = '{"type":["string","null"]}'; Json = 'null'; Valid = $true }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Schema = $Schema; Json = $Json; Valid = $Valid } {
                param($Schema, $Json, $Valid)
                $instance = $Json | ConvertFrom-Json
                (Test-ShpJsonSchema -Schema $Schema -InputObject $instance).Valid | Should -Be $Valid
            }
        }

        It 'Validates a nested object rather than stopping at the first level' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","properties":{"outer":{"type":"object","required":["inner"],"properties":{"inner":{"type":"integer"}}}}}'

                (Test-ShpJsonSchema -Schema $schema -InputObject ('{"outer":{"inner":1}}' | ConvertFrom-Json)).Valid | Should -BeTrue
                (Test-ShpJsonSchema -Schema $schema -InputObject ('{"outer":{"inner":"x"}}' | ConvertFrom-Json)).Valid | Should -BeFalse
                (Test-ShpJsonSchema -Schema $schema -InputObject ('{"outer":{}}' | ConvertFrom-Json)).Valid | Should -BeFalse
            }
        }
    }

    Context 'Says what it cannot check' {
        It 'Reports <Keyword> as unsupported instead of claiming conformance' -ForEach @(
            @{ Keyword = '$ref'; Schema = '{"type":"object","properties":{"a":{"$ref":"#/$defs/x"}}}' }
            @{ Keyword = 'anyOf'; Schema = '{"anyOf":[{"type":"string"},{"type":"integer"}]}' }
            @{ Keyword = 'oneOf'; Schema = '{"oneOf":[{"type":"string"}]}' }
            @{ Keyword = 'allOf'; Schema = '{"allOf":[{"type":"string"}]}' }
            @{ Keyword = 'not'; Schema = '{"not":{"type":"string"}}' }
            @{ Keyword = 'if'; Schema = '{"if":{"type":"string"},"then":{"minLength":1}}' }
        ) {
            InModuleScope $script:moduleName -Parameters @{ Schema = $Schema } {
                param($Schema)
                $verdict = Test-ShpJsonSchema -Schema $Schema -InputObject ('"anything"' | ConvertFrom-Json)

                $verdict.Supported | Should -BeFalse
                $verdict.Valid | Should -BeNullOrEmpty
                $verdict.Unsupported | Should -Not -BeNullOrEmpty
            }
        }

        It 'Reports an unusable schema as unsupported rather than as a mismatch' {
            InModuleScope $script:moduleName {
                $verdict = Test-ShpJsonSchema -Schema 'not json at all' -InputObject ('{}' | ConvertFrom-Json)

                $verdict.Supported | Should -BeFalse
                $verdict.Valid | Should -BeNullOrEmpty
            }
        }

        It 'Refuses a schema deeper than its bound instead of walking it' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","properties":{"a":{"type":"object","properties":{"b":{"type":"object","properties":{"c":{"type":"string"}}}}}}}'

                $verdict = Test-ShpJsonSchema -Schema $schema -InputObject ('{}' | ConvertFrom-Json) -MaxDepth 2

                $verdict.Supported | Should -BeFalse
                $verdict.Unsupported | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Bounded reporting' {
        It 'Caps the number of errors it reports' {
            InModuleScope $script:moduleName {
                $properties = @{}
                foreach ($index in 1..40) { $properties["p$index"] = @{ type = 'integer' } }
                $schema = @{ type = 'object'; properties = $properties } | ConvertTo-Json -Depth 6
                $instanceJson = @{}
                foreach ($index in 1..40) { $instanceJson["p$index"] = 'not an integer' }
                $instance = ($instanceJson | ConvertTo-Json -Depth 6) | ConvertFrom-Json

                $verdict = Test-ShpJsonSchema -Schema $schema -InputObject $instance

                $verdict.Valid | Should -BeFalse
                $verdict.Error.Count | Should -BeLessOrEqual 20
            }
        }

        It 'Names the failing member without quoting its value' {
            InModuleScope $script:moduleName {
                $schema = '{"type":"object","properties":{"apiKey":{"type":"integer"}}}'
                $instance = '{"apiKey":"sk-do-not-log-this"}' | ConvertFrom-Json

                $verdict = Test-ShpJsonSchema -Schema $schema -InputObject $instance

                ($verdict.Error -join ' ') | Should -Match 'apiKey'
                ($verdict.Error -join ' ') | Should -Not -Match 'sk-do-not-log-this'
            }
        }
    }
}
