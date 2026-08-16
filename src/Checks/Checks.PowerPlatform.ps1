#Requires -Version 7.0
<#
    Controles 85 a 87 - AGENTS, PLUGINS ET GOUVERNANCE COPILOT (lot 7, agents avances)

      85 - Agents Copilot Studio a risque : mode d'authentification 'None', connexions
           fournies par le createur, createurs hors du perimetre autorise    [powerplatform]
      86 - Politique de donnees Power Platform encadrant les connecteurs et les serveurs
           MCP utilisables par les agents                                    [powerplatform]
      87 - Identites d'agent Microsoft Entra : proprietaire et sponsor, correspondance
           avec le registre, couverture par l'acces conditionnel     [graph, preversion]

    Power Platform est un domaine d'administration distinct du tenant Microsoft 365 :
    role Administrateur Power Platform, consentement propre, module
    Microsoft.PowerApps.Administration.PowerShell. Le moteur ne le connecte pas par defaut.
    Sans connexion, les controles 85 et 86 ressortent en "Non evalue" : l'absence de
    connecteur n'est pas un ecart de configuration du client.

    L'API d'identites d'agent Microsoft Entra est en PREVERSION et ses noms de proprietes
    ne sont pas stabilises. Le controle 87 n'est donc pas note (Scored = false) et retombe
    sur "Non applicable" des que l'endpoint ne repond pas, plutot que de rendre un verdict
    sur une surface d'API mouvante.

    Lecture seule stricte : aucune ecriture, aucune invite interactive (les commandes
    portant un parametre obligatoire ne sont jamais appelees), toutes les sondes sont
    plafonnees et passent par Get-CceSafe ou Invoke-CceGraphRequest.
#>

# Plafonds d'execution : aucune boucle par agent, par politique ou par identite ne peut
# croitre avec la taille du tenant.
$script:CcePpAgentMax = 200
$script:CcePpAgentDetailMax = 25
$script:CcePpPolicyMax = 20
$script:CcePpConnectorConfigMax = 10
$script:CcePpIdentityMax = 200
$script:CcePpIdentityDetailMax = 25

# Endpoint documente de l'API d'inventaire Power Platform. La requete est une lecture
# (resourcequery) : elle n'ecrit rien, malgre le verbe POST impose par l'API.
$script:CcePpInventoryUri = 'https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01'
$script:CcePpInventoryAudience = 'https://api.powerplatform.com/'
$script:CcePpInventoryTimeout = 30

# Segment de cast des identites d'agent Microsoft Entra (preversion).
$script:CcePpAgentIdentityPath = 'servicePrincipals/microsoft.graph.agentIdentity'

# Forme de nom d'une cmdlet d'inventaire d'agents. Ancre en fin de nom : elle exclut les
# commandes de configuration (Get-AdminPowerAppEnvironmentCopilotSettings et assimilees),
# qui exigent un environnement en parametre et ne sont pas des inventaires.
$script:CcePpInventoryCommandPattern = '(?i)^Get-Admin[A-Za-z]*(CopilotStudioAgent|CopilotAgent|Agent|Bot)s?$'

# Motifs de detection, tenus a l'ecart du code pour rester lisibles et ajustables.
$script:CcePpNoAuthPattern = '^\s*(none|no\s*auth|noauthentication|anonymous)\s*$'
$script:CcePpMakerPattern = '(?i)maker|author|creator|createur'
$script:CcePpBroadSharePattern = '(?i)^(true|1|tenant|everyone|organization|organisation|all)'
$script:CcePpCaAgentPattern = '(?i)agentidentit|agenticidentit|agentidentities|agenticinstance'

function Get-CcePpValue {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete, eventuellement imbriquee, sur plusieurs noms
        candidats.
    .DESCRIPTION
        Les inventaires Power Platform et les reponses Graph en preversion changent de
        forme (objet, dictionnaire, propriete a la racine ou sous "properties"). Le mode
        strict interdisant l'acces a une propriete absente, toute lecture passe ici.
        Renvoie $null lorsque aucun des chemins candidats n'aboutit a une valeur non vide.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string[]] $Name
    )

    if ($null -eq $InputObject) { return $null }

    foreach ($candidate in $Name) {
        $current = $InputObject
        $found = $true

        foreach ($segment in ($candidate -split '\.')) {
            if ($null -eq $current) { $found = $false; break }

            if ($current -is [System.Collections.IDictionary]) {
                if ($current.Contains($segment)) { $current = $current[$segment] }
                else { $found = $false; break }
                continue
            }

            $property = $current.PSObject.Properties[$segment]
            if ($property) { $current = $property.Value } else { $found = $false; break }
        }

        if ($found -and $null -ne $current -and "$current" -ne '') { return $current }
    }

    $null
}

function Get-CcePpText {
    <# Valeur textuelle nettoyee d'une propriete, chaine vide si absente. #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string[]] $Name
    )

    $value = Get-CcePpValue -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return '' }
    "$value".Trim()
}

function Get-CcePpList {
    <# Collection non nulle derriere une propriete, tableau vide si absente. #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory)] [string[]] $Name
    )

    $value = Get-CcePpValue -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return @() }

    @(@($value) | Where-Object { $null -ne $_ })
}

function Get-CcePpRows {
    <#
    .SYNOPSIS
        Normalise une reponse (Graph, API d'inventaire, cmdlet) en tableau d'elements.
    #>
    [CmdletBinding()] param($Response)

    if ($null -eq $Response) { return @() }

    $keys = @('value', 'resources', 'data', 'items')

    if ($Response -is [System.Collections.IDictionary]) {
        foreach ($key in $keys) {
            if ($Response.Contains($key)) {
                return @(@($Response[$key]) | Where-Object { $null -ne $_ })
            }
        }
        return @()
    }

    if ($Response -isnot [string] -and $Response -is [System.Collections.IEnumerable]) {
        return @(@($Response) | Where-Object { $null -ne $_ })
    }

    foreach ($key in $keys) {
        $property = $Response.PSObject.Properties[$key]
        if ($property) {
            return @(@($property.Value) | Where-Object { $null -ne $_ })
        }
    }

    @($Response)
}

function Test-CcePpCollection {
    <#
    .SYNOPSIS
        Vrai si la reponse expose reellement une collection reconnue.
    .DESCRIPTION
        Sert a distinguer "la source repond et ne contient aucun element" de "la source
        repond dans une forme inattendue". Sans cette distinction, une charge utile non
        reconnue produirait un inventaire vide, donc un verdict conforme invente.
    #>
    [CmdletBinding()] param($Response)

    if ($null -eq $Response) { return $false }
    if ($Response -isnot [string] -and $Response -is [System.Collections.IEnumerable]) { return $true }

    foreach ($key in @('value', 'resources', 'data', 'items')) {
        if ($Response -is [System.Collections.IDictionary]) {
            if ($Response.Contains($key)) { return $true }
            continue
        }
        if ($Response.PSObject.Properties[$key]) { return $true }
    }

    $false
}

function Get-CcePpItems {
    <#
    .SYNOPSIS
        Elements d'une reponse, en deballant une eventuelle enveloppe de collection.
    .DESCRIPTION
        Plusieurs sources renvoient leurs elements dans une enveloppe ("value") elle-meme
        emise comme un objet unique : Get-DlpPolicy et l'API d'inventaire notamment. Un
        niveau d'enveloppe est deballe, ce qui suffit a toutes les sources utilisees ici.
    #>
    [CmdletBinding()] param($Response)

    $rows = @(Get-CcePpRows -Response $Response)
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        foreach ($item in @(Get-CcePpRows -Response $row)) {
            if ($null -ne $item) { $items.Add($item) }
        }
    }

    @($items)
}

function Get-CcePpConfigValue {
    <# Parametre d'execution optionnel, lu sans jamais lever si la cle est absente. #>
    [CmdletBinding()]
    param(
        $Context,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Context) { return '' }

    $config = $Context.Config
    if ($null -eq $config) { return '' }

    if ($config -is [System.Collections.IDictionary]) {
        if ($config.Contains($Name)) { return "$($config[$Name])".Trim() }
        return ''
    }

    $property = $config.PSObject.Properties[$Name]
    if ($property) { return "$($property.Value)".Trim() }
    ''
}

function Test-CcePpCommandSafe {
    <#
    .SYNOPSIS
        Vrai si la commande peut etre appelee sans aucun argument.
    .DESCRIPTION
        Appeler une commande dont le jeu de parametres par defaut porte un parametre
        obligatoire declencherait une invite interactive : le moteur ne doit jamais en
        produire. Une commande dont aucun jeu n'est appelable a vide est donc ecartee.
    #>
    [CmdletBinding()] param($Command)

    if ($null -eq $Command) { return $false }

    $sets = @(Get-CceSafe { @($Command.ParameterSets) } -What 'ParameterSets')
    if ($sets.Count -eq 0) { return $false }

    $candidates = @($sets | Where-Object { $_.IsDefault })
    if ($candidates.Count -eq 0) { $candidates = $sets }

    foreach ($set in $candidates) {
        $mandatory = @(@($set.Parameters) | Where-Object { $null -ne $_ -and $_.IsMandatory })
        if ($mandatory.Count -eq 0) { return $true }
    }

    $false
}

function Get-CcePpCommand {
    <# Commande disponible portant l'un des noms demandes, sinon $null. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string[]] $Name)

    foreach ($candidate in $Name) {
        $found = Get-CceSafe { Get-Command -Name $candidate -ErrorAction SilentlyContinue } -What "Get-Command $candidate"
        $first = @($found) | Where-Object { $null -ne $_ } | Select-Object -First 1
        if ($null -ne $first) { return $first }
    }

    $null
}

function Get-CcePpInventoryCommand {
    <#
    .SYNOPSIS
        Cmdlet d'inventaire des agents exposee par le module d'administration Power Platform.
    .DESCRIPTION
        Le nom de la cmdlet d'inventaire des agents varie selon la version du module :
        plutot que de coder en dur un nom qui peut ne pas exister, le moteur demande au
        module deja charge ce qu'il expose.

        La recherche est volontairement restreinte au module REELLEMENT IMPORTE dans la
        session : une commande resolue depuis le cache d'analyse de modules ne porte pas
        les attributs de ses parametres, et l'appeler pourrait declencher une invite
        interactive sur un parametre obligatoire. Double garde : le nom doit designer un
        inventaire d'agents, et la commande doit etre appelable sans aucun argument.
    #>
    [CmdletBinding()] param()

    $module = @(Get-CceSafe {
            Get-Module -Name 'Microsoft.PowerApps.Administration.PowerShell' -ErrorAction SilentlyContinue
        } -What 'Get-Module Microsoft.PowerApps.Administration.PowerShell') | Select-Object -First 1

    if ($null -eq $module) { return $null }

    $exported = Get-CceSafe { @($module.ExportedCommands.Values) } -What 'ExportedCommands'

    foreach ($candidate in @($exported)) {
        if ($null -eq $candidate) { continue }
        if ("$($candidate.Name)" -notmatch $script:CcePpInventoryCommandPattern) { continue }
        if (-not (Test-CcePpCommandSafe -Command $candidate)) { continue }

        return $candidate
    }

    $null
}

function Get-CcePpAgentApiInventory {
    <#
    .SYNOPSIS
        Inventaire des agents Copilot Studio via l'API d'inventaire Power Platform.
    .DESCRIPTION
        Repli utilise lorsque le module n'expose aucune cmdlet d'inventaire. La requete
        resourcequery est une lecture : elle projette quelques champs et ne modifie rien.
        Le jeton est celui de la session Power Platform deja ouverte : aucune nouvelle
        authentification n'est declenchee, et tout echec retombe silencieusement.
    #>
    [CmdletBinding()] param($Context)

    $result = [pscustomobject]@{
        Available = $false
        Reason    = (T 'c85.reason.notoken')
        Rows      = @()
    }

    $tokenCommand = Get-CcePpCommand -Name 'Get-JwtToken'
    if ($null -eq $tokenCommand) { return $result }

    $hasAudience = [bool] (Get-CceSafe { $tokenCommand.Parameters.ContainsKey('Audience') } -What 'Get-JwtToken.Parameters')
    if (-not $hasAudience) { return $result }

    $token = Get-CceSafe { Get-JwtToken -Audience $script:CcePpInventoryAudience -ErrorAction Stop } -What 'Get-JwtToken'
    if ([string]::IsNullOrWhiteSpace("$token")) { return $result }

    $body = @'
{"TableName":"PowerPlatformResources","Clauses":[{"$type":"where","FieldName":"type","Operator":"==","Values":["'microsoft.copilotstudio/agents'"]},{"$type":"project","FieldList":["properties.displayName","properties.authentication","properties.channels","properties.lastPublishedAt","properties.ownerId"]}]}
'@

    $response = Get-CceSafe {
        Invoke-RestMethod -Method Post -Uri $script:CcePpInventoryUri `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' -Body $body `
            -TimeoutSec $script:CcePpInventoryTimeout -ErrorAction Stop
    } -What 'resourcequery/resources/query'

    if ($null -eq $response) {
        $result.Reason = T 'c85.reason.apifailed'
        return $result
    }

    # Charge utile non reconnue : ne surtout pas la convertir en "aucun agent".
    if (-not (Test-CcePpCollection -Response $response)) {
        $result.Reason = T 'c85.reason.apishape'
        return $result
    }

    $result.Available = $true
    $result.Reason = ''
    $result.Rows = @(Get-CcePpItems -Response $response)
    $result
}

function Get-CcePpAgentInventory {
    <#
    .SYNOPSIS
        Inventaire plafonne des agents Copilot Studio du tenant.
    .DESCRIPTION
        Deux sources successives : la cmdlet d'inventaire du module d'administration
        Power Platform, puis l'API d'inventaire documentee. Si aucune ne repond, l'objet
        renvoye porte Available = $false et le motif exact : le controle bascule alors en
        "Manuel" plutot que de conclure sur un inventaire vide.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('PpAgentInventory')) { return $Context.Cache['PpAgentInventory'] }

    $max = $script:CcePpAgentMax
    $configured = Get-CcePpConfigValue -Context $Context -Name 'AgentInventoryMax'
    if ($configured -match '^\d+$' -and [int] $configured -gt 0) { $max = [int] $configured }

    $inventory = [pscustomobject]@{
        Available = $false
        Source    = ''
        Reason    = (T 'c85.reason.nosource')
        Agents    = @()
        Total     = 0
        Truncated = $false
    }

    $rows = $null
    $source = ''

    $command = Get-CcePpInventoryCommand
    if ($null -ne $command) {
        $commandName = "$($command.Name)"
        $probe = Get-CceSafe { [pscustomobject]@{ Rows = @(& $commandName -ErrorAction Stop) } } -What $commandName

        if ($null -ne $probe) {
            $rows = @(Get-CcePpItems -Response $probe.Rows)
            $source = $commandName
        }
        else {
            $inventory.Reason = (T 'c85.reason.cmdfailed') -f $commandName
        }
    }

    if ($null -eq $rows) {
        $api = Get-CcePpAgentApiInventory -Context $Context
        if ($api.Available) {
            $rows = @($api.Rows)
            $source = $script:CcePpInventoryUri
        }
        elseif ($null -eq $command) {
            $inventory.Reason = $api.Reason
        }
    }

    if ($null -ne $rows) {
        $inventory.Available = $true
        $inventory.Source = $source
        $inventory.Reason = ''
        $inventory.Total = @($rows).Count
        $inventory.Agents = @(@($rows) | Select-Object -First $max)
        $inventory.Truncated = (@($rows).Count -gt $max)
    }

    $Context.Cache['PpAgentInventory'] = $inventory
    $inventory
}

function Get-CcePpMakerScope {
    <#
    .SYNOPSIS
        Perimetre des createurs d'agents autorises, lorsqu'il est declare a l'execution.
    .DESCRIPTION
        Le groupe des createurs autorises est propre a chaque client : il se declare par
        le parametre d'execution AgentMakerGroup (identifiant ou nom d'affichage). Sans
        valeur, le controle inventorie les createurs sans les juger, plutot que d'inventer
        une convention. Une seule page de membres est lue.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('PpMakerScope')) { return $Context.Cache['PpMakerScope'] }

    $scope = [pscustomobject]@{
        Defined  = $false
        Resolved = $false
        Name     = ''
        Members  = @()
    }

    $group = Get-CcePpConfigValue -Context $Context -Name 'AgentMakerGroup'

    if (-not [string]::IsNullOrWhiteSpace($group)) {
        $scope.Defined = $true
        $scope.Name = $group

        if (Test-CceService -Service Graph -Context $Context) {
            $groupId = $group

            if ($group -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                $escaped = $group -replace "'", "''"
                $lookup = Invoke-CceGraphRequest -Quiet `
                    -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$escaped'&`$select=id,displayName&`$top=1"
                $first = @(Get-CcePpRows -Response $lookup) | Select-Object -First 1
                $groupId = Get-CcePpText -InputObject $first -Name 'id'
            }

            if (-not [string]::IsNullOrWhiteSpace($groupId)) {
                $members = Invoke-CceGraphRequest -Quiet `
                    -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members?`$select=id,userPrincipalName,mail"

                $set = [System.Collections.Generic.List[string]]::new()
                foreach ($member in @(Get-CcePpRows -Response $members)) {
                    foreach ($field in @('userPrincipalName', 'mail', 'id')) {
                        $value = Get-CcePpText -InputObject $member -Name $field
                        if ($value) { $set.Add($value.ToLowerInvariant()) }
                    }
                }

                $scope.Members = @($set | Sort-Object -Unique)
                $scope.Resolved = ($scope.Members.Count -gt 0)
            }
        }
    }

    $Context.Cache['PpMakerScope'] = $scope
    $scope
}

function ConvertTo-CcePpAgentEntry {
    <#
    .SYNOPSIS
        Vue normalisee d'un agent Copilot Studio : nom, authentification, canaux, createur,
        origine des connexions, portee de partage.
    #>
    [CmdletBinding()] param($Agent)

    $name = Get-CcePpText -InputObject $Agent -Name 'properties.displayName', 'displayName', 'name', 'botName', 'BotName'
    if (-not $name) { $name = T 'c85.val.unnamed' }

    $auth = Get-CcePpText -InputObject $Agent -Name `
        'properties.authentication', 'authentication', 'properties.authenticationMode', 'authenticationMode', 'properties.authenticationType'

    $channelLabels = [System.Collections.Generic.List[string]]::new()
    foreach ($channel in (Get-CcePpList -InputObject $Agent -Name 'properties.channels', 'channels')) {
        $label = if ($channel -is [string]) { $channel.Trim() }
        else { Get-CcePpText -InputObject $channel -Name 'name', 'channelName', 'displayName', 'type' }

        if ($label) { $channelLabels.Add($label) }
    }

    $creator = Get-CcePpText -InputObject $Agent -Name `
        'properties.ownerId', 'properties.owner.userPrincipalName', 'properties.createdBy.userPrincipalName', `
        'properties.createdBy', 'ownerId', 'createdBy', 'owner'

    $connections = Get-CcePpText -InputObject $Agent -Name `
        'properties.connectionsProvidedBy', 'connectionsProvidedBy', 'properties.connectionProvider', `
        'properties.connectionsProvided', 'properties.authenticationTrigger'

    $sharing = Get-CcePpText -InputObject $Agent -Name `
        'properties.sharedWithTenant', 'properties.isSharedWithTenant', 'properties.shareType', `
        'properties.sharing', 'properties.securityMode'

    [pscustomobject]@{
        Name         = $name
        Auth         = $auth
        AuthKnown    = [bool] $auth
        Anonymous    = ($auth -match $script:CcePpNoAuthPattern)
        Channels     = if ($channelLabels.Count -gt 0) { (@($channelLabels | Sort-Object -Unique)) -join ', ' } else { T 'c85.val.unknown' }
        Creator      = $creator
        CreatorKnown = [bool] $creator
        MakerOwned   = ($connections -match $script:CcePpMakerPattern)
        Connections  = $connections
        BroadlyShared = ($sharing -match $script:CcePpBroadSharePattern)
    }
}

function Invoke-CceCheck85 {
    <# Agents Copilot Studio a risque : authentification None, connexions du createur, createurs hors perimetre #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service PowerPlatform -Context $Context)) {
        return New-CceNotEvaluated -Service PowerPlatform -Context $Context
    }

    $inventory = Get-CcePpAgentInventory -Context $Context

    # Aucune source d'inventaire : le controle rend la procedure, jamais un verdict.
    if (-not $inventory.Available) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c85.obs.manual') `
            -Evidence ((T 'c85.ev.manual') -f $inventory.Reason) `
            -Remediation (T 'c85.rem.manual')
    }

    $agents = @($inventory.Agents)

    if ($agents.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c85.obs.none') `
            -Evidence ((T 'c85.ev.none') -f $inventory.Source)
    }

    $scope = Get-CcePpMakerScope -Context $Context

    $entries = [System.Collections.Generic.List[object]]::new()
    $anonymous = [System.Collections.Generic.List[object]]::new()
    $makerOwned = [System.Collections.Generic.List[object]]::new()
    $outsiders = [System.Collections.Generic.List[object]]::new()
    $creators = [ordered]@{}
    $unknownAuth = 0

    foreach ($agent in $agents) {
        $entry = ConvertTo-CcePpAgentEntry -Agent $agent
        $entries.Add($entry)

        if ($entry.Anonymous) { $anonymous.Add($entry) }
        elseif (-not $entry.AuthKnown) { $unknownAuth++ }

        if ($entry.MakerOwned) { $makerOwned.Add($entry) }

        if ($entry.CreatorKnown) {
            $key = $entry.Creator
            if (-not $creators.Contains($key)) { $creators[$key] = 0 }
            $creators[$key] = [int] $creators[$key] + 1

            if ($scope.Resolved -and ($scope.Members -notcontains $key.ToLowerInvariant())) { $outsiders.Add($entry) }
        }
    }

    # --- Preuve commune : source, plafond, perimetre de createurs, agents a risque.
    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c85.ev.source') -f $inventory.Source, $agents.Count, $inventory.Total))
    if ($inventory.Truncated) { $evidence.Add(((T 'c85.ev.truncated') -f $agents.Count, $inventory.Total)) }

    if ($scope.Resolved) { $evidence.Add(((T 'c85.ev.scope.ok') -f $scope.Name, $scope.Members.Count)) }
    elseif ($scope.Defined) { $evidence.Add(((T 'c85.ev.scope.ko') -f $scope.Name)) }
    else { $evidence.Add((T 'c85.ev.scope.none')) }

    foreach ($entry in @($anonymous | Select-Object -First $script:CcePpAgentDetailMax)) {
        $evidence.Add(((T 'c85.ev.anonymous') -f $entry.Name, $entry.Channels, $(if ($entry.CreatorKnown) { $entry.Creator } else { T 'c85.val.unknown' })))
    }

    foreach ($entry in @($makerOwned | Select-Object -First $script:CcePpAgentDetailMax)) {
        $evidence.Add(((T 'c85.ev.maker') -f $entry.Name, $entry.Connections, $(if ($entry.BroadlyShared) { T 'c85.val.shared' } else { T 'c85.val.limited' })))
    }

    foreach ($entry in @($outsiders | Select-Object -First $script:CcePpAgentDetailMax)) {
        $evidence.Add(((T 'c85.ev.outsider') -f $entry.Name, $entry.Creator, $scope.Name))
    }

    foreach ($creator in @($creators.Keys | Select-Object -First 10)) {
        $evidence.Add(((T 'c85.ev.creator') -f $creator, $creators[$creator]))
    }

    if ($unknownAuth -gt 0) { $evidence.Add(((T 'c85.ev.unknown') -f $unknownAuth, $agents.Count)) }

    $proof = $evidence | ConvertTo-CceText -MaxItems 40

    # --- Verdicts, du plus grave au plus benin.
    if ($anonymous.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c85.obs.ko') -f $anonymous.Count, $agents.Count) `
            -Evidence $proof `
            -Remediation (T 'c85.rem.ko')
    }

    # Champ d'authentification absent de bout en bout : rien n'a ete mesure.
    if ($unknownAuth -eq $agents.Count) {
        return New-CceResult -Status 'Manuel' `
            -Observed ((T 'c85.obs.unknown') -f $agents.Count) `
            -Evidence $proof `
            -Remediation (T 'c85.rem.unknown')
    }

    if ($makerOwned.Count -gt 0 -or $outsiders.Count -gt 0 -or $unknownAuth -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c85.obs.warn') -f $agents.Count, $makerOwned.Count, $outsiders.Count, $unknownAuth) `
            -Evidence $proof `
            -Remediation (T 'c85.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c85.obs.ok') -f $agents.Count) `
        -Evidence $proof
}

function Get-CcePpDlpCoverage {
    <#
    .SYNOPSIS
        Vue normalisee d'une politique de donnees Power Platform : portee, classification
        des connecteurs, couverture de l'environnement par defaut.
    #>
    [CmdletBinding()]
    param(
        $Policy,
        [string] $DefaultEnvironment = ''
    )

    $name = Get-CcePpText -InputObject $Policy -Name 'displayName', 'DisplayName', 'name', 'PolicyName'
    if (-not $name) { $name = T 'c86.val.unnamed' }

    $id = Get-CcePpText -InputObject $Policy -Name 'name', 'PolicyName', 'id', 'Id'
    $type = Get-CcePpText -InputObject $Policy -Name 'environmentType', 'EnvironmentType'

    $environments = [System.Collections.Generic.List[string]]::new()
    foreach ($environment in (Get-CcePpList -InputObject $Policy -Name 'environments', 'Environments')) {
        $label = if ($environment -is [string]) { $environment.Trim() }
        else { Get-CcePpText -InputObject $environment -Name 'name', 'id', 'EnvironmentName' }

        if ($label) { $environments.Add($label.ToLowerInvariant()) }
    }

    $business = 0
    $nonBusiness = 0
    $blocked = 0

    foreach ($group in (Get-CcePpList -InputObject $Policy -Name 'connectorGroups', 'ConnectorGroups')) {
        $classification = Get-CcePpText -InputObject $group -Name 'classification', 'Classification'
        $count = @(Get-CcePpList -InputObject $group -Name 'connectors', 'Connectors').Count

        switch -Regex ($classification) {
            '(?i)^blocked'      { $blocked += $count }
            '(?i)^confidential' { $business += $count }
            '(?i)^business'     { $business += $count }
            '(?i)^general'      { $nonBusiness += $count }
            default             { $nonBusiness += $count }
        }
    }

    # Couverture de l'environnement par defaut : c'est celui ou tout createur peut publier
    # sans demander quoi que ce soit, donc celui qui doit imperativement etre couvert.
    $covers = $null
    if ($type -match '(?i)^all') { $covers = $true }
    elseif ($DefaultEnvironment) {
        $needle = $DefaultEnvironment.ToLowerInvariant()
        if ($type -match '(?i)^only') { $covers = ($environments -contains $needle) }
        elseif ($type -match '(?i)^except') { $covers = ($environments -notcontains $needle) }
    }

    [pscustomobject]@{
        Name          = $name
        Id            = $id
        Type          = if ($type) { $type } else { T 'c86.val.unknown' }
        Environments  = $environments.Count
        Business      = $business
        NonBusiness   = $nonBusiness
        Blocked       = $blocked
        CoversDefault = $covers
    }
}

function Invoke-CceCheck86 {
    <# Politique de donnees Power Platform encadrant connecteurs et serveurs MCP #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service PowerPlatform -Context $Context)) {
        return New-CceNotEvaluated -Service PowerPlatform -Context $Context
    }

    $command = Get-CcePpCommand -Name 'Get-DlpPolicy'
    if ($null -eq $command) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c86.obs.nocmd') `
            -Evidence (T 'c86.ev.nocmd') `
            -Remediation (T 'c86.rem.nocmd')
    }

    # Get-CceSafe rend $null sur exception comme sur absence de sortie : l'emballage
    # distingue "aucune politique" de "lecture impossible".
    $probe = Get-CceSafe { [pscustomobject]@{ Rows = @(Get-DlpPolicy -ErrorAction Stop) } } -What 'Get-DlpPolicy'

    if ($null -eq $probe) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c86.obs.failed') `
            -Evidence (T 'c86.ev.failed') `
            -Remediation (T 'c86.rem.failed')
    }

    # Get-DlpPolicy emet ses strategies dans une enveloppe "value" : sans deballage, le
    # moteur compterait une strategie fantome aux compteurs tous a zero.
    $policies = @(Get-CcePpItems -Response $probe.Rows)

    if ($policies.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c86.obs.none') `
            -Evidence (T 'c86.ev.none') `
            -Remediation (T 'c86.rem.none')
    }

    # Environnement par defaut : lecture facultative, un echec ne fait que reduire la
    # precision de la couverture annoncee.
    $defaultEnvironment = ''
    $defaultLabel = ''
    if ($null -ne (Get-CcePpCommand -Name 'Get-AdminPowerAppEnvironment')) {
        $environment = Get-CceSafe { @(Get-AdminPowerAppEnvironment -Default -ErrorAction Stop) | Select-Object -First 1 } -What 'Get-AdminPowerAppEnvironment -Default'
        $defaultEnvironment = Get-CcePpText -InputObject $environment -Name 'EnvironmentName', 'environmentName', 'name', 'id'
        $defaultLabel = Get-CcePpText -InputObject $environment -Name 'DisplayName', 'displayName', 'properties.displayName'
    }

    $analysed = @($policies | Select-Object -First $script:CcePpPolicyMax)
    $coverages = [System.Collections.Generic.List[object]]::new()
    foreach ($policy in $analysed) {
        $coverages.Add((Get-CcePpDlpCoverage -Policy $policy -DefaultEnvironment $defaultEnvironment))
    }

    $blockedTotal = 0
    foreach ($coverage in $coverages) { $blockedTotal += [int] $coverage.Blocked }

    $covering = @($coverages | Where-Object { $_.CoversDefault -eq $true })
    $defaultKnown = [bool] $defaultEnvironment

    # --- Politiques de connecteurs avancees : seul levier documente pour bloquer un
    # serveur MCP entier (le blocage outil par outil n'existe pas).
    $advanced = 0
    $advancedRead = $false
    $tenantId = "$($Context.Tenant.Id)"

    if ($tenantId -and $null -ne (Get-CcePpCommand -Name 'Get-PowerAppDlpPolicyConnectorConfigurations')) {
        foreach ($coverage in @($coverages | Select-Object -First $script:CcePpConnectorConfigMax)) {
            if (-not $coverage.Id) { continue }

            $policyId = $coverage.Id
            $configuration = Get-CceSafe {
                Get-PowerAppDlpPolicyConnectorConfigurations -TenantId $tenantId -PolicyName $policyId -ErrorAction Stop
            } -What 'Get-PowerAppDlpPolicyConnectorConfigurations'

            if ($null -eq $configuration) { continue }

            $advancedRead = $true
            $advanced += @(Get-CcePpList -InputObject $configuration -Name 'connectorActionConfigurations', 'ConnectorActionConfigurations').Count
            $advanced += @(Get-CcePpList -InputObject $configuration -Name 'endpointConfigurations', 'EndpointConfigurations').Count
        }
    }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c86.ev.count') -f $policies.Count, $analysed.Count))

    if ($defaultKnown) {
        $label = if ($defaultLabel) { $defaultLabel } else { $defaultEnvironment }
        $evidence.Add(((T 'c86.ev.default') -f $label, $covering.Count))
    }
    else {
        $evidence.Add((T 'c86.ev.default.unknown'))
    }

    foreach ($coverage in $coverages) {
        $evidence.Add(((T 'c86.ev.policy') -f $coverage.Name, $coverage.Type, $coverage.Business, $coverage.NonBusiness, $coverage.Blocked))
    }

    if ($advancedRead) { $evidence.Add(((T 'c86.ev.mcp') -f $advanced)) }
    else { $evidence.Add((T 'c86.ev.mcp.na')) }

    $proof = $evidence | ConvertTo-CceText -MaxItems 30

    if ($defaultKnown -and $covering.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c86.obs.warn.default') -f $policies.Count) `
            -Evidence $proof `
            -Remediation (T 'c86.rem.warn.default')
    }

    if ($blockedTotal -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c86.obs.warn.noblock') -f $policies.Count) `
            -Evidence $proof `
            -Remediation (T 'c86.rem.warn.noblock')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c86.obs.ok') -f $policies.Count, $covering.Count, $blockedTotal) `
        -Evidence $proof
}

function Get-CceEntraAgentIdentity {
    <#
    .SYNOPSIS
        Identites d'agent Microsoft Entra, si l'endpoint de preversion repond.
    .DESCRIPTION
        Trois formes d'appel sont tentees, de la plus riche a la plus simple : le segment
        de cast et l'expansion des proprietaires ne sont pas disponibles partout. Aucune
        reponse -> $null, et le controle bascule en "Non applicable".
    #>
    [CmdletBinding()] param($Context)

    $uris = @(
        "https://graph.microsoft.com/v1.0/$($script:CcePpAgentIdentityPath)?`$select=id,displayName,accountEnabled,createdDateTime&`$expand=owners&`$top=$($script:CcePpIdentityMax)",
        "https://graph.microsoft.com/v1.0/$($script:CcePpAgentIdentityPath)?`$top=$($script:CcePpIdentityMax)",
        "https://graph.microsoft.com/beta/$($script:CcePpAgentIdentityPath)?`$top=$($script:CcePpIdentityMax)"
    )

    foreach ($uri in $uris) {
        $response = Invoke-CceGraphRequest -Uri $uri -Quiet
        if ($null -ne $response) {
            return [pscustomobject]@{
                Uri        = $uri
                Identities = @(Get-CcePpRows -Response $response)
            }
        }
    }

    $null
}

function Get-CcePpCaAgentPolicy {
    <#
    .SYNOPSIS
        Strategies d'acces conditionnel qui semblent cibler des identites d'agent.
    .DESCRIPTION
        Les noms de proprietes de ciblage des identites d'agent ne sont pas stabilises :
        la detection se fait par motif sur la strategie serialisee et n'est presentee que
        comme un indice, jamais comme une preuve de couverture.
    #>
    [CmdletBinding()] param($Context)

    $result = [pscustomobject]@{ Read = $false; Names = @() }

    $policies = @(Get-CceConditionalAccessPolicy -Context $Context)
    if ($policies.Count -eq 0) { return $result }

    $result.Read = $true
    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($policy in $policies) {
        $state = Get-CcePpText -InputObject $policy -Name 'state'
        if ($state -match '(?i)^disabled') { continue }

        $json = Get-CceSafe { $policy | ConvertTo-Json -Depth 8 -Compress } -What 'ConvertTo-Json (acces conditionnel)'
        if ([string]::IsNullOrWhiteSpace("$json")) { continue }

        if ("$json" -match $script:CcePpCaAgentPattern) {
            $name = Get-CcePpText -InputObject $policy -Name 'displayName', 'id'
            if ($name) { $names.Add($name) }
        }
    }

    $result.Names = @($names | Sort-Object -Unique)
    $result
}

function Invoke-CceCheck87 {
    <# Identites d'agent Entra : proprietaire, sponsor et couverture par l'acces conditionnel #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) {
        return New-CceNotEvaluated -Service Graph -Context $Context
    }

    $probe = Get-CceEntraAgentIdentity -Context $Context

    # API en preversion : un endpoint muet n'est pas un ecart du tenant.
    if ($null -eq $probe) {
        return New-CceNotApplicable -Reason (T 'c87.na.endpoint') -Evidence (T 'c87.ev.endpoint')
    }

    $identities = @($probe.Identities)

    if ($identities.Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c87.na.none') -Evidence ((T 'c87.ev.none') -f $probe.Uri)
    }

    $orphans = [System.Collections.Generic.List[object]]::new()
    $withOwner = 0
    $withSponsorOnly = 0
    $detailBudget = $script:CcePpIdentityDetailMax
    $detailUsed = 0

    foreach ($identity in $identities) {
        $id = Get-CcePpText -InputObject $identity -Name 'id'
        $name = Get-CcePpText -InputObject $identity -Name 'displayName', 'appDisplayName'
        if (-not $name) { $name = T 'c87.val.unnamed' }

        $enabled = Get-CcePpText -InputObject $identity -Name 'accountEnabled'
        if (-not $enabled) { $enabled = T 'c87.val.unknown' }

        $owners = @(Get-CcePpList -InputObject $identity -Name 'owners').Count

        # Les proprietaires et sponsors ne sont interroges que pour les identites qui en
        # paraissent depourvues : le nombre d'appels reste borne quelle que soit la taille
        # du registre d'agents.
        $sponsors = 0
        if ($owners -eq 0 -and $id -and $detailBudget -gt 0) {
            $detailBudget--
            $detailUsed++

            $ownerResponse = Invoke-CceGraphRequest -Quiet -Uri "https://graph.microsoft.com/v1.0/$($script:CcePpAgentIdentityPath)/$id/owners?`$select=id&`$top=10"
            $owners = @(Get-CcePpRows -Response $ownerResponse).Count

            if ($owners -eq 0) {
                $sponsorResponse = Invoke-CceGraphRequest -Quiet -Uri "https://graph.microsoft.com/v1.0/$($script:CcePpAgentIdentityPath)/$id/sponsors?`$select=id&`$top=10"
                $sponsors = @(Get-CcePpRows -Response $sponsorResponse).Count
            }
        }

        if ($owners -gt 0) { $withOwner++ }
        elseif ($sponsors -gt 0) { $withSponsorOnly++ }
        else { $orphans.Add([pscustomobject]@{ Name = $name; Id = $id; Enabled = $enabled }) }
    }

    $ca = Get-CcePpCaAgentPolicy -Context $Context

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c87.ev.preview'))
    $evidence.Add(((T 'c87.ev.source') -f $probe.Uri, $identities.Count))
    $evidence.Add(((T 'c87.ev.split') -f $withOwner, $withSponsorOnly, $orphans.Count))

    if ($detailUsed -gt 0) { $evidence.Add(((T 'c87.ev.budget') -f $detailUsed, $script:CcePpIdentityDetailMax)) }

    foreach ($orphan in @($orphans | Select-Object -First $script:CcePpIdentityDetailMax)) {
        $evidence.Add(((T 'c87.ev.orphan') -f $orphan.Name, $orphan.Id, $orphan.Enabled))
    }

    if (-not $ca.Read) { $evidence.Add((T 'c87.ev.ca.na')) }
    elseif ($ca.Names.Count -gt 0) { $evidence.Add(((T 'c87.ev.ca.ok') -f $ca.Names.Count, ($ca.Names -join ', '))) }
    else { $evidence.Add((T 'c87.ev.ca.none')) }

    $proof = $evidence | ConvertTo-CceText -MaxItems 40

    if ($orphans.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c87.obs.warn') -f $orphans.Count, $identities.Count) `
            -Evidence $proof `
            -Remediation (T 'c87.rem.warn')
    }

    if ($ca.Names.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c87.obs.warn.ca') -f $identities.Count) `
            -Evidence $proof `
            -Remediation (T 'c87.rem.ca')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c87.obs.ok') -f $identities.Count, $ca.Names.Count) `
        -Evidence $proof
}
