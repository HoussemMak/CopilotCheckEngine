#Requires -Version 7.0
<#
    Controles 80 a 84 - COUT ET CYCLE DE VIE DES LICENCES

    Ce domaine ne mesure pas une configuration de securite mais la valeur economique
    du parc Copilot : sieges payes sans usage, population qui consomme Copilot Chat
    sans licence, facturation a l'usage des agents, porte d'entree des achats en
    libre-service, et veille des changements annonces par Microsoft.

    Trois particularites l'opposent au reste du referentiel :

      - le controle 80 raisonne sur le rapport d'usage Copilot, dont la version v1.0
        renvoie un flux CSV et la version beta du JSON : la collecte essaie plusieurs
        chemins documentes puis normalise les deux formes ;
      - le controle 81 travaille sur un denominateur DISTINCT de la population
        licenciee (Copilot Chat est disponible sans siege Copilot depuis 2025) et ne
        modifie aucun autre controle ;
      - le controle 82 est informatif : aucune API publique n'expose les strategies de
        facturation a l'usage, il reste donc manuel et hors du score (Scored = false).

    Lecture seule stricte : aucune commande de modification, aucune invite interactive.
#>

# Periode de reference du rapport d'usage. La cible documentee est 90 jours ; le repli
# a 30 jours (collecteur mutualise) sert lorsque la periode longue n'est pas servie.
$script:CceCostUsageDays = 90
$script:CceCostFallbackDays = 30

# Journal d'audit : fenetre et plafond d'enregistrements, pour borner le cout.
$script:CceCostAuditDays = 30
$script:CceCostAuditMax = 2000

# Message Center : pagination plafonnee, seuils de veille.
$script:CceCostMessageTop = 100
$script:CceCostMessagePageMax = 5
$script:CceCostActionSoonDays = 30
$script:CceCostMajorReviewDays = 7

# Nombre maximum de lignes nominatives reportees en preuve.
$script:CceCostEvidenceMax = 20

function Get-CceCostValue {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete.
    .DESCRIPTION
        Graph, Exchange et MSCommerce renvoient tantot des objets, tantot des
        dictionnaires, et le mode strict interdit l'acces a une propriete absente.
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

function Get-CceCostFieldMap {
    <#
    .SYNOPSIS
        Table "nom normalise -> valeur" d'une ligne de rapport.
    .DESCRIPTION
        Le meme rapport d'usage s'expose en JSON (userPrincipalName,
        copilotChatLastActivityDate) et en CSV (User Principal Name,
        Copilot Chat Last Activity Date). La normalisation (minuscules, caracteres
        non alphanumeriques retires) rend les deux formes interchangeables.
    #>
    [CmdletBinding()] param($Row)

    $map = [ordered]@{}
    if ($null -eq $Row) { return $map }

    if ($Row -is [System.Collections.IDictionary]) {
        foreach ($key in @($Row.Keys)) {
            $normal = ("$key" -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            if ($normal -ne '' -and -not $map.Contains($normal)) { $map[$normal] = $Row[$key] }
        }
        return $map
    }

    foreach ($property in $Row.PSObject.Properties) {
        $normal = ("$($property.Name)" -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($normal -ne '' -and -not $map.Contains($normal)) { $map[$normal] = $property.Value }
    }

    $map
}

function Get-CceCostDate {
    <# Convertit une valeur en DateTime, ou $null si elle est absente ou illisible. #>
    [CmdletBinding()] param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    $text = "$Value".Trim()
    if ($text -eq '') { return $null }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [ref] $parsed)) { return $parsed }
    $null
}

function ConvertTo-CceCostUsageRow {
    <#
    .SYNOPSIS
        Normalise les lignes du rapport d'usage Copilot.
    .DESCRIPTION
        Retient l'UPN, la date d'activite la plus recente toutes applications
        confondues (toute colonne dont le nom se termine par LastActivityDate) et,
        lorsque la version v2 du rapport l'expose, le compteur de prompts soumis.
    #>
    [CmdletBinding()] param($Rows)

    $normalised = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($Rows)) {
        $map = Get-CceCostFieldMap -Row $row

        $upn = ''
        foreach ($candidate in @('userprincipalname', 'upn', 'userid')) {
            if (-not $map.Contains($candidate)) { continue }
            $upn = "$($map[$candidate])".Trim()
            if ($upn -ne '') { break }
        }

        $last = $null
        $hasActivityField = $false
        $prompts = $null
        $promptField = ''

        foreach ($key in @($map.Keys)) {
            if ($key -like '*lastactivitydate') {
                $hasActivityField = $true
                $date = Get-CceCostDate -Value $map[$key]
                if ($null -ne $date -and ($null -eq $last -or $date -gt $last)) { $last = $date }
                continue
            }

            if ($key -like '*promptcount' -or $key -like '*promptssubmitted' -or $key -like '*promptsubmitted') {
                $number = 0
                if ([int]::TryParse("$($map[$key])", [ref] $number)) {
                    if ($null -eq $prompts) { $prompts = 0 }
                    $prompts += $number
                    if ($promptField -eq '') { $promptField = $key }
                }
            }
        }

        $normalised.Add([pscustomobject]@{
            Upn              = $upn
            LastActivity     = $last
            HasActivityField = $hasActivityField
            Prompts          = $prompts
            PromptField      = $promptField
        })
    }

    @($normalised)
}

function Get-CceCostReportRow {
    <#
    .SYNOPSIS
        Extrait les lignes d'une reponse de rapport, JSON ou flux CSV.
    .DESCRIPTION
        Les rapports d'usage repondent en CSV sur les chemins v1.0 et en JSON lorsque
        $format=application/json est accepte : les deux formes sont ramenees a une
        collection d'objets. Le resultat est enveloppe : un rapport vide mais valide
        ne doit pas etre confondu avec une reponse illisible, distinction qu'un tableau
        vide perdrait (PowerShell deroule @() en $null a la sortie d'une fonction).
        Renvoie $null si la reponse n'est pas exploitable.
    #>
    [CmdletBinding()] param($Response)

    if ($null -eq $Response) { return $null }

    if ($Response -is [string]) {
        $text = $Response
        if ($text.Trim() -eq '') { return $null }
        $rows = Get-CceSafe { $text | ConvertFrom-Csv -ErrorAction Stop } -What 'ConvertFrom-Csv'
        if ($null -eq $rows) { return $null }
        return [pscustomobject]@{ Rows = @($rows) }
    }

    if ($Response -is [System.Collections.IDictionary]) {
        if (-not $Response.Contains('value')) { return $null }
    }
    elseif ($null -eq $Response.PSObject.Properties['value']) { return $null }

    [pscustomobject]@{ Rows = @(Get-CceCostValue -Item $Response -Name 'value') }
}

function Get-CceCostUsageReport {
    <#
    .SYNOPSIS
        Rapport d'usage Copilot par utilisateur, sur la periode la plus longue servie.
    .DESCRIPTION
        Essaie successivement les chemins documentes (v1.0 /copilot/reports en version
        v2, puis sans version, puis la beta), et retombe sur le collecteur mutualise a
        30 jours de Checks.Copilot.ps1. Chaque tentative est silencieuse : un chemin non
        deploye sur le tenant ne doit pas polluer le journal.
        Ok = $false signifie "rapport illisible", jamais "aucun usage".
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CostUsageReport')) { return $Context.Cache['CostUsageReport'] }

    $report = [pscustomobject]@{
        Ok          = $false
        Rows        = @()
        Days        = 0
        Source      = ''
        Anonymised  = $false
        PromptField = ''
        ZeroPrompt  = 0
    }

    if (-not $Context.Services.Graph) {
        $Context.Cache['CostUsageReport'] = $report
        return $report
    }

    $long = $script:CceCostUsageDays
    $attempts = @(
        [pscustomobject]@{
            Days = $long
            Uri  = "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D$long',version='v2')?`$format=application/json"
        },
        [pscustomobject]@{
            Days = $long
            Uri  = "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D$long')?`$format=application/json"
        },
        [pscustomobject]@{
            Days = $long
            Uri  = "https://graph.microsoft.com/beta/reports/getMicrosoft365CopilotUsageUserDetail(period='D$long')?`$format=application/json"
        }
    )

    $rows = $null
    $days = 0
    $source = ''

    foreach ($attempt in $attempts) {
        $response = Invoke-CceGraphRequest -Quiet -Uri $attempt.Uri
        $candidate = Get-CceCostReportRow -Response $response
        if ($null -eq $candidate) { continue }

        $rows = @($candidate.Rows)
        $days = $attempt.Days
        $source = $attempt.Uri
        break
    }

    if ($null -eq $rows) {
        # Repli sur la collecte deja mutualisee par le domaine Copilot (30 jours) :
        # une periode plus courte vaut mieux qu'un controle aveugle, a condition de
        # le dire et de ne pas durcir le verdict.
        $shared = Get-CceCopilotUsageReport -Context $Context
        if ($null -ne $shared) {
            $rows = @($shared)
            $days = $script:CceCostFallbackDays
            $source = 'beta/reports/getMicrosoft365CopilotUsageUserDetail(period=''D30'')'
        }
    }

    if ($null -eq $rows) {
        $Context.Cache['CostUsageReport'] = $report
        return $report
    }

    $normalised = @(ConvertTo-CceCostUsageRow -Rows $rows)

    # Un rapport non vide dont aucune ligne ne porte de colonne d'activite n'a pas la
    # forme attendue : le declarer lisible produirait un verdict invente.
    $usable = ($normalised.Count -eq 0) -or (@($normalised | Where-Object { $_.HasActivityField }).Count -gt 0)
    if (-not $usable) {
        $Context.Cache['CostUsageReport'] = $report
        return $report
    }

    $promptField = ''
    foreach ($row in $normalised) {
        if ($row.PromptField -ne '') { $promptField = $row.PromptField; break }
    }

    $report.Ok = $true
    $report.Rows = $normalised
    $report.Days = $days
    $report.Source = $source
    $report.PromptField = $promptField
    $report.ZeroPrompt = @($normalised | Where-Object { $null -ne $_.Prompts -and $_.Prompts -eq 0 }).Count
    $report.Anonymised = (@($normalised | Where-Object { $_.Upn -match '^[A-Fa-f0-9]{40,}$' }).Count -gt 0)

    $Context.Cache['CostUsageReport'] = $report
    $report
}

function Invoke-CceCheck80 {
    <# Licences Copilot dormantes : sieges attribues a des comptes actifs sans aucun prompt #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    # Tout tenant possede au moins un abonnement : une table vide signale un defaut de
    # droits, jamais une organisation sans licence. Le distinguer evite de classer
    # "sans objet" un controle qui n'a en realite pas pu etre lu.
    $skus = @(Get-CceSubscribedSku -Context $Context)
    if ($skus.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c80.obs.noskus') `
            -Evidence (T 'c80.ev.noskus') `
            -Remediation (T 'c80.rem.noskus')
    }

    $skuIds = @(Get-CceCopilotSkuId -Context $Context)
    if ($skuIds.Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c80.na.nosku') -RequiredLicense (T 'c80.na.lic')
    }

    $users = @(Get-CceCopilotUser -Context $Context)
    $active = @($users | Where-Object { [bool] (Get-CceCostValue -Item $_ -Name 'AccountEnabled') })
    $disabled = $users.Count - $active.Count

    if ($active.Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c80.na.noseat') -Evidence ((T 'c80.ev.noseat') -f $users.Count)
    }

    $report = Get-CceCostUsageReport -Context $Context

    if (-not $report.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c80.obs.ne') `
            -Evidence (T 'c80.ev.ne') `
            -Remediation (T 'c80.rem.ne')
    }

    if ($report.Anonymised) {
        # UPN haches : le croisement licence x usage est impossible par construction.
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c80.obs.anon') `
            -Evidence (T 'c80.ev.anon') `
            -Remediation (T 'c80.rem.anon')
    }

    $index = @{}
    foreach ($row in $report.Rows) {
        if ($row.Upn -eq '') { continue }
        $key = $row.Upn.ToLowerInvariant()
        if (-not $index.ContainsKey($key)) { $index[$key] = $row }
    }

    $silent = [System.Collections.Generic.List[string]]::new()
    $absent = [System.Collections.Generic.List[string]]::new()
    $usedCount = 0

    foreach ($user in $active) {
        $upn = "$(Get-CceCostValue -Item $user -Name 'UserPrincipalName')".Trim()
        if ($upn -eq '') { continue }

        $key = $upn.ToLowerInvariant()
        if (-not $index.ContainsKey($key)) { $absent.Add($upn); continue }

        if ($null -eq $index[$key].LastActivity) { $silent.Add($upn) } else { $usedCount++ }
    }

    $evidence = [System.Collections.Generic.List[string]]::new()

    foreach ($upn in ($silent | Select-Object -First $script:CceCostEvidenceMax)) {
        $evidence.Add(((T 'c80.ev.silent') -f $upn, $report.Days))
    }

    foreach ($upn in ($absent | Select-Object -First $script:CceCostEvidenceMax)) {
        $evidence.Add(((T 'c80.ev.absent') -f $upn, $report.Days))
    }

    $evidence.Add(((T 'c80.ev.summary') -f $active.Count, $usedCount, $silent.Count, $absent.Count, $report.Days, $report.Source))
    if ($disabled -gt 0) { $evidence.Add(((T 'c80.ev.disabled') -f $disabled)) }
    if ($report.PromptField -ne '') { $evidence.Add(((T 'c80.ev.prompts') -f $report.ZeroPrompt, $report.PromptField)) }

    $proof = $evidence | ConvertTo-CceText -MaxItems 45

    if ($silent.Count -gt 0) {
        # La periode de reference documentee est de 90 jours : sur une fenetre plus
        # courte, le silence reste un signal fort mais pas l'ecart formel de l'exigence.
        if ($report.Days -ge $script:CceCostUsageDays) {
            return New-CceResult -Status 'Non conforme' `
                -Observed ((T 'c80.obs.ko') -f $silent.Count, $active.Count, $report.Days) `
                -Evidence $proof `
                -Remediation (T 'c80.rem.ko')
        }

        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c80.obs.warn') -f $silent.Count, $report.Days, $active.Count) `
            -Evidence $proof `
            -Remediation (T 'c80.rem.warn')
    }

    if ($absent.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c80.obs.absent') -f $absent.Count, $active.Count) `
            -Evidence $proof `
            -Remediation (T 'c80.rem.absent')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c80.obs.ok') -f $active.Count, $report.Days) `
        -Evidence $proof
}

function Invoke-CceCheck81 {
    <#
        Perimetre de Copilot Chat pour la population NON licenciee.

        Microsoft 365 Copilot Chat est disponible sans siege Copilot pour tout porteur
        d'une licence M365 ou Office eligible : la population qui l'utilise est donc un
        denominateur distinct de la population licenciee, et Microsoft indique que cet
        usage n'est pas expose par les API de rapport Graph. Le journal d'audit unifie
        est la seule source : on y compte les utilisateurs distincts et on retire ceux
        qui portent une licence Copilot.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }
    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    # Sans table d'abonnements lisible, la population licenciee ne peut pas etre etablie :
    # tous les utilisateurs du journal passeraient a tort pour non licencies.
    if (@(Get-CceSubscribedSku -Context $Context).Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c81.obs.noskus') `
            -Evidence (T 'c81.ev.noskus') `
            -Remediation (T 'c81.rem.noskus')
    }

    $start = (Get-Date).AddDays(-$script:CceCostAuditDays)
    $end = Get-Date

    # Get-CceSafe rend $null sur exception comme sur absence de sortie : l'enveloppe
    # distingue "journal interrogeable mais vide" de "recherche impossible".
    $probe = Get-CceSafe {
        [pscustomobject]@{
            Rows = @(Search-UnifiedAuditLog -RecordType CopilotInteraction `
                    -StartDate $start -EndDate $end -ResultSize $script:CceCostAuditMax -ErrorAction Stop)
        }
    } -What 'Search-UnifiedAuditLog (CopilotInteraction)'

    if ($null -eq $probe) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c81.obs.ne') `
            -Evidence (T 'c81.ev.ne') `
            -Remediation (T 'c81.rem.ne')
    }

    $records = @($probe.Rows)

    if ($records.Count -eq 0) {
        # Aucun enregistrement : audit non ingere ou aucune interaction. Dans les deux
        # cas la surface non licenciee n'est pas mesurable, le verdict reste manuel.
        return New-CceResult -Status 'Manuel' `
            -Observed ((T 'c81.obs.manual') -f $script:CceCostAuditDays) `
            -Evidence (T 'c81.ev.manual') `
            -Remediation (T 'c81.rem.manual')
    }

    $seen = [ordered]@{}
    foreach ($record in $records) {
        $ids = "$(Get-CceCostValue -Item $record -Name 'UserIds')".Trim()
        if ($ids -eq '') { continue }

        foreach ($id in ($ids -split '[;,]')) {
            $upn = $id.Trim().ToLowerInvariant()
            if ($upn -eq '') { continue }
            if (-not $seen.Contains($upn)) { $seen[$upn] = 0 }
            $seen[$upn] = [int] $seen[$upn] + 1
        }
    }

    $licensed = @{}
    foreach ($user in @(Get-CceCopilotUser -Context $Context)) {
        $upn = "$(Get-CceCostValue -Item $user -Name 'UserPrincipalName')".Trim()
        if ($upn -ne '') { $licensed[$upn.ToLowerInvariant()] = $true }
    }

    # Les identites de service (applications, comptes systeme) n'ont pas d'UPN :
    # elles sont comptees a part plutot que gonfler la population non licenciee.
    $people = @($seen.Keys | Where-Object { $_ -like '*@*' })
    $system = @($seen.Keys).Count - $people.Count
    $unlicensed = @($people | Where-Object { -not $licensed.ContainsKey($_) })
    $covered = $people.Count - $unlicensed.Count

    $evidence = [System.Collections.Generic.List[string]]::new()
    foreach ($upn in ($unlicensed | Select-Object -First $script:CceCostEvidenceMax)) {
        $evidence.Add(((T 'c81.ev.line') -f $upn, $seen[$upn]))
    }

    $evidence.Add(((T 'c81.ev.summary') -f $records.Count, $people.Count, $covered, $unlicensed.Count, $script:CceCostAuditDays))
    if ($system -gt 0) { $evidence.Add(((T 'c81.ev.system') -f $system)) }
    if ($licensed.Count -eq 0) { $evidence.Add((T 'c81.ev.nolicensed')) }
    if ($records.Count -ge $script:CceCostAuditMax) { $evidence.Add(((T 'c81.ev.truncated') -f $script:CceCostAuditMax)) }
    $evidence.Add((T 'c81.ev.note'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 30

    if ($unlicensed.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c81.obs.warn') -f $unlicensed.Count, $people.Count, $script:CceCostAuditDays) `
            -Evidence $proof `
            -Remediation (T 'c81.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c81.obs.ok') -f $people.Count, $script:CceCostAuditDays) `
        -Evidence $proof
}

function Invoke-CceCheck82 {
    <#
        Facturation a l'usage des agents : strategie, perimetre, budget et credits.

        Aucun endpoint Microsoft Graph ni cmdlet publique n'expose les strategies de
        facturation Copilot ni la consommation de Copilot Credits. L'exigence est donc
        informative : elle figure au rapport avec sa procedure, sans peser sur le score
        (Scored = false dans le referentiel). Inventer un verdict ici reviendrait a
        noter une donnee que le moteur ne peut pas lire.
    #>
    [CmdletBinding()] param($Context)

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c82.ev.manual'))
    $evidence.Add((T 'c82.ev.budget'))
    $evidence.Add((T 'c82.ev.prereq'))

    $proof = $evidence | ConvertTo-CceText -MaxItems 5

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c82.obs.manual') `
        -Evidence $proof `
        -Remediation (T 'c82.rem.manual')
}

function Invoke-CceCheck83 {
    <# Bloquer les achats en libre-service de licences Microsoft 365 Copilot #>
    [CmdletBinding()] param($Context)

    # Domaine d'administration distinct : le service Commerce n'est pas connecte par
    # defaut, son absence est un manque de perimetre, pas un ecart de configuration.
    if (-not (Test-CceService -Service Commerce -Context $Context)) { return New-CceNotEvaluated -Service Commerce -Context $Context }

    if (-not (Get-Command -Name 'Get-MSCommerceProductPolicies' -ErrorAction SilentlyContinue)) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c83.obs.nocmd') `
            -Evidence (T 'c83.ev.nocmd') `
            -Remediation (T 'c83.rem.nocmd')
    }

    $policies = Get-CceSafe { Get-MSCommerceProductPolicies -PolicyId AllowSelfServicePurchase -ErrorAction Stop } `
        -What 'Get-MSCommerceProductPolicies (AllowSelfServicePurchase)'

    if ($null -eq $policies) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c83.obs.ne') `
            -Evidence (T 'c83.ev.ne') `
            -Remediation (T 'c83.rem.ne')
    }

    $rows = @(foreach ($policy in @($policies)) {
        [pscustomobject]@{
            Name  = "$(Get-CceCostValue -Item $policy -Name 'ProductName')".Trim()
            Id    = "$(Get-CceCostValue -Item $policy -Name 'ProductId')".Trim()
            Value = "$(Get-CceCostValue -Item $policy -Name 'PolicyValue')".Trim()
        }
    })

    # L'identifiant produit n'est jamais code en dur : il est lu dans la sortie.
    $copilot = @($rows | Where-Object { $_.Name -match '(?i)copilot' -or $_.Id -match '(?i)copilot' })

    if ($copilot.Count -eq 0) {
        return New-CceNotApplicable -Reason (T 'c83.na.reason') -Evidence ((T 'c83.ev.na') -f $rows.Count)
    }

    $enabled = @($copilot | Where-Object { $_.Value -match '(?i)^enabled$' })
    $trials = @($copilot | Where-Object { $_.Value -match '(?i)trial' })
    $blocked = @($copilot | Where-Object { $_.Value -match '(?i)^disabled$' })
    $unknown = @($copilot | Where-Object { $_.Value -notmatch '(?i)^(enabled|disabled)$' -and $_.Value -notmatch '(?i)trial' })

    $evidence = [System.Collections.Generic.List[string]]::new()
    foreach ($row in ($copilot | Select-Object -First $script:CceCostEvidenceMax)) {
        $evidence.Add(((T 'c83.ev.line') -f $row.Name, $row.Id, $row.Value))
    }
    $evidence.Add(((T 'c83.ev.summary') -f $copilot.Count, $rows.Count))

    $proof = $evidence | ConvertTo-CceText -MaxItems 25

    if ($enabled.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c83.obs.ko') -f $enabled.Count, (($enabled | ForEach-Object { $_.Name }) -join ', ')) `
            -Evidence $proof `
            -Remediation (T 'c83.rem.ko')
    }

    if ($trials.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c83.obs.warn') -f $trials.Count, (($trials | ForEach-Object { $_.Name }) -join ', ')) `
            -Evidence $proof `
            -Remediation (T 'c83.rem.warn')
    }

    if ($unknown.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c83.obs.unknown') -f $unknown.Count, (($unknown | ForEach-Object { $_.Value }) -join ', ')) `
            -Evidence $proof `
            -Remediation (T 'c83.rem.unknown')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c83.obs.ok') -f $blocked.Count, (($blocked | ForEach-Object { $_.Name }) -join ', ')) `
        -Evidence $proof
}

function Get-CceCostServiceMessage {
    <#
    .SYNOPSIS
        Messages du Message Center, filtres sur Copilot.
    .DESCRIPTION
        Le filtre serveur sur une collection (services/any) n'est pas servi par toutes
        les versions deployees : en cas de refus, la collecte repasse sans filtre et
        trie cote client. Pagination plafonnee pour borner le cout sur un tenant ancien.
        Ok = $false signifie "Message Center illisible", jamais "aucun message".
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CostServiceMessages')) { return $Context.Cache['CostServiceMessages'] }

    $result = [pscustomobject]@{
        Ok           = $false
        Messages     = @()
        Total        = 0
        ServerFilter = $true
        Truncated    = $false
    }

    if (-not $Context.Services.Graph) {
        $Context.Cache['CostServiceMessages'] = $result
        return $result
    }

    $base = 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/messages'
    $top = $script:CceCostMessageTop

    $response = Invoke-CceGraphRequest -Quiet -Uri "$base`?`$filter=services/any(s:s eq 'Microsoft 365 Copilot')&`$top=$top"

    if ($null -eq $response) {
        $result.ServerFilter = $false
        $response = Invoke-CceGraphRequest -Quiet -Uri "$base`?`$top=$top"
    }

    if ($null -eq $response) {
        $Context.Cache['CostServiceMessages'] = $result
        return $result
    }

    $raw = [System.Collections.Generic.List[object]]::new()
    $current = $response
    $page = 0

    while ($null -ne $current) {
        foreach ($entry in @(Get-CceCostValue -Item $current -Name 'value')) {
            if ($null -ne $entry) { $raw.Add($entry) }
        }

        $page++
        $next = "$(Get-CceCostValue -Item $current -Name '@odata.nextLink')".Trim()
        if ($next -eq '') { break }

        if ($page -ge $script:CceCostMessagePageMax) { $result.Truncated = $true; break }

        $current = Invoke-CceGraphRequest -Quiet -Uri $next
        if ($null -eq $current) { $result.Truncated = $true; break }
    }

    $messages = [System.Collections.Generic.List[object]]::new()

    foreach ($message in $raw) {
        $services = @(Get-CceCostValue -Item $message -Name 'services') -join ', '
        $title = "$(Get-CceCostValue -Item $message -Name 'title')".Trim()

        if ($services -notmatch '(?i)copilot' -and $title -notmatch '(?i)copilot') { continue }

        $viewpoint = Get-CceCostValue -Item $message -Name 'viewPoint'

        $messages.Add([pscustomobject]@{
            Id           = "$(Get-CceCostValue -Item $message -Name 'id')".Trim()
            Title        = $title
            Services     = $services
            Category     = "$(Get-CceCostValue -Item $message -Name 'category')".Trim()
            Severity     = "$(Get-CceCostValue -Item $message -Name 'severity')".Trim()
            ActionBy     = Get-CceCostDate -Value (Get-CceCostValue -Item $message -Name 'actionRequiredByDateTime')
            LastModified = Get-CceCostDate -Value (Get-CceCostValue -Item $message -Name 'lastModifiedDateTime')
            Major        = ("$(Get-CceCostValue -Item $message -Name 'isMajorChange')" -match '^(?i)(true|1)$')
            HasViewpoint = ($null -ne $viewpoint)
            Archived     = ("$(Get-CceCostValue -Item $viewpoint -Name 'isArchived')" -match '^(?i)(true|1)$')
            Read         = ("$(Get-CceCostValue -Item $viewpoint -Name 'isRead')" -match '^(?i)(true|1)$')
        })
    }

    $result.Ok = $true
    $result.Messages = @($messages)
    $result.Total = $raw.Count

    $Context.Cache['CostServiceMessages'] = $result
    $result
}

function Get-CceCostMessageState {
    <# Libelle de l'etat de traitement d'un message, selon le point de vue expose. #>
    [CmdletBinding()] param($Message)

    if (-not $Message.HasViewpoint) { return T 'c84.state.unknown' }
    if ($Message.Archived) { return T 'c84.state.archived' }
    if ($Message.Read) { return T 'c84.state.read' }
    T 'c84.state.new'
}

function Invoke-CceCheck84 {
    <# Veille du Message Center sur les changements Copilot a action requise #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $feed = Get-CceCostServiceMessage -Context $Context

    if (-not $feed.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c84.obs.ne') `
            -Evidence (T 'c84.ev.ne') `
            -Remediation (T 'c84.rem.ne')
    }

    $now = Get-Date
    $messages = @($feed.Messages)

    $actionable = @($messages | Where-Object { $null -ne $_.ActionBy })
    # Un message archive a ete traite : il ne compte plus comme un retard.
    $overdue = @($actionable | Where-Object { $_.ActionBy -lt $now -and -not $_.Archived })
    $soon = @($actionable | Where-Object {
        $_.ActionBy -ge $now -and ($_.ActionBy - $now).TotalDays -le $script:CceCostActionSoonDays -and -not $_.Archived
    })
    $major = @($messages | Where-Object {
        $_.Major -and -not $_.Archived -and
        ($null -eq $_.LastModified -or ($now - $_.LastModified).TotalDays -le $script:CceCostMajorReviewDays)
    })

    $evidence = [System.Collections.Generic.List[string]]::new()

    foreach ($message in (@($overdue) + @($soon) | Select-Object -First $script:CceCostEvidenceMax)) {
        $due = if ($null -ne $message.ActionBy) { $message.ActionBy.ToString('yyyy-MM-dd') } else { T 'c84.val.nodate' }
        $evidence.Add(((T 'c84.ev.action') -f $message.Id, $message.Title, $due, (Get-CceCostMessageState -Message $message)))
    }

    foreach ($message in ($major | Select-Object -First 10)) {
        $when = if ($null -ne $message.LastModified) { $message.LastModified.ToString('yyyy-MM-dd') } else { T 'c84.val.nodate' }
        $evidence.Add(((T 'c84.ev.major') -f $message.Id, $message.Title, $when))
    }

    if ($messages.Count -eq 0) { $evidence.Add(((T 'c84.ev.none') -f $feed.Total)) }

    $evidence.Add(((T 'c84.ev.summary') -f $feed.Total, $messages.Count, $actionable.Count, $overdue.Count, $soon.Count, $script:CceCostActionSoonDays, $major.Count, $script:CceCostMajorReviewDays))

    if (-not $feed.ServerFilter) { $evidence.Add((T 'c84.ev.clientfilter')) }
    if ($feed.Truncated) { $evidence.Add(((T 'c84.ev.truncated') -f $feed.Total)) }

    # Le point de vue (lu / archive) est propre au compte connecte et n'existe qu'en
    # delegue : sans lui, le moteur constate l'echeance sans savoir si elle est traitee.
    $withViewpoint = @($messages | Where-Object { $_.HasViewpoint }).Count
    $evidence.Add(((T 'c84.ev.viewpoint') -f $withViewpoint, $messages.Count))

    $proof = $evidence | ConvertTo-CceText -MaxItems 40

    if ($overdue.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c84.obs.ko') -f $overdue.Count, $messages.Count) `
            -Evidence $proof `
            -Remediation (T 'c84.rem.ko')
    }

    if ($soon.Count -gt 0 -or $major.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c84.obs.warn') -f $soon.Count, $script:CceCostActionSoonDays, $major.Count) `
            -Evidence $proof `
            -Remediation (T 'c84.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c84.obs.ok') -f $messages.Count, $actionable.Count) `
        -Evidence $proof
}
