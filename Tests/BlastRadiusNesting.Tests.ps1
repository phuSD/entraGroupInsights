BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    # Import the .psm1 directly (not the manifest) so the tests run fully
    # offline, without Microsoft.Graph.Authentication installed.
    Import-Module (Join-Path $moduleRoot 'EntraGroupInsights.psm1') -Force

    $script:childId  = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:parentId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:grandchildId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
}

Describe 'Get-EGIGroupBlastRadius (nested group detection)' {

    BeforeAll {
        Mock -ModuleName EntraGroupInsights Invoke-MgGraphRequest {
            param($Method, $Uri, $Headers)

            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId\?") {
                return [pscustomobject]@{
                    id                          = $script:childId
                    displayName                 = 'Sales-DE-Dynamic'
                    groupTypes                  = @('DynamicMembership')
                    membershipRule              = '(user.department -eq "Sales") -and (user.country -eq "DE")'
                    assignedLicenses            = @()
                    isAssignableToRole          = $false
                    resourceProvisioningOptions = @()
                }
            }
            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId/transitiveMemberOf/microsoft\.graph\.group") {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:parentId; displayName = 'EU-AllStaff'; groupTypes = @() }) }
            }
            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId/transitiveMembers/microsoft\.graph\.group") {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:grandchildId; displayName = 'Sales-DE-VIP'; groupTypes = @() }) }
            }
            if ($Uri -match '^https://graph\.microsoft\.com/v1\.0/identity/conditionalAccess/policies') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                            id          = 'pol1'
                            displayName = 'Require MFA EU'
                            state       = 'enabled'
                            conditions  = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @($script:parentId); excludeGroups = @() } }
                        })
                }
            }
            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId/appRoleAssignments") {
                return [pscustomobject]@{ value = @() }
            }
            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:parentId/appRoleAssignments") {
                return [pscustomobject]@{ value = @([pscustomobject]@{ resourceDisplayName = 'Salesforce'; appRoleId = 'role-1' }) }
            }
            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:parentId\?") {
                return [pscustomobject]@{ assignedLicenses = @([pscustomobject]@{ skuId = 'sku-eu-123' }) }
            }
            if ($Uri -match 'groups\?\$filter=groupTypes') { return [pscustomobject]@{ value = @() } }

            throw "Unexpected mock Graph call: $Uri"
        }

        $script:blastRadius = Get-EGIGroupBlastRadius -GroupId $script:childId
    }

    It 'lists the transitive parent group' {
        $script:blastRadius.ParentGroups.displayName | Should -Contain 'EU-AllStaff'
    }

    It 'lists the transitive child group' {
        $script:blastRadius.ChildGroups.displayName | Should -Contain 'Sales-DE-VIP'
    }

    It 'attributes a Conditional Access policy on the parent group as inherited' {
        $hit = $script:blastRadius.ConditionalAccessPolicies | Where-Object DisplayName -EQ 'Require MFA EU'
        $hit | Should -Not -BeNullOrEmpty
        $hit.Source | Should -Be "Nested via 'EU-AllStaff'"
    }

    It 'attributes a license assigned to the parent group as inherited' {
        $hit = $script:blastRadius.AssignedLicenses | Where-Object SkuId -EQ 'sku-eu-123'
        $hit | Should -Not -BeNullOrEmpty
        $hit.Source | Should -Be "Nested via 'EU-AllStaff'"
    }

    It 'attributes an app role assignment on the parent group as inherited' {
        $hit = $script:blastRadius.AppRoleAssignments | Where-Object resourceDisplayName -EQ 'Salesforce'
        $hit | Should -Not -BeNullOrEmpty
        $hit.Source | Should -Be "Nested via 'EU-AllStaff'"
    }

    It 'rolls the inherited hits into TotalDependencyCount and RiskLevel' {
        $script:blastRadius.TotalDependencyCount | Should -Be 3
        $script:blastRadius.RiskLevel | Should -Be 'Critical'
    }

    It 'does not tag anything as Direct, since none of the dependencies reference the child group itself' {
        $script:blastRadius.ConditionalAccessPolicies | Where-Object Source -EQ 'Direct' | Should -BeNullOrEmpty
    }
}

Describe 'Get-EGIGroupBlastRadius (no nesting)' {

    BeforeAll {
        Mock -ModuleName EntraGroupInsights Invoke-MgGraphRequest {
            param($Method, $Uri, $Headers)

            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId\?") {
                return [pscustomobject]@{
                    id                          = $script:childId
                    displayName                 = 'Sales-DE-Dynamic'
                    groupTypes                  = @('DynamicMembership')
                    membershipRule              = '(user.department -eq "Sales")'
                    assignedLicenses            = @()
                    isAssignableToRole          = $false
                    resourceProvisioningOptions = @()
                }
            }
            if ($Uri -match 'transitiveMemberOf/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'transitiveMembers/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'conditionalAccess/policies') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'appRoleAssignments') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'groups\?\$filter=groupTypes') { return [pscustomobject]@{ value = @() } }

            throw "Unexpected mock Graph call: $Uri"
        }

        $script:blastRadius = Get-EGIGroupBlastRadius -GroupId $script:childId
    }

    It 'returns empty (not null) ParentGroups, ChildGroups, RuleReferencedGroups, and RuleReferencedByGroups arrays when the group has no nesting' {
        $script:blastRadius.ParentGroups.Count | Should -Be 0
        $script:blastRadius.ChildGroups.Count | Should -Be 0
        $script:blastRadius.RuleReferencedGroups.Count | Should -Be 0
        $script:blastRadius.RuleReferencedByGroups.Count | Should -Be 0
    }

    It 'reports RiskLevel None when nothing depends on the group directly or transitively' {
        $script:blastRadius.TotalDependencyCount | Should -Be 0
        $script:blastRadius.RiskLevel | Should -Be 'None'
    }
}

Describe 'Get-EGIGroupBlastRadius (memberOf rule references)' {

    BeforeAll {
        $script:referencedId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    }

    Context 'the referenced group resolves' {

        BeforeAll {
            Mock -ModuleName EntraGroupInsights Invoke-MgGraphRequest {
                param($Method, $Uri, $Headers)

                if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId\?") {
                    return [pscustomobject]@{
                        id                          = $script:childId
                        displayName                 = 'Contractors-AllOf-VendorX'
                        groupTypes                  = @('DynamicMembership')
                        membershipRule              = "user.memberof -any (group.objectId -in ['$script:referencedId'])"
                        assignedLicenses            = @()
                        isAssignableToRole          = $false
                        resourceProvisioningOptions = @()
                    }
                }
                if ($Uri -match 'transitiveMemberOf/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'transitiveMembers/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'conditionalAccess/policies') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'appRoleAssignments') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'groups\?\$filter=groupTypes') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:referencedId\?") {
                    return [pscustomobject]@{ id = $script:referencedId; displayName = 'VendorX-Contractors' }
                }

                throw "Unexpected mock Graph call: $Uri"
            }

            $script:blastRadius = Get-EGIGroupBlastRadius -GroupId $script:childId
        }

        It 'resolves the group referenced by the memberOf clause' {
            $script:blastRadius.RuleReferencedGroups.Count | Should -Be 1
            $script:blastRadius.RuleReferencedGroups[0].id | Should -Be $script:referencedId
            $script:blastRadius.RuleReferencedGroups[0].displayName | Should -Be 'VendorX-Contractors'
        }

        It 'does not count the reference toward TotalDependencyCount or RiskLevel' {
            $script:blastRadius.TotalDependencyCount | Should -Be 0
            $script:blastRadius.RiskLevel | Should -Be 'None'
        }
    }

    Context 'the referenced group cannot be resolved (deleted / no permission)' {

        BeforeAll {
            Mock -ModuleName EntraGroupInsights Invoke-MgGraphRequest {
                param($Method, $Uri, $Headers)

                if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId\?") {
                    return [pscustomobject]@{
                        id                          = $script:childId
                        displayName                 = 'Contractors-AllOf-VendorX'
                        groupTypes                  = @('DynamicMembership')
                        membershipRule              = "user.memberof -any (group.objectId -in ['$script:referencedId'])"
                        assignedLicenses            = @()
                        isAssignableToRole          = $false
                        resourceProvisioningOptions = @()
                    }
                }
                if ($Uri -match 'transitiveMemberOf/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'transitiveMembers/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'conditionalAccess/policies') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'appRoleAssignments') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match 'groups\?\$filter=groupTypes') { return [pscustomobject]@{ value = @() } }
                if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:referencedId\?") {
                    throw '404 Not Found'
                }

                throw "Unexpected mock Graph call: $Uri"
            }

            $script:blastRadius = Get-EGIGroupBlastRadius -GroupId $script:childId -WarningAction SilentlyContinue
        }

        It 'still lists the referenced group by ID with an unresolved marker instead of dropping it' {
            $script:blastRadius.RuleReferencedGroups.Count | Should -Be 1
            $script:blastRadius.RuleReferencedGroups[0].id | Should -Be $script:referencedId
            $script:blastRadius.RuleReferencedGroups[0].displayName | Should -Match 'unresolved'
        }
    }
}

Describe 'Get-EGIGroupBlastRadius (reverse memberOf lookup)' {

    BeforeAll {
        $script:otherDynamicGroupId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $script:unrelatedGroupId    = 'ffffffff-ffff-ffff-ffff-ffffffffffff'

        Mock -ModuleName EntraGroupInsights Invoke-MgGraphRequest {
            param($Method, $Uri, $Headers)

            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId\?") {
                return [pscustomobject]@{
                    id                          = $script:childId
                    displayName                 = 'VendorX-Contractors'
                    groupTypes                  = @('DynamicMembership')
                    membershipRule              = '(user.department -eq "Contractor")'
                    assignedLicenses            = @()
                    isAssignableToRole          = $false
                    resourceProvisioningOptions = @()
                }
            }
            if ($Uri -match 'transitiveMemberOf/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'transitiveMembers/microsoft\.graph\.group') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'conditionalAccess/policies') { return [pscustomobject]@{ value = @() } }
            if ($Uri -match "^https://graph\.microsoft\.com/v1\.0/groups/$script:childId/appRoleAssignments") { return [pscustomobject]@{ value = @() } }
            if ($Uri -match 'groups\?\$filter=groupTypes') {
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{ id = $script:otherDynamicGroupId; displayName = 'Contractors-AllOf-VendorX'; membershipRule = "user.memberof -any (group.objectId -in ['$script:childId'])" }
                        [pscustomobject]@{ id = $script:unrelatedGroupId; displayName = 'Some-Other-Dynamic-Group'; membershipRule = '(user.department -eq "Sales")' }
                        [pscustomobject]@{ id = $script:childId; displayName = 'VendorX-Contractors'; membershipRule = '(user.department -eq "Contractor")' }
                    )
                }
            }

            throw "Unexpected mock Graph call: $Uri"
        }

        $script:blastRadius = Get-EGIGroupBlastRadius -GroupId $script:childId
    }

    It 'finds another dynamic group whose rule references this group via memberOf' {
        $script:blastRadius.RuleReferencedByGroups.displayName | Should -Contain 'Contractors-AllOf-VendorX'
    }

    It 'excludes dynamic groups whose rule does not reference this group' {
        $script:blastRadius.RuleReferencedByGroups.displayName | Should -Not -Contain 'Some-Other-Dynamic-Group'
    }

    It 'excludes the group itself even though it appears in the tenant-wide dynamic group listing' {
        $script:blastRadius.RuleReferencedByGroups.id | Should -Not -Contain $script:childId
    }

    It 'does not count reverse references toward TotalDependencyCount or RiskLevel' {
        $script:blastRadius.TotalDependencyCount | Should -Be 0
        $script:blastRadius.RiskLevel | Should -Be 'None'
    }
}
