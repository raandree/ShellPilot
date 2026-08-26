function ConvertTo-ShpAnnotation {
    <#
    .SYNOPSIS
        Converts a structured finding into a CI annotation command.

    .DESCRIPTION
        Accepts a ShellPilot result or a plain finding object from the pipeline
        and returns a GitHub Actions, Azure DevOps, or readable text annotation.
        A ShellPilot result is unwrapped through its ContentObject member. If
        ContentObject is an array, one annotation is produced per finding.

        Finding properties are read case-insensitively. By default the cmdlet
        reads Level, Path, Line, Column, Title, and Message. PropertyMap changes
        the source property for any of those canonical names, for example
        @{ Level = 'severity'; Message = 'detail' }.

        Error, Warning, and Notice are recognized without regard to case.
        GitHub Actions supports all three. Azure DevOps accepts only error and
        warning, so Notice becomes warning there. Every missing or unknown level
        also becomes warning; malformed model output must not create an error
        annotation by accident.

        Without Format, GITHUB_ACTIONS is checked first, then TF_BUILD. If
        neither variable is set, Text is used. Strings are returned by default.
        Emit writes each annotation to the host stream instead.

    .PARAMETER InputObject
        A ShellPilot.Result or a plain object containing one finding. Accepts
        pipeline input. A ShellPilot result's ContentObject may contain one
        finding or an array of findings.

    .PARAMETER PropertyMap
        Maps canonical finding names to property names in the input schema.
        Unspecified entries retain their defaults. For example,
        @{ Level = 'severity'; Path = 'file'; Message = 'detail' }.

    .PARAMETER Format
        GitHubActions, AzureDevOps, or Text. When omitted, a non-empty
        GITHUB_ACTIONS variable selects GitHubActions; otherwise a non-empty
        TF_BUILD variable selects AzureDevOps; otherwise Text is used.

    .PARAMETER Emit
        Writes each formatted annotation to the host stream instead of returning
        it to the success stream.

    .PARAMETER Summary
        Appends the findings as a Markdown table to the file named by
        GITHUB_STEP_SUMMARY when that environment variable is set.

    .EXAMPLE
        $schema = @{
            type = 'object'
            required = @('Level', 'Message')
            properties = @{
                Level = @{ type = 'string' }
                Path = @{ type = 'string' }
                Line = @{ type = 'integer' }
                Column = @{ type = 'integer' }
                Title = @{ type = 'string' }
                Message = @{ type = 'string' }
            }
        } | ConvertTo-Json -Depth 5 -Compress

        Invoke-Shp -Prompt 'Review the staged changes.' -JsonSchema $schema |
            ConvertTo-ShpAnnotation -Emit

        Requests one structured finding, unwraps ContentObject from the
        ShellPilot result, auto-detects the CI vendor, and emits the annotation.

    .EXAMPLE
        $map = @{ Level = 'severity'; Path = 'file'; Message = 'detail' }
        $findings | ConvertTo-ShpAnnotation -PropertyMap $map -Format Text

        Formats objects from a caller-specific schema as readable text.

    .OUTPUTS
        System.String

        One annotation per finding. Emit writes to the host stream instead.

    .LINK
        Invoke-Shp

    .LINK
        https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands

    .LINK
        https://learn.microsoft.com/azure/devops/pipelines/scripts/logging-commands
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The -Emit switch deliberately writes CI workflow commands to the host stream so the runner can interpret them; default output remains on the pipeline.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject,

        [hashtable]$PropertyMap = @{},

        [ValidateSet('GitHubActions', 'AzureDevOps', 'Text')]
        [string]$Format,

        [switch]$Emit,

        [switch]$Summary
    )

    begin {
        $propertyName = [ordered]@{
            Level   = 'Level'
            Path    = 'Path'
            Line    = 'Line'
            Column  = 'Column'
            Title   = 'Title'
            Message = 'Message'
        }

        foreach ($canonicalName in @($propertyName.Keys)) {
            if ($PropertyMap.ContainsKey($canonicalName) -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$PropertyMap[$canonicalName]
                )) {
                $propertyName[$canonicalName] =
                    [string]$PropertyMap[$canonicalName]
            }
        }

        $resolvedFormat = if ($PSBoundParameters.ContainsKey('Format')) {
            $Format
        } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) {
            'GitHubActions'
        } elseif (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD)) {
            'AzureDevOps'
        } else {
            'Text'
        }

        $summaryPath = if ($Summary -and
            -not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
            $env:GITHUB_STEP_SUMMARY
        } else {
            $null
        }
        $summaryStarted = $false
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

        $findProperty = {
            param(
                [AllowNull()]
                [object]$Candidate,

                [Parameter(Mandatory)]
                [string]$Name
            )

            if ($null -eq $Candidate) {
                return [pscustomobject]@{ Found = $false; Value = $null }
            }

            if ($Candidate -is [System.Collections.IDictionary]) {
                foreach ($key in $Candidate.Keys) {
                    if ([string]::Equals(
                        [string]$key,
                        $Name,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                        return [pscustomobject]@{
                            Found = $true
                            Value = $Candidate[$key]
                        }
                    }
                }

                return [pscustomobject]@{ Found = $false; Value = $null }
            }

            $property = $Candidate.PSObject.Properties |
                Where-Object {
                    [string]::Equals(
                        $_.Name,
                        $Name,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Select-Object -First 1

            [pscustomobject]@{
                Found = $null -ne $property
                Value = if ($null -ne $property) { $property.Value } else { $null }
            }
        }

        $escapeGitHubData = {
            param([AllowNull()][object]$Value)

            ([string]$Value).
                Replace('%', '%25').
                Replace("`r", '%0D').
                Replace("`n", '%0A')
        }

        $escapeGitHubProperty = {
            param([AllowNull()][object]$Value)

            (& $escapeGitHubData $Value).
                Replace(':', '%3A').
                Replace(',', '%2C')
        }

        $escapeAzureData = {
            param([AllowNull()][object]$Value)

            ([string]$Value).
                Replace('%', '%AZP25').
                Replace("`r", '%0D').
                Replace("`n", '%0A')
        }

        $escapeAzureProperty = {
            param([AllowNull()][object]$Value)

            $withoutDelimiters = ([string]$Value).
                Replace(';', '').
                Replace(']', '')
            & $escapeAzureData $withoutDelimiters
        }

        $convertToMarkdownCell = {
            param([AllowNull()][object]$Value)

            [System.Net.WebUtility]::HtmlEncode([string]$Value).
                Replace('|', '\|').
                Replace("`r`n", '<br>').
                Replace("`r", '<br>').
                Replace("`n", '<br>')
        }
    }

    process {
        $isShellPilotResult = $null -ne $InputObject -and
            $InputObject.PSObject.TypeNames -contains 'ShellPilot.Result'
        if ($isShellPilotResult) {
            $contentObject = & $findProperty $InputObject 'ContentObject'
            if ($null -eq $contentObject.Value) {
                $findings = [object[]]::new(1)
            } else {
                $findings = @($contentObject.Value)
            }
        } elseif ($null -eq $InputObject) {
            $findings = [object[]]::new(1)
        } else {
            $findings = @($InputObject)
        }

        foreach ($finding in $findings) {
            $value = @{}
            foreach ($canonicalName in @($propertyName.Keys)) {
                $property = & $findProperty $finding $propertyName[$canonicalName]
                $value[$canonicalName] = if ($property.Found) {
                    [string]$property.Value
                } else {
                    ''
                }
            }

            $level = switch ($value.Level.Trim().ToLowerInvariant()) {
                'error'   { 'error'; break }
                'warning' { 'warning'; break }
                'notice'  { 'notice'; break }
                default   { 'warning' }
            }
            $azureLevel = if ($level -eq 'error') { 'error' } else { 'warning' }

            $annotation = switch ($resolvedFormat) {
                'GitHubActions' {
                    $commandProperty = [System.Collections.Generic.List[string]]::new()
                    if (-not [string]::IsNullOrWhiteSpace($value.Path)) {
                        $commandProperty.Add(
                            'file={0}' -f (& $escapeGitHubProperty $value.Path)
                        )
                    }
                    if (-not [string]::IsNullOrWhiteSpace($value.Line)) {
                        $commandProperty.Add(
                            'line={0}' -f (& $escapeGitHubProperty $value.Line)
                        )
                    }
                    if (-not [string]::IsNullOrWhiteSpace($value.Column)) {
                        $commandProperty.Add(
                            'col={0}' -f (& $escapeGitHubProperty $value.Column)
                        )
                    }
                    if (-not [string]::IsNullOrWhiteSpace($value.Title)) {
                        $commandProperty.Add(
                            'title={0}' -f (& $escapeGitHubProperty $value.Title)
                        )
                    }

                    $propertyText = if ($commandProperty.Count -gt 0) {
                        ' ' + ($commandProperty -join ',')
                    } else {
                        ''
                    }
                    '::{0}{1}::{2}' -f $level, $propertyText,
                        (& $escapeGitHubData $value.Message)
                    break
                }

                'AzureDevOps' {
                    $commandProperty =
                        [System.Collections.Generic.List[string]]::new()
                    $commandProperty.Add('type={0}' -f $azureLevel)
                    if (-not [string]::IsNullOrWhiteSpace($value.Path)) {
                        $commandProperty.Add(
                            'sourcepath={0}' -f
                                (& $escapeAzureProperty $value.Path)
                        )
                    }
                    if (-not [string]::IsNullOrWhiteSpace($value.Line)) {
                        $commandProperty.Add(
                            'linenumber={0}' -f
                                (& $escapeAzureProperty $value.Line)
                        )
                    }

                    '##vso[task.logissue {0}]{1}' -f
                        ($commandProperty -join ';'),
                        (& $escapeAzureData $value.Message)
                    break
                }

                default {
                    $prefix = '[{0}]' -f $level.ToUpperInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($value.Path)) {
                        $location = $value.Path
                        if (-not [string]::IsNullOrWhiteSpace($value.Line)) {
                            $location += ':' + $value.Line
                        }
                        if (-not [string]::IsNullOrWhiteSpace($value.Column)) {
                            $location += ':' + $value.Column
                        }
                        $prefix += ' ' + $location
                    }
                    if (-not [string]::IsNullOrWhiteSpace($value.Title)) {
                        $prefix += ' ' + $value.Title + ':'
                    }

                    if ([string]::IsNullOrEmpty($value.Message)) {
                        $prefix
                    } else {
                        $prefix + ' ' + $value.Message
                    }
                }
            }

            if ($null -ne $summaryPath) {
                $summaryText = if (-not $summaryStarted) {
                    '| Level | Path | Line | Column | Title | Message |' + "`n" +
                    '| --- | --- | ---: | ---: | --- | --- |' + "`n"
                } else {
                    ''
                }
                $summaryText += '| {0} | {1} | {2} | {3} | {4} | {5} |{6}' -f
                    (& $convertToMarkdownCell $level),
                    (& $convertToMarkdownCell $value.Path),
                    (& $convertToMarkdownCell $value.Line),
                    (& $convertToMarkdownCell $value.Column),
                    (& $convertToMarkdownCell $value.Title),
                    (& $convertToMarkdownCell $value.Message),
                    "`n"

                try {
                    [System.IO.File]::AppendAllText(
                        $summaryPath,
                        $summaryText,
                        $utf8NoBom
                    )
                    $summaryStarted = $true
                } catch {
                    Write-Warning (
                        'Could not append the GitHub step summary at {0}: {1}' -f
                            $summaryPath,
                            $_.Exception.Message
                    )
                    $summaryPath = $null
                }
            }

            if ($Emit) {
                Write-Host -Object $annotation
            } else {
                $annotation
            }
        }
    }
}