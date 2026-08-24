function Get-ShpFileFormat {
    <#
    .SYNOPSIS
        Identifies a file's format from its leading bytes.

    .DESCRIPTION
        Private helper backing Invoke-Shp -Attachment. Matches the head of a
        file against a magic-number table and reports what it is, so an
        attachment can be routed (image, text, or binary) and so the model is
        told which format it is looking at rather than having to infer it from
        an extension that may be wrong or absent.

        Content decides, not the extension. A file that matches no signature is
        classified by inspection: NUL bytes mean binary, and anything that
        decodes cleanly as UTF-8 (or carries a Unicode byte-order mark) is text.
        That catches both directions of the usual mislabelling - a .log that is
        really gzip, and an extensionless config file that is really text.

        The container formats are reported as containers. A .docx and a .jar are
        both Zip archives, and saying so - rather than guessing at the payload -
        is what lets the model decide how to open it.

    .PARAMETER Byte
        The leading bytes of the file. A few hundred are enough; the longest
        signature this matches is 8 bytes and the text heuristic reads the rest.

    .PARAMETER Extension
        The file extension including the dot, used only to narrow a container
        signature (a Zip that is really a .docx) and never to override content.

    .EXAMPLE
        Get-ShpFileFormat -Byte $bytes -Extension '.msg'

        Reports the OLE2 compound-file format for a .msg, with Kind 'Binary'.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with Kind ('Image', 'Text' or 'Binary'), Format (a human
        description), Mime (for an image, otherwise $null) and Encoding (for
        text, otherwise $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Byte,

        [string]$Extension
    )

    $ext = if ($Extension) { $Extension.ToLowerInvariant() } else { '' }

    function Test-Magic {
        param([byte[]]$Buffer, [int]$Offset, [int[]]$Signature)
        if ($Buffer.Count -lt ($Offset + $Signature.Count)) { return $false }
        for ($i = 0; $i -lt $Signature.Count; $i++) {
            if ($Buffer[$Offset + $i] -ne $Signature[$i]) { return $false }
        }
        $true
    }

    $image = @(
        @{ Sig = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A); Format = 'PNG image'; Mime = 'image/png' }
        @{ Sig = @(0xFF, 0xD8, 0xFF);                               Format = 'JPEG image'; Mime = 'image/jpeg' }
        @{ Sig = @(0x47, 0x49, 0x46, 0x38);                         Format = 'GIF image'; Mime = 'image/gif' }
        @{ Sig = @(0x42, 0x4D);                                     Format = 'BMP image'; Mime = 'image/bmp' }
    )
    foreach ($m in $image) {
        if (Test-Magic -Buffer $Byte -Offset 0 -Signature $m.Sig) {
            return [pscustomobject]@{ Kind = 'Image'; Format = $m.Format; Mime = $m.Mime; Encoding = $null }
        }
    }
    # WebP is a RIFF container: the form type at offset 8 is what distinguishes
    # it from a RIFF wave or video.
    if ((Test-Magic -Buffer $Byte -Offset 0 -Signature @(0x52, 0x49, 0x46, 0x46)) -and
        (Test-Magic -Buffer $Byte -Offset 8 -Signature @(0x57, 0x45, 0x42, 0x50))) {
        return [pscustomobject]@{ Kind = 'Image'; Format = 'WebP image'; Mime = 'image/webp'; Encoding = $null }
    }

    $zipPayload = @{
        '.docx' = 'Word document (OOXML, Zip container)'
        '.xlsx' = 'Excel workbook (OOXML, Zip container)'
        '.pptx' = 'PowerPoint presentation (OOXML, Zip container)'
        '.odt'  = 'OpenDocument text (Zip container)'
        '.ods'  = 'OpenDocument spreadsheet (Zip container)'
        '.jar'  = 'Java archive (Zip container)'
        '.nupkg' = 'NuGet package (Zip container)'
    }
    $binary = @(
        @{ Sig = @(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1); Format = 'OLE2 compound file (CFBF) - the container behind .msg, .doc, .xls, .ppt and .msi' }
        @{ Sig = @(0x25, 0x50, 0x44, 0x46);                         Format = 'PDF document' }
        @{ Sig = @(0x50, 0x4B, 0x03, 0x04);                         Format = 'Zip container' }
        @{ Sig = @(0x50, 0x4B, 0x05, 0x06);                         Format = 'Zip container (empty)' }
        @{ Sig = @(0x1F, 0x8B);                                     Format = 'gzip stream' }
        @{ Sig = @(0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C);             Format = '7-Zip archive' }
        @{ Sig = @(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07);             Format = 'RAR archive' }
        @{ Sig = @(0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66); Format = 'SQLite database' }
        @{ Sig = @(0x4D, 0x5A);                                     Format = 'Windows executable (PE/MZ)' }
        @{ Sig = @(0x7F, 0x45, 0x4C, 0x46);                         Format = 'ELF executable' }
        @{ Sig = @(0x49, 0x44, 0x33);                               Format = 'MP3 audio (ID3)' }
        @{ Sig = @(0x4F, 0x67, 0x67, 0x53);                         Format = 'Ogg container' }
    )
    foreach ($m in $binary) {
        if (Test-Magic -Buffer $Byte -Offset 0 -Signature $m.Sig) {
            $format = $m.Format
            if ($format -like 'Zip container*' -and $zipPayload.ContainsKey($ext)) { $format = $zipPayload[$ext] }
            return [pscustomobject]@{ Kind = 'Binary'; Format = $format; Mime = $null; Encoding = $null }
        }
    }
    # ISO base media (MP4 and friends) carries its brand at offset 4, not 0.
    if (Test-Magic -Buffer $Byte -Offset 4 -Signature @(0x66, 0x74, 0x79, 0x70)) {
        return [pscustomobject]@{ Kind = 'Binary'; Format = 'ISO base media container (MP4/MOV)'; Mime = $null; Encoding = $null }
    }

    # A byte-order mark settles both the kind and the encoding.
    $boms = @(
        @{ Sig = @(0xEF, 0xBB, 0xBF);       Encoding = 'UTF-8 (BOM)' }
        @{ Sig = @(0xFF, 0xFE, 0x00, 0x00); Encoding = 'UTF-32 LE' }
        @{ Sig = @(0x00, 0x00, 0xFE, 0xFF); Encoding = 'UTF-32 BE' }
        @{ Sig = @(0xFF, 0xFE);             Encoding = 'UTF-16 LE' }
        @{ Sig = @(0xFE, 0xFF);             Encoding = 'UTF-16 BE' }
    )
    foreach ($b in $boms) {
        if (Test-Magic -Buffer $Byte -Offset 0 -Signature $b.Sig) {
            return [pscustomobject]@{ Kind = 'Text'; Format = "Text ($($b.Encoding))"; Mime = $null; Encoding = $b.Encoding }
        }
    }

    if ($Byte.Count -eq 0) {
        return [pscustomobject]@{ Kind = 'Text'; Format = 'Empty file'; Mime = $null; Encoding = 'UTF-8' }
    }
    # No signature: a NUL byte is the classic binary tell, because no text
    # encoding without a BOM produces one.
    if ($Byte -contains 0) {
        return [pscustomobject]@{ Kind = 'Binary'; Format = 'Unrecognised binary'; Mime = $null; Encoding = $null }
    }
    # Strict UTF-8 rejects malformed sequences instead of substituting U+FFFD,
    # which is what makes this a test rather than a guess.
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $null = $strictUtf8.GetString($Byte)
        return [pscustomobject]@{ Kind = 'Text'; Format = 'Text (UTF-8)'; Mime = $null; Encoding = 'UTF-8' }
    } catch {
        # A truncated multi-byte sequence at the end of the sampled window is not
        # evidence of binary, so fall back to single-byte text rather than
        # declaring a Latin-1 file unreadable.
        return [pscustomobject]@{ Kind = 'Text'; Format = 'Text (single-byte, not valid UTF-8)'; Mime = $null; Encoding = 'Latin-1' }
    }
}
