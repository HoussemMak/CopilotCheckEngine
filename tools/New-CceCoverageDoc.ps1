#Requires -Version 7.0
<#
.SYNOPSIS
    Genere docs/COVERAGE.md : la source de donnees utilisee par chaque controle.

.DESCRIPTION
    Le tableau de couverture est derive du catalogue et de la table de correspondance
    ci-dessous, afin qu'il reste synchronise avec le referentiel.
#>
[CmdletBinding()]
param(
    [string] $CatalogPath = (Join-Path $PSScriptRoot '..\data\checklist-catalog.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\docs\COVERAGE.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Id -> @{ Mode; Source }
# Mode : Automatique | Poste local | Manuel
$map = @{
    1  = @{ Mode = 'Automatique'; Source = 'Graph - Get-MgSubscribedSku' }
    2  = @{ Mode = 'Automatique'; Source = 'Graph - Get-MgSubscribedSku' }
    3  = @{ Mode = 'Automatique'; Source = 'Graph - Get-MgUser (filtre assignedLicenses)' }
    4  = @{ Mode = 'Automatique'; Source = 'Graph - /groups?$filter=assignedLicenses' }
    5  = @{ Mode = 'Automatique'; Source = 'Graph beta - /directory/subscriptions' }
    6  = @{ Mode = 'Poste local'; Source = 'Registre ClickToRun (-IncludeLocalChecks) + rapport M365 Apps' }
    7  = @{ Mode = 'Automatique'; Source = 'Graph beta - /admin/microsoft365Apps/installationOptions (+ registre local)' }
    8  = @{ Mode = 'Automatique'; Source = 'Exchange - Get-OrganizationConfig' }
    9  = @{ Mode = 'Poste local'; Source = 'Registre Office privacy (-IncludeLocalChecks)' }
    10 = @{ Mode = 'Automatique'; Source = 'Graph - /identity/conditionalAccess/policies' }
    11 = @{ Mode = 'Automatique'; Source = 'Graph - analyse des controles block sur Microsoft Graph' }
    12 = @{ Mode = 'Automatique'; Source = 'Graph - analyse des controles block sur Office 365' }
    13 = @{ Mode = 'Automatique'; Source = 'Graph - suffixes UPN' }
    14 = @{ Mode = 'Automatique'; Source = 'Graph - comptes desactives licencies' }
    15 = @{ Mode = 'Automatique'; Source = 'Graph - comptes invites licencies' }
    16 = @{ Mode = 'Automatique'; Source = 'SharePoint - Get-SPOTenant' }
    17 = @{ Mode = 'Automatique'; Source = 'SharePoint - Get-SPOTenant' }
    18 = @{ Mode = 'Automatique'; Source = 'SharePoint - Get-SPOSite (detection mots-cles sensibles)' }
    19 = @{ Mode = 'Automatique'; Source = 'SharePoint - Get-SPOSite -IncludePersonalSite + Graph' }
    20 = @{ Mode = 'Manuel';      Source = 'Test fonctionnel Microsoft Search' }
    21 = @{ Mode = 'Manuel';      Source = 'PnP.PowerShell par site (Get-PnPWeb -Includes NoCrawl)' }
    22 = @{ Mode = 'Automatique'; Source = 'SharePoint - Get-SPOTenantRestrictedSearchMode' }
    23 = @{ Mode = 'Automatique'; Source = 'SharePoint - Get-SPOTenant (OneDriveStorageQuota)' }
    24 = @{ Mode = 'Automatique'; Source = 'Exchange - Get-Mailbox (echantillon Copilot)' }
    25 = @{ Mode = 'Automatique'; Source = 'Exchange - Get-CASMailbox' }
    26 = @{ Mode = 'Automatique'; Source = 'Exchange - Get-AdminAuditLogConfig + Get-OrganizationConfig' }
    27 = @{ Mode = 'Automatique'; Source = 'Teams - Get-CsTeamsAppPermissionPolicy + Graph appCatalogs' }
    28 = @{ Mode = 'Automatique'; Source = 'Teams - Get-CsTeamsAppSetupPolicy + Graph appCatalogs' }
    29 = @{ Mode = 'Automatique'; Source = 'Teams - Get-CsTeamsMeetingPolicy (AllowTranscription)' }
    30 = @{ Mode = 'Automatique'; Source = 'Teams - Get-CsTeamsMeetingPolicy (AllowCloudRecording)' }
    31 = @{ Mode = 'Automatique'; Source = 'Teams - Get-CsTeamsMeetingPolicy (CopilotMode)' }
    32 = @{ Mode = 'Automatique'; Source = 'Teams - Get-CsTeamsMeetingPolicy (sous-titres)' }
    33 = @{ Mode = 'Automatique'; Source = "Graph beta - rapport d'usage Copilot (preuve d'activite)" }
    34 = @{ Mode = 'Automatique'; Source = "Graph beta - rapport d'usage Copilot par workload" }
    35 = @{ Mode = 'Automatique'; Source = 'Graph beta - activite Copilot Chat' }
    36 = @{ Mode = 'Manuel';      Source = 'Decision de gouvernance a documenter' }
    37 = @{ Mode = 'Automatique'; Source = "Graph beta - rapport d'usage (propagation constatee)" }
    38 = @{ Mode = 'Automatique'; Source = "Graph beta - accessibilite du rapport + detection d'anonymisation" }
    39 = @{ Mode = 'Manuel';      Source = 'Viva Insights (pas d''API d''etat)' }
    40 = @{ Mode = 'Manuel';      Source = 'Portail Copilot (pas d''API publique)' }
    41 = @{ Mode = 'Manuel';      Source = 'Portail Copilot (pas d''API publique)' }
    42 = @{ Mode = 'Manuel';      Source = 'Portail Copilot (pas d''API publique)' }
    43 = @{ Mode = 'Manuel';      Source = 'Portail Copilot > Agents' }
    44 = @{ Mode = 'Manuel';      Source = 'Portail Copilot > Agents' }
    45 = @{ Mode = 'Automatique'; Source = 'Graph - inventaire servicePrincipals tiers' }
    46 = @{ Mode = 'Automatique'; Source = 'Graph - /external/connections' }
    47 = @{ Mode = 'Automatique'; Source = 'Exchange - Search-UnifiedAuditLog (CopilotInteraction)' }
    48 = @{ Mode = 'Manuel';      Source = 'Livrable documentaire' }
    49 = @{ Mode = 'Manuel';      Source = 'Processus organisationnel' }
    50 = @{ Mode = 'Manuel';      Source = 'Livrable documentaire' }
    51 = @{ Mode = 'Manuel';      Source = 'Rituel de gouvernance' }
    52 = @{ Mode = 'Automatique'; Source = 'Purview - Get-Label' }
    53 = @{ Mode = 'Automatique'; Source = 'Purview - Get-LabelPolicy' }
    54 = @{ Mode = 'Automatique'; Source = 'Purview - Get-AutoSensitivityLabelPolicy' }
    55 = @{ Mode = 'Automatique'; Source = 'Purview - Get-DlpCompliancePolicy (couverture 4 workloads)' }
    56 = @{ Mode = 'Automatique'; Source = 'Purview - Get-RetentionCompliancePolicy' }
    57 = @{ Mode = 'Automatique'; Source = 'Purview - Get-UnifiedAuditLogRetentionPolicy' }
    58 = @{ Mode = 'Manuel';      Source = 'Test fonctionnel eDiscovery' }
    59 = @{ Mode = 'Manuel';      Source = 'Rapports Purview DAG' }
}

$catalog = Get-Content -Path $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json

$counts = @{ 'Automatique' = 0; 'Poste local' = 0; 'Manuel' = 0 }
foreach ($m in $map.Values) { $counts[$m.Mode]++ }

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Couverture des controles')
[void]$sb.AppendLine()
[void]$sb.AppendLine("Genere par ``tools/New-CceCoverageDoc.ps1``. Referentiel : $($catalog.title) v$($catalog.version) ($($catalog.itemCount) exigences).")
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Mode | Nombre | Signification |')
[void]$sb.AppendLine('| --- | ---: | --- |')
[void]$sb.AppendLine("| Automatique | $($counts['Automatique']) | Statut deduit d'une interrogation du tenant. |")
[void]$sb.AppendLine("| Poste local | $($counts['Poste local']) | Necessite ``-IncludeLocalChecks`` sur un poste de reference. |")
[void]$sb.AppendLine("| Manuel | $($counts['Manuel']) | Aucune API publique : le moteur documente la procedure et laisse le statut a valider. |")
[void]$sb.AppendLine()

foreach ($group in ($catalog.items | Group-Object Section)) {
    [void]$sb.AppendLine("## $($group.Name)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| # | Exigence | Priorite | Mode | Source interrogee |')
    [void]$sb.AppendLine('| ---: | --- | --- | --- | --- |')

    foreach ($item in ($group.Group | Sort-Object Id)) {
        $entry = $map[[int]$item.Id]
        $req = ($item.Requirement -replace '\|', '\|')
        [void]$sb.AppendLine("| $($item.Id) | $req | $($item.Priority) | $($entry.Mode) | $($entry.Source) |")
    }
    [void]$sb.AppendLine()
}

$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$sb.ToString() | Set-Content -Path $OutputPath -Encoding utf8

Write-Host "Couverture ecrite : $OutputPath" -ForegroundColor Green
Write-Host ("  Automatique : {0} | Poste local : {1} | Manuel : {2}" -f `
    $counts['Automatique'], $counts['Poste local'], $counts['Manuel'])
