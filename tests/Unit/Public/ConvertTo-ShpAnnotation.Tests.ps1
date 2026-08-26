BeforeAll {
    $script:moduleName = 'ShellPilot'
    $script:annotationEnvironment = @(
        'GITHUB_ACTIONS'
        'TF_BUILD'
        'GITHUB_STEP_SUMMARY'
    )
    $script:savedAnnotationEnvironment = @{}

    foreach ($name in $script:annotationEnvironment) {
        $script:savedAnnotationEnvironment[$name] =
            [System.Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    foreach ($name in $script:annotationEnvironment) {
        if ($null -ne $script:savedAnnotationEnvironment[$name]) {
            Set-Item -LiteralPath "Env:$name" `
                -Value $script:savedAnnotationEnvironment[$name]
        } else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    Get-Module -Name $script:moduleName -All |
        Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ShpAnnotation' {
    BeforeEach {
        foreach ($name in $script:annotationEnvironment) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    It 'Should be exported by the module' {
        Get-Command -Name 'ConvertTo-ShpAnnotation' -Module $script:moduleName |
            Should -Not -BeNullOrEmpty
    }

    Context 'Input mapping' {
        It 'Unwraps ContentObject from a ShellPilot result' {
            $result = [pscustomobject]@{
                ContentObject = [pscustomobject]@{
                    Level   = 'Error'
                    Path    = 'src/app.ps1'
                    Line    = 12
                    Column  = 4
                    Title   = 'Use approved verbs'
                    Message = 'Use Write-Output.'
                }
            }
            $result.PSObject.TypeNames.Insert(0, 'ShellPilot.Result')

            $annotation = $result |
                ConvertTo-ShpAnnotation -Format GitHubActions

            $annotation | Should -BeExactly (
                '::error file=src/app.ps1,line=12,col=4,' +
                'title=Use approved verbs::Use Write-Output.'
            )
        }

        It 'Accepts multiple findings in ContentObject' {
            $result = [pscustomobject]@{
                ContentObject = @(
                    [pscustomobject]@{ Level = 'Error'; Message = 'First' }
                    [pscustomobject]@{ Level = 'Warning'; Message = 'Second' }
                )
            }
            $result.PSObject.TypeNames.Insert(0, 'ShellPilot.Result')

            $annotations = @(
                $result | ConvertTo-ShpAnnotation -Format GitHubActions
            )

            $annotations | Should -HaveCount 2
            $annotations[0] | Should -BeExactly '::error::First'
            $annotations[1] | Should -BeExactly '::warning::Second'
        }

        It 'Does not unwrap ContentObject from a plain finding' {
            $finding = [pscustomobject]@{
                Level         = 'Error'
                Message       = 'Outer'
                ContentObject = [pscustomobject]@{
                    Level   = 'Warning'
                    Message = 'Inner'
                }
            }

            $annotation = $finding |
                ConvertTo-ShpAnnotation -Format GitHubActions

            $annotation | Should -BeExactly '::error::Outer'
        }

        It 'Reads finding property names case-insensitively' {
            $finding = [pscustomobject]@{
                lEvEl   = 'ERROR'
                pAtH    = 'src/app.ps1'
                lInE    = 12
                cOlUmN  = 4
                tItLe   = 'Rule'
                mEsSaGe = 'Broken'
            }

            $annotation = $finding |
                ConvertTo-ShpAnnotation -Format GitHubActions

            $annotation | Should -BeExactly (
                '::error file=src/app.ps1,line=12,col=4,title=Rule::Broken'
            )
        }

        It 'Uses PropertyMap for a caller-specific schema' {
            $finding = @{
                severity = 'Error'
                fileName = 'src/app.ps1'
                row      = 12
                offset   = 4
                rule     = 'Use approved verbs'
                detail   = 'Use Write-Output.'
            }
            $propertyMap = @{
                Level   = 'severity'
                Path    = 'fileName'
                Line    = 'row'
                Column  = 'offset'
                Title   = 'rule'
                Message = 'detail'
            }

            $annotation = $finding | ConvertTo-ShpAnnotation `
                -Format GitHubActions -PropertyMap $propertyMap

            $annotation | Should -BeExactly (
                '::error file=src/app.ps1,line=12,col=4,' +
                'title=Use approved verbs::Use Write-Output.'
            )
        }

        It 'Does not throw for a null or malformed finding' {
            {
                ConvertTo-ShpAnnotation -InputObject $null `
                    -Format GitHubActions
            } | Should -Not -Throw

            ConvertTo-ShpAnnotation -InputObject $null `
                -Format GitHubActions | Should -BeExactly '::warning::'
        }
    }

    Context 'GitHub Actions format' {
        It 'Emits the documented workflow command' {
            $finding = [pscustomobject]@{
                Level   = 'Error'
                Path    = 'src/app.ps1'
                Line    = 12
                Column  = 4
                Title   = 'Use approved verbs'
                Message = 'Use Write-Output.'
            }

            $annotation = $finding |
                ConvertTo-ShpAnnotation -Format GitHubActions

            $annotation | Should -BeExactly (
                '::error file=src/app.ps1,line=12,col=4,' +
                'title=Use approved verbs::Use Write-Output.'
            )
        }

        It 'Escapes command data and property values independently' {
            $finding = [pscustomobject]@{
                Level   = 'Error'
                Path    = 'src:part,100%;].ps1'
                Line    = 7
                Column  = 2
                Title   = 'Rule:100%,;]'
                Message = "First`r`n100%: value, semi; bracket]"
            }

            $annotation = $finding |
                ConvertTo-ShpAnnotation -Format GitHubActions

            $annotation | Should -BeExactly (
                '::error file=src%3Apart%2C100%25;].ps1,line=7,col=2,' +
                'title=Rule%3A100%25%2C;]::' +
                'First%0D%0A100%25: value, semi; bracket]'
            )
        }

        It 'Maps notice explicitly and an unknown or missing level to warning' {
            $findings = @(
                [pscustomobject]@{ Level = 'Notice'; Message = 'Information' }
                [pscustomobject]@{ Level = 'Fatal'; Message = 'Unknown' }
                [pscustomobject]@{ Message = 'Missing' }
            )

            $annotations = @(
                $findings | ConvertTo-ShpAnnotation -Format GitHubActions
            )

            $annotations[0] | Should -BeExactly '::notice::Information'
            $annotations[1] | Should -BeExactly '::warning::Unknown'
            $annotations[2] | Should -BeExactly '::warning::Missing'
        }
    }

    Context 'Azure DevOps format' {
        It 'Emits the documented task.logissue command' {
            $finding = [pscustomobject]@{
                Level   = 'Error'
                Path    = 'src/app.ps1'
                Line    = 12
                Column  = 4
                Title   = 'Use approved verbs'
                Message = 'Use Write-Output.'
            }

            $annotation = $finding |
                ConvertTo-ShpAnnotation -Format AzureDevOps

            $annotation | Should -BeExactly (
                '##vso[task.logissue type=error;sourcepath=src/app.ps1;' +
                'linenumber=12]Use Write-Output.'
            )
        }

        It 'Escapes message data and strips property delimiters' {
            $finding = [pscustomobject]@{
                Level   = 'Error'
                Path    = 'src:part,100%;].ps1'
                Line    = 7
                Message = "First`r`n100%: value, semi; bracket]"
            }

            $annotation = $finding |
                ConvertTo-ShpAnnotation -Format AzureDevOps

            $annotation | Should -BeExactly (
                '##vso[task.logissue type=error;' +
                'sourcepath=src:part,100%AZP25.ps1;linenumber=7]' +
                'First%0D%0A100%AZP25: value, semi; bracket]'
            )
        }

        It 'Maps notice and an unknown or missing level to warning' {
            $findings = @(
                [pscustomobject]@{ Level = 'Notice'; Message = 'Information' }
                [pscustomobject]@{ Level = 'Fatal'; Message = 'Unknown' }
                [pscustomobject]@{ Message = 'Missing' }
            )

            $annotations = @(
                $findings | ConvertTo-ShpAnnotation -Format AzureDevOps
            )

            $annotations[0] | Should -BeExactly (
                '##vso[task.logissue type=warning]Information'
            )
            $annotations[1] | Should -BeExactly (
                '##vso[task.logissue type=warning]Unknown'
            )
            $annotations[2] | Should -BeExactly (
                '##vso[task.logissue type=warning]Missing'
            )
        }
    }

    Context 'Text format' {
        It 'Keeps every mapped field in a readable line' {
            $finding = [pscustomobject]@{
                Level   = 'Error'
                Path    = 'src/app.ps1'
                Line    = 12
                Column  = 4
                Title   = 'Use approved verbs'
                Message = 'Use Write-Output.'
            }

            $annotation = $finding | ConvertTo-ShpAnnotation -Format Text

            $annotation | Should -BeExactly (
                '[ERROR] src/app.ps1:12:4 Use approved verbs: ' +
                'Use Write-Output.'
            )
        }
    }

    Context 'Format auto-detection' {
        It 'Prefers GitHub Actions when both vendor variables are set' {
            $env:GITHUB_ACTIONS = 'true'
            $env:TF_BUILD = 'True'

            $annotation = [pscustomobject]@{ Message = 'Finding' } |
                ConvertTo-ShpAnnotation

            $annotation | Should -BeExactly '::warning::Finding'
        }

        It 'Uses Azure DevOps when only TF_BUILD is set' {
            $env:TF_BUILD = 'True'

            $annotation = [pscustomobject]@{ Message = 'Finding' } |
                ConvertTo-ShpAnnotation

            $annotation | Should -BeExactly (
                '##vso[task.logissue type=warning]Finding'
            )
        }

        It 'Falls back to Text when neither vendor variable is set' {
            $annotation = [pscustomobject]@{ Message = 'Finding' } |
                ConvertTo-ShpAnnotation

            $annotation | Should -BeExactly '[WARNING] Finding'
        }
    }

    Context 'Destinations' {
        It 'Writes annotations to the host only when Emit is set' {
            $finding = [pscustomobject]@{ Level = 'Error'; Message = 'Broken' }

            InModuleScope $script:moduleName -Parameters @{ Finding = $finding } {
                param($Finding)

                Mock Write-Host

                $output = $Finding |
                    ConvertTo-ShpAnnotation -Format GitHubActions -Emit

                $output | Should -BeNullOrEmpty
                Should -Invoke Write-Host -Times 1 -Exactly `
                    -ParameterFilter { $Object -eq '::error::Broken' }
            }
        }

        It 'Appends a Markdown table to GITHUB_STEP_SUMMARY' {
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'summary.md'
            [System.IO.File]::WriteAllText(
                $env:GITHUB_STEP_SUMMARY,
                "Existing content`n"
            )
            $finding = [pscustomobject]@{
                Level   = 'Error'
                Path    = 'src/app.ps1'
                Line    = 12
                Column  = 4
                Title   = 'Rule'
                Message = "First|line`nSecond"
            }

            $finding | ConvertTo-ShpAnnotation -Format Text -Summary |
                Out-Null

            $summary = [System.IO.File]::ReadAllText(
                $env:GITHUB_STEP_SUMMARY
            ).Replace("`r`n", "`n")
            $expectedSummary = @(
                'Existing content'
                '| Level | Path | Line | Column | Title | Message |'
                '| --- | --- | ---: | ---: | --- | --- |'
                '| error | src/app.ps1 | 12 | 4 | Rule | First\|line<br>Second |'
                ''
            ) -join "`n"
            $summary | Should -BeExactly $expectedSummary
        }
    }
}