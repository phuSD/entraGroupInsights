function Test-EGIRuleTreeNode {
    <#
    .SYNOPSIS
        Recursively evaluates a rule tree node (from ConvertFrom-EGIRuleString) against a user.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Node,
        [Parameter(Mandatory)] $User
    )

    switch ($Node.Type) {
        'Leaf' { return Test-EGILeafExpression -Expression $Node.Expression -User $User }
        'Not' { return -not (Test-EGIRuleTreeNode -Node $Node.Child -User $User) }
        'And' {
            foreach ($child in $Node.Children) {
                if (-not (Test-EGIRuleTreeNode -Node $child -User $User)) { return $false }
            }
            return $true
        }
        'Or' {
            foreach ($child in $Node.Children) {
                if (Test-EGIRuleTreeNode -Node $child -User $User) { return $true }
            }
            return $false
        }
        default { throw "Unknown node type '$($Node.Type)'." }
    }
}
