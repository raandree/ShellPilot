function ConvertTo-ShpHexPreview {
    <#
    .SYNOPSIS
        Renders bytes as a classic offset/hex/ASCII dump.

    .DESCRIPTION
        Private helper backing Invoke-Shp -Attachment. Formats the head of a
        binary file the way hexdump -C does, because that layout is what lets a
        model recognise a format: the magic number is legible in the hex column
        and any embedded strings are legible in the ASCII column.

        This is deliberately the only part of a binary attachment that reaches
        the model. A few hundred bytes carry the signature and cost almost
        nothing, while the file itself stays on disk for the model to decode
        with the file and terminal tools.

    .PARAMETER Byte
        The bytes to render. Pass only the head of the file; this renders every
        byte it is given.

    .EXAMPLE
        ConvertTo-ShpHexPreview -Byte $bytes

        Renders lines such as
        00000000  d0 cf 11 e0 a1 b1 1a e1  00 00 00 00 00 00 00 00  |................|

    .OUTPUTS
        System.String

        The dump, one 16-byte row per line, separated by newlines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Byte
    )

    $lines = New-Object System.Collections.Generic.List[string]
    for ($offset = 0; $offset -lt $Byte.Count; $offset += 16) {
        $row = $Byte[$offset..([Math]::Min($offset + 15, $Byte.Count - 1))]
        $hex = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 16; $i++) {
            # The gap after the eighth byte is part of the canonical layout.
            if ($i -eq 8) { $null = $hex.Append(' ') }
            if ($i -lt $row.Count) { $null = $hex.AppendFormat('{0:x2} ', $row[$i]) } else { $null = $hex.Append('   ') }
        }
        $ascii = -join ($row | ForEach-Object { if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' } })
        # No trimming: the padding for a short final row is what keeps the ASCII
        # column aligned, and the doubled space before it is canonical.
        $null = $lines.Add(('{0:x8}  {1} |{2}|' -f $offset, $hex.ToString(), $ascii))
    }
    $lines -join "`n"
}
