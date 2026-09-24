function Test-ShpJsonSchema {
    <#
    .SYNOPSIS
        Validates a parsed JSON value against a bounded subset of JSON Schema,
        locally and without a dependency.

    .DESCRIPTION
        Private helper behind the module's output contracts. It exists because
        "the reply parsed as JSON" and "the reply matches the schema that was
        requested" are different claims, and only the second one is what a
        caller asked for when they supplied -JsonSchema or when an MCP server
        declared an outputSchema.

        It is deliberately a SUBSET, and it says so. The keywords it evaluates
        are: type (single or list, including null), const, enum, required,
        properties, additionalProperties, items, minimum, maximum,
        exclusiveMinimum, exclusiveMaximum, multipleOf, minLength, maxLength,
        pattern, minItems, maxItems and uniqueItems. Anything outside that list
        is ignored where it is merely descriptive - title, description,
        examples, default, $schema, $id, $comment, format - and REPORTED as
        unsupported where it changes the meaning of the schema: $ref, $defs,
        definitions, allOf, anyOf, oneOf, not, if/then/else,
        patternProperties, propertyNames, dependentSchemas, contains and
        unevaluatedProperties.

        That distinction is the whole point. A validator that silently skipped a
        composition keyword would answer "valid" for a schema it never checked,
        which is a worse claim than "parsed". So the result has three states:
        Supported = false means no answer was reached, Valid = true means the
        subset was checked and satisfied, Valid = false means a rule was broken
        and Error names it.

        Bounds come first. The schema is walked to a depth ceiling before any
        comparison, so a pathological schema is refused as unsupported rather
        than validated expensively. Error reporting is capped, and an error
        names the member and the rule, never the value - a validation report is
        exactly the sort of thing that ends up in a log, and the value may be
        the secret.

        No regular expression from the schema is ever used to match a path,
        command or address; pattern applies to a string value only, with a
        match timeout so a pathological pattern cannot hang a turn.

    .PARAMETER Schema
        The schema, as a JSON string or as an already-parsed object.

    .PARAMETER InputObject
        The value to validate, as returned by ConvertFrom-Json.

    .PARAMETER MaxDepth
        Depth ceiling for the schema walk. Default 12.

    .PARAMETER MaxError
        Most errors to report. Default 20.

    .EXAMPLE
        Test-ShpJsonSchema -Schema $jsonSchema -InputObject ($reply | ConvertFrom-Json)

        Returns Valid = $true only when the reply satisfies the supported
        keywords of the schema.

    .EXAMPLE
        (Test-ShpJsonSchema -Schema '{"anyOf":[{"type":"string"}]}' -InputObject 'x').Supported

        Returns $false: composition is outside the subset, so no conformance
        claim is made.

    .OUTPUTS
        System.Collections.Hashtable

        Supported (bool), Valid ($true, $false, or $null when not supported),
        Error (bounded strings naming member and rule) and Unsupported (the
        keywords that stopped the check).

    .LINK
        Invoke-Shp
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Schema,

        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [ValidateRange(1, 64)]
        [int]$MaxDepth = 12,

        [ValidateRange(1, 200)]
        [int]$MaxError = 20
    )

    $unsupportedKeyword = @(
        '$ref', '$defs', 'definitions', 'allOf', 'anyOf', 'oneOf', 'not',
        'if', 'then', 'else', 'patternProperties', 'propertyNames',
        'dependentSchemas', 'dependencies', 'contains', 'unevaluatedProperties',
        'unevaluatedItems', 'prefixItems'
    )

    $unsupported = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    $schemaObject = $Schema
    if ($Schema -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Schema)) {
            return @{ Supported = $false; Valid = $null; Error = @(); Unsupported = @('the schema is empty') }
        }
        try { $schemaObject = $Schema | ConvertFrom-Json -ErrorAction Stop }
        catch { return @{ Supported = $false; Valid = $null; Error = @(); Unsupported = @('the schema is not valid JSON') } }
    }
    if ($null -eq $schemaObject -or $schemaObject -is [valuetype] -or $schemaObject -is [string]) {
        return @{ Supported = $false; Valid = $null; Error = @(); Unsupported = @('the schema is not a JSON object') }
    }

    # Some callers wrap the schema the way the service does. Unwrap one level so
    # a caller who passed the request envelope is not told their schema is
    # unusable.
    foreach ($wrapper in 'schema', 'json_schema') {
        if ($schemaObject.PSObject.Properties[$wrapper] -and $schemaObject.$wrapper -is [psobject]) {
            $schemaObject = $schemaObject.$wrapper
        }
    }

    $memberNames = {
        param($Value)
        if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | ForEach-Object { [string]$_ }) }
        elseif ($Value -is [psobject]) { @($Value.PSObject.Properties.Name) }
        else { @() }
    }
    $memberValue = {
        param($Value, $Name)
        if ($Value -is [System.Collections.IDictionary]) { $Value[$Name] } else { $Value.$Name }
    }
    $hasMember = {
        param($Value, $Name)
        (& $memberNames $Value) -contains $Name
    }

    # Walk the whole schema first, to the depth ceiling, so an unsupported
    # keyword or an over-deep schema is reported BEFORE any comparison is made
    # and mistaken for a conformance answer.
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ Value = $schemaObject; Depth = 1 })
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        if ($item.Depth -gt $MaxDepth) {
            $null = $unsupported.Add("the schema is nested deeper than $MaxDepth levels")
            break
        }
        $node = $item.Value
        if ($null -eq $node -or $node -is [valuetype] -or $node -is [string]) { continue }
        if ($node -is [array]) {
            foreach ($element in $node) { $pending.Enqueue([pscustomobject]@{ Value = $element; Depth = $item.Depth + 1 }) }
            continue
        }
        foreach ($name in (& $memberNames $node)) {
            if ($name -in $unsupportedKeyword -and -not $unsupported.Contains($name)) { $null = $unsupported.Add($name) }
            $pending.Enqueue([pscustomobject]@{ Value = (& $memberValue $node $name); Depth = $item.Depth + 1 })
        }
    }

    if ($unsupported.Count -gt 0) {
        return @{ Supported = $false; Valid = $null; Error = @(); Unsupported = $unsupported.ToArray() }
    }

    $addError = {
        param($Path, $Message)
        if ($errors.Count -ge $MaxError) { return }
        $null = $errors.Add(('{0}: {1}' -f $(if ($Path) { $Path } else { '(root)' }), $Message))
    }

    $typeMatches = {
        param($Value, $TypeName)
        switch ($TypeName) {
            'null'    { $null -eq $Value }
            'boolean' { $Value -is [bool] }
            'string'  { $Value -is [string] }
            'integer' { ($Value -is [int] -or $Value -is [long] -or $Value -is [bigint]) -or
                        (($Value -is [double] -or $Value -is [decimal]) -and [double]$Value -eq [Math]::Truncate([double]$Value)) }
            'number'  { ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [bigint]) -and $Value -isnot [bool] }
            'array'   { $Value -is [array] }
            'object'  { $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [valuetype] -and $Value -isnot [array] }
            default   { $true }
        }
    }

    # Iterative, with an explicit stack: a schema is caller data and a recursive
    # walk over caller data is a stack-depth question nobody wants to answer.
    $work = [System.Collections.Generic.Stack[object]]::new()
    $work.Push([pscustomobject]@{ Schema = $schemaObject; Value = $InputObject; Path = '' })

    while ($work.Count -gt 0) {
        if ($errors.Count -ge $MaxError) { break }
        $frame = $work.Pop()
        $node = $frame.Schema
        $value = $frame.Value
        $path = $frame.Path
        if ($null -eq $node -or $node -is [valuetype] -or $node -is [string]) { continue }

        if (& $hasMember $node 'type') {
            $declared = @(& $memberValue $node 'type')
            $matched = $false
            foreach ($typeName in $declared) {
                if (& $typeMatches $value ([string]$typeName)) { $matched = $true; break }
            }
            if (-not $matched) {
                & $addError $path ("expected type {0}" -f (($declared | ForEach-Object { [string]$_ }) -join ' or '))
                continue
            }
        }

        if (& $hasMember $node 'const') {
            $constant = & $memberValue $node 'const'
            if (-not ($value -is [array]) -and -not ($constant -is [array]) -and $value -ne $constant) {
                & $addError $path 'does not equal the declared const'
                continue
            }
        }

        if (& $hasMember $node 'enum') {
            $allowed = @(& $memberValue $node 'enum')
            $found = $false
            foreach ($candidate in $allowed) { if ($value -eq $candidate) { $found = $true; break } }
            if (-not $found) {
                & $addError $path 'is not one of the declared enum values'
                continue
            }
        }

        if ($value -is [string]) {
            if ((& $hasMember $node 'minLength') -and $value.Length -lt [int](& $memberValue $node 'minLength')) {
                & $addError $path ('is shorter than minLength {0}' -f [int](& $memberValue $node 'minLength'))
            }
            if ((& $hasMember $node 'maxLength') -and $value.Length -gt [int](& $memberValue $node 'maxLength')) {
                & $addError $path ('is longer than maxLength {0}' -f [int](& $memberValue $node 'maxLength'))
            }
            if (& $hasMember $node 'pattern') {
                $expression = [string](& $memberValue $node 'pattern')
                try {
                    if (-not [regex]::IsMatch($value, $expression, [System.Text.RegularExpressions.RegexOptions]::None, [timespan]::FromSeconds(1))) {
                        & $addError $path 'does not match the declared pattern'
                    }
                } catch {
                    $null = $unsupported.Add('pattern')
                }
            }
        }

        if ($value -isnot [bool] -and ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal] -or $value -is [bigint])) {
            $numeric = [double]$value
            if ((& $hasMember $node 'minimum') -and $numeric -lt [double](& $memberValue $node 'minimum')) {
                & $addError $path ('is below minimum {0}' -f (& $memberValue $node 'minimum'))
            }
            if ((& $hasMember $node 'maximum') -and $numeric -gt [double](& $memberValue $node 'maximum')) {
                & $addError $path ('is above maximum {0}' -f (& $memberValue $node 'maximum'))
            }
            if ((& $hasMember $node 'exclusiveMinimum') -and $numeric -le [double](& $memberValue $node 'exclusiveMinimum')) {
                & $addError $path 'is at or below exclusiveMinimum'
            }
            if ((& $hasMember $node 'exclusiveMaximum') -and $numeric -ge [double](& $memberValue $node 'exclusiveMaximum')) {
                & $addError $path 'is at or above exclusiveMaximum'
            }
            if (& $hasMember $node 'multipleOf') {
                $divisor = [double](& $memberValue $node 'multipleOf')
                if ($divisor -gt 0 -and [Math]::Abs(($numeric / $divisor) - [Math]::Round($numeric / $divisor)) -gt 1e-9) {
                    & $addError $path 'is not a multiple of the declared multipleOf'
                }
            }
        }

        if ($value -is [array]) {
            if ((& $hasMember $node 'minItems') -and $value.Count -lt [int](& $memberValue $node 'minItems')) {
                & $addError $path ('has fewer than minItems {0}' -f [int](& $memberValue $node 'minItems'))
            }
            if ((& $hasMember $node 'maxItems') -and $value.Count -gt [int](& $memberValue $node 'maxItems')) {
                & $addError $path ('has more than maxItems {0}' -f [int](& $memberValue $node 'maxItems'))
            }
            if ((& $hasMember $node 'uniqueItems') -and [bool](& $memberValue $node 'uniqueItems')) {
                $seen = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($element in $value) {
                    if (-not $seen.Add(($element | ConvertTo-Json -Depth 8 -Compress))) {
                        & $addError $path 'contains duplicate items where uniqueItems is declared'
                        break
                    }
                }
            }
            if (& $hasMember $node 'items') {
                $itemSchema = & $memberValue $node 'items'
                for ($index = 0; $index -lt $value.Count; $index++) {
                    $work.Push([pscustomobject]@{ Schema = $itemSchema; Value = $value[$index]; Path = ('{0}[{1}]' -f $path, $index) })
                }
            }
            continue
        }

        $isObject = $null -ne $value -and $value -isnot [string] -and $value -isnot [valuetype]
        if (-not $isObject) { continue }

        $present = @(& $memberNames $value)
        $declaredProperties = if (& $hasMember $node 'properties') { & $memberValue $node 'properties' } else { $null }
        $declaredNames = @(& $memberNames $declaredProperties)

        if (& $hasMember $node 'required') {
            foreach ($requiredName in @(& $memberValue $node 'required')) {
                if ($present -notcontains [string]$requiredName) {
                    & $addError $path ("is missing required member '{0}'" -f $requiredName)
                }
            }
        }

        if (& $hasMember $node 'additionalProperties') {
            $additional = & $memberValue $node 'additionalProperties'
            if ($additional -is [bool] -and -not $additional) {
                foreach ($name in $present) {
                    if ($declaredNames -notcontains $name) {
                        & $addError $path ("has member '{0}', which additionalProperties forbids" -f $name)
                    }
                }
            } elseif ($additional -is [psobject] -or $additional -is [System.Collections.IDictionary]) {
                foreach ($name in $present) {
                    if ($declaredNames -notcontains $name) {
                        $work.Push([pscustomobject]@{ Schema = $additional; Value = (& $memberValue $value $name); Path = ('{0}.{1}' -f $path, $name) })
                    }
                }
            }
        }

        foreach ($name in $declaredNames) {
            if ($present -notcontains $name) { continue }
            $work.Push([pscustomobject]@{
                Schema = (& $memberValue $declaredProperties $name)
                Value  = (& $memberValue $value $name)
                Path   = ('{0}.{1}' -f $path, $name)
            })
        }
    }

    if ($unsupported.Count -gt 0) {
        return @{ Supported = $false; Valid = $null; Error = @(); Unsupported = $unsupported.ToArray() }
    }

    @{
        Supported   = $true
        Valid       = ($errors.Count -eq 0)
        Error       = $errors.ToArray()
        Unsupported = @()
    }
}
