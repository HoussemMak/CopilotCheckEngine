#Requires -Version 7.0
<#
.SYNOPSIS
    Genere un rapport de demonstration a partir de donnees synthetiques.

.DESCRIPTION
    Ne se connecte a aucun tenant : sert de test de fumee pour la chaine d'export
    (XLSX + HTML + JSON) et produit les exemples publies dans samples/.

.EXAMPLE
    .\tools\New-CceDemoReport.ps1 -OutputPath .\samples
#>
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot '..\samples'),
    [string] $CatalogPath = (Join-Path $PSScriptRoot '..\data\checklist-catalog.json'),
    [int]    $Seed = 20260415
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
foreach ($folder in 'Private', 'Checks', 'Export') {
    Get-ChildItem -Path (Join-Path $root "src\$folder") -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
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

Write-CceLog 'Generation de donnees de demonstration (aucun tenant contacte)' -Level INFO

# Exigences reellement non automatisables : elles restent en "Manuel" dans la demo.
$manualIds = @(6, 9, 20, 21, 36, 39, 40, 41, 42, 43, 44, 48, 49, 50, 51, 58, 59)
$random = [Random]::new($Seed)

$observedSamples = @{
    Conforme       = 'Valeur constatee conforme a la cible'
    'Non conforme' = 'Ecart constate par rapport a la valeur attendue'
    Attention      = 'Configuration partielle : arbitrage requis'
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($item in $catalog.items) {
    if ($item.Id -in $manualIds) {
        $status = 'Manuel'
        $observed = 'Verification manuelle requise (aucune API publique)'
        $remediation = 'Valider le parametre dans le portail d''administration concerne.'
    }
    else {
        $roll = $random.Next(0, 100)
        $status = if ($roll -lt 58) { 'Conforme' } elseif ($roll -lt 80) { 'Non conforme' } elseif ($roll -lt 93) { 'Attention' } else { 'Non evalue' }
        $observed = if ($observedSamples.ContainsKey($status)) { $observedSamples[$status] } else { 'Service non connecte lors de cette execution' }
        $remediation = if ($status -in @('Non conforme', 'Attention')) { "Appliquer la procedure : $($item.HowTo -split "`n" | Select-Object -First 1)" } else { '' }
    }

    $results.Add([pscustomobject]@{
        Id                   = $item.Id
        Section              = $item.Section
        Categorie            = $item.Category
        Requirement          = $item.Requirement
        Priorite             = $item.Priority
        Statut               = $status
        ValeurConstatee      = $observed
        ValeurAttendue       = $item.Expected
        ActionCorrective     = $remediation
        Preuve               = "Donnees de demonstration - controle $($item.Id)"
        Pourquoi             = $item.Rationale
        Procedure            = $item.HowTo
        CommandeVerification = $item.Verification
        Reference            = $item.Reference
    })
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$base = Join-Path $OutputPath 'CopilotCheck_demo'

Export-CceExcel -Results $results -Context $Context -Path "$base.xlsx" | Out-Null
Export-CceHtml  -Results $results -Context $Context -Path "$base.html" | Out-Null

$stats = Get-CceStatistics -Results $results
Write-Host ''
Write-Host ('Demo generee : {0} exigences, {1} conformes, {2} non conformes, taux {3} %' -f `
    $stats.Total, $stats.Conforme, $stats.NonConforme, $stats.TauxConformite) -ForegroundColor Green
Write-Host ("  $base.xlsx")
Write-Host ("  $base.html")
