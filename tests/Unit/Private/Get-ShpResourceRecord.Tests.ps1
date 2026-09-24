BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ShpResourceRecord' {
    BeforeAll {
        $script:root = Join-Path -Path $TestDrive -ChildPath 'skills'
        $null = New-Item -Path (Join-Path $script:root 'review') -ItemType Directory -Force
        $script:skillFile = Join-Path $script:root 'review/SKILL.md'
        @(
            '---'
            'name: code-review'
            'description: Review a diff for defects'
            'allowed-tools: read_file, grep_files'
            '---'
            ''
            '# Review'
            ''
            'See [the checklist](./checklist.md).'
        ) | Set-Content -LiteralPath $script:skillFile -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:root 'review/checklist.md') -Value '- check the tests' -Encoding utf8
    }

    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Get-ShpResourceRecord' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Get-ShpResourceRecord' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    Context 'Provenance' {
        It 'Should report the source root, the relative path and a SHA-256 of the body' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $record = Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill

                $record.Ok | Should -BeTrue
                $record.SourceRoot | Should -Not -BeNullOrEmpty
                $record.RelativePath | Should -Match 'review'
                $record.Hash | Should -Match '^[0-9a-f]{64}$'
                $record.SizeBytes | Should -BeGreaterThan 0
                $record.Trust | Should -BeExactly 'ExplicitPath'
                $record.SchemaVersion | Should -Be 1
            }
        }

        It 'Should report the same hash for the same bytes and a different one after an edit' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $first = (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill).Hash
                $second = (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill).Hash
                $first | Should -BeExactly $second

                Add-Content -LiteralPath $File -Value 'one more line'
                (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill).Hash | Should -Not -BeExactly $first
            }
        }
    }

    Context 'Metadata validation' {
        It 'Should read the declared name and description' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $record = Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill
                $record.Name | Should -BeExactly 'code-review'
                $record.Description | Should -BeExactly 'Review a diff for defects'
            }
        }

        It 'Should refuse a Skill with no description rather than offering a nameless one' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $path = Join-Path $Root 'bare/SKILL.md'
                $null = New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force
                @('---', 'name: bare', '---', '', 'body') | Set-Content -LiteralPath $path -Encoding utf8

                $record = Get-ShpResourceRecord -Path $path -Root $Root -Kind Skill
                $record.Ok | Should -BeFalse
                $record.Reason | Should -Match 'description'
            }
        }

        It 'Should refuse a name outside the allowed shape' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $path = Join-Path $Root 'weird/SKILL.md'
                $null = New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force
                @('---', 'name: ../../etc/passwd', 'description: nope', '---', 'body') | Set-Content -LiteralPath $path -Encoding utf8

                $record = Get-ShpResourceRecord -Path $path -Root $Root -Kind Skill
                $record.Ok | Should -BeFalse
                $record.Reason | Should -Match 'name'
            }
        }

        It 'Should cap a description rather than passing an unbounded one to the model' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $path = Join-Path $Root 'long/SKILL.md'
                $null = New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force
                @('---', 'name: long', ('description: ' + ('x' * 5000)), '---', 'body') | Set-Content -LiteralPath $path -Encoding utf8

                $record = Get-ShpResourceRecord -Path $path -Root $Root -Kind Skill
                $record.Description.Length | Should -BeLessOrEqual 1024
                $record.Warning | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Progressive disclosure is preserved' {
        It 'Should return the body only when asked for it' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill).Body | Should -BeNullOrEmpty
                (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill -IncludeBody).Body | Should -Match 'Review'
            }
        }

        It 'Should strip the front matter from the body it returns' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $body = (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill -IncludeBody).Body
                $body | Should -Not -Match 'allowed-tools'
            }
        }
    }

    Context 'Bounds' {
        It 'Should refuse a body over the byte cap' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $path = Join-Path $Root 'big/SKILL.md'
                $null = New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force
                @('---', 'name: big', 'description: big', '---', ('y' * 4000)) | Set-Content -LiteralPath $path -Encoding utf8

                $record = Get-ShpResourceRecord -Path $path -Root $Root -Kind Skill -MaxBytes 1024
                $record.Ok | Should -BeFalse
                $record.Reason | Should -Match 'cap|bytes'
            }
        }

        It 'Should fingerprint a directly referenced local resource and bound how many it follows' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $record = Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill -IncludeBody -IncludeReference
                @($record.Reference).Count | Should -Be 1
                $record.Reference[0].RelativePath | Should -Match 'checklist'
                $record.Reference[0].Hash | Should -Match '^[0-9a-f]{64}$'
            }
        }

        It 'Should stop at the reference count cap rather than walking a whole tree' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $folder = Join-Path $Root 'many'
                $null = New-Item -Path $folder -ItemType Directory -Force
                $links = foreach ($i in 1..10) {
                    Set-Content -LiteralPath (Join-Path $folder "ref$i.md") -Value "ref $i" -Encoding utf8
                    "[ref$i](./ref$i.md)"
                }
                @('---', 'name: many', 'description: many', '---') + $links | Set-Content -LiteralPath (Join-Path $folder 'SKILL.md') -Encoding utf8

                $record = Get-ShpResourceRecord -Path (Join-Path $folder 'SKILL.md') -Root $Root -Kind Skill -IncludeBody -IncludeReference -MaxReference 3
                @($record.Reference).Count | Should -Be 3
                $record.Warning -join ' ' | Should -Match 'reference'
            }
        }

        It 'Should never fetch a remote reference' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $folder = Join-Path $Root 'remote'
                $null = New-Item -Path $folder -ItemType Directory -Force
                @('---', 'name: remote', 'description: remote', '---', '[docs](https://example.com/page.md)') |
                    Set-Content -LiteralPath (Join-Path $folder 'SKILL.md') -Encoding utf8

                $record = Get-ShpResourceRecord -Path (Join-Path $folder 'SKILL.md') -Root $Root -Kind Skill -IncludeBody -IncludeReference
                @($record.Reference).Count | Should -Be 0
            }
        }

        It 'Should refuse a reference that escapes the source root' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $outside = Join-Path (Split-Path $Root -Parent) 'outside.md'
                Set-Content -LiteralPath $outside -Value 'not yours' -Encoding utf8
                $folder = Join-Path $Root 'escape'
                $null = New-Item -Path $folder -ItemType Directory -Force
                @('---', 'name: escape', 'description: escape', '---', '[out](../../outside.md)') |
                    Set-Content -LiteralPath (Join-Path $folder 'SKILL.md') -Encoding utf8

                $record = Get-ShpResourceRecord -Path (Join-Path $folder 'SKILL.md') -Root $Root -Kind Skill -IncludeBody -IncludeReference
                @($record.Reference).Count | Should -Be 0
                $record.Warning -join ' ' | Should -Match 'outside|escape'
            }
        }
    }

    Context 'Mutation between catalog and load' {
        It 'Should refuse a body whose hash no longer matches the one the catalog recorded' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $folder = Join-Path $Root 'mutate'
                $null = New-Item -Path $folder -ItemType Directory -Force
                $path = Join-Path $folder 'SKILL.md'
                @('---', 'name: mutate', 'description: mutate', '---', 'original') | Set-Content -LiteralPath $path -Encoding utf8
                $catalogued = (Get-ShpResourceRecord -Path $path -Root $Root -Kind Skill).Hash

                Set-Content -LiteralPath $path -Value 'replaced entirely' -Encoding utf8

                $record = Get-ShpResourceRecord -Path $path -Root $Root -Kind Skill -IncludeBody -ExpectedHash $catalogued
                $record.Ok | Should -BeFalse
                $record.Changed | Should -BeTrue
                $record.Reason | Should -Match 'changed'
            }
        }

        It 'Should accept a body whose hash still matches' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $catalogued = (Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill).Hash
                $record = Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill -IncludeBody -ExpectedHash $catalogued
                $record.Ok | Should -BeTrue
                $record.Changed | Should -BeFalse
            }
        }
    }

    Context 'Experimental allowed-tools metadata' {
        It 'Should read the declared tool list' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root; File = $script:skillFile } {
                param($Root, $File)

                $record = Get-ShpResourceRecord -Path $File -Root $Root -Kind Skill
                @($record.AllowedTool) | Should -Be @('read_file', 'grep_files')
            }
        }

        It 'Should report no list at all when the file declares none, which must not be read as an empty allow list' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $folder = Join-Path $Root 'notools'
                $null = New-Item -Path $folder -ItemType Directory -Force
                @('---', 'name: notools', 'description: notools', '---', 'body') | Set-Content -LiteralPath (Join-Path $folder 'SKILL.md') -Encoding utf8

                $record = Get-ShpResourceRecord -Path (Join-Path $folder 'SKILL.md') -Root $Root -Kind Skill
                $record.AllowedTool | Should -BeNullOrEmpty
                $record.DeclaresAllowedTool | Should -BeFalse
            }
        }
    }

    Context 'Instruction files' {
        It 'Should read an instruction front matter and fingerprint it the same way' {
            InModuleScope $script:moduleName -Parameters @{ Root = $script:root } {
                param($Root)

                $path = Join-Path $Root 'style.instructions.md'
                @('---', 'description: House style', 'applyTo: "**/*.ps1"', '---', 'Use full cmdlet names.') |
                    Set-Content -LiteralPath $path -Encoding utf8

                $record = Get-ShpResourceRecord -Path $path -Root $Root -Kind Instruction
                $record.Ok | Should -BeTrue
                $record.Description | Should -BeExactly 'House style'
                $record.ApplyTo | Should -BeExactly '**/*.ps1'
                $record.Hash | Should -Match '^[0-9a-f]{64}$'
            }
        }
    }
}
