BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-ShpMcpToolResult' {
    It 'Joins text blocks into the output envelope' {
        InModuleScope $script:moduleName {
            $response = @{
                Ok     = $true
                Result = '{"resultType":"complete","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}],"isError":false}' | ConvertFrom-Json
            }

            $envelope = ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json

            $envelope.output | Should -Be "first`nsecond"
            $envelope.PSObject.Properties['error'] | Should -BeNullOrEmpty
        }
    }

    It 'Treats an absent resultType as complete, for a legacy server' {
        InModuleScope $script:moduleName {
            $response = @{ Ok = $true; Result = '{"content":[{"type":"text","text":"ok"}]}' | ConvertFrom-Json }

            (ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json).output | Should -Be 'ok'
        }
    }

    It 'Maps isError onto the module error envelope so the model can self-correct' {
        InModuleScope $script:moduleName {
            $response = @{
                Ok     = $true
                Result = '{"resultType":"complete","content":[{"type":"text","text":"Invalid date."}],"isError":true}' | ConvertFrom-Json
            }

            $envelope = ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json

            $envelope.error | Should -Be 'Invalid date.'
            $envelope.PSObject.Properties['output'] | Should -BeNullOrEmpty
        }
    }

    It 'Refuses an input_required result instead of treating it as a completed call' {
        InModuleScope $script:moduleName {
            $response = @{ Ok = $true; Result = '{"resultType":"input_required","inputRequests":{}}' | ConvertFrom-Json }

            $envelope = ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json

            $envelope.error | Should -Match 'interactive input'
        }
    }

    It 'Refuses an unrecognised result type' {
        InModuleScope $script:moduleName {
            $response = @{ Ok = $true; Result = '{"resultType":"something_new"}' | ConvertFrom-Json }

            (ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json).error |
                Should -Match 'unsupported result type'
        }
    }

    It 'Never inlines image or audio bytes' -ForEach @(
        @{ Type = 'image'; Mime = 'image/png' }
        @{ Type = 'audio'; Mime = 'audio/wav' }
    ) {
        InModuleScope $script:moduleName -Parameters @{ Type = $Type; Mime = $Mime } {
            param($Type, $Mime)
            $payload = 'A' * 5000
            $response = @{
                Ok     = $true
                Result = (@{ resultType = 'complete'; content = @(@{ type = $Type; data = $payload; mimeType = $Mime }) } |
                    ConvertTo-Json -Depth 8 | ConvertFrom-Json)
            }

            $text = ConvertFrom-ShpMcpToolResult -Response $response

            $text | Should -Not -Match 'AAAAAAAAAA'
            $text | Should -Match ([regex]::Escape($Mime))
            ($text | ConvertFrom-Json).output | Should -Match 'omitted'
        }
    }

    It 'Reports a resource link without fetching it' {
        InModuleScope $script:moduleName {
            $response = @{
                Ok     = $true
                Result = '{"resultType":"complete","content":[{"type":"resource_link","uri":"https://example.invalid/x","name":"x","mimeType":"text/plain"}]}' | ConvertFrom-Json
            }

            $envelope = ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json

            $envelope.output | Should -Match 'not fetched'
            $envelope.output | Should -Match 'example.invalid'
        }
    }

    It 'Includes the text of an embedded resource and omits a binary one' {
        InModuleScope $script:moduleName {
            $withText = @{ Ok = $true; Result = '{"content":[{"type":"resource","resource":{"uri":"file:///a.rs","text":"fn main(){}"}}]}' | ConvertFrom-Json }
            (ConvertFrom-ShpMcpToolResult -Response $withText | ConvertFrom-Json).output | Should -Be 'fn main(){}'

            $binary = @{ Ok = $true; Result = '{"content":[{"type":"resource","resource":{"uri":"file:///a.bin","mimeType":"application/octet-stream","blob":"AAAA"}}]}' | ConvertFrom-Json }
            (ConvertFrom-ShpMcpToolResult -Response $binary | ConvertFrom-Json).output | Should -Match 'omitted'
        }
    }

    It 'Carries structuredContent alongside the text' {
        InModuleScope $script:moduleName {
            $response = @{
                Ok     = $true
                Result = '{"resultType":"complete","content":[{"type":"text","text":"{\"t\":22}"}],"structuredContent":{"t":22}}' | ConvertFrom-Json
            }

            $envelope = ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json

            $envelope.structured.t | Should -Be 22
        }
    }

    It 'Turns a JSON-RPC protocol error into the error envelope, naming the code' {
        InModuleScope $script:moduleName {
            $response = @{ Ok = $false; Error = ('{"code":-32602,"message":"Unknown tool: nope"}' | ConvertFrom-Json) }

            (ConvertFrom-ShpMcpToolResult -Response $response | ConvertFrom-Json).error |
                Should -Be 'MCP error -32602: Unknown tool: nope'
        }
    }

    It 'Emits a single-line envelope, so a tool result cannot break the transcript' {
        InModuleScope $script:moduleName {
            $response = @{ Ok = $true; Result = '{"content":[{"type":"text","text":"a\nb\nc"}]}' | ConvertFrom-Json }

            $text = ConvertFrom-ShpMcpToolResult -Response $response

            $text.Contains("`n") | Should -BeFalse
        }
    }
}
