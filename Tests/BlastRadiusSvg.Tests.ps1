BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    # Import the .psm1 directly (not the manifest) so the tests run fully
    # offline, without Microsoft.Graph.Authentication installed.
    Import-Module (Join-Path $moduleRoot 'EntraGroupInsights.psm1') -Force

    $script:blastRadius = [pscustomobject]@{
        GroupId                   = '11111111-2222-3333-4444-555555555555'
        DisplayName               = 'Sales-DE-Dynamic'
        IsRoleAssignable          = $false
        IsTeamsGroup              = $false
        MembershipRule            = '(user.department -eq "Sales") -and (user.country -eq "DE")'
        ParentGroups              = @()
        ChildGroups               = @()
        RuleReferencedGroups      = @()
        RuleReferencedByGroups    = @()
        ConditionalAccessPolicies = @()
        AssignedLicenses          = @()
        AppRoleAssignments        = @()
        PimEligibleRoleCount      = 0
        TotalDependencyCount      = 0
        RiskLevel                 = 'Low'
    }
}

Describe 'Export-EGIGroupBlastRadiusSvg' {

    It 'draws the membership rule as its own box' {
        $path = Join-Path $TestDrive 'rule-only.svg'
        $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path
        $svg = Get-Content -LiteralPath $path -Raw

        $svg | Should -Match 'Membership rule'
        $svg | Should -Match 'user\.department'
    }

    It 'omits the rule box when the group has no membership rule' {
        $path = Join-Path $TestDrive 'no-rule.svg'
        $noRule = $script:blastRadius | Select-Object * -ExcludeProperty MembershipRule
        $noRule | Add-Member -NotePropertyName MembershipRule -NotePropertyValue $null
        $noRule | Export-EGIGroupBlastRadiusSvg -Path $path
        $svg = Get-Content -LiteralPath $path -Raw

        $svg | Should -Not -Match 'Membership rule'
    }

    It 'draws a matching example user as a green "Matches rule" node' {
        $path = Join-Path $TestDrive 'match.svg'
        $matchingUser = [pscustomobject]@{ DisplayName = 'Alice Nguyen'; department = 'Sales'; country = 'DE' }
        $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUser $matchingUser
        $svg = Get-Content -LiteralPath $path -Raw

        $svg | Should -Match 'Alice Nguyen'
        $svg | Should -Match 'Matches rule'
        $svg | Should -Match '#16a34a'
    }

    It 'draws a non-matching example user as a red "Does not match rule" node' {
        $path = Join-Path $TestDrive 'no-match.svg'
        $nonMatchingUser = [pscustomobject]@{ DisplayName = 'Bob Fischer'; department = 'Engineering'; country = 'DE' }
        $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUser $nonMatchingUser
        $svg = Get-Content -LiteralPath $path -Raw

        $svg | Should -Match 'Bob Fischer'
        $svg | Should -Match 'Does not match rule'
        $svg | Should -Match '#dc2626'
    }

    It 'produces well-formed XML' {
        $path = Join-Path $TestDrive 'wellformed.svg'
        $matchingUser = [pscustomobject]@{ DisplayName = 'Alice Nguyen'; department = 'Sales'; country = 'DE' }
        $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUser $matchingUser

        { [xml](Get-Content -LiteralPath $path -Raw) } | Should -Not -Throw
    }

    It 'rejects -ExampleUser and -ExampleUserId together' {
        $path = Join-Path $TestDrive 'both.svg'
        { $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUser @{ DisplayName = 'X' } -ExampleUserId 'x@contoso.com' } |
            Should -Throw '*either*'
    }

    Context '-ExampleUserId (looks a real user up via Microsoft Graph)' {

        BeforeAll {
            Mock -ModuleName EntraGroupInsights Invoke-MgGraphRequest {
                param($Method, $Uri)
                $script:lastGraphUri = $Uri
                if ($Uri -match 'alice') {
                    return [pscustomobject]@{ id = 'aaaa'; displayName = 'Alice Nguyen'; department = 'Sales'; country = 'DE' }
                }
                return [pscustomobject]@{ id = 'bbbb'; displayName = 'Bob Fischer'; department = 'Engineering'; country = 'DE' }
            }
        }

        It 'looks the user up by UPN and draws a matching-user node' {
            $path = Join-Path $TestDrive 'upn-match.svg'
            $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUserId 'alice.nguyen@contoso.com'
            $svg = Get-Content -LiteralPath $path -Raw

            $svg | Should -Match 'Alice Nguyen'
            $svg | Should -Match 'Matches rule'
            Should -Invoke -ModuleName EntraGroupInsights Invoke-MgGraphRequest -Times 1
        }

        It 'only requests properties referenced by the membership rule (plus id/displayName)' {
            $path = Join-Path $TestDrive 'select.svg'
            $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUserId 'alice.nguyen@contoso.com'

            $script:lastGraphUri | Should -Match '\$select=id,displayName,department,country'
        }

        It 'draws a non-matching user in red' {
            $path = Join-Path $TestDrive 'id-no-match.svg'
            $script:blastRadius | Export-EGIGroupBlastRadiusSvg -Path $path -ExampleUserId '99999999-9999-9999-9999-999999999999'
            $svg = Get-Content -LiteralPath $path -Raw

            $svg | Should -Match 'Bob Fischer'
            $svg | Should -Match 'Does not match rule'
        }
    }

    Context 'nested group columns' {

        BeforeAll {
            $script:nestedBlastRadius = [pscustomobject]@{
                GroupId                   = '11111111-2222-3333-4444-555555555555'
                DisplayName               = 'Sales-DE-Dynamic'
                IsRoleAssignable          = $false
                IsTeamsGroup              = $false
                MembershipRule            = '(user.department -eq "Sales") -and (user.country -eq "DE")'
                ParentGroups              = @([pscustomobject]@{ id = 'p1'; displayName = 'EU-AllStaff' })
                ChildGroups               = @([pscustomobject]@{ id = 'c1'; displayName = 'Sales-DE-VIP' })
                ConditionalAccessPolicies = @(
                    [pscustomobject]@{ DisplayName = 'Require MFA EU'; State = 'enabled'; Reference = 'Include'; Source = "Nested via 'EU-AllStaff'" }
                )
                AssignedLicenses          = @(
                    [pscustomobject]@{ SkuId = 'sku-eu-123'; Source = "Nested via 'EU-AllStaff'" }
                )
                AppRoleAssignments        = @(
                    [pscustomobject]@{ resourceDisplayName = 'Salesforce'; appRoleId = 'role-1'; Source = "Nested via 'EU-AllStaff'" }
                )
                PimEligibleRoleCount      = 0
                TotalDependencyCount      = 3
                RiskLevel                 = 'Critical'
            }
        }

        It 'draws parent and child group columns' {
            $path = Join-Path $TestDrive 'nested.svg'
            $script:nestedBlastRadius | Export-EGIGroupBlastRadiusSvg -Path $path
            $svg = Get-Content -LiteralPath $path -Raw

            $svg | Should -Match 'Nested in \(parent groups\)'
            $svg | Should -Match 'EU-AllStaff'
            $svg | Should -Match 'Contains \(nested groups\)'
            $svg | Should -Match 'Sales-DE-VIP'
        }

        It 'labels inherited Conditional Access, license, and app role entries with their source group' {
            $path = Join-Path $TestDrive 'nested-sources.svg'
            $script:nestedBlastRadius | Export-EGIGroupBlastRadiusSvg -Path $path
            $svg = Get-Content -LiteralPath $path -Raw

            $svg | Should -Match "via &apos;EU-AllStaff&apos;"
        }

        It 'produces well-formed XML with the extra columns' {
            $path = Join-Path $TestDrive 'nested-wellformed.svg'
            $script:nestedBlastRadius | Export-EGIGroupBlastRadiusSvg -Path $path

            { [xml](Get-Content -LiteralPath $path -Raw) } | Should -Not -Throw
        }
    }

    Context 'memberOf rule-reference column' {

        It 'draws groups referenced by a memberOf rule clause' {
            $ruleReferenced = $script:blastRadius | Select-Object * -ExcludeProperty RuleReferencedGroups
            $ruleReferenced | Add-Member -NotePropertyName RuleReferencedGroups -NotePropertyValue @(
                [pscustomobject]@{ id = 'd1'; displayName = 'VendorX-Contractors' }
            )

            $path = Join-Path $TestDrive 'memberof.svg'
            $ruleReferenced | Export-EGIGroupBlastRadiusSvg -Path $path
            $svg = Get-Content -LiteralPath $path -Raw

            $svg | Should -Match 'Rule references \(memberOf\)'
            $svg | Should -Match 'VendorX-Contractors'
        }
    }

    Context 'memberOf reverse rule-reference column' {

        It 'draws other dynamic groups whose rule references this group' {
            $referencedBy = $script:blastRadius | Select-Object * -ExcludeProperty RuleReferencedByGroups
            $referencedBy | Add-Member -NotePropertyName RuleReferencedByGroups -NotePropertyValue @(
                [pscustomobject]@{ id = 'a1'; displayName = 'Contractors-AllOf-VendorX' }
            )

            $path = Join-Path $TestDrive 'memberof-reverse.svg'
            $referencedBy | Export-EGIGroupBlastRadiusSvg -Path $path
            $svg = Get-Content -LiteralPath $path -Raw

            $svg | Should -Match 'Referenced by \(memberOf\)'
            $svg | Should -Match 'Contractors-AllOf-VendorX'
        }
    }
}
