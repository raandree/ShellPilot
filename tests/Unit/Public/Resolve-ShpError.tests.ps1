BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-ShpError' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Mock Invoke-Shp { [pscustomobject]@{ Content = 'the path does not exist' } }
        }
    }

    It 'Warns and returns nothing when the session has no error' {
        InModuleScope $script:moduleName {
            $global:Error.Clear()
            Resolve-ShpError -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            Should -Invoke Invoke-Shp -Times 0 -Exactly
        }
    }

    It 'Sends the message, exception type and category of the supplied error' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            $null = Resolve-ShpError -ErrorRecord $record
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter {
                $Prompt -match 'Message:' -and $Prompt -match 'Exception type:' -and $Prompt -match 'Category:'
            }
        }
    }

    It 'Includes the failing command line' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            $null = Resolve-ShpError -ErrorRecord $record
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter { $Prompt -match 'definitely' }
        }
    }

    It 'Disables every tool by default' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            $null = Resolve-ShpError -ErrorRecord $record
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter {
                $DisableBrowsing -and $DisableFileAccess -and $DisableTerminal -and $DisableUserPrompts -and $DisableUserTools
            }
        }
    }

    It 'Leaves the tools enabled with -EnableTools' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            $null = Resolve-ShpError -ErrorRecord $record -EnableTools
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter { -not $DisableTerminal }
        }
    }

    It 'Appends extra guidance to the system prompt' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            $null = Resolve-ShpError -ErrorRecord $record -Instruction 'Answer in German.'
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter { $SystemPrompt -match 'Answer in German\.' }
        }
    }

    It 'Accepts an error record from the pipeline' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            ($record | Resolve-ShpError).Content | Should -Be 'the path does not exist'
        }
    }

    It 'Passes the requested model through' {
        InModuleScope $script:moduleName {
            $record = try { Get-Item 'X:\definitely\not\here' -ErrorAction Stop } catch { $_ }
            $null = Resolve-ShpError -ErrorRecord $record -Model 'claude-opus-5'
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter { $Model -eq 'claude-opus-5' }
        }
    }

    It 'Falls back to the newest error when none is supplied' {
        InModuleScope $script:moduleName {
            $global:Error.Clear()
            try { Get-Item 'X:\fallback\marker' -ErrorAction Stop } catch { }
            $null = Resolve-ShpError
            Should -Invoke Invoke-Shp -Times 1 -Exactly -ParameterFilter { $Prompt -match 'fallback' }
        }
    }
}
