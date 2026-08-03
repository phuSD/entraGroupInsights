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
        ConditionalAccessPolicies = @()
        AssignedLicenseSkuIds     = @()
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
}
