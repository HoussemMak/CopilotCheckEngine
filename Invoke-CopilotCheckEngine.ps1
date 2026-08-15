#Requires -Version 7.0
<#
.SYNOPSIS
    Genere la checklist de configuration Microsoft 365 Copilot renseignee avec les
    donnees reelles du tenant, et l'exporte en XLSX et en HTML.

.DESCRIPTION
    Copilot Check Engine parcourt les 59 exigences du referentiel
    (data/checklist-catalog.json), interroge le tenant via Microsoft Graph,
    Exchange Online, Purview, SharePoint Online et Microsoft Teams, puis produit :

      - un classeur Excel (Synthese / Checklist / Preuves / Journal) ;
      - un rapport HTML autonome, filtrable et imprimable ;
      - un fichier JSON exploitable par une chaine CI ou un tableau de bord.

    Aucune modification n'est effectuee sur le tenant : le moteur est strictement
    en lecture seule.

.PARAMETER TenantId
    Identifiant (GUID) ou domaine du tenant a auditer.

.PARAMETER AdminUpn
    Compte d'administration utilise pour les connexions interactives Exchange / Purview.

.PARAMETER ClientId
    Identifiant d'application pour une execution non interactive (app-only).

.PARAMETER CertificateThumbprint
    Empreinte du certificat associe a l'application (app-only, methode recommandee).

.PARAMETER ClientSecret
    Secret client de l'application (app-only, Graph uniquement).

.PARAMETER Organization
    Domaine du tenant (ex. contoso.onmicrosoft.com), requis pour Exchange/Purview en app-only.

.PARAMETER SharePointAdminUrl
    URL du centre d'administration SharePoint. Deduite du domaine par defaut si omise.

.PARAMETER Services
    Sous-ensemble de services a interroger. Les controles portes par un service
    non selectionne sont marques « Non evalue ».

.PARAMETER OutputPath
    Repertoire de sortie des rapports. Defaut : .\output

.PARAMETER IncludeLocalChecks
    Ajoute l'inspection du poste courant (canal Office, experiences connectees).

.PARAMETER MailboxSampleSize
    Nombre de boites aux lettres analysees pour les controles Exchange. Defaut : 100.

.PARAMETER SkipConnect
    Reutilise les sessions deja ouvertes au lieu d'etablir de nouvelles connexions.

.PARAMETER KeepConnections
    Ne ferme pas les sessions en fin d'execution.

.PARAMETER OpenReport
    Ouvre le rapport HTML a la fin de l'execution.

.EXAMPLE
    .\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -AdminUpn admin@contoso.com -OpenReport

    Execution interactive complete, avec ouverture du rapport HTML.

.EXAMPLE
    .\Invoke-CopilotCheckEngine.ps1 -TenantId <guid> -ClientId <guid> -CertificateThumbprint <hash> -Organization contoso.onmicrosoft.com

    Execution non interactive (planifiee).

.EXAMPLE
    .\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -Services Graph,Teams

    Audit partiel limite a Microsoft Graph et Microsoft Teams.

.NOTES
    Lecture seule. Aucune commande de modification n'est appelee.
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $AdminUpn,
    [string] $ClientId,
    [string] $CertificateThumbprint,
    [string] $ClientSecret,
    [string] $Organization,
    [string] $SharePointAdminUrl,

    [ValidateSet('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams')]
    [string[]] $Services = @('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams'),

    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [string] $CatalogPath = (Join-Path $PSScriptRoot 'data\checklist-catalog.json'),

    [switch] $IncludeLocalChecks,
    [int]    $MailboxSampleSize = 100,
    [switch] $SkipConnect,
    [switch] $KeepConnections,
    [switch] $OpenReport,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Chargement du moteur
# ---------------------------------------------------------------------------
foreach ($folder in 'Private', 'Checks', 'Export') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot "src\$folder") -Filter '*.ps1' -ErrorAction Stop |
        Sort-Object Name |
        ForEach-Object { . $_.FullName }
}

if (-not (Test-Path $CatalogPath)) {
    throw "Catalogue introuvable : $CatalogPath. Executer tools\Convert-XlsxToCatalog.ps1 pour le regenerer."
}

$catalog = Get-Content -Path $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Contexte
# ---------------------------------------------------------------------------
$script:CceContext = New-CceContext -Configuration @{
    IncludeLocalChecks = [bool] $IncludeLocalChecks
    MailboxSampleSize  = $MailboxSampleSize
    CatalogTitle       = $catalog.title
    CatalogVersion     = $catalog.version
    RequestedServices  = $Services
}
$Context = $script:CceContext

Write-Host ''
Write-Host '  Copilot Check Engine' -ForegroundColor Cyan
Write-Host ('  {0} v{1} - {2} exigences' -f $catalog.title, $catalog.version, $catalog.itemCount) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Connexions
# ---------------------------------------------------------------------------
if ($SkipConnect) {
    Write-CceLog 'Reutilisation des sessions existantes (-SkipConnect)' -Level INFO

    foreach ($svc in @($Context.Services.Keys)) {
        if ($svc -notin $Services) { continue }
        $probe = switch ($svc) {
            'Graph'      { { $null -ne (Get-MgContext) } }
            'Exchange'   { { $null -ne (Get-OrganizationConfig -ErrorAction Stop) } }
            'Purview'    { { $null -ne (Get-Label -ErrorAction Stop) } }
            'SharePoint' { { $null -ne (Get-SPOTenant -ErrorAction Stop) } }
            'Teams'      { { $null -ne (Get-CsTeamsMeetingPolicy -Identity Global -ErrorAction Stop) } }
        }
        $Context.Services.$svc = [bool] (Get-CceSafe $probe -What "sonde $svc")
    }

    if ($Context.Services.Graph) {
        $mg = Get-MgContext
        $Context.Tenant.Id = $mg.TenantId
        $org = Get-CceSafe { Get-MgOrganization -ErrorAction Stop } -What 'Get-MgOrganization'
        if ($org) {
            $Context.Tenant.Name = $org.DisplayName
            $Context.Tenant.DefaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsInitial }).Name
        }
    }
}
else {
    $auth = @{
        TenantId              = $TenantId
        AdminUpn              = $AdminUpn
        ClientId              = $ClientId
        CertificateThumbprint = $CertificateThumbprint
        ClientSecret          = $ClientSecret
        Organization          = if ($Organization) { $Organization } else { $TenantId }
        SharePointAdminUrl    = $SharePointAdminUrl
    }

    Connect-CceServices -Context $Context -Auth $auth -Services $Services
}

if (-not ($Context.Services.Values -contains $true)) {
    throw "Aucun service n'a pu etre contacte : verifier les identifiants, les droits et la connectivite."
}

# ---------------------------------------------------------------------------
# Execution des controles
# ---------------------------------------------------------------------------
Write-Host ''
Write-CceLog ("Execution des {0} controles..." -f $catalog.itemCount) -Level STEP

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($item in $catalog.items) {
    $index++
    $functionName = 'Invoke-CceCheck{0:D2}' -f $item.Id

    Write-Progress -Activity 'Copilot Check Engine' `
        -Status ("[{0}/{1}] {2}" -f $index, $catalog.itemCount, $item.Requirement) `
        -PercentComplete (100 * $index / $catalog.itemCount)

    if (Get-Command $functionName -ErrorAction SilentlyContinue) {
        try {
            $outcome = & $functionName -Context $Context
        }
        catch {
            $outcome = New-CceResult -Status 'Non evalue' `
                -Observed 'Erreur pendant le controle' `
                -Evidence $_.Exception.Message `
                -Remediation "Consulter l'onglet Journal et relancer le controle isolement."
            Write-CceLog ("Controle {0} en erreur : {1}" -f $item.Id, $_.Exception.Message) -Level ERROR
        }
    }
    else {
        $outcome = New-CceResult -Status 'Non evalue' `
            -Observed 'Controle non implemente' `
            -Evidence "Aucune fonction $functionName dans src\Checks."
    }

    $results.Add([pscustomobject]@{
        Id                   = $item.Id
        Section              = $item.Section
        Categorie            = $item.Category
        Requirement          = $item.Requirement
        Priorite             = $item.Priority
        Statut               = $outcome.Status
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

Write-Progress -Activity 'Copilot Check Engine' -Completed

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$slug = if ($Context.Tenant.DefaultDomain) {
    ($Context.Tenant.DefaultDomain -replace '\.onmicrosoft\.com$', '') -replace '[^\w\-]', '_'
}
elseif ($Context.Tenant.Id) { $Context.Tenant.Id }
else { 'tenant' }

$stamp = $Context.StartedAt.ToString('yyyyMMdd-HHmmss')
$base = Join-Path $OutputPath ("CopilotCheck_{0}_{1}" -f $slug, $stamp)

Write-Host ''
Write-CceLog 'Generation des rapports...' -Level STEP

$xlsxPath = Export-CceExcel -Results $results -Context $Context -Path "$base.xlsx"
$htmlPath = Export-CceHtml  -Results $results -Context $Context -Path "$base.html"

$jsonPath = "$base.json"
[pscustomobject]@{
    tenant     = $Context.Tenant
    generated  = $Context.StartedAt
    catalog    = @{ title = $catalog.title; version = $catalog.version; items = $catalog.itemCount }
    services   = $Context.Services
    statistics = Get-CceStatistics -Results $results
    results    = $results
} | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8
Write-CceLog "Export JSON : $jsonPath" -Level OK

# ---------------------------------------------------------------------------
# Restitution console
# ---------------------------------------------------------------------------
$stats = Get-CceStatistics -Results $results

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ('  Tenant                     : {0}' -f $(if ($Context.Tenant.Name) { $Context.Tenant.Name } else { $Context.Tenant.Id }))
Write-Host ('  Exigences controlees       : {0}' -f $stats.Total)
Write-Host ('  Conformes                  : {0}' -f $stats.Conforme)          -ForegroundColor Green
Write-Host ('  Non conformes              : {0}' -f $stats.NonConforme)       -ForegroundColor Red
Write-Host ('  Points d''attention         : {0}' -f $stats.Attention)        -ForegroundColor Yellow
Write-Host ('  Verification manuelle      : {0}' -f $stats.Manuel)            -ForegroundColor Cyan
Write-Host ('  Non evalues                : {0}' -f $stats.NonEvalue)         -ForegroundColor DarkGray
Write-Host ('  Taux de conformite         : {0} %' -f $stats.TauxConformite)  -ForegroundColor Cyan
Write-Host ('  Bloquants non conformes    : {0}' -f $stats.BloquantsKo.Count) -ForegroundColor $(if ($stats.BloquantsKo.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

if ($stats.BloquantsKo.Count -gt 0) {
    Write-Host ''
    Write-Host '  Exigences bloquantes a traiter en priorite :' -ForegroundColor Red
    foreach ($b in $stats.BloquantsKo) {
        Write-Host ('   #{0,-3} {1}' -f $b.Id, $b.Requirement) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('  XLSX : {0}' -f $xlsxPath) -ForegroundColor White
Write-Host ('  HTML : {0}' -f $htmlPath) -ForegroundColor White
Write-Host ('  JSON : {0}' -f $jsonPath) -ForegroundColor White
Write-Host ''

if ($OpenReport) { Invoke-Item $htmlPath }
if (-not $KeepConnections -and -not $SkipConnect) { Disconnect-CceServices -Context $Context }

if ($PassThru) {
    [pscustomobject]@{
        Results    = $results
        Statistics = $stats
        Context    = $Context
        Reports    = [pscustomobject]@{ Xlsx = $xlsxPath; Html = $htmlPath; Json = $jsonPath }
    }
}
