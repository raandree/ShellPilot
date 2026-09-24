function New-ShpContextReport {
    <#
    .SYNOPSIS
        Assembles a Context report from pre-named contributions, applying one
        estimator to all of them.

    .DESCRIPTION
        Private helper shared by Get-ShpContextReport and Invoke-Shp
        -ContextReport. It owns three things a per-caller implementation would
        get subtly wrong:

        - The canonical source order and the canonical source names. A report
          whose rows differ between two callers cannot be compared, and
          comparing two reports is the whole point of having one.
        - The single estimator. Every Known row is measured by
          ConvertTo-ShpTokenCount and the total is the sum of those rows, so
          the total and the breakdown cannot disagree. That is stated on the
          report as Estimator rather than left to be inferred.
        - The honest unknown. A contribution this module cannot size locally -
          an image, a Skill body nobody loaded - is reported with a null count
          and a reason, never as zero. Zero is a measurement; null is an
          admission, and a caller sizing a budget needs to tell them apart.

        Provider-side overhead (per-message framing, the tokenizer's own
        disagreement with this heuristic) is NOT modelled. The estimate is a
        guide; the service's reported usage stays authoritative.

    .PARAMETER Source
        One record per contribution: Name (a canonical source name), optionally
        Text (string or string array), Tokens/Chars for a pre-measured
        contribution, ItemCount, Known and Detail.

    .PARAMETER ContextBudget
        The resolved Context budget in estimated tokens; 0 means the guard is
        disabled and no remaining figure is reported.

    .PARAMETER ContextBudgetSource
        Where that budget came from.

    .PARAMETER Model
        The model the report was sized for, for display.

    .PARAMETER DeferredToolLoading
        Whether eligible dynamic schemas were withheld for this composition.

    .PARAMETER DeferredToolCount
        How many Tool schemas were withheld.

    .PARAMETER DeferredToolSchemaTokens
        What those withheld schemas would have cost.

    .EXAMPLE
        New-ShpContextReport -Source @(@{ Name = 'Prompt'; Text = 'hello' })

        Returns a report whose Prompt row carries the estimate and whose other
        rows are present and empty.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.ContextReport.

    .LINK
        Get-ShpContextReport
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpContextReport measures supplied text and returns a report; it changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary[]]$Source,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$ContextBudget,

        [AllowEmptyString()]
        [string]$ContextBudgetSource = 'Unknown',

        [AllowEmptyString()]
        [string]$Model = '',

        [switch]$DeferredToolLoading,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$DeferredToolCount,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$DeferredToolSchemaTokens
    )

    $supplied = @{}
    foreach ($record in $Source) {
        $name = [string]$record['Name']
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Every Context report source must carry a Name.' }
        if ($name -notin $script:ShpContextSourceOrder) {
            throw ("'{0}' is not a Context report source. The accounted sources are: {1}." -f $name, ($script:ShpContextSourceOrder -join ', '))
        }
        $supplied[$name] = $record
    }

    $rows = [System.Collections.Generic.List[pscustomobject]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $total = 0
    foreach ($name in $script:ShpContextSourceOrder) {
        $record = $supplied[$name]
        $known = $true
        $detail = ''
        $itemCount = 0
        $chars = 0
        $tokens = 0

        if ($null -ne $record) {
            if ($record.Contains('Known')) { $known = [bool]$record['Known'] }
            if ($record.Contains('Detail')) { $detail = [string]$record['Detail'] }
            if ($record.Contains('ItemCount')) { $itemCount = [int]$record['ItemCount'] }
            if ($record.Contains('Text')) {
                foreach ($text in @($record['Text'])) {
                    if ([string]::IsNullOrEmpty($text)) { continue }
                    $chars += ([string]$text).Length
                    $tokens += ConvertTo-ShpTokenCount -Text ([string]$text)
                }
            }
            if ($record.Contains('Chars')) { $chars = [int]$record['Chars'] }
            if ($record.Contains('Tokens')) { $tokens = [int]$record['Tokens'] }
        }

        if ($known) {
            $total += $tokens
        } else {
            $null = $unknown.Add($name)
        }

        $null = $rows.Add([pscustomobject]@{
            PSTypeName      = 'ShellPilot.ContextSource'
            Name            = $name
            EstimatedTokens = $(if ($known) { $tokens } else { $null })
            Chars           = $(if ($known) { $chars } else { $null })
            ItemCount       = $itemCount
            Known           = $known
            Detail          = $detail
        })
    }

    # A budget of 0 means the guard is off, not that nothing is left. Reporting
    # a remaining figure against a disabled guard would invent a limit.
    $remaining = $null
    $fits = $null
    if ($ContextBudget -gt 0) {
        $remaining = $ContextBudget - $total
        $fits = $total -le $ContextBudget
    }

    [pscustomobject]@{
        PSTypeName               = 'ShellPilot.ContextReport'
        Estimator                = 'ConvertTo-ShpTokenCount'
        Model                    = $Model
        EstimatedTokens          = $total
        Sources                  = $rows.ToArray()
        Unknown                  = $unknown.ToArray()
        ContextBudget            = $ContextBudget
        ContextBudgetSource      = $ContextBudgetSource
        RemainingTokens          = $remaining
        FitsBudget               = $fits
        DeferredToolLoading      = [bool]$DeferredToolLoading
        DeferredToolCount        = $DeferredToolCount
        DeferredToolSchemaTokens = $DeferredToolSchemaTokens
    }
}
