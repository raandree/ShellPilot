function Invoke-EditFileTool {
    <#
    .SYNOPSIS
        Replaces one exact string in a local file and returns a JSON status.

    .DESCRIPTION
        Private helper backing the edit_file tool. Replaces OldString only
        when exactly one case-sensitive, ordinal match exists, including
        overlapping matches when counting ambiguity. Matching is literal:
        regular expressions, Unicode normalization and newline conversion are
        not applied. An empty NewString deletes the matching text.

        Preserves the existing BOM, encoding and all text outside the match.
        Supports strict UTF-8 without a BOM and BOM-marked UTF-8, UTF-16 and
        UTF-32 in either byte order. Refuses invalid or unsupported encodings
        instead of guessing and corrupting the file. No parent directories or
        missing files are created. The Invoke-Shp dispatcher applies the tool
        policy and ShouldProcess before calling this helper.

        Only regular, seekable files are supported. Input and output are each
        limited to $script:ShpEditFileMaxBytes including the BOM. The bound
        cannot be raised by model arguments. Oversized files and replacements
        are refused before writing.

        Serializes edits to the same resolved path with a named mutex. Writes
        and flushes a same-directory temporary copy, verifies the target's
        content has not changed, then atomically replaces it. Copying retains
        file attributes and Unix modes; replacement retains Windows security
        metadata. A detected conflict is refused, not overwritten. Other
        programs must coordinate their own renames: the final check and rename
        are not a filesystem compare-and-swap operation.

        Replacement requests a same-directory backup of the original. If a
        native replacement failure moves the original away, the error names
        recoveryPath and retains that backup for manual recovery. Cleanup is
        best effort; it never deletes a reported recovery file.

    .PARAMETER Path
        Literal file path, absolute or relative to the PowerShell location. The
        returned path is the resolved one, so a link reports its target.

    .PARAMETER OldString
        Nonempty text to replace. Supply the exact case and line endings from
        the file, with enough surrounding text to identify one occurrence.

    .PARAMETER NewString
        Replacement text. An explicitly empty string deletes OldString.

    .EXAMPLE
        Invoke-EditFileTool -Path ./settings.txt -OldString 'count=1' -NewString 'count=2'

        Replaces the single count setting, preserving the file encoding and
        line endings, and returns its path, byte count and replacement count.

    .OUTPUTS
        System.String

        A compact JSON envelope with path, bytes and replacements, or error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$OldString,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewString
    )

    $readStream = $null
    $temporaryPath = $null
    $backupPath = $null
    $recoveryPath = $null
    $replacementComplete = $false
    $editLock = $null
    $lockTaken = $false
    $hasher = $null
    try {
        if ([string]::IsNullOrEmpty($OldString)) {
            throw 'oldString must not be empty. Supply exact text from the file that occurs once.'
        }

        $maxBytes = $script:ShpEditFileMaxBytes
        $maxDisplay = '{0:N0} MiB' -f ($maxBytes / 1MB)
        # Cheap pre-filter in characters; the authoritative byte check runs after encoding.
        if ($OldString.Length -gt $maxBytes -or $NewString.Length -gt $maxBytes) {
            throw ('edit_file is limited to {0}. Supply a smaller replacement or edit a smaller file with another tool.' -f $maxDisplay)
        }

        $resolvedPath = Resolve-ShpRealPath -Path $Path
        $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
        if ($item -isnot [System.IO.FileInfo]) {
            throw 'Path must identify an existing file. Use list_directory to locate the file to edit.'
        }
        if ($item.Attributes.HasFlag([System.IO.FileAttributes]::Device)) {
            throw 'Path must identify a regular file, not a device. Choose a regular file to edit.'
        }
        if (-not $IsWindows -and [string]$item.UnixStat.ItemType -ne 'File') {
            throw 'Path must identify a regular file, not a directory, socket or pipe. Choose a regular file to edit.'
        }

        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $lockPath = if ($IsWindows) { $item.FullName.ToUpperInvariant() } else { $item.FullName }
        $lockName = 'ShellPilot.EditFile.' + [BitConverter]::ToString(
            $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($lockPath))).Replace('-', '')
        $editLock = [System.Threading.Mutex]::new($false, $lockName)
        try {
            $lockTaken = $editLock.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) { throw 'Another edit is in progress for this file. Read the current file and retry.' }
        $item.Refresh()
        if ($item.IsReadOnly) { throw 'The file is read-only. Choose a writable file or ask the user to change its access.' }

        $fileShare = [System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete
        $readStream = [System.IO.File]::Open($item.FullName, 'Open', 'Read', $fileShare)
        if (-not $readStream.CanSeek) {
            throw 'Path must identify a seekable regular file. Devices and pipes cannot be edited.'
        }
        if ($readStream.Length -gt $maxBytes) {
            throw ('The file exceeds the {0} edit_file limit. Edit a smaller file with another tool; no bytes were written.' -f $maxDisplay)
        }
        $fileBytes = [byte[]]::new($readStream.Length)
        $readOffset = 0
        while ($readOffset -lt $fileBytes.Length) {
            $bytesRead = $readStream.Read($fileBytes, $readOffset, $fileBytes.Length - $readOffset)
            if ($bytesRead -eq 0) { throw 'The file changed while being read. Read the current file and retry the edit.' }
            $readOffset += $bytesRead
        }
        if ($readStream.ReadByte() -ne -1) {
            throw 'The file changed while being read. Read the current file and retry the edit.'
        }
        $readStream.Dispose()
        $readStream = $null

        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $preambleLength = 0
        $bomEncodings = @(
            [System.Text.UTF32Encoding]::new($false, $true, $true)
            [System.Text.UTF32Encoding]::new($true, $true, $true)
            [System.Text.UTF8Encoding]::new($true, $true)
            [System.Text.UnicodeEncoding]::new($false, $true, $true)
            [System.Text.UnicodeEncoding]::new($true, $true, $true)
        )
        foreach ($candidate in $bomEncodings) {
            $preamble = $candidate.GetPreamble()
            if ($fileBytes.Length -lt $preamble.Length) { continue }
            $matchesPreamble = $true
            for ($byteIndex = 0; $byteIndex -lt $preamble.Length; $byteIndex++) {
                if ($fileBytes[$byteIndex] -ne $preamble[$byteIndex]) {
                    $matchesPreamble = $false
                    break
                }
            }
            if ($matchesPreamble) {
                $encoding = $candidate
                $preambleLength = $preamble.Length
                break
            }
        }

        try {
            $text = $encoding.GetString($fileBytes, $preambleLength, $fileBytes.Length - $preambleLength)
        } catch {
            throw 'Unsupported or invalid file encoding. Use UTF-8 or BOM-marked UTF-16/UTF-32 text; no bytes were written.'
        }

        $matchIndex = $text.IndexOf($OldString, [System.StringComparison]::Ordinal)
        if ($matchIndex -lt 0) {
            throw 'oldString has 0 matches. Read the current file with read_file and supply exact text, including case and line endings (CRLF is \r\n, not \n). No bytes were written.'
        }

        $matchCount = 1
        $searchIndex = $matchIndex
        while (($searchIndex = $text.IndexOf($OldString, $searchIndex + 1, [System.StringComparison]::Ordinal)) -ge 0) {
            $matchCount++
        }
        if ($matchCount -gt 1) {
            throw ('oldString has {0} matches. Include more surrounding text so exactly one occurrence matches. No bytes were written.' -f $matchCount)
        }

        if ([long]$text.Length - $OldString.Length + $NewString.Length -gt $maxBytes) {
            throw ('The edited file would exceed the {0} edit_file limit. Supply a smaller replacement; no bytes were written.' -f $maxDisplay)
        }
        $updatedText = $text.Remove($matchIndex, $OldString.Length).Insert($matchIndex, $NewString)
        if ([long]$encoding.GetByteCount($updatedText) + $preambleLength -gt $maxBytes) {
            throw ('The edited file would exceed the {0} edit_file limit. Supply a smaller replacement; no bytes were written.' -f $maxDisplay)
        }
        $contentBytes = $encoding.GetBytes($updatedText)
        $updatedBytes = [byte[]]::new($preambleLength + $contentBytes.Length)
        [System.Array]::Copy($fileBytes, 0, $updatedBytes, 0, $preambleLength)
        [System.Array]::Copy($contentBytes, 0, $updatedBytes, $preambleLength, $contentBytes.Length)
        $originalHash = [Convert]::ToBase64String($hasher.ComputeHash($fileBytes))
        $temporaryPath = Join-Path -Path $item.DirectoryName -ChildPath ('.shp-edit-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        if ($IsWindows) {
            $temporarySecurity = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
            $secureStream = [System.IO.FileSystemAclExtensions]::Create(
                [System.IO.FileInfo]::new($temporaryPath), [System.IO.FileMode]::CreateNew,
                [System.Security.AccessControl.FileSystemRights]::Write, [System.IO.FileShare]::None,
                4096, [System.IO.FileOptions]::None, $temporarySecurity)
            $secureStream.Dispose()
            Set-Acl -LiteralPath $temporaryPath -AclObject $temporarySecurity -ErrorAction Stop
        }
        $temporaryItem = $item.CopyTo($temporaryPath, $IsWindows)
        $writeStream = [System.IO.File]::Open($temporaryPath, 'Truncate', 'Write', 'None')
        try {
            $writeStream.Write($updatedBytes, 0, $updatedBytes.Length)
            $writeStream.Flush($true)
        } finally {
            $writeStream.Dispose()
        }

        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $currentPath = Resolve-ShpRealPath -Path $Path
        if (-not [string]::Equals($item.FullName, $currentPath, $comparison)) {
            throw 'The file path changed during the edit. Read the current file and retry; no edit was committed.'
        }
        $currentItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if ($currentItem -isnot [System.IO.FileInfo] -or
            $currentItem.Attributes.HasFlag([System.IO.FileAttributes]::Device) -or
            (-not $IsWindows -and -not ([string]$currentItem.UnixMode).StartsWith('-'))) {
            throw 'The file type changed during the edit. Read the current file and retry; no edit was committed.'
        }
        $currentStream = [System.IO.File]::Open($currentPath, 'Open', 'Read', $fileShare)
        try {
            if (-not $currentStream.CanSeek -or $currentStream.Length -ne $fileBytes.Length) {
                throw 'The file changed during the edit. Read the current file and retry; no edit was committed.'
            }
            $hasher.Initialize()
            $buffer = [byte[]]::new(64KB)
            $remaining = $fileBytes.Length
            while ($remaining -gt 0) {
                $bytesRead = $currentStream.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
                if ($bytesRead -eq 0) { throw 'The file changed during the edit. Read the current file and retry.' }
                $null = $hasher.TransformBlock($buffer, 0, $bytesRead, $null, 0)
                $remaining -= $bytesRead
            }
            $null = $hasher.TransformFinalBlock([byte[]]::new(0), 0, 0)
            if ($currentStream.ReadByte() -ne -1 -or [Convert]::ToBase64String($hasher.Hash) -cne $originalHash) {
                throw 'The file changed during the edit. Read the current file and retry; no edit was committed.'
            }
        } finally {
            $currentStream.Dispose()
        }
        $backupPath = [System.IO.Path]::ChangeExtension($temporaryPath, '.bak')
        try {
            $null = $temporaryItem.Replace($currentPath, $backupPath, $false)
            $replacementComplete = $true
        } catch {
            $replacementError = $_
            if ([System.IO.File]::Exists($backupPath)) {
                $recoveryPath = $backupPath
            } elseif (-not [System.IO.File]::Exists($currentPath) -and [System.IO.File]::Exists($temporaryPath)) {
                $recoveryPath = $temporaryPath
            }
            throw $replacementError
        }

        return ([pscustomobject]@{
            path = $item.FullName
            bytes = $updatedBytes.Length
            replacements = 1
        } | ConvertTo-Json -Compress)
    } catch {
        $errorRecord = $_
        $failure = @{ path = $Path; error = $errorRecord.Exception.Message }
        if ($recoveryPath) {
            $failure.recoveryPath = $recoveryPath
            $failure.error += ' A recovery file was retained at recoveryPath. Ask the user to inspect it before retrying.'
        }
        return ($failure | ConvertTo-Json -Compress)
    } finally {
        if ($readStream) { $readStream.Dispose() }
        $cleanupPaths = @($temporaryPath)
        if ($replacementComplete) { $cleanupPaths += $backupPath }
        foreach ($cleanupPath in $cleanupPaths) {
            if (-not $cleanupPath -or $cleanupPath -eq $recoveryPath -or -not [System.IO.File]::Exists($cleanupPath)) { continue }
            try {
                [System.IO.File]::Delete($cleanupPath)
            } catch {
                $cleanupError = $_
                Write-Warning ("Could not remove edit temporary file '{0}': {1}" -f $cleanupPath, $cleanupError.Exception.Message)
            }
        }
        if ($lockTaken) { $editLock.ReleaseMutex() }
        if ($editLock) { $editLock.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }
}
