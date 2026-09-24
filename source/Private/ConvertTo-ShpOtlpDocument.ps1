function ConvertTo-ShpOtlpDocument {
    <#
    .SYNOPSIS
        Renders translated spans as the OTLP/JSON resourceSpans document a
        collector accepts.

    .DESCRIPTION
        Private helper behind ConvertTo-ShpOtelTrace -Format Otlp. It performs
        the shape change only: times become nanosecond STRINGS (the OTLP/JSON
        encoding for a 64-bit value, which JSON numbers cannot carry safely),
        attributes become typed key/value pairs, span kinds and status codes
        become their protocol integers, and the whole thing is wrapped in one
        resource and one instrumentation scope.

        Nothing is decided here. Which spans exist, what they are named and
        which attributes they carry is the mapping's business; this function
        only re-expresses what it is handed, which is why the mapping version
        travels through as the scope version rather than being re-derived.

    .PARAMETER Span
        The translated spans, as produced by ConvertTo-ShpOtelTrace.

    .PARAMETER ServiceName
        The service.name resource attribute.

    .PARAMETER MappingVersion
        The mapping version, reported as the instrumentation scope version.

    .EXAMPLE
        ConvertTo-ShpOtlpDocument -Span $spans -ServiceName 'ci-agent' -MappingVersion '0.1'

        Returns a resourceSpans document ready to serialise and post.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        An object with a resourceSpans member.

    .LINK
        ConvertTo-ShpOtelTrace
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Span = @(),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MappingVersion
    )

    $kindCode = @{ 'Unspecified' = 0; 'Internal' = 1; 'Server' = 2; 'Client' = 3; 'Producer' = 4; 'Consumer' = 5 }
    $statusCode = @{ 'Unset' = 0; 'Ok' = 1; 'Error' = 2 }

    $toAnyValue = {
        param($Value)
        if ($Value -is [bool]) { return [pscustomobject]@{ boolValue = $Value } }
        if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return [pscustomobject]@{ doubleValue = [double]$Value } }
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return [pscustomobject]@{ intValue = [string][long]$Value } }
        [pscustomobject]@{ stringValue = [string]$Value }
    }
    $toAttributes = {
        param($Table)
        @(
            foreach ($key in $Table.Keys) {
                [pscustomobject]@{ key = [string]$key; value = (& $toAnyValue $Table[$key]) }
            }
        )
    }

    $rendered = @(
        foreach ($item in $Span) {
            [pscustomobject]@{
                traceId           = $item.TraceId
                spanId            = $item.SpanId
                parentSpanId      = $item.ParentSpanId
                name              = $item.Name
                kind              = $kindCode[[string]$item.Kind]
                startTimeUnixNano = [string][long]$item.StartTimeUnixNano
                endTimeUnixNano   = [string][long]$item.EndTimeUnixNano
                attributes        = (& $toAttributes $item.Attributes)
                status            = [pscustomobject]@{ code = $statusCode[[string]$item.StatusCode]; message = [string]$item.StatusMessage }
                events            = @(
                    foreach ($spanEvent in $item.Events) {
                        [pscustomobject]@{
                            name         = $spanEvent.Name
                            timeUnixNano = [string][long]$spanEvent.TimeUnixNano
                            attributes   = (& $toAttributes $spanEvent.Attributes)
                        }
                    }
                )
            }
        }
    )

    [pscustomobject]@{
        resourceSpans = @(
            [pscustomobject]@{
                resource   = [pscustomobject]@{
                    attributes = @(
                        [pscustomobject]@{ key = 'service.name'; value = [pscustomobject]@{ stringValue = $ServiceName } }
                        [pscustomobject]@{ key = 'telemetry.sdk.name'; value = [pscustomobject]@{ stringValue = $script:ShpOtelScopeName } }
                        [pscustomobject]@{ key = 'telemetry.sdk.language'; value = [pscustomobject]@{ stringValue = 'powershell' } }
                    )
                }
                scopeSpans = @(
                    [pscustomobject]@{
                        scope = [pscustomobject]@{ name = $script:ShpOtelScopeName; version = $MappingVersion }
                        spans = $rendered
                    }
                )
            }
        )
    }
}
