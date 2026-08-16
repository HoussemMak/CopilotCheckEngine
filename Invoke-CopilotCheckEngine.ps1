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

.PARAMETER Language
    Langue des rapports : 'fr' (defaut) ou 'en'. Pilote le referentiel charge
    (data/checklist-catalog[.en].json) et l'ensemble des libelles.
    Report language: 'fr' (default) or 'en'.

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

.EXAMPLE
    .\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -Language en -OpenReport

    Rapports en anglais. / English reports.

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

    # PowerPlatform et Commerce ne sont pas dans la valeur par defaut : ce sont des
    # domaines d'administration distincts, qui exigent un role et un consentement
    # supplementaires chez le client. A demander explicitement.
    [ValidateSet('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams', 'PowerPlatform', 'Commerce')]
    [string[]] $Services = @('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams'),

    [ValidateSet('fr', 'en')]
    [string] $Language = 'fr',

    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [string] $CatalogPath,

    [switch] $IncludeLocalChecks,
    [int]    $MailboxSampleSize = 100,

    # Terme metier connu et indexe, utilise par la sonde fonctionnelle de l'index
    # semantique. Sans valeur, la sonde reste manuelle plutot que de produire un
    # faux ecart.
    [string] $RetrievalProbeTerm,

    # Autorise le declenchement des rapports qui n'existent pas encore (gouvernance
    # d'acces aux donnees, agents SharePoint). Desactive par defaut : le moteur est
    # sans effet de bord tant que ce commutateur n'est pas passe explicitement.
    [switch] $AllowReportGeneration,

    # Expression reguliere de la convention de nommage des agents, propre au client.
    # Sans valeur, le controle inventorie les agents sans juger leur nom.
    [string] $AgentNamingPattern,
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

# Ressources de langue : a charger avant tout appel a T.
$langInfo = Import-CceStrings -Language $Language -DataPath (Join-Path $PSScriptRoot 'data')

if (-not $CatalogPath) {
    $CatalogPath = if ($Language -eq 'fr') {
        Join-Path $PSScriptRoot 'data\checklist-catalog.json'
    }
    else {
        Join-Path $PSScriptRoot "data\checklist-catalog.$Language.json"
    }
}

if (-not (Test-Path $CatalogPath)) {
    throw ((T 'cli.catalog.missing') -f $CatalogPath)
}

$catalog = Get-Content -Path $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Contexte
# ---------------------------------------------------------------------------
$script:CceContext = New-CceContext -Configuration @{
    IncludeLocalChecks    = [bool] $IncludeLocalChecks
    MailboxSampleSize     = $MailboxSampleSize
    CatalogTitle          = $catalog.title
    CatalogVersion        = $catalog.version
    RequestedServices     = $Services
    RetrievalProbeTerm    = $RetrievalProbeTerm
    AllowReportGeneration = [bool] $AllowReportGeneration
    AgentNamingPattern    = $AgentNamingPattern
    # Renseigne apres connexion : plusieurs sondes n'existent qu'en delegue.
    AuthMode              = if ($ClientId -and ($CertificateThumbprint -or $ClientSecret)) { 'application' } else { 'delegated' }
}
$Context = $script:CceContext

Write-Host ''
Write-Host '  Copilot Check Engine' -ForegroundColor Cyan
Write-Host ('  ' + ((T 'cli.catalog') -f $catalog.title, $catalog.version, $catalog.itemCount)) -ForegroundColor DarkGray
Write-Host ('  ' + ((T 'cli.lang.loaded') -f $langInfo.Language.ToUpper(), $langInfo.Loaded)) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
# Connexions
# ---------------------------------------------------------------------------
if ($SkipConnect) {
    Write-CceLog (T 'cli.reuse') -Level INFO

    foreach ($svc in @($Context.Services.Keys)) {
        if ($svc -notin $Services) { continue }
        $probe = switch ($svc) {
            'Graph'      { { $null -ne (Get-MgContext) } }
            'Exchange'   { { $null -ne (Get-OrganizationConfig -ErrorAction Stop) } }
            'Purview'    { { $null -ne (Get-Label -ErrorAction Stop) } }
            'SharePoint' { { $null -ne (Get-SPOTenant -ErrorAction Stop) } }
            'Teams'      { { $null -ne (Get-CsTeamsMeetingPolicy -Identity Global -ErrorAction Stop) } }
            'PowerPlatform' { { $null -ne (Get-Command Get-AdminPowerApp -ErrorAction Stop) } }
            'Commerce'      { { $null -ne (Get-Command Get-MSCommerceProductPolicies -ErrorAction Stop) } }
        }
        $Context.Services.$svc = [bool] (Get-CceSafe $probe -What ((T 'conn.probe') -f $svc))
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
    throw (T 'cli.noservice')
}

# ---------------------------------------------------------------------------
# Execution des controles
# ---------------------------------------------------------------------------
Write-Host ''
Write-CceLog ((T 'cli.running') -f $catalog.itemCount) -Level STEP

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
                -Observed (T 'cli.check.error.obs') `
                -Evidence $_.Exception.Message `
                -Remediation (T 'cli.check.error.rem')
            Write-CceLog ((T 'cli.check.error') -f $item.Id, $_.Exception.Message) -Level ERROR
        }
    }
    else {
        $outcome = New-CceResult -Status 'Non evalue' `
            -Observed (T 'cli.check.missing.obs') `
            -Evidence ((T 'cli.check.missing.ev') -f $functionName)
    }

    # Le catalogue est localise : on conserve le libelle tel quel pour l'affichage
    # et on derive le jeton canonique pour toute la logique de calcul.
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
$base = Join-Path $OutputPath ("CopilotCheck_{0}_{1}_{2}" -f $slug, $Language, $stamp)

Write-Host ''
Write-CceLog (T 'cli.reports') -Level STEP

$xlsxPath = Export-CceExcel -Results $results -Context $Context -Path "$base.xlsx"
$htmlPath = Export-CceHtml  -Results $results -Context $Context -Path "$base.html"

$jsonPath = "$base.json"
[pscustomobject]@{
    tenant     = $Context.Tenant
    generated  = $Context.StartedAt
    language   = $Language
    catalog    = @{ title = $catalog.title; version = $catalog.version; items = $catalog.itemCount }
    services   = $Context.Services
    statistics = Get-CceStatistics -Results $results
    results    = $results
} | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8
Write-CceLog ((T 'cli.export.json') -f $jsonPath) -Level OK

# ---------------------------------------------------------------------------
# Restitution console
# ---------------------------------------------------------------------------
$stats = Get-CceStatistics -Results $results

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
$line = { param($label, $value, $color) Write-Host ('  {0,-34} : {1}' -f $label, $value) -ForegroundColor $color }

& $line (T 'sum.tenant')        $(if ($Context.Tenant.Name) { $Context.Tenant.Name } else { $Context.Tenant.Id }) 'White'
& $line (T 'sum.total')         $stats.Total          'White'
& $line (T 'sum.compliant')     $stats.Conforme       'Green'
& $line (T 'sum.noncompliant')  $stats.NonConforme    'Red'
& $line (T 'sum.warning')       $stats.Attention      'Yellow'
& $line (T 'sum.manual')        $stats.Manuel         'Cyan'
& $line (T 'sum.notapplicable') $stats.NonApplicable  'DarkGray'
& $line (T 'sum.notevaluated')  $stats.NonEvalue      'DarkGray'
& $line (T 'sum.rate')          $stats.TauxConformite 'Cyan'
& $line (T 'sum.blockingko')   $stats.BloquantsKo.Count $(if ($stats.BloquantsKo.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

if ($stats.BloquantsKo.Count -gt 0) {
    Write-Host ''
    Write-Host ('  ' + (T 'cli.blocking.header')) -ForegroundColor Red
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
