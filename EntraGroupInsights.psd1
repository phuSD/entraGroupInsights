@{
    RootModule        = 'EntraGroupInsights.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e938a2fe-9488-4b2b-a1d4-571d37b33334'
    Author            = 'Your Name'
    CompanyName       = 'Unknown'
    Copyright         = '(c) Your Name. All rights reserved.'
    Description       = 'Visualizes and analyzes Microsoft Entra ID dynamic group rules: rule-tree parsing, at-scale membership simulation, snapshot/diff versioning, and blast-radius mapping (Conditional Access, license, app role, and PIM dependencies) for a given group.'
    PowerShellVersion = '7.2'

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
        'Export-EGIGroupSnapshot'
        'Compare-EGIGroupSnapshot'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Entra', 'EntraID', 'AzureAD', 'IdentityGovernance', 'ConditionalAccess', 'DynamicGroups', 'MicrosoftGraph', 'Security')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/yourhandle/EntraGroupInsights'
            ReleaseNotes = 'Initial 0.1.0 prototype: rule-tree visualization, bulk rule simulation subset, blast-radius mapping, and JSON snapshot/diff for change tracking.'
        }
    }
}
