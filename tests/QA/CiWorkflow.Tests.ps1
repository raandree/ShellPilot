Describe 'CI minimum PowerShell install' -Tag 'FunctionalQuality' {
    BeforeAll {
        Import-Module -Name 'powershell-yaml' -ErrorAction Stop

        $workflowPath = Join-Path -Path $PSScriptRoot -ChildPath '../../.github/workflows/ci.yml'
        $workflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $workflowPath -Raw)
        $installSteps = @($workflow.jobs.test.steps | Where-Object { $_.name -eq 'Install minimum PowerShell' })
        if ($installSteps.Count -ne 1) {
            throw "Expected one 'Install minimum PowerShell' step in the test job, found $($installSteps.Count)."
        }

        $script:installScript = [string]$installSteps[0].run
        $parseErrors = $null
        $tokens = $null
        $syntaxTree = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:installScript, [ref]$tokens, [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) {
            throw "The install step does not parse: $($parseErrors[0].Message)"
        }
        $script:installCodeTokens = @($tokens | Where-Object { $_.Kind -ne 'Comment' })

        $assignments = $syntaxTree.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)

        $versionAssignments = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$version' })
        if ($versionAssignments.Count -ne 1) {
            throw "Expected one `$version assignment in the install step, found $($versionAssignments.Count)."
        }
        $script:pinnedVersion = $versionAssignments[0].Right.Expression.SafeGetValue()

        $digestAssignments = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$pinnedDigests' })
        $script:pinnedDigests = if ($digestAssignments.Count -eq 1) {
            $digestAssignments[0].Right.Expression.SafeGetValue()
        }
        else {
            @{}
        }
    }

    It 'Should not query the GitHub REST API' {
        $script:installCodeTokens.Text -match 'api\.github\.com' |
            Should -BeNullOrEmpty -Because 'an anonymous request shares the hosted runner''s per-IP rate limit'
    }

    It 'Should pin a SHA-256 digest for the <Platform> archive' -ForEach @(
        @{ Platform = 'win-x64'; ArchiveFormat = 'PowerShell-{0}-win-x64.zip' }
        @{ Platform = 'win-arm64'; ArchiveFormat = 'PowerShell-{0}-win-arm64.zip' }
        @{ Platform = 'linux-x64'; ArchiveFormat = 'powershell-{0}-linux-x64.tar.gz' }
        @{ Platform = 'linux-arm64'; ArchiveFormat = 'powershell-{0}-linux-arm64.tar.gz' }
        @{ Platform = 'osx-x64'; ArchiveFormat = 'powershell-{0}-osx-x64.tar.gz' }
        @{ Platform = 'osx-arm64'; ArchiveFormat = 'powershell-{0}-osx-arm64.tar.gz' }
    ) {
        $script:pinnedDigests[($ArchiveFormat -f $script:pinnedVersion)] |
            Should -MatchExactly '^[a-f0-9]{64}$'
    }

    Context 'When the downloaded archive does not match its pinned digest' {
        BeforeAll {
            $script:runnerVariableNames = @('RUNNER_OS', 'RUNNER_ARCH', 'RUNNER_TEMP', 'GITHUB_PATH')
            $script:savedRunnerVariables = @{}
            foreach ($name in $script:runnerVariableNames) {
                $script:savedRunnerVariables[$name] = [Environment]::GetEnvironmentVariable($name)
            }

            $script:githubPathFile = Join-Path -Path $TestDrive -ChildPath 'github_path'
            [Environment]::SetEnvironmentVariable('RUNNER_OS', 'Linux')
            [Environment]::SetEnvironmentVariable('RUNNER_ARCH', 'X64')
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $TestDrive)
            [Environment]::SetEnvironmentVariable('GITHUB_PATH', $script:githubPathFile)

            Mock -CommandName Invoke-RestMethod -MockWith {
                throw 'The install step must not call the GitHub REST API.'
            }
            Mock -CommandName Invoke-WebRequest -MockWith {
                Set-Content -LiteralPath $OutFile -Value 'not the release archive'
            }
        }

        AfterAll {
            foreach ($name in $script:runnerVariableNames) {
                [Environment]::SetEnvironmentVariable($name, $script:savedRunnerVariables[$name])
            }
        }

        It 'Should refuse the archive before installing it' {
            { & ([scriptblock]::Create($script:installScript)) } |
                Should -Throw -ExpectedMessage 'Checksum mismatch for powershell-*-linux-x64.tar.gz.'

            Should -Invoke -CommandName Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke -CommandName Invoke-RestMethod -Times 0 -Exactly
            Test-Path -LiteralPath $script:githubPathFile | Should -BeFalse
        }
    }
}
