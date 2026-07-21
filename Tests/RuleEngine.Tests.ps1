BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot 'EntraGroupInsights.psd1') -Force
}

Describe 'ConvertFrom-EGIRuleString' {

    It 'parses a single leaf expression' {
        $tree = ConvertFrom-EGIRuleString -Rule 'user.department -eq "Sales"'
        $tree.Type | Should -Be 'Leaf'
        $tree.Expression | Should -Be 'user.department -eq "Sales"'
    }

    It 'parses an -or expression' {
        $tree = ConvertFrom-EGIRuleString -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")'
        $tree.Type | Should -Be 'Or'
        $tree.Children.Count | Should -Be 2
    }

    It 'parses -and -not with correct precedence' {
        $tree = ConvertFrom-EGIRuleString -Rule '(user.department -eq "Sales") -and -not (user.jobTitle -startsWith "SDE")'
        $tree.Type | Should -Be 'And'
        $tree.Children[1].Type | Should -Be 'Not'
    }

    It 'keeps an -any(...) lambda body as a single leaf' {
        $tree = ConvertFrom-EGIRuleString -Rule 'user.otherMails -any (_ -contains "contoso")'
        $tree.Type | Should -Be 'Leaf'
        $tree.Expression | Should -Match '-any'
    }
}

Describe 'Test-EGIDynamicGroupRule' {

    BeforeAll {
        $script:users = @(
            [pscustomobject]@{ DisplayName = 'Alice'; Department = 'Sales'; Country = 'DE' }
            [pscustomobject]@{ DisplayName = 'Bob'; Department = 'Marketing'; Country = 'DE' }
            [pscustomobject]@{ DisplayName = 'Carol'; Department = 'Sales'; Country = 'US' }
        )
    }

    It 'matches only users satisfying an AND rule' {
        $result = Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -and (user.country -eq "DE")' -Users $script:users -PassThru
        $result.DisplayName | Should -Be 'Alice'
    }

    It 'matches users satisfying an OR rule' {
        $result = Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")' -Users $script:users -PassThru
        $result.Count | Should -Be 3
    }

    It 'reports an error for unsupported constructs instead of a wrong result' {
        $result = Test-EGIDynamicGroupRule -Rule 'user.employeehiredate -ge system.now -plus p1d' -Users $script:users
        $result | Where-Object { $_.Error } | Should -Not -BeNullOrEmpty
    }
}
