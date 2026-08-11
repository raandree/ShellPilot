function New-ShpHttpErrorDetail {
    <#
    .SYNOPSIS
        Builds the structured detail object carried on a failed HTTP request.

    .DESCRIPTION
        Private helper shared by both senders (Invoke-ShpHttpRequest and
        Invoke-ShpStreamRequest). A caller that has to work out WHY a request
        failed must not be made to regex an exception string, so both senders put
        this object on ErrorRecord.TargetObject. It carries the status code, the
        service's own error code, the parameter it objected to, its human
        message, the whole raw body and the request URI.

        The service's error code alone is not always enough to identify what was
        refused - a rejected store parameter comes back as code
        "unsupported_value" with param "store" - which is why Param is carried
        separately. A body that is not a {"error":{...}} envelope (an HTML page
        from an intermediate proxy, plain text, an empty body) is normal and
        simply leaves the parsed members null; the raw body is still handed over
        intact.

        The object renders short by default. Body is deliberately kept whole, but
        Resolve-ShpError interpolates TargetObject straight into a model prompt,
        so the stock "@{StatusCode=...; Body=...}" rendering would send an entire
        proxy error page on a billable call.

    .PARAMETER StatusCode
        The HTTP status code of the failed response.

    .PARAMETER Body
        The raw response body, kept whole on the returned object.

    .PARAMETER RequestUri
        The absolute URI the failed request was sent to.

    .EXAMPLE
        New-ShpHttpErrorDetail -StatusCode 400 -RequestUri $uri -Body $content

        Returns the detail object for a refused request, with ErrorCode and Param
        parsed from the body when the service returned an error envelope.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

        A ShellPilot.HttpErrorDetail with StatusCode, ErrorCode, Param, Message,
        Body and RequestUri members.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-ShpHttpErrorDetail parses a response body into a detail object; it changes no state and needs no ShouldProcess confirmation.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int]$StatusCode,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Body,

        [Parameter(Mandatory)]
        [string]$RequestUri
    )

    $rawBody = if ($null -eq $Body) { '' } else { $Body }

    $errorCode = $null
    $errorMessage = $null
    $errorParam = $null
    if ($rawBody.Trim()) {
        try {
            $parsed = $rawBody | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.PSObject.Properties.Match('error').Count -gt 0 -and $parsed.error) {
                if ($parsed.error.PSObject.Properties.Match('code').Count -gt 0)    { $errorCode = [string]$parsed.error.code }
                if ($parsed.error.PSObject.Properties.Match('message').Count -gt 0) { $errorMessage = [string]$parsed.error.message }
                if ($parsed.error.PSObject.Properties.Match('param').Count -gt 0)   { $errorParam = [string]$parsed.error.param }
            }
        } catch {
            Write-Debug 'Error response body is not JSON; leaving the structured members unset.'
        }
    }

    $detail = [pscustomobject]@{
        PSTypeName = 'ShellPilot.HttpErrorDetail'
        StatusCode = $StatusCode
        ErrorCode  = $errorCode
        Param      = $errorParam
        Message    = $errorMessage
        Body       = $rawBody
        RequestUri = $RequestUri
    }
    $detail | Add-Member -MemberType ScriptMethod -Name ToString -Force -Value {
        $parts = @('HTTP ' + $this.StatusCode)
        if ($this.ErrorCode) { $parts += $this.ErrorCode }
        if ($this.Param)     { $parts += '(param {0})' -f $this.Param }
        if ($this.Message)   { $parts += '- {0}' -f $this.Message }
        $parts -join ' '
    }
    $detail
}
