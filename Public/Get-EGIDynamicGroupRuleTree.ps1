function Get-EGIDynamicGroupRuleTree {
    <#
    .SYNOPSIS
        Parses a dynamic group's membership rule into a readable logic tree.

    .DESCRIPTION
        Fetches the membershipRule for a given Entra ID group (or accepts a raw
        rule string) and renders it as a nested AND/OR/NOT tree instead of one
        long, hard-to-read condition string.

    .PARAMETER GroupId
        Object ID of the dynamic group. Requires an existing Microsoft Graph
        connection (Connect-MgGraph) with at least Group.Read.All.

    .PARAMETER Rule
        Alternatively, pass a raw membership rule string directly without
        querying Graph - useful for testing rules before they are saved.

    .PARAMETER AsText
        Return an indented plain-text tree instead of the object tree.

    .EXAMPLE
        Get-EGIDynamicGroupRuleTree -GroupId '11111111-2222-3333-4444-555555555555' -AsText

    .EXAMPLE
        Get-EGIDynamicGroupRuleTree -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")' -AsText
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByGroupId')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByGroupId')]
        [ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')]
        [string] $GroupId,

        [Parameter(Mandatory, ParameterSetName = 'ByRule')]
        [string] $Rule,

        [switch] $AsText
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByGroupId') {
        $group = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=id,displayName,groupTypes,membershipRule,membershipRuleProcessingState"

        if ($group.groupTypes -notcontains 'DynamicMembership') {
            Write-Warning "Group '$($group.displayName)' is not a dynamic membership group."
            return
        }
        if ([string]::IsNullOrWhiteSpace($group.membershipRule)) {
            Write-Warning "Group '$($group.displayName)' has no membership rule set."
            return
        }
        $Rule = $group.membershipRule
        $displayName = $group.displayName
    }
    else {
        $displayName = '(ad-hoc rule)'
    }

    $tree = ConvertFrom-EGIRuleString -Rule $Rule

    if ($AsText) {
        return "Group: $displayName`nRule : $Rule`n`n" + (ConvertTo-EGIRuleTreeText -Node $tree)
    }

    [pscustomobject]@{
        GroupId     = if ($PSCmdlet.ParameterSetName -eq 'ByGroupId') { $GroupId } else { $null }
        DisplayName = $displayName
        RawRule     = $Rule
        Tree        = $tree
    }
}
