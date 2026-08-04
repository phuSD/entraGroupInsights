function Export-EGIGroupBlastRadiusSvg {
    <#
    .SYNOPSIS
        Renders a Get-EGIGroupBlastRadius result as a standalone SVG relationship diagram.

    .DESCRIPTION
        Draws the group as a hub node in the center-left, and every downstream
        dependency (Conditional Access policies, license SKUs, app role
        assignments, PIM eligibility, structural parent/child group nesting,
        groups referenced by this group's memberOf rule clause, and other
        dynamic groups that reference this group the same way) as spoke
        nodes grouped into color-coded columns, connected back to the hub
        with curved lines. Conditional Access, license, and app role entries
        inherited through a parent group (rather than referencing this group
        directly) are labeled with where they actually come from, e.g.
        "(Nested via 'Contoso-EU')".

        If the blast radius object carries a dynamic group's MembershipRule,
        it is drawn as its own box wired to the hub, so the diagram shows not
        just what depends on the group but why members end up in it.

        Passing -ExampleUser (or -ExampleUserId) additionally draws a sample
        user node wired to the hub, evaluated against the membership rule
        (via Test-EGIRuleTreeNode) and colored green/red depending on
        whether that user would match - a concrete "would this person be a
        member" illustration next to the abstract rule text.

        The output is a plain, self-contained .svg file - no external tools or
        libraries required. Open it directly in a browser, embed it in a wiki
        page, or attach it to a change-ticket as evidence of the blast radius
        before a rule change.

        Renders exactly one blast radius per call: piping several objects into
        a single -Path raises an error instead of silently keeping only the last.

    .PARAMETER BlastRadius
        A result object from Get-EGIGroupBlastRadius.

    .PARAMETER Path
        Output file path, e.g. './reports/sales-de-blast-radius.svg'.

    .PARAMETER ExampleUser
        Optional sample user object ([pscustomobject] or hashtable, e.g. from
        Get-MgUser) drawn as its own node and checked against
        $BlastRadius.MembershipRule to illustrate whether that user would be
        a member. Property names must match the Graph attribute names used in
        the rule (department, jobTitle, country, ...), case-insensitive.
        Mutually exclusive with -ExampleUserId.

    .PARAMETER ExampleUserId
        Object ID or userPrincipalName of a real user to look up via
        Microsoft Graph (Connect-MgGraph, at least User.Read.All) and draw
        the same way as -ExampleUser. Only the properties referenced by
        $BlastRadius.MembershipRule (plus id/displayName) are requested, so
        the rule decides what gets fetched. Mutually exclusive with
        -ExampleUser.

    .EXAMPLE
        Get-EGIGroupBlastRadius -GroupId $id | Export-EGIGroupBlastRadiusSvg -Path './report.svg'

    .EXAMPLE
        $exampleUser = [pscustomobject]@{ DisplayName = 'Alice Nguyen'; department = 'Sales'; country = 'DE' }
        Get-EGIGroupBlastRadius -GroupId $id |
            Export-EGIGroupBlastRadiusSvg -Path './report.svg' -ExampleUser $exampleUser

    .EXAMPLE
        Get-EGIGroupBlastRadius -GroupId $id |
            Export-EGIGroupBlastRadiusSvg -Path './report.svg' -ExampleUserId 'alice.nguyen@contoso.com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject] $BlastRadius,

        [Parameter(Mandatory)]
        [string] $Path,

        [object] $ExampleUser,

        [string] $ExampleUserId
    )

    begin {
        $received = [System.Collections.Generic.List[object]]::new()
    }

    process {
        $received.Add($BlastRadius)
    }

    end {
        if ($received.Count -gt 1) {
            throw "Export-EGIGroupBlastRadiusSvg received $($received.Count) blast-radius objects, but -Path '$Path' names a single file. Export one group per call (loop and vary -Path for multiple groups)."
        }
        $BlastRadius = $received[0]

        if ($ExampleUser -and $ExampleUserId) {
            throw "Specify either -ExampleUser or -ExampleUserId, not both."
        }

        if ($ExampleUserId) {
            $selectProps = [System.Collections.Generic.List[string]]::new()
            $selectProps.Add('id')
            $selectProps.Add('displayName')
            if (-not [string]::IsNullOrWhiteSpace($BlastRadius.MembershipRule)) {
                foreach ($m in [regex]::Matches($BlastRadius.MembershipRule, '(?<!\w)user\.([A-Za-z_][A-Za-z0-9_]*)', 'IgnoreCase')) {
                    $propName = $m.Groups[1].Value
                    if ($selectProps -notcontains $propName) { $selectProps.Add($propName) }
                }
            }
            try {
                $ExampleUser = Invoke-MgGraphRequest -Method GET `
                    -Uri "https://graph.microsoft.com/v1.0/users/$ExampleUserId`?`$select=$($selectProps -join ',')"
            }
            catch {
                throw "Could not fetch example user '$ExampleUserId' from Microsoft Graph: $($_.Exception.Message)"
            }
        }

        # ---- Build the category list ---------------------------------------
        function Format-EGISourceSuffix {
            param([string] $Source)
            if ($Source -and $Source -ne 'Direct') { return '  ' + ($Source -replace '^Nested ', '') }
            return ''
        }

        $categories = @(
            [pscustomobject]@{
                Name  = 'Conditional Access'
                Color = '#2563eb'
                Items = @($BlastRadius.ConditionalAccessPolicies | ForEach-Object {
                        "$($_.DisplayName)  [$($_.Reference) / $($_.State)]$(Format-EGISourceSuffix $_.Source)"
                    })
            }
            [pscustomobject]@{
                Name  = 'Licenses'
                Color = '#16a34a'
                Items = @($BlastRadius.AssignedLicenses | ForEach-Object {
                        "$($_.SkuId)$(Format-EGISourceSuffix $_.Source)"
                    })
            }
            [pscustomobject]@{
                Name  = 'App role assignments'
                Color = '#d97706'
                Items = @($BlastRadius.AppRoleAssignments | ForEach-Object {
                        "$($_.resourceDisplayName)$(Format-EGISourceSuffix $_.Source)"
                    })
            }
            [pscustomobject]@{
                Name  = 'PIM eligibility'
                Color = '#dc2626'
                Items = @(if ($BlastRadius.PimEligibleRoleCount -gt 0) {
                        "$($BlastRadius.PimEligibleRoleCount) eligible role assignment(s)"
                    })
            }
            [pscustomobject]@{
                Name  = 'Nested in (parent groups)'
                Color = '#7c3aed'
                Items = @($BlastRadius.ParentGroups | ForEach-Object { $_.displayName })
            }
            [pscustomobject]@{
                Name  = 'Contains (nested groups)'
                Color = '#0891b2'
                Items = @($BlastRadius.ChildGroups | ForEach-Object { $_.displayName })
            }
            [pscustomobject]@{
                Name  = 'Rule references (memberOf)'
                Color = '#be185d'
                Items = @($BlastRadius.RuleReferencedGroups | ForEach-Object { $_.displayName })
            }
            [pscustomobject]@{
                Name  = 'Referenced by (memberOf)'
                Color = '#c026d3'
                Items = @($BlastRadius.RuleReferencedByGroups | ForEach-Object { $_.displayName })
            }
        )

        # ---- Layout constants ------------------------------------------------
        $colWidth   = 300
        $colGap     = 60
        $itemHeight = 34
        $itemGap    = 10
        $topMargin  = 60
        $hubWidth   = 220
        $hubHeight  = 70
        $hubX       = 20
        $stackGap   = 20

        $colX = @(0..($categories.Count - 1)) | ForEach-Object { 340 + $_ * ($colWidth + $colGap) }

        $maxItemsInAnyColumn = ($categories | ForEach-Object { [Math]::Max($_.Items.Count, 1) } | Measure-Object -Maximum).Maximum
        $width = 340 + ($categories.Count * ($colWidth + $colGap))

        function ConvertTo-SafeXml {
            param([string] $Text)
            if ($null -eq $Text) { return '' }
            return [System.Security.SecurityElement]::Escape($Text)
        }

        function Get-EGIWrappedLines {
            param([string] $Text, [int] $MaxCharsPerLine = 40, [int] $MaxLines = 6)
            $words = $Text -split '\s+'
            $lines = [System.Collections.Generic.List[string]]::new()
            $current = ''
            foreach ($word in $words) {
                $candidate = if ($current) { "$current $word" } else { $word }
                if ($candidate.Length -gt $MaxCharsPerLine -and $current) {
                    $lines.Add($current)
                    $current = $word
                }
                else {
                    $current = $candidate
                }
            }
            if ($current) { $lines.Add($current) }
            if ($lines.Count -gt $MaxLines) {
                $lines = $lines[0..($MaxLines - 1)]
                $lines[$MaxLines - 1] = $lines[$MaxLines - 1] + ' ...'
            }
            return $lines
        }

        # ---- Membership rule box (below the hub) ------------------------------
        $ruleLines = @()
        if (-not [string]::IsNullOrWhiteSpace($BlastRadius.MembershipRule)) {
            $ruleLines = @(Get-EGIWrappedLines -Text $BlastRadius.MembershipRule)
        }
        $ruleBoxWidth  = 300
        $ruleLineHeight = 16
        $ruleBoxHeight = if ($ruleLines.Count -gt 0) { 34 + ($ruleLines.Count * $ruleLineHeight) } else { 0 }

        # ---- Example user box (above the hub) ---------------------------------
        $exampleName      = $null
        $examplePropLines = @()
        $exampleMatches   = $null
        $exampleError     = $null
        if ($ExampleUser) {
            $exampleName = Get-EGIUserProperty -Obj $ExampleUser -Name 'DisplayName'
            if ([string]::IsNullOrWhiteSpace($exampleName)) { $exampleName = 'Example user' }

            $propNames = if ($ExampleUser -is [System.Collections.IDictionary]) { @($ExampleUser.Keys) } else { @($ExampleUser.PSObject.Properties.Name) }
            $propNames = @($propNames | Where-Object { $_ -notin @('Id', 'DisplayName') } | Select-Object -First 3)
            $examplePropLines = @(foreach ($p in $propNames) { "$p`: $(Get-EGIUserProperty -Obj $ExampleUser -Name $p)" })

            if (-not [string]::IsNullOrWhiteSpace($BlastRadius.MembershipRule)) {
                try {
                    $exampleTree = ConvertFrom-EGIRuleString -Rule $BlastRadius.MembershipRule
                    $exampleMatches = [bool](Test-EGIRuleTreeNode -Node $exampleTree -User $ExampleUser)
                }
                catch {
                    $exampleError = $_.Exception.Message
                }
            }
        }
        $userBoxWidth  = 220
        $userBoxHeight = if ($ExampleUser) { 40 + ($examplePropLines.Count * 15) + 20 } else { 0 }

        # ---- Overall canvas + vertical hub/rule/user stack --------------------
        $leftStackHeight = $hubHeight
        if ($ExampleUser) { $leftStackHeight += $userBoxHeight + $stackGap }
        if ($ruleBoxHeight -gt 0) { $leftStackHeight += $ruleBoxHeight + $stackGap }

        $height = [Math]::Max(
            [Math]::Max(($maxItemsInAnyColumn * ($itemHeight + $itemGap)) + $topMargin + 80, 260),
            $leftStackHeight + $topMargin + 40
        )

        $stackStartY = [Math]::Max(60, [Math]::Round(($height - $leftStackHeight) / 2))
        $cursorY = $stackStartY
        $userBoxY = $cursorY
        if ($ExampleUser) { $cursorY += $userBoxHeight + $stackGap }
        $hubY = $cursorY
        $cursorY += $hubHeight + $stackGap
        $ruleBoxY = $cursorY

        $hubCenterY = $hubY + ($hubHeight / 2)
        $hubRightEdgeX = $hubX + $hubWidth

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"0 0 $width $height`" font-family=`"Segoe UI, Arial, sans-serif`">")
        [void]$sb.AppendLine("<rect x=`"0`" y=`"0`" width=`"$width`" height=`"$height`" fill=`"#ffffff`"/>")

        # Title + risk badge
        $title = ConvertTo-SafeXml "Blast radius: $($BlastRadius.DisplayName)"
        [void]$sb.AppendLine("<text x=`"20`" y=`"28`" font-size=`"18`" font-weight=`"600`" fill=`"#111827`">$title</text>")
        $riskColor = switch ($BlastRadius.RiskLevel) {
            'Critical' { '#dc2626' }
            'High'     { '#d97706' }
            'Medium'   { '#ca8a04' }
            'Low'      { '#16a34a' }
            default    { '#6b7280' }
        }
        [void]$sb.AppendLine("<text x=`"20`" y=`"48`" font-size=`"13`" fill=`"$riskColor`" font-weight=`"600`">Risk: $($BlastRadius.RiskLevel)  |  Total dependencies: $($BlastRadius.TotalDependencyCount)</text>")

        # Hub node (the group itself)
        [void]$sb.AppendLine("<rect x=`"$hubX`" y=`"$hubY`" width=`"$hubWidth`" height=`"$hubHeight`" rx=`"10`" fill=`"#eef2ff`" stroke=`"#4338ca`" stroke-width=`"1.5`"/>")
        [void]$sb.AppendLine("<text x=`"$($hubX + $hubWidth/2)`" y=`"$($hubY + $hubHeight/2 - 4)`" text-anchor=`"middle`" font-size=`"13`" font-weight=`"600`" fill=`"#312e81`">$(ConvertTo-SafeXml $BlastRadius.DisplayName)</text>")
        [void]$sb.AppendLine("<text x=`"$($hubX + $hubWidth/2)`" y=`"$($hubY + $hubHeight/2 + 16)`" text-anchor=`"middle`" font-size=`"11`" fill=`"#4338ca`">Dynamic group</text>")

        # Membership rule box (below the hub)
        if ($ruleBoxHeight -gt 0) {
            $hubBottomCenterX = $hubX + $hubWidth / 2
            [void]$sb.AppendLine("<path d=`"M $hubBottomCenterX $($hubY + $hubHeight) L $hubBottomCenterX $ruleBoxY`" fill=`"none`" stroke=`"#b45309`" stroke-width=`"1.5`"/>")
            [void]$sb.AppendLine("<rect x=`"$hubX`" y=`"$ruleBoxY`" width=`"$ruleBoxWidth`" height=`"$ruleBoxHeight`" rx=`"8`" fill=`"#fffbeb`" stroke=`"#b45309`" stroke-width=`"1.5`"/>")
            $ruleTextX = $hubX + 12
            $ruleTextY = $ruleBoxY + 20
            [void]$sb.AppendLine("<text x=`"$ruleTextX`" y=`"$ruleTextY`" font-size=`"12`" font-weight=`"600`" fill=`"#92400e`">Membership rule</text>")
            $ruleTextY += 18
            foreach ($line in $ruleLines) {
                [void]$sb.AppendLine("<text x=`"$ruleTextX`" y=`"$ruleTextY`" font-size=`"11`" font-family=`"Consolas, monospace`" fill=`"#78350f`">$(ConvertTo-SafeXml $line)</text>")
                $ruleTextY += $ruleLineHeight
            }
        }

        # Example user node (above the hub), checked against the membership rule
        if ($ExampleUser) {
            $userColor = if ($exampleError) { '#6b7280' } elseif ($exampleMatches -eq $true) { '#16a34a' } elseif ($exampleMatches -eq $false) { '#dc2626' } else { '#6b7280' }
            $userFill = if ($exampleError) { '#f9fafb' } elseif ($exampleMatches -eq $true) { '#f0fdf4' } elseif ($exampleMatches -eq $false) { '#fef2f2' } else { '#f9fafb' }
            $userCenterX = $hubX + $userBoxWidth / 2

            [void]$sb.AppendLine("<rect x=`"$hubX`" y=`"$userBoxY`" width=`"$userBoxWidth`" height=`"$userBoxHeight`" rx=`"10`" fill=`"$userFill`" stroke=`"$userColor`" stroke-width=`"1.5`"/>")
            $nameY = $userBoxY + 20
            [void]$sb.AppendLine("<text x=`"$userCenterX`" y=`"$nameY`" text-anchor=`"middle`" font-size=`"13`" font-weight=`"600`" fill=`"#111827`">$(ConvertTo-SafeXml $exampleName)</text>")
            $propTextY = $nameY + 17
            foreach ($line in $examplePropLines) {
                [void]$sb.AppendLine("<text x=`"$userCenterX`" y=`"$propTextY`" text-anchor=`"middle`" font-size=`"11`" fill=`"#374151`">$(ConvertTo-SafeXml $line)</text>")
                $propTextY += 15
            }
            $verdict = if ($exampleError) { "Rule error: $exampleError" } elseif ($exampleMatches -eq $true) { 'Matches rule' } elseif ($exampleMatches -eq $false) { 'Does not match rule' } else { 'Example user' }
            [void]$sb.AppendLine("<text x=`"$userCenterX`" y=`"$($userBoxY + $userBoxHeight - 8)`" text-anchor=`"middle`" font-size=`"11`" font-weight=`"600`" fill=`"$userColor`">$(ConvertTo-SafeXml $verdict)</text>")

            [void]$sb.AppendLine("<path d=`"M $userCenterX $($userBoxY + $userBoxHeight) L $userCenterX $hubY`" fill=`"none`" stroke=`"$userColor`" stroke-width=`"1.5`" stroke-dasharray=`"4,3`"/>")
        }

        for ($c = 0; $c -lt $categories.Count; $c++) {
            $cat = $categories[$c]
            $x = $colX[$c]

            [void]$sb.AppendLine("<text x=`"$x`" y=`"$($topMargin - 20)`" font-size=`"13`" font-weight=`"600`" fill=`"$($cat.Color)`">$(ConvertTo-SafeXml $cat.Name) ($($cat.Items.Count))</text>")

            if ($cat.Items.Count -eq 0) {
                [void]$sb.AppendLine("<text x=`"$x`" y=`"$topMargin`" font-size=`"12`" fill=`"#9ca3af`">(none)</text>")
                continue
            }

            for ($r = 0; $r -lt $cat.Items.Count; $r++) {
                $y = $topMargin + $r * ($itemHeight + $itemGap)
                $labelRaw = [string]$cat.Items[$r]
                if ($labelRaw.Length -gt 40) { $labelRaw = $labelRaw.Substring(0, 37) + '...' }
                $label = ConvertTo-SafeXml $labelRaw

                $itemCenterY = $y + ($itemHeight / 2)
                $ctrlX = ($hubRightEdgeX + $x) / 2

                [void]$sb.AppendLine("<path d=`"M $hubRightEdgeX $hubCenterY Q $ctrlX $itemCenterY $x $itemCenterY`" fill=`"none`" stroke=`"$($cat.Color)`" stroke-width=`"1`" opacity=`"0.45`"/>")
                [void]$sb.AppendLine("<rect x=`"$x`" y=`"$y`" width=`"$colWidth`" height=`"$itemHeight`" rx=`"6`" fill=`"#ffffff`" stroke=`"$($cat.Color)`" stroke-width=`"1`"/>")
                [void]$sb.AppendLine("<text x=`"$($x + 10)`" y=`"$($itemCenterY + 4)`" font-size=`"12`" fill=`"#111827`">$label</text>")
            }
        }

        [void]$sb.AppendLine('</svg>')

        # BOM-less UTF-8 on every PowerShell edition (5.1's Set-Content writes a BOM).
        $resolvedPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        [System.IO.File]::WriteAllText($resolvedPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
        Write-Verbose "Wrote blast-radius SVG report to $Path"
        return (Get-Item -LiteralPath $resolvedPath)
    }
}
