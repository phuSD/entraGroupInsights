function Compare-EGIGroupSnapshot {
    <#
    .SYNOPSIS
        Diffs two snapshots produced by Export-EGIGroupSnapshot.

    .DESCRIPTION
        Shows which dynamic groups were added, removed, or had their membership
        rule (or processing state) changed between two points in time - e.g. two
        Git commits of your snapshot file, or "yesterday" vs "today".

    .PARAMETER ReferencePath
        Path to the older/baseline snapshot JSON file.

    .PARAMETER DifferencePath
        Path to the newer snapshot JSON file.

    .EXAMPLE
        Compare-EGIGroupSnapshot -ReferencePath './snapshots/2026-07-20.json' -DifferencePath './snapshots/2026-07-21.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ReferencePath,
        [Parameter(Mandatory)] [string] $DifferencePath
    )

    $ref = (Get-Content -Path $ReferencePath -Raw | ConvertFrom-Json).Groups
    $diff = (Get-Content -Path $DifferencePath -Raw | ConvertFrom-Json).Groups

    $refById = @{}
    foreach ($g in $ref) { $refById[$g.GroupId] = $g }
    $diffById = @{}
    foreach ($g in $diff) { $diffById[$g.GroupId] = $g }

    $added = foreach ($id in $diffById.Keys) {
        if (-not $refById.ContainsKey($id)) {
            [pscustomobject]@{ ChangeType = 'Added'; GroupId = $id; DisplayName = $diffById[$id].DisplayName; NewRule = $diffById[$id].MembershipRule }
        }
    }

    $removed = foreach ($id in $refById.Keys) {
        if (-not $diffById.ContainsKey($id)) {
            [pscustomobject]@{ ChangeType = 'Removed'; GroupId = $id; DisplayName = $refById[$id].DisplayName; OldRule = $refById[$id].MembershipRule }
        }
    }

    $changed = foreach ($id in $diffById.Keys) {
        if ($refById.ContainsKey($id)) {
            $old = $refById[$id]
            $new = $diffById[$id]
            if ($old.MembershipRule -ne $new.MembershipRule -or $old.ProcessingState -ne $new.ProcessingState) {
                [pscustomobject]@{
                    ChangeType      = 'RuleChanged'
                    GroupId         = $id
                    DisplayName     = $new.DisplayName
                    OldRule         = $old.MembershipRule
                    NewRule         = $new.MembershipRule
                    OldState        = $old.ProcessingState
                    NewState        = $new.ProcessingState
                }
            }
        }
    }

    [pscustomobject]@{
        Added   = @($added)
        Removed = @($removed)
        Changed = @($changed)
        Summary = "{0} added, {1} removed, {2} changed" -f @($added).Count, @($removed).Count, @($changed).Count
    }
}
