#Requires -Version 7.0
<# Controles 52 a 59 - SECURITE ET PROTECTION DES DONNEES #>

# ---------------------------------------------------------------------------
# Referentiel technique du domaine
# ---------------------------------------------------------------------------

# Purview a separe la retention des interactions IA en trois emplacements dedies :
# "Experiences Microsoft 365 Copilot" (application User:M365Copilot), "Applications
# IA d'entreprise" et "Autres applications IA". Ces emplacements ne sont adressables
# que par la famille *-AppRetentionCompliancePolicy : Get-RetentionCompliancePolicy
# ne les retourne jamais, quel que soit l'etat du tenant.
$script:CceSecurityCopilotLocationPattern = 'M365Copilot|MicrosoftCopilot|CopilotExperience'
$script:CceSecurityAiLocationPattern      = 'EnterpriseAIApps|OtherAIApps|EnterpriseAI|CopilotStudio|ChatGPT'

# Ancien emplacement unique "Conversations Teams et interactions Copilot" : encore
# present sur beaucoup de tenants, mais il ne couvre plus les interactions recentes.
$script:CceSecurityLegacyCopilotPattern = 'Copilot|TeamsChat'

# Types d'enregistrement d'audit propres aux interactions IA.
$script:CceSecurityAiRecordTypes = @('CopilotInteraction', 'ConnectedAIAppInteraction', 'AIAppInteraction')

# Depuis le 17 octobre 2023, la retention par defaut d'Audit (Standard) est de
# 180 jours : un seuil a 90 jours declarerait conforme un tenant non configure.
$script:CceSecurityAuditFloorDays = 180

# Durees nommees renvoyees par les strategies de retention, converties en jours.
$script:CceSecurityDurationDays = @{
    'ThreeMonths' = 90;   'SixMonths'  = 180;  'NineMonths' = 270
    'TwelveMonths' = 365; 'OneYear'    = 365;  'TwoYears'   = 730
    'ThreeYears' = 1095;  'FiveYears'  = 1825; 'SevenYears' = 2555
    'TenYears' = 3650
}

# --- Etiquettes chiffrantes et droits d'usage (controle 52) -----------------
# Une application d'IA ne restitue le contenu d'un element chiffre que si l'identite
# appelante detient a la fois VIEW et EXTRACT. Une etiquette configuree pour empecher
# le copier-coller (EXTRACT retire) rend donc tout le corpus ainsi etiquete invisible
# pour Copilot, sans le moindre message d'erreur : l'echec est silencieux.
$script:CceSecurityLabelRequiredRight = @('VIEW', 'EXTRACT')

# OWNER (controle total) porte implicitement l'ensemble des droits d'usage.
$script:CceSecurityLabelOwnerRight = 'OWNER'

# Protection par modele = droits figes dans l'etiquette, donc auditables. Permissions
# definies par l'utilisateur = droits decides au moment de l'application : Copilot ne
# peut pas ouvrir ces elements hors SharePoint et OneDrive.
$script:CceSecurityLabelUserDefinedPattern = 'UserDefined|UserDefinedProtection|DoNotForward|EncryptOnly'

# --- Emplacement DLP Microsoft 365 Copilot (controle 55) --------------------
# Cinquieme emplacement de strategie DLP, distinct des quatre charges de travail
# historiques : il est le seul mecanisme qui separe le droit d'ACCES de l'utilisateur
# du droit d'EXPLOITATION du contenu par l'IA.
$script:CceSecurityDlpCopilotLocationId = '470f2276-e011-4e9d-a6ec-20768be3a4b0'
$script:CceSecurityDlpCopilotPattern = 'CopilotExperiences|M365Copilot|MicrosoftCopilot|CopilotChat'

# Action documentee sur cet emplacement : RestrictAccess / ExcludeContentProcessing.
$script:CceSecurityDlpBlockPattern = 'ExcludeContentProcessing'

# Condition attendue : "Le contenu contient > Etiquettes de confidentialite".
$script:CceSecurityDlpLabelPattern = 'SensitivityLabel|ContentContainsSensitiveInformation|SensitiveInformationType|labels'

# Les quatre charges de travail historiques restent exigees : l'emplacement Copilot
# s'y ajoute, il ne s'y substitue pas.
$script:CceSecurityDlpWorkload = @('Exchange', 'SharePoint', 'OneDrive', 'Teams')

# Plafonds d'exploration : le controle garde un cout constant sur un grand tenant.
$script:CceSecurityDlpMaxRule = 200
$script:CceSecurityDlpMaxDetail = 8

# Profondeur maximale d'aplatissement d'un objet de service : au-dela, la structure
# ne porte plus d'information de perimetre et le cout deviendrait imprevisible.
$script:CceSecurityDeepTextMaxDepth = 4

# --- DSPM for AI (controle 66) ----------------------------------------------
# Les strategies deployees en un clic depuis Data Security Posture Management for AI
# portent des noms normalises par le service : ils sont donc detectables par script.
$script:CceSecurityDspmPolicyPattern = 'DSPM for AI|Microsoft AI Hub|AI Hub'

# Familles de strategies par defaut, reconnues par motif sur le nom normalise.
$script:CceSecurityDspmFamilyPattern = [ordered]@{
    'risky'     = 'risky AI usage|risky AI app|risky AI'
    'unethical' = 'Unethical behavior|Unethical behaviour'
    'capture'   = 'Capture interactions'
    'protect'   = 'Protect sensitive'
}

# Les trois premieres sont exigees ; "protect" recouvre l'emplacement DLP du controle 55.
$script:CceSecurityDspmRequiredFamily = @('risky', 'unethical', 'capture')

# Insider Risk Management et Conformite des communications sont portes par les
# references E5 ou par les modules complementaires Purview : sans eux, la capacite
# n'est pas detenue par le tenant et l'exigence sort du score.
$script:CceSecurityDspmSkuPattern = 'ENTERPRISEPREMIUM|SPE_E5|SPE_F5|M365_E5|M365_G5|M365_F5|INFORMATION_PROTECTION_COMPLIANCE|IDENTITY_THREAT_PROTECTION|INSIDER_RISK|PURVIEW'
$script:CceSecurityDspmPlanPattern = 'INSIDER_RISK|COMMUNICATIONS_COMPLIANCE|COMMUNICATION_COMPLIANCE|MICROSOFT_COMMUNICATION_COMPLIANCE|INFORMATION_BARRIERS|RECORDS_MANAGEMENT|PURVIEW_DISCOVERY'

# --- eDiscovery sur les donnees Copilot (controle 58) -----------------------
# L'API v1.0 /security/cases/ediscoveryCases n'est servie qu'aux tenants dotes de
# eDiscovery (Premium) : le code de statut de la reponse porte a lui seul une part
# du diagnostic (200 = licence + role effectifs, 403 = l'un des deux manque).
$script:CceSecurityEdiscoveryUri = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases'

# Groupe de roles Purview qui ouvre l'acces aux cas : son identite n'est pas localisee.
$script:CceSecurityEdiscoveryRoleGroup = 'eDiscovery Manager'
$script:CceSecurityEdiscoveryRolePattern = 'eDiscovery'

# Marqueurs documentes d'une recherche portant sur les interactions Copilot :
# condition ItemClass IPM.SkypeTeams.Message.Copilot.* ou filtre Type > Copilot activity.
$script:CceSecurityCopilotQueryPattern = 'IPM\.SkypeTeams\.Message\.Copilot|Copilot\s+activity|itemclass\s*[:=]\s*\S*copilot'

# Plans de service et references d'abonnement porteurs de eDiscovery (Premium).
# Le filet est volontairement large : conclure a tort "licence absente" retirerait
# l'exigence du score, conclure a tort "licence presente" ne fait que preciser un motif.
$script:CceSecurityEdiscoveryPlanPattern = 'EQUIVIO|EDISCOVERY|PURVIEW_DISCOVERY'
$script:CceSecurityEdiscoverySkuPattern = 'ENTERPRISEPREMIUM|SPE_E5|SPE_F5|M365_E5|M365_G5|INFORMATION_PROTECTION_COMPLIANCE|EQUIVIO|EDISCOVERY'

# Plafonds d'exploration : le controle garde un cout constant sur un grand tenant.
$script:CceSecurityEdiscoveryMaxPage = 5
$script:CceSecurityEdiscoveryMaxDetail = 5

# Proprietes purement descriptives : les ecarter de la recherche d'emplacement evite
# qu'un simple nom de strategie ("Retention-M365Copilot") soit pris pour un perimetre.
$script:CceSecurityScopeIgnoredProperty = @(
    'Name', 'Comment', 'Description', 'DisplayName', 'Identity', 'DistinguishedName',
    'Guid', 'ObjectId', 'ExchangeObjectId', 'ImmutableId', 'OrganizationId',
    'OrganizationalUnitRoot', 'RunspaceId', 'PSComputerName', 'PSShowComputerName',
    'CreatedBy', 'LastModifiedBy'
)

function Get-CceSecurityValue {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete : absente, nulle ou illisible -> valeur de repli.
    .DESCRIPTION
        Le moteur s'execute sous Set-StrictMode : une propriete absente sur un objet
        renvoye par un service leverait une exception. Ce helper la neutralise.
    #>
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory)] [string] $Name, $Default = $null)

    if ($null -eq $InputObject) { return $Default }

    try {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) { return $Default }
        $property.Value
    }
    catch { $Default }
}

function Get-CceSecurityScopeText {
    <#
    .SYNOPSIS
        Aplatit les proprietes de perimetre d'une strategie en une chaine unique.
    .DESCRIPTION
        Le nom exact de la propriete portant les emplacements varie selon la version
        du module ; on parcourt donc toutes les proprietes hors champs descriptifs.
    #>
    [CmdletBinding()] param($InputObject)

    if ($null -eq $InputObject) { return '' }

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($property in $InputObject.PSObject.Properties) {
        if ($script:CceSecurityScopeIgnoredProperty -contains $property.Name) { continue }

        try {
            $value = $property.Value
            if ($null -eq $value) { continue }

            if ($value -is [string]) { $parts.Add($value) }
            elseif ($value -is [System.Collections.IEnumerable]) {
                foreach ($entry in $value) { if ($null -ne $entry) { $parts.Add("$entry") } }
            }
            else { $parts.Add("$value") }
        }
        catch { continue }
    }

    $parts -join ' '
}

function Test-CceSecurityLegacyRetention {
    <#
    .SYNOPSIS
        Vraie si une strategie de retention classique cible l'ancien emplacement Teams/Copilot.
    #>
    [CmdletBinding()] param($Policy)

    $locations = @(Get-CceSecurityValue -InputObject $Policy -Name 'TeamsChatLocation' -Default @())
    if ($locations.Count -gt 0) { return $true }

    "$(Get-CceSecurityValue -InputObject $Policy -Name 'Workload' -Default '')" -match $script:CceSecurityLegacyCopilotPattern
}

function Get-CceSecurityRetentionDay {
    <#
    .SYNOPSIS
        Convertit une duree de retention (nom symbolique, nombre de jours, illimitee) en jours.
    .DESCRIPTION
        Renvoie $null lorsque la valeur n'est pas interpretable : l'appelant accorde
        alors le benefice du doute plutot que de prononcer un ecart infonde.
    #>
    [CmdletBinding()] param([string] $Duration)

    if ([string]::IsNullOrWhiteSpace($Duration)) { return $null }
    if ($Duration -match 'Unlimited|Infinite') { return [int]::MaxValue }
    if ($script:CceSecurityDurationDays.ContainsKey($Duration)) { return $script:CceSecurityDurationDays[$Duration] }

    $parsed = 0
    if ([int]::TryParse($Duration, [ref] $parsed)) { return $parsed }

    $null
}

function Get-CceSecurityRetentionText {
    <#
    .SYNOPSIS
        Libelle localise d'une duree de retention exprimee en jours.
    #>
    [CmdletBinding()] param($Days)

    if ($null -eq $Days) { return T 'c56.ev.nodur' }
    if ($Days -ge [int]::MaxValue) { return T 'c56.ev.unlimited' }

    (T 'c56.ev.days') -f $Days
}

function Get-CceSecurityDeepText {
    <#
    .SYNOPSIS
        Aplatit un objet de service en texte, dictionnaires et collections imbriques compris.
    .DESCRIPTION
        Get-CceSecurityScopeText suffit pour des proprietes plates. Les strategies DLP
        exposent au contraire des structures imbriquees (RestrictAccess, EnforcementPlanes,
        AdvancedRule) dont la simple conversion en chaine donnerait "System.Collections.Hashtable"
        et masquerait le perimetre reel. Seules les VALEURS sont conservees : retenir les noms
        de proprietes ferait passer un intitule technique pour un emplacement configure.
        La profondeur est bornee : le cout du controle ne doit pas dependre de la forme
        exacte des objets renvoyes par le service.
    #>
    [CmdletBinding()]
    param($InputObject, [int] $Depth = 0)

    if ($null -eq $InputObject -or $Depth -gt $script:CceSecurityDeepTextMaxDepth) { return '' }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [ValueType]) { return "$InputObject" }

    $parts = [System.Collections.Generic.List[string]]::new()

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            try { $parts.Add((Get-CceSecurityDeepText -InputObject $InputObject[$key] -Depth ($Depth + 1))) } catch { continue }
        }
        return ($parts -join ' ')
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        foreach ($entry in $InputObject) {
            try { $parts.Add((Get-CceSecurityDeepText -InputObject $entry -Depth ($Depth + 1))) } catch { continue }
        }
        return ($parts -join ' ')
    }

    try {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($script:CceSecurityScopeIgnoredProperty -contains $property.Name) { continue }
            try { $parts.Add((Get-CceSecurityDeepText -InputObject $property.Value -Depth ($Depth + 1))) } catch { continue }
        }
    }
    catch { return "$InputObject" }

    if ($parts.Count -eq 0) { return "$InputObject" }
    ($parts -join ' ')
}

function Get-CceSecurityRightsEntry {
    <#
    .SYNOPSIS
        Normalise EncryptionRightsDefinitions en couples identite / droits d'usage.
    .DESCRIPTION
        La propriete est exposee tantot comme une chaine "identite:DROIT1,DROIT2",
        tantot comme une collection d'objets porteurs de Identity et Rights. Les deux
        formes sont acceptees : une lecture qui echouerait sur la forme produirait un
        faux ecart sur une exigence Bloquante.
    #>
    [CmdletBinding()]
    param($Definition)

    $entries = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Definition) { return $entries }

    $items = if ($Definition -is [string]) { @($Definition) }
    elseif ($Definition -is [System.Collections.IEnumerable]) { @($Definition) }
    else { @($Definition) }

    foreach ($item in $items) {
        if ($null -eq $item) { continue }

        $identity = "$(Get-CceSecurityValue -InputObject $item -Name 'Identity' -Default '')"
        $rightsRaw = Get-CceSecurityValue -InputObject $item -Name 'Rights'
        $rightsText = ''

        if ($null -ne $rightsRaw) {
            $rightsText = if ($rightsRaw -is [string]) { $rightsRaw } else { (@($rightsRaw) | ForEach-Object { "$_" }) -join ',' }
        }

        if (-not $identity -and -not $rightsText) {
            # Forme textuelle "identite:DROITS" : le premier deux-points separe les deux.
            $text = "$item"
            if (-not $text) { continue }

            $split = $text -split ':', 2
            if ($split.Count -eq 2) { $identity = $split[0].Trim(); $rightsText = $split[1] }
            else { $rightsText = $text }
        }

        $rights = @($rightsText -split '[,;\s]+' | ForEach-Object { "$_".Trim().ToUpperInvariant() } | Where-Object { $_ })
        if ($rights.Count -eq 0) { continue }

        $entries.Add([pscustomobject]@{ Identity = $identity; Rights = $rights })
    }

    $entries
}

function Test-CceSecurityRightGrant {
    <#
    .SYNOPSIS
        Vraie si le jeu de droits permet a Copilot de restituer le contenu chiffre.
    .DESCRIPTION
        VIEW seul ne suffit pas : Microsoft exige EXTRACT (copie) pour qu'une application
        d'IA puisse retourner le contenu d'un element protege. OWNER porte tous les droits.
    #>
    [CmdletBinding()]
    param([string[]] $Rights)

    $granted = @(@($Rights) | ForEach-Object { "$_".Trim().ToUpperInvariant() } | Where-Object { $_ })
    if ($granted -contains $script:CceSecurityLabelOwnerRight) { return $true }

    foreach ($required in $script:CceSecurityLabelRequiredRight) {
        if ($granted -notcontains $required) { return $false }
    }

    $true
}

function Get-CceSecurityDlpPolicy {
    <#
    .SYNOPSIS
        Inventaire des strategies DLP, lu une seule fois par execution.
    .DESCRIPTION
        Renvoie $null lorsque la lecture est impossible : la difference entre "aucune
        strategie" et "inventaire illisible" doit rester visible jusqu'au verdict.
    #>
    [CmdletBinding()] param($Context)

    # La virgule est indispensable : une collection vide renvoyee sans elle serait
    # deroulee a la sortie de la fonction et parviendrait a l'appelant sous la forme
    # $null, transformant "aucune strategie" en "inventaire illisible".
    if ($Context.Cache.ContainsKey('DlpCompliancePolicies')) { return , $Context.Cache['DlpCompliancePolicies'] }

    $policies = Get-CceSafe { , @(Get-DlpCompliancePolicy -ErrorAction Stop) } -What 'Get-DlpCompliancePolicy'
    $Context.Cache['DlpCompliancePolicies'] = $policies
    , $policies
}

function Get-CceSecurityDlpRule {
    <# Inventaire des regles DLP, lu une seule fois par execution. #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('DlpComplianceRules')) { return , $Context.Cache['DlpComplianceRules'] }

    $rules = Get-CceSafe { , @(Get-DlpComplianceRule -ErrorAction Stop) } -What 'Get-DlpComplianceRule'
    $Context.Cache['DlpComplianceRules'] = $rules
    , $rules
}

function Test-CceSecurityDlpCopilotScope {
    <#
    .SYNOPSIS
        Vraie si la strategie DLP porte l'emplacement Microsoft 365 Copilot.
    .DESCRIPTION
        Deux marqueurs equivalents : le plan d'application CopilotExperiences et le GUID
        d'emplacement documente. Le nom et le commentaire de la strategie sont ecartes de
        l'analyse : une strategie appelee "DLP-Copilot" ne prouve rien sur son perimetre.
    #>
    [CmdletBinding()] param($Policy)

    $text = Get-CceSecurityDeepText -InputObject $Policy
    if (-not $text) { return $false }

    ($text -match $script:CceSecurityDlpCopilotPattern) -or ($text -match [regex]::Escape($script:CceSecurityDlpCopilotLocationId))
}

function Get-CceSecurityDlpCopilotRule {
    <#
    .SYNOPSIS
        Regles rattachees aux strategies portant l'emplacement Copilot.
    .DESCRIPTION
        Deux mesures distinctes : la regle bloque-t-elle reellement le traitement du
        contenu (RestrictAccess / ExcludeContentProcessing), et s'appuie-t-elle sur une
        condition d'etiquette de confidentialite. Un inventaire illisible n'est jamais
        converti en ecart : il est signale comme tel.
    #>
    [CmdletBinding()] param($Context, $Policy)

    $result = [pscustomobject]@{ Readable = $false; Total = 0; Blocking = @(); Labelled = @() }

    $names = @(@($Policy) |
        ForEach-Object { "$(Get-CceSecurityValue -InputObject $_ -Name 'Name' -Default '')" } |
        Where-Object { $_ })
    if ($names.Count -eq 0) { return $result }

    $rules = Get-CceSecurityDlpRule -Context $Context
    if ($null -eq $rules) { return $result }

    $result.Readable = $true

    $candidates = @(@($rules) | Where-Object {
        $parent = "$(Get-CceSecurityValue -InputObject $_ -Name 'ParentPolicyName' -Default '')"
        if (-not $parent) { $parent = "$(Get-CceSecurityValue -InputObject $_ -Name 'Policy' -Default '')" }
        $parent -and ($names -contains $parent)
    } | Select-Object -First $script:CceSecurityDlpMaxRule)

    $result.Total = $candidates.Count

    $blocking = [System.Collections.Generic.List[string]]::new()
    $labelled = [System.Collections.Generic.List[string]]::new()

    foreach ($rule in $candidates) {
        if ("$(Get-CceSecurityValue -InputObject $rule -Name 'Disabled' -Default $false)" -eq 'True') { continue }

        $name = "$(Get-CceSecurityValue -InputObject $rule -Name 'Name' -Default '')"
        $text = Get-CceSecurityDeepText -InputObject $rule

        if ($text -match $script:CceSecurityDlpBlockPattern) { $blocking.Add($name) }
        if ($text -match $script:CceSecurityDlpLabelPattern) { $labelled.Add($name) }
    }

    $result.Blocking = @($blocking)
    $result.Labelled = @($labelled)
    $result
}

function Test-CceSecurityPolicyActive {
    <#
    .SYNOPSIS
        Vraie si une strategie de conformite est reellement en application.
    .DESCRIPTION
        Les familles de strategies Purview n'exposent pas le meme etat : Enabled pour les
        unes, Mode pour les autres, Status pour Insider Risk. Une propriete absente vaut
        "active" : le moteur ne prononce un ecart que sur une valeur qu'il a su lire.
    #>
    [CmdletBinding()] param($Policy)

    if ("$(Get-CceSecurityValue -InputObject $Policy -Name 'Enabled' -Default $true)" -eq 'False') { return $false }
    if ("$(Get-CceSecurityValue -InputObject $Policy -Name 'Mode' -Default 'Enable')" -match 'Disable|PendingDeletion') { return $false }
    if ("$(Get-CceSecurityValue -InputObject $Policy -Name 'Status' -Default '')" -match 'Disabled|Inactive|Draft') { return $false }

    $true
}

function Test-CceSecurityDspmEntitlement {
    <#
    .SYNOPSIS
        Vraie si un abonnement du tenant porte Insider Risk Management ou Purview E5.
    .DESCRIPTION
        Sert uniquement a qualifier une absence : sans la capacite, les strategies par
        defaut DSPM for AI ne peuvent pas exister et l'exigence sort du score. Une
        detection positive de strategie prime toujours sur ce test.
    #>
    [CmdletBinding()] param($Context)

    foreach ($sku in @(Get-CceSubscribedSku -Context $Context)) {
        $part = "$(Get-CceSecurityValue -InputObject $sku -Name 'SkuPartNumber' -Default '')"
        if ($part -match $script:CceSecurityDspmSkuPattern) { return $true }

        foreach ($plan in @(Get-CceSecurityValue -InputObject $sku -Name 'ServicePlans' -Default @())) {
            $name = "$(Get-CceSecurityValue -InputObject $plan -Name 'ServicePlanName' -Default '')"
            $state = "$(Get-CceSecurityValue -InputObject $plan -Name 'ProvisioningStatus' -Default '')"
            if ($name -match $script:CceSecurityDspmPlanPattern -and $state -notmatch 'Disabled') { return $true }
        }
    }

    $false
}

function Get-CceSecurityDspmFamilyLabel {
    <# Libelle localise d'une famille de strategie par defaut DSPM for AI. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Family)

    switch ($Family) {
        'risky'     { T 'c66.fam.risky' }
        'unethical' { T 'c66.fam.unethical' }
        'capture'   { T 'c66.fam.capture' }
        'protect'   { T 'c66.fam.protect' }
        default     { $Family }
    }
}

function Invoke-CceCheck52 {
    <#
        Etiquettes de confidentialite : socle de trois niveaux ET droits d'usage.
        Le comptage seul laissait passer l'erreur la plus silencieuse d'un deploiement
        Copilot. Microsoft exige que l'identite dispose de VIEW et de EXTRACT pour qu'une
        application d'IA restitue le contenu d'un element chiffre : une etiquette
        "Confidentiel" configuree pour interdire le copier-coller rend tout le corpus
        ainsi etiquete invisible pour Copilot, sans aucun message d'erreur. Les etiquettes
        en permissions definies par l'utilisateur sont signalees pour la meme raison.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    # La virgule preserve la difference entre "aucune etiquette" et "lecture impossible".
    $labels = Get-CceSafe { , @(Get-Label -ErrorAction Stop) } -What 'Get-Label'
    if ($null -eq $labels) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $all = @($labels)
    $active = @($all | Where-Object { "$(Get-CceSecurityValue -InputObject $_ -Name 'Disabled' -Default $false)" -ne 'True' })

    $lines = [System.Collections.Generic.List[string]]::new()
    $blocking = [System.Collections.Generic.List[string]]::new()
    $partial = [System.Collections.Generic.List[string]]::new()
    $userDefined = [System.Collections.Generic.List[string]]::new()
    $unreadable = [System.Collections.Generic.List[string]]::new()
    $encrypting = 0

    foreach ($label in ($active | Sort-Object Priority)) {
        $priority = "$(Get-CceSecurityValue -InputObject $label -Name 'Priority' -Default '')"
        $name = "$(Get-CceSecurityValue -InputObject $label -Name 'DisplayName' -Default '')"
        if (-not $name) { $name = "$(Get-CceSecurityValue -InputObject $label -Name 'Name' -Default '')" }

        if ("$(Get-CceSecurityValue -InputObject $label -Name 'EncryptionEnabled' -Default $false)" -ne 'True') {
            $line = (T 'c52.ev.line') -f $priority, $name
            $lines.Add($line)
            continue
        }

        $encrypting++
        $protection = "$(Get-CceSecurityValue -InputObject $label -Name 'EncryptionProtectionType' -Default '')"

        if ($protection -match $script:CceSecurityLabelUserDefinedPattern) {
            $userDefined.Add($name)
            $line = (T 'c52.ev.userdefined') -f $priority, $name, $protection
            $lines.Add($line)
            continue
        }

        $entries = @(Get-CceSecurityRightsEntry -Definition (Get-CceSecurityValue -InputObject $label -Name 'EncryptionRightsDefinitions'))

        if ($entries.Count -eq 0) {
            $unreadable.Add($name)
            $line = (T 'c52.ev.norights') -f $priority, $name, $protection
            $lines.Add($line)
            continue
        }

        $rightsText = (@($entries | ForEach-Object {
            $entryLine = (T 'c52.ev.rights') -f $_.Identity, (@($_.Rights) -join ',')
            $entryLine
        }) -join ' | ')

        $granting = @($entries | Where-Object { Test-CceSecurityRightGrant -Rights $_.Rights })
        $denied = @($entries | Where-Object { -not (Test-CceSecurityRightGrant -Rights $_.Rights) } |
            ForEach-Object { if ($_.Identity) { $_.Identity } else { (@($_.Rights) -join ',') } })

        if ($granting.Count -eq 0) {
            $blocking.Add($name)
            $line = (T 'c52.ev.missing') -f $priority, $name, ($script:CceSecurityLabelRequiredRight -join ', '), $rightsText
            $lines.Add($line)
            continue
        }

        if ($denied.Count -gt 0) {
            $partial.Add($name)
            $line = (T 'c52.ev.partial') -f $priority, $name, (@($denied) -join ', '), $rightsText
            $lines.Add($line)
            continue
        }

        $line = (T 'c52.ev.enc') -f $priority, $name, $protection, $rightsText
        $lines.Add($line)
    }

    $evidence = $lines | ConvertTo-CceText

    if ($active.Count -lt 3) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c52.obs.main') -f $active.Count, $all.Count) `
            -Evidence $evidence `
            -Remediation (T 'c52.rem.ko')
    }

    if ($blocking.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c52.obs.noextract') -f $active.Count, $blocking.Count) `
            -Evidence $evidence `
            -Remediation ((T 'c52.rem.noextract') -f (@($blocking) -join ', '))
    }

    if ($partial.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c52.obs.partial') -f $active.Count, $partial.Count) `
            -Evidence $evidence `
            -Remediation ((T 'c52.rem.partial') -f (@($partial) -join ', '))
    }

    if ($unreadable.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c52.obs.unreadable') -f $active.Count, $unreadable.Count) `
            -Evidence $evidence `
            -Remediation ((T 'c52.rem.unreadable') -f (@($unreadable) -join ', '))
    }

    if ($userDefined.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c52.obs.userdefined') -f $active.Count, $userDefined.Count) `
            -Evidence $evidence `
            -Remediation ((T 'c52.rem.userdefined') -f (@($userDefined) -join ', '))
    }

    if ($encrypting -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c52.obs.noenc') -f $active.Count, $all.Count) `
            -Evidence $evidence `
            -Remediation (T 'c52.rem.noenc')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c52.obs.ok') -f $active.Count, $encrypting) `
        -Evidence $evidence
}

function Invoke-CceCheck53 {
    <# Publier les labels vers les utilisateurs Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSafe { Get-LabelPolicy -ErrorAction Stop } -What 'Get-LabelPolicy'
    if ($null -eq $policies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $count = @($policies).Count

    if ($count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c53.obs.none') `
            -Evidence (T 'c53.ev.none') `
            -Remediation (T 'c53.rem.none')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c53.obs.ok') -f $count) `
        -Evidence ($policies | ForEach-Object { (T 'c53.ev.line') -f $_.Name, (@($_.Labels) -join ', ') } | ConvertTo-CceText)
}

function Invoke-CceCheck54 {
    <# Activer l'auto-labeling pour les nouveaux fichiers #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSafe { Get-AutoSensitivityLabelPolicy -ErrorAction Stop } -What 'Get-AutoSensitivityLabelPolicy'
    if ($null -eq $policies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $usable = @($policies | Where-Object { "$($_.Mode)" -notmatch 'PendingDeletion' })

    if ($usable.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c54.obs.none') `
            -Evidence (T 'c54.ev.none') `
            -Remediation (T 'c54.rem.none')
    }

    $enforcing = @($usable | Where-Object { "$($_.Mode)" -match 'Enable' })
    $status = if ($enforcing.Count -gt 0) { 'Conforme' } else { 'Attention' }

    New-CceResult -Status $status `
        -Observed ((T 'c54.obs.main') -f $usable.Count, $enforcing.Count) `
        -Evidence ($usable | ForEach-Object { (T 'c54.ev.line') -f $_.Name, $_.Mode } | ConvertTo-CceText) `
        -Remediation $(if ($status -eq 'Conforme') { '' } else { (T 'c54.rem.warn') })
}

function Invoke-CceCheck55 {
    <#
        Strategies DLP : les quatre charges de travail historiques ET l'emplacement
        "Microsoft 365 Copilot et Copilot Chat".
        Cet emplacement est le seul mecanisme qui separe le droit d'ACCES de l'utilisateur
        du droit d'EXPLOITATION du contenu par l'IA : l'element reste accessible et peut
        apparaitre en citation, mais son contenu n'est ni lu ni resume par Copilot.
        Sans lui, un document etiquete "Tres confidentiel" dont les permissions sont trop
        larges est resume mot pour mot des la premiere requete.
        Le delai de prise en compte d'une modification atteint 4 heures cote service.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSecurityDlpPolicy -Context $Context
    if ($null -eq $policies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $all = @($policies)
    $enabled = @($all | Where-Object {
        ("$(Get-CceSecurityValue -InputObject $_ -Name 'Enabled' -Default $true)" -ne 'False') -and
        ("$(Get-CceSecurityValue -InputObject $_ -Name 'Mode' -Default 'Enable')" -notmatch 'Disable')
    })

    if ($enabled.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c55.obs.none') `
            -Evidence ((T 'c55.ev.none') -f $all.Count) `
            -Remediation (T 'c55.rem.none')
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($policy in $enabled) {
        $line = (T 'c55.ev.line') -f "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')", "$(Get-CceSecurityValue -InputObject $policy -Name 'Mode' -Default '')", "$(Get-CceSecurityValue -InputObject $policy -Name 'Workload' -Default '')"
        $lines.Add($line)
    }

    $covered = @()
    foreach ($workload in $script:CceSecurityDlpWorkload) {
        if (@($enabled | Where-Object { "$(Get-CceSecurityValue -InputObject $_ -Name 'Workload' -Default '')" -match $workload }).Count -gt 0) { $covered += $workload }
    }
    $missing = @($script:CceSecurityDlpWorkload | Where-Object { $_ -notin $covered })

    # --- Emplacement Microsoft 365 Copilot -----------------------------------
    $copilot = @($enabled | Where-Object { Test-CceSecurityDlpCopilotScope -Policy $_ })
    $copilotActive = @($copilot | Where-Object { "$(Get-CceSecurityValue -InputObject $_ -Name 'Mode' -Default 'Enable')" -match '^Enable' })

    if ($copilot.Count -eq 0) {
        $line = (T 'c55.ev.copilotnone') -f $enabled.Count, $script:CceSecurityDlpCopilotLocationId
        $lines.Add($line)

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c55.obs.nocopilot') -f $enabled.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c55.rem.nocopilot')
    }

    foreach ($policy in ($copilot | Select-Object -First $script:CceSecurityDlpMaxDetail)) {
        $line = (T 'c55.ev.copilot') -f "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')", "$(Get-CceSecurityValue -InputObject $policy -Name 'Mode' -Default '')"
        $lines.Add($line)
    }

    if ($copilotActive.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c55.obs.copilotsim') -f $copilot.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c55.rem.copilotsim')
    }

    $ruleInfo = Get-CceSecurityDlpCopilotRule -Context $Context -Policy $copilotActive
    $blockingCount = @($ruleInfo.Blocking).Count

    if (-not $ruleInfo.Readable) {
        # Inventaire des regles illisible : le constat ne doit pas se lire comme une absence.
        $lines.Add((T 'c55.ev.copilotunread'))
    }
    else {
        if ($blockingCount -eq 0) {
            $line = (T 'c55.ev.copilotnorule') -f $ruleInfo.Total
            $lines.Add($line)

            return New-CceResult -Status 'Attention' `
                -Observed ((T 'c55.obs.copilotnorule') -f $copilotActive.Count) `
                -Evidence ($lines | ConvertTo-CceText) `
                -Remediation (T 'c55.rem.copilotnorule')
        }

        $line = (T 'c55.ev.copilotrule') -f ((@($ruleInfo.Blocking) | Select-Object -First $script:CceSecurityDlpMaxDetail) -join ', ')
        $lines.Add($line)

        if (@($ruleInfo.Labelled).Count -eq 0) { $lines.Add((T 'c55.ev.copilotnolabel')) }
    }

    if ($missing.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c55.obs.partial') -f $enabled.Count, ($missing -join ', ')) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation ((T 'c55.rem.partial') -f ($missing -join ', '))
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c55.obs.ok') -f $enabled.Count, $copilotActive.Count, $blockingCount) `
        -Evidence ($lines | ConvertTo-CceText)
}

function Invoke-CceCheck56 {
    <#
        Retention des interactions Copilot.
        Les emplacements IA (Experiences Microsoft 365 Copilot, Applications IA
        d'entreprise, Autres applications IA) ne sont exposes que par la famille
        *-AppRetentionCompliancePolicy. L'ancienne strategie "Conversations Teams
        et interactions Copilot" est encore detectee, mais signalee comme heritee.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    # Source de verite. La virgule preserve la difference entre "aucune strategie"
    # (collection vide) et "requete impossible" ($null).
    $appPolicies = Get-CceSafe { , @(Get-AppRetentionCompliancePolicy -ErrorAction Stop) } -What 'Get-AppRetentionCompliancePolicy'
    if ($null -eq $appPolicies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    # L'affectation passe par une variable : @(appel) reemballerait la collection
    # renvoyee et masquerait les strategies derriere un tableau imbrique.
    $legacyResult = Get-CceSafe { , @(Get-RetentionCompliancePolicy -ErrorAction Stop) } -What 'Get-RetentionCompliancePolicy'
    $legacyPolicies = if ($null -eq $legacyResult) { @() } else { @($legacyResult) }
    $inherited = @($legacyPolicies | Where-Object { Test-CceSecurityLegacyRetention -Policy $_ })

    $detail = [System.Collections.Generic.List[object]]::new()
    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($policy in @($appPolicies)) {
        $scope = Get-CceSecurityScopeText -InputObject $policy
        if ($scope -notmatch $script:CceSecurityCopilotLocationPattern) { continue }

        $policyName = "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')"
        $enabled = "$(Get-CceSecurityValue -InputObject $policy -Name 'Enabled' -Default $true)"
        $mode = "$(Get-CceSecurityValue -InputObject $policy -Name 'Mode' -Default 'Enable')"

        $markers = @([regex]::Matches($scope, "$($script:CceSecurityCopilotLocationPattern)|$($script:CceSecurityAiLocationPattern)") |
            ForEach-Object { $_.Value } | Sort-Object -Unique)

        # La duree n'est portee que par la regle associee, jamais par la strategie.
        $rules = Get-CceSafe { , @(Get-AppRetentionComplianceRule -Policy $policyName -ErrorAction Stop) } -What 'Get-AppRetentionComplianceRule'

        $days = $null
        foreach ($rule in @($rules)) {
            $raw = "$(Get-CceSecurityValue -InputObject $rule -Name 'RetentionDuration' -Default '')"
            $value = Get-CceSecurityRetentionDay -Duration $raw
            if ($null -ne $value -and ($null -eq $days -or $value -gt $days)) { $days = $value }
        }

        $line = (T 'c56.ev.app') -f $policyName, $enabled, $mode, ($markers -join ', '), (Get-CceSecurityRetentionText -Days $days)
        $lines.Add($line)

        $detail.Add([pscustomobject]@{
            Name   = $policyName
            Active = (($enabled -ne 'False') -and ($mode -match 'Enable'))
            Days   = $days
        })
    }

    foreach ($policy in $inherited) {
        $line = (T 'c56.ev.line') -f "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')", "$(Get-CceSecurityValue -InputObject $policy -Name 'Enabled' -Default '')", "$(Get-CceSecurityValue -InputObject $policy -Name 'Workload' -Default '')"
        $lines.Add($line)
    }

    if ($detail.Count -eq 0) {
        if ($inherited.Count -gt 0) {
            return New-CceResult -Status 'Attention' `
                -Observed ((T 'c56.obs.legacy') -f $inherited.Count) `
                -Evidence ($lines | ConvertTo-CceText) `
                -Remediation (T 'c56.rem.legacy')
        }

        $all = @($appPolicies) + $legacyPolicies
        foreach ($policy in $all) {
            $line = (T 'c56.ev.lineall') -f "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')", "$(Get-CceSecurityValue -InputObject $policy -Name 'Workload' -Default '')"
            $lines.Add($line)
        }

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c56.obs.none') -f $all.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c56.rem.none')
    }

    $active = @($detail | Where-Object { $_.Active })
    if ($active.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c56.obs.inactive') -f $detail.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c56.rem.inactive')
    }

    $best = $null
    foreach ($entry in $active) {
        if ($null -ne $entry.Days -and ($null -eq $best -or $entry.Days -gt $best)) { $best = $entry.Days }
    }

    if ($null -eq $best) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c56.obs.norule') -f $active.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c56.rem.norule')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c56.obs.ok') -f $active.Count, (Get-CceSecurityRetentionText -Days $best)) `
        -Evidence ($lines | ConvertTo-CceText)
}

function Invoke-CceCheck57 {
    <#
        Retention des journaux d'audit : seuil de 180 jours (valeur par defaut
        d'Audit Standard depuis le 17/10/2023) et couverture des types
        d'enregistrement IA (CopilotInteraction, ConnectedAIAppInteraction,
        AIAppInteraction).
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSafe { , @(Get-UnifiedAuditLogRetentionPolicy -ErrorAction Stop) } -What 'Get-UnifiedAuditLogRetentionPolicy'
    if ($null -eq $policies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    if (@($policies).Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed (T 'c57.obs.none') `
            -Evidence (T 'c57.ev.none') `
            -Remediation (T 'c57.rem.none')
    }

    $detail = [System.Collections.Generic.List[object]]::new()

    foreach ($policy in @($policies)) {
        $raw = "$(Get-CceSecurityValue -InputObject $policy -Name 'RetentionDuration' -Default '')"
        $enabled = "$(Get-CceSecurityValue -InputObject $policy -Name 'Enabled' -Default $true)"
        $types = @(@(Get-CceSecurityValue -InputObject $policy -Name 'RecordTypes' -Default @()) | ForEach-Object { "$_" })

        $detail.Add([pscustomobject]@{
            Name      = "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')"
            Duration  = $raw
            Days      = (Get-CceSecurityRetentionDay -Duration $raw)
            Priority  = "$(Get-CceSecurityValue -InputObject $policy -Name 'Priority' -Default '')"
            Enabled   = ($enabled -ne 'False')
            Types     = $types
            TypesText = $(if ($types.Count -eq 0) { T 'c57.ev.alltypes' } else { $types -join ', ' })
        })
    }

    $lines = @($detail | ForEach-Object { (T 'c57.ev.detail') -f $_.Name, $_.Duration, $_.TypesText, $_.Priority, $_.Enabled })
    $compact = @($detail | ForEach-Object { (T 'c57.ev.line') -f $_.Name, $_.Duration, $_.Priority })
    $evidence = $lines | ConvertTo-CceText

    $enabledPolicies = @($detail | Where-Object { $_.Enabled })
    if ($enabledPolicies.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c57.obs.disabled') -f $detail.Count) `
            -Evidence $evidence `
            -Remediation (T 'c57.rem.disabled')
    }

    # Une duree non interpretable n'est jamais comptee en ecart : le moteur ne
    # prononce un "Non conforme" que sur une valeur qu'il a su lire.
    $tooShort = @($enabledPolicies | Where-Object { $null -ne $_.Days -and $_.Days -lt $script:CceSecurityAuditFloorDays })
    if ($tooShort.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c57.obs.ko') -f $enabledPolicies.Count, $tooShort.Count, $script:CceSecurityAuditFloorDays) `
            -Evidence $evidence `
            -Remediation ((T 'c57.rem.ko') -f (@($tooShort.Name) -join ', '), $script:CceSecurityAuditFloorDays)
    }

    $qualifying = @($enabledPolicies | Where-Object { $null -eq $_.Days -or $_.Days -ge $script:CceSecurityAuditFloorDays })
    $missing = @($script:CceSecurityAiRecordTypes | Where-Object {
        $recordType = $_
        # RecordTypes vide = tous les types d'enregistrement.
        @($qualifying | Where-Object { $_.Types.Count -eq 0 -or ($_.Types -join ' ') -match "\b$recordType\b" }).Count -eq 0
    })

    if ($missing.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c57.obs.noai') -f $qualifying.Count, ($missing -join ', ')) `
            -Evidence $evidence `
            -Remediation ((T 'c57.rem.noai') -f ($missing -join ', '))
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c57.obs.main') -f $enabledPolicies.Count, ($compact -join ' | ')) `
        -Evidence $evidence
}

function Invoke-CceSecurityGraphProbe {
    <#
    .SYNOPSIS
        Appel Graph en lecture seule qui conserve le code de statut HTTP.
    .DESCRIPTION
        Invoke-CceGraphRequest ramene toute erreur a $null : ici, la distinction porte
        le diagnostic (403 = licence ou role manquant, 404 = solution non deployee,
        le reste = incident). Le code est lu sur l'exception, avec repli sur le texte
        du message lorsque le SDK ne l'expose pas comme propriete.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri)

    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Status = 200; Response = $response; Message = '' }
    }
    catch {
        $message = "$($_.Exception.Message)"
        $status = 0

        $code = Get-CceSecurityValue -InputObject $_.Exception -Name 'StatusCode'
        if ($null -eq $code) {
            $inner = Get-CceSecurityValue -InputObject $_.Exception -Name 'Response'
            $code = Get-CceSecurityValue -InputObject $inner -Name 'StatusCode'
        }
        if ($null -ne $code) {
            try { $status = [int] $code } catch { $status = 0 }
        }

        if ($status -eq 0 -and $message -match '\b(400|401|403|404|429|500|503)\b') { $status = [int] $Matches[1] }
        if ($status -eq 0) {
            if ($message -match 'Forbidden|AccessDenied|Authorization_RequestDenied|InsufficientPrivileges') { $status = 403 }
            elseif ($message -match 'Unauthorized|InvalidAuthenticationToken') { $status = 401 }
            elseif ($message -match 'NotFound') { $status = 404 }
        }

        [pscustomobject]@{ Ok = $false; Status = $status; Response = $null; Message = $message }
    }
}

function Get-CceSecurityEdiscoveryCase {
    <#
    .SYNOPSIS
        Sonde de l'API eDiscovery : cas existants et code de statut de la reponse.
    .DESCRIPTION
        Un seul appel, mis en cache : l'inventaire est global au tenant. La pagination
        est plafonnee, un tenant de plusieurs milliers de cas ne doit pas allonger l'audit.
        Aucune ecriture : ni cas, ni recherche, ni export ne sont crees.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('EdiscoveryCases')) { return $Context.Cache['EdiscoveryCases'] }

    $probe = Invoke-CceSecurityGraphProbe -Uri $script:CceSecurityEdiscoveryUri

    $cases = [System.Collections.Generic.List[object]]::new()
    $truncated = $false
    $page = 0
    $response = if ($probe.Ok) { $probe.Response } else { $null }

    while ($null -ne $response) {
        foreach ($case in @(Get-CceSecurityValue -InputObject $response -Name 'value' -Default @())) { $cases.Add($case) }
        $page++

        $next = "$(Get-CceSecurityValue -InputObject $response -Name '@odata.nextLink' -Default '')"
        if (-not $next) { break }
        if ($page -ge $script:CceSecurityEdiscoveryMaxPage) { $truncated = $true; break }

        $response = Invoke-CceGraphRequest -Uri $next -Quiet
    }

    $result = [pscustomobject]@{
        Ok        = $probe.Ok
        Status    = $probe.Status
        Message   = $probe.Message
        Uri       = $script:CceSecurityEdiscoveryUri
        Cases     = @($cases)
        Truncated = $truncated
    }

    $Context.Cache['EdiscoveryCases'] = $result
    $result
}

function Test-CceSecurityEdiscoveryEntitlement {
    <#
    .SYNOPSIS
        Vraie si un abonnement du tenant porte eDiscovery (Premium).
    .DESCRIPTION
        Sert uniquement a qualifier un refus : sans licence, l'exigence sort du score
        ("Non applicable") ; avec licence, un refus signale un manque de droits
        ("Non evalue"). Les deux statuts restent hors du taux de conformite.
    #>
    [CmdletBinding()] param($Context)

    foreach ($sku in @(Get-CceSubscribedSku -Context $Context)) {
        $part = "$(Get-CceSecurityValue -InputObject $sku -Name 'SkuPartNumber' -Default '')"
        if ($part -match $script:CceSecurityEdiscoverySkuPattern) { return $true }

        foreach ($plan in @(Get-CceSecurityValue -InputObject $sku -Name 'ServicePlans' -Default @())) {
            $name = "$(Get-CceSecurityValue -InputObject $plan -Name 'ServicePlanName' -Default '')"
            $state = "$(Get-CceSecurityValue -InputObject $plan -Name 'ProvisioningStatus' -Default '')"
            if ($name -match $script:CceSecurityEdiscoveryPlanPattern -and $state -notmatch 'Disabled') { return $true }
        }
    }

    $false
}

function Get-CceSecuritySkuSummary {
    <# Liste compacte des references d'abonnement, pour justifier un "Non applicable". #>
    [CmdletBinding()] param($Context)

    $parts = @(Get-CceSubscribedSku -Context $Context |
        ForEach-Object { "$(Get-CceSecurityValue -InputObject $_ -Name 'SkuPartNumber' -Default '')" } |
        Where-Object { $_ })

    if ($parts.Count -eq 0) { return T 'c58.ev.nosku' }
    (@($parts | Select-Object -First 12) -join ', ')
}

function Get-CceSecurityMemberName {
    <# Libelle exploitable d'un membre de groupe de roles, quelle que soit sa forme. #>
    [CmdletBinding()] param($InputObject)

    foreach ($property in 'DisplayName', 'Name', 'PrimarySmtpAddress', 'WindowsLiveID', 'Identity') {
        $value = "$(Get-CceSecurityValue -InputObject $InputObject -Name $property -Default '')"
        if ($value) { return $value }
    }

    "$InputObject"
}

function Get-CceSecurityEdiscoveryManager {
    <#
    .SYNOPSIS
        Membres du groupe de roles eDiscovery Manager (lecture seule Purview).
    .DESCRIPTION
        Get-RoleGroupMember est la source directe. En cas d'echec, Get-RoleGroup permet
        de distinguer un groupe reellement absent - qui est un constat - d'une lecture
        impossible, qui ne doit jamais etre comptee en ecart.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('EdiscoveryManagers')) { return $Context.Cache['EdiscoveryManagers'] }

    $result = [pscustomobject]@{
        Readable   = $false
        GroupFound = $false
        Members    = @()
        Reason     = ''
    }

    if (-not (Test-CceService -Service Purview -Context $Context)) {
        $result.Reason = if ($Context.ServiceError.Contains('Purview')) { "$($Context.ServiceError['Purview'])" } else { T 'core.notevaluated.reason' }
        $Context.Cache['EdiscoveryManagers'] = $result
        return $result
    }

    # La virgule preserve la difference entre "groupe vide" et "lecture impossible".
    $members = Get-CceSafe { , @(Get-RoleGroupMember -Identity $script:CceSecurityEdiscoveryRoleGroup -ErrorAction Stop) } -What 'Get-RoleGroupMember'

    if ($null -ne $members) {
        $result.Readable = $true
        $result.GroupFound = $true
        $result.Members = @(@($members) | ForEach-Object { Get-CceSecurityMemberName -InputObject $_ } | Where-Object { $_ })
        $Context.Cache['EdiscoveryManagers'] = $result
        return $result
    }

    $groups = Get-CceSafe { , @(Get-RoleGroup -ErrorAction Stop) } -What 'Get-RoleGroup'
    if ($null -eq $groups -or @($groups).Count -eq 0) {
        $result.Reason = T 'c58.ev.rolesfail'
        $Context.Cache['EdiscoveryManagers'] = $result
        return $result
    }

    $result.Readable = $true

    $matched = @(@($groups) | Where-Object {
        "$(Get-CceSecurityValue -InputObject $_ -Name 'Name' -Default '') $(Get-CceSecurityValue -InputObject $_ -Name 'DisplayName' -Default '')" -match $script:CceSecurityEdiscoveryRolePattern
    })

    if ($matched.Count -eq 0) {
        $Context.Cache['EdiscoveryManagers'] = $result
        return $result
    }

    $result.GroupFound = $true

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $matched) {
        foreach ($member in @(Get-CceSecurityValue -InputObject $group -Name 'Members' -Default @())) {
            $text = "$member"
            if ($text) { $names.Add($text) }
        }
    }
    $result.Members = @($names | Sort-Object -Unique)

    $Context.Cache['EdiscoveryManagers'] = $result
    $result
}

function Get-CceSecurityCopilotSearch {
    <#
    .SYNOPSIS
        Recherches de conformite ciblant les interactions Copilot.
    .DESCRIPTION
        Un seul appel global, mis en cache. Seule la requete de contenu est examinee :
        un simple nom de recherche contenant "Copilot" ne prouve rien.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotComplianceSearch')) { return $Context.Cache['CopilotComplianceSearch'] }

    $result = [pscustomobject]@{ Readable = $false; Total = 0; Matches = @() }

    if (-not (Test-CceService -Service Purview -Context $Context)) {
        $Context.Cache['CopilotComplianceSearch'] = $result
        return $result
    }

    $searches = Get-CceSafe { , @(Get-ComplianceSearch -ErrorAction Stop) } -What 'Get-ComplianceSearch'
    if ($null -eq $searches) {
        $Context.Cache['CopilotComplianceSearch'] = $result
        return $result
    }

    $all = @($searches)
    $result.Readable = $true
    $result.Total = $all.Count
    $result.Matches = @($all | Where-Object {
        "$(Get-CceSecurityValue -InputObject $_ -Name 'ContentMatchQuery' -Default '')" -match $script:CceSecurityCopilotQueryPattern
    })

    $Context.Cache['CopilotComplianceSearch'] = $result
    $result
}

function Invoke-CceCheck58 {
    <#
        eDiscovery sur les donnees Copilot : trois mesures, toutes en lecture seule.
          1. GET /security/cases/ediscoveryCases : un 200 prouve d'un seul coup la
             licence eDiscovery (Premium), la permission du compte d'audit et la
             disponibilite de la solution ; un 403 signale lequel des deux manque.
          2. Composition du groupe de roles eDiscovery Manager : sans gestionnaire
             nominatif, personne ne peut conduire la recherche le jour d'une injonction.
          3. Recherches de conformite portant sur les interactions Copilot
             (ItemClass IPM.SkypeTeams.Message.Copilot.* / Type > Copilot activity).
        Le moteur ne cree ni cas, ni recherche, ni export : la sonde ne modifie rien.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $probe = Get-CceSecurityEdiscoveryCase -Context $Context
    $statusText = if ($probe.Status -gt 0) { "$($probe.Status)" } else { T 'c58.ev.nostatus' }

    if (-not $probe.Ok) {
        $http = (T 'c58.ev.http') -f $probe.Uri, $statusText, $probe.Message

        if ($probe.Status -eq 404) {
            return New-CceNotApplicable -Reason (T 'c58.na.api') -Evidence $http
        }

        if ($probe.Status -eq 401 -or $probe.Status -eq 403) {
            if (Test-CceSecurityEdiscoveryEntitlement -Context $Context) {
                return New-CceResult -Status 'Non evalue' `
                    -Observed ((T 'c58.obs.denied') -f $statusText) `
                    -Evidence $http `
                    -Remediation (T 'c58.rem.denied')
            }

            $sku = (T 'c58.ev.nolicense') -f (Get-CceSecuritySkuSummary -Context $Context)
            return New-CceNotApplicable -Reason (T 'c58.na.license') `
                -RequiredLicense (T 'c58.lic.premium') `
                -Evidence (@($http, $sku) -join [Environment]::NewLine)
        }

        return New-CceResult -Status 'Non evalue' `
            -Observed ((T 'c58.obs.error') -f $statusText) `
            -Evidence $http `
            -Remediation (T 'c58.rem.error')
    }

    $cases = @($probe.Cases)
    $caseCount = $cases.Count

    $lines = [System.Collections.Generic.List[string]]::new()
    $line = (T 'c58.ev.probe') -f $probe.Uri, $statusText, $caseCount
    $lines.Add($line)

    if ($probe.Truncated) { $lines.Add((T 'c58.ev.truncated')) }

    foreach ($case in ($cases | Select-Object -First $script:CceSecurityEdiscoveryMaxDetail)) {
        $line = (T 'c58.ev.case') -f "$(Get-CceSecurityValue -InputObject $case -Name 'displayName' -Default '')", "$(Get-CceSecurityValue -InputObject $case -Name 'status' -Default '')", "$(Get-CceSecurityValue -InputObject $case -Name 'createdDateTime' -Default '')"
        $lines.Add($line)
    }

    if ($caseCount -eq 0) { $lines.Add((T 'c58.ev.nocase')) }

    $searchInfo = Get-CceSecurityCopilotSearch -Context $Context
    $searchCount = @($searchInfo.Matches).Count

    if ($searchInfo.Readable) {
        foreach ($search in (@($searchInfo.Matches) | Select-Object -First $script:CceSecurityEdiscoveryMaxDetail)) {
            $line = (T 'c58.ev.search') -f "$(Get-CceSecurityValue -InputObject $search -Name 'Name' -Default '')", "$(Get-CceSecurityValue -InputObject $search -Name 'Status' -Default '')", "$(Get-CceSecurityValue -InputObject $search -Name 'ContentMatchQuery' -Default '')"
            $lines.Add($line)
        }

        if ($searchCount -eq 0) {
            $line = (T 'c58.ev.searchnone') -f $searchInfo.Total
            $lines.Add($line)
        }
    }
    elseif (Test-CceService -Service Purview -Context $Context) {
        # Inventaire illisible : le constat ne doit pas se lire comme une absence.
        $lines.Add((T 'c58.ev.searchunread'))
    }

    $managerInfo = Get-CceSecurityEdiscoveryManager -Context $Context

    if (-not $managerInfo.Readable) {
        $line = (T 'c58.ev.rolesunread') -f $managerInfo.Reason
        $lines.Add($line)

        return New-CceResult -Status 'Non evalue' `
            -Observed ((T 'c58.obs.nopurview') -f $caseCount) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c58.rem.nopurview')
    }

    if (-not $managerInfo.GroupFound) {
        $lines.Add((T 'c58.ev.nogroup'))

        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c58.obs.nogroup') `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c58.rem.nomanager')
    }

    $managerCount = @($managerInfo.Members).Count

    if ($managerCount -eq 0) {
        $lines.Add((T 'c58.ev.nomanager'))

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c58.obs.nomanager') -f $caseCount) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c58.rem.nomanager')
    }

    $line = (T 'c58.ev.manager') -f $managerCount, ((@($managerInfo.Members) | Select-Object -First $script:CceSecurityEdiscoveryMaxDetail) -join ', ')
    $lines.Add($line)

    # Capacite disponible mais jamais exercee : c'est precisement ce que l'exigence
    # cherche a reveler avant qu'une injonction ne l'apprenne a l'organisation.
    if ($caseCount -eq 0 -and $searchCount -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c58.obs.unused') -f $managerCount) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c58.rem.unused')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c58.obs.ok') -f $caseCount, $managerCount, $searchCount) `
        -Evidence ($lines | ConvertTo-CceText) `
        -Remediation $(if ($searchCount -eq 0) { T 'c58.rem.nosearch' } else { '' })
}

function Invoke-CceCheck59 {
    <# Activer Microsoft Purview Data Access Governance pour SharePoint #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c59.obs.manual') `
        -Evidence (T 'c59.ev.manual') `
        -Remediation (T 'c59.rem.manual')
}

function Invoke-CceCheck66 {
    <#
        DSPM for AI : strategies par defaut et detection de l'usage a risque de l'IA.

        Data Security Posture Management for AI est le point d'entree Purview dedie a la
        gouvernance des Copilot, des agents et des IA tierces. Ses strategies deployables
        en un clic portent des noms normalises par le service, donc detectables par script :
          - Insider Risk Management      "DSPM for AI - Detect risky AI usage"
          - Conformite des communications "DSPM for AI - Unethical behavior in AI apps"
          - Strategie de collecte         "DSPM for AI - Capture interactions for Copilot experiences"
          - DLP                           "DSPM for AI - Protect sensitive data from Copilot processing"

        L'etat de la solution elle-meme (evaluations de risque de donnees, recommandations)
        n'a aucune API publique : il reste a constater dans le portail. Le controle ne porte
        donc que sur les strategies, qui sont, elles, lisibles.

        Toutes les lectures sont facultatives et independantes : une famille illisible
        n'est jamais convertie en ecart, elle est signalee comme non lue.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $sources = [System.Collections.Generic.List[object]]::new()
    $unread = [System.Collections.Generic.List[string]]::new()
    $readable = 0

    # DLP : famille "Protect sensitive data from Copilot processing". L'inventaire est
    # partage avec le controle 55, il n'est donc lu qu'une seule fois par execution.
    $dlp = Get-CceSecurityDlpPolicy -Context $Context
    if ($null -eq $dlp) { $unread.Add((T 'c66.ev.unread.dlp')) }
    else { $readable++; foreach ($policy in @($dlp)) { $sources.Add($policy) } }

    # Conformite des communications : famille "Unethical behavior in AI apps".
    $review = Get-CceSafe { , @(Get-SupervisoryReviewPolicyV2 -ErrorAction Stop) } -What 'Get-SupervisoryReviewPolicyV2'
    if ($null -eq $review) { $unread.Add((T 'c66.ev.unread.review')) }
    else { $readable++; foreach ($policy in @($review)) { $sources.Add($policy) } }

    # Insider Risk Management : famille "Detect risky AI usage".
    $insider = Get-CceSafe { , @(Get-InsiderRiskPolicy -ErrorAction Stop) } -What 'Get-InsiderRiskPolicy'
    if ($null -eq $insider) { $unread.Add((T 'c66.ev.unread.insider')) }
    else { $readable++; foreach ($policy in @($insider)) { $sources.Add($policy) } }

    # Strategies de collecte : famille "Capture interactions for Copilot experiences".
    $collection = Get-CceSafe { , @(Get-AppRetentionCompliancePolicy -ErrorAction Stop) } -What 'Get-AppRetentionCompliancePolicy'
    if ($null -eq $collection) { $unread.Add((T 'c66.ev.unread.collection')) }
    else { $readable++; foreach ($policy in @($collection)) { $sources.Add($policy) } }

    if ($readable -eq 0) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $matched = @(@($sources) | Where-Object {
        "$(Get-CceSecurityValue -InputObject $_ -Name 'Name' -Default '') $(Get-CceSecurityValue -InputObject $_ -Name 'DisplayName' -Default '')" -match $script:CceSecurityDspmPolicyPattern
    })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'c66.ev.portal'))
    foreach ($note in $unread) { $lines.Add($note) }

    if ($matched.Count -eq 0) {
        # Une detection positive prime toujours sur le test de licence : ce n'est qu'en
        # l'absence totale de strategie que la question de la capacite detenue se pose.
        if (-not (Test-CceSecurityDspmEntitlement -Context $Context)) {
            $lines.Add((T 'c66.na.license'))
            $line = (T 'c66.ev.nolicense') -f (Get-CceSecuritySkuSummary -Context $Context)
            $lines.Add($line)

            return New-CceNotApplicable -Reason (T 'c66.na.license') `
                -RequiredLicense (T 'c66.lic.purview') `
                -Evidence ($lines | ConvertTo-CceText)
        }

        $lines.Add((T 'c66.ev.none'))

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c66.obs.none') -f @($sources).Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c66.rem.none')
    }

    $activeFamily = [System.Collections.Generic.List[string]]::new()
    $activeCount = 0

    foreach ($policy in $matched) {
        $name = "$(Get-CceSecurityValue -InputObject $policy -Name 'Name' -Default '')"
        if (-not $name) { $name = "$(Get-CceSecurityValue -InputObject $policy -Name 'DisplayName' -Default '')" }

        $isActive = Test-CceSecurityPolicyActive -Policy $policy
        if ($isActive) { $activeCount++ }

        $state = if ($isActive) { T 'c66.ev.active' } else { T 'c66.ev.inactive' }
        $line = (T 'c66.ev.policy') -f $name, $state
        $lines.Add($line)

        if (-not $isActive) { continue }

        foreach ($family in $script:CceSecurityDspmFamilyPattern.Keys) {
            if ($name -match $script:CceSecurityDspmFamilyPattern[$family] -and $activeFamily -notcontains $family) {
                $activeFamily.Add($family)
            }
        }
    }

    if ($activeCount -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c66.obs.inactive') -f $matched.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c66.rem.inactive')
    }

    $missing = @($script:CceSecurityDspmRequiredFamily | Where-Object { $activeFamily -notcontains $_ })
    $missingText = (@($missing | ForEach-Object { Get-CceSecurityDspmFamilyLabel -Family $_ }) -join ' ; ')

    if ($missing.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c66.obs.partial') -f $activeCount, $missing.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation ((T 'c66.rem.partial') -f $missingText)
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c66.obs.ok') -f $activeCount, @($activeFamily).Count) `
        -Evidence ($lines | ConvertTo-CceText) `
        -Remediation $(if ($activeFamily -contains 'protect') { '' } else { (T 'c66.rem.protect') })
}
