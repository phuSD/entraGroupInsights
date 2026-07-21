BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    # Import the .psm1 directly (not the manifest) so the tests run fully
    # offline, without Microsoft.Graph.Authentication installed.
    Import-Module (Join-Path $moduleRoot 'EntraGroupInsights.psm1') -Force
}

Describe 'Get-EGIDynamicGroupRuleTree (parser)' {

    It 'parses a single leaf expression' {
        $tree = (Get-EGIDynamicGroupRuleTree -Rule 'user.department -eq "Sales"').Tree
        $tree.Type | Should -Be 'Leaf'
        $tree.Expression | Should -Be 'user.department -eq "Sales"'
    }

    It 'parses an -or expression' {
        $tree = (Get-EGIDynamicGroupRuleTree -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")').Tree
        $tree.Type | Should -Be 'Or'
        $tree.Children.Count | Should -Be 2
    }

    It 'parses -and -not with correct precedence' {
        $tree = (Get-EGIDynamicGroupRuleTree -Rule '(user.department -eq "Sales") -and -not (user.jobTitle -startsWith "SDE")').Tree
        $tree.Type | Should -Be 'And'
        $tree.Children[1].Type | Should -Be 'Not'
    }

    It 'keeps an -any(...) lambda body as a single leaf' {
        $tree = (Get-EGIDynamicGroupRuleTree -Rule 'user.otherMails -any (_ -contains "contoso")').Tree
        $tree.Type | Should -Be 'Leaf'
        $tree.Expression | Should -Match '-any'
    }

    It 'keeps parens inside quoted lambda values out of the depth count' {
        $tree = (Get-EGIDynamicGroupRuleTree -Rule 'user.otherMails -any (_ -contains "a(b")').Tree
        $tree.Type | Should -Be 'Leaf'
        $tree.Expression | Should -Match '\-any'
    }

    It 'warns when -and and -or are mixed without parentheses' {
        $null = Get-EGIDynamicGroupRuleTree -Rule 'user.a -eq "1" -or user.b -eq "2" -and user.c -eq "3"' `
            -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -BeGreaterThan 0
        "$warnings" | Should -Match 'parenthes'
    }

    It 'does not warn when the mix is fully parenthesized' {
        $null = Get-EGIDynamicGroupRuleTree -Rule '(user.a -eq "1" -or user.b -eq "2") -and user.c -eq "3"' `
            -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be 0
    }

    It 'throws on unbalanced parentheses' {
        { Get-EGIDynamicGroupRuleTree -Rule '(user.a -eq "1"' } | Should -Throw
    }
}

Describe 'Test-EGIDynamicGroupRule' {

    BeforeAll {
        $script:users = @(
            [pscustomobject]@{ Id = 'u1'; DisplayName = 'Alice'; Department = 'Sales'; Country = 'DE' }
            [pscustomobject]@{ Id = 'u2'; DisplayName = 'Bob'; Department = 'Marketing'; Country = 'DE' }
            [pscustomobject]@{ Id = 'u3'; DisplayName = 'Carol'; Department = 'Sales'; Country = 'US' }
        )
    }

    It 'matches only users satisfying an AND rule' {
        $result = Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -and (user.country -eq "DE")' -Users $script:users -PassThru
        $result.DisplayName | Should -Be 'Alice'
    }

    It '-PassThru returns the original user objects, not report rows' {
        $result = Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -and (user.country -eq "DE")' -Users $script:users -PassThru
        $result.Id | Should -Be 'u1'
        $result.Country | Should -Be 'DE'
    }

    It 'matches users satisfying an OR rule' {
        $result = Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")' -Users $script:users -PassThru
        $result.Count | Should -Be 3
    }

    It 'includes the user Id in the report rows' {
        $result = Test-EGIDynamicGroupRule -Rule 'user.department -eq "Sales"' -Users $script:users
        ($result | Where-Object Matches).Id | Should -Be @('u1', 'u3')
    }

    It 'reports an error for unsupported constructs instead of a wrong result' {
        $result = Test-EGIDynamicGroupRule -Rule 'user.employeehiredate -ge system.now -plus p1d' -Users $script:users -WarningAction SilentlyContinue
        $result | Where-Object { $_.Error } | Should -Not -BeNullOrEmpty
    }

    It 'supports hashtable user objects' {
        $hashUsers = @(
            @{ Id = 'h1'; DisplayName = 'Hank'; Department = 'Sales'; Country = 'DE' }
        )
        $result = Test-EGIDynamicGroupRule -Rule 'user.department -eq "Sales"' -Users $hashUsers
        $result.DisplayName | Should -Be 'Hank'
        $result.Matches | Should -BeTrue
    }

    It 'evaluates -in and -notIn against list literals' {
        $result = Test-EGIDynamicGroupRule -Rule 'user.department -in ["Sales", "Marketing"]' -Users $script:users -PassThru
        $result.Count | Should -Be 3

        $result = Test-EGIDynamicGroupRule -Rule 'user.department -notIn ["Sales"]' -Users $script:users -PassThru
        $result.DisplayName | Should -Be 'Bob'
    }

    It 'keeps quoted commas inside -in list values intact' {
        $users = @([pscustomobject]@{ DisplayName = 'Rita'; Department = 'R, D' })
        $result = Test-EGIDynamicGroupRule -Rule 'user.department -in ["R, D", "Sales"]' -Users $users -PassThru
        $result.DisplayName | Should -Be 'Rita'
    }

    It 'evaluates -any over a collection property' {
        $users = @(
            [pscustomobject]@{ DisplayName = 'Mia'; OtherMails = @('mia@contoso.com', 'mia@fabrikam.com') }
            [pscustomobject]@{ DisplayName = 'Ned'; OtherMails = @('ned@fabrikam.com') }
        )
        $result = Test-EGIDynamicGroupRule -Rule 'user.otherMails -any (_ -contains "contoso")' -Users $users -PassThru
        $result.DisplayName | Should -Be 'Mia'
    }

    It 'evaluates extension attribute properties' {
        $users = @(
            [pscustomobject]@{ DisplayName = 'Eve'; extension_abc123_costCenter = '42' }
            [pscustomobject]@{ DisplayName = 'Sam'; extension_abc123_costCenter = '7' }
        )
        $result = Test-EGIDynamicGroupRule -Rule 'user.extension_abc123_costCenter -eq "42"' -Users $users -PassThru
        $result.DisplayName | Should -Be 'Eve'
    }

    It 'treats wildcard characters in values as literals' {
        $users = @(
            [pscustomobject]@{ DisplayName = '[Ext] Dave'; Department = 'Ops' }
            [pscustomobject]@{ DisplayName = 'Erin'; Department = 'Ops' }
        )
        $result = Test-EGIDynamicGroupRule -Rule 'user.displayName -startsWith "[Ext]"' -Users $users -PassThru
        $result.DisplayName | Should -Be '[Ext] Dave'

        $result = Test-EGIDynamicGroupRule -Rule 'user.displayName -contains "[Ext]"' -Users $users -PassThru
        $result.DisplayName | Should -Be '[Ext] Dave'
    }

    It 'treats null properties as non-matching for positive string operators' {
        $users = @([pscustomobject]@{ DisplayName = 'NoDept'; Department = $null })
        $result = Test-EGIDynamicGroupRule -Rule 'user.department -startsWith "Sal"' -Users $users
        $result.Matches | Should -BeFalse
    }
}
