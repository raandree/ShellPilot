BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpSystemContent' {
    It 'Returns the base text, the catalog segments and the joined text' {
        InModuleScope $script:moduleName {
            $composition = New-ShpSystemContent

            $composition.Base | Should -Match 'research and coding assistant'
            $composition.SkillCatalog | Should -BeExactly ''
            $composition.InstructionCatalog | Should -BeExactly ''
            $composition.Text | Should -BeExactly $composition.Base
        }
    }

    It 'Adds a category sentence only for a category that is enabled' {
        InModuleScope $script:moduleName {
            $without = New-ShpSystemContent
            $withTerminal = New-ShpSystemContent -TerminalEnabled $true

            $without.Base | Should -Not -Match 'run_command'
            $withTerminal.Base | Should -Match 'run_command'
        }
    }

    It 'Names only the file tools that survived an explicit selection' {
        InModuleScope $script:moduleName {
            $offered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $null = $offered.Add('read_file')
            $null = $offered.Add('grep_files')

            $composition = New-ShpSystemContent -FileAccessEnabled $true -ExplicitToolSelection -OfferedTool $offered

            $composition.Base | Should -Match 'The available file tools are: read_file, grep_files'
            $composition.Base | Should -Not -Match 'write_file'
        }
    }

    It 'Lists the Skill catalog as its own segment and joins it into the text' {
        InModuleScope $script:moduleName {
            $catalog = @([pscustomobject]@{ Name = 'inventory'; Description = 'Count the widgets.' })

            $composition = New-ShpSystemContent -SkillsEnabled $true -SkillCatalog $catalog

            $composition.SkillCatalog | Should -Match 'inventory: Count the widgets\.'
            $composition.Base | Should -Not -Match 'inventory'
            $composition.Text | Should -Match 'inventory'
            $composition.Text | Should -BeExactly ($composition.Base + "`n`n" + $composition.SkillCatalog)
        }
    }

    It 'Lists the Instruction catalog with its applyTo hint' {
        InModuleScope $script:moduleName {
            $catalog = @([pscustomobject]@{ Name = 'style'; Description = 'House style.'; ApplyTo = '**/*.ps1' })

            $composition = New-ShpSystemContent -InstructionRootEnabled $true -InstructionCatalog $catalog

            $composition.InstructionCatalog | Should -Match 'style: House style\.'
            $composition.InstructionCatalog | Should -Match 'applies to: \*\*/\*\.ps1'
            $composition.Text | Should -BeExactly ($composition.Base + "`n`n" + $composition.InstructionCatalog)
        }
    }

    It 'Never loads a Skill body into the system content' {
        InModuleScope $script:moduleName {
            $catalog = @([pscustomobject]@{ Name = 'inventory'; Description = 'Count the widgets.'; SkillFile = 'X:\never\read\SKILL.md' })

            $composition = New-ShpSystemContent -SkillsEnabled $true -SkillCatalog $catalog

            $composition.Text | Should -Not -Match 'never'
        }
    }
}
