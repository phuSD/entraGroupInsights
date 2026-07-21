function Test-EGILeafExpression {
    <#
    .SYNOPSIS
        Evaluates one leaf expression (e.g. 'user.department -eq "Sales"') against a user object.

    .DESCRIPTION
        Supports the common single-property comparison operators (-eq, -ne, -startsWith,
        -notStartsWith, -endsWith, -notEndsWith, -contains, -notContains, -match, -notMatch,
        -in, -notIn) plus a best-effort handling of '-any (_ -op value)' over collection
        properties such as otherMails / proxyAddresses.

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

    if ($Expression -match '(?i)^Direct Reports for') {
        throw "Leaf '$Expression' uses the direct-reports rule, which this prototype does not simulate."
    }
    if ($Expression -match '(?i)\bmemberOf\b') {
        throw "Leaf '$Expression' uses the (preview) memberOf operator, which this prototype does not simulate."
    }
    if ($Expression -match '(?i)system\.now') {
        throw "Leaf '$Expression' uses date-math against system.now, which this prototype does not simulate."
    }

    function Get-Prop {
        param($Obj, [string]$Name)
        if ($Obj -is [System.Collections.IDictionary]) {
            foreach ($k in $Obj.Keys) { if ($k -ieq $Name) { return $Obj[$k] } }
            return $null
        }
        $p = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($p) { return $p.Value } else { return $null }
    }

    function ConvertFrom-EGILiteral {
        param([string] $Text)
        $t = $Text.Trim()
        if ($t -ieq 'null') { return $null }
        if ($t -ieq 'true') { return $true }
        if ($t -ieq 'false') { return $false }
        if ($t -match '^\[(.*)\]$') {
            $inner = $Matches[1]
            return ($inner -split ',') | ForEach-Object {
                $v = $_.Trim().Trim('"', "'")
                $v -replace '``"', '"'
            }
        }
        if ($t -match '^"(.*)"$' -or $t -match "^'(.*)'$") {
            return ($Matches[1] -replace '``"', '"')
        }
        if ($t -match '^-?\d+(\.\d+)?$') { return [double]$t }
        return $t
    }

    function Invoke-EGIOperator {
        param($Left, [string] $Op, $Right)
        $op = $Op.TrimStart('-').ToLowerInvariant()
        switch ($op) {
            'eq' { return $Left -eq $Right }
            'ne' { return $Left -ne $Right }
            'startswith' { return ($null -ne $Left) -and ("$Left" -like "$Right*") }
            'notstartswith' { return -not (($null -ne $Left) -and ("$Left" -like "$Right*")) }
            'endswith' { return ($null -ne $Left) -and ("$Left" -like "*$Right") }
            'notendswith' { return -not (($null -ne $Left) -and ("$Left" -like "*$Right")) }
            'contains' { return ($null -ne $Left) -and ("$Left" -like "*$Right*") }
            'notcontains' { return -not (($null -ne $Left) -and ("$Left" -like "*$Right*")) }
            'match' { return ($null -ne $Left) -and ("$Left" -match "$Right") }
            'notmatch' { return -not (($null -ne $Left) -and ("$Left" -match "$Right")) }
            'in' { return $Right -contains $Left }
            'notin' { return -not ($Right -contains $Left) }
            default { throw "Unsupported operator '$Op' in leaf '$Expression'." }
        }
    }

    # '-any (_ -op value)' over a collection property.
    if ($Expression -match '(?i)^user\.([A-Za-z0-9]+)\s+-any\s*\(\s*_\s+(-\S+)\s+(.+)\)\s*$') {
        $propName = $Matches[1]
        $op = $Matches[2]
        $value = ConvertFrom-EGILiteral -Text $Matches[3]
        $collection = @(Get-Prop -Obj $User -Name $propName)
        foreach ($item in $collection) {
            if (Invoke-EGIOperator -Left $item -Op $op -Right $value) { return $true }
        }
        return $false
    }

    # Simple single-property comparison: user.<prop> <op> <value>
    if ($Expression -match '(?i)^user\.([A-Za-z0-9]+)\s+(-\S+)\s+(.+)$') {
        $propName = $Matches[1]
        $op = $Matches[2]
        $value = ConvertFrom-EGILiteral -Text $Matches[3]
        $left = Get-Prop -Obj $User -Name $propName
        return (Invoke-EGIOperator -Left $left -Op $op -Right $value)
    }

    throw "Could not parse leaf expression: '$Expression'."
}
