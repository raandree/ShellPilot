BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Start-ShpJob' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Start-ShpJob' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Start-ShpJob' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'Should accept only the two cmdlets it is allowed to run' {
        InModuleScope $script:moduleName {
            $validateSet = (Get-Command -Name 'Start-ShpJob').Parameters['Command'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }

            $validateSet.ValidValues | Should -Be @('Invoke-Shp', 'Invoke-ShpBatch')
            { Start-ShpJob -Command 'Get-ChildItem' -Parameter @{} } | Should -Throw
        }
    }

    # The job really has to import the module and reach the cmdlet. Proved with
    # a call that fails INSIDE the job before any network request: the CI
    # entitlement gate is raised before the token exchange, so a job that comes
    # back carrying ShpCopilotBackendInCi is a job that ran Invoke-Shp with the
    # parameters it was handed.
    Context 'The job really runs the requested cmdlet' {
        BeforeAll {
            $script:savedCi = [System.Environment]::GetEnvironmentVariable('CI')
            $script:savedApiBase = [System.Environment]::GetEnvironmentVariable('SHELLPILOT_API_BASE')
            $script:savedAllow = [System.Environment]::GetEnvironmentVariable('SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI')
            Remove-Item -LiteralPath 'Env:SHELLPILOT_API_BASE' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'Env:SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI' -ErrorAction SilentlyContinue
            $env:CI = 'true'
        }

        AfterAll {
            foreach ($pair in @(
                    @{ Name = 'CI'; Value = $script:savedCi }
                    @{ Name = 'SHELLPILOT_API_BASE'; Value = $script:savedApiBase }
                    @{ Name = 'SHELLPILOT_ALLOW_COPILOT_BACKEND_IN_CI'; Value = $script:savedAllow }
                )) {
                if ($null -ne $pair.Value) {
                    Set-Item -LiteralPath "Env:$($pair.Name)" -Value $pair.Value
                } else {
                    Remove-Item -LiteralPath "Env:$($pair.Name)" -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Should return a job that invokes Invoke-Shp with the supplied parameters' {
            $job = InModuleScope $script:moduleName {
                Start-ShpJob -Command 'Invoke-Shp' -Parameter @{ Prompt = 'hi'; DisableBrowsing = $true }
            }

            try {
                $job | Should -BeOfType ([System.Management.Automation.Job])
                $null = Wait-Job -Job $job -Timeout 120

                $jobError = $null
                $null = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobError
                @($jobError)[0].FullyQualifiedErrorId | Should -Match 'ShpCopilotBackendInCi'
            } finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
