@{
    RootModule        = 'EntraGroupInsights.psm1'
    ModuleVersion     = '0.1.2'
    GUID              = 'e938a2fe-9488-4b2b-a1d4-571d37b33334'
    Author            = 'Pascal Huber'
    Copyright         = '(c) Pascal Huber. All rights reserved.'
    Description       = 'Visualizes and analyzes Microsoft Entra ID dynamic group rules: rule-tree parsing, at-scale membership simulation, snapshot/diff versioning, and blast-radius mapping (Conditional Access, license, app role, and PIM dependencies) for a given group.'
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
            ReleaseNotes = '0.1.2: rule-engine hardening (wildcard values compared literally, extension_* attributes, quoted commas in -in lists, warning on ambiguous -and/-or mixes), leaf compilation cache for bulk simulation, -PassThru returns the original user objects, advanced-query headers for snapshot export, blast-radius count/risk fixes, BOM-less UTF-8 output.'
        }
    }
}
