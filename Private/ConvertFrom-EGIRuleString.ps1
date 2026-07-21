function ConvertFrom-EGIRuleString {
    <#
    .SYNOPSIS
        Parses an Entra ID dynamic membership rule string into a logic tree.

    .DESCRIPTION
        Tokenizes and parses rules of the form used by dynamic group membership,
        e.g. '(user.department -eq "Sales") -and -not (user.jobTitle -startsWith "SDE")'.

        Operator precedence: this parser binds -not tightest, then -and, then -or
        (conventional boolean precedence). CAUTION: Microsoft's dynamic-membership
        documentation lists -or with HIGHER precedence than -and, the opposite of
        most languages. Because real-world rules almost always parenthesize, this
        parser emits a warning whenever -and and -or are mixed at the same
        parenthesization level instead of silently picking one interpretation.

        LIMITATION: the body of an -any(...) / -all(...) lambda (e.g.
        'user.proxyAddresses -any (_ -startsWith "SMTP:")') is treated as an opaque
        leaf expression rather than recursively parsed, because its internal syntax
        (the '_' placeholder) is not the same grammar as the outer rule. This is a
        deliberate simplification for a v0.1 prototype.

    .PARAMETER Rule
        The raw dynamic membership rule string.

    .OUTPUTS
        A nested [pscustomobject] tree with Type 'And' | 'Or' | 'Not' | 'Leaf'.

    .EXAMPLE
        ConvertFrom-EGIRuleString -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Rule
    )

    # ---- Tokenizer -------------------------------------------------------
    # NOTE: state is kept in hashtables (reference types) and passed
    # explicitly into helper functions, rather than relying on PowerShell's
    # scope chain, so nested function calls reliably mutate shared state.
    $tokens = [System.Collections.Generic.List[pscustomobject]]::new()
    $atomState = @{ Buffer = '' }

    function Complete-EGIAtom {
        param($AtomState, $TokenList)
        if ($AtomState.Buffer.Trim().Length -gt 0) {
            $TokenList.Add([pscustomobject]@{ Type = 'Atom'; Value = $AtomState.Buffer.Trim() })
        }
        $AtomState.Buffer = ''
    }

    $i = 0
    $n = $Rule.Length

    while ($i -lt $n) {
        $rest = $Rule.Substring($i)

        if ($Rule[$i] -match '\s') {
            # Keep whitespace inside an atom ('user.department -eq "Sales"');
            # leading/trailing runs are trimmed when the atom completes.
            if ($atomState.Buffer.Length -gt 0) { $atomState.Buffer += $Rule[$i] }
            $i++
            continue
        }

        if ($Rule[$i] -eq '(') {
            # Is this an -any( / -all( lambda body? If the atom buffer just ended
            # with -any / -all, keep the parenthesized block as part of the atom.
            if ($atomState.Buffer.TrimEnd() -match '(?i)-(any|all)$') {
                $depth = 1
                $j = $i + 1
                while ($j -lt $n -and $depth -gt 0) {
                    $ch = $Rule[$j]
                    if ($ch -eq '"' -or $ch -eq "'") {
                        # Skip quoted sections so parens inside values don't affect depth.
                        $j++
                        while ($j -lt $n -and $Rule[$j] -ne $ch) { $j++ }
                    }
                    elseif ($ch -eq '(') { $depth++ }
                    elseif ($ch -eq ')') { $depth-- }
                    $j++
                }
                $j = [Math]::Min($j, $n)
                $atomState.Buffer += ' ' + $Rule.Substring($i, $j - $i)
                $i = $j
                continue
            }
            Complete-EGIAtom -AtomState $atomState -TokenList $tokens
            $tokens.Add([pscustomobject]@{ Type = 'LParen' })
            $i++
            continue
        }

        if ($Rule[$i] -eq ')') {
            Complete-EGIAtom -AtomState $atomState -TokenList $tokens
            $tokens.Add([pscustomobject]@{ Type = 'RParen' })
            $i++
            continue
        }

        if ($rest -match '(?i)^-and\b') {
            Complete-EGIAtom -AtomState $atomState -TokenList $tokens
            $tokens.Add([pscustomobject]@{ Type = 'And' })
            $i += 4
            continue
        }
        if ($rest -match '(?i)^-or\b') {
            Complete-EGIAtom -AtomState $atomState -TokenList $tokens
            $tokens.Add([pscustomobject]@{ Type = 'Or' })
            $i += 3
            continue
        }
        if ($rest -match '(?i)^-not\b') {
            Complete-EGIAtom -AtomState $atomState -TokenList $tokens
            $tokens.Add([pscustomobject]@{ Type = 'Not' })
            $i += 4
            continue
        }

        # Respect quoted strings so -and/-or text inside quotes is never split.
        if ($Rule[$i] -eq '"' -or $Rule[$i] -eq "'") {
            $quote = $Rule[$i]
            $j = $i + 1
            while ($j -lt $n -and $Rule[$j] -ne $quote) { $j++ }
            $j = [Math]::Min($j + 1, $n)
            $atomState.Buffer += $Rule.Substring($i, $j - $i)
            $i = $j
            continue
        }

        $atomState.Buffer += $Rule[$i]
        $i++
    }
    Complete-EGIAtom -AtomState $atomState -TokenList $tokens

    if ($tokens.Count -eq 0) {
        throw 'Empty rule string.'
    }

    # Warn when -and / -or are mixed at the same parenthesization level: this
    # parser binds -and tighter than -or, but Microsoft's documentation lists
    # -or above -and, so an unparenthesized mix is ambiguous.
    $levelOps = [System.Collections.Generic.HashSet[string]]::new()
    $opStack = [System.Collections.Generic.Stack[object]]::new()
    $mixed = $false
    foreach ($t in $tokens) {
        switch ($t.Type) {
            'LParen' { $opStack.Push($levelOps); $levelOps = [System.Collections.Generic.HashSet[string]]::new() }
            'RParen' { if ($opStack.Count -gt 0) { $levelOps = $opStack.Pop() } }
            'And' { [void]$levelOps.Add('And'); if ($levelOps.Count -gt 1) { $mixed = $true } }
            'Or' { [void]$levelOps.Add('Or'); if ($levelOps.Count -gt 1) { $mixed = $true } }
        }
    }
    if ($mixed) {
        Write-Warning ('Rule mixes -and and -or at the same parenthesization level. This parser evaluates -and before -or, ' +
            "but Microsoft's dynamic-membership documentation lists -or with higher precedence than -and. " +
            'Add explicit parentheses so the intended grouping is unambiguous.')
    }

    # ---- Recursive-descent parser -----------------------------------------
    # $parseState.Pos is mutated by reference (hashtable) so every helper
    # below sees the same cursor position without relying on scope chains.
    $parseState = @{ Pos = 0 }

    function Get-EGIToken {
        param($TokenList, $ParseState)
        if ($ParseState.Pos -lt $TokenList.Count) { return $TokenList[$ParseState.Pos] }
        return $null
    }

    function Step-EGIToken {
        param($TokenList, $ParseState)
        $t = Get-EGIToken -TokenList $TokenList -ParseState $ParseState
        $ParseState.Pos++
        return $t
    }

    function Read-EGIPrimary {
        param($TokenList, $ParseState)
        $t = Get-EGIToken -TokenList $TokenList -ParseState $ParseState
        if ($null -eq $t) { throw 'Unexpected end of rule while parsing an expression.' }
        if ($t.Type -eq 'LParen') {
            Step-EGIToken -TokenList $TokenList -ParseState $ParseState | Out-Null
            $node = Read-EGIOr -TokenList $TokenList -ParseState $ParseState
            $close = Step-EGIToken -TokenList $TokenList -ParseState $ParseState
            if ($null -eq $close -or $close.Type -ne 'RParen') {
                throw 'Missing closing parenthesis in rule.'
            }
            return $node
        }
        if ($t.Type -eq 'Atom') {
            Step-EGIToken -TokenList $TokenList -ParseState $ParseState | Out-Null
            return [pscustomobject]@{ Type = 'Leaf'; Expression = $t.Value }
        }
        throw "Unexpected token '$($t.Type)' while parsing an expression."
    }

    function Read-EGINot {
        param($TokenList, $ParseState)
        $peeked = Get-EGIToken -TokenList $TokenList -ParseState $ParseState
        if ($peeked -and $peeked.Type -eq 'Not') {
            Step-EGIToken -TokenList $TokenList -ParseState $ParseState | Out-Null
            return [pscustomobject]@{ Type = 'Not'; Child = (Read-EGINot -TokenList $TokenList -ParseState $ParseState) }
        }
        return Read-EGIPrimary -TokenList $TokenList -ParseState $ParseState
    }

    function Read-EGIAnd {
        param($TokenList, $ParseState)
        $left = Read-EGINot -TokenList $TokenList -ParseState $ParseState
        $children = [System.Collections.Generic.List[object]]::new()
        $children.Add($left)
        while (($p = Get-EGIToken -TokenList $TokenList -ParseState $ParseState) -and $p.Type -eq 'And') {
            Step-EGIToken -TokenList $TokenList -ParseState $ParseState | Out-Null
            $children.Add((Read-EGINot -TokenList $TokenList -ParseState $ParseState))
        }
        if ($children.Count -eq 1) { return $left }
        return [pscustomobject]@{ Type = 'And'; Children = $children }
    }

    function Read-EGIOr {
        param($TokenList, $ParseState)
        $left = Read-EGIAnd -TokenList $TokenList -ParseState $ParseState
        $children = [System.Collections.Generic.List[object]]::new()
        $children.Add($left)
        while (($p = Get-EGIToken -TokenList $TokenList -ParseState $ParseState) -and $p.Type -eq 'Or') {
            Step-EGIToken -TokenList $TokenList -ParseState $ParseState | Out-Null
            $children.Add((Read-EGIAnd -TokenList $TokenList -ParseState $ParseState))
        }
        if ($children.Count -eq 1) { return $left }
        return [pscustomobject]@{ Type = 'Or'; Children = $children }
    }

    $tree = Read-EGIOr -TokenList $tokens -ParseState $parseState
    if ($parseState.Pos -ne $tokens.Count) {
        throw "Unexpected trailing tokens after position $($parseState.Pos) - check for unbalanced parentheses."
    }
    return $tree
}
