#Requires -Version 7.0
<#
.SYNOPSIS
    Genere un rapport de demonstration a partir de donnees synthetiques.

.DESCRIPTION
    Ne se connecte a aucun tenant : sert de test de fumee pour la chaine d'export
    (XLSX + HTML) et produit les exemples publies dans samples/.

.EXAMPLE
    .\tools\New-CceDemoReport.ps1
    .\tools\New-CceDemoReport.ps1 -Language en
#>
[CmdletBinding()]
param(
    [ValidateSet('fr', 'en')] [string] $Language = 'fr',
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\samples'),
    [string] $CatalogPath,
    [int]    $Seed = 20260415
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
foreach ($folder in 'Private', 'Checks', 'Export') {
    Get-ChildItem -Path (Join-Path $root "src\$folder") -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
}

Import-CceStrings -Language $Language -DataPath (Join-Path $root 'data') | Out-Null

if (-not $CatalogPath) {
    $CatalogPath = if ($Language -eq 'fr') {
        Join-Path $root 'data\checklist-catalog.json'
    }
    else {
        Join-Path $root "data\checklist-catalog.$Language.json"
    }
}

$catalog = Get-Content -Path $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json

$script:CceContext = New-CceContext -Configuration @{
    IncludeLocalChecks = $false
    MailboxSampleSize  = 100
    CatalogTitle       = $catalog.title
    CatalogVersion     = $catalog.version
}
$Context = $script:CceContext
$Context.Tenant.Id = '00000000-1111-2222-3333-444444444444'
$Context.Tenant.Name = 'Contoso Demo'
$Context.Tenant.DefaultDomain = 'contosodemo.onmicrosoft.com'
foreach ($k in @($Context.Services.Keys)) { $Context.Services.$k = $true }

Write-CceLog "Donnees de demonstration - langue $Language (aucun tenant contacte)" -Level INFO

# Exigences reellement non automatisables : elles restent en "Manuel" dans la demo.
$manualIds = @(6, 9, 20, 21, 36, 39, 40, 41, 42, 43, 44, 48, 49, 50, 51, 58, 59)
$random = [Random]::new($Seed)

$results = [System.Collections.Generic.List[object]]::new()

foreach ($item in $catalog.items) {
    if ($item.Id -in $manualIds) {
        $status = 'Manuel'
        $observed = T 'demo.obs.manual'
        $remediation = T 'demo.rem.manual'
    }
    else {
        $roll = $random.Next(0, 100)
        $status = if ($roll -lt 58) { 'Conforme' } elseif ($roll -lt 80) { 'Non conforme' } elseif ($roll -lt 93) { 'Attention' } else { 'Non evalue' }

        $observed = switch ($status) {
            'Conforme'     { T 'demo.obs.ok' }
            'Non conforme' { T 'demo.obs.ko' }
            'Attention'    { T 'demo.obs.warn' }
            default        { T 'demo.obs.na' }
        }

        $remediation = if ($status -in @('Non conforme', 'Attention')) {
            (T 'demo.rem.default') -f (($item.HowTo -split "`n" | Select-Object -First 1).Trim())
        }
        else { '' }
    }

    $outcome = New-CceResult -Status $status -Observed $observed -Remediation $remediation `
        -Evidence ((T 'demo.evidence') -f $item.Id)

    $priorityToken = ConvertTo-CceCanonicalPriority -Priority $item.Priority

    $phase = if ($item.PSObject.Properties.Name -contains 'Phase' -and $item.Phase) { $item.Phase } else { 'pre-deployment' }

    $results.Add([pscustomobject]@{
        Id                   = $item.Id
        Section              = $item.Section
        Categorie            = $item.Category
        Requirement          = $item.Requirement
        Phase                = $phase
        PhaseLibelle         = T "phase.$phase"
        Mode                 = if ($item.PSObject.Properties.Name -contains 'Mode') { $item.Mode } else { '' }
        AuthMode             = if ($item.PSObject.Properties.Name -contains 'AuthMode') { $item.AuthMode } else { 'both' }
        LicenceRequise       = if ($item.PSObject.Properties.Name -contains 'RequiresLicense') { $item.RequiresLicense } else { '' }
        Notee                = if ($item.PSObject.Properties.Name -contains 'Scored') { [bool] $item.Scored } else { $true }
        Priorite             = $priorityToken
        PrioriteLibelle      = Get-CcePriorityLabel -Priority $priorityToken
        Statut               = $outcome.Status
        StatutLibelle        = Get-CceStatusLabel -Status $outcome.Status
        ValeurConstatee      = $outcome.Observed
        ValeurAttendue       = $item.Expected
        ActionCorrective     = $outcome.Remediation
        Preuve               = $outcome.Evidence
        Pourquoi             = $item.Rationale
        Procedure            = $item.HowTo
        CommandeVerification = $item.Verification
        Reference            = $item.Reference
    })
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$suffix = if ($Language -eq 'fr') { '' } else { ".$Language" }
$base = Join-Path $OutputPath "CopilotCheck_demo$suffix"

Export-CceExcel -Results $results -Context $Context -Path "$base.xlsx" | Out-Null
Export-CceHtml  -Results $results -Context $Context -Path "$base.html" | Out-Null

$stats = Get-CceStatistics -Results $results
Write-Host ''
Write-Host ('Demo [{0}] : {1} exigences, {2} conformes, {3} non conformes, taux {4} %' -f `
    $Language.ToUpper(), $stats.Total, $stats.Conforme, $stats.NonConforme, $stats.TauxConformite) -ForegroundColor Green
Write-Host "  $base.xlsx"
Write-Host "  $base.html"
