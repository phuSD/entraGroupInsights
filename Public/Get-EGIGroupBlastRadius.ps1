function Get-EGIGroupBlastRadius {
    <#
    .SYNOPSIS
        Maps everything downstream that depends on a given Entra ID group.

    .DESCRIPTION
        A dynamic group's rule usually looks harmless in isolation, but the group
        itself is frequently the target of Conditional Access policies, license
        assignment, application role assignments, and (for role-assignable groups)
        PIM eligibility. This function collects all of those references so a
        membership-rule change can be evaluated against its real blast radius
        before it is saved.

        Nested group membership is included on both sides:
        - Parent groups (this group's transitive memberOf) are checked for the
          same Conditional Access / license / app role dependencies, since
          Entra evaluates group-based Conditional Access, group-based
          licensing, and group-based app role assignment against a user's
          *transitive* group membership - a policy on a parent group reaches
          this group's members even though it never references this group's
          ID directly. Each such hit is tagged with which group it actually
          came from (Source: 'Direct' or "Nested via '<parent>'").
        - Child groups (other groups nested as this group's transitive
          members) are listed for visibility into the nesting structure, but
          their own dependencies are not expanded - a child group's
          assignments don't flow back up to this group's members.
        - Dynamic groups can also nest by rule instead of by structure: a
          membership rule using the (preview) memberOf operator, e.g.
          'user.memberof -any (group.objectId -in [''<id>''])', makes this
          group's effective population mirror another group's membership
          without this group ever being added as that group's member. Any
          group referenced this way is resolved and listed in
          RuleReferencedGroups for visibility - same as ChildGroups, these
          are not expanded for their own Conditional Access / license / app
          role dependencies, since a referenced group's own dependencies
          already apply to its members directly and don't need to be
          duplicated onto this group's blast radius.
        - The reverse of the point above also matters: some *other* dynamic
          group elsewhere in the tenant might reference *this* group through
          its own memberOf clause, so a change to this group's population
          would ripple into that other group too. Since Graph has no
          "who references me" query, this is found by listing every dynamic
          group in the tenant and scanning each one's rule text for a
          memberOf reference to this group's ID; matches are listed in
          RuleReferencedByGroups. This is the one part of the nested-group
          detection that costs an extra tenant-wide group listing call, so
          it scales with how many dynamic groups the tenant has.

        Requires an existing Microsoft Graph connection (Connect-MgGraph) with at
        least: Group.Read.All, Policy.Read.All, Directory.Read.All, and
        RoleManagement.Read.Directory if the group is role-assignable.

    .PARAMETER GroupId
        Object ID of the group to analyze.

    .EXAMPLE
        Get-EGIGroupBlastRadius -GroupId '11111111-2222-3333-4444-555555555555' | Format-List
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')]
        [string] $GroupId
    )

    $group = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,assignedLicenses,isAssignableToRole,resourceProvisioningOptions"

    Write-Verbose "Analyzing blast radius for group '$($group.displayName)' ($GroupId)"

    # --- Nesting: parent groups (this group's transitive memberOf) ------
    $parentGroups = @()
    try {
        $parentGroups = Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName,groupTypes"
    }
    catch {
        Write-Warning "Could not read parent group memberships for group '$($group.displayName)': $($_.Exception.Message)"
    }

    # --- Nesting: child groups (other groups nested inside this one) ----
    $childGroups = @()
    try {
        $childGroups = Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMembers/microsoft.graph.group?`$select=id,displayName,groupTypes"
    }
    catch {
        Write-Warning "Could not read nested member groups for group '$($group.displayName)': $($_.Exception.Message)"
    }

    # --- Nesting: groups referenced by a memberOf (preview) rule clause --
    # e.g. 'user.memberof -any (group.objectId -in [''<id>''])'. Scoped to
    # the text right after the word 'memberof' up to its first closing
    # paren, so GUIDs elsewhere in an unrelated part of the rule aren't
    # picked up by mistake.
    $ruleReferencedGroups = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not [string]::IsNullOrWhiteSpace($group.membershipRule)) {
        $refIds = [System.Collections.Generic.List[string]]::new()
        foreach ($clause in [regex]::Matches($group.membershipRule, '(?i)memberof[^()]*\(([^)]*)\)')) {
            foreach ($idMatch in [regex]::Matches($clause.Groups[1].Value, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) {
                if ($refIds -notcontains $idMatch.Value) { $refIds.Add($idMatch.Value) }
            }
        }
        foreach ($refId in $refIds) {
            try {
                $refGroup = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$refId`?`$select=id,displayName"
                $ruleReferencedGroups.Add([pscustomobject]@{ id = $refGroup.id; displayName = $refGroup.displayName })
            }
            catch {
                Write-Warning "Could not resolve group '$refId' referenced by '$($group.displayName)''s membershipRule (memberOf): $($_.Exception.Message)"
                $ruleReferencedGroups.Add([pscustomobject]@{ id = $refId; displayName = "(unresolved: $refId)" })
            }
        }
    }

    # --- Nesting: other dynamic groups whose own rule references this ----
    # --- group via memberOf (the reverse of RuleReferencedGroups) --------
    $ruleReferencedByGroups = [System.Collections.Generic.List[pscustomobject]]::new()
    try {
        $allDynamicGroups = Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=groupTypes/any(c:c eq 'DynamicMembership')&`$select=id,displayName,membershipRule"
        foreach ($candidate in $allDynamicGroups) {
            if ($candidate.id -eq $GroupId) { continue }
            if ([string]::IsNullOrWhiteSpace($candidate.membershipRule)) { continue }

            $referencesThisGroup = $false
            foreach ($clause in [regex]::Matches($candidate.membershipRule, '(?i)memberof[^()]*\(([^)]*)\)')) {
                if ([regex]::IsMatch($clause.Groups[1].Value, [regex]::Escape($GroupId), 'IgnoreCase')) {
                    $referencesThisGroup = $true
                    break
                }
            }
            if ($referencesThisGroup) {
                $ruleReferencedByGroups.Add([pscustomobject]@{ id = $candidate.id; displayName = $candidate.displayName })
            }
        }
    }
    catch {
        Write-Warning "Could not scan tenant dynamic groups for memberOf references to group '$($group.displayName)': $($_.Exception.Message)"
    }

    # --- Conditional Access policies referencing this group, direct or ---
    # --- inherited through a parent group's include/exclude list --------
    $caPolicies = Invoke-EGIGraphPaged -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$select=id,displayName,state,conditions'
    $caMatches = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($policy in $caPolicies) {
        $includeHit = $policy.conditions.users.includeGroups -contains $GroupId
        $excludeHit = $policy.conditions.users.excludeGroups -contains $GroupId
        if ($includeHit -or $excludeHit) {
            $caMatches.Add([pscustomobject]@{
                    DisplayName = $policy.displayName
                    State       = $policy.state
                    Reference   = if ($includeHit -and $excludeHit) { 'Include+Exclude' } elseif ($includeHit) { 'Include' } else { 'Exclude' }
                    Source      = 'Direct'
                })
        }
        foreach ($parent in $parentGroups) {
            $parentIncludeHit = $policy.conditions.users.includeGroups -contains $parent.id
            $parentExcludeHit = $policy.conditions.users.excludeGroups -contains $parent.id
            if ($parentIncludeHit -or $parentExcludeHit) {
                $caMatches.Add([pscustomobject]@{
                        DisplayName = $policy.displayName
                        State       = $policy.state
                        Reference   = if ($parentIncludeHit -and $parentExcludeHit) { 'Include+Exclude' } elseif ($parentIncludeHit) { 'Include' } else { 'Exclude' }
                        Source      = "Nested via '$($parent.displayName)'"
                    })
            }
        }
    }

    # --- License assignment, direct or inherited through a parent group -
    # Outer @() keeps a single license from unrolling to a bare hashtable,
    # whose .Count would be its key count rather than 1.
    $licenses = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($lic in @($group.assignedLicenses) | Where-Object { $_.skuId }) {
        $licenses.Add([pscustomobject]@{ SkuId = $lic.skuId; Source = 'Direct' })
    }
    foreach ($parent in $parentGroups) {
        try {
            $parentDetails = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($parent.id)`?`$select=assignedLicenses"
            foreach ($lic in @($parentDetails.assignedLicenses) | Where-Object { $_.skuId }) {
                $licenses.Add([pscustomobject]@{ SkuId = $lic.skuId; Source = "Nested via '$($parent.displayName)'" })
            }
        }
        catch {
            Write-Warning "Could not read license assignment for parent group '$($parent.displayName)': $($_.Exception.Message)"
        }
    }

    # --- Application role assignments, direct or inherited --------------
    $appRoleAssignments = [System.Collections.Generic.List[pscustomobject]]::new()
    try {
        foreach ($a in Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/appRoleAssignments") {
            $appRoleAssignments.Add([pscustomobject]@{ resourceDisplayName = $a.resourceDisplayName; appRoleId = $a.appRoleId; Source = 'Direct' })
        }
    }
    catch {
        Write-Warning "Could not read app role assignments for group '$($group.displayName)': $($_.Exception.Message)"
    }
    foreach ($parent in $parentGroups) {
        try {
            foreach ($a in Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/groups/$($parent.id)/appRoleAssignments") {
                $appRoleAssignments.Add([pscustomobject]@{ resourceDisplayName = $a.resourceDisplayName; appRoleId = $a.appRoleId; Source = "Nested via '$($parent.displayName)'" })
            }
        }
        catch {
            Write-Warning "Could not read app role assignments for parent group '$($parent.displayName)': $($_.Exception.Message)"
        }
    }

    # --- PIM eligibility, only relevant for role-assignable groups -------
    # Not extended to parent groups: Entra does not allow a role-assignable
    # group to be nested inside another role-assignable group, so PIM
    # eligibility never flows through group nesting in practice.
    $pimEligibility = @()
    if ($group.isAssignableToRole) {
        try {
            $pimEligibility = Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=principalId eq '$GroupId'"
        }
        catch {
            Write-Warning "Could not read PIM eligibility for group '$($group.displayName)' - check RoleManagement.Read.Directory permission: $($_.Exception.Message)"
        }
    }

    # --- Teams / SharePoint provisioning (Microsoft 365 groups only) ----
    $isTeamsGroup = $group.resourceProvisioningOptions -contains 'Team'

    $totalDependencies = $caMatches.Count + $licenses.Count + $appRoleAssignments.Count + @($pimEligibility).Count + [int]$isTeamsGroup

    $riskLevel = switch ($true) {
        { $totalDependencies -eq 0 } { 'None'; break }
        { @($pimEligibility).Count -gt 0 -or ($caMatches | Where-Object State -EQ 'enabled') } { 'Critical'; break }
        { $totalDependencies -ge 3 } { 'High'; break }
        { $totalDependencies -ge 2 } { 'Medium'; break }
        default { 'Low' }
    }

    [pscustomobject]@{
        GroupId                   = $GroupId
        DisplayName               = $group.displayName
        IsRoleAssignable          = [bool]$group.isAssignableToRole
        IsTeamsGroup              = $isTeamsGroup
        MembershipRule            = $group.membershipRule
        ParentGroups              = @($parentGroups | Select-Object id, displayName, groupTypes)
        ChildGroups               = @($childGroups | Select-Object id, displayName, groupTypes)
        RuleReferencedGroups      = @($ruleReferencedGroups)
        RuleReferencedByGroups    = @($ruleReferencedByGroups)
        ConditionalAccessPolicies = @($caMatches)
        AssignedLicenses          = @($licenses)
        AppRoleAssignments        = @($appRoleAssignments)
        PimEligibleRoleCount      = @($pimEligibility).Count
        TotalDependencyCount      = $totalDependencies
        RiskLevel                 = $riskLevel
    }
}
