@{
    RootModule        = 'EntraGroupInsights.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e938a2fe-9488-4b2b-a1d4-571d37b33334'
    Author            = 'Pascal Huber'
    Copyright         = '(c) Pascal Huber. All rights reserved.'
    Description       = 'Visualizes and de-risks Microsoft Entra ID dynamic group rules: rule-tree parsing, at-scale membership simulation, snapshot/diff versioning, and blast-radius mapping (Conditional Access, license, app role, and PIM dependencies - including inheritance through nested/parent groups and rule-based memberOf references) for a given group, with an SVG relationship report and example-user "would they match" illustration.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # Loaded lazily by the consuming session; the module itself only needs
    # Microsoft.Graph.Authentication for the active context, the rest are
    # invoked via Invoke-MgGraphRequest so a full SDK install isn't mandatory.
    RequiredModules   = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }
    )

    FunctionsToExport = @(
        'Get-EGIDynamicGroupRuleTree'
        'Test-EGIDynamicGroupRule'
        'Get-EGIGroupBlastRadius'
        'Export-EGIGroupBlastRadiusSvg'
        'Export-EGIGroupSnapshot'
        'Compare-EGIGroupSnapshot'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Entra', 'EntraID', 'AzureAD', 'IdentityGovernance', 'ConditionalAccess', 'DynamicGroups', 'MicrosoftGraph', 'Security')
            LicenseUri   = 'https://github.com/phuSD/EntraGroupInsights/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/phuSD/EntraGroupInsights'
            ReleaseNotes = '1.0.0: first stable release. Rule-tree parsing and bulk membership simulation for the common comparison operators, blast-radius mapping (Conditional Access, license, app role, and PIM dependencies) now including inheritance through nested/parent groups and rule-based memberOf references, a self-contained SVG relationship report with optional example-user match illustration, and JSON snapshot/diff for change tracking. See README Limitations for what is intentionally out of scope (Direct Reports rules, employeeHireDate date-math, and the general -and/-or precedence caveat).'
        }
    }
}
