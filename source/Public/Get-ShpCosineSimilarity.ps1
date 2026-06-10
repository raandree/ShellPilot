function Get-ShpCosineSimilarity {
    <#
    .SYNOPSIS
        Computes the cosine similarity between two embedding vectors.

    .DESCRIPTION
        Returns the cosine similarity (a value from -1 to 1, where 1 means
        identical direction) between a reference vector and a candidate vector,
        using pure PowerShell so no compiled dependency is needed. Pair it with
        Request-ShpEmbedding to rank texts by semantic similarity for search or
        retrieval; to score many candidates, pipe them through ForEach-Object.
        The two vectors must have the same length; a zero-magnitude vector
        yields a score of 0.

    .PARAMETER Reference
        The reference embedding vector to compare against. Mandatory.

    .PARAMETER Candidate
        The candidate embedding vector to score. Mandatory.

    .EXAMPLE
        Get-ShpCosineSimilarity -Reference $a -Candidate $b

        Returns the cosine similarity between vectors $a and $b.

    .EXAMPLE
        $docs | ForEach-Object { Get-ShpCosineSimilarity -Reference $query -Candidate $_.Embedding }

        Scores each document embedding against the query vector.

    .OUTPUTS
        System.Double

        The cosine similarity score.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [double[]]$Reference,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [double[]]$Candidate
    )

    if ($Candidate.Length -ne $Reference.Length) {
        throw "Vector length mismatch: reference has $($Reference.Length) elements, candidate has $($Candidate.Length)."
    }

    $dot = 0.0
    $refNorm = 0.0
    $candNorm = 0.0
    for ($i = 0; $i -lt $Reference.Length; $i++) {
        $dot += $Reference[$i] * $Candidate[$i]
        $refNorm += $Reference[$i] * $Reference[$i]
        $candNorm += $Candidate[$i] * $Candidate[$i]
    }
    $refNorm = [Math]::Sqrt($refNorm)
    $candNorm = [Math]::Sqrt($candNorm)

    if ($refNorm -eq 0 -or $candNorm -eq 0) { 0.0 } else { [double]($dot / ($refNorm * $candNorm)) }
}
