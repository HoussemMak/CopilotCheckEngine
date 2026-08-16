#Requires -Version 7.0
<#
    Controles 72 a 79 - RESIDENCE ET SOUVERAINETE DES DONNEES

    Ce domaine ne mesure pas la securite d'un reglage Copilot mais la legitimite
    juridique de son usage : qui administre le service, qui peut acceder au contenu
    lors d'une intervention de support, ou les interactions sont stockees, combien de
    temps elles survivent au depart d'un collaborateur, et quels sous-traitants tiers
    entrent dans le traitement. Aucun de ces controles ne conditionne le fonctionnement
    de Copilot : ils conditionnent l'autorisation de s'en servir.

    Quatre limites de preuve encadrent le domaine et expliquent ses statuts :

      - les controles 76, 77 et 79 portent sur des reglages du centre d'administration
        Microsoft 365 qu'aucune API Graph ni cmdlet publique n'expose a ce jour. Ils
        restent manuels et la valeur attendue est une decision documentee, jamais un
        verdict invente par le moteur. Ils restent notes (Scored = true) parce qu'ils
        portent sur un reglage reellement present dans le tenant, et non sur une
        capacite elle-meme en preversion ;
      - le controle 78 s'appuie sur un endpoint dont la permission n'existe qu'en mode
        delegue : en contexte applicatif, le moteur ne peut que declarer le controle
        non evalue, ce qui signale un manque de perimetre et non un ecart ;
      - le controle 74 ne peut lire que ce que le tenant expose : la geographie
        effective et la Preferred Data Location des utilisateurs licencies. La
        formalisation de cette geographie dans le dossier de conformite reste un acte
        documentaire, rappele en preuve ;
      - le controle 75 combine les trois mecanismes de conservation d'une boite aux
        lettres (conservation pour litige, conservation appliquee a la boite, politique
        d'organisation dont la boite peut etre exclue). Les trois sont lus, et une
        exclusion explicite est traitee comme une absence de couverture, jamais comme
        une couverture.

    Lecture seule stricte : aucune commande de modification, aucune invite interactive.
#>

# Modeles de role Entra, resolus par identifiant ET par libelle : un identifiant qui
# changerait resterait rattrape par le libelle, et inversement.
$script:CceResidenceAiAdminRoleId = 'd2562ede-74db-457e-a7b6-544e236ebb61'
$script:CceResidenceAiAdminRoleName = 'AI Administrator'
$script:CceResidenceGlobalAdminRoleId = '62e90394-69f5-4237-9190-012177145e10'
$script:CceResidenceGlobalAdminRoleName = 'Global Administrator'
$script:CceResidenceLockboxRoleId = '9f06204d-73c1-4d4c-880a-6edb90606fd8'
$script:CceResidenceLockboxRoleName = 'Customer LockBox Access Approver'

# Deux approbateurs Customer Lockbox au minimum : une demande Microsoft expire
# silencieusement au bout de 12 heures si personne ne statue.
$script:CceResidenceLockboxApproverMin = 2

# Pagination Graph plafonnee, pour borner le cout sur un grand tenant.
$script:CceResidencePageMax = 12

# Nombre maximum de lignes nominatives reportees en preuve.
$script:CceResidenceEvidenceMax = 20

# Marqueur technique pour un principal sans libelle exploitable (jamais affiche seul).
$script:CceResidenceNoLabel = '-'

function Get-CceResidenceValue {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete.
    .DESCRIPTION
        Graph renvoie tantot des objets, tantot des dictionnaires, et Exchange des
        objets de deserialisation dont les proprietes varient selon la version du
        module. Le mode strict interdit l'acces a une propriete absente : cette
        fonction est le seul point d'acces autorise aux donnees collectees.
    #>
    [CmdletBinding()] param($Item, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $Item) { return $null }

    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }

    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Test-CceResidenceProperty {
    <# Vrai si la propriete existe reellement, meme vide : distingue "absent" de "faux". #>
    [CmdletBinding()] param($Item, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $Item) { return $false }
    if ($Item -is [System.Collections.IDictionary]) { return [bool] $Item.Contains($Name) }
    [bool] ($null -ne $Item.PSObject.Properties[$Name])
}

function Get-CceResidenceText {
    <# Valeur textuelle nettoyee, chaine vide si la propriete est absente ou nulle. #>
    [CmdletBinding()] param($Item, [Parameter(Mandatory)] [string] $Name)

    $value = Get-CceResidenceValue -Item $Item -Name $Name
    if ($null -eq $value) { return '' }
    "$value".Trim()
}

function Test-CceResidenceFlag {
    <# Conversion tolerante en booleen : Graph, Exchange et JSON n'ecrivent pas pareil. #>
    [CmdletBinding()] param($Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    [bool] ("$Value".Trim() -match '^(?i)(true|1|yes|enabled)$')
}

function Get-CceResidenceList {
    <# Normalise une valeur multivaluee en tableau de chaines non vides. #>
    [CmdletBinding()] param($Value)

    $items = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return @($items) }

    foreach ($entry in @($Value)) {
        if ($null -eq $entry) { continue }
        $text = "$entry".Trim()
        if ($text -ne '') { $items.Add($text) }
    }

    @($items)
}

function Get-CceResidenceGraphCollection {
    <#
    .SYNOPSIS
        Collection Graph paginee et plafonnee.
    .DESCRIPTION
        Le resultat est enveloppe : Ok = $false signifie "reponse illisible", jamais
        "collection vide". La distinction est vitale ici, ou une liste vide de
        titulaires de role est un ecart de configuration et une lecture refusee un
        manque de droits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [switch] $Quiet
    )

    $result = [pscustomobject]@{ Ok = $false; Items = @(); Truncated = $false }

    $response = if ($Quiet) { Invoke-CceGraphRequest -Uri $Uri -Quiet } else { Invoke-CceGraphRequest -Uri $Uri }
    if ($null -eq $response) { return $result }

    $items = [System.Collections.Generic.List[object]]::new()
    $current = $response
    $page = 0

    while ($null -ne $current) {
        foreach ($entry in @(Get-CceResidenceValue -Item $current -Name 'value')) {
            if ($null -ne $entry) { $items.Add($entry) }
        }

        $page++
        $next = "$(Get-CceResidenceValue -Item $current -Name '@odata.nextLink')".Trim()
        if ($next -eq '') { break }

        if ($page -ge $script:CceResidencePageMax) { $result.Truncated = $true; break }

        $current = Invoke-CceGraphRequest -Uri $next -Quiet
        if ($null -eq $current) { $result.Truncated = $true; break }
    }

    $result.Ok = $true
    $result.Items = @($items)
    $result
}

function ConvertTo-CceResidencePrincipal {
    <# Reduit une collection de principaux Graph a ce que la preuve doit montrer. #>
    [CmdletBinding()] param($Entries)

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }

        $rows.Add([pscustomobject]@{
            Id   = Get-CceResidenceText -Item $entry -Name 'id'
            Name = Get-CceResidenceText -Item $entry -Name 'displayName'
            Upn  = Get-CceResidenceText -Item $entry -Name 'userPrincipalName'
            Type = ((Get-CceResidenceText -Item $entry -Name '@odata.type') -replace '^#microsoft\.graph\.', '')
        })
    }

    @($rows)
}

function Get-CceResidencePrincipalLabel {
    <# Libelle d'un titulaire : UPN, a defaut nom affiche, a defaut identifiant. #>
    [CmdletBinding()] param($Principal)

    foreach ($field in 'Upn', 'Name', 'Id') {
        $value = "$(Get-CceResidenceValue -Item $Principal -Name $field)".Trim()
        if ($value -ne '') { return $value }
    }

    $script:CceResidenceNoLabel
}

function Get-CceResidenceDirectoryRole {
    <#
    .SYNOPSIS
        Roles d'annuaire actives sur le tenant, collectes une seule fois.
    .DESCRIPTION
        Un role integre n'apparait dans directoryRoles qu'une fois active. Son absence
        de la liste signifie donc "aucun titulaire", tandis qu'une liste illisible
        signifie "annuaire non lisible" : l'enveloppe conserve la difference.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ResidenceDirectoryRoles')) { return $Context.Cache['ResidenceDirectoryRoles'] }

    $result = [pscustomobject]@{ Ok = $false; Roles = @() }

    if (-not $Context.Services.Graph) {
        $Context.Cache['ResidenceDirectoryRoles'] = $result
        return $result
    }

    $roles = Get-CceResidenceGraphCollection -Uri 'https://graph.microsoft.com/v1.0/directoryRoles'
    if ($roles.Ok) {
        $result.Ok = $true
        $result.Roles = @($roles.Items)
    }

    $Context.Cache['ResidenceDirectoryRoles'] = $result
    $result
}

function Get-CceResidenceRoleHolder {
    <#
    .SYNOPSIS
        Titulaires actifs et eligibles d'un role d'annuaire.
    .DESCRIPTION
        Ok = $false : annuaire illisible (droits insuffisants).
        Found = $false : role jamais active sur le tenant, donc aucun titulaire actif.
        EligibleKnown = $false : les affectations eligibles PIM n'ont pas pu etre lues,
        ce qui n'est pas un ecart : la lecture des planifications d'eligibilite exige sa
        propre permission et le module PIM n'est pas detenu par tous les tenants.
    #>
    [CmdletBinding()]
    param(
        $Context,
        [Parameter(Mandatory)] [string] $TemplateId,
        [Parameter(Mandatory)] [string] $DisplayName
    )

    $result = [pscustomobject]@{
        Ok            = $false
        Found         = $false
        RoleId        = ''
        Members       = @()
        Eligible      = @()
        EligibleKnown = $false
    }

    $index = Get-CceResidenceDirectoryRole -Context $Context
    if (-not $index.Ok) { return $result }
    $result.Ok = $true

    $role = $null
    foreach ($entry in @($index.Roles)) {
        $template = Get-CceResidenceText -Item $entry -Name 'roleTemplateId'
        $label = Get-CceResidenceText -Item $entry -Name 'displayName'
        if ($template -eq $TemplateId -or $label -eq $DisplayName) { $role = $entry; break }
    }

    # Affectations eligibles PIM : lues meme si le role n'est pas active, car une
    # eligibilite sans activation en cours est precisement le bon etat cible.
    $eligible = Get-CceResidenceGraphCollection -Quiet `
        -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?`$filter=roleDefinitionId eq '$TemplateId'&`$expand=principal"

    if ($eligible.Ok) {
        $result.EligibleKnown = $true
        $principals = foreach ($entry in @($eligible.Items)) { Get-CceResidenceValue -Item $entry -Name 'principal' }
        $result.Eligible = @(ConvertTo-CceResidencePrincipal -Entries $principals)
    }

    if ($null -eq $role) { return $result }

    $result.Found = $true
    $result.RoleId = Get-CceResidenceText -Item $role -Name 'id'

    $members = Get-CceResidenceGraphCollection -Uri "https://graph.microsoft.com/v1.0/directoryRoles/$($result.RoleId)/members?`$top=999"
    if (-not $members.Ok) {
        $result.Ok = $false
        return $result
    }

    $result.Members = @(ConvertTo-CceResidencePrincipal -Entries $members.Items)
    $result
}

function Get-CceResidenceServicePlan {
    <#
    .SYNOPSIS
        Plans de service souscrits par le tenant, en majuscules.
    .DESCRIPTION
        Sert a detecter une capacite reellement detenue (Customer Lockbox, Multi-Geo,
        Advanced Data Residency) avant de conclure a un ecart : une capacite non
        achetee releve du statut "Non applicable", jamais d'une non-conformite.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ResidenceServicePlans')) { return $Context.Cache['ResidenceServicePlans'] }

    $result = [pscustomobject]@{ Ok = $false; Plans = @(); Skus = @() }

    # Les entrees nulles sont retirees : un collecteur en echec met en cache un element
    # nul, et le mode strict interdirait d'en lire la moindre propriete.
    $skus = @(Get-CceSubscribedSku -Context $Context | Where-Object { $null -ne $_ })
    if ($skus.Count -eq 0) {
        $Context.Cache['ResidenceServicePlans'] = $result
        return $result
    }

    $plans = [System.Collections.Generic.List[string]]::new()
    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($sku in $skus) {
        $part = Get-CceResidenceText -Item $sku -Name 'SkuPartNumber'
        if ($part -ne '' -and -not $parts.Contains($part.ToUpperInvariant())) { $parts.Add($part.ToUpperInvariant()) }

        foreach ($plan in @(Get-CceResidenceValue -Item $sku -Name 'ServicePlans')) {
            $name = Get-CceResidenceText -Item $plan -Name 'ServicePlanName'
            if ($name -eq '') { continue }
            $upper = $name.ToUpperInvariant()
            if (-not $plans.Contains($upper)) { $plans.Add($upper) }
        }
    }

    $result.Ok = $true
    $result.Plans = @($plans)
    $result.Skus = @($parts)

    $Context.Cache['ResidenceServicePlans'] = $result
    $result
}

function Test-CceResidenceCapability {
    <# Vrai si un plan de service ou un abonnement correspond au motif demande. #>
    [CmdletBinding()]
    param(
        $Inventory,
        [Parameter(Mandatory)] [string] $Pattern
    )

    if (-not $Inventory.Ok) { return $false }

    foreach ($name in (@($Inventory.Plans) + @($Inventory.Skus))) {
        if ($name -like $Pattern) { return $true }
    }

    $false
}

function Get-CceResidenceCopilotSku {
    <#
    .SYNOPSIS
        Identifiants des abonnements Copilot, lus defensivement.
    .DESCRIPTION
        Le collecteur mutualise filtre les abonnements par motif de nom, ce qui suppose
        une table d'abonnements exploitable. Cette enveloppe la relit sans jamais lever :
        Ok = $false signifie "table d'abonnements illisible", tandis que Ok = $true avec
        une liste vide signifie "tenant sans abonnement Copilot".
    #>
    [CmdletBinding()] param($Context)

    $result = [pscustomobject]@{ Ok = $false; SkuIds = @() }

    $skus = @(Get-CceSubscribedSku -Context $Context | Where-Object { $null -ne $_ })
    if ($skus.Count -eq 0) { return $result }

    $pattern = Get-CceCopilotSkuPattern
    $ids = [System.Collections.Generic.List[string]]::new()

    foreach ($sku in $skus) {
        $part = Get-CceResidenceText -Item $sku -Name 'SkuPartNumber'
        if ($part -eq '' -or $part -notlike $pattern) { continue }

        $id = Get-CceResidenceText -Item $sku -Name 'SkuId'
        if ($id -ne '' -and -not $ids.Contains($id)) { $ids.Add($id) }
    }

    $result.Ok = $true
    $result.SkuIds = @($ids)
    $result
}

function Invoke-CceCheck72 {
    <#
        Role AI Administrator attribue pour l'administration Copilot (moindre privilege).

        Le role integre AI Administrator couvre les reglages du Copilot Control System,
        l'inventaire des agents et les rapports d'adoption. Sans lui, ces taches se font
        avec Global Administrator, ce qui multiplie les comptes hautement privilegies sur
        le perimetre le plus sensible du tenant. Le moteur constate les titulaires ; le
        fait qu'aucun compte n'ait recu Global Administrator dans le seul but d'administrer
        Copilot reste une verification d'intention, rappelee en preuve.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $ai = Get-CceResidenceRoleHolder -Context $Context `
        -TemplateId $script:CceResidenceAiAdminRoleId -DisplayName $script:CceResidenceAiAdminRoleName

    if (-not $ai.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c72.obs.ne') `
            -Evidence (T 'c72.ev.ne') `
            -Remediation (T 'c72.rem.ne')
    }

    $global = Get-CceResidenceRoleHolder -Context $Context `
        -TemplateId $script:CceResidenceGlobalAdminRoleId -DisplayName $script:CceResidenceGlobalAdminRoleName

    $active = @($ai.Members)
    $eligible = @($ai.Eligible)
    $total = $active.Count + $eligible.Count

    $globalIds = @{}
    $globalKnown = [bool] $global.Ok
    if ($globalKnown) {
        foreach ($member in @($global.Members)) {
            $id = "$($member.Id)".Trim()
            if ($id -ne '') { $globalIds[$id.ToLowerInvariant()] = $true }
        }
    }

    $overlap = @(@($active) + @($eligible) | Where-Object {
        $id = "$($_.Id)".Trim()
        $id -ne '' -and $globalIds.ContainsKey($id.ToLowerInvariant())
    })

    $evidence = [System.Collections.Generic.List[string]]::new()

    foreach ($member in ($active | Select-Object -First $script:CceResidenceEvidenceMax)) {
        $evidence.Add(((T 'c72.ev.active') -f (Get-CceResidencePrincipalLabel -Principal $member), $member.Type))
    }

    foreach ($member in ($eligible | Select-Object -First $script:CceResidenceEvidenceMax)) {
        $evidence.Add(((T 'c72.ev.eligible') -f (Get-CceResidencePrincipalLabel -Principal $member), $member.Type))
    }

    $evidence.Add(((T 'c72.ev.summary') -f $active.Count, $eligible.Count))

    if ($globalKnown) { $evidence.Add(((T 'c72.ev.ga') -f @($global.Members).Count)) }
    else { $evidence.Add((T 'c72.ev.ga.unknown')) }

    if (-not $ai.EligibleKnown) { $evidence.Add((T 'c72.ev.pim.unknown')) }
    if ($overlap.Count -gt 0) { $evidence.Add(((T 'c72.ev.overlap') -f $overlap.Count, $total)) }

    $evidence.Add((T 'c72.ev.manual'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 45

    if ($total -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c72.obs.ko') `
            -Evidence $proof `
            -Remediation (T 'c72.rem.ko')
    }

    # Un titulaire AI Administrator qui est aussi Global Administrator n'apporte aucune
    # reduction de privilege : le role est attribue mais l'objectif n'est pas atteint.
    if ($globalKnown -and $overlap.Count -eq $total) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c72.obs.warn') -f $total) `
            -Evidence $proof `
            -Remediation (T 'c72.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c72.obs.ok') -f $active.Count, $eligible.Count) `
        -Evidence $proof
}

function Invoke-CceCheck73 {
    <#
        Customer Lockbox actif et au moins deux approbateurs declares.

        Les interactions Copilot etant stockees dans la boite aux lettres de
        l'utilisateur, un acces de depannage Microsoft peut porter sur tout l'historique
        des prompts et des extraits de documents cites en ancrage. Customer Lockbox
        impose une approbation explicite de l'organisation ; deux approbateurs au moins
        evitent qu'une demande expire faute de decideur disponible.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $org = Get-CceSafe { Get-OrganizationConfig -ErrorAction Stop } -What 'Get-OrganizationConfig (CustomerLockBoxEnabled)'

    if ($null -eq $org) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c73.obs.ne') `
            -Evidence (T 'c73.ev.ne') `
            -Remediation (T 'c73.rem.ne')
    }

    if (-not (Test-CceResidenceProperty -Item $org -Name 'CustomerLockBoxEnabled')) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c73.obs.noprop') `
            -Evidence (T 'c73.ev.noprop') `
            -Remediation (T 'c73.rem.noprop')
    }

    $enabled = Test-CceResidenceFlag -Value (Get-CceResidenceValue -Item $org -Name 'CustomerLockBoxEnabled')

    # Capacite non detenue : Customer Lockbox est inclus dans les plans E5 ou dans le
    # module complementaire de conformite. Sans le plan de service correspondant, le
    # reglage ne peut pas etre active : c'est un manque de licence, pas un ecart.
    $inventory = Get-CceResidenceServicePlan -Context $Context
    if (-not $enabled -and $inventory.Ok -and -not (Test-CceResidenceCapability -Inventory $inventory -Pattern '*LOCKBOX*')) {
        return New-CceNotApplicable -Reason (T 'c73.na.reason') -RequiredLicense (T 'c73.na.lic')
    }

    $approvers = Get-CceResidenceRoleHolder -Context $Context `
        -TemplateId $script:CceResidenceLockboxRoleId -DisplayName $script:CceResidenceLockboxRoleName

    $known = [bool] ($Context.Services.Graph -and $approvers.Ok)
    $members = @($approvers.Members)

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c73.ev.state') -f $enabled))

    if ($known) {
        foreach ($member in ($members | Select-Object -First $script:CceResidenceEvidenceMax)) {
            $evidence.Add(((T 'c73.ev.approver') -f (Get-CceResidencePrincipalLabel -Principal $member)))
        }

        $evidence.Add(((T 'c73.ev.summary') -f $members.Count, $script:CceResidenceLockboxApproverMin))
        if (-not $approvers.Found) { $evidence.Add((T 'c73.ev.role.missing')) }
    }
    elseif (-not $Context.Services.Graph) {
        $evidence.Add((T 'c73.ev.graph.off'))
    }
    else {
        $evidence.Add((T 'c73.ev.role.unreadable'))
    }

    $evidence.Add((T 'c73.ev.expiry'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 30

    if (-not $enabled) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c73.obs.ko') -f $enabled) `
            -Evidence $proof `
            -Remediation (T 'c73.rem.ko')
    }

    if (-not $known) {
        return New-CceResult -Status 'Attention' `
            -Observed (T 'c73.obs.warn.unknown') `
            -Evidence $proof `
            -Remediation (T 'c73.rem.warn.unknown')
    }

    if ($members.Count -lt $script:CceResidenceLockboxApproverMin) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c73.obs.warn.approver') -f $members.Count, $script:CceResidenceLockboxApproverMin) `
            -Evidence $proof `
            -Remediation (T 'c73.rem.warn.approver')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c73.obs.ok') -f $members.Count) `
        -Evidence $proof
}

function Get-CceResidenceOrganization {
    <# Profil d'organisation : pays d'inscription et emplacement de donnees prefere. #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ResidenceOrganization')) { return $Context.Cache['ResidenceOrganization'] }

    $result = [pscustomobject]@{ Ok = $false; Country = ''; DataLocation = ''; Name = '' }

    if (-not $Context.Services.Graph) {
        $Context.Cache['ResidenceOrganization'] = $result
        return $result
    }

    # Le $select est tente en premier : certaines versions deployees refusent la
    # projection sur preferredDataLocation, auquel cas la ressource complete repond.
    $response = Invoke-CceGraphRequest -Quiet `
        -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,countryLetterCode,preferredDataLocation'

    if ($null -eq $response) { $response = Invoke-CceGraphRequest -Uri 'https://graph.microsoft.com/v1.0/organization' }
    if ($null -eq $response) {
        $Context.Cache['ResidenceOrganization'] = $result
        return $result
    }

    $entry = @(Get-CceResidenceValue -Item $response -Name 'value') | Select-Object -First 1
    if ($null -eq $entry) {
        $Context.Cache['ResidenceOrganization'] = $result
        return $result
    }

    $result.Ok = $true
    $result.Name = Get-CceResidenceText -Item $entry -Name 'displayName'
    $result.Country = Get-CceResidenceText -Item $entry -Name 'countryLetterCode'
    $result.DataLocation = Get-CceResidenceText -Item $entry -Name 'preferredDataLocation'

    $Context.Cache['ResidenceOrganization'] = $result
    $result
}

function Get-CceResidenceCopilotDataLocation {
    <#
    .SYNOPSIS
        Preferred Data Location des utilisateurs porteurs d'une licence Copilot.
    .DESCRIPTION
        La propriete preferredDataLocation n'est retournee que via $select : elle est
        donc demandee explicitement, licence par licence. Ok = $false signifie
        "population non lisible", jamais "aucun utilisateur".
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ResidencePdl')) { return $Context.Cache['ResidencePdl'] }

    $result = [pscustomobject]@{ Ok = $false; Rows = @(); Truncated = $false }

    if (-not $Context.Services.Graph) {
        $Context.Cache['ResidencePdl'] = $result
        return $result
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $ok = $false

    $catalogue = Get-CceResidenceCopilotSku -Context $Context
    if (-not $catalogue.Ok) {
        $Context.Cache['ResidencePdl'] = $result
        return $result
    }

    # Tenant sans abonnement Copilot : population lisible et vide, ce qui n'est pas un echec.
    if (@($catalogue.SkuIds).Count -eq 0) {
        $result.Ok = $true
        $Context.Cache['ResidencePdl'] = $result
        return $result
    }

    foreach ($skuId in @($catalogue.SkuIds)) {
        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=assignedLicenses/any(x:x/skuId eq $skuId)&`$select=userPrincipalName,preferredDataLocation,accountEnabled&`$top=999"
        $page = Get-CceResidenceGraphCollection -Uri $uri
        if (-not $page.Ok) {
            $Context.Cache['ResidencePdl'] = $result
            return $result
        }

        $ok = $true
        if ($page.Truncated) { $result.Truncated = $true }

        foreach ($entry in @($page.Items)) {
            $upn = Get-CceResidenceText -Item $entry -Name 'userPrincipalName'
            if ($upn -eq '') { continue }

            $key = $upn.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $rows.Add([pscustomobject]@{
                Upn      = $upn
                Location = Get-CceResidenceText -Item $entry -Name 'preferredDataLocation'
                Enabled  = Test-CceResidenceFlag -Value (Get-CceResidenceValue -Item $entry -Name 'accountEnabled')
            })
        }
    }

    $result.Ok = $ok
    $result.Rows = @($rows)

    $Context.Cache['ResidencePdl'] = $result
    $result
}

function Invoke-CceCheck74 {
    <#
        Residence des donnees Copilot : geographie effective et Preferred Data Location.

        Le contenu des interactions et l'index semantique associe sont stockes dans la
        geographie du tenant. En Multi-Geo, c'est la Preferred Data Location de
        l'utilisateur qui interroge Copilot qui determine l'emplacement : un PDL vide
        renvoie ses donnees dans la geographie primaire, sans qu'aucune alerte ne le
        signale. Le moteur lit la geographie effective et le PDL de chaque licencie ;
        la formalisation de la geographie attendue reste un acte documentaire.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    # Tout tenant possede au moins un abonnement : une table vide signale un defaut de
    # droits, jamais une organisation sans licence.
    $inventory = Get-CceResidenceServicePlan -Context $Context
    if (-not $inventory.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c74.obs.noskus') `
            -Evidence (T 'c74.ev.noskus') `
            -Remediation (T 'c74.rem.noskus')
    }

    $organization = Get-CceResidenceOrganization -Context $Context
    if (-not $organization.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c74.obs.ne') `
            -Evidence (T 'c74.ev.ne') `
            -Remediation (T 'c74.rem.ne')
    }

    $catalogue = Get-CceResidenceCopilotSku -Context $Context
    if (-not $catalogue.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c74.obs.noskus') `
            -Evidence (T 'c74.ev.noskus') `
            -Remediation (T 'c74.rem.noskus')
    }

    if (@($catalogue.SkuIds).Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c74.na.nosku') -RequiredLicense (T 'c74.na.lic')
    }

    $population = Get-CceResidenceCopilotDataLocation -Context $Context
    if (-not $population.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c74.obs.users.ne') `
            -Evidence (T 'c74.ev.users.ne') `
            -Remediation (T 'c74.rem.users.ne')
    }

    $users = @($population.Rows)
    $placed = @($users | Where-Object { $_.Location -ne '' })
    $missing = @($users | Where-Object { $_.Location -eq '' })

    $hasMultiGeoPlan = Test-CceResidenceCapability -Inventory $inventory -Pattern '*MULTIGEO*'
    $hasAdrPlan = (Test-CceResidenceCapability -Inventory $inventory -Pattern '*ADVANCED_DATA_RESIDENCY*') -or
                  (Test-CceResidenceCapability -Inventory $inventory -Pattern '*ADV_DATA_RES*')

    # Multi-Geo est repute en place des qu'un signal existe : plan de service, PDL de
    # tenant, ou au moins un utilisateur deja place dans une geographie satellite.
    $multiGeo = $hasMultiGeoPlan -or ($organization.DataLocation -ne '') -or ($placed.Count -gt 0)

    $country = if ($organization.Country -ne '') { $organization.Country } else { T 'c74.val.none' }
    $tenantLocation = if ($organization.DataLocation -ne '') { $organization.DataLocation } else { T 'c74.val.none' }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c74.ev.geo') -f $country, $tenantLocation))

    if ($multiGeo) { $evidence.Add(((T 'c74.ev.multigeo') -f $hasMultiGeoPlan, $placed.Count, $users.Count)) }
    else { $evidence.Add(((T 'c74.ev.singlegeo') -f $users.Count)) }

    foreach ($user in ($missing | Select-Object -First $script:CceResidenceEvidenceMax)) {
        $evidence.Add(((T 'c74.ev.pdl.missing') -f $user.Upn, $country))
    }

    foreach ($group in ($placed | Group-Object Location | Sort-Object Count -Descending | Select-Object -First 10)) {
        $evidence.Add(((T 'c74.ev.pdl.line') -f $group.Name, $group.Count))
    }

    if ($hasAdrPlan) { $evidence.Add((T 'c74.ev.adr')) } else { $evidence.Add((T 'c74.ev.adr.none')) }
    if ($population.Truncated) { $evidence.Add((T 'c74.ev.truncated')) }
    $evidence.Add((T 'c74.ev.doc'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 45

    if ($multiGeo -and $missing.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c74.obs.ko') -f $missing.Count, $users.Count, $country) `
            -Evidence $proof `
            -Remediation (T 'c74.rem.ko')
    }

    if ($multiGeo) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c74.obs.ok.multi') -f $users.Count, $tenantLocation) `
            -Evidence $proof
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c74.obs.ok.single') -f $country, $users.Count) `
        -Evidence $proof
}

function Get-CceResidenceOrganizationHold {
    <#
    .SYNOPSIS
        Conservations appliquees a l'echelle de l'organisation.
    .DESCRIPTION
        Une politique de retention couvrant tout Exchange Online n'est pas recopiee dans
        la propriete InPlaceHolds de chaque boite : elle figure au niveau de
        l'organisation, et seules les boites explicitement exclues portent alors un
        identifiant prefixe d'un signe moins. Ignorer cette source produirait un rapport
        declarant non couvertes toutes les boites d'un tenant pourtant sous retention.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ResidenceOrgHolds')) { return $Context.Cache['ResidenceOrgHolds'] }

    $result = [pscustomobject]@{ Ok = $false; Holds = @(); Mailbox = @() }

    if (-not $Context.Services.Exchange) {
        $Context.Cache['ResidenceOrgHolds'] = $result
        return $result
    }

    $org = Get-CceSafe { Get-OrganizationConfig -ErrorAction Stop } -What 'Get-OrganizationConfig (InPlaceHolds)'
    if ($null -eq $org) {
        $Context.Cache['ResidenceOrgHolds'] = $result
        return $result
    }

    $holds = @(Get-CceResidenceList -Value (Get-CceResidenceValue -Item $org -Name 'InPlaceHolds'))

    # Seuls les identifiants portant sur des boites aux lettres sont retenus : les
    # prefixes skp (Skype) et grp (groupes Microsoft 365) couvrent d'autres charges.
    $mailbox = @($holds | Where-Object { $_ -notmatch '^-' -and $_ -notmatch '^(?i)(skp|grp)' })

    $result.Ok = $true
    $result.Holds = $holds
    $result.Mailbox = $mailbox

    $Context.Cache['ResidenceOrgHolds'] = $result
    $result
}

function Get-CceResidenceHoldIndex {
    <#
    .SYNOPSIS
        Index UPN -> etat de conservation, construit en un seul appel.
    .DESCRIPTION
        Reserve aux populations larges : un inventaire complet coute moins qu'une
        resolution unitaire par utilisateur au-dela de quelques centaines de boites.
        Ok = $false signifie "inventaire indisponible", jamais "aucune boite".
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ResidenceHoldIndex')) { return $Context.Cache['ResidenceHoldIndex'] }

    $result = [pscustomobject]@{ Ok = $false; Map = @{} }

    if (-not $Context.Services.Exchange) {
        $Context.Cache['ResidenceHoldIndex'] = $result
        return $result
    }

    $probe = $null

    if (Get-Command -Name 'Get-EXOMailbox' -ErrorAction SilentlyContinue) {
        $probe = Get-CceSafe {
            [pscustomobject]@{
                Rows = @(Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox `
                        -Properties UserPrincipalName, LitigationHoldEnabled, InPlaceHolds, RetentionHoldEnabled `
                        -ErrorAction Stop)
            }
        } -What 'Get-EXOMailbox (conservation)'
    }

    if ($null -eq $probe) {
        $probe = Get-CceSafe {
            [pscustomobject]@{
                Rows = @(Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox -ErrorAction Stop)
            }
        } -What 'Get-Mailbox (conservation)'
    }

    if ($null -eq $probe) {
        $Context.Cache['ResidenceHoldIndex'] = $result
        return $result
    }

    $map = @{}
    foreach ($row in @($probe.Rows)) {
        $upn = Get-CceResidenceText -Item $row -Name 'UserPrincipalName'
        if ($upn -eq '') { continue }
        $map[$upn.ToLowerInvariant()] = $row
    }

    $result.Ok = $true
    $result.Map = $map

    $Context.Cache['ResidenceHoldIndex'] = $result
    $result
}

function ConvertTo-CceResidenceHoldRow {
    <# Etat de conservation d'une boite, ramene aux trois mecanismes qui la couvrent. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Upn,
        $Mailbox,
        $OrganizationHold
    )

    if ($null -eq $Mailbox) {
        return [pscustomobject]@{
            Upn = $Upn; Found = $false; Covered = $false; Litigation = $false
            Holds = @(); Excluded = @(); OrgCovered = $false
        }
    }

    $entries = @(Get-CceResidenceList -Value (Get-CceResidenceValue -Item $Mailbox -Name 'InPlaceHolds'))
    $holds = @($entries | Where-Object { $_ -notmatch '^-' })
    $excluded = @($entries | Where-Object { $_ -match '^-' } | ForEach-Object { $_.Substring(1) })

    $litigation = Test-CceResidenceFlag -Value (Get-CceResidenceValue -Item $Mailbox -Name 'LitigationHoldEnabled')

    # Une politique d'organisation ne couvre la boite que si celle-ci n'en est pas exclue.
    $orgCovered = $false
    foreach ($hold in @($OrganizationHold)) {
        if ($excluded -notcontains $hold) { $orgCovered = $true; break }
    }

    [pscustomobject]@{
        Upn        = $Upn
        Found      = $true
        Covered    = ($litigation -or $holds.Count -gt 0 -or $orgCovered)
        Litigation = $litigation
        Holds      = $holds
        Excluded   = @($excluded)
        OrgCovered = $orgCovered
    }
}

function Invoke-CceCheck75 {
    <#
        Preservation des interactions Copilot au depart d'un collaborateur.

        Les prompts et les reponses sont copies dans un dossier masque de la boite aux
        lettres. A la suppression du compte, ils ne survivent que si la boite devient
        inactive, ce qui suppose une conservation appliquee AVANT la suppression. Ce
        controle verifie la couverture effective des boites licenciees Copilot, la ou
        l'exigence 56 verifie l'existence d'une politique.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }
    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $catalogue = Get-CceResidenceCopilotSku -Context $Context
    if (-not $catalogue.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c75.obs.noskus') `
            -Evidence (T 'c75.ev.noskus') `
            -Remediation (T 'c75.rem.noskus')
    }

    if (@($catalogue.SkuIds).Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c75.na.nosku') -RequiredLicense (T 'c75.na.lic')
    }

    # Population licenciee reprise de la collecte du controle 74 : une seule enumeration
    # Microsoft Graph sert les deux controles, et l'enveloppe distingue une lecture
    # refusee d'un tenant reellement sans siege.
    $population = Get-CceResidenceCopilotDataLocation -Context $Context
    if (-not $population.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c75.obs.users.ne') `
            -Evidence (T 'c75.ev.users.ne') `
            -Remediation (T 'c75.rem.users.ne')
    }

    $users = @($population.Rows | Where-Object { "$($_.Upn)".Trim() -ne '' })
    if ($users.Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c75.na.noseat') -Evidence (T 'c75.ev.noseat')
    }

    $organizationHold = Get-CceResidenceOrganizationHold -Context $Context
    $orgHolds = @($organizationHold.Mailbox)

    $max = [int] ($Context.Config['MailboxLookupMax'] ?? 200)
    $index = $null
    if ($users.Count -gt $max) {
        $probe = Get-CceResidenceHoldIndex -Context $Context
        if ($probe.Ok) { $index = $probe.Map }
    }

    $useExo = [bool] (Get-Command -Name 'Get-EXOMailbox' -ErrorAction SilentlyContinue)
    $lookups = 0
    $rows = [System.Collections.Generic.List[object]]::new()
    $skipped = 0

    foreach ($user in $users) {
        $upn = Get-CceResidenceText -Item $user -Name 'Upn'
        $key = $upn.ToLowerInvariant()
        $mailbox = $null

        if ($null -ne $index) {
            if ($index.ContainsKey($key)) { $mailbox = $index[$key] }
        }
        elseif ($lookups -lt $max) {
            $lookups++

            if ($useExo) {
                $mailbox = Get-CceSafe {
                    Get-EXOMailbox -Identity $upn -Properties UserPrincipalName, LitigationHoldEnabled, InPlaceHolds, RetentionHoldEnabled -ErrorAction Stop
                } -What "Get-EXOMailbox $upn"
            }

            if ($null -eq $mailbox) {
                $mailbox = Get-CceSafe { Get-Mailbox -Identity $upn -ErrorAction Stop } -What "Get-Mailbox $upn"
            }
        }
        else {
            $skipped++
            continue
        }

        $rows.Add((ConvertTo-CceResidenceHoldRow -Upn $upn -Mailbox $mailbox -OrganizationHold $orgHolds))
    }

    $examined = @($rows)
    $resolved = @($examined | Where-Object { $_.Found })

    # Resolution totalement muette : l'absence de boite ne se distingue pas d'un refus
    # de la commande, donc le moteur ne tranche pas.
    if ($null -eq $index -and $examined.Count -gt 0 -and $resolved.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed ((T 'c75.obs.ne') -f $examined.Count) `
            -Evidence (T 'c75.ev.ne') `
            -Remediation (T 'c75.rem.ne')
    }

    $uncovered = @($resolved | Where-Object { -not $_.Covered })
    $covered = @($resolved | Where-Object { $_.Covered })
    $unresolved = @($examined | Where-Object { -not $_.Found })

    $evidence = [System.Collections.Generic.List[string]]::new()

    foreach ($row in ($uncovered | Select-Object -First $script:CceResidenceEvidenceMax)) {
        $evidence.Add(((T 'c75.ev.uncovered') -f $row.Upn, $row.Litigation, $row.Holds.Count))
    }

    foreach ($row in (@($resolved | Where-Object { $_.Excluded.Count -gt 0 }) | Select-Object -First 10)) {
        $evidence.Add(((T 'c75.ev.excluded') -f $row.Upn, ($row.Excluded -join ', ')))
    }

    foreach ($row in ($unresolved | Select-Object -First 10)) {
        $evidence.Add(((T 'c75.ev.unresolved') -f $row.Upn))
    }

    $evidence.Add(((T 'c75.ev.summary') -f $users.Count, $covered.Count, $uncovered.Count, $unresolved.Count))

    if (-not $organizationHold.Ok) { $evidence.Add((T 'c75.ev.orghold.unknown')) }
    elseif ($orgHolds.Count -gt 0) { $evidence.Add(((T 'c75.ev.orghold') -f $orgHolds.Count)) }
    else { $evidence.Add((T 'c75.ev.orghold.none')) }

    if ($skipped -gt 0) { $evidence.Add(((T 'c75.ev.skipped') -f $skipped, $max)) }
    $evidence.Add((T 'c75.ev.note'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 45

    if ($uncovered.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c75.obs.ko') -f $uncovered.Count, $resolved.Count) `
            -Evidence $proof `
            -Remediation (T 'c75.rem.ko')
    }

    if ($unresolved.Count -gt 0 -or $skipped -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c75.obs.warn') -f ($unresolved.Count + $skipped), $users.Count) `
            -Evidence $proof `
            -Remediation (T 'c75.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c75.obs.ok') -f $covered.Count) `
        -Evidence $proof
}

function Invoke-CceCheck76 {
    <#
        Sous-traitants IA tiers : parametre subprocessors et modeles en preversion.

        Le reglage "AI providers operating as Microsoft subprocessors" et son
        sous-parametre "Preview models with Data Retention" ne sont exposes par aucune
        API Graph ni cmdlet publique. Le controle reste donc manuel : il fournit la
        procedure de constat et la decision attendue, sans inventer de verdict. La
        decision porte sur un cadre contractuel, pas sur une valeur technique.
    #>
    [CmdletBinding()] param($Context)

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c76.ev.manual'))
    $evidence.Add((T 'c76.ev.preview'))
    $evidence.Add((T 'c76.ev.region'))
    $evidence.Add((T 'c76.ev.register'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 10

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c76.obs.manual') `
        -Evidence $proof `
        -Remediation (T 'c76.rem.manual')
}

function Invoke-CceCheck77 {
    <#
        Flex routing : frontiere de donnees europeenne et exigences de souverainete.

        Le parametre autorise l'inference des grands modeles de langage hors frontiere
        europeenne pendant les pics de charge. Il est actif par defaut pour les tenants
        eligibles crees apres le 25 mars 2026, et il n'est pas affiche pour les tenants
        ayant achete Multi-Geo. Aucune API ne l'expose : le controle documente la
        procedure et la decision attendue.
    #>
    [CmdletBinding()] param($Context)

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c77.ev.manual'))
    $evidence.Add((T 'c77.ev.default'))
    $evidence.Add((T 'c77.ev.multigeo'))
    $evidence.Add((T 'c77.ev.powerplatform'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 10

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c77.obs.manual') `
        -Evidence $proof `
        -Remediation (T 'c77.rem.manual')
}

function Invoke-CceCheck78 {
    <#
        Mode limite de Copilot dans les reunions Teams.

        Le mode limite empeche Copilot de repondre aux prompts portant sur le ressenti
        et les emotions des participants. La lecture n'existe qu'en permission deleguee
        (CopilotSettings-LimitedMode.Read) : en contexte applicatif, le controle est non
        evalue, ce qui signale un manque de perimetre et non un ecart de configuration.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $response = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/v1.0/copilot/admin/settings/limitedMode'
    if ($null -eq $response) {
        $response = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/beta/copilot/admin/settings/limitedMode'
    }

    if ($null -eq $response) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c78.obs.ne') `
            -Evidence (T 'c78.ev.ne') `
            -Remediation (T 'c78.rem.ne')
    }

    # Une reponse qui ne porte aucune des deux proprietes attendues n'est pas la
    # ressource cherchee : la lire comme "mode limite desactive" serait un faux verdict.
    $hasFlag = Test-CceResidenceProperty -Item $response -Name 'isEnabledForGroup'
    $hasGroup = Test-CceResidenceProperty -Item $response -Name 'groupId'

    if (-not $hasFlag -and -not $hasGroup) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c78.obs.shape') `
            -Evidence (T 'c78.ev.shape') `
            -Remediation (T 'c78.rem.shape')
    }

    $enabled = Test-CceResidenceFlag -Value (Get-CceResidenceValue -Item $response -Name 'isEnabledForGroup')
    $groupId = Get-CceResidenceText -Item $response -Name 'groupId'

    $groupName = ''
    if ($groupId -ne '') {
        $group = Invoke-CceGraphRequest -Quiet -Uri "https://graph.microsoft.com/v1.0/groups/${groupId}?`$select=displayName"
        $groupName = Get-CceResidenceText -Item $group -Name 'displayName'
    }

    $groupLabel = if ($groupName -ne '') { $groupName } elseif ($groupId -ne '') { $groupId } else { T 'c78.val.tenant' }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c78.ev.state') -f $enabled, $groupLabel))
    $evidence.Add((T 'c78.ev.scope'))
    $evidence.Add((T 'c78.ev.social'))
    $evidence.Add((T 'c78.ev.delegated'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 10

    if (-not $enabled) {
        return New-CceResult -Status 'Attention' `
            -Observed (T 'c78.obs.warn') `
            -Evidence $proof `
            -Remediation (T 'c78.rem.warn')
    }

    if ($groupId -eq '') {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c78.obs.ok.tenant') `
            -Evidence $proof
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c78.obs.ok.group') -f $groupLabel) `
        -Evidence $proof
}

function Invoke-CceCheck79 {
    <#
        Programme Frontier : acces aux fonctionnalites Copilot en preversion.

        Le reglage expose le tenant a des preversions : il est donc controlable et note,
        a la difference d'une capacite elle-meme en preversion. Aucune API ne l'expose
        (la ressource beta copilotPolicySetting ne couvre pas Frontier) : le controle
        documente la procedure de constat et la decision attendue.
    #>
    [CmdletBinding()] param($Context)

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c79.ev.manual'))
    $evidence.Add((T 'c79.ev.values'))
    $evidence.Add((T 'c79.ev.risk'))
    $evidence.Add((T 'c79.ev.review'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 10

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c79.obs.manual') `
        -Evidence $proof `
        -Remediation (T 'c79.rem.manual')
}
