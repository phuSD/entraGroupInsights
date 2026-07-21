# EntraGroupInsights

Visualizes and de-risks Microsoft Entra ID **dynamic group** rules:

- **Rule-tree parsing** — turn a long `-and`/`-or`/`-not` condition string into a readable tree
- **Bulk rule simulation** — test a rule against thousands of users at once (native admin center caps this at 20)
- **Blast-radius mapping** — find every Conditional Access policy, license assignment, app role assignment, and PIM eligibility that depends on a group
- **SVG relationship report** — render a group's blast radius as a standalone, shareable diagram
- **Snapshot/diff versioning** — export dynamic group rules to JSON, commit to Git, diff between runs

This is a v0.1 prototype. See [Limitations](#limitations) before relying on it for production decisions.

## Prerequisites

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Connect-MgGraph -Scopes 'Group.Read.All','Policy.Read.All','Directory.Read.All','RoleManagement.Read.Directory'
```

The module talks to Graph via `Invoke-MgGraphRequest`, so only `Microsoft.Graph.Authentication`
is a hard dependency — you don't need the full Microsoft.Graph SDK installed.

**PowerShell version**: works on both Windows PowerShell 5.1 and PowerShell 7+ (no PS7-only
syntax is used anywhere in this module). If you're on Windows PowerShell 5.1, make sure you
also meet Microsoft's prerequisites for `Microsoft.Graph.Authentication` on that edition:
.NET Framework 4.7.2+, an up-to-date `PowerShellGet` (`Install-Module PowerShellGet`), and an
execution policy of `RemoteSigned` or less restrictive.

## Install

Once published:

```powershell
Install-Module EntraGroupInsights -Scope CurrentUser
```

## Usage

### 1. Visualize a rule as a tree

```powershell
Get-EGIDynamicGroupRuleTree -GroupId '11111111-2222-3333-4444-555555555555' -AsText
```

```
Group: Sales-DE-Dynamic
Rule : (user.department -eq "Sales") -and -not (user.country -eq "US")

-AND
  - user.department -eq "Sales"
  -NOT
    - user.country -eq "US"
```

Or test a rule before you've even saved it:

```powershell
Get-EGIDynamicGroupRuleTree -Rule '(user.department -eq "Sales") -or (user.department -eq "Marketing")' -AsText
```

### 2. Simulate a rule against your whole tenant

```powershell
$users = Get-MgUser -All -Property Id,DisplayName,Department,Country,JobTitle
Test-EGIDynamicGroupRule -Rule '(user.department -eq "Sales") -and (user.country -eq "DE")' -Users $users
```

Add `-PassThru` to get back only the matching users.

### 3. Map a group's blast radius before changing its rule

```powershell
Get-EGIGroupBlastRadius -GroupId '11111111-2222-3333-4444-555555555555' | Format-List
```

Returns Conditional Access references, assigned licenses, app role assignments,
PIM eligibility, and a rolled-up `RiskLevel` (`None` / `Low` / `Medium` / `High` / `Critical`).

### 4. Render the blast radius as an SVG report

```powershell
Get-EGIGroupBlastRadius -GroupId '11111111-2222-3333-4444-555555555555' |
    Export-EGIGroupBlastRadiusSvg -Path './reports/sales-de-blast-radius.svg'
```

The group is drawn as a hub on the left; Conditional Access, licenses, app role
assignments, and PIM eligibility appear as color-coded spoke columns on the
right, each connected back to the hub. It's a plain, self-contained `.svg`
file — no external tools needed — so it opens directly in a browser, drops
into a wiki page, or attaches to a change ticket as evidence of the blast
radius before a rule change goes live.

For a network view across *many* groups at once (not just one group's
dependencies), exporting to Graphviz DOT format and letting `dot -Tsvg` do
the layout scales better than hand-rolled coordinates — open an issue/ask if
that's needed and it can be added as `Export-EGITenantGroupGraph`.

### 5. Snapshot and diff over time

```powershell
Export-EGIGroupSnapshot -Path './snapshots/dynamic-groups.json'
# ... commit to Git, run again tomorrow with a different filename ...
Compare-EGIGroupSnapshot -ReferencePath './snapshots/2026-07-20.json' -DifferencePath './snapshots/2026-07-21.json'
```

## Limitations

This prototype's rule engine covers the common comparison operators
(`-eq -ne -startsWith -notStartsWith -endsWith -notEndsWith -contains -notContains -match -notMatch -in -notIn`)
and a best-effort `-any(...)` handling. It does **not** simulate:

- `Direct Reports for "<objectId>"` rules
- the `memberOf` (preview) operator
- `employeeHireDate` date-math against `system.now`

Leaves using these raise a clear error per user rather than silently returning a wrong
match/no-match — check the `Error` column in `Test-EGIDynamicGroupRule`'s output.

**Operator precedence caveat**: this module parses with conventional precedence
(`-not` binds tightest, then `-and`, then `-or`), but Microsoft's dynamic-membership
documentation lists `-or` with *higher* precedence than `-and`. Rules that mix
`-and` and `-or` at the same parenthesization level are therefore ambiguous, and the
module emits a warning when it sees one — add explicit parentheses to be safe.

`Get-EGIGroupBlastRadius` currently checks Conditional Access, license assignment, app
role assignments, and PIM eligibility. Group-based Teams/SharePoint dependencies are
flagged at a high level (`IsTeamsGroup`) but not enumerated in detail yet.

## Publishing to PowerShell Gallery

```powershell
# One-time: get an API key from https://www.powershellgallery.com/account/apikeys
Test-ModuleManifest -Path ./EntraGroupInsights/EntraGroupInsights.psd1
Publish-Module -Path ./EntraGroupInsights -NuGetApiKey $env:PSGALLERY_API_KEY -Repository PSGallery
```

## Tests

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0
Invoke-Pester ./Tests
```

The rule-engine tests run fully offline (no Graph connection needed).
