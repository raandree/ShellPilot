BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Start-ShpChat' {
    It 'Exits on /exit without calling the model' {
        InModuleScope $script:moduleName {
            Mock Read-Host { '/exit' }
            Mock Invoke-Shp { }
            Mock Write-Host { }
            Start-ShpChat
            Should -Invoke Invoke-Shp -Times 0 -Exactly
        }
    }

    It 'Sends a normal line to the model then exits' {
        InModuleScope $script:moduleName {
            $script:shpReads = @('hello', '/exit')
            $script:shpReadIndex = 0
            Mock Read-Host { $r = $script:shpReads[$script:shpReadIndex]; $script:shpReadIndex++; $r }
            Mock Invoke-Shp { [pscustomobject]@{ Content = 'hi there' } }
            Mock Write-Host { }
            Start-ShpChat -DisableStreaming
            Should -Invoke Invoke-Shp -Times 1 -Exactly
        }
    }

    It 'Clears the conversation on /clear' {
        InModuleScope $script:moduleName {
            $script:shpReads2 = @('/clear', '/exit')
            $script:shpReadIndex2 = 0
            Mock Read-Host { $r = $script:shpReads2[$script:shpReadIndex2]; $script:shpReadIndex2++; $r }
            Mock Clear-ShpChat { }
            Mock Invoke-Shp { }
            Mock Write-Host { }
            Start-ShpChat
            Should -Invoke Clear-ShpChat -Times 1 -Exactly
        }
    }
}
