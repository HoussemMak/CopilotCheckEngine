#Requires -Version 7.0
<# Controles 43 a 51 - AGENTS, PLUGINS ET GOUVERNANCE COPILOT #>

# Registre d'agents du tenant (API de gestion des packages Copilot, Microsoft Agent 365).
# Le filtre documente restreint le catalogue aux packages hebergeables par Copilot ;
# une version deployee qui ne le supporte pas repond 400 et le repli sans filtre prend le relais.
$script:CceAgentPackageUri = 'https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages?$filter=supportedHosts/any(h:h eq ''Copilot'')'
$script:CceAgentPackageUriPlain = 'https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages'

# Plafonds d'execution : un tenant de plusieurs milliers de comptes ne doit jamais
# declencher une pagination sans fin.
$script:CceAgentPageMax = 20
$script:CceAgentItemMax = 2000

# Un agent inchange depuis 90 jours est un candidat a la revue trimestrielle ;
# au-dela d'un an, le signal est fort. La date exposee est une date de MODIFICATION,
# jamais une date d'usage : le verdict reste donc une alerte, pas un ecart.
$script:CceAgentDormantDays = 90
$script:CceAgentStaleDays = 365

function Get-CceAgentValue {
    <#
    .SYNOPSIS
        Lit une propriete d'un package sans supposer sa presence.
    .DESCRIPTION
        Le mode strict interdit l'acces direct a une propriete inexistante et la reponse
        Graph varie selon la version deployee : la resolution passe par PSObject, ou par
        l'indexeur lorsque la reponse est materialisee en table de hachage.
    #>
    [CmdletBinding()]
    param($Item, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $Item) { return $null }

    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }

    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-CceAgentFieldText {
    <#
    .SYNOPSIS
        Aplatit en texte un champ qui peut etre une chaine, une collection ou un objet.
    .DESCRIPTION
        availableTo, deployedTo et publisher sont documentes comme des valeurs simples
        ('all', 'none') mais peuvent etre renvoyes sous forme d'objet d'audience selon la
        version de l'API : on retient la premiere propriete porteuse de sens.
    #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value.Trim() }
    if ($Value -is [bool]) { return "$Value" }

    $names = @('scope', 'value', 'type', 'audienceType', 'audienceScope', 'displayName', 'name', 'id')

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($name in $names) {
            if ($Value.Contains($name) -and "$($Value[$name])".Trim() -ne '') { return "$($Value[$name])".Trim() }
        }
        return ''
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($entry in $Value) { Get-CceAgentFieldText -Value $entry }
        return (@($parts | Where-Object { "$_" -ne '' }) -join ', ')
    }

    foreach ($name in $names) {
        $property = $Value.PSObject.Properties[$name]
        if ($null -ne $property -and "$($property.Value)".Trim() -ne '') { return "$($property.Value)".Trim() }
    }

    "$Value".Trim()
}

function Test-CceAgentTenantWide {
    <# Vrai lorsque la portee lue designe l'ensemble de l'organisation. #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $Scope)

    if ([string]::IsNullOrWhiteSpace($Scope)) { return $false }
    $Scope.Trim().ToLowerInvariant() -in @('all', 'allusers', 'alluser', 'everyone', 'entiretenant', 'tenant', 'organization', 'wholetenant')
}

function Get-CceAgentDate {
    <# Convertit une date ISO 8601 en DateTime, ou $null si le champ est absent ou illisible. #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [ref] $parsed)) { return $parsed }
    $null
}

function Get-CceAgentSetting {
    <# Lit un parametre d'execution du contexte sans supposer sa presence. #>
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory)] [string] $Name)

    if ($Context.Config -is [System.Collections.IDictionary] -and $Context.Config.Contains($Name)) {
        return "$($Context.Config[$Name])".Trim()
    }
    ''
}

function Get-CceAgentGraphResponse {
    <#
    .SYNOPSIS
        Appel Graph du registre d'agents, avec conservation du code HTTP.
    .DESCRIPTION
        Le collecteur mutualise neutralise l'erreur en $null ; ici la nature de l'echec
        porte le verdict : 403 sans licence Microsoft Agent 365 rend le controle sans objet,
        alors qu'un refus d'autorisation rend le controle non evalue. Le code est lu sur la
        reponse quand elle est exposee, sinon deduit du message.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri)

    try {
        $value = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Status = 200; Value = $value; Message = '' }
    }
    catch {
        $message = "$($_.Exception.Message)"
        $hint = $message
        $status = 0

        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $codeProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
            if ($null -ne $codeProperty -and $null -ne $codeProperty.Value) { $hint = "$($codeProperty.Value) $message" }
        }

        foreach ($candidate in @(400, 401, 403, 404, 429, 500, 501, 503)) {
            if ($hint -match "\b$candidate\b") { $status = $candidate; break }
        }

        if ($status -eq 0) {
            if ($hint -match '(?i)forbidden|denied|privileg') { $status = 403 }
            elseif ($hint -match '(?i)unauthorized|invalidauthenticationtoken') { $status = 401 }
            elseif ($hint -match '(?i)notfound|not\s+found|unknown\s+version|badrequest') { $status = 404 }
        }

        [pscustomobject]@{ Ok = $false; Status = $status; Value = $null; Message = $message }
    }
}

function Get-CceAgentInventory {
    <#
    .SYNOPSIS
        Inventaire des agents du tenant, collecte une seule fois par execution.
    .DESCRIPTION
        Source : API de gestion des packages Copilot (registre d'agents Microsoft Agent 365),
        portee CopilotPackages.Read.All, role Administrateur IA ou Administrateur general.
        Les controles 43, 44, 48 et 51 s'appuient sur le meme resultat, mis en cache y compris
        lorsqu'il echoue : un tenant sans licence ne doit pas payer quatre appels refuses.
        State : 'ok' | 'graph' | 'license' | 'rights' | 'error'.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('AgentPackages')) { return $Context.Cache['AgentPackages'] }

    $inventory = [pscustomobject]@{
        State     = 'error'
        Packages  = @()
        Truncated = $false
        Detail    = ''
    }

    if (-not $Context.Services.Graph) {
        $inventory.State = 'graph'
        $Context.Cache['AgentPackages'] = $inventory
        return $inventory
    }

    $response = Get-CceAgentGraphResponse -Uri $script:CceAgentPackageUri
    if (-not $response.Ok -and $response.Status -eq 400) {
        $response = Get-CceAgentGraphResponse -Uri $script:CceAgentPackageUriPlain
    }

    if (-not $response.Ok) {
        $inventory.Detail = $response.Message
        $inventory.State = switch ($response.Status) {
            401     { 'rights' }
            403     {
                # Graph distingue le refus d'autorisation (portee ou role manquant) de
                # l'absence de la capacite elle-meme : seul le premier est un defaut de droits.
                if ($response.Message -match '(?i)authorization_requestdenied|insufficient privileges|accessdenied|access denied') { 'rights' } else { 'license' }
            }
            404     { 'license' }
            501     { 'license' }
            default { 'error' }
        }

        $Context.Cache['AgentPackages'] = $inventory
        return $inventory
    }

    $raw = [System.Collections.Generic.List[object]]::new()
    $current = $response.Value
    $page = 0

    while ($null -ne $current) {
        foreach ($entry in @(Get-CceAgentValue -Item $current -Name 'value')) {
            if ($null -ne $entry) { $raw.Add($entry) }
        }

        $page++
        $next = "$(Get-CceAgentValue -Item $current -Name '@odata.nextLink')".Trim()

        if ($next -eq '') { break }
        if ($page -ge $script:CceAgentPageMax -or $raw.Count -ge $script:CceAgentItemMax) {
            $inventory.Truncated = $true
            break
        }

        $nextResponse = Get-CceAgentGraphResponse -Uri $next
        if (-not $nextResponse.Ok) {
            $inventory.Truncated = $true
            break
        }

        $current = $nextResponse.Value
    }

    $inventory.State = 'ok'
    $inventory.Packages = @(foreach ($package in $raw) {
        $publisher = ''
        foreach ($field in @('publisherName', 'publisher', 'developerName', 'developer', 'verifiedPublisher')) {
            $publisher = Get-CceAgentFieldText -Value (Get-CceAgentValue -Item $package -Name $field)
            if ($publisher -ne '') { break }
        }

        $name = Get-CceAgentFieldText -Value (Get-CceAgentValue -Item $package -Name 'displayName')
        if ($name -eq '') { $name = Get-CceAgentFieldText -Value (Get-CceAgentValue -Item $package -Name 'name') }

        [pscustomobject]@{
            Id           = "$(Get-CceAgentValue -Item $package -Name 'id')".Trim()
            Name         = $name
            Publisher    = $publisher
            IsMicrosoft  = ($publisher -ne '' -and $publisher -match '(?i)microsoft')
            AvailableTo  = Get-CceAgentFieldText -Value (Get-CceAgentValue -Item $package -Name 'availableTo')
            DeployedTo   = Get-CceAgentFieldText -Value (Get-CceAgentValue -Item $package -Name 'deployedTo')
            IsBlocked    = ("$(Get-CceAgentValue -Item $package -Name 'isBlocked')" -match '^(?i)(true|1)$')
            LastModified = Get-CceAgentDate -Value (Get-CceAgentValue -Item $package -Name 'lastModifiedDateTime')
        }
    })

    $Context.Cache['AgentPackages'] = $inventory
    $inventory
}

function New-CceAgentUnavailable {
    <#
    .SYNOPSIS
        Verdict commun des controles adosses au registre d'agents lorsqu'il est illisible.
    .DESCRIPTION
        Capacite non detenue (licence Microsoft Agent 365 absente, API non deployee) -> sans objet,
        hors denominateur du score. Droits insuffisants ou service absent -> non evalue.
    #>
    [CmdletBinding()] param($Context, $Inventory)

    switch ($Inventory.State) {
        'graph' {
            New-CceNotEvaluated -Service Graph -Context $Context
        }
        'license' {
            New-CceNotApplicable -Reason ((T 'c51.ev.unlicensed') -f $Inventory.Detail) `
                -RequiredLicense (T 'c51.ev.lic')
        }
        'rights' {
            New-CceResult -Status 'Non evalue' `
                -Observed (T 'c51.obs.denied') `
                -Evidence ((T 'c51.ev.denied') -f $Inventory.Detail) `
                -Remediation (T 'c51.rem.denied')
        }
        default {
            New-CceResult -Status 'Non evalue' `
                -Observed (T 'c51.obs.error') `
                -Evidence ((T 'c51.ev.error') -f $Inventory.Detail) `
                -Remediation (T 'c51.rem.error')
        }
    }
}

function Get-CceAgentLabel {
    <# Nom affichable d'un agent, ou marqueur localise lorsque le package n'en porte pas. #>
    [CmdletBinding()] param($Package)

    if ("$($Package.Name)".Trim() -ne '') { return "$($Package.Name)".Trim() }
    T 'c51.ev.unnamed'
}

function Get-CceAgentPublisherLabel {
    <# Editeur affichable, ou marqueur localise : un editeur absent est en soi un constat. #>
    [CmdletBinding()] param($Package)

    if ("$($Package.Publisher)".Trim() -ne '') { return "$($Package.Publisher)".Trim() }
    T 'c51.ev.nopublisher'
}

function Invoke-CceCheck43 {
    <# Restreindre la creation d'agents Copilot aux administrateurs #>
    [CmdletBinding()] param($Context)

    # Le reglage lui-meme (Copilot > Agents > Parametres > Acces utilisateur) n'est expose
    # par aucune API de lecture : le verdict reste manuel. Le registre d'agents fournit
    # cependant sa contrepartie mesuree, le nombre d'agents crees dans l'organisation.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'c43.ev.manual'))

    $inventory = Get-CceAgentInventory -Context $Context
    if ($inventory.State -eq 'ok') {
        $packages = @($inventory.Packages)
        $custom = @($packages | Where-Object { -not $_.IsMicrosoft })
        $blocked = @($packages | Where-Object { $_.IsBlocked })
        $lines.Add(((T 'c43.ev.inventory') -f $packages.Count, $custom.Count, $blocked.Count))
    }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c43.obs.manual') `
        -Evidence ($lines | ConvertTo-CceText -MaxItems 4) `
        -Remediation (T 'c43.rem.manual')
}

function Invoke-CceCheck44 {
    <# Portee de publication de chaque agent : availableTo, deployedTo, isBlocked #>
    [CmdletBinding()] param($Context)

    $inventory = Get-CceAgentInventory -Context $Context
    if ($inventory.State -ne 'ok') { return New-CceAgentUnavailable -Context $Context -Inventory $inventory }

    $packages = @($inventory.Packages)

    if ($packages.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c44.obs.none') -f 0) `
            -Evidence (T 'c44.ev.empty')
    }

    $tenantWide = @($packages | Where-Object {
        (Test-CceAgentTenantWide -Scope $_.AvailableTo) -or (Test-CceAgentTenantWide -Scope $_.DeployedTo)
    })

    # Les agents de premiere partie sont publies a l'echelle du tenant par construction, et
    # un agent bloque par l'administration n'est plus invocable : ni l'un ni l'autre ne
    # materialise une publication non maitrisee.
    $exposed = @($tenantWide | Where-Object { -not $_.IsMicrosoft -and -not $_.IsBlocked })
    $microsoft = @($tenantWide | Where-Object { $_.IsMicrosoft }).Count
    $blocked = @($tenantWide | Where-Object { $_.IsBlocked }).Count

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($package in ($exposed | Select-Object -First 20)) {
        $lines.Add(((T 'c44.ev.line') -f (Get-CceAgentLabel -Package $package), (Get-CceAgentPublisherLabel -Package $package), $package.AvailableTo, $package.DeployedTo))
    }
    $lines.Add(((T 'c44.ev.scope') -f $tenantWide.Count, $microsoft, $blocked))
    if ($inventory.Truncated) { $lines.Add(((T 'c51.ev.truncated') -f $packages.Count)) }
    $lines.Add((T 'c44.ev.studio'))

    $evidence = $lines | ConvertTo-CceText -MaxItems 25

    if ($exposed.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c44.obs.none') -f $packages.Count) `
            -Evidence $evidence
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c44.obs.ko') -f $exposed.Count, $packages.Count) `
        -Evidence $evidence `
        -Remediation (T 'c44.rem.ko')
}

function Invoke-CceCheck45 {
    <# Controler les extensions et plugins tiers autorises #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    # Inventaire des applications d'entreprise tierces consentues sur le tenant.
    $response = Invoke-CceGraphRequest -Quiet `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=servicePrincipalType eq 'Application' and accountEnabled eq true&`$select=id,displayName,appId,publisherName,tags&`$top=999"

    if (-not $response) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c45.obs.error') `
            -Evidence (T 'c45.ev.error') `
            -Remediation (T 'c45.rem.error')
    }

    $apps = (Get-CceResponseValue $response)
    $thirdParty = @($apps | Where-Object {
        "$($_.publisherName)" -notmatch 'Microsoft' -and @($_.tags) -contains 'WindowsAzureActiveDirectoryIntegratedApp'
    })

    New-CceResult -Status $(if ($thirdParty.Count -eq 0) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c45.obs.count') -f $thirdParty.Count, $apps.Count) `
        -Evidence ($thirdParty | Select-Object -First 25 |
            ForEach-Object { (T 'c45.ev.line') -f $_.displayName, $_.publisherName } | ConvertTo-CceText -MaxItems 25) `
        -Remediation $(if ($thirdParty.Count -eq 0) { '' } else {
            T 'c45.rem.ko'
        })
}

# --- Connecteurs Microsoft Graph (connecteurs Copilot) -------------------------
# Une connexion creee en visibilite 'Tout le monde' publie l'integralite de la source
# externe (CRM, ITSM, base RH tierce) dans l'index : son contenu devient citable par
# Copilot pour TOUS les utilisateurs du tenant, quelles que soient les autorisations du
# systeme d'origine. Ce mode n'est expose par aucune propriete documentee de
# externalConnection ; l'indice observable est la declaration de groupes externes, qui
# materialise la projection des autorisations de la source dans l'index.
$script:CceConnectorUri = 'https://graph.microsoft.com/v1.0/external/connections?$select=id,name,description,state,configuration'
$script:CceConnectorUriPlain = 'https://graph.microsoft.com/v1.0/external/connections'
$script:CceConnectorGroupUriFormat = 'https://graph.microsoft.com/v1.0/external/connections/{0}/groups'

# Plafonds d'execution : l'inventaire des connexions est court par nature, mais la sonde
# d'autorisation coute un appel par connexion et ne doit jamais suivre la taille du tenant.
$script:CceConnectorPageMax = 10
$script:CceConnectorItemMax = 200
$script:CceConnectorGroupProbeMax = 25
$script:CceConnectorGroupDenialMax = 3
$script:CceConnectorShownMax = 25

function Get-CceConnectorGroupProbe {
    <#
    .SYNOPSIS
        Compte les groupes externes declares par une connexion de connecteur.
    .DESCRIPTION
        Un connecteur qui respecte les autorisations de sa source projette celles-ci dans
        l'index sous forme de groupes externes ; une connexion indexee en visibilite
        'Tout le monde' n'en declare aucun. Les operations sur externalGroup restent
        reservees a l'application proprietaire de la connexion : un refus est restitue
        comme tel, jamais converti en constat de visibilite globale.
        State : 'ok' | 'denied' | 'error'.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $ConnectionId)

    $response = Get-CceAgentGraphResponse -Uri ($script:CceConnectorGroupUriFormat -f $ConnectionId)

    if ($response.Ok) {
        return [pscustomobject]@{
            State  = 'ok'
            Count  = @(Get-CceAgentValue -Item $response.Value -Name 'value').Count
            Detail = ''
        }
    }

    $state = if ($response.Status -in @(401, 403)) { 'denied' } else { 'error' }
    [pscustomobject]@{ State = $state; Count = 0; Detail = $response.Message }
}

function Get-CceConnectorInventory {
    <#
    .SYNOPSIS
        Inventaire des connexions de connecteurs Microsoft Graph, collecte une seule fois.
    .DESCRIPTION
        Source : GET /v1.0/external/connections, portee ExternalConnection.Read.All.
        Chaque connexion recoit son indice d'autorisation, mesure par une sonde plafonnee.
        Le resultat est mis en cache y compris lorsqu'il echoue : un tenant sans droit sur
        l'API ne doit pas payer deux fois le meme refus.
        State : 'ok' | 'graph' | 'error'.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('GraphConnectors')) { return $Context.Cache['GraphConnectors'] }

    $inventory = [pscustomobject]@{
        State       = 'error'
        Connections = @()
        Truncated   = $false
        Detail      = ''
    }

    if (-not $Context.Services.Graph) {
        $inventory.State = 'graph'
        $Context.Cache['GraphConnectors'] = $inventory
        return $inventory
    }

    # La projection $select n'est pas supportee par toutes les versions deployees :
    # un refus de forme bascule sur l'appel nu plutot que de perdre l'inventaire.
    $response = Get-CceAgentGraphResponse -Uri $script:CceConnectorUri
    if (-not $response.Ok -and $response.Status -in @(400, 404)) {
        $response = Get-CceAgentGraphResponse -Uri $script:CceConnectorUriPlain
    }

    if (-not $response.Ok) {
        $inventory.Detail = $response.Message
        $Context.Cache['GraphConnectors'] = $inventory
        return $inventory
    }

    $raw = [System.Collections.Generic.List[object]]::new()
    $current = $response.Value
    $page = 0

    while ($null -ne $current) {
        foreach ($entry in @(Get-CceAgentValue -Item $current -Name 'value')) {
            if ($null -ne $entry) { $raw.Add($entry) }
        }

        $page++
        $next = "$(Get-CceAgentValue -Item $current -Name '@odata.nextLink')".Trim()

        if ($next -eq '') { break }
        if ($page -ge $script:CceConnectorPageMax -or $raw.Count -ge $script:CceConnectorItemMax) {
            $inventory.Truncated = $true
            break
        }

        $nextResponse = Get-CceAgentGraphResponse -Uri $next
        if (-not $nextResponse.Ok) {
            $inventory.Truncated = $true
            break
        }

        $current = $nextResponse.Value
    }

    $probed = 0
    $denialStreak = 0

    $inventory.State = 'ok'
    $inventory.Connections = @(foreach ($connection in $raw) {
        $id = "$(Get-CceAgentValue -Item $connection -Name 'id')".Trim()
        $configuration = Get-CceAgentValue -Item $connection -Name 'configuration'
        $authorized = @(Get-CceAgentValue -Item $configuration -Name 'authorizedAppIds').Count

        # Trois refus consecutifs signent une autorisation absente au niveau de
        # l'application : inutile de payer un appel par connexion pour le reconfirmer.
        $probe = if ($id -eq '' -or $probed -ge $script:CceConnectorGroupProbeMax -or $denialStreak -ge $script:CceConnectorGroupDenialMax) {
            [pscustomobject]@{ State = 'skipped'; Count = 0; Detail = '' }
        }
        else {
            $probed++
            Get-CceConnectorGroupProbe -ConnectionId $id
        }

        if ($probe.State -eq 'denied') { $denialStreak++ }
        elseif ($probe.State -ne 'skipped') { $denialStreak = 0 }

        [pscustomobject]@{
            Id             = $id
            Name           = "$(Get-CceAgentValue -Item $connection -Name 'name')".Trim()
            Description    = "$(Get-CceAgentValue -Item $connection -Name 'description')".Trim()
            State          = "$(Get-CceAgentValue -Item $connection -Name 'state')".Trim()
            AuthorizedApps = $authorized
            GroupState     = $probe.State
            GroupCount     = $probe.Count
            GroupDetail    = $probe.Detail
        }
    })

    $Context.Cache['GraphConnectors'] = $inventory
    $inventory
}

function Get-CceConnectorLabel {
    <# Nom affichable d'une connexion, ou marqueur localise a defaut. #>
    [CmdletBinding()] param($Connection)

    if ("$($Connection.Name)".Trim() -ne '') { return "$($Connection.Name)".Trim() }
    T 'c46.ev.unnamed'
}

function Get-CceConnectorStateLabel {
    <# Etat de la connexion, ou marqueur localise lorsque l'API ne le renvoie pas. #>
    [CmdletBinding()] param($Connection)

    if ("$($Connection.State)".Trim() -ne '') { return "$($Connection.State)".Trim() }
    T 'c46.ev.nostate'
}

function Get-CceConnectorAclText {
    <# Restitution de l'indice d'autorisation d'une connexion, sans jamais conclure a sa place. #>
    [CmdletBinding()] param($Connection)

    switch ($Connection.GroupState) {
        'ok' {
            if ($Connection.GroupCount -gt 0) {
                return ((T 'c46.ev.acl.groups') -f $Connection.GroupCount)
            }
            return (T 'c46.ev.acl.everyone')
        }
        'denied'  { return (T 'c46.ev.acl.denied') }
        'skipped' { return (T 'c46.ev.acl.skipped') }
    }

    (T 'c46.ev.acl.error') -f $Connection.GroupDetail
}

function Invoke-CceCheck46 {
    <# Connecteurs Microsoft Graph : inventaire et detection des connexions indexees en visibilite 'Tout le monde' #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $inventory = Get-CceConnectorInventory -Context $Context

    if ($inventory.State -eq 'graph') { return New-CceNotEvaluated -Service Graph -Context $Context }

    if ($inventory.State -ne 'ok') {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c46.obs.error') `
            -Evidence ((T 'c46.ev.error') -f $inventory.Detail) `
            -Remediation (T 'c46.rem.error')
    }

    $connections = @($inventory.Connections)

    if ($connections.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c46.obs.none') `
            -Evidence (T 'c46.ev.none')
    }

    # Une connexion dont la sonde aboutit sans aucun groupe externe est le candidat
    # documente a la visibilite 'Tout le monde'. L'indice n'est pas une preuve : une
    # source peut projeter ses autorisations sur des identites Entra sans groupe externe.
    $everyone = @($connections | Where-Object { $_.GroupState -eq 'ok' -and $_.GroupCount -eq 0 })
    $mapped = @($connections | Where-Object { $_.GroupState -eq 'ok' -and $_.GroupCount -gt 0 })
    $unknown = @($connections | Where-Object { $_.GroupState -ne 'ok' })
    $restricted = @($connections | Where-Object { $_.AuthorizedApps -gt 0 })

    # Les connexions a risque sont restituees en tete : ce sont elles qui portent l'action.
    $ordered = @($everyone) + @($unknown) + @($mapped)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($connection in ($ordered | Select-Object -First $script:CceConnectorShownMax)) {
        $lines.Add(((T 'c46.ev.line') -f (Get-CceConnectorLabel -Connection $connection), $connection.Id, (Get-CceConnectorStateLabel -Connection $connection), (Get-CceConnectorAclText -Connection $connection)))
    }

    $lines.Add(((T 'c46.ev.summary') -f $connections.Count, $everyone.Count, $mapped.Count, $unknown.Count))
    if ($restricted.Count -gt 0) { $lines.Add(((T 'c46.ev.apps') -f $restricted.Count)) }
    if ($inventory.Truncated) { $lines.Add(((T 'c46.ev.truncated') -f $connections.Count)) }
    $lines.Add((T 'c46.ev.portal'))
    $lines.Add((T 'c46.ev.immutable'))

    $evidence = $lines | ConvertTo-CceText -MaxItems 30

    if ($everyone.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c46.obs.risk') -f $everyone.Count, $connections.Count) `
            -Evidence $evidence `
            -Remediation (T 'c46.rem.risk')
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c46.obs.ko') -f $connections.Count) `
        -Evidence $evidence `
        -Remediation (T 'c46.rem.ko')
}

function Get-CceC47AuditValue {
    <#
    .SYNOPSIS
        Lit une propriete d'un enregistrement d'audit, a la racine ou sous CopilotEventData.
    .DESCRIPTION
        Le schema CopilotInteraction expose AgentId, AgentName, AppHost, AppIdentity ou
        XPIADetected tantot a la racine de AuditData, tantot dans le noeud CopilotEventData,
        et ces champs sont absents des enregistrements anterieurs. Le mode strict interdisant
        l'acces direct a une propriete inexistante, la resolution passe par PSObject.
        Renvoie $null lorsque la propriete est absente ou vide.
    #>
    [CmdletBinding()]
    param(
        $Data,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Data) { return $null }

    $direct = $Data.PSObject.Properties[$Name]
    if ($null -ne $direct -and $null -ne $direct.Value -and "$($direct.Value)" -ne '') { return $direct.Value }

    $container = $Data.PSObject.Properties['CopilotEventData']
    if ($null -eq $container -or $null -eq $container.Value) { return $null }

    $nested = $container.Value.PSObject.Properties[$Name]
    if ($null -ne $nested -and $null -ne $nested.Value -and "$($nested.Value)" -ne '') { return $nested.Value }

    $null
}

function Invoke-CceCheck47 {
    <# Auditer les interactions agents : tracabilite par AgentId, types IA tiers, signaux XPIA/jailbreak #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $start = (Get-Date).AddDays(-7)
    $end = Get-Date

    # Get-CceSafe rend $null aussi bien sur exception que sur absence de sortie : la recherche
    # est emballee pour distinguer "journal interrogeable mais vide" de "recherche impossible".
    $probe = Get-CceSafe {
        [pscustomobject]@{
            Rows = @(Search-UnifiedAuditLog -RecordType CopilotInteraction -StartDate $start -EndDate $end -ResultSize 500 -ErrorAction Stop)
        }
    } -What 'Search-UnifiedAuditLog (CopilotInteraction)'

    if ($null -eq $probe) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c47.obs.na') `
            -Evidence (T 'c47.ev.na') `
            -Remediation (T 'c47.rem.na')
    }

    $records = @($probe.Rows)
    $count = $records.Count

    # Les interactions avec des applications IA non Microsoft relevent de deux autres types
    # d'enregistrement, soumis a la facturation a l'usage Purview et inactifs par defaut.
    $aiLines = [System.Collections.Generic.List[string]]::new()
    foreach ($recordType in @('ConnectedAIAppInteraction', 'AIAppInteraction')) {
        $aiProbe = Get-CceSafe {
            [pscustomobject]@{
                Rows = @(Search-UnifiedAuditLog -RecordType $recordType -StartDate $start -EndDate $end -ResultSize 10 -ErrorAction Stop)
            }
        } -What "Search-UnifiedAuditLog ($recordType)"

        $aiLine = if ($null -eq $aiProbe) {
            (T 'c47.ev.ai.na') -f $recordType
        }
        elseif (@($aiProbe.Rows).Count -eq 0) {
            (T 'c47.ev.ai.none') -f $recordType
        }
        else {
            (T 'c47.ev.ai.ok') -f $recordType, @($aiProbe.Rows).Count
        }

        $aiLines.Add($aiLine)
    }

    $lines = [System.Collections.Generic.List[string]]::new()

    if ($count -eq 0) {
        $lines.Add((T 'c47.ev.none'))
        foreach ($aiLine in $aiLines) { $lines.Add($aiLine) }

        return New-CceResult -Status 'Attention' `
            -Observed (T 'c47.obs.none') `
            -Evidence ($lines | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c47.rem.none')
    }

    # Depouillement des enregistrements : tracabilite par agent et signaux d'attaque.
    $agents = [ordered]@{}
    $agentless = 0
    $parsed = 0
    $xpia = 0
    $jailbreak = 0

    foreach ($record in $records) {
        $rawData = Get-CceC47AuditValue -Data $record -Name 'AuditData'
        if ([string]::IsNullOrWhiteSpace("$rawData")) { continue }

        $data = $null
        try { $data = "$rawData" | ConvertFrom-Json -ErrorAction Stop }
        catch { $data = $null }
        if ($null -eq $data) { continue }

        $parsed++

        $agentId = "$(Get-CceC47AuditValue -Data $data -Name 'AgentId')".Trim()
        $agentName = "$(Get-CceC47AuditValue -Data $data -Name 'AgentName')".Trim()
        $appHost = "$(Get-CceC47AuditValue -Data $data -Name 'AppHost')".Trim()
        if ($appHost -eq '') { $appHost = "$(Get-CceC47AuditValue -Data $data -Name 'AppIdentity')".Trim() }

        if ($agentId -eq '') {
            $agentless++
        }
        else {
            if (-not $agents.Contains($agentId)) {
                $agents[$agentId] = [pscustomobject]@{ Name = ''; Count = 0; Hosts = [ordered]@{} }
            }
            $entry = $agents[$agentId]
            $entry.Count++
            if ($entry.Name -eq '' -and $agentName -ne '') { $entry.Name = $agentName }
            if ($appHost -ne '' -and -not $entry.Hosts.Contains($appHost)) { $entry.Hosts[$appHost] = $true }
        }

        if ("$(Get-CceC47AuditValue -Data $data -Name 'XPIADetected')" -match '^(true|1)$') { $xpia++ }

        $jailbreakHit = "$(Get-CceC47AuditValue -Data $data -Name 'JailbreakDetected')" -match '^(true|1)$'
        foreach ($message in @(Get-CceC47AuditValue -Data $data -Name 'Messages')) {
            if ($null -eq $message) { continue }
            $flag = $message.PSObject.Properties['JailbreakDetected']
            if ($null -ne $flag -and "$($flag.Value)" -match '^(true|1)$') { $jailbreakHit = $true }
        }
        if ($jailbreakHit) { $jailbreak++ }
    }

    if ($parsed -eq 0) {
        # Detail illisible : le verdict historique est conserve plutot que de degrader
        # un tenant dont l'audit fonctionne, mais la limite est tracee dans la preuve.
        $lines.Add((T 'c47.ev.noparse'))
    }
    else {
        foreach ($key in ($agents.Keys | Select-Object -First 12)) {
            $entry = $agents[$key]
            $displayName = if ($entry.Name -ne '') { $entry.Name } else { T 'c47.ev.agent.unnamed' }
            $hostList = ($entry.Hosts.Keys | Sort-Object) -join ', '
            $lines.Add(((T 'c47.ev.agent') -f $displayName, $key, $entry.Count, $hostList))
        }

        if ($agentless -gt 0) { $lines.Add(((T 'c47.ev.agentless') -f $agentless)) }

        $lines.Add(((T 'c47.ev.signal') -f $xpia, $jailbreak, $parsed))
    }

    foreach ($aiLine in $aiLines) { $lines.Add($aiLine) }

    foreach ($record in ($records | Select-Object -First 5)) {
        $when = "$(Get-CceC47AuditValue -Data $record -Name 'CreationDate')"
        $who = "$(Get-CceC47AuditValue -Data $record -Name 'UserIds')"
        $what = "$(Get-CceC47AuditValue -Data $record -Name 'Operations')"
        $lines.Add(((T 'c47.ev.line') -f $when, $who, $what))
    }

    $evidence = $lines | ConvertTo-CceText -MaxItems 30

    if ($parsed -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c47.obs.ok') -f $count) `
            -Evidence $evidence
    }

    if (($xpia + $jailbreak) -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c47.obs.risk') -f $count, ($xpia + $jailbreak)) `
            -Evidence $evidence `
            -Remediation (T 'c47.rem.risk')
    }

    if ($agents.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c47.obs.noagent') -f $count) `
            -Evidence $evidence `
            -Remediation (T 'c47.rem.noagent')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c47.obs.agents') -f $count, $agents.Count) `
        -Evidence $evidence
}

function Invoke-CceCheck48 {
    <# Conformite des noms d'agents a la convention de nommage de l'organisation #>
    [CmdletBinding()] param($Context)

    $inventory = Get-CceAgentInventory -Context $Context
    if ($inventory.State -ne 'ok') { return New-CceAgentUnavailable -Context $Context -Inventory $inventory }

    $packages = @($inventory.Packages)

    # La convention appartient au client : sans motif transmis, le moteur inventorie
    # les noms sans les juger plutot que d'inventer un ecart.
    $pattern = Get-CceAgentSetting -Context $Context -Name 'AgentNamingPattern'

    # Un agent de premiere partie porte le nom decide par son editeur : seule la
    # production propre a l'organisation releve de la convention interne.
    $custom = @($packages | Where-Object { -not $_.IsMicrosoft })
    $unknownPublisher = @($packages | Where-Object { "$($_.Publisher)".Trim() -eq '' }).Count

    if ($pattern -eq '') {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($package in ($custom | Select-Object -First 20)) {
            $lines.Add(((T 'c48.ev.sample') -f (Get-CceAgentLabel -Package $package), (Get-CceAgentPublisherLabel -Package $package)))
        }
        $lines.Add(((T 'c48.ev.nopattern') -f $custom.Count))

        return New-CceResult -Status 'Non applicable' `
            -Observed (T 'c48.obs.nopattern') `
            -Evidence ($lines | ConvertTo-CceText -MaxItems 25) `
            -Remediation (T 'c48.rem.nopattern')
    }

    $regex = $null
    try { $regex = [regex]::new($pattern) }
    catch {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c48.obs.badpattern') `
            -Evidence ((T 'c48.ev.badpattern') -f $pattern, $_.Exception.Message) `
            -Remediation (T 'c48.rem.badpattern')
    }

    if ($custom.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c48.obs.nocustom') `
            -Evidence ((T 'c48.ev.nocustom') -f $packages.Count)
    }

    # Le motif est confronte au nom brut du package : un agent sans nom ne peut pas
    # respecter une convention, et le marqueur affichable ne doit jamais etre evalue.
    $offenders = @($custom | Where-Object {
        "$($_.Name)".Trim() -eq '' -or -not $regex.IsMatch("$($_.Name)".Trim())
    })

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($package in ($offenders | Select-Object -First 20)) {
        $lines.Add(((T 'c48.ev.line') -f (Get-CceAgentLabel -Package $package), (Get-CceAgentPublisherLabel -Package $package)))
    }
    $lines.Add(((T 'c48.ev.ok') -f $pattern, $custom.Count, ($custom.Count - $offenders.Count)))
    if ($unknownPublisher -gt 0) { $lines.Add(((T 'c48.ev.unknownpub') -f $unknownPublisher)) }
    if ($inventory.Truncated) { $lines.Add(((T 'c51.ev.truncated') -f $packages.Count)) }

    $evidence = $lines | ConvertTo-CceText -MaxItems 25

    if ($offenders.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c48.obs.ok') -f $custom.Count, $pattern) `
            -Evidence $evidence
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c48.obs.ko') -f $offenders.Count, $custom.Count, $pattern) `
        -Evidence $evidence `
        -Remediation (T 'c48.rem.ko')
}

function Invoke-CceCheck49 {
    <# Creer un processus d'approbation pour les nouveaux agents #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c49.obs.manual') `
        -Evidence (T 'c49.ev.manual') `
        -Remediation (T 'c49.rem.manual')
}

function Invoke-CceCheck50 {
    <# Documenter une politique d'usage des agents Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c50.obs.manual') `
        -Evidence (T 'c50.ev.manual') `
        -Remediation (T 'c50.rem.manual')
}

function Invoke-CceCheck51 {
    <# Revue periodique des agents deployes : inventaire du registre et agents dormants #>
    [CmdletBinding()] param($Context)

    $inventory = Get-CceAgentInventory -Context $Context
    if ($inventory.State -ne 'ok') { return New-CceAgentUnavailable -Context $Context -Inventory $inventory }

    $packages = @($inventory.Packages)

    if ($packages.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c51.obs.none') `
            -Evidence (T 'c51.ev.none')
    }

    $now = Get-Date
    $microsoft = @($packages | Where-Object { $_.IsMicrosoft }).Count
    $custom = @($packages | Where-Object { -not $_.IsMicrosoft }).Count
    $unknownPublisher = @($packages | Where-Object { "$($_.Publisher)".Trim() -eq '' }).Count
    $blocked = @($packages | Where-Object { $_.IsBlocked }).Count
    $undated = @($packages | Where-Object { $null -eq $_.LastModified }).Count

    $dormant = @($packages |
        Where-Object { $null -ne $_.LastModified -and ($now - $_.LastModified).TotalDays -gt $script:CceAgentDormantDays } |
        Sort-Object LastModified)
    $stale = @($dormant | Where-Object { ($now - $_.LastModified).TotalDays -gt $script:CceAgentStaleDays }).Count

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(((T 'c51.ev.summary') -f $packages.Count, $microsoft, $custom, $unknownPublisher, $blocked))

    foreach ($package in ($dormant | Select-Object -First 20)) {
        $age = [int] ($now - $package.LastModified).TotalDays
        $lines.Add(((T 'c51.ev.dormant') -f (Get-CceAgentLabel -Package $package), (Get-CceAgentPublisherLabel -Package $package), $package.LastModified.ToString('yyyy-MM-dd'), $age))
    }

    if ($stale -gt 0) { $lines.Add(((T 'c51.ev.stale') -f $stale, $script:CceAgentStaleDays)) }
    if ($undated -gt 0) { $lines.Add(((T 'c51.ev.nodate') -f $undated)) }
    if ($inventory.Truncated) { $lines.Add(((T 'c51.ev.truncated') -f $packages.Count)) }

    $evidence = $lines | ConvertTo-CceText -MaxItems 30

    if ($dormant.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c51.obs.ok') -f $packages.Count, $script:CceAgentDormantDays) `
            -Evidence $evidence
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c51.obs.dormant') -f $packages.Count, $dormant.Count, $script:CceAgentDormantDays) `
        -Evidence $evidence `
        -Remediation (T 'c51.rem.dormant')
}
