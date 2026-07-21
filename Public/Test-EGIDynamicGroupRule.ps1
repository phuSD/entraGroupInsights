function Test-EGIDynamicGroupRule {
    <#
    .SYNOPSIS
        Simulates a dynamic group membership rule against many users at once.

    .DESCRIPTION
        Microsoft Entra's own "Validate rules" tab only checks up to 20 users/devices
        per run. This function evaluates a rule against an arbitrary number of user
        objects (e.g. your whole tenant) locally, so you can answer "who would join or
        leave this group if I change the rule this way" before saving anything.

        Supports the common comparison operators and a best-effort '-any(...)' handling.
        Does NOT support: direct-reports rules, the memberOf (preview) operator, or
        employeeHireDate date-math against system.now - such leaves raise a clear error
        instead of a silently wrong result.

    .PARAMETER Rule
        The raw dynamic membership rule string to test.

    .PARAMETER Users
        An array of user objects ([pscustomobject] or hashtable). Property names must
        match the Graph attribute names used in the rule (department, jobTitle,
        otherMails, employeeId, ...), case-insensitive. Typically produced with:
          Get-MgUser -All -Property Id,DisplayName,Department,JobTitle,UserType,Country

    .PARAMETER PassThru
        Return the original user objects that match the rule (with all their
        properties), instead of the full pass/fail table.

    .EXAMPLE
        $users = Get-MgUser -All -Property Id,DisplayName,Department,Country
        Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -and (user.country -eq "DE")' -Users $users
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Rule,
        [Parameter(Mandatory)] [object[]] $Users,
        [switch] $PassThru
    )

    $tree = ConvertFrom-EGIRuleString -Rule $Rule
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $matched = [System.Collections.Generic.List[object]]::new()
    $errorCount = 0

    foreach ($user in $Users) {
        $id = Get-EGIUserProperty -Obj $user -Name 'Id'
        $displayName = Get-EGIUserProperty -Obj $user -Name 'DisplayName'

        try {
            $match = if (Test-EGIRuleTreeNode -Node $tree -User $user) { $true } else { $false }
            if ($match) { $matched.Add($user) }
            $results.Add([pscustomobject]@{
                    Id          = $id
                    DisplayName = $displayName
                    Matches     = $match
                    Error       = $null
                })
        }
        catch {
            $errorCount++
            $results.Add([pscustomobject]@{
                    Id          = $id
                    DisplayName = $displayName
                    Matches     = $null
                    Error       = $_.Exception.Message
                })
        }
    }

    if ($errorCount -gt 0) {
        Write-Warning "$errorCount of $($Users.Count) user(s) could not be evaluated - see the Error column (unsupported rule constructs)."
    }

    if ($PassThru) {
        return $matched.ToArray()
    }
    return $results
}
