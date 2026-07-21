# Compiled-leaf cache: leaf expressions are identical for every user in a run,
# so each unique expression is parsed once and the compiled form is reused.
$script:EGILeafCache = @{}

function Get-EGIUserProperty {
    <#
    .SYNOPSIS
        Case-insensitive property lookup on a user object ([pscustomobject] or hashtable).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Obj,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) { if ($k -ieq $Name) { return $Obj[$k] } }
        return $null
    }
    $p = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($p) { return $p.Value } else { return $null }
}

function ConvertFrom-EGILiteral {
    <#
    .SYNOPSIS
        Converts a rule literal ('"Sales"', 'true', '["A", "B"]', '42') to a .NET value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text)

    $t = $Text.Trim()
    if ($t -ieq 'null') { return $null }
    if ($t -ieq 'true') { return $true }
    if ($t -ieq 'false') { return $false }
    if ($t -match '^\[(.*)\]$') {
        $inner = $Matches[1]
        # Split on commas, but keep quoted values intact so "R, D" stays one item.
        $values = foreach ($m in [regex]::Matches($inner, '"([^"]*)"|''([^'']*)''|([^,\s"''][^,]*)')) {
            if ($m.Groups[1].Success) { $m.Groups[1].Value -replace '`"', '"' }
            elseif ($m.Groups[2].Success) { $m.Groups[2].Value }
            else { $m.Groups[3].Value.Trim() }
        }
        return @($values)
    }
    if ($t -match '^"(.*)"$' -or $t -match "^'(.*)'$") {
        return ($Matches[1] -replace '`"', '"')
    }
    if ($t -match '^-?\d+(\.\d+)?$') { return [double]$t }
    return $t
}

function Invoke-EGIOperator {
    <#
    .SYNOPSIS
        Applies one comparison operator. Wildcard metacharacters in the value
        (* ? [ ]) are escaped so -startsWith/-endsWith/-contains stay literal
        substring comparisons, matching Entra semantics.
    #>
    [CmdletBinding()]
    param($Left, [Parameter(Mandatory)] [string] $Op, $Right, [string] $Expression)

    $opName = $Op.TrimStart('-').ToLowerInvariant()
    $escaped = [System.Management.Automation.WildcardPattern]::Escape("$Right")
    switch ($opName) {
        'eq' { return $Left -eq $Right }
        'ne' { return $Left -ne $Right }
        'startswith' { return ($null -ne $Left) -and ("$Left" -like "$escaped*") }
        'notstartswith' { return -not (($null -ne $Left) -and ("$Left" -like "$escaped*")) }
        'endswith' { return ($null -ne $Left) -and ("$Left" -like "*$escaped") }
        'notendswith' { return -not (($null -ne $Left) -and ("$Left" -like "*$escaped")) }
        'contains' { return ($null -ne $Left) -and ("$Left" -like "*$escaped*") }
        'notcontains' { return -not (($null -ne $Left) -and ("$Left" -like "*$escaped*")) }
        'match' { return ($null -ne $Left) -and ("$Left" -match "$Right") }
        'notmatch' { return -not (($null -ne $Left) -and ("$Left" -match "$Right")) }
        'in' { return $Right -contains $Left }
        'notin' { return -not ($Right -contains $Left) }
        default { throw "Unsupported operator '$Op' in leaf '$Expression'." }
    }
}

function ConvertTo-EGICompiledLeaf {
    <#
    .SYNOPSIS
        Parses a leaf expression once into a reusable form; results are cached
        per expression string so bulk simulation doesn't re-parse per user.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Expression)

    if ($script:EGILeafCache.ContainsKey($Expression)) { return $script:EGILeafCache[$Expression] }

    $supportedOps = @('eq', 'ne', 'startswith', 'notstartswith', 'endswith', 'notendswith',
        'contains', 'notcontains', 'match', 'notmatch', 'in', 'notin')

    $leaf =
    if ($Expression -match '(?i)^Direct Reports for') {
        @{ Kind = 'Unsupported'; Message = "Leaf '$Expression' uses the direct-reports rule, which this prototype does not simulate." }
    }
    elseif ($Expression -match '(?i)\bmemberOf\b') {
        @{ Kind = 'Unsupported'; Message = "Leaf '$Expression' uses the (preview) memberOf operator, which this prototype does not simulate." }
    }
    elseif ($Expression -match '(?i)system\.now') {
        @{ Kind = 'Unsupported'; Message = "Leaf '$Expression' uses date-math against system.now, which this prototype does not simulate." }
    }
    # '-any (_ -op value)' over a collection property.
    elseif ($Expression -match '(?i)^user\.([A-Za-z0-9_]+)\s+-any\s*\(\s*_\s+(-\S+)\s+(.+)\)\s*$') {
        @{ Kind = 'Any'; Property = $Matches[1]; Operator = $Matches[2]; Value = (ConvertFrom-EGILiteral -Text $Matches[3]) }
    }
    # Simple single-property comparison: user.<prop> <op> <value>
    elseif ($Expression -match '(?i)^user\.([A-Za-z0-9_]+)\s+(-\S+)\s+(.+)$') {
        @{ Kind = 'Simple'; Property = $Matches[1]; Operator = $Matches[2]; Value = (ConvertFrom-EGILiteral -Text $Matches[3]) }
    }
    else {
        @{ Kind = 'Unsupported'; Message = "Could not parse leaf expression: '$Expression'." }
    }

    if ($leaf.Kind -ne 'Unsupported' -and $supportedOps -notcontains $leaf.Operator.TrimStart('-').ToLowerInvariant()) {
        $leaf = @{ Kind = 'Unsupported'; Message = "Unsupported operator '$($leaf.Operator)' in leaf '$Expression'." }
    }

    $script:EGILeafCache[$Expression] = $leaf
    return $leaf
}

function Test-EGILeafExpression {
    <#
    .SYNOPSIS
        Evaluates one leaf expression (e.g. 'user.department -eq "Sales"') against a user object.

    .DESCRIPTION
        Supports the common single-property comparison operators (-eq, -ne, -startsWith,
        -notStartsWith, -endsWith, -notEndsWith, -contains, -notContains, -match, -notMatch,
        -in, -notIn) plus a best-effort handling of '-any (_ -op value)' over collection
        properties such as otherMails / proxyAddresses. Extension attribute properties
        (user.extension_<appId>_<name>) are supported like any other string property.

        NOT SUPPORTED in this v0.1 prototype (throws a descriptive error so callers can
        skip/flag the rule instead of silently returning a wrong result):
          - 'Direct Reports for "<objectId>"' rules
          - the memberOf (preview) operator
          - employeeHireDate date-math expressions (system.now -plus/-minus)

    .PARAMETER Expression
        The raw leaf text, e.g. 'user.department -eq "Sales"'.

    .PARAMETER User
        A [pscustomobject]/hashtable representing the user, with properties named
        after the Graph user attributes (department, jobTitle, otherMails, ...).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Expression,
        [Parameter(Mandatory)] $User
    )

    $leaf = ConvertTo-EGICompiledLeaf -Expression $Expression

    switch ($leaf.Kind) {
        'Unsupported' { throw $leaf.Message }
        'Any' {
            $collection = @(Get-EGIUserProperty -Obj $User -Name $leaf.Property)
            foreach ($item in $collection) {
                if (Invoke-EGIOperator -Left $item -Op $leaf.Operator -Right $leaf.Value -Expression $Expression) { return $true }
            }
            return $false
        }
        'Simple' {
            $left = Get-EGIUserProperty -Obj $User -Name $leaf.Property
            return (Invoke-EGIOperator -Left $left -Op $leaf.Operator -Right $leaf.Value -Expression $Expression)
        }
    }
}
