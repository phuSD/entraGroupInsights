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
        [Parameter(Mandatory)] [string] $GroupId
    )

    $group = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,assignedLicenses,isAssignableToRole,resourceProvisioningOptions"

    Write-Verbose "Analyzing blast radius for group '$($group.displayName)' ($GroupId)"

    # --- Conditional Access policies referencing this group ------------
    $caPolicies = Invoke-EGIGraphPaged -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$select=id,displayName,state,conditions'
    $caMatches = foreach ($policy in $caPolicies) {
        $includeHit = $policy.conditions.users.includeGroups -contains $GroupId
        $excludeHit = $policy.conditions.users.excludeGroups -contains $GroupId
        if ($includeHit -or $excludeHit) {
            [pscustomobject]@{
                DisplayName = $policy.displayName
                State       = $policy.state
                Reference   = if ($includeHit -and $excludeHit) { 'Include+Exclude' } elseif ($includeHit) { 'Include' } else { 'Exclude' }
            }
        }
    }

    # --- License assignment on the group itself -------------------------
    $licenses = @($group.assignedLicenses) | Where-Object { $_.skuId }

    # --- Application role assignments (enterprise app access) -----------
    $appRoleAssignments = try {
        Invoke-EGIGraphPaged -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/appRoleAssignments"
    }
    catch {
        Write-Warning "Could not read app role assignments for group '$($group.displayName)': $($_.Exception.Message)"
        @()
    }

    # --- PIM eligibility, only relevant for role-assignable groups -------
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

    $totalDependencies = @($caMatches).Count + $licenses.Count + @($appRoleAssignments).Count + @($pimEligibility).Count + [int]$isTeamsGroup

    $riskLevel = switch ($true) {
        { $totalDependencies -eq 0 } { 'None'; break }
        { @($pimEligibility).Count -gt 0 -or ($caMatches | Where-Object State -EQ 'enabled') } { 'Critical'; break }
        { $totalDependencies -ge 3 } { 'High'; break }
        { $totalDependencies -ge 1 } { 'Medium'; break }
        default { 'Low' }
    }

    [pscustomobject]@{
        GroupId                  = $GroupId
        DisplayName              = $group.displayName
        IsRoleAssignable         = [bool]$group.isAssignableToRole
        IsTeamsGroup             = $isTeamsGroup
        ConditionalAccessPolicies = @($caMatches)
        AssignedLicenseSkuIds    = @($licenses.skuId)
        AppRoleAssignments       = @($appRoleAssignments | Select-Object resourceDisplayName, appRoleId)
        PimEligibleRoleCount     = @($pimEligibility).Count
        TotalDependencyCount     = $totalDependencies
        RiskLevel                = $riskLevel
    }
}
