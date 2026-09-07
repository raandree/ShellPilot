BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Protect-ShpEgressContent' {
    AfterEach { Clear-ShpRedactionPolicy }

    Context 'Named secret environment values' {
        BeforeEach {
            $script:savedLiteralSecret = [Environment]::GetEnvironmentVariable('SHP_LITERAL_SECRET')
            $env:SHP_LITERAL_SECRET = 'opaque.[value]+$42'
            Set-ShpRedactionPolicy -SecretEnvironmentVariable 'SHP_LITERAL_SECRET'
        }

        AfterEach {
            [Environment]::SetEnvironmentVariable('SHP_LITERAL_SECRET', $script:savedLiteralSecret)
        }

        It 'Redacts named values literally in every outbound text shape and reports only names and counts' {
            InModuleScope $script:moduleName {
                $secret = $env:SHP_LITERAL_SECRET
                $messages = @(
                    @{ role = 'user'; content = "first $secret then $secret" }
                    @{ role = 'tool'; content = @(@{ type = 'text'; text = $secret }) }
                    @{ type = 'function_call_output'; output = $secret }
                    @{ role = 'assistant'; content = $secret }
                )
                $hits = Protect-ShpEgressContent -Message $messages
                $messages[0].content | Should -BeExactly 'first [redacted:env-SHP_LITERAL_SECRET] then [redacted:env-SHP_LITERAL_SECRET]'
                $messages[1].content[0].text | Should -BeExactly '[redacted:env-SHP_LITERAL_SECRET]'
                $messages[2].output | Should -BeExactly '[redacted:env-SHP_LITERAL_SECRET]'
                $messages[3].content | Should -BeExactly $secret
                ($hits | Where-Object Name -eq 'env-SHP_LITERAL_SECRET').Count | Should -Be 4
                $hits | ConvertTo-Json | Should -Not -Match ([regex]::Escape($secret))
                @(Protect-ShpEgressContent -Message $messages).Count | Should -Be 0
            }
        }

        It 'Resolves the current value after a secret rotates' {
            $env:SHP_LITERAL_SECRET = 'rotated-secret-value'
            InModuleScope $script:moduleName {
                $message = @(@{ role = 'user'; content = 'rotated-secret-value' })
                $null = Protect-ShpEgressContent -Message $message
                $message[0].content | Should -BeExactly '[redacted:env-SHP_LITERAL_SECRET]'
            }
        }

        It 'Skips an unset or empty named value without matching all text' {
            $env:SHP_LITERAL_SECRET = ''
            InModuleScope $script:moduleName {
                $message = @(@{ role = 'user'; content = 'unchanged text' })
                @(Protect-ShpEgressContent -Message $message).Count | Should -Be 0
                $message[0].content | Should -BeExactly 'unchanged text'
            }
        }

        It 'Refuses a value that becomes too short before egress' {
            $env:SHP_LITERAL_SECRET = 'true'
            InModuleScope $script:moduleName {
                { Protect-ShpEgressContent -Message @(@{ role = 'user'; content = 'true' }) } |
                    Should -Throw '*SHP_LITERAL_SECRET*8*'
            }
        }

        It 'Protects the Event stream through the same rule' {
            $eventPath = Join-Path $TestDrive 'literal-secret.jsonl'
            InModuleScope $script:moduleName -Parameters @{ EventPath = $eventPath } {
                param($EventPath)
                Write-ShpEvent -State @{ Enabled = $true; Path = $EventPath; Sequence = 0; Redact = $true } -Type 'tool.result' -Data @{ text = $env:SHP_LITERAL_SECRET }
            }
            (Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json).data.text |
                Should -BeExactly '[redacted:env-SHP_LITERAL_SECRET]'
        }
    }

    Context 'Built-in patterns' {
        It 'Redacts a GitHub token and reports a stable placeholder and count' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $message = @(@{ role = 'user'; content = "token: $secret twice: $secret" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Be 'token: [redacted:github-token] twice: [redacted:github-token]'
                $message[0]['content'] | Should -Not -Match ([regex]::Escape($secret))
                @($hits).Count | Should -Be 1
                ($hits | Where-Object Name -eq 'github-token').Count | Should -Be 2
            }
        }

        It 'Redacts an AWS access key id' {
            InModuleScope $script:moduleName {
                $secret = 'AKIAIOSFODNN7EXAMPLE'
                $message = @(@{ role = 'user'; content = "aws key $secret in the log" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Be 'aws key [redacted:aws-access-key-id] in the log'
                ($hits | Where-Object Name -eq 'aws-access-key-id').Count | Should -Be 1
            }
        }

        It 'Redacts a PEM private-key block spanning multiple lines' {
            InModuleScope $script:moduleName {
                $secret = @(
                    '-----BEGIN RSA PRIVATE KEY-----'
                    'MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEr7wDWERXfPUasfNyfNaTNTgOSpTG9'
                    'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789=='
                    '-----END RSA PRIVATE KEY-----'
                ) -join "`n"
                $message = @(@{ role = 'tool'; tool_call_id = '1'; content = "key follows:`n$secret`ndone" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Be "key follows:`n[redacted:pem-private-key]`ndone"
                ($hits | Where-Object Name -eq 'pem-private-key').Count | Should -Be 1
            }
        }

        It 'Redacts a JWT' {
            InModuleScope $script:moduleName {
                $secret = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U'
                $message = @(@{ role = 'user'; content = "auth: $secret" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Be 'auth: [redacted:jwt]'
                ($hits | Where-Object Name -eq 'jwt').Count | Should -Be 1
            }
        }

        It 'Redacts basic-auth credentials embedded in a URL, keeping the URL shape' {
            InModuleScope $script:moduleName {
                $message = @(@{ role = 'user'; content = 'clone https://alice:hunter2@example.com/repo.git please' })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Be 'clone https://[redacted:url-credentials]@example.com/repo.git please'
                ($hits | Where-Object Name -eq 'url-credentials').Count | Should -Be 1
            }
        }

        It 'Redacts a connection-string password field, keeping the key name' {
            InModuleScope $script:moduleName {
                $message = @(@{ role = 'tool'; tool_call_id = '1'; content = 'Server=tcp:x;Database=y;User Id=admin;Password=Sup3rSecret!;Encrypt=true' })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Be 'Server=tcp:x;Database=y;User Id=admin;Password=[redacted:connection-string-password];Encrypt=true'
                ($hits | Where-Object Name -eq 'connection-string-password').Count | Should -Be 1
            }
        }

        It 'Returns an empty result when nothing matches' {
            InModuleScope $script:moduleName {
                $message = @(@{ role = 'user'; content = 'nothing secret here' })

                $hits = Protect-ShpEgressContent -Message $message

                @($hits).Count | Should -Be 0
                $message[0]['content'] | Should -Be 'nothing secret here'
            }
        }
    }

    Context 'Role handling' {
        It 'Never redacts the assistant''s own chat message' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $message = @(@{ role = 'assistant'; content = "here is $secret verbatim" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Match ([regex]::Escape($secret))
                @($hits).Count | Should -Be 0
            }
        }

        It 'Never redacts a Responses-API function_call item (the model''s own tool call)' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                # A real function_call item never carries 'output', but the guard
                # must key off 'type' before it ever inspects a field - so prove
                # the skip with a field this function would otherwise scan.
                $message = @(@{ type = 'function_call'; call_id = '1'; name = 'run_command'; output = "echo $secret" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['output'] | Should -Match ([regex]::Escape($secret))
                @($hits).Count | Should -Be 0
            }
        }

        It 'Redacts a Responses-API function_call_output item on its output field' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $message = @(@{ type = 'function_call_output'; call_id = '1'; output = "result: $secret" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['output'] | Should -Be 'result: [redacted:github-token]'
                ($hits | Where-Object Name -eq 'github-token').Count | Should -Be 1
            }
        }

        It 'Redacts a tool-role chat message (the run_command/read_file/fetch_url egress path)' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $message = @(@{ role = 'tool'; tool_call_id = '1'; name = 'run_command'; content = "{`"stdout`":`"$secret`"}" })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'] | Should -Not -Match ([regex]::Escape($secret))
                ($hits | Where-Object Name -eq 'github-token').Count | Should -Be 1
            }
        }
    }

    Context 'Content block shapes (vision input)' {
        It 'Redacts a text content block but leaves an image_url block untouched' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $imageBlock = @{ type = 'image_url'; image_url = @{ url = 'data:image/png;base64,AAAA' } }
                $message = @(@{
                        role    = 'user'
                        content = @(
                            @{ type = 'text'; text = "look at this: $secret" }
                            $imageBlock
                        )
                    })

                $hits = Protect-ShpEgressContent -Message $message

                $message[0]['content'][0]['text'] | Should -Be 'look at this: [redacted:github-token]'
                $message[0]['content'][1]['image_url']['url'] | Should -Be 'data:image/png;base64,AAAA'
                ($hits | Where-Object Name -eq 'github-token').Count | Should -Be 1
            }
        }
    }

    Context 'Idempotency across repeated calls' {
        It 'Reports no further matches once a span has already been redacted' {
            InModuleScope $script:moduleName {
                $secret = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                $message = @(@{ role = 'user'; content = "token: $secret" })

                $first = Protect-ShpEgressContent -Message $message
                $second = Protect-ShpEgressContent -Message $message

                ($first | Where-Object Name -eq 'github-token').Count | Should -Be 1
                @($second).Count | Should -Be 0
                $message[0]['content'] | Should -Be 'token: [redacted:github-token]'
            }
        }
    }

    Context 'Custom policy layered on the built-ins' {
        It 'Applies an additional Set-ShpRedactionPolicy rule alongside the built-ins' {
            Set-ShpRedactionPolicy -Rule 'InternalToken(itk_[A-Za-z0-9]{10,})'
            try {
                InModuleScope $script:moduleName {
                    $ghToken = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz'
                    $message = @(@{ role = 'user'; content = "gh=$ghToken internal=itk_abcdefghijklmnop" })

                    $hits = Protect-ShpEgressContent -Message $message

                    $message[0]['content'] | Should -Be 'gh=[redacted:github-token] internal=[redacted:InternalToken]'
                    ($hits | Where-Object Name -eq 'github-token').Count   | Should -Be 1
                    ($hits | Where-Object Name -eq 'InternalToken').Count  | Should -Be 1
                }
            } finally { Clear-ShpRedactionPolicy }
        }
    }
}
