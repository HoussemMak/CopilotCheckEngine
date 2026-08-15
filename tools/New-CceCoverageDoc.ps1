#Requires -Version 7.0
<#
.SYNOPSIS
    Genere docs/COVERAGE.md et docs/COVERAGE.en.md : la source de donnees de chaque controle.

.DESCRIPTION
    Le tableau de couverture est derive du catalogue et de la table de correspondance
    ci-dessous, afin de rester synchronise avec le referentiel.

.EXAMPLE
    .\tools\New-CceCoverageDoc.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Id -> mode + source interrogee. Mode : Auto | Local | Manual
# Table de hachage classique et non [ordered] : un dictionnaire ordonne s'indexe
# par position lorsqu'on lui passe un entier, ce qui casserait $map[[int]$item.Id].
$map = @{
    1  = @{ Mode = 'Auto';   Fr = 'Graph - Get-MgSubscribedSku'; En = 'Graph - Get-MgSubscribedSku' }
    2  = @{ Mode = 'Auto';   Fr = 'Graph - Get-MgSubscribedSku'; En = 'Graph - Get-MgSubscribedSku' }
    3  = @{ Mode = 'Auto';   Fr = 'Graph - Get-MgUser (filtre assignedLicenses)'; En = 'Graph - Get-MgUser (assignedLicenses filter)' }
    4  = @{ Mode = 'Auto';   Fr = 'Graph - /groups?$filter=assignedLicenses'; En = 'Graph - /groups?$filter=assignedLicenses' }
    5  = @{ Mode = 'Auto';   Fr = 'Graph beta - /directory/subscriptions'; En = 'Graph beta - /directory/subscriptions' }
    6  = @{ Mode = 'Local';  Fr = 'Registre ClickToRun (-IncludeLocalChecks) + rapport M365 Apps'; En = 'ClickToRun registry (-IncludeLocalChecks) + M365 Apps usage report' }
    7  = @{ Mode = 'Auto';   Fr = 'Graph beta - /admin/microsoft365Apps/installationOptions (+ registre local)'; En = 'Graph beta - /admin/microsoft365Apps/installationOptions (+ local registry)' }
    8  = @{ Mode = 'Auto';   Fr = 'Exchange - Get-OrganizationConfig'; En = 'Exchange - Get-OrganizationConfig' }
    9  = @{ Mode = 'Local';  Fr = 'Registre Office privacy (-IncludeLocalChecks)'; En = 'Office privacy registry (-IncludeLocalChecks)' }
    10 = @{ Mode = 'Auto';   Fr = 'Graph - /identity/conditionalAccess/policies'; En = 'Graph - /identity/conditionalAccess/policies' }
    11 = @{ Mode = 'Auto';   Fr = 'Graph - analyse des controles block sur Microsoft Graph'; En = 'Graph - analysis of block controls targeting Microsoft Graph' }
    12 = @{ Mode = 'Auto';   Fr = 'Graph - analyse des controles block sur Office 365'; En = 'Graph - analysis of block controls targeting Office 365' }
    13 = @{ Mode = 'Auto';   Fr = 'Graph - suffixes UPN'; En = 'Graph - UPN suffixes' }
    14 = @{ Mode = 'Auto';   Fr = 'Graph - comptes desactives licencies'; En = 'Graph - licensed disabled accounts' }
    15 = @{ Mode = 'Auto';   Fr = 'Graph - comptes invites licencies'; En = 'Graph - licensed guest accounts' }
    16 = @{ Mode = 'Auto';   Fr = 'SharePoint - Get-SPOTenant'; En = 'SharePoint - Get-SPOTenant' }
    17 = @{ Mode = 'Auto';   Fr = 'SharePoint - Get-SPOTenant'; En = 'SharePoint - Get-SPOTenant' }
    18 = @{ Mode = 'Auto';   Fr = 'SharePoint - Get-SPOSite (detection mots-cles sensibles)'; En = 'SharePoint - Get-SPOSite (sensitive keyword detection)' }
    19 = @{ Mode = 'Auto';   Fr = 'SharePoint - Get-SPOSite -IncludePersonalSite + Graph'; En = 'SharePoint - Get-SPOSite -IncludePersonalSite + Graph' }
    20 = @{ Mode = 'Manual'; Fr = 'Test fonctionnel Microsoft Search'; En = 'Microsoft Search functional test' }
    21 = @{ Mode = 'Manual'; Fr = 'PnP.PowerShell par site (Get-PnPWeb -Includes NoCrawl)'; En = 'PnP.PowerShell per site (Get-PnPWeb -Includes NoCrawl)' }
    22 = @{ Mode = 'Auto';   Fr = 'SharePoint - Get-SPOTenantRestrictedSearchMode'; En = 'SharePoint - Get-SPOTenantRestrictedSearchMode' }
    23 = @{ Mode = 'Auto';   Fr = 'SharePoint - Get-SPOTenant (OneDriveStorageQuota)'; En = 'SharePoint - Get-SPOTenant (OneDriveStorageQuota)' }
    24 = @{ Mode = 'Auto';   Fr = 'Exchange - Get-Mailbox (echantillon Copilot)'; En = 'Exchange - Get-Mailbox (Copilot sample)' }
    25 = @{ Mode = 'Auto';   Fr = 'Exchange - Get-CASMailbox'; En = 'Exchange - Get-CASMailbox' }
    26 = @{ Mode = 'Auto';   Fr = 'Exchange - Get-AdminAuditLogConfig + Get-OrganizationConfig'; En = 'Exchange - Get-AdminAuditLogConfig + Get-OrganizationConfig' }
    27 = @{ Mode = 'Auto';   Fr = 'Teams - Get-CsTeamsAppPermissionPolicy + Graph appCatalogs'; En = 'Teams - Get-CsTeamsAppPermissionPolicy + Graph appCatalogs' }
    28 = @{ Mode = 'Auto';   Fr = 'Teams - Get-CsTeamsAppSetupPolicy + Graph appCatalogs'; En = 'Teams - Get-CsTeamsAppSetupPolicy + Graph appCatalogs' }
    29 = @{ Mode = 'Auto';   Fr = 'Teams - Get-CsTeamsMeetingPolicy (AllowTranscription)'; En = 'Teams - Get-CsTeamsMeetingPolicy (AllowTranscription)' }
    30 = @{ Mode = 'Auto';   Fr = 'Teams - Get-CsTeamsMeetingPolicy (AllowCloudRecording)'; En = 'Teams - Get-CsTeamsMeetingPolicy (AllowCloudRecording)' }
    31 = @{ Mode = 'Auto';   Fr = 'Teams - Get-CsTeamsMeetingPolicy (CopilotMode)'; En = 'Teams - Get-CsTeamsMeetingPolicy (CopilotMode)' }
    32 = @{ Mode = 'Auto';   Fr = 'Teams - Get-CsTeamsMeetingPolicy (sous-titres)'; En = 'Teams - Get-CsTeamsMeetingPolicy (captions)' }
    33 = @{ Mode = 'Auto';   Fr = "Graph beta - rapport d'usage Copilot (preuve d'activite)"; En = 'Graph beta - Copilot usage report (evidence of activity)' }
    34 = @{ Mode = 'Auto';   Fr = "Graph beta - rapport d'usage Copilot par workload"; En = 'Graph beta - Copilot usage report per workload' }
    35 = @{ Mode = 'Auto';   Fr = 'Graph beta - activite Copilot Chat'; En = 'Graph beta - Copilot Chat activity' }
    36 = @{ Mode = 'Manual'; Fr = 'Decision de gouvernance a documenter'; En = 'Governance decision to document' }
    37 = @{ Mode = 'Auto';   Fr = "Graph beta - rapport d'usage (propagation constatee)"; En = 'Graph beta - usage report (observed propagation)' }
    38 = @{ Mode = 'Auto';   Fr = "Graph beta - accessibilite du rapport + detection d'anonymisation"; En = 'Graph beta - report reachability + anonymisation detection' }
    39 = @{ Mode = 'Manual'; Fr = "Viva Insights (pas d'API d'etat)"; En = 'Viva Insights (no status API)' }
    40 = @{ Mode = 'Manual'; Fr = "Portail Copilot (pas d'API publique)"; En = 'Copilot portal (no public API)' }
    41 = @{ Mode = 'Manual'; Fr = "Portail Copilot (pas d'API publique)"; En = 'Copilot portal (no public API)' }
    42 = @{ Mode = 'Manual'; Fr = "Portail Copilot (pas d'API publique)"; En = 'Copilot portal (no public API)' }
    43 = @{ Mode = 'Manual'; Fr = 'Portail Copilot > Agents'; En = 'Copilot portal > Agents' }
    44 = @{ Mode = 'Manual'; Fr = 'Portail Copilot > Agents'; En = 'Copilot portal > Agents' }
    45 = @{ Mode = 'Auto';   Fr = 'Graph - inventaire servicePrincipals tiers'; En = 'Graph - third-party servicePrincipals inventory' }
    46 = @{ Mode = 'Auto';   Fr = 'Graph - /external/connections'; En = 'Graph - /external/connections' }
    47 = @{ Mode = 'Auto';   Fr = 'Exchange - Search-UnifiedAuditLog (CopilotInteraction)'; En = 'Exchange - Search-UnifiedAuditLog (CopilotInteraction)' }
    48 = @{ Mode = 'Manual'; Fr = 'Livrable documentaire'; En = 'Documentation deliverable' }
    49 = @{ Mode = 'Manual'; Fr = 'Processus organisationnel'; En = 'Organisational process' }
    50 = @{ Mode = 'Manual'; Fr = 'Livrable documentaire'; En = 'Documentation deliverable' }
    51 = @{ Mode = 'Manual'; Fr = 'Rituel de gouvernance'; En = 'Governance ritual' }
    52 = @{ Mode = 'Auto';   Fr = 'Purview - Get-Label'; En = 'Purview - Get-Label' }
    53 = @{ Mode = 'Auto';   Fr = 'Purview - Get-LabelPolicy'; En = 'Purview - Get-LabelPolicy' }
    54 = @{ Mode = 'Auto';   Fr = 'Purview - Get-AutoSensitivityLabelPolicy'; En = 'Purview - Get-AutoSensitivityLabelPolicy' }
    55 = @{ Mode = 'Auto';   Fr = 'Purview - Get-DlpCompliancePolicy (couverture 4 workloads)'; En = 'Purview - Get-DlpCompliancePolicy (4-workload coverage)' }
    56 = @{ Mode = 'Auto';   Fr = 'Purview - Get-RetentionCompliancePolicy'; En = 'Purview - Get-RetentionCompliancePolicy' }
    57 = @{ Mode = 'Auto';   Fr = 'Purview - Get-UnifiedAuditLogRetentionPolicy'; En = 'Purview - Get-UnifiedAuditLogRetentionPolicy' }
    58 = @{ Mode = 'Manual'; Fr = 'Test fonctionnel eDiscovery'; En = 'eDiscovery functional test' }
    59 = @{ Mode = 'Manual'; Fr = 'Rapports Purview DAG'; En = 'Purview DAG reports' }
}

$labels = @{
    fr = @{
        Title      = '# Couverture des controles'
        Intro      = 'Genere par `tools/New-CceCoverageDoc.ps1`. Referentiel : {0} v{1} ({2} exigences).'
        ModeHeader = '| Mode | Nombre | Signification |'
        ModeSep    = '| --- | ---: | --- |'
        Auto       = 'Automatique'
        Local      = 'Poste local'
        Manual     = 'Manuel'
        AutoDesc   = "Statut deduit d'une interrogation du tenant."
        LocalDesc  = 'Necessite `-IncludeLocalChecks` sur un poste de reference.'
        ManualDesc = 'Aucune API publique : le moteur documente la procedure et laisse le statut a valider.'
        TableHead  = '| # | Exigence | Priorite | Mode | Source interrogee |'
        TableSep   = '| ---: | --- | --- | --- | --- |'
    }
    en = @{
        Title      = '# Check coverage'
        Intro      = 'Generated by `tools/New-CceCoverageDoc.ps1`. Baseline: {0} v{1} ({2} requirements).'
        ModeHeader = '| Mode | Count | Meaning |'
        ModeSep    = '| --- | ---: | --- |'
        Auto       = 'Automatic'
        Local      = 'Workstation'
        Manual     = 'Manual'
        AutoDesc   = 'Status derived from a tenant query.'
        LocalDesc  = 'Requires `-IncludeLocalChecks` on a reference workstation.'
        ManualDesc = 'No public API: the engine documents the procedure and leaves the status to be validated.'
        TableHead  = '| # | Requirement | Priority | Mode | Source queried |'
        TableSep   = '| ---: | --- | --- | --- | --- |'
    }
}

$targets = @(
    @{ Lang = 'fr'; Catalog = 'data\checklist-catalog.json';    Output = 'docs\COVERAGE.md' }
    @{ Lang = 'en'; Catalog = 'data\checklist-catalog.en.json'; Output = 'docs\COVERAGE.en.md' }
)

foreach ($target in $targets) {
    $catalogPath = Join-Path $Root $target.Catalog
    if (-not (Test-Path $catalogPath)) {
        Write-Warning "Catalogue absent, ignore : $catalogPath"
        continue
    }

    $catalog = Get-Content -Path $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json
    $L = $labels[$target.Lang]

    $counts = @{ Auto = 0; Local = 0; Manual = 0 }
    foreach ($entry in $map.Values) { $counts[$entry.Mode]++ }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine($L.Title)
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(($L.Intro -f $catalog.title, $catalog.version, $catalog.itemCount))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine($L.ModeHeader)
    [void]$sb.AppendLine($L.ModeSep)
    [void]$sb.AppendLine("| $($L.Auto) | $($counts.Auto) | $($L.AutoDesc) |")
    [void]$sb.AppendLine("| $($L.Local) | $($counts.Local) | $($L.LocalDesc) |")
    [void]$sb.AppendLine("| $($L.Manual) | $($counts.Manual) | $($L.ManualDesc) |")
    [void]$sb.AppendLine()

    foreach ($group in ($catalog.items | Group-Object Section)) {
        [void]$sb.AppendLine("## $($group.Name)")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine($L.TableHead)
        [void]$sb.AppendLine($L.TableSep)

        foreach ($item in ($group.Group | Sort-Object Id)) {
            $entry = $map[[int]$item.Id]
            $mode = $L[$entry.Mode]
            $source = if ($target.Lang -eq 'fr') { $entry.Fr } else { $entry.En }
            $req = ($item.Requirement -replace '\|', '\|')
            [void]$sb.AppendLine("| $($item.Id) | $req | $($item.Priority) | $mode | $source |")
        }
        [void]$sb.AppendLine()
    }

    $outputPath = Join-Path $Root $target.Output
    $dir = Split-Path -Parent $outputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sb.ToString() | Set-Content -Path $outputPath -Encoding utf8

    Write-Host ("Couverture [{0}] : {1}" -f $target.Lang.ToUpper(), $outputPath) -ForegroundColor Green
}

Write-Host ("  Automatique : {0} | Poste local : {1} | Manuel : {2}" -f $counts.Auto, $counts.Local, $counts.Manual)
