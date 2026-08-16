#Requires -Version 7.0
<#
    Controles 16 a 23 - SHAREPOINT ET ONEDRIVE, complete par les controles dont la
    sonde est le module Microsoft.Online.SharePoint.PowerShell : 59 (rapports de
    gouvernance d'acces aux donnees), 60 (integration des etiquettes de sensibilite),
    61 (revendications du selecteur de personnes), 62 (Restricted Content Discovery
    applique aux sites a risque), 63 (portee de Copilot in SharePoint), 64 (inventaire
    des agents SharePoint) et 65 (Microsoft Loop et Microsoft Whiteboard).
#>

$script:CceSensitiveSiteKeywords = 'rh|hr|paie|payroll|finance|comptab|direction|board|legal|juridique|confidentiel'

# Portee du lien de partage par defaut : CoreDefaultShareLinkScope et
# OneDriveDefaultShareLinkScope. Selon la version du module, la valeur remonte
# sous forme de nom d'enumeration ou d'entier : les deux formes sont normalisees.
$script:CceSpoLinkScopeMap = @{
    '-1'              = 'Uninitialized'
    'uninitialized'   = 'Uninitialized'
    '0'               = 'SpecificPeople'
    'specificpeople'  = 'SpecificPeople'
    '1'               = 'Organization'
    'organization'    = 'Organization'
    '2'               = 'Anyone'
    'anyone'          = 'Anyone'
    'anonymousaccess' = 'Anyone'
    '3'               = 'ExistingAccess'
    'existing'        = 'ExistingAccess'
    'existingaccess'  = 'ExistingAccess'
}

# Role du lien par defaut : CoreDefaultShareLinkRole, OneDriveDefaultShareLinkRole
# et propriete historique DefaultLinkPermission.
$script:CceSpoLinkRoleMap = @{
    '-1'             = 'Uninitialized'
    'uninitialized'  = 'Uninitialized'
    '0'              = 'None'
    'none'           = 'None'
    '1'              = 'View'
    'view'           = 'View'
    '2'              = 'Edit'
    'edit'           = 'Edit'
    'review'         = 'Review'
    'restrictedview' = 'RestrictedView'
    'owner'          = 'Owner'
}

# DefaultSharingLinkType n'utilise pas la meme numerotation que les parametres
# Core*/OneDrive* : table distincte, sous peine de verdict inverse.
$script:CceSpoLegacyLinkTypeMap = @{
    '0'               = 'None'
    'none'            = 'None'
    '1'               = 'Direct'
    'direct'          = 'Direct'
    '2'               = 'Internal'
    'internal'        = 'Internal'
    '3'               = 'AnonymousAccess'
    'anonymousaccess' = 'AnonymousAccess'
}

# Portees exploitables : hors de cette liste, la valeur est jugee illisible et le
# controle se replie sur les proprietes historiques plutot que de trancher a tort.
$script:CceSpoKnownLinkScope = @('SpecificPeople', 'Organization', 'Anyone', 'ExistingAccess')

# Roles qui accordent plus que la lecture au destinataire du lien par defaut.
$script:CceSpoOpenLinkRole = @('Edit', 'Review', 'Owner', 'ManageList')

# Noms commerciaux : marques Microsoft, identiques dans toutes les langues, donc hors
# ressources de langue. Ils alimentent RequiredLicense de New-CceNotApplicable.
$script:CceSpoCopilotLicense = 'Microsoft 365 Copilot'
$script:CceSpoAdvancedManagementLicense = 'SharePoint Advanced Management'

# Rapports d'activite de gouvernance d'acces aux donnees consideres comme preuve qu'une
# collecte est en place. Un seul suffit : les trois portent le meme prerequis d'audit.
$script:CceSpoDagActivityEntity = @('EveryoneExceptExternalUsersAtSite', 'SharingLinks_Anyone', 'SharingLinks_PeopleInYourOrg')

# Fraicheur maximale d'un rapport de reference des permissions, en jours.
$script:CceSpoDagMaxAgeDays = 90

# Point d'entree de la sonde fonctionnelle de l'index semantique (API Retrieval).
$script:CceSpoRetrievalUri = 'https://graph.microsoft.com/v1.0/copilot/retrieval'

function Get-CceSpoProperty {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete SharePoint Online.
    .DESCRIPTION
        Le jeu de proprietes de Get-SPOTenant varie avec la version du module et le
        moteur s'execute en Set-StrictMode Latest : une propriete absente doit rendre
        $null, jamais lever d'exception.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }

    Get-CceSafe { $property.Value } -What $Name
}

function ConvertTo-CceSpoEnumLabel {
    <#
    .SYNOPSIS
        Normalise une valeur d'enumeration SharePoint (nom ou entier) en libelle canonique.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $Value,
        [Parameter(Mandatory)] [hashtable] $Map
    )

    $raw = "$Value".Trim()
    if ($raw -eq '') { return '' }
    if ($Map.ContainsKey($raw)) { return $Map[$raw] }
    $raw
}

function Test-CceSpoCmdletRequiresArgument {
    <#
    .SYNOPSIS
        Vrai si la commande exige un argument dans son jeu de parametres par defaut.
    .DESCRIPTION
        Appeler une telle commande sans argument declencherait une invite bloquante :
        le moteur prefere renoncer a la lecture et le signaler dans la preuve.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Command)

    try {
        $defaultSet = "$($Command.DefaultParameterSet)"

        foreach ($parameter in $Command.Parameters.Values) {
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute -isnot [System.Management.Automation.ParameterAttribute]) { continue }
                if (-not $attribute.Mandatory) { continue }
                if ($attribute.ParameterSetName -eq '__AllParameterSets') { return $true }
                if ($defaultSet -and $attribute.ParameterSetName -eq $defaultSet) { return $true }
            }
        }

        return $false
    }
    catch {
        return $true
    }
}

function Get-CceSpoRestrictedSearchAllowedList {
    <#
    .SYNOPSIS
        Liste des sites autorises par Restricted SharePoint Search (lecture seule).
    .OUTPUTS
        Objet { Readable = bool ; Urls = string[] }.
    #>
    [CmdletBinding()]
    param()

    $command = Get-Command -Name 'Get-SPOTenantRestrictedSearchAllowedList' -ErrorAction SilentlyContinue
    if (-not $command) { return [pscustomobject]@{ Readable = $false; Urls = @() } }
    if (Test-CceSpoCmdletRequiresArgument -Command $command) { return [pscustomobject]@{ Readable = $false; Urls = @() } }

    $raw = Get-CceSafe { Get-SPOTenantRestrictedSearchAllowedList -ErrorAction Stop } -What 'Get-SPOTenantRestrictedSearchAllowedList'
    if ($null -eq $raw) { return [pscustomobject]@{ Readable = $false; Urls = @() } }

    $urls = foreach ($entry in @($raw)) {
        if ($entry -is [string]) { $entry.Trim(); continue }

        $value = ''
        foreach ($name in 'Url', 'SiteUrl', 'SiteId', 'Name') {
            $candidate = Get-CceSpoProperty -InputObject $entry -Name $name
            if ($null -ne $candidate -and "$candidate".Trim() -ne '') { $value = "$candidate".Trim(); break }
        }
        if ($value -eq '') { $value = "$entry".Trim() }
        $value
    }

    [pscustomobject]@{
        Readable = $true
        Urls     = @($urls | Where-Object { $_ -ne '' })
    }
}

function Get-CceAllSpoSite {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SpoSites')) { return $Context.Cache['SpoSites'] }
    if (-not $Context.Services.SharePoint) { return @() }

    Write-CceLog (T 'collect.spo.sites') -Level INFO
    $sites = Get-CceSafe { Get-SPOSite -Limit All -ErrorAction Stop } -What 'Get-SPOSite'
    $Context.Cache['SpoSites'] = @($sites)
    $Context.Cache['SpoSites']
}

function Get-CceSpoConfigValue {
    <#
    .SYNOPSIS
        Lecture defensive d'un parametre d'execution du moteur.
    .DESCRIPTION
        Le moteur s'execute en Set-StrictMode Latest : lire une cle absente de
        $Context.Config leve une exception. Les outils de test construisent un contexte
        reduit, un controle ne doit donc jamais supposer qu'une cle existe.
    #>
    [CmdletBinding()]
    param(
        $Context,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $Context) { return $Default }

    $holder = $Context.PSObject.Properties['Config']
    if ($null -eq $holder -or $null -eq $holder.Value) { return $Default }

    $bag = $holder.Value
    $value = $null

    if ($bag -is [System.Collections.IDictionary]) {
        if (-not $bag.Contains($Name)) { return $Default }
        $value = $bag[$Name]
    }
    else {
        $property = $bag.PSObject.Properties[$Name]
        if ($null -eq $property) { return $Default }
        $value = $property.Value
    }

    if ($null -eq $value) { return $Default }
    $value
}

function Get-CceSpoFirstProperty {
    <#
    .SYNOPSIS
        Premiere propriete renseignee parmi plusieurs noms candidats, en texte.
    .DESCRIPTION
        Le schema des objets renvoyes par les cmdlets de rapport SharePoint varie avec la
        version du module : on interroge les noms connus dans l'ordre plutot que d'en
        supposer un seul.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string[]] $Name
    )

    foreach ($candidate in $Name) {
        $value = Get-CceSpoProperty -InputObject $InputObject -Name $candidate
        if ($null -ne $value -and "$value".Trim() -ne '') { return "$value".Trim() }
    }

    ''
}

function ConvertTo-CceSpoDate {
    <# Conversion tolerante d'une date de rapport ; $null si la valeur est illisible. #>
    [CmdletBinding()]
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    [datetime] $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [ref] $parsed)) { return $parsed }

    $null
}

function Get-CceSpoMissingMandatoryParameter {
    <#
    .SYNOPSIS
        Parametres obligatoires du jeu par defaut qui ne sont pas fournis par l'appelant.
    .DESCRIPTION
        Invoquer une commande sans ses parametres obligatoires declencherait une invite
        bloquante en session interactive : le moteur prefere renoncer a la lecture et le
        signaler dans la preuve.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Command,
        [string[]] $Supplied = @()
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    try {
        $defaultSet = "$($Command.DefaultParameterSet)"

        foreach ($parameter in $Command.Parameters.Values) {
            if ($Supplied -contains $parameter.Name) { continue }

            foreach ($attribute in $parameter.Attributes) {
                if ($attribute -isnot [System.Management.Automation.ParameterAttribute]) { continue }
                if (-not $attribute.Mandatory) { continue }

                if ($attribute.ParameterSetName -eq '__AllParameterSets' -or
                    ($defaultSet -ne '' -and $attribute.ParameterSetName -eq $defaultSet)) {
                    if (-not $missing.Contains($parameter.Name)) { $missing.Add($parameter.Name) }
                    break
                }
            }
        }
    }
    catch {
        return @($Command.Name)
    }

    @($missing)
}

function Invoke-CceSpoModuleCommand {
    <#
    .SYNOPSIS
        Invocation defensive d'une commande du module SharePoint Online.
    .DESCRIPTION
        La commande peut etre absente du module installe, exiger un parametre que le moteur
        ne sait pas fournir, ou echouer faute de licence complementaire. Chaque cas est
        distingue pour que le controle appelant choisisse entre "Non evalue" (limite du
        moteur) et "Non applicable" (capacite non detenue par le tenant).

        Seules des commandes de lecture sont appelees ici. La seule exception est le
        declenchement d'un rapport, subordonne au commutateur AllowReportGeneration et
        decide par le controle appelant, jamais par cette fonction.
    .OUTPUTS
        Objet { Available ; Reason = ok|cmdlet|parameter|license|denied|error ; Message ; Output }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [hashtable] $Parameter = @{}
    )

    $outcome = [pscustomobject]@{
        Available = $false
        Reason    = 'cmdlet'
        Message   = ''
        Output    = @()
    }

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $outcome }

    # On ne transmet que les parametres reellement declares par la version installee.
    $splat = @{}
    foreach ($key in $Parameter.Keys) {
        if ($command.Parameters.ContainsKey($key)) { $splat[$key] = $Parameter[$key] }
    }

    $missing = @(Get-CceSpoMissingMandatoryParameter -Command $command -Supplied @($splat.Keys))
    if ($missing.Count -gt 0) {
        $outcome.Reason = 'parameter'
        $outcome.Message = $missing -join ', '
        return $outcome
    }

    $splat['ErrorAction'] = 'Stop'

    try {
        $raw = & $command @splat
        $outcome.Available = $true
        $outcome.Reason = 'ok'
        $outcome.Output = @(@($raw) | Where-Object { $null -ne $_ })
    }
    catch {
        $outcome.Message = "$($_.Exception.Message)".Trim()

        $outcome.Reason = if ($outcome.Message -imatch 'licen[cs]|subscription|advanced management|not enabled|not supported') { 'license' }
        elseif ($outcome.Message -imatch 'denied|unauthori[sz]|forbidden|permission|not have|privilege') { 'denied' }
        else { 'error' }
    }

    $outcome
}

function ConvertTo-CceSpoReportEntry {
    <#
    .SYNOPSIS
        Normalise une ligne de rapport SharePoint (gouvernance d'acces aux donnees,
        Restricted Content Discovery) en objet stable.
    #>
    [CmdletBinding()]
    param($Raw)

    $status = Get-CceSpoFirstProperty -InputObject $Raw -Name 'Status', 'ReportStatus', 'State'
    $created = Get-CceSpoFirstProperty -InputObject $Raw -Name 'CreatedDateTime', 'ReportGeneratedTime', 'TriggeredDateTime', 'CreatedTime', 'ReportStartTime'
    $count = Get-CceSpoFirstProperty -InputObject $Raw -Name 'CountOfSitesInReport', 'SitesFound', 'SiteCount', 'TotalSites'

    $date = ConvertTo-CceSpoDate -Value $created
    $siteCount = if ($count -match '^\d+$') { [int] $count } else { -1 }
    $age = if ($null -eq $date) { -1 } else { [int] [Math]::Floor(((Get-Date) - $date).TotalDays) }

    # Statut absent du schema : on ne declare le rapport exploitable que s'il porte
    # malgre tout un comptage, plutot que de conclure a tort a son absence.
    $completed = ($status -imatch 'complet') -or ($status -eq '' -and $siteCount -ge 0)

    [pscustomobject]@{
        Id        = Get-CceSpoFirstProperty -InputObject $Raw -Name 'ReportID', 'ReportId', 'Id'
        Name      = Get-CceSpoFirstProperty -InputObject $Raw -Name 'ReportName', 'Name'
        Entity    = Get-CceSpoFirstProperty -InputObject $Raw -Name 'ReportEntity', 'Entity'
        Workload  = Get-CceSpoFirstProperty -InputObject $Raw -Name 'Workload'
        Type      = Get-CceSpoFirstProperty -InputObject $Raw -Name 'ReportType', 'Type'
        Status    = $status
        Created   = $created
        SiteCount = $siteCount
        Threshold = Get-CceSpoFirstProperty -InputObject $Raw -Name 'CountOfUsersMoreThan', 'UserCountThreshold'
        AgeDays   = $age
        Completed = $completed
    }
}

function Get-CceSpoLatestReport {
    <# Rapport le plus recent, en privilegiant ceux au statut Completed. #>
    [CmdletBinding()]
    param($Insight)

    if ($null -eq $Insight) { return $null }
    if (-not $Insight.Available) { return $null }

    $reports = @($Insight.Reports)
    if ($reports.Count -eq 0) { return $null }

    $completed = @($reports | Where-Object { $_.Completed })
    $pool = if ($completed.Count -gt 0) { $completed } else { $reports }

    @($pool | Sort-Object -Property @{ Expression = { if ($_.AgeDays -lt 0) { [int]::MaxValue } else { $_.AgeDays } } })[0]
}

function Get-CceSpoDagInsight {
    <#
    .SYNOPSIS
        Lecture d'un rapport de gouvernance d'acces aux donnees (lecture seule, mise en cache).
    .DESCRIPTION
        Get-SPODataAccessGovernanceInsight retourne les metadonnees des rapports deja
        generes : statut, date, nombre de sites remontes. Le declenchement
        (Start-SPODataAccessGovernanceInsight) est une action de modification et n'est
        jamais appele par le moteur.
    #>
    [CmdletBinding()]
    param(
        $Context,
        [Parameter(Mandatory)] [string] $Entity,
        [string] $Workload = 'SharePoint'
    )

    $key = 'SpoDag:{0}:{1}' -f $Entity, $Workload
    if ($Context.Cache.ContainsKey($key)) { return $Context.Cache[$key] }

    $outcome = Invoke-CceSpoModuleCommand -Name 'Get-SPODataAccessGovernanceInsight' `
        -Parameter @{ ReportEntity = $Entity; Workload = $Workload }

    $reports = @()
    if ($outcome.Available) {
        $reports = @(@($outcome.Output) | ForEach-Object { ConvertTo-CceSpoReportEntry -Raw $_ })
    }

    $insight = [pscustomobject]@{
        Entity    = $Entity
        Workload  = $Workload
        Available = $outcome.Available
        Reason    = $outcome.Reason
        Message   = $outcome.Message
        Reports   = $reports
    }

    $Context.Cache[$key] = $insight
    $insight
}

function Get-CceSpoRcdReport {
    <# Rapports Restricted Content Discovery deja generes (lecture seule, mise en cache). #>
    [CmdletBinding()]
    param($Context)

    if ($Context.Cache.ContainsKey('SpoRcdReport')) { return $Context.Cache['SpoRcdReport'] }

    $outcome = Invoke-CceSpoModuleCommand -Name 'Get-SPORestrictedContentDiscoverabilityReport'

    $reports = @()
    if ($outcome.Available) {
        $reports = @(@($outcome.Output) | ForEach-Object { ConvertTo-CceSpoReportEntry -Raw $_ })
    }

    $insight = [pscustomobject]@{
        Available = $outcome.Available
        Reason    = $outcome.Reason
        Message   = $outcome.Message
        Reports   = $reports
    }

    $Context.Cache['SpoRcdReport'] = $insight
    $insight
}

function Invoke-CceSpoRetrievalProbe {
    <#
    .SYNOPSIS
        Sonde fonctionnelle de l'index semantique : POST /copilot/retrieval.
    .DESCRIPTION
        L'appel est un POST mais reste strictement une lecture : l'API Retrieval renvoie
        les extraits que le compte appelant a le droit de lire, en empruntant le meme
        chemin de recuperation que Copilot. Elle n'existe qu'en delegue.
    .OUTPUTS
        Objet { Called ; Success ; Status ; Hits ; Message }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $QueryString,
        [string] $DataSource = 'sharePoint',
        [int] $MaximumNumberOfResults = 10
    )

    $outcome = [pscustomobject]@{
        Called  = $false
        Success = $false
        Status  = 0
        Hits    = @()
        Message = ''
    }

    if ($null -eq (Get-Command -Name 'Invoke-MgGraphRequest' -ErrorAction SilentlyContinue)) { return $outcome }

    $body = @{
        queryString            = $QueryString
        dataSource             = $DataSource
        resourceMetadata       = @('title', 'author')
        maximumNumberOfResults = $MaximumNumberOfResults
    } | ConvertTo-Json -Depth 4 -Compress

    $outcome.Called = $true

    try {
        $response = Invoke-MgGraphRequest -Method POST -Uri $script:CceSpoRetrievalUri `
            -Body $body -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop

        $hits = @()
        if ($null -ne $response) {
            $property = $response.PSObject.Properties['retrievalHits']
            if ($null -ne $property -and $null -ne $property.Value) { $hits = @($property.Value) }
        }

        $outcome.Success = $true
        $outcome.Status = 200
        $outcome.Hits = $hits
    }
    catch {
        $outcome.Message = "$($_.Exception.Message)".Trim()
        $outcome.Status = ConvertTo-CceSpoHttpStatus -Exception $_.Exception -Message $outcome.Message
    }

    $outcome
}

function ConvertTo-CceSpoHttpStatus {
    <# Code HTTP d'une exception Graph, 0 s'il n'est pas exploitable. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        $Exception,
        [string] $Message = ''
    )

    $raw = ''

    if ($null -ne $Exception) {
        $response = $Exception.PSObject.Properties['Response']
        if ($null -ne $response -and $null -ne $response.Value) {
            $status = $response.Value.PSObject.Properties['StatusCode']
            if ($null -ne $status -and $null -ne $status.Value) { $raw = "$($status.Value)".Trim() }
        }
    }

    # A defaut, code annonce explicitement dans le message, puis libelle normalise.
    # Un nombre isole ne suffit pas : confondre un identifiant avec un code HTTP
    # transformerait une erreur banale en verdict "Non applicable".
    if ($raw -eq '' -and $Message -imatch '(?:status|code|http|fail\w*|return\w*|respon\w*)\D{0,40}(4\d{2}|5\d{2})') { $raw = $Matches[1] }
    if ($raw -eq '' -and $Message -imatch '(Unauthorized|Forbidden|Not\s?Found|Too\s?Many\s?Requests|Not\s?Implemented)') { $raw = $Matches[1] -replace '\s', '' }

    switch -Regex ($raw) {
        '^\d+$'           { [int] $raw; break }
        'Unauthorized'    { 401; break }
        'Forbidden'       { 403; break }
        'NotFound'        { 404; break }
        'TooManyRequests' { 429; break }
        'NotImplemented'  { 501; break }
        default           { 0 }
    }
}

function Invoke-CceCheck16 {
    <#
        Partage global SharePoint et portee des liens de partage par defaut.

        Le modele actuel distingue les sites d'equipe (CoreDefaultShareLinkScope /
        CoreDefaultShareLinkRole) et OneDrive (OneDriveDefaultShareLinkScope /
        OneDriveDefaultShareLinkRole). OneDrive est le principal generateur de
        sur-partage interne remonte par Copilot : il est evalue sans tolerance,
        la tolerance "Organization" ne valant que pour les sites d'equipe.
        Repli sur DefaultSharingLinkType / DefaultLinkPermission si le module
        n'expose pas les parametres modernes.
    #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $sharing = "$(Get-CceSpoProperty -InputObject $tenant -Name 'SharingCapability')"

    $coreScope = ConvertTo-CceSpoEnumLabel -Value (Get-CceSpoProperty -InputObject $tenant -Name 'CoreDefaultShareLinkScope') -Map $script:CceSpoLinkScopeMap
    $coreRole = ConvertTo-CceSpoEnumLabel -Value (Get-CceSpoProperty -InputObject $tenant -Name 'CoreDefaultShareLinkRole') -Map $script:CceSpoLinkRoleMap
    $oneScope = ConvertTo-CceSpoEnumLabel -Value (Get-CceSpoProperty -InputObject $tenant -Name 'OneDriveDefaultShareLinkScope') -Map $script:CceSpoLinkScopeMap
    $oneRole = ConvertTo-CceSpoEnumLabel -Value (Get-CceSpoProperty -InputObject $tenant -Name 'OneDriveDefaultShareLinkRole') -Map $script:CceSpoLinkRoleMap
    $legacyType = ConvertTo-CceSpoEnumLabel -Value (Get-CceSpoProperty -InputObject $tenant -Name 'DefaultSharingLinkType') -Map $script:CceSpoLegacyLinkTypeMap
    $legacyRole = ConvertTo-CceSpoEnumLabel -Value (Get-CceSpoProperty -InputObject $tenant -Name 'DefaultLinkPermission') -Map $script:CceSpoLinkRoleMap

    $issues = [System.Collections.Generic.List[string]]::new()
    $severity = 0    # 0 = conforme, 1 = attention, 2 = non conforme

    if ($sharing -eq 'ExternalUserAndGuestSharing') {
        $issues.Add((T 'c16.ev.anon'))
        $severity = 2

        $fileAnon = "$(Get-CceSpoProperty -InputObject $tenant -Name 'FileAnonymousLinkType')"
        $folderAnon = "$(Get-CceSpoProperty -InputObject $tenant -Name 'FolderAnonymousLinkType')"
        $anonExpiry = "$(Get-CceSpoProperty -InputObject $tenant -Name 'RequireAnonymousLinksExpireInDays')"
        $issues.Add(((T 'c16.ev.anon.types') -f $fileAnon, $folderAnon, $anonExpiry))
    }
    elseif ($sharing -eq 'ExternalUserSharingOnly') {
        $issues.Add((T 'c16.ev.external'))
        $severity = [Math]::Max($severity, 1)
    }

    $coreKnown = $coreScope -in $script:CceSpoKnownLinkScope
    $oneKnown = $oneScope -in $script:CceSpoKnownLinkScope

    if ($coreKnown -or $oneKnown) {
        $effectiveCoreScope = if ($coreKnown) { $coreScope } else { '' }
        $effectiveOneScope = if ($oneKnown) { $oneScope } else { $effectiveCoreScope }
        $effectiveOneRole = if ($oneKnown -and $oneRole -and $oneRole -ne 'Uninitialized') { $oneRole } else { $coreRole }

        if (-not $oneKnown) { $issues.Add(((T 'c16.ev.one.inherit') -f $effectiveCoreScope, $coreRole)) }

        # Sites d'equipe : Organization reste tolere s'il est documente, Anyone jamais.
        if ($effectiveCoreScope -eq 'Anyone') {
            $issues.Add((T 'c16.ev.core.anyone'))
            $severity = 2
        }
        elseif ($effectiveCoreScope -eq 'Organization') {
            $issues.Add((T 'c16.ev.core.org'))
        }

        # OneDrive : aucune tolerance, la cible est SpecificPeople.
        if ($effectiveOneScope -eq 'Anyone') {
            $issues.Add((T 'c16.ev.one.anyone'))
            $severity = 2
        }
        elseif ($effectiveOneScope -eq 'Organization') {
            $issues.Add((T 'c16.ev.one.org'))
            $severity = [Math]::Max($severity, 1)
        }

        if ($coreRole -in $script:CceSpoOpenLinkRole) {
            $issues.Add(((T 'c16.ev.core.role') -f $coreRole))
            $severity = [Math]::Max($severity, 1)
        }

        if ($effectiveOneRole -in $script:CceSpoOpenLinkRole) {
            $issues.Add(((T 'c16.ev.one.role') -f $effectiveOneRole))
            $severity = [Math]::Max($severity, 1)
        }

        $observed = (T 'c16.obs.modern') -f $sharing, $coreScope, $coreRole, $oneScope, $oneRole
        $issues.Add(((T 'c16.ev.legacy.detail') -f $legacyType, $legacyRole))
    }
    else {
        $issues.Add((T 'c16.ev.legacy.only'))

        if ($legacyType -eq 'AnonymousAccess') {
            $issues.Add(((T 'c16.ev.linktype') -f $legacyType))
            $severity = 2
        }
        elseif ($legacyType -ne 'Direct' -and $legacyType -ne 'Internal') {
            $issues.Add(((T 'c16.ev.linktype') -f $legacyType))
            $severity = [Math]::Max($severity, 1)
        }

        if ($legacyRole -in $script:CceSpoOpenLinkRole) {
            $issues.Add(((T 'c16.ev.linkperm') -f $legacyRole))
            $severity = [Math]::Max($severity, 1)
        }

        $observed = (T 'c16.obs.legacy') -f $sharing, $legacyType, $legacyRole
    }

    if ($severity -eq 0) { $issues.Add((T 'c16.ev.ok')) }

    $status = switch ($severity) {
        2 { 'Non conforme' }
        1 { 'Attention' }
        default { 'Conforme' }
    }

    New-CceResult -Status $status -Observed $observed `
        -Evidence (@(@($observed) + @($issues)) | ConvertTo-CceText -MaxItems 20) `
        -Remediation $(if ($severity -eq 0) { '' } else { T 'c16.rem.ko' })
}

function Invoke-CceCheck17 {
    <# Expiration des liens anonymes a 7 jours maximum #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $days = $tenant.RequireAnonymousLinksExpireInDays
    $sharing = "$($tenant.SharingCapability)"

    if ($sharing -ne 'ExternalUserAndGuestSharing') {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c17.obs.na') -f $sharing) `
            -Evidence ((T 'c17.ev.na') -f $days)
    }

    if ($days -gt 0 -and $days -le 7) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("RequireAnonymousLinksExpireInDays = {0}" -f $days) -Evidence ((T 'c17.ev.ok') -f $days)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ("RequireAnonymousLinksExpireInDays = {0}" -f $days) `
        -Evidence ((T 'c17.ev.ko') -f $days) `
        -Remediation "Set-SPOTenant -RequireAnonymousLinksExpireInDays 7"
}

function Invoke-CceCheck18 {
    <#
        Sur-partage reel des sites SharePoint.

        SharingCapability ne mesure pas le sur-partage : il mesure la capacite de partage
        EXTERNE configuree sur le site. Or le vecteur numero un en contexte Copilot est
        interne : la revendication "Tout le monde sauf les utilisateurs externes" (EEEU)
        posee sur un site ou sur un element, qui rend le contenu decouvrable par toute
        l'organisation. Un site RH ferme a l'externe mais porteur d'EEEU sur sa
        bibliotheque de paie est l'exposition la plus grave du tenant.

        Le verdict s'appuie donc d'abord sur les rapports de gouvernance d'acces aux
        donnees (EveryoneExceptExternalUsersAtSite et ...ForItems), la capacite de partage
        externe et l'heuristique par mot-cle ne restant qu'un signal secondaire.
        Le detail par site s'obtient hors moteur avec Export-SPODataAccessGovernanceInsight.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $severity = 0    # 0 = conforme, 1 = attention, 2 = non conforme

    # --- 1. Sur-partage interne : rapports EEEU -------------------------------
    $siteInsight = Get-CceSpoDagInsight -Context $Context -Entity 'EveryoneExceptExternalUsersAtSite' -Workload 'SharePoint'
    $itemInsight = Get-CceSpoDagInsight -Context $Context -Entity 'EveryoneExceptExternalUsersForItems' -Workload 'SharePoint'
    $permInsight = Get-CceSpoDagInsight -Context $Context -Entity 'PermissionedUsers' -Workload 'SharePoint'

    $siteReport = Get-CceSpoLatestReport -Insight $siteInsight
    $itemReport = Get-CceSpoLatestReport -Insight $itemInsight
    $permReport = Get-CceSpoLatestReport -Insight $permInsight

    $eeeuSites = -1
    $eeeuItems = -1

    if ($null -ne $siteReport -and $siteReport.Completed -and $siteReport.SiteCount -ge 0) {
        $eeeuSites = $siteReport.SiteCount

        if ($eeeuSites -gt 0) {
            $evidence.Add(((T 'c18.ev.eeeu.site') -f $eeeuSites, $siteReport.Created))
            $severity = 2
        }
        else { $evidence.Add(((T 'c18.ev.eeeu.site.ok') -f $siteReport.Created)) }
    }

    if ($null -ne $itemReport -and $itemReport.Completed -and $itemReport.SiteCount -ge 0) {
        $eeeuItems = $itemReport.SiteCount

        if ($eeeuItems -gt 0) {
            $evidence.Add(((T 'c18.ev.eeeu.items') -f $eeeuItems, $itemReport.Created))
            $severity = [Math]::Max($severity, 1)
        }
        else { $evidence.Add(((T 'c18.ev.eeeu.items.ok') -f $itemReport.Created)) }
    }

    $measured = ($eeeuSites -ge 0 -or $eeeuItems -ge 0)

    if ($null -ne $permReport -and $permReport.Completed) {
        $evidence.Add(((T 'c18.ev.permissioned') -f $permReport.SiteCount, $permReport.Threshold, $permReport.Created))
    }

    if ($measured) { $evidence.Add((T 'c18.ev.detail')) }
    else {
        if ($siteInsight.Reason -eq 'license') { $evidence.Add((T 'c18.ev.dag.license')) }
        elseif ($siteInsight.Reason -eq 'denied') { $evidence.Add((T 'c18.ev.dag.denied')) }
        elseif ($siteInsight.Reason -eq 'ok') { $evidence.Add((T 'c18.ev.dag.none')) }
        else { $evidence.Add((T 'c18.ev.dag.cmdlet')) }

        $detail = "$($siteInsight.Message)".Trim()
        if ($detail -ne '') { $evidence.Add(((T 'c18.ev.dag.detail') -f $detail)) }
    }

    # --- 2. Signal secondaire : capacite de partage externe --------------------
    $sites = @(Get-CceAllSpoSite -Context $Context)
    $overshared = @($sites | Where-Object { "$(Get-CceSpoProperty -InputObject $_ -Name 'SharingCapability')" -eq 'ExternalUserAndGuestSharing' })
    $sensitive = @($overshared | Where-Object { "$($_.Title) $($_.Url)" -match $script:CceSensitiveSiteKeywords })

    if ($overshared.Count -gt 0) {
        $evidence.Add(((T 'c18.ev.legacy') -f $overshared.Count, $sites.Count))
        $severity = [Math]::Max($severity, $(if ($sensitive.Count -gt 0) { 2 } else { 1 }))

        foreach ($site in $sensitive) { $evidence.Add(((T 'c18.ev.sensitive') -f $site.Title, $site.Url)) }
        foreach ($site in @($overshared | Where-Object { $_ -notin $sensitive })) {
            $evidence.Add(('{0} - {1}' -f $site.Title, $site.Url))
        }
    }
    elseif ($sites.Count -gt 0) { $evidence.Add((T 'c18.ev.ok')) }

    # --- 3. Verdict -----------------------------------------------------------
    # Sans rapport EEEU et sans ecart sur le signal secondaire, le sur-partage interne
    # n'a tout simplement pas ete mesure : le declarer conforme serait un faux positif.
    if (-not $measured -and $severity -eq 0) {
        if ($sites.Count -eq 0) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c18.obs.nodag') `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c18.rem.eeeu')
    }

    $observed = if ($eeeuSites -gt 0) { (T 'c18.obs.eeeu.ko') -f $eeeuSites }
    elseif ($eeeuItems -gt 0) { (T 'c18.obs.eeeu.items') -f $eeeuItems }
    elseif ($overshared.Count -gt 0) { (T 'c18.obs.ko') -f $overshared.Count, $sites.Count, $sensitive.Count }
    else { (T 'c18.obs.ok') -f $sites.Count }

    $status = switch ($severity) {
        2 { 'Non conforme' }
        1 { 'Attention' }
        default { 'Conforme' }
    }

    $remediation = if ($severity -eq 0) { '' }
    elseif ($eeeuSites -gt 0 -or $eeeuItems -gt 0) { T 'c18.rem.eeeu' }
    else { T 'c18.rem.ko' }

    New-CceResult -Status $status -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation $remediation
}

function Invoke-CceCheck19 {
    <# Provisionner OneDrive pour tous les utilisateurs Copilot #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }
    if (-not $Context.Services.Graph) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = @(Get-CceCopilotUser -Context $Context | Where-Object { $_.AccountEnabled -and "$($_.UserType)" -ne 'Guest' })
    if ($users.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' -Observed (T 'c19.obs.none') `
            -Evidence (T 'c19.ev.none')
    }

    $personal = Get-CceSafe {
        Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'" -ErrorAction Stop
    } -What 'Get-SPOSite (OneDrive)'

    if ($null -eq $personal) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $owners = @($personal | ForEach-Object { "$($_.Owner)".ToLower() })
    $missing = @($users | Where-Object { $owners -notcontains $_.UserPrincipalName.ToLower() })

    if ($missing.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c19.obs.ok') -f $users.Count) `
            -Evidence ((T 'c19.ev.ok') -f @($personal).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c19.obs.ko') -f $missing.Count, $users.Count) `
        -Evidence ($missing | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation (T 'c19.rem.ko')
}

function Invoke-CceCheck20 {
    <#
        Sonde fonctionnelle de l'index semantique (API Retrieval Microsoft 365 Copilot).

        L'exigence demandait jusqu'ici de taper une requete dans microsoft365.com et de
        juger le resultat a l'oeil : c'etait le controle Bloquant laisse sans preuve.
        POST /copilot/retrieval emprunte exactement le chemin d'ancrage de Copilot et
        renvoie les extraits que le compte appelant a le droit de lire. Une reponse vide
        sur un contenu de reference connu prouve que la chaine est cassee : NoCrawl actif,
        Restricted SharePoint Search mal cadree, Restricted Content Discovery, ou index
        semantique pas encore propage.

        Sans terme de sonde fourni (-RetrievalProbeTerm), le controle reste manuel : il ne
        doit jamais produire un faux ecart sur une requete choisie au hasard. Le resultat
        n'a de sens qu'au moins 72 heures apres l'attribution des premieres licences.
        Jeton delegue obligatoire : aucune permission applicative n'existe pour cette API.
    #>
    [CmdletBinding()] param($Context)

    $term = "$(Get-CceSpoConfigValue -Context $Context -Name 'RetrievalProbeTerm' -Default '')".Trim()

    if ($term -eq '') {
        $tenant = Get-CceSpoTenant -Context $Context
        $detail = ''
        if ($null -ne $tenant) {
            $detail = 'SearchResolveExactEmailOrUPN={0}' -f (Get-CceSpoProperty -InputObject $tenant -Name 'SearchResolveExactEmailOrUPN')
        }

        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c20.obs.manual') `
            -Evidence ((T 'c20.ev.manual') -f $detail) `
            -Remediation (T 'c20.rem.manual')
    }

    if (-not $Context.Services.Graph) { return New-CceNotEvaluated -Service Graph -Context $Context }

    if ("$(Get-CceSpoConfigValue -Context $Context -Name 'AuthMode' -Default 'delegated')" -eq 'application') {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c20.obs.authmode') `
            -Evidence (T 'core.authmode.delegated') `
            -Remediation (T 'c20.rem.authmode')
    }

    # Licence absente : l'API n'existe pas sur le tenant, ce n'est pas un ecart.
    # Le test n'est concluant que si l'inventaire des abonnements a bien pu etre lu.
    $skus = @(Get-CceSubscribedSku -Context $Context)
    if ($skus.Count -gt 0 -and @(Get-CceCopilotSkuId -Context $Context).Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c20.ev.nolicense') -RequiredLicense $script:CceSpoCopilotLicense
    }

    $probe = Invoke-CceSpoRetrievalProbe -QueryString $term
    if (-not $probe.Called) { return New-CceNotEvaluated -Service Graph -Context $Context }

    if ($probe.Success) {
        $hits = @($probe.Hits)

        if ($hits.Count -eq 0) {
            return New-CceResult -Status 'Non conforme' `
                -Observed ((T 'c20.obs.empty') -f $term) `
                -Evidence (@((T 'c20.ev.empty') -f $term) + @(T 'c20.ev.delay') | ConvertTo-CceText) `
                -Remediation (T 'c20.rem.empty')
        }

        $lines = foreach ($hit in $hits) {
            $metadata = Get-CceSpoProperty -InputObject $hit -Name 'resourceMetadata'
            $title = Get-CceSpoFirstProperty -InputObject $metadata -Name 'title', 'name'
            $url = Get-CceSpoFirstProperty -InputObject $hit -Name 'webUrl', 'resourceUrl', 'url'
            (T 'c20.ev.hit') -f $title, $url
        }

        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c20.obs.ok') -f $hits.Count, $term) `
            -Evidence (@((T 'c20.ev.ok') -f $term, $hits.Count) + @($lines) | ConvertTo-CceText -MaxItems 12)
    }

    if ($probe.Status -eq 401 -or $probe.Status -eq 403) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c20.obs.denied') `
            -Evidence ((T 'c20.ev.denied') -f $probe.Status, $probe.Message) `
            -Remediation (T 'c20.rem.denied')
    }

    if ($probe.Status -eq 404 -or $probe.Status -eq 501) {
        return New-CceNotApplicable -Reason (T 'c20.ev.noapi') -RequiredLicense $script:CceSpoCopilotLicense
    }

    New-CceResult -Status 'Non evalue' `
        -Observed ((T 'c20.obs.error') -f $probe.Status) `
        -Evidence ((T 'c20.ev.error') -f $probe.Message) `
        -Remediation (T 'c20.rem.denied')
}

function Invoke-CceCheck21 {
    <#
        Exclusion de la decouverte Copilot : Restricted Content Discovery.

        Web.NoCrawl n'est expose ni par Microsoft Graph ni par le module SharePoint
        officiel : il ne se lit que site par site via PnP.PowerShell, module communautaire
        non supporte par Microsoft. Le mecanisme qui exclut reellement un site de Copilot
        aujourd'hui n'est plus NoCrawl mais Restricted Content Discovery, qui retire aussi
        du site les points d'entree IA. Le controle inventorie donc les sites sous RCD et
        l'etat de la delegation de sa gestion ; NoCrawl reste une verification
        complementaire par site, signalee dans la preuve.

        RCD est une posture legitime : un site restreint produit un avertissement pour que
        l'auditeur confirme qu'il est documente, jamais un ecart automatique.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $severity = 0
    $restrictedCount = -1
    $restrictedSites = @()

    # --- 1. Delegation de la gestion RCD --------------------------------------
    $tenant = Get-CceSpoTenant -Context $Context
    $delegate = "$(Get-CceSpoProperty -InputObject $tenant -Name 'DelegateRestrictedContentDiscoverabilityManagement')".Trim()

    if ($delegate -eq '') { $evidence.Add((T 'c21.ev.delegate.unknown')) }
    elseif ($delegate -match '^(true|1)$') {
        $evidence.Add((T 'c21.ev.delegate.on'))
        $severity = [Math]::Max($severity, 1)
    }
    else { $evidence.Add(((T 'c21.ev.delegate.off') -f $delegate)) }

    # --- 2. Inventaire des sites sous RCD -------------------------------------
    # La propriete RestrictContentOrgWideSearch n'est exposee par Get-SPOSite que sur les
    # versions recentes du module : on teste sa presence avant de s'y fier, plutot que de
    # boucler un appel par site sur un tenant qui en compte des milliers.
    $sites = @(Get-CceAllSpoSite -Context $Context)

    if ($sites.Count -gt 0 -and $null -ne $sites[0].PSObject.Properties['RestrictContentOrgWideSearch']) {
        $restrictedSites = @($sites | Where-Object {
                "$(Get-CceSpoProperty -InputObject $_ -Name 'RestrictContentOrgWideSearch')".Trim() -match '^(true|1)$'
            })
        $restrictedCount = $restrictedSites.Count
    }

    # --- 3. Rapport tenant Restricted Content Discovery -----------------------
    $report = Get-CceSpoRcdReport -Context $Context
    $latest = Get-CceSpoLatestReport -Insight $report

    if ($null -ne $latest) {
        $evidence.Add(((T 'c21.ev.report') -f $latest.Status, $latest.Created, $latest.SiteCount))
        if ($restrictedCount -lt 0 -and $latest.Completed -and $latest.SiteCount -ge 0) { $restrictedCount = $latest.SiteCount }
    }
    elseif ($report.Available) {
        $evidence.Add((T 'c21.ev.report.none'))

        # Aucun rapport preexistant : la generation n'est declenchee que sur opt-in
        # explicite de l'operateur, le moteur restant sans effet de bord par defaut.
        if ([bool] (Get-CceSpoConfigValue -Context $Context -Name 'AllowReportGeneration' -Default $false)) {
            $started = Invoke-CceSpoModuleCommand -Name 'Start-SPORestrictedContentDiscoverabilityReport'
            if ($started.Available) { $evidence.Add((T 'c21.ev.report.started')) }
        }
        else { $evidence.Add((T 'core.report.optin')) }
    }
    elseif ($report.Reason -eq 'license') { $evidence.Add((T 'c21.ev.license')) }
    elseif ($report.Reason -eq 'denied') { $evidence.Add(((T 'c21.ev.denied') -f $report.Message)) }
    else { $evidence.Add((T 'c21.ev.cmdlet')) }

    $evidence.Add((T 'c21.ev.manual'))

    # --- 4. Verdict -----------------------------------------------------------
    if ($restrictedCount -lt 0) {
        if ($report.Reason -eq 'license') {
            return New-CceNotApplicable -Reason (T 'c21.ev.license') `
                -RequiredLicense $script:CceSpoAdvancedManagementLicense `
                -Evidence ($evidence | ConvertTo-CceText -MaxItems 20)
        }

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c21.obs.manual') `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c21.rem.manual')
    }

    if ($restrictedCount -gt 0) {
        $severity = [Math]::Max($severity, 1)
        foreach ($site in @($restrictedSites | Select-Object -First 20)) {
            $evidence.Add(((T 'c21.ev.site') -f $site.Title, $site.Url))
        }
    }

    $observed = if ($restrictedCount -gt 0) { (T 'c21.obs.restricted') -f $restrictedCount, $sites.Count }
    else { (T 'c21.obs.none') -f $sites.Count }

    New-CceResult -Status $(if ($severity -ge 1) { 'Attention' } else { 'Conforme' }) `
        -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation $(if ($severity -ge 1) { T 'c21.rem.restricted' } else { '' })
}

function Invoke-CceCheck22 {
    <#
        Restricted SharePoint Search : sortie du dispositif.

        Le dispositif est en retrait, toute nouvelle activation etant bloquee depuis
        le 31 juillet 2026. La cible est donc Disabled : un tenant encore Enabled
        presente un ecart a resorber, avec bascule vers Restricted Content Discovery.
        Sonde officielle : Get-SPOTenantRestrictedSearchMode, complete par
        Get-SPOTenantRestrictedSearchAllowedList (plafond de 100 sites).
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $evidence = [System.Collections.Generic.List[string]]::new()

    $mode = Get-CceSafe { Get-SPOTenantRestrictedSearchMode -ErrorAction Stop } -What 'Get-SPOTenantRestrictedSearchMode'

    $modeValue = ''
    if ($null -ne $mode) {
        $first = @($mode)[0]
        $modeValue = "$first".Trim()

        foreach ($name in 'RestrictedSearchMode', 'Mode', 'Value') {
            $inner = Get-CceSpoProperty -InputObject $first -Name $name
            if ($null -ne $inner -and "$inner".Trim() -ne '') { $modeValue = "$inner".Trim(); break }
        }
    }

    if ($modeValue -match '^\s*(disabled|false|0)\s*$') {
        $evidence.Add(((T 'c22.ev.disabled') -f $modeValue))
        $evidence.Add((T 'c22.ev.retired'))

        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c22.obs.mode') -f $modeValue) `
            -Evidence ($evidence | ConvertTo-CceText)
    }

    if ($modeValue -match '^\s*(enabled|true|1)\s*$') {
        $allowed = Get-CceSpoRestrictedSearchAllowedList
        $allowedCount = @($allowed.Urls).Count

        $evidence.Add(((T 'c22.ev.enabled') -f $modeValue, $allowedCount))
        $evidence.Add((T 'c22.ev.retired'))

        if (-not $allowed.Readable) { $evidence.Add((T 'c22.ev.allowed.unread')) }
        elseif ($allowedCount -eq 0) { $evidence.Add((T 'c22.ev.allowed.empty')) }
        elseif ($allowedCount -ge 100) { $evidence.Add(((T 'c22.ev.allowed.cap') -f $allowedCount)) }

        foreach ($url in @($allowed.Urls)) { $evidence.Add($url) }

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c22.obs.enabled') -f $modeValue, $allowedCount) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c22.rem.enabled')
    }

    if ($modeValue -ne '') { $evidence.Add(((T 'c22.ev.unknown') -f $modeValue)) }

    # Repli sur la propriete historique, seule disponible sur les modules anciens.
    $tenant = Get-CceSpoTenant -Context $Context
    $governedRaw = Get-CceSpoProperty -InputObject $tenant -Name 'IsContentAccessGoverned'

    if ($null -ne $governedRaw -and "$governedRaw".Trim() -ne '') {
        $governedText = "$governedRaw".Trim()
        $evidence.Add(((T 'c22.ev.legacy') -f $governedText))
        $evidence.Add((T 'c22.ev.retired'))

        if ($governedText -match '^\s*(true|1|enabled)\s*$') {
            return New-CceResult -Status 'Non conforme' `
                -Observed ((T 'c22.obs.legacy') -f $governedText) `
                -Evidence ($evidence | ConvertTo-CceText) `
                -Remediation (T 'c22.rem.enabled')
        }

        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c22.obs.legacy') -f $governedText) `
            -Evidence ($evidence | ConvertTo-CceText)
    }

    $evidence.Add((T 'c22.ev.manual'))

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c22.obs.manual') `
        -Evidence ($evidence | ConvertTo-CceText) `
        -Remediation (T 'c22.rem.manual')
}

function Invoke-CceCheck23 {
    <# Quota OneDrive a 1 To minimum #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $quota = [int64] $tenant.OneDriveStorageQuota
    $ok = $quota -ge 1048576

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c23.obs.value') -f $quota, ($quota / 1048576)) `
        -Evidence ((T 'c23.ev.value') -f $quota) `
        -Remediation $(if ($ok) { '' } else { "Set-SPOTenant -OneDriveStorageQuota 1048576" })
}

function Invoke-CceCheck59 {
    <#
        Rapports de gouvernance d'acces aux donnees (Data Access Governance).

        Cette exigence porte sur des rapports SharePoint : la sonde est le module
        Microsoft.Online.SharePoint.PowerShell (Get-SPODataAccessGovernanceInsight,
        version 16.0.25409 ou superieure), d'ou son implementation dans ce fichier.

        La cible est la base de reference des permissions : un rapport PermissionedUsers
        au statut Completed pour SharePoint ET pour OneDrive, date de moins de 90 jours,
        complete par au moins un rapport d'activite. Sans cette base, l'organisation
        deploie Copilot sans connaitre le nombre d'utilisateurs reellement habilites sur
        chaque site, c'est-a-dire sans mesurer son exposition.

        Strictement en lecture : Start-SPODataAccessGovernanceInsight et Start-SPOSiteReview
        declenchent des traitements et ne sont jamais appeles, quel que soit le contexte.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $severity = 0
    $present = 0
    $expected = 3    # PermissionedUsers SharePoint + OneDrive + un rapport d'activite

    # --- 1. Base de reference des permissions ---------------------------------
    $permInsight = [ordered]@{}
    foreach ($workload in @('SharePoint', 'OneDriveForBusiness')) {
        $permInsight[$workload] = Get-CceSpoDagInsight -Context $Context -Entity 'PermissionedUsers' -Workload $workload
    }

    $reason = $permInsight['SharePoint'].Reason

    if ($reason -ne 'ok') {
        # Licence absente : la capacite n'est pas detenue par le tenant, elle sort du score.
        if ($reason -eq 'license') {
            return New-CceNotApplicable -Reason (T 'c59.ev.license') -RequiredLicense $script:CceSpoAdvancedManagementLicense
        }

        $evidence.Add((T 'c59.ev.manual'))
        $detail = "$($permInsight['SharePoint'].Message)".Trim()
        if ($detail -ne '') { $evidence.Add(((T 'c59.ev.detail') -f $detail)) }

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c59.obs.manual') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c59.rem.manual')
    }

    foreach ($workload in @($permInsight.Keys)) {
        $report = Get-CceSpoLatestReport -Insight $permInsight[$workload]

        if ($null -eq $report -or -not $report.Completed) {
            $evidence.Add(((T 'c59.ev.perm.missing') -f $workload))
            $severity = [Math]::Max($severity, 1)
            continue
        }

        $evidence.Add(((T 'c59.ev.perm') -f $workload, $report.Status, $report.Created, $report.SiteCount))

        if ($report.AgeDays -ge 0 -and $report.AgeDays -gt $script:CceSpoDagMaxAgeDays) {
            $evidence.Add(((T 'c59.ev.perm.stale') -f $workload, $report.AgeDays, $script:CceSpoDagMaxAgeDays))
            $severity = [Math]::Max($severity, 1)
        }
        else { $present++ }
    }

    # --- 2. Rapports d'activite ------------------------------------------------
    $activity = $false

    foreach ($entity in $script:CceSpoDagActivityEntity) {
        $report = Get-CceSpoLatestReport -Insight (Get-CceSpoDagInsight -Context $Context -Entity $entity -Workload 'SharePoint')
        if ($null -eq $report) { continue }

        $evidence.Add(((T 'c59.ev.activity') -f $entity, $report.Status, $report.Created))
        if ($report.Completed) { $activity = $true }
    }

    if ($activity) { $present++ }
    else {
        $evidence.Add((T 'c59.ev.activity.none'))
        $severity = [Math]::Max($severity, 1)

        # Sans collecte d'audit initiee, aucun rapport d'activite ne sera jamais produit.
        $audit = Invoke-CceSpoModuleCommand -Name 'Get-SPOAuditDataCollectionStatusForActivityInsights' `
            -Parameter @{ ReportEntity = 'SharingLinks_Anyone' }

        if ($audit.Available) {
            $first = @($audit.Output) | Select-Object -First 1
            $auditStatus = Get-CceSpoFirstProperty -InputObject $first -Name 'Status', 'AuditDataCollectionStatus', 'State'
            if ($auditStatus -eq '') { $auditStatus = "$first".Trim() }
            if ($auditStatus -ne '') { $evidence.Add(((T 'c59.ev.audit') -f $auditStatus)) }
        }
    }

    # --- 3. Revues d'acces de sites deja initiees (informatif) -----------------
    $review = Invoke-CceSpoModuleCommand -Name 'Get-SPOSiteReview' -Parameter @{ ReportEntity = 'PermissionedUsers' }
    if ($review.Available) { $evidence.Add(((T 'c59.ev.review') -f @($review.Output).Count)) }

    # --- 4. Verdict -----------------------------------------------------------
    if ($present -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c59.obs.none') `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 25) `
            -Remediation (T 'c59.rem.ko')
    }

    if ($present -lt $expected -or $severity -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c59.obs.partial') -f $present, $expected) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 25) `
            -Remediation (T 'c59.rem.ko')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c59.obs.ok') -f $present, $script:CceSpoDagMaxAgeDays) `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 25)
}

function Get-CceSpoTriState {
    <#
    .SYNOPSIS
        Normalise une propriete booleenne SharePoint en 'true', 'false' ou '' (illisible).
    .DESCRIPTION
        Selon la version du module, un interrupteur remonte en booleen, en entier ou sous
        forme de libelle d'enumeration. La chaine vide distingue le cas "propriete absente
        du module installe" du cas "reglage desactive" : les confondre transformerait une
        limite du moteur en ecart de configuration.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    $raw = "$(Get-CceSpoProperty -InputObject $InputObject -Name $Name)".Trim()
    if ($raw -eq '') { return '' }
    if ($raw -match '^(true|1|yes|on|enabled)$') { return 'true' }
    if ($raw -match '^(false|0|no|off|disabled)$') { return 'false' }
    ''
}

function ConvertTo-CceSpoUrlList {
    <#
    .SYNOPSIS
        Normalise une liste de sites SharePoint (chaines, objets ou chaine separee) en URL.
    .DESCRIPTION
        Les listes de perimetre (KnowledgeAgentSelectedSitesList, listes autorisees)
        remontent tantot en tableau de chaines, tantot en objets, tantot en une chaine
        unique separee par des points-virgules selon la version du module.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param($Value)

    if ($null -eq $Value) { return @() }

    $entries = if ($Value -is [string]) { $Value -split '[;,]' } else { @($Value) }

    $urls = foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) { $entry.Trim(); continue }

        $candidate = Get-CceSpoFirstProperty -InputObject $entry -Name 'Url', 'SiteUrl', 'SiteId', 'Name'
        if ($candidate -eq '') { $candidate = "$entry".Trim() }
        $candidate
    }

    @($urls | Where-Object { $_ -ne '' })
}

function Get-CceSpoRestrictedSite {
    <#
    .SYNOPSIS
        Sites places sous Restricted Content Discovery, lus dans l'inventaire deja collecte.
    .DESCRIPTION
        Aucune requete par site : la propriete RestrictContentOrgWideSearch est portee par
        les objets de Get-CceAllSpoSite. Elle n'existe que sur les versions recentes du
        module, d'ou l'indicateur Readable qui evite de conclure a une absence de
        restriction alors que la propriete n'a simplement pas ete lue.
    .OUTPUTS
        Objet { Readable = bool ; Sites = object[] }.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SpoRcdSites')) { return $Context.Cache['SpoRcdSites'] }

    $sites = @(Get-CceAllSpoSite -Context $Context)
    $readable = ($sites.Count -gt 0 -and $null -ne $sites[0].PSObject.Properties['RestrictContentOrgWideSearch'])

    $restricted = @()
    if ($readable) {
        $restricted = @($sites | Where-Object {
                "$(Get-CceSpoProperty -InputObject $_ -Name 'RestrictContentOrgWideSearch')".Trim() -match '^(true|1)$'
            })
    }

    $outcome = [pscustomobject]@{ Readable = $readable; Sites = $restricted }
    $Context.Cache['SpoRcdSites'] = $outcome
    $outcome
}

function Get-CceSpoAgentInsight {
    <#
    .SYNOPSIS
        Rapports d'inventaire des agents SharePoint deja generes (lecture seule, mise en cache).
    .DESCRIPTION
        Get-SPOCopilotAgentInsightsReport retourne les metadonnees des rapports existants.
        Le declenchement (Start-SPOCopilotAgentInsightsReport) cree une ressource cote
        service : il n'est jamais decide ici, mais par le controle appelant, sur opt-in.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SpoAgentReport')) { return $Context.Cache['SpoAgentReport'] }

    $outcome = Invoke-CceSpoModuleCommand -Name 'Get-SPOCopilotAgentInsightsReport'

    $reports = @()
    if ($outcome.Available) {
        $reports = @(@($outcome.Output) | ForEach-Object { ConvertTo-CceSpoReportEntry -Raw $_ })
    }

    $insight = [pscustomobject]@{
        Available = $outcome.Available
        Reason    = $outcome.Reason
        Message   = $outcome.Message
        Reports   = $reports
    }

    $Context.Cache['SpoAgentReport'] = $insight
    $insight
}

function Get-CceSpoEeeuSiteCount {
    <#
    .SYNOPSIS
        Nombre de sites remontes par le rapport EveryoneExceptExternalUsersAtSite, -1 si inconnu.
    .DESCRIPTION
        Mesure partagee par les controles 18, 62 et 63 : le rapport est lu une seule fois
        et conserve dans le cache de la gouvernance d'acces aux donnees.
    #>
    [CmdletBinding()] param($Context)

    $insight = Get-CceSpoDagInsight -Context $Context -Entity 'EveryoneExceptExternalUsersAtSite' -Workload 'SharePoint'
    $report = Get-CceSpoLatestReport -Insight $insight

    if ($null -eq $report -or -not $report.Completed -or $report.SiteCount -lt 0) { return -1 }
    $report.SiteCount
}

function Invoke-CceCheck60 {
    <#
        Etiquettes de sensibilite actives pour les fichiers Office dans SharePoint et OneDrive.

        EnableAIPIntegration est le prerequis d'ancrage des exigences portant sur les
        etiquettes : tant qu'il reste a False, SharePoint et OneDrive ne traitent pas le
        contenu des fichiers Office chiffres par une etiquette. Ces documents ne sont ni
        indexes ni exploitables par Copilot alors meme que les etiquettes sont publiees et
        appliquees. Le reglage est un opt-in, jamais actif par defaut sur les tenants
        anciens, et il est propre a chaque geographie en Multi-Geo.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $tenant = Get-CceSpoTenant -Context $Context
    if ($null -eq $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $aipRaw = "$(Get-CceSpoProperty -InputObject $tenant -Name 'EnableAIPIntegration')".Trim()
    $aip = Get-CceSpoTriState -InputObject $tenant -Name 'EnableAIPIntegration'
    $noteRaw = "$(Get-CceSpoProperty -InputObject $tenant -Name 'EnableSensitivityLabelforOneNote')".Trim()
    $note = Get-CceSpoTriState -InputObject $tenant -Name 'EnableSensitivityLabelforOneNote'

    $evidence = [System.Collections.Generic.List[string]]::new()

    if ($aip -eq '') {
        $evidence.Add((T 'c60.ev.unknown'))
        $evidence.Add((T 'c60.ev.multigeo'))

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c60.obs.unknown') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c60.rem.unknown')
    }

    if ($aip -ne 'true') {
        $evidence.Add((T 'c60.ev.ko'))
        $evidence.Add((T 'c60.ev.multigeo'))

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c60.obs.ko') -f $aipRaw) `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c60.rem.ko')
    }

    $evidence.Add((T 'c60.ev.ok'))

    switch ($note) {
        'true' { $evidence.Add(((T 'c60.ev.onenote.ok') -f $noteRaw)) }
        'false' { $evidence.Add(((T 'c60.ev.onenote.ko') -f $noteRaw)) }
        default { $evidence.Add((T 'c60.ev.onenote.unknown')) }
    }

    $evidence.Add((T 'c60.ev.multigeo'))

    if ($note -eq 'false') {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c60.obs.onenote') -f $aipRaw, $noteRaw) `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c60.rem.onenote')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c60.obs.ok') -f $aipRaw) `
        -Evidence ($evidence | ConvertTo-CceText)
}

function Invoke-CceCheck61 {
    <#
        Revendications de partage a l'echelle de l'organisation dans le selecteur de personnes.

        Tant que "Tout le monde sauf les utilisateurs externes", "Tous les utilisateurs" et
        "Everyone" restent proposees dans le selecteur, un proprietaire de site rend en trois
        clics une bibliotheque entiere lisible par tout le tenant. C'est le seul controle
        preventif qui empeche la creation de nouveaux sur-partages internes pendant que les
        rapports de gouvernance d'acces aux donnees servent a nettoyer l'existant.

        "Everyone" et "Tous les utilisateurs" n'ont pas d'usage legitime documente : leur
        visibilite est un ecart. La revendication EEEU peut relever d'un usage intranet
        assume : elle produit un avertissement, a confirmer et documenter par l'auditeur.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $tenant = Get-CceSpoTenant -Context $Context
    if ($null -eq $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $everyone = Get-CceSpoTriState -InputObject $tenant -Name 'ShowEveryoneClaim'
    $allUsers = Get-CceSpoTriState -InputObject $tenant -Name 'ShowAllUsersClaim'
    $eeeu = Get-CceSpoTriState -InputObject $tenant -Name 'ShowEveryoneExceptExternalUsersClaim'

    $evidence = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $visible = 0
    $readable = 0
    $severity = 0

    # --- 1. Revendications exposees par le selecteur de personnes -------------
    if ($everyone -eq '') { $missing.Add('ShowEveryoneClaim') }
    elseif ($everyone -eq 'true') {
        $readable++; $visible++; $severity = 2
        $evidence.Add((T 'c61.ev.everyone.on'))
    }
    else {
        $readable++
        $evidence.Add((T 'c61.ev.everyone.off'))
    }

    if ($allUsers -eq '') { $missing.Add('ShowAllUsersClaim') }
    elseif ($allUsers -eq 'true') {
        $readable++; $visible++; $severity = 2
        $evidence.Add((T 'c61.ev.allusers.on'))
    }
    else {
        $readable++
        $evidence.Add((T 'c61.ev.allusers.off'))
    }

    if ($eeeu -eq '') { $missing.Add('ShowEveryoneExceptExternalUsersClaim') }
    elseif ($eeeu -eq 'true') {
        $readable++; $visible++
        $severity = [Math]::Max($severity, 1)
        $evidence.Add((T 'c61.ev.eeeu.on'))
    }
    else {
        $readable++
        $evidence.Add((T 'c61.ev.eeeu.off'))
    }

    if ($missing.Count -gt 0) { $evidence.Add(((T 'c61.ev.missing') -f ($missing -join ', '))) }

    if ($readable -eq 0) {
        $evidence.Add((T 'c61.ev.unknown'))

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c61.obs.unknown') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c61.rem.unknown')
    }

    # --- 2. Complement par site : liens "Personnes de votre organisation" ------
    # Lecture de l'inventaire deja collecte, jamais un appel par site.
    $sites = @(Get-CceAllSpoSite -Context $Context)

    if ($sites.Count -gt 0 -and $null -ne $sites[0].PSObject.Properties['DisableCompanyWideSharingLinks']) {
        $disabled = @($sites | Where-Object {
                "$(Get-CceSpoProperty -InputObject $_ -Name 'DisableCompanyWideSharingLinks')".Trim() -match '^(true|1|disabled)$'
            })

        if ($disabled.Count -gt 0) { $evidence.Add(((T 'c61.ev.sitelinks') -f $disabled.Count, $sites.Count)) }
        else { $evidence.Add(((T 'c61.ev.sitelinks.none') -f $sites.Count)) }
    }
    elseif ($sites.Count -gt 0) { $evidence.Add((T 'c61.ev.sitelinks.unread')) }

    # --- 3. Verdict ------------------------------------------------------------
    $observed = if ($visible -gt 0) { (T 'c61.obs.ko') -f $visible, $readable }
    else { (T 'c61.obs.ok') -f $readable }

    $status = switch ($severity) {
        2 { 'Non conforme' }
        1 { 'Attention' }
        default { 'Conforme' }
    }

    New-CceResult -Status $status -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
        -Remediation $(if ($severity -eq 0) { '' } else { T 'c61.rem.ko' })
}

function Invoke-CceCheck62 {
    <#
        Restricted Content Discovery appliquee aux sites sensibles non encore remedies.

        Le controle 21 inventorie les sites restreints et verifie que la restriction reste
        pilotee centralement ; celui-ci pose la question inverse, la seule qui compte avant
        un go-live : les sites a haut risque sont-ils couverts pendant la revue des
        permissions ? RCD retire un site des reponses Copilot et de la recherche
        organisationnelle sans modifier aucune permission, et lui retire ses points d'entree
        IA. Sans elle, un site RH ou Finance identifie comme sur-partage reste interrogeable
        en langage naturel par tout le tenant pendant toute la duree de la remediation.

        Le sur-partage mesure (rapport EveryoneExceptExternalUsersAtSite) fait foi ; la
        detection par mot-cle ne sert qu'a nommer des sites a confirmer, jamais a prononcer
        un ecart a elle seule.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    # --- 1. Le dispositif est-il detenu par le tenant ? ------------------------
    $report = Get-CceSpoRcdReport -Context $Context
    if ($report.Reason -eq 'license') {
        return New-CceNotApplicable -Reason (T 'c62.ev.license') -RequiredLicense $script:CceSpoAdvancedManagementLicense
    }

    $sites = @(Get-CceAllSpoSite -Context $Context)
    if ($sites.Count -eq 0) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $severity = 0

    # --- 2. Perimetre effectivement couvert -----------------------------------
    $rcd = Get-CceSpoRestrictedSite -Context $Context

    if (-not $rcd.Readable) {
        $evidence.Add((T 'c62.ev.property'))

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c62.obs.unknown') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c62.rem.unknown')
    }

    $restricted = @($rcd.Sites)

    # --- 3. Sites a haut risque ------------------------------------------------
    $eeeuSites = Get-CceSpoEeeuSiteCount -Context $Context
    $measured = ($eeeuSites -ge 0)

    $exposed = @($sites | Where-Object {
            "$($_.Title) $($_.Url)" -match $script:CceSensitiveSiteKeywords -and
            "$(Get-CceSpoProperty -InputObject $_ -Name 'SharingCapability')" -eq 'ExternalUserAndGuestSharing'
        })

    $uncovered = @($exposed | Where-Object { $_ -notin $restricted })

    if ($eeeuSites -gt 0) { $evidence.Add(((T 'c62.ev.eeeu') -f $eeeuSites)) }
    elseif ($eeeuSites -eq 0) { $evidence.Add((T 'c62.ev.eeeu.ok')) }
    else { $evidence.Add((T 'c62.ev.eeeu.none')) }

    $evidence.Add(((T 'c62.ev.rcd') -f $restricted.Count, $sites.Count))
    if ($restricted.Count -gt 0) { $evidence.Add((T 'c62.ev.selective')) }

    # --- 4. Delegation de la gestion de la restriction (informatif) ------------
    $tenant = Get-CceSpoTenant -Context $Context
    $delegate = Get-CceSpoTriState -InputObject $tenant -Name 'DelegateRestrictedContentDiscoverabilityManagement'

    if ($delegate -eq 'true') { $evidence.Add((T 'c62.ev.delegate.on')) }
    elseif ($delegate -eq 'false') { $evidence.Add((T 'c62.ev.delegate.off')) }

    foreach ($site in @($uncovered | Select-Object -First 20)) {
        $evidence.Add(((T 'c62.ev.site') -f $site.Title, $site.Url))
    }

    $evidence.Add((T 'c62.ev.latency'))

    # --- 5. Verdict ------------------------------------------------------------
    if (-not $measured -and $uncovered.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c62.obs.nodag') `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c62.rem.nodag')
    }

    if ($eeeuSites -gt 0 -and $restricted.Count -eq 0) { $severity = 2 }
    elseif ($eeeuSites -gt 0) { $severity = [Math]::Max($severity, 1) }
    if ($uncovered.Count -gt 0) { $severity = [Math]::Max($severity, 1) }

    $observed = if ($eeeuSites -gt 0 -and $restricted.Count -eq 0) { (T 'c62.obs.nocover') -f $eeeuSites }
    elseif ($uncovered.Count -gt 0) { (T 'c62.obs.ko') -f $uncovered.Count }
    elseif ($eeeuSites -gt 0) { (T 'c62.obs.partial') -f $restricted.Count, $eeeuSites }
    else { (T 'c62.obs.ok') -f $sites.Count }

    $status = switch ($severity) {
        2 { 'Non conforme' }
        1 { 'Attention' }
        default { 'Conforme' }
    }

    New-CceResult -Status $status -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation $(if ($severity -eq 0) { '' } else { T 'c62.rem.ko' })
}

function Invoke-CceCheck63 {
    <#
        Portee de Copilot in SharePoint : KnowledgeAgentScope.

        Copilot in SharePoint est distribue en preversion sans opt-in : aucune action
        administrateur n'est requise pour le recevoir. Le controle ne porte donc pas sur la
        capacite en preversion elle-meme, mais sur le reglage qui expose le tenant : la
        portee doit resulter d'une decision explicite et tracee, pas de la valeur par defaut
        du service. AllSites sur un tenant dont le sur-partage est encore mesure ouvre une
        interrogation en langage naturel sur des sites non audites.

        Le parametre exige le module SharePoint Online 16.0.26615.12013 ou superieur : sur
        une version anterieure la propriete est absente, ce qui est une limite du moteur et
        non un ecart de configuration.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $tenant = Get-CceSpoTenant -Context $Context
    if ($null -eq $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $scope = "$(Get-CceSpoProperty -InputObject $tenant -Name 'KnowledgeAgentScope')".Trim()

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c63.ev.optout'))

    if ($scope -eq '') {
        $evidence.Add((T 'c63.ev.module'))

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c63.obs.unknown') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c63.rem.unknown')
    }

    $selected = @(ConvertTo-CceSpoUrlList -Value (Get-CceSpoProperty -InputObject $tenant -Name 'KnowledgeAgentSelectedSitesList'))
    $severity = 0
    $eeeuSites = -1

    switch -Regex ($scope) {
        '^(?i)nosites$' {
            $evidence.Add((T 'c63.ev.nosites'))
            break
        }

        '^(?i)includeselectedsites$' {
            if ($selected.Count -eq 0) {
                $evidence.Add((T 'c63.ev.include.empty'))
                $severity = 1
            }
            else { $evidence.Add(((T 'c63.ev.include') -f $selected.Count)) }
            break
        }

        '^(?i)excludeselectedsites$' {
            if ($selected.Count -eq 0) {
                $evidence.Add((T 'c63.ev.exclude.empty'))
                $severity = 1
            }
            else { $evidence.Add(((T 'c63.ev.exclude') -f $selected.Count)) }
            break
        }

        '^(?i)allsites$' {
            $evidence.Add((T 'c63.ev.all'))
            $severity = 1

            $eeeuSites = Get-CceSpoEeeuSiteCount -Context $Context
            if ($eeeuSites -gt 0) {
                $evidence.Add(((T 'c63.ev.all.eeeu') -f $eeeuSites))
                $severity = 2
            }
            break
        }

        default {
            $evidence.Add(((T 'c63.ev.unexpected') -f $scope))
            $severity = 1
        }
    }

    # Le plafond ne concerne que les portees qui exploitent reellement la liste : une liste
    # residuelle sous NoSites ne doit pas degrader le verdict d'une decision explicite.
    if ($selected.Count -ge 100 -and $scope -match '^(include|exclude)selectedsites$') {
        $evidence.Add(((T 'c63.ev.cap') -f $selected.Count))
        $severity = [Math]::Max($severity, 1)
    }

    foreach ($url in @($selected | Select-Object -First 15)) { $evidence.Add($url) }

    $observed = if ($eeeuSites -gt 0) { (T 'c63.obs.all') -f $scope, $eeeuSites }
    else { (T 'c63.obs.scope') -f $scope, $selected.Count }

    $status = switch ($severity) {
        2 { 'Non conforme' }
        1 { 'Attention' }
        default { 'Conforme' }
    }

    New-CceResult -Status $status -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 25) `
        -Remediation $(if ($severity -eq 0) { '' } else { T 'c63.rem.ko' })
}

function Invoke-CceCheck64 {
    <#
        Inventaire des agents crees dans SharePoint.

        Les agents SharePoint sont des fichiers .agent stockes dans la bibliotheque Ressources
        du site : ils ne passent ni par le catalogue d'applications Microsoft 365, ni par
        Copilot Studio, ni par les parametres d'agents du centre d'administration. Le blocage
        d'un agent depuis le centre d'administration ne couvre pas SharePoint ni OneDrive.
        Un agent cree sur un site sur-partage constitue donc un point d'entree conversationnel
        vers tout le contenu du site, hors de portee des controles d'agents du referentiel.

        Le rapport se declenche (Start-SPOCopilotAgentInsightsReport) et se lit plus tard :
        le moteur ne lit que les rapports preexistants et ne declenche une generation que
        sur opt-in explicite de l'operateur.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $insight = Get-CceSpoAgentInsight -Context $Context
    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c64.ev.scope'))

    if (-not $insight.Available) {
        if ($insight.Reason -eq 'license') {
            return New-CceNotApplicable -Reason (T 'c64.ev.license') `
                -RequiredLicense $script:CceSpoAdvancedManagementLicense `
                -Evidence ($evidence | ConvertTo-CceText)
        }

        if ($insight.Reason -eq 'denied') { $evidence.Add(((T 'c64.ev.denied') -f $insight.Message)) }
        else { $evidence.Add((T 'c64.ev.cmdlet')) }

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c64.obs.unknown') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c64.rem.unknown')
    }

    $latest = Get-CceSpoLatestReport -Insight $insight

    if ($null -eq $latest) {
        $evidence.Add((T 'c64.ev.none'))

        # Aucun rapport preexistant : la generation reste subordonnee a un opt-in explicite,
        # le moteur demeurant sans effet de bord par defaut.
        if ([bool] (Get-CceSpoConfigValue -Context $Context -Name 'AllowReportGeneration' -Default $false)) {
            $started = Invoke-CceSpoModuleCommand -Name 'Start-SPOCopilotAgentInsightsReport' `
                -Parameter @{ Content = 'CopilotAgentsOnSites' }
            if ($started.Available) { $evidence.Add((T 'c64.ev.started')) }
        }
        else { $evidence.Add((T 'core.report.optin')) }

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c64.obs.none') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c64.rem.none')
    }

    $evidence.Add(((T 'c64.ev.report') -f $latest.Status, $latest.Created, $latest.SiteCount))
    $severity = 0

    if ($latest.AgeDays -ge 0 -and $latest.AgeDays -gt $script:CceSpoDagMaxAgeDays) {
        $evidence.Add(((T 'c64.ev.stale') -f $latest.AgeDays, $script:CceSpoDagMaxAgeDays))
        $severity = 1
    }

    # Croisement avec les sites sensibles et les sites deja retires de la decouverte :
    # lecture de l'inventaire en cache, aucune requete supplementaire par site.
    $sites = @(Get-CceAllSpoSite -Context $Context)
    $sensitive = @($sites | Where-Object { "$($_.Title) $($_.Url)" -match $script:CceSensitiveSiteKeywords })
    $rcd = Get-CceSpoRestrictedSite -Context $Context
    $evidence.Add(((T 'c64.ev.cross') -f $sensitive.Count, @($rcd.Sites).Count))
    $evidence.Add((T 'c64.ev.download'))

    if ($latest.SiteCount -lt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c64.obs.nocount') -f $latest.Status, $latest.Created) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c64.rem.agents')
    }

    if ($latest.SiteCount -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c64.obs.agents') -f $latest.SiteCount, $latest.Created) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c64.rem.agents')
    }

    if ($severity -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c64.obs.stale') -f $latest.AgeDays, $latest.Created) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c64.rem.stale')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c64.obs.ok') -f $latest.Created) `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 20)
}

function Invoke-CceCheck65 {
    <#
        Microsoft Loop et Microsoft Whiteboard actives sur le tenant.

        Ces deux interrupteurs conditionnent deux surfaces Copilot achetees avec la licence :
        sans Loop, Copilot dans Loop est indisponible et les Copilot Pages ne peuvent pas
        etre partagees comme composants dans Teams, Outlook ou OneNote ; sans Whiteboard,
        Copilot dans Whiteboard est indisponible. Ils sont frequemment restes a False sur les
        tenants deployes avant 2023, ou desactives pour limiter la creation de conteneurs
        SharePoint Embedded.

        La desactivation peut etre une decision de gouvernance assumee : le controle produit
        un avertissement a documenter, jamais un ecart automatique.
    #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $tenant = Get-CceSpoTenant -Context $Context
    if ($null -eq $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $loop = Get-CceSpoTriState -InputObject $tenant -Name 'IsLoopEnabled'
    $board = Get-CceSpoTriState -InputObject $tenant -Name 'IsWBFluidEnabled'
    $notes = Get-CceSpoTriState -InputObject $tenant -Name 'IsCollabMeetingNotesFluidEnabled'

    $evidence = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $readable = 0
    $off = 0

    if ($loop -eq '') { $missing.Add('IsLoopEnabled') }
    elseif ($loop -eq 'true') { $readable++; $evidence.Add((T 'c65.ev.loop.on')) }
    else { $readable++; $off++; $evidence.Add((T 'c65.ev.loop.off')) }

    if ($board -eq '') { $missing.Add('IsWBFluidEnabled') }
    elseif ($board -eq 'true') { $readable++; $evidence.Add((T 'c65.ev.wb.on')) }
    else { $readable++; $off++; $evidence.Add((T 'c65.ev.wb.off')) }

    if ($notes -eq '') { $missing.Add('IsCollabMeetingNotesFluidEnabled') }
    elseif ($notes -eq 'true') { $readable++; $evidence.Add((T 'c65.ev.notes.on')) }
    else { $readable++; $off++; $evidence.Add((T 'c65.ev.notes.off')) }

    if ($missing.Count -gt 0) { $evidence.Add(((T 'c65.ev.missing') -f ($missing -join ', '))) }

    if ($readable -eq 0) {
        $evidence.Add((T 'c65.ev.unknown'))

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c65.obs.unknown') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c65.rem.unknown')
    }

    $evidence.Add((T 'c65.ev.policy'))

    if ($off -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c65.obs.ko') -f $off, $readable) `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c65.rem.ko')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c65.obs.ok') -f $readable) `
        -Evidence ($evidence | ConvertTo-CceText)
}
