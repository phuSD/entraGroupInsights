function Invoke-EGIGraphPaged {
    <#
    .SYNOPSIS
        Calls a Microsoft Graph GET endpoint and follows @odata.nextLink until exhausted.

    .PARAMETER Uri
        The initial Graph request URI (v1.0 or beta).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri

    while ($null -ne $next) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($response.value) { $items.AddRange(@($response.value)) }
        $next = $response.'@odata.nextLink'
    }

    return $items.ToArray()
}
