BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpMcpToolList' {
    It 'Returns a single page' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                @{ Ok = $true; Result = '{"tools":[{"name":"a"},{"name":"b"}]}' | ConvertFrom-Json }
            }

            $listed = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

            $listed.Ok | Should -BeTrue
            $listed.Tools.Count | Should -Be 2
            $listed.Truncated | Should -BeFalse
        }
    }

    It 'Follows nextCursor to the end of the list' {
        InModuleScope $script:moduleName {
            $script:page = 0
            Mock Invoke-ShpMcpRequest {
                $script:page++
                switch ($script:page) {
                    1 { @{ Ok = $true; Result = '{"tools":[{"name":"a"}],"nextCursor":"p2"}' | ConvertFrom-Json } }
                    2 { @{ Ok = $true; Result = '{"tools":[{"name":"b"}],"nextCursor":"p3"}' | ConvertFrom-Json } }
                    default { @{ Ok = $true; Result = '{"tools":[{"name":"c"}]}' | ConvertFrom-Json } }
                }
            }

            $listed = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

            $listed.Tools.Count | Should -Be 3
            @($listed.Tools.name) | Should -Be @('a', 'b', 'c')
        }
    }

    It 'Passes the cursor back to the server' {
        InModuleScope $script:moduleName {
            $script:page = 0
            $script:seenCursor = $null
            Mock Invoke-ShpMcpRequest {
                $script:page++
                if ($script:page -eq 1) { return @{ Ok = $true; Result = '{"tools":[{"name":"a"}],"nextCursor":"CURSOR-1"}' | ConvertFrom-Json } }
                $script:seenCursor = $Params['cursor']
                @{ Ok = $true; Result = '{"tools":[]}' | ConvertFrom-Json }
            }

            $null = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

            $script:seenCursor | Should -Be 'CURSOR-1'
        }
    }

    It 'Stops on a repeating cursor instead of paging forever' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                @{ Ok = $true; Result = '{"tools":[{"name":"a"}],"nextCursor":"same"}' | ConvertFrom-Json }
            }

            $listed = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

            $listed.Ok | Should -BeTrue
            Should -Invoke Invoke-ShpMcpRequest -Times 2 -Exactly
        }
    }

    It 'Caps the number of tools and says it truncated' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                $tools = 1..50 | ForEach-Object { @{ name = "tool$_" } }
                @{ Ok = $true; Result = (@{ tools = $tools } | ConvertTo-Json -Depth 6 | ConvertFrom-Json) }
            }

            $listed = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new('')) -MaxTool 10

            $listed.Tools.Count | Should -Be 10
            $listed.Truncated | Should -BeTrue
        }
    }

    It 'Caps the number of pages a hostile server can make it fetch' {
        InModuleScope $script:moduleName {
            $script:page = 0
            Mock Invoke-ShpMcpRequest {
                $script:page++
                @{ Ok = $true; Result = (@{ tools = @(@{ name = "t$script:page" }); nextCursor = "c$script:page" } | ConvertTo-Json -Depth 6 | ConvertFrom-Json) }
            }

            $listed = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new('')) -MaxPage 3 -MaxTool 500

            $listed.Truncated | Should -BeTrue
            Should -Invoke Invoke-ShpMcpRequest -Times 3 -Exactly
        }
    }

    It 'Reports a failing tools/list rather than returning an empty list' {
        InModuleScope $script:moduleName {
            Mock Invoke-ShpMcpRequest {
                @{ Ok = $false; Error = ([pscustomobject]@{ code = -32603; message = 'boom' }) }
            }

            $listed = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))

            $listed.Ok | Should -BeFalse
            $listed.Reason | Should -Match 'boom'
        }
    }

    It 'Declares the protocol version only for a modern server' {
        InModuleScope $script:moduleName {
            $script:sawVersion = 'unset'
            Mock Invoke-ShpMcpRequest {
                $script:sawVersion = $ProtocolVersion
                @{ Ok = $true; Result = '{"tools":[]}' | ConvertFrom-Json }
            }

            $null = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new(''))
            $script:sawVersion | Should -BeNullOrEmpty

            $null = Get-ShpMcpToolList -Writer ([System.IO.StringWriter]::new()) -Reader ([System.IO.StringReader]::new('')) -ProtocolVersion '2026-07-28'
            $script:sawVersion | Should -Be '2026-07-28'
        }
    }
}
