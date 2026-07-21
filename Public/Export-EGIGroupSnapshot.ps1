function Export-EGIGroupSnapshot {
    <#
    .SYNOPSIS
        Exports all dynamic membership groups and their rules to a JSON snapshot file.

    .DESCRIPTION
        Intended to be run on a schedule (e.g. a daily Azure Automation runbook or
        scheduled task) and the output committed to a Git repository. Each commit
        then becomes a reviewable version of "what dynamic group rules looked like
        on this date" - the same policy-as-code pattern Microsoft recommends for
        Conditional Access, applied to dynamic groups.

    .PARAMETER Path
        File path to write the JSON snapshot to.

    .EXAMPLE
        Export-EGIGroupSnapshot -Path './snapshots/dynamic-groups-2026-07-21.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    # Filtering on groupTypes/any(...) is a Graph "advanced query": it requires
    # $count=true plus the ConsistencyLevel:eventual header on every page.
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=groupTypes/any(c:c eq 'DynamicMembership')&`$count=true&`$select=id,displayName,membershipRule,membershipRuleProcessingState,isAssignableToRole"
    $groups = Invoke-EGIGraphPaged -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' }

    $snapshot = [pscustomobject]@{
        CapturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        GroupCount    = @($groups).Count
        Groups        = @($groups | ForEach-Object {
                [pscustomobject]@{
                    GroupId       = $_.id
                    DisplayName   = $_.displayName
                    MembershipRule = $_.membershipRule
                    ProcessingState = $_.membershipRuleProcessingState
                    RoleAssignable  = [bool]$_.isAssignableToRole
                }
            } | Sort-Object GroupId)
    }

    # BOM-less UTF-8 regardless of PowerShell edition (5.1's Set-Content writes a
    # BOM), so snapshots committed from different hosts diff cleanly in Git.
    $json = ($snapshot | ConvertTo-Json -Depth 6) + "`n"
    $resolvedPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.File]::WriteAllText($resolvedPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Verbose "Wrote snapshot of $($snapshot.GroupCount) dynamic group(s) to $Path"
    return $snapshot
}
