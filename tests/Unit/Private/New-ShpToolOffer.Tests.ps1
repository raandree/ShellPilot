BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpToolOffer' {
    BeforeEach {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
        }
    }
    AfterEach {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
        }
    }

    It 'Offers nothing when every category is disabled' {
        InModuleScope $script:moduleName {
            $offer = New-ShpToolOffer -DisableTodoList

            @($offer.Tool).Count | Should -Be 0
            $offer.OfferedTool.Count | Should -Be 0
        }
    }

    It 'Offers exactly the enabled categories' {
        InModuleScope $script:moduleName {
            $offer = New-ShpToolOffer -BrowsingEnabled $true -TerminalEnabled $true -DisableTodoList

            @($offer.OfferedTool) | Should -Contain 'fetch_url'
            @($offer.OfferedTool) | Should -Contain 'run_command'
            @($offer.OfferedTool) | Should -Not -Contain 'read_file'
            $offer.BrowsingEnabled | Should -BeTrue
            $offer.FileAccessEnabled | Should -BeFalse
        }
    }

    It 'Narrows the offer to an explicit selection' {
        InModuleScope $script:moduleName {
            $offer = New-ShpToolOffer -FileAccessEnabled $true -ToolSelectionBound -Tool @('read_file') -DisableTodoList

            @($offer.OfferedTool) | Should -Be @('read_file')
        }
    }

    It 'Offers nothing for an explicitly empty selection' {
        InModuleScope $script:moduleName {
            $offer = New-ShpToolOffer -FileAccessEnabled $true -ToolSelectionBound -Tool @() -DisableTodoList

            $offer.OfferedTool.Count | Should -Be 0
        }
    }

    It 'Lets an exclusion beat a selection' {
        InModuleScope $script:moduleName {
            $offer = New-ShpToolOffer -FileAccessEnabled $true -ToolSelectionBound -Tool @('read_file') `
                -ExcludeTool @('read_file') -DisableTodoList

            $offer.OfferedTool.Count | Should -Be 0
        }
    }

    It 'Intersects the offer with the read-only set in Plan mode' {
        InModuleScope $script:moduleName {
            $offer = New-ShpToolOffer -FileAccessEnabled $true -TerminalEnabled $true -Mode 'Plan' -DisableTodoList

            @($offer.OfferedTool) | Should -Contain 'read_file'
            @($offer.OfferedTool) | Should -Not -Contain 'write_file'
            @($offer.OfferedTool) | Should -Not -Contain 'run_command'
        }
    }

    It 'Offers a registered User tool and maps it to its command' {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{
                test_clock = @{
                    Name = 'test_clock'; Command = 'Get-Random'; Description = 'Read the clock.'
                    Schema = @{ type = 'function'; function = @{ name = 'test_clock'; description = 'Read the clock.'; parameters = @{ type = 'object'; properties = @{} } } }
                }
            }

            $offer = New-ShpToolOffer -DisableTodoList

            @($offer.OfferedTool) | Should -Contain 'test_clock'
            $offer.UserToolCommand['test_clock'] | Should -BeExactly 'Get-Random'
            $offer.UserToolsEnabled | Should -BeTrue
        }
    }

    It 'Skips an MCP server that is not Ready without contacting it' {
        InModuleScope $script:moduleName {
            $script:ShpMcpServers = @{
                broken = @{
                    Name = 'broken'; State = 'Faulted'; FaultReason = 'start failed'
                    Tools = @(@{ Name = 'mcp_broken_read'; OriginalName = 'read'; Schema = @{ type = 'function'; function = @{ name = 'mcp_broken_read'; parameters = @{ type = 'object'; properties = @{} } } } })
                }
            }

            $offer = New-ShpToolOffer -DisableTodoList -WarningAction SilentlyContinue

            $offer.McpToolMap.Count | Should -Be 0
            $offer.McpEnabled | Should -BeFalse
        }
    }

    It 'Withholds eligible dynamic schemas and offers search_tools instead' {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{
                test_clock = @{
                    Name = 'test_clock'; Command = 'Get-Random'; Description = 'Read the clock.'
                    Schema = @{ type = 'function'; function = @{ name = 'test_clock'; description = 'Read the clock.'; parameters = @{ type = 'object'; properties = @{} } } }
                }
            }

            $offer = New-ShpToolOffer -DisableTodoList -DeferredToolLoading

            @($offer.OfferedTool) | Should -Not -Contain 'test_clock'
            @($offer.OfferedTool) | Should -Contain 'search_tools'
            @($offer.DeferredTool.Keys) | Should -Be @('test_clock')
            $offer.DeferredTool['test_clock'].Origin | Should -BeExactly 'User'
        }
    }

    It 'Keeps an explicitly selected dynamic schema eager' {
        InModuleScope $script:moduleName {
            $script:ShpUserTools = @{
                test_clock = @{
                    Name = 'test_clock'; Command = 'Get-Random'; Description = 'Read the clock.'
                    Schema = @{ type = 'function'; function = @{ name = 'test_clock'; description = 'Read the clock.'; parameters = @{ type = 'object'; properties = @{} } } }
                }
            }

            $offer = New-ShpToolOffer -DisableTodoList -DeferredToolLoading -ToolSelectionBound -Tool @('test_clock')

            @($offer.OfferedTool) | Should -Contain 'test_clock'
            $offer.DeferredTool.Count | Should -Be 0
        }
    }
}
