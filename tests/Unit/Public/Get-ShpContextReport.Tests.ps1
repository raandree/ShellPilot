BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpContextReport' {
    BeforeEach {
        InModuleScope $script:moduleName {
            Clear-ShpContext
            $script:ShpChat = @()
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            $script:ShpModelLimitCache = $null
        }
    }
    AfterEach {
        InModuleScope $script:moduleName {
            Clear-ShpContext
            $script:ShpChat = @()
            $script:ShpUserTools = @{}
            $script:ShpMcpServers = @{}
            $script:ShpModelLimitCache = $null
        }
    }

    Context 'Command surface' {
        It 'Should be exported by the module' {
            Get-Command -Name 'Get-ShpContextReport' -Module $script:moduleName | Should -Not -BeNullOrEmpty
        }
        It 'Should account the context without any provider call or credential' {
            InModuleScope $script:moduleName {
                Mock Invoke-ShpHttpRequest { throw 'a Context report must not issue a request' }
                Mock Invoke-ShpStreamRequest { throw 'a Context report must not issue a request' }
                Mock Get-ShpSessionToken { throw 'a Context report must not exchange a Session token' }
                Mock Resolve-ShpOAuthToken { throw 'a Context report must not read an OAuth token' }

                $report = Get-ShpContextReport -Prompt 'Summarise the build failure.'

                $report.PSTypeNames | Should -Contain 'ShellPilot.ContextReport'
                Should -Invoke Invoke-ShpHttpRequest -Times 0 -Exactly
                Should -Invoke Get-ShpSessionToken -Times 0 -Exactly
                Should -Invoke Resolve-ShpOAuthToken -Times 0 -Exactly
            }
        }
    }

    Context 'Attribution' {
        It 'Names every accounted source in one fixed order' {
            $report = Get-ShpContextReport -Prompt 'hello'

            @($report.Sources.Name) | Should -Be @(
                'System', 'Instructions', 'SkillCatalog', 'SkillBodies',
                'ToolSchemas', 'Attachments', 'SessionChat', 'Prompt', 'ToolResults')
        }

        It 'Reconciles the total with the sum of the known sources under one estimator' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = ('prior question ' * 50) }
                    [pscustomobject]@{ role = 'assistant'; content = ('prior answer ' * 50) }
                )
            }

            $report = Get-ShpContextReport -Prompt ('please summarise ' * 40) -SystemPrompt ('be terse ' * 30)

            $report.Estimator | Should -BeExactly 'ConvertTo-ShpTokenCount'
            $known = @($report.Sources | Where-Object { $_.Known })
            $sum = ($known | Measure-Object -Property EstimatedTokens -Sum).Sum
            $report.EstimatedTokens | Should -Be $sum
            $report.EstimatedTokens | Should -BeGreaterThan 0
        }

        It 'Attributes the current prompt to the Prompt source' {
            $small = Get-ShpContextReport -Prompt 'hi'
            $large = Get-ShpContextReport -Prompt ('token ' * 500)

            $promptRow = { param($r) ($r.Sources | Where-Object { $_.Name -eq 'Prompt' }).EstimatedTokens }
            (& $promptRow $large) | Should -BeGreaterThan (& $promptRow $small)
            (& $promptRow $large) | Should -Be (ConvertTo-ShpTokenCount -Text ('token ' * 500))
        }

        It 'Attributes prior turns to Session chat rather than to the prompt' {
            InModuleScope $script:moduleName {
                $script:ShpChat = @(
                    [pscustomobject]@{ role = 'user'; content = ('earlier ' * 200) }
                    [pscustomobject]@{ role = 'assistant'; content = ('reply ' * 200) }
                )
            }

            $report = Get-ShpContextReport -Prompt 'next'

            $chatRow = $report.Sources | Where-Object { $_.Name -eq 'SessionChat' }
            $chatRow.EstimatedTokens | Should -BeGreaterThan 100
            $chatRow.ItemCount | Should -Be 2
            ($report.Sources | Where-Object { $_.Name -eq 'Prompt' }).EstimatedTokens | Should -BeLessThan 10
        }

        It 'Attributes tool-role history to Tool results, not to Session chat' {
            $history = @(
                [pscustomobject]@{ role = 'user'; content = 'read the log' }
                [pscustomobject]@{ role = 'tool'; content = ('LOGLINE ' * 300) }
                [pscustomobject]@{ role = 'assistant'; content = 'done' }
            )

            $report = Get-ShpContextReport -Prompt 'next' -History $history

            $toolRow = $report.Sources | Where-Object { $_.Name -eq 'ToolResults' }
            $toolRow.ItemCount | Should -Be 1
            $toolRow.EstimatedTokens | Should -BeGreaterThan 100
            ($report.Sources | Where-Object { $_.Name -eq 'SessionChat' }).ItemCount | Should -Be 2
        }

        It 'Attributes caller instructions to the Instructions source' {
            $bare = Get-ShpContextReport -Prompt 'hi'
            $guided = Get-ShpContextReport -Prompt 'hi' -SystemPrompt ('always cite sources. ' * 50)

            $row = { param($r) ($r.Sources | Where-Object { $_.Name -eq 'Instructions' }).EstimatedTokens }
            (& $row $guided) | Should -BeGreaterThan (& $row $bare)
        }

        It 'Attributes the Skill catalog and reports unloaded bodies as unknown' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-skill-{0}" -f [guid]::NewGuid().ToString('N'))
            $skill = Join-Path $root 'inventory'
            $null = New-Item -ItemType Directory -Path $skill -Force
            Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value @(
                '---'
                'name: inventory'
                'description: Count the widgets in the warehouse.'
                '---'
                ('BODY LINE ' * 200)
            )
            try {
                $report = Get-ShpContextReport -Prompt 'hi' -SkillPath $root

                $catalog = $report.Sources | Where-Object { $_.Name -eq 'SkillCatalog' }
                $catalog.EstimatedTokens | Should -BeGreaterThan 0
                $catalog.ItemCount | Should -Be 1
                $bodies = $report.Sources | Where-Object { $_.Name -eq 'SkillBodies' }
                $bodies.Known | Should -BeFalse
                $bodies.EstimatedTokens | Should -BeNullOrEmpty
                $report.Unknown | Should -Contain 'SkillBodies'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Accounts Skill bodies when the caller asks what loading them would cost' {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("shp-skill-{0}" -f [guid]::NewGuid().ToString('N'))
            $skill = Join-Path $root 'inventory'
            $null = New-Item -ItemType Directory -Path $skill -Force
            Set-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value @(
                '---'
                'name: inventory'
                'description: Count the widgets in the warehouse.'
                '---'
                ('BODY LINE ' * 200)
            )
            try {
                $report = Get-ShpContextReport -Prompt 'hi' -SkillPath $root -IncludeSkillBody

                $bodies = $report.Sources | Where-Object { $_.Name -eq 'SkillBodies' }
                $bodies.Known | Should -BeTrue
                $bodies.EstimatedTokens | Should -BeGreaterThan 100
                $report.Unknown | Should -Not -Contain 'SkillBodies'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Attributes Tool schemas and shows what deferred loading withholds' {
            InModuleScope $script:moduleName {
                $script:ShpUserTools = @{
                    test_inventory = @{
                        Name = 'test_inventory'
                        Command = 'Get-Random'
                        Description = 'Read the warehouse inventory and return every counted widget.'
                        Schema = @{
                            type = 'function'
                            function = @{
                                name = 'test_inventory'
                                description = ('Read the warehouse inventory and return every counted widget. ' * 20)
                                parameters = @{ type = 'object'; properties = @{} }
                            }
                        }
                    }
                }

                $eager = Get-ShpContextReport -Prompt 'hi'
                $deferred = Get-ShpContextReport -Prompt 'hi' -DeferredToolLoading

                $eagerTokens = ($eager.Sources | Where-Object { $_.Name -eq 'ToolSchemas' }).EstimatedTokens
                $deferredTokens = ($deferred.Sources | Where-Object { $_.Name -eq 'ToolSchemas' }).EstimatedTokens
                $eagerTokens | Should -BeGreaterThan 0
                $deferredTokens | Should -BeLessThan $eagerTokens
                $deferred.DeferredToolLoading | Should -BeTrue
                $deferred.DeferredToolCount | Should -Be 1
                $deferred.DeferredToolSchemaTokens | Should -BeGreaterThan 0
                $eager.DeferredToolCount | Should -Be 0
            }
        }

        It 'Reports an image attachment as unknown rather than counting it as zero' {
            $report = Get-ShpContextReport -Prompt 'describe it' -Image 'https://example.invalid/picture.png'

            $row = $report.Sources | Where-Object { $_.Name -eq 'Attachments' }
            $row.Known | Should -BeFalse
            $row.Detail | Should -Match 'image'
            $report.Unknown | Should -Contain 'Attachments'
        }
    }

    Context 'Budget' {
        It 'Reports the resolved budget, its source and what is left' {
            InModuleScope $script:moduleName {
                $report = Get-ShpContextReport -Prompt 'hi' -MaxContextWindowTokens 50000

                $report.ContextBudget | Should -Be 50000
                $report.ContextBudgetSource | Should -BeExactly 'Parameter'
                $report.RemainingTokens | Should -Be (50000 - $report.EstimatedTokens)
                $report.FitsBudget | Should -BeTrue
            }
        }

        It 'Reports no remaining tokens when the guard is disabled' {
            $report = Get-ShpContextReport -Prompt 'hi' -MaxContextWindowTokens 0

            $report.ContextBudget | Should -Be 0
            $report.RemainingTokens | Should -BeNullOrEmpty
            $report.FitsBudget | Should -BeNullOrEmpty
        }
    }
}
