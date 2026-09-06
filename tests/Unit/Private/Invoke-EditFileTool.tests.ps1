BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-EditFileTool' {
    It 'Replaces exactly one literal occurrence: <Name>' -ForEach @(
        @{ Name = 'regex characters'; Content = 'a.b[0]+$^ and aXb0'; OldString = 'a.b[0]+$^'; NewString = '$1\new'; Expected = '$1\new and aXb0' }
        @{ Name = 'case-sensitive'; Content = 'OLD old Old'; OldString = 'old'; NewString = 'new'; Expected = 'OLD new Old' }
        @{ Name = 'whole file'; Content = 'old'; OldString = 'old'; NewString = 'new text'; Expected = 'new text' }
        @{ Name = 'end of file'; Content = 'start old'; OldString = 'old'; NewString = 'new'; Expected = 'start new' }
        @{ Name = 'deletion'; Content = 'start old end'; OldString = 'old'; NewString = ''; Expected = 'start  end' }
        @{ Name = 'whitespace'; Content = 'left  right'; OldString = '  '; NewString = ' '; Expected = 'left right' }
        @{ Name = 'unchanged replacement'; Content = 'old'; OldString = 'old'; NewString = 'old'; Expected = 'old' }
    ) {
        $filePath = Join-Path $TestDrive 'literal[1].txt'
        [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UTF8Encoding]::new($false))
        $parameters = @{ FilePath = $filePath; OldString = $OldString; NewString = $NewString }

        $result = InModuleScope $script:moduleName -Parameters $parameters {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString $NewString | ConvertFrom-Json
        }
        $expectedPath = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Resolve-ShpRealPath -Path $FilePath
        }

        $result.error | Should -BeNullOrEmpty
        $result.path | Should -BeExactly $expectedPath
        $result.replacements | Should -Be 1
        $result.bytes | Should -Be ([System.IO.FileInfo]::new($filePath).Length)
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly $Expected
    }

    It 'Refuses zero matches without changing bytes: <Name>' -ForEach @(
        @{ Name = 'absent'; Content = 'before'; OldString = 'missing' }
        @{ Name = 'case mismatch'; Content = 'before'; OldString = 'BEFORE' }
        @{ Name = 'different line endings'; Content = "first`r`nsecond"; OldString = "first`nsecond" }
        @{ Name = 'Unicode normalization'; Content = "caf$([char]0x00e9)"; OldString = "cafe$([char]0x0301)" }
        @{ Name = 'empty file'; Content = ''; OldString = 'old' }
    ) {
        $filePath = Join-Path $TestDrive 'no-match.txt'
        [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UTF8Encoding]::new($true))
        $original = [System.IO.File]::ReadAllBytes($filePath)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; OldString = $OldString } {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match '0 matches'
        $result.error | Should -Match 'read_file'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($original))
    }

    It 'Refuses <MatchCount> matches without changing bytes: <Name>' -ForEach @(
        @{ Name = 'separate occurrences'; Content = 'old|old|old'; OldString = 'old'; MatchCount = 3 }
        @{ Name = 'overlapping occurrences'; Content = 'aaaa'; OldString = 'aa'; MatchCount = 3 }
    ) {
        $filePath = Join-Path $TestDrive 'ambiguous.txt'
        [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UnicodeEncoding]::new($false, $true))
        $original = [System.IO.File]::ReadAllBytes($filePath)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; OldString = $OldString } {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match "$MatchCount matches"
        $result.error | Should -Match 'surrounding text'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($original))
    }

    It 'Preserves the exact bytes outside the replacement for <EncodingName>' -ForEach @(
        @{ EncodingName = 'UTF-8 without BOM'; Encoding = [System.Text.UTF8Encoding]::new($false, $true) }
        @{ EncodingName = 'UTF-8 with BOM'; Encoding = [System.Text.UTF8Encoding]::new($true, $true) }
        @{ EncodingName = 'UTF-16 LE'; Encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true) }
        @{ EncodingName = 'UTF-16 BE'; Encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true) }
        @{ EncodingName = 'UTF-32 LE'; Encoding = [System.Text.UTF32Encoding]::new($false, $true, $true) }
        @{ EncodingName = 'UTF-32 BE'; Encoding = [System.Text.UTF32Encoding]::new($true, $true, $true) }
    ) {
        $filePath = Join-Path $TestDrive 'encoded.txt'
        $unicodeText = "caf$([char]0x00e9) $([char]::ConvertFromUtf32(0x1f680))"
        $content = "$unicodeText`r`nfirst`r`nold`nlast`rend"
        $expected = "$unicodeText`r`nfirst`r`n$unicodeText`nlast`rend"
        [byte[]]$original = $Encoding.GetPreamble() + $Encoding.GetBytes($content)
        [byte[]]$expectedBytes = $Encoding.GetPreamble() + $Encoding.GetBytes($expected)
        [System.IO.File]::WriteAllBytes($filePath, $original)

        $parameters = @{ FilePath = $filePath; NewString = $unicodeText }
        $result = InModuleScope $script:moduleName -Parameters $parameters {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString $NewString | ConvertFrom-Json
        }

        $result.error | Should -BeNullOrEmpty
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($expectedBytes))
        $result.bytes | Should -Be $expectedBytes.Length
    }

    It 'Refuses an input larger than 8 MiB without reading or changing its content' {
        $filePath = Join-Path $TestDrive 'oversized.txt'
        $stream = [System.IO.File]::Create($filePath)
        try {
            $stream.Write([byte[]]@(0x6f, 0x6c, 0x64), 0, 3)
            $stream.SetLength(8MB + 1)
        } finally {
            $stream.Dispose()
        }
        $originalHash = (Get-FileHash -LiteralPath $filePath).Hash

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match '8 MiB'
        (Get-FileHash -LiteralPath $filePath).Hash | Should -BeExactly $originalHash
    }

    It 'Refuses a replacement that exceeds 8 MiB after <Name> encoding' -ForEach @(
        @{ Name = 'UTF-8'; Encoding = [System.Text.UTF8Encoding]::new($false, $true); Length = 8MB + 1 }
        @{ Name = 'UTF-16 with BOM'; Encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true); Length = 4MB }
        @{ Name = 'UTF-32 with BOM'; Encoding = [System.Text.UTF32Encoding]::new($false, $true, $true); Length = 2MB }
    ) {
        $filePath = Join-Path $TestDrive 'oversized-replacement.txt'
        [System.IO.File]::WriteAllText($filePath, 'old', $Encoding)
        $originalHash = (Get-FileHash -LiteralPath $filePath).Hash

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; Length = $Length } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString ([string]::new('x', $Length)) |
                ConvertFrom-Json
        }

        $result.error | Should -Match '8 MiB'
        (Get-FileHash -LiteralPath $filePath).Hash | Should -BeExactly $originalHash
    }

    It 'Refuses a path that does not resolve to a file' {
        $filePath = Join-Path $TestDrive 'not-a-file.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            $FilePath = Resolve-ShpRealPath -Path $FilePath
            Mock Resolve-ShpRealPath { $FilePath }
            Mock Get-Item { [pscustomobject]@{ FullName = $FilePath } }
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'existing file'
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'old'
    }

    It 'Refuses a device rather than opening it' {
        $filePath = Join-Path $TestDrive 'device-target.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            $deviceItem = [System.IO.FileInfo]::new($FilePath) |
                Add-Member -NotePropertyName Attributes -NotePropertyValue ([System.IO.FileAttributes]::Device) -Force -PassThru
            $deviceItem | Should -BeOfType [System.IO.FileInfo]
            Mock Get-Item { $deviceItem }
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'device'
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'old'
    }

    It 'Refuses a named pipe instead of blocking on it' -Skip:$IsWindows {
        $fifoPath = Join-Path $TestDrive 'pipe-target'
        & mkfifo $fifoPath
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $fifoPath | Should -BeTrue

        $modulePath = (Get-Module -Name $script:moduleName).Path.Replace("'", "''")
        $escapedPath = $fifoPath.Replace("'", "''")
        $probe = @"
            `$ErrorActionPreference = 'Stop'
            `$module = Import-Module -Name '$modulePath' -Force -PassThru
            & `$module {
                Invoke-EditFileTool -Path `$args[0] -OldString 'old' -NewString 'new'
            } '$escapedPath'
"@
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand',
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe)))) {
            $startInfo.ArgumentList.Add($argument)
        }
        $worker = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = $worker.StandardOutput.ReadToEndAsync()
        $stderr = $worker.StandardError.ReadToEndAsync()
        try {
            $worker.WaitForExit(15000) |
                Should -BeTrue -Because 'the type check must run before the file is opened'
            $worker.ExitCode | Should -Be 0 -Because $stderr.GetAwaiter().GetResult()
            ($stdout.GetAwaiter().GetResult() | ConvertFrom-Json).error | Should -Match 'regular file'
        } finally {
            if (-not $worker.HasExited) { $worker.Kill($true) }
            $worker.Dispose()
            [System.IO.File]::Delete($fifoPath)
        }
    }

    It 'Preserves the original and cleans temporary files after a <Phase> failure' -ForEach @(
        @{ Phase = 'staging' }
        @{ Phase = 'replacement' }
    ) {
        $filePath = Join-Path $TestDrive 'failed-edit.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')
        $originalHash = (Get-FileHash -LiteralPath $filePath).Hash

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; Phase = $Phase } {
            $FilePath = Resolve-ShpRealPath -Path $FilePath
            $sourceItem = Get-Item -LiteralPath $FilePath
            $sourceItem | Add-Member -NotePropertyName FailurePhase -NotePropertyValue $Phase
            $sourceItem | Add-Member -MemberType ScriptMethod -Name CopyTo -Force -Value {
                param($Destination, $Overwrite)
                [System.IO.File]::Copy($this.FullName, $Destination, $Overwrite)
                if ($this.FailurePhase -eq 'staging') {
                    [System.IO.File]::WriteAllText($Destination, 'partial')
                    throw [System.IO.IOException]::new('Injected staging failure.')
                }
                $temporaryItem = [System.IO.FileInfo]::new($Destination)
                $temporaryItem | Add-Member -MemberType ScriptMethod -Name Replace -Force -Value {
                    throw [System.IO.IOException]::new('Injected replacement failure.')
                }
                $temporaryItem
            }
            Mock Resolve-ShpRealPath { $FilePath }
            Mock Get-Item { $sourceItem } -ParameterFilter { $LiteralPath -eq $FilePath }

            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match "Injected $Phase failure"
        (Get-FileHash -LiteralPath $filePath).Hash | Should -BeExactly $originalHash
        @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '.shp-edit-*') | Should -BeNullOrEmpty
    }

    It 'Retains recoverable original bytes after native replacement error <ErrorCode>' -ForEach @(
        @{ ErrorCode = 1176 }
        @{ ErrorCode = 1177 }
    ) {
        $filePath = Join-Path $TestDrive 'partial-replacement.txt'
        [System.IO.File]::WriteAllText($filePath, 'original')
        $originalHash = (Get-FileHash -LiteralPath $filePath).Hash

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath; ErrorCode = $ErrorCode } {
            $FilePath = Resolve-ShpRealPath -Path $FilePath
            $sourceItem = Get-Item -LiteralPath $FilePath
            $sourceItem | Add-Member -NotePropertyName NativeErrorCode -NotePropertyValue $ErrorCode
            $sourceItem | Add-Member -MemberType ScriptMethod -Name CopyTo -Force -Value {
                param($Destination, $Overwrite)
                [System.IO.File]::Copy($this.FullName, $Destination, $Overwrite)
                $temporaryItem = [System.IO.FileInfo]::new($Destination)
                $temporaryItem | Add-Member -NotePropertyName NativeErrorCode -NotePropertyValue $this.NativeErrorCode
                $temporaryItem | Add-Member -MemberType ScriptMethod -Name Replace -Force -Value {
                    param($Destination, $Backup)
                    if ($this.NativeErrorCode -eq 1176) {
                        if ([string]::IsNullOrEmpty([string]$Backup)) {
                            [System.IO.File]::Delete($Destination)
                        }
                    } else {
                        $displacedPath = if ([string]::IsNullOrEmpty([string]$Backup)) { "$Destination.displaced" } else { $Backup }
                        [System.IO.File]::Move($Destination, $displacedPath)
                    }
                    throw [System.IO.IOException]::new(('Injected native replacement error {0}.' -f $this.NativeErrorCode))
                }
                $temporaryItem
            }
            Mock Resolve-ShpRealPath { $FilePath }
            Mock Get-Item { $sourceItem } -ParameterFilter { $LiteralPath -eq $FilePath }

            Invoke-EditFileTool -Path $FilePath -OldString 'original' -NewString 'updated' | ConvertFrom-Json
        }

        try {
            $result.error | Should -Match "Injected native replacement error $ErrorCode"
            $recoverablePath = if ([System.IO.File]::Exists($filePath)) { $filePath } else { $result.recoveryPath }
            $recoverablePath | Should -Not -BeNullOrEmpty
            (Get-FileHash -LiteralPath $recoverablePath).Hash | Should -BeExactly $originalHash
            if ($ErrorCode -eq 1177) {
                $result.recoveryPath | Should -Match '\.bak$'
                $result.error | Should -Match 'recoveryPath'
            }
            @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '.shp-edit-*.tmp') | Should -BeNullOrEmpty
        } finally {
            if ($result.recoveryPath) { Remove-Item -LiteralPath $result.recoveryPath -Force }
        }
    }

    It 'Refuses a concurrent change even when its length and modification time match' {
        $filePath = Join-Path $TestDrive 'concurrent.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            $FilePath = Resolve-ShpRealPath -Path $FilePath
            $sourceItem = Get-Item -LiteralPath $FilePath
            $sourceItem | Add-Member -MemberType ScriptMethod -Name CopyTo -Force -Value {
                param($Destination, $Overwrite)
                [System.IO.File]::Copy($this.FullName, $Destination, $Overwrite)
                $otherPath = "$Destination.other"
                [System.IO.File]::WriteAllText($otherPath, 'alt')
                [System.IO.File]::SetLastWriteTimeUtc($otherPath, $this.LastWriteTimeUtc)
                [System.IO.File]::Move($otherPath, $this.FullName, $true)
                [System.IO.FileInfo]::new($Destination)
            }
            Mock Resolve-ShpRealPath { $FilePath }
            Mock Get-Item { $sourceItem } -ParameterFilter { $LiteralPath -eq $FilePath }

            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'changed.*retry'
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'alt'
        @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '.shp-edit-*') | Should -BeNullOrEmpty
    }

    It 'Refuses an edit already in progress on the same resolved path: linked=<LinkedRoot>' -ForEach @(
        @{ LinkedRoot = $false }
        @{ LinkedRoot = $true }
    ) {
        $root = Join-Path $TestDrive 'busy-root'
        $null = New-Item -ItemType Directory -Path $root -Force
        if ($LinkedRoot) {
            $linkPath = Join-Path $TestDrive 'busy-link'
            $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $null = New-Item -ItemType $linkType -Path $linkPath -Target $root
            $root = $linkPath
        }
        $filePath = Join-Path $root 'busy.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')
        $resolvedPath = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Resolve-ShpRealPath -Path $FilePath
        }
        $lockPath = if ($IsWindows) { $resolvedPath.ToUpperInvariant() } else { $resolvedPath }
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            $lockName = 'ShellPilot.EditFile.' + [BitConverter]::ToString(
                $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($lockPath))).Replace('-', '')
        } finally {
            $hasher.Dispose()
        }
        $ready = [System.Threading.ManualResetEventSlim]::new($false)
        $release = [System.Threading.ManualResetEventSlim]::new($false)
        $worker = [powershell]::Create()
        $null = $worker.AddScript({
            param($LockName, $Ready, $Release)
            $mutex = [System.Threading.Mutex]::new($false, $LockName)
            $taken = $false
            try {
                $taken = $mutex.WaitOne(10000)
                if (-not $taken) { throw 'Could not acquire the test edit lock.' }
                $Ready.Set()
                if (-not $Release.Wait(10000)) { throw 'The test did not release the edit lock.' }
            } finally {
                if ($taken) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }.ToString()).AddArgument($lockName).AddArgument($ready).AddArgument($release)
        $workerRun = $worker.BeginInvoke()
        try {
            $ready.Wait(10000) | Should -BeTrue

            $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
                Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
            }

            $result.error | Should -Match 'another edit.*retry'
            [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'old'
        } finally {
            $release.Set()
            $null = $worker.EndInvoke($workerRun)
            $worker.Dispose()
            $ready.Dispose()
            $release.Dispose()
        }
    }

    It 'Preserves a read-only target rather than replacing it' {
        $filePath = Join-Path $TestDrive 'read-only.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')
        $item = Get-Item -LiteralPath $filePath
        $item.IsReadOnly = $true
        try {
            $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
                Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
            }

            $result.error | Should -Not -BeNullOrEmpty
            [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'old'
        } finally {
            $item.IsReadOnly = $false
        }
    }

    It 'Preserves a restricted Windows security descriptor' -Skip:(-not $IsWindows) {
        $filePath = Join-Path $TestDrive 'restricted.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')
        $security = Get-Acl -LiteralPath $filePath
        $security.SetAccessRuleProtection($true, $false)
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $security.SetAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity.User, 'FullControl', 'Allow'))
        } finally {
            $identity.Dispose()
        }
        Set-Acl -LiteralPath $filePath -AclObject $security
        $originalDescriptor = (Get-Acl -LiteralPath $filePath).Sddl

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            $FilePath = Resolve-ShpRealPath -Path $FilePath
            $script:editTemporaryDescriptor = $null
            $sourceItem = Get-Item -LiteralPath $FilePath
            $sourceItem | Add-Member -MemberType ScriptMethod -Name CopyTo -Force -Value {
                param($Destination, $Overwrite)
                [System.IO.File]::Copy($this.FullName, $Destination, $Overwrite)
                $script:editTemporaryDescriptor = (Get-Acl -LiteralPath $Destination).Sddl
                [System.IO.FileInfo]::new($Destination)
            }
            Mock Resolve-ShpRealPath { $FilePath }
            Mock Get-Item { $sourceItem } -ParameterFilter { $LiteralPath -eq $FilePath }
            $editResult = Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
            $editResult | Add-Member -NotePropertyName TemporaryDescriptor -NotePropertyValue $script:editTemporaryDescriptor
            $editResult
        }

        $result.error | Should -BeNullOrEmpty
        $result.TemporaryDescriptor | Should -BeExactly $originalDescriptor
        (Get-Acl -LiteralPath $filePath).Sddl | Should -BeExactly $originalDescriptor
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'new'
        @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '.shp-edit-*') | Should -BeNullOrEmpty
    }

    It 'Preserves Unix file modes' -Skip:($IsWindows -or -not ('System.IO.UnixFileMode' -as [type])) {
        $filePath = Join-Path $TestDrive 'restricted-unix.txt'
        [System.IO.File]::WriteAllText($filePath, 'old')
        $mode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        [System.IO.File]::SetUnixFileMode($filePath, $mode)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -BeNullOrEmpty
        [System.IO.File]::GetUnixFileMode($filePath) | Should -Be $mode
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'new'
    }

    It 'Preserves <Name> line endings in a multiline replacement' -ForEach @(
        @{ Name = 'CRLF'; NewLine = "`r`n" }
        @{ Name = 'LF'; NewLine = "`n" }
        @{ Name = 'CR'; NewLine = "`r" }
    ) {
        $filePath = Join-Path $TestDrive 'multiline.txt'
        $content = "start${NewLine}old${NewLine}text${NewLine}end${NewLine}"
        $expected = "start${NewLine}new${NewLine}text${NewLine}end${NewLine}"
        [System.IO.File]::WriteAllText($filePath, $content)
        $parameters = @{
            FilePath = $filePath
            OldString = "old${NewLine}text"
            NewString = "new${NewLine}text"
        }

        $result = InModuleScope $script:moduleName -Parameters $parameters {
            Invoke-EditFileTool -Path $FilePath -OldString $OldString -NewString $NewString | ConvertFrom-Json
        }

        $result.error | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly $expected
    }

    It 'Refuses an empty oldString without changing the file' {
        $filePath = Join-Path $TestDrive 'empty-search.txt'
        [System.IO.File]::WriteAllText($filePath, 'before')

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString '' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'oldString.*empty'
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'before'
    }

    It 'Refuses unsupported or malformed text rather than changing its encoding: <Name>' -ForEach @(
        @{ Name = 'non-UTF-8 without BOM'; Bytes = [byte[]]@(0x6f, 0x6c, 0x64, 0xe9) }
        @{ Name = 'malformed UTF-8 with BOM'; Bytes = [byte[]]@(0xef, 0xbb, 0xbf, 0x6f, 0x6c, 0x64, 0xff) }
        @{ Name = 'malformed UTF-16'; Bytes = [byte[]]@(0xff, 0xfe, 0x6f, 0, 0x6c, 0, 0x64, 0, 0xff) }
    ) {
        $filePath = Join-Path $TestDrive 'invalid-encoding.txt'
        [System.IO.File]::WriteAllBytes($filePath, $Bytes)

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.error | Should -Match 'encoding'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) |
            Should -BeExactly ([Convert]::ToBase64String($Bytes))
    }

    It 'Returns an error for a missing file without creating its parents' {
        $filePath = Join-Path $TestDrive 'missing/target.txt'

        $result = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Invoke-EditFileTool -Path $FilePath -OldString 'old' -NewString 'new' | ConvertFrom-Json
        }

        $result.path | Should -BeExactly $filePath
        $result.error | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Split-Path -Path $filePath -Parent) | Should -BeFalse
    }

    It 'Resolves a relative literal path against the PowerShell location' {
        $filePath = Join-Path $TestDrive 'relative[1].txt'
        [System.IO.File]::WriteAllText($filePath, 'old')

        $result = InModuleScope $script:moduleName -Parameters @{ Root = $TestDrive } {
            Push-Location -LiteralPath $Root
            try {
                Invoke-EditFileTool -Path './relative[1].txt' -OldString 'old' -NewString 'new' | ConvertFrom-Json
            } finally {
                Pop-Location
            }
        }
        $expectedPath = InModuleScope $script:moduleName -Parameters @{ FilePath = $filePath } {
            Resolve-ShpRealPath -Path $FilePath
        }

        $result.error | Should -BeNullOrEmpty
        $result.path | Should -BeExactly $expectedPath
        [System.IO.File]::ReadAllText($filePath) | Should -BeExactly 'new'
    }
}
