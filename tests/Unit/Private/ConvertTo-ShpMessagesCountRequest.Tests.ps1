BeforeAll {
    $script:moduleName = 'ShellPilot'
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpMessagesCountRequest' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:payload = @{
                model = 'claude-haiku-4.5'
                stream = $false
                max_tokens = 32
                messages = @(
                    @{ role = 'system'; content = 'Approved Agent body.' }
                    @{ role = 'user'; content = 'Read the selected fixture.' }
                )
                tools = @(@{
                    type = 'function'
                    function = @{
                        name = 'child_read_file'
                        description = 'Read a selected file.'
                        parameters = @{
                            type = 'object'
                            properties = @{ path = @{ type = 'string' } }
                            required = @('path')
                            additionalProperties = $false
                        }
                    }
                })
                tool_choice = 'auto'
            }
        }
    }

    It 'preserves system text, messages, and the complete Tool schema' {
        InModuleScope $script:moduleName {
            $count = ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload
            $count.model | Should -BeExactly 'claude-haiku-4.5'
            $count.system[0].text | Should -BeExactly 'Approved Agent body.'
            $count.messages[0].content | Should -BeExactly 'Read the selected fixture.'
            $count.tools[0].input_schema.properties.path.type | Should -BeExactly 'string'
            $count.tools[0].input_schema.additionalProperties | Should -BeFalse
            $count.tools[0].input_schema.required | Should -Contain 'path'
            $count.tools[0].description | Should -BeExactly 'Read a selected file.'
        }
    }

    It 'preserves Tool-call arguments and correlated results without executing them' {
        InModuleScope $script:moduleName {
            $script:payload.messages += @(
                @{
                    role = 'assistant'; content = 'Inspecting the fixture.'
                    tool_calls = @(@{
                        id = 'fixture-call-1'; type = 'function'
                        function = @{ name = 'child_read_file'; arguments = '{"path":"notes.txt"}' }
                    })
                }
                @{ role = 'tool'; tool_call_id = 'fixture-call-1'; content = 'Fixture bytes.' }
            )
            $count = ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload
            $count.messages[1].content[0].text | Should -BeExactly 'Inspecting the fixture.'
            $count.messages[1].content[1].input.path | Should -BeExactly 'notes.txt'
            $count.messages[2].content[0].tool_use_id | Should -BeExactly 'fixture-call-1'
            $count.messages[2].content[0].content | Should -BeExactly 'Fixture bytes.'
        }
    }

    It 'maps the Engine named Tool result through its exact named call correlation' {
        InModuleScope $script:moduleName {
            $script:payload.messages += @(
                @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'call-1'; type = 'function'; function = @{ name = 'child_read_file'; arguments = '{"Path":"input.txt"}' } }) }
                @{ role = 'tool'; name = 'child_read_file'; tool_call_id = 'call-1'; content = 'selected input' }
            )
            $count = ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload
            $count.messages[1].content[0].name | Should -BeExactly 'child_read_file'
            $count.messages[2].content[0].tool_use_id | Should -BeExactly $count.messages[1].content[0].id
            $count.messages[2].content[0].content | Should -BeExactly 'selected input'
        }
    }

    It 'refuses a Tool result name that does not match the correlated call' {
        InModuleScope $script:moduleName {
            $script:payload.messages += @(
                @{ role = 'assistant'; content = $null; tool_calls = @(@{ id = 'call-1'; type = 'function'; function = @{ name = 'child_read_file'; arguments = '{}' } }) }
                @{ role = 'tool'; name = 'other_tool'; tool_call_id = 'call-1'; content = 'selected input' }
            )
            { ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload } | Should -Throw
        }
    }

    It 'refuses unsupported <Field> instead of omitting it' -ForEach @(
        @{ Field = 'model'; Value = 'gpt-5-mini' }
        @{ Field = 'stream'; Value = $true }
        @{ Field = 'response_format'; Value = @{ type = 'json_object' } }
        @{ Field = 'temperature'; Value = 0 }
        @{ Field = 'tool_choice'; Value = 'required' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Field = $Field; Value = $Value } {
            param($Field, $Value)
            $script:payload[$Field] = $Value
            $failure = { ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpCountShapeUnsupported'
        }
    }

    It 'refuses <Case> messages without exposing their content' -ForEach @(
        @{ Case = 'Vision'; Message = @{ role = 'user'; content = @(@{ type = 'image_url'; image_url = @{ url = 'file:///private-canary' } }) } }
        @{ Case = 'late system'; Message = @{ role = 'system'; content = 'private-canary' } }
        @{ Case = 'unmatched Tool result'; Message = @{ role = 'tool'; tool_call_id = 'unknown-call'; content = 'private-canary' } }
        @{ Case = 'unknown field'; Message = @{ role = 'user'; content = 'private-canary'; unrecognized = $true } }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Message = $Message } {
            param($Message)
            $script:payload.messages += $Message
            $failure = { ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpCountShapeUnsupported'
            ($failure | Out-String) | Should -Not -Match 'private-canary'
        }
    }

    It 'refuses duplicate argument keys instead of silently changing the count input' {
        InModuleScope $script:moduleName {
            $script:payload.messages += @(
                @{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'call-1'; type = 'function'; function = @{ name = 'child_read_file'; arguments = '{"path":"first","path":"second"}' } }) }
                @{ role = 'tool'; tool_call_id = 'call-1'; content = 'result' }
            )
            $failure = { ConvertTo-ShpMessagesCountRequest -ChatRequest $script:payload } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -Match '^ShpCountShapeUnsupported'
        }
    }
}
