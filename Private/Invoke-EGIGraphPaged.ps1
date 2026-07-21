function Invoke-EGIGraphPaged {
    <#
    .SYNOPSIS
        Calls a Microsoft Graph GET endpoint and follows @odata.nextLink until exhausted.

    .PARAMETER Uri
        The initial Graph request URI (v1.0 or beta).

    .PARAMETER Headers
        Optional extra request headers, re-sent on every page. Required for
        advanced queries (e.g. @{ ConsistencyLevel = 'eventual' }), where the
        header must accompany each nextLink request as well.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri

    while ($null -ne $next) {
        $response = if ($Headers -and $Headers.Count -gt 0) {
            Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers
        }
        else {
            Invoke-MgGraphRequest -Method GET -Uri $next
        }
        if ($response.value) { $items.AddRange(@($response.value)) }
        $next = $response.'@odata.nextLink'
    }

    return $items.ToArray()
}
