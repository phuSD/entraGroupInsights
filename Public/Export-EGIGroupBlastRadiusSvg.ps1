function Export-EGIGroupBlastRadiusSvg {
    <#
    .SYNOPSIS
        Renders a Get-EGIGroupBlastRadius result as a standalone SVG relationship diagram.

    .DESCRIPTION
        Draws the group as a hub node in the center-left, and every downstream
        dependency (Conditional Access policies, license SKUs, app role
        assignments, PIM eligibility) as spoke nodes grouped into color-coded
        columns, connected back to the hub with curved lines.

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

    .EXAMPLE
        Get-EGIGroupBlastRadius -GroupId $id | Export-EGIGroupBlastRadiusSvg -Path './report.svg'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject] $BlastRadius,

        [Parameter(Mandatory)]
        [string] $Path
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

        # ---- Build the category list ---------------------------------------
        $categories = @(
            [pscustomobject]@{
                Name  = 'Conditional Access'
                Color = '#2563eb'
                Items = @($BlastRadius.ConditionalAccessPolicies | ForEach-Object {
                        "$($_.DisplayName)  [$($_.Reference) / $($_.State)]"
                    })
            }
            [pscustomobject]@{
                Name  = 'Licenses'
                Color = '#16a34a'
                Items = @($BlastRadius.AssignedLicenseSkuIds)
            }
            [pscustomobject]@{
                Name  = 'App role assignments'
                Color = '#d97706'
                Items = @($BlastRadius.AppRoleAssignments | ForEach-Object { $_.resourceDisplayName })
            }
            [pscustomobject]@{
                Name  = 'PIM eligibility'
                Color = '#dc2626'
                Items = @(if ($BlastRadius.PimEligibleRoleCount -gt 0) {
                        "$($BlastRadius.PimEligibleRoleCount) eligible role assignment(s)"
                    })
            }
        )

        # ---- Layout constants ------------------------------------------------
        $colWidth   = 260
        $colGap     = 60
        $itemHeight = 34
        $itemGap    = 10
        $topMargin  = 60
        $hubWidth   = 220
        $hubHeight  = 70

        $colX = @(0..3) | ForEach-Object { 340 + $_ * ($colWidth + $colGap) }

        $maxItemsInAnyColumn = ($categories | ForEach-Object { [Math]::Max($_.Items.Count, 1) } | Measure-Object -Maximum).Maximum
        $height = [Math]::Max(($maxItemsInAnyColumn * ($itemHeight + $itemGap)) + $topMargin + 80, 260)
        $width = 340 + (4 * ($colWidth + $colGap))

        $hubY = [Math]::Round($height / 2 - $hubHeight / 2)
        $hubX = 20
        $hubCenterY = $hubY + ($hubHeight / 2)
        $hubRightEdgeX = $hubX + $hubWidth

        function ConvertTo-SafeXml {
            param([string] $Text)
            if ($null -eq $Text) { return '' }
            return [System.Security.SecurityElement]::Escape($Text)
        }

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
                if ($labelRaw.Length -gt 34) { $labelRaw = $labelRaw.Substring(0, 31) + '...' }
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
