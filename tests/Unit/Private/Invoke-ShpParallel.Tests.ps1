BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-ShpParallel' {
    It 'Should exist as a private function in the module' {
        InModuleScope $script:moduleName {
            Get-Command -Name 'Invoke-ShpParallel' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    It 'Should not be exported by the module' {
        Get-Command -Name 'Invoke-ShpParallel' -Module $script:moduleName -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'Should run the script block once for every work item' {
        InModuleScope $script:moduleName {
            $items = 1..7 | ForEach-Object { [pscustomobject]@{ N = $_ } }

            $result = Invoke-ShpParallel -WorkItem $items -ThrottleLimit 3 -ScriptBlock { 'n-' + $_.N }

            @($result).Count | Should -Be 7
            @($result) | Sort-Object | Should -Be @('n-1', 'n-2', 'n-3', 'n-4', 'n-5', 'n-6', 'n-7')
        }
    }

    It 'Should emit nothing for an empty work-item collection' {
        InModuleScope $script:moduleName {
            $result = Invoke-ShpParallel -WorkItem @() -ScriptBlock { 'never' }
            @($result).Count | Should -Be 0
        }
    }

    # The whole point of -ThrottleLimit is that it bounds how many calls are in
    # flight at once. Assert it by measuring, not by trusting the parameter: each
    # worker registers itself in a shared concurrent dictionary, records how many
    # workers were live at that moment, then waits long enough for an unthrottled
    # run to overlap all of them.
    It 'Should bound observed concurrency to -ThrottleLimit' {
        InModuleScope $script:moduleName {
            $live = [System.Collections.Concurrent.ConcurrentDictionary[int, int]]::new()
            $observed = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
            $items = 1..12 | ForEach-Object {
                [pscustomobject]@{ N = $_; Live = $live; Observed = $observed }
            }

            $null = Invoke-ShpParallel -WorkItem $items -ThrottleLimit 3 -ScriptBlock {
                $null = $_.Live.TryAdd($_.N, 1)
                $_.Observed.Add($_.Live.Count)
                Start-Sleep -Milliseconds 150
                $removed = 0
                $null = $_.Live.TryRemove($_.N, [ref]$removed)
            }

            ($observed | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 3
            ($observed | Measure-Object -Maximum).Maximum | Should -BeGreaterThan 1
        }
    }

    It 'Should run serially when -ThrottleLimit is 1' {
        InModuleScope $script:moduleName {
            $live = [System.Collections.Concurrent.ConcurrentDictionary[int, int]]::new()
            $observed = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
            $items = 1..4 | ForEach-Object {
                [pscustomobject]@{ N = $_; Live = $live; Observed = $observed }
            }

            $null = Invoke-ShpParallel -WorkItem $items -ThrottleLimit 1 -ScriptBlock {
                $null = $_.Live.TryAdd($_.N, 1)
                $_.Observed.Add($_.Live.Count)
                Start-Sleep -Milliseconds 50
                $removed = 0
                $null = $_.Live.TryRemove($_.N, [ref]$removed)
            }

            ($observed | Measure-Object -Maximum).Maximum | Should -Be 1
        }
    }

    # Parallel completion order is not input order, so anything downstream has to
    # carry its own identity. Prove the dispatcher really does return results out
    # of order by making the first item the slowest.
    It 'Should return results in completion order rather than input order' {
        InModuleScope $script:moduleName {
            $items = 1..4 | ForEach-Object {
                [pscustomobject]@{ N = $_; DelayMs = (5 - $_) * 120 }
            }

            $result = @(Invoke-ShpParallel -WorkItem $items -ThrottleLimit 4 -ScriptBlock {
                    Start-Sleep -Milliseconds $_.DelayMs
                    $_.N
                })

            $result.Count | Should -Be 4
            $result[0] | Should -Not -Be 1
            ($result | Sort-Object) | Should -Be @(1, 2, 3, 4)
        }
    }

    It 'Should reject a -ThrottleLimit below 1' {
        InModuleScope $script:moduleName {
            { Invoke-ShpParallel -WorkItem @([pscustomobject]@{ N = 1 }) -ThrottleLimit 0 -ScriptBlock { $_ } } |
                Should -Throw
        }
    }
}
