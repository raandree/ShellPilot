function ConvertTo-ShpTokenCount {
    <#
    .SYNOPSIS
        Estimates the number of model tokens in a piece of text.

    .DESCRIPTION
        Returns an approximate token count for the supplied text using a pure
        PowerShell heuristic, so a caller can size a prompt - and, with
        Get-ShpCostEstimate, its likely cost - before sending it. No exact
        tokenizer is used (that would need a compiled dependency, which this
        module avoids); the estimate blends a character-per-token ratio with a
        word count and is deliberately conservative. Treat the result as a
        guide, not an exact figure: the service's reported usage is
        authoritative. Accepts text from the pipeline.

    .PARAMETER Text
        The text to estimate. Accepts one or more strings (each is estimated
        and the counts are summed). Mandatory.

    .EXAMPLE
        ConvertTo-ShpTokenCount -Text 'Summarise PowerShell splatting in two lines.'

        Returns an approximate token count for the prompt.

    .EXAMPLE
        Get-Content .\prompt.txt -Raw | ConvertTo-ShpTokenCount

        Estimates the token count of a prompt held in a file.

    .OUTPUTS
        System.Int32

        The estimated token count.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$Text
    )

    begin { $total = 0 }
    process {
        foreach ($t in $Text) {
            if ([string]::IsNullOrEmpty($t)) { continue }
            # Blend two cheap signals: ~4 characters per token (the common
            # rule of thumb for English) and ~1.3 tokens per whitespace word
            # (punctuation and sub-word splits push the count above the word
            # count). Take the larger so the estimate rarely undershoots.
            $charEstimate = [Math]::Ceiling($t.Length / 4.0)
            $words = ($t -split '\s+' | Where-Object { $_ }).Count
            $wordEstimate = [Math]::Ceiling($words * 1.3)
            $total += [int][Math]::Max($charEstimate, $wordEstimate)
        }
    }
    end { $total }
}
