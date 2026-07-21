function ConvertTo-EGIRuleTreeText {
    <#
    .SYNOPSIS
        Renders a rule tree (from ConvertFrom-EGIRuleString) as an indented ASCII tree.

    .PARAMETER Node
        The tree node to render.

    .PARAMETER Indent
        Internal recursion parameter, do not set manually.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Node,

        [int] $Indent = 0
    )

    $pad = '  ' * $Indent
    $lines = [System.Collections.Generic.List[string]]::new()

    switch ($Node.Type) {
        'Leaf' {
            $lines.Add("$pad- $($Node.Expression)")
        }
        'Not' {
            $lines.Add("$pad-NOT")
            $lines.Add((ConvertTo-EGIRuleTreeText -Node $Node.Child -Indent ($Indent + 1)))
        }
        'And' {
            $lines.Add("$pad-AND")
            foreach ($child in $Node.Children) {
                $lines.Add((ConvertTo-EGIRuleTreeText -Node $child -Indent ($Indent + 1)))
            }
        }
        'Or' {
            $lines.Add("$pad-OR")
            foreach ($child in $Node.Children) {
                $lines.Add((ConvertTo-EGIRuleTreeText -Node $child -Indent ($Indent + 1)))
            }
        }
        default {
            $lines.Add("$pad? unknown node type: $($Node.Type)")
        }
    }

    return ($lines -join "`n")
}
