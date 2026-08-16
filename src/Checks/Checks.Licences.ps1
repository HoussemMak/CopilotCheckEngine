#Requires -Version 7.0
<# Controles 1 a 5 - LICENCES COPILOT #>

# Conserve pour compatibilite : ce filtre historique ne reconnaissait que M365 E3/E5,
# Office 365 E3/E5 et Business Premium. Il est remplace par la table officielle
# ci-dessous, qui couvre l'integralite des plans de base eligibles a Copilot.
$script:CceBaseSkuPattern = 'SPE_E3|SPE_E5|SPE_F|ENTERPRISEPACK|ENTERPRISEPREMIUM|Microsoft_365_E3|Microsoft_365_E5|SPB|O365_BUSINESS_PREMIUM'

<#
    Plans de base eligibles au module complementaire Microsoft 365 Copilot.

    La liste officielle 2026 depasse tres largement M365 E3/E5/Business Premium :
    Microsoft 365 E3/E5/E7/F1/F3/A1/A3/A5/Business/Apps, Office 365 E1/E3/E5/F3/A1/A3/A5,
    Teams (Essentials, Enterprise, EEA, Rooms), Exchange Kiosk/Plan 1/Plan 2, SharePoint,
    OneDrive, Planner/Project, Visio et Clipchamp, plus les declinaisons gouvernementales.

    Le moteur raisonne sur le SkuPartNumber, identifiant produit documente et stable :
    assignedLicenses ne porte que le skuId, et subscribedSkus fournit la correspondance
    skuId -> SkuPartNumber propre au tenant. La table combine une liste d'identifiants
    exacts et des motifs de famille, pour absorber les variantes (EEA sans Teams, GCC,
    DoD, declinaisons Faculty/Student, nouveaux libelles Microsoft_365_*).
#>
$script:CceEligibleBaseSkuName = @(
    # Microsoft 365 - entreprise, frontline, gouvernement
    'SPE_E3', 'SPE_E5', 'SPE_F1', 'M365_F1', 'M365_F1_COMM',
    'SPE_E3_USGOV_GCCHIGH', 'SPE_E3_USGOV_DOD', 'SPE_E5_USGOV_GCCHIGH', 'SPE_E5_USGOV_DOD',
    # Microsoft 365 - education
    'M365EDU_A1', 'M365EDU_A3_FACULTY', 'M365EDU_A3_STUDENT', 'M365EDU_A3_STUUSEBNFT',
    'M365EDU_A5_FACULTY', 'M365EDU_A5_STUDENT', 'M365EDU_A5_STUUSEBNFT',
    # Microsoft 365 - PME et applications
    'SPB', 'O365_BUSINESS', 'O365_BUSINESS_ESSENTIALS', 'O365_BUSINESS_PREMIUM',
    'SMB_BUSINESS', 'SMB_BUSINESS_ESSENTIALS', 'SMB_BUSINESS_PREMIUM', 'OFFICESUBSCRIPTION',
    # Office 365
    'STANDARDPACK', 'ENTERPRISEPACK', 'ENTERPRISEPREMIUM', 'DESKLESSPACK',
    'STANDARDPACK_GOV', 'ENTERPRISEPACK_GOV', 'ENTERPRISEPREMIUM_GOV', 'DESKLESSPACK_GOV',
    'ENTERPRISEPACK_FACULTY', 'ENTERPRISEPACK_STUDENT',
    'ENTERPRISEPREMIUM_FACULTY', 'ENTERPRISEPREMIUM_STUDENT',
    'STANDARDWOFFPACK_FACULTY', 'STANDARDWOFFPACK_STUDENT',
    'STANDARDWOFFPACK_IW_FACULTY', 'STANDARDWOFFPACK_IW_STUDENT',
    # Microsoft Teams
    'TEAMS_ESSENTIALS_AAD', 'Teams_Ess', 'MEETING_ROOM',
    'Microsoft_Teams_Rooms_Basic', 'Microsoft_Teams_Rooms_Pro',
    'Microsoft_Teams_Enterprise', 'Microsoft_Teams_Enterprise_New', 'Microsoft_Teams_EEA_New',
    # Exchange Online / SharePoint / OneDrive
    'EXCHANGEDESKLESS', 'EXCHANGESTANDARD', 'EXCHANGEENTERPRISE',
    'EXCHANGESTANDARD_GOV', 'EXCHANGEENTERPRISE_GOV',
    'SHAREPOINTDESKLESS', 'SHAREPOINTSTANDARD', 'SHAREPOINTENTERPRISE',
    'SHAREPOINTSTANDARD_GOV', 'SHAREPOINTENTERPRISE_GOV',
    'WACONEDRIVESTANDARD', 'WACONEDRIVEENTERPRISE',
    # Planner / Project / Visio / Clipchamp
    'PLANNER_PLAN1', 'PROJECTESSENTIALS', 'PROJECTPROFESSIONAL', 'PROJECTPREMIUM',
    'PROJECT_P1', 'PROJECT_PLAN1', 'PROJECT_PLAN3', 'PROJECT_PLAN5',
    'VISIOONLINE_PLAN1', 'VISIOCLIENT', 'VISIO_PLAN1_DEPT', 'VISIO_PLAN2_DEPT',
    'CLIPCHAMP', 'CLIPCHAMP_PREMIUM', 'Microsoft_Clipchamp'
)

$script:CceEligibleBaseSkuPattern = @(
    '^Microsoft_365_E[3-7]',                        # E3 / E5 / E7, y compris variantes EEA et "no Teams"
    '^Microsoft_365_F[13]',
    '^Microsoft_365_A[135]',
    '^Microsoft_365_G[35]',
    '^Microsoft_365_(Business|Apps)',
    '^SPE_(E3|E5|E7|F1)',
    '^M365(EDU)?_(E[357]|F[13]|A[135]|G[35])',
    '^Office_365_(E[135]|F3|A[135]|G[135])',
    '^Microsoft_Teams_(Enterprise|EEA|Rooms|Essentials)',
    '^Teams_(Ess|Rooms)',
    '^Exchange_Online_(Kiosk|Plan)',
    '^(SharePoint|OneDrive)_(Plan|Kiosk)',
    '^(Planner|Project)_Plan',
    '^Visio_(Plan|P[12])',
    '^Microsoft_Clipchamp'
)

function Get-CceLicenceValue {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete : Graph renvoie tantot des objets, tantot des
        dictionnaires, et le mode strict interdit l'acces a une propriete absente.
    #>
    [CmdletBinding()] param($InputObject, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function Get-CceSkuSummary {
    <# Vue normalisee d'un abonnement : nom, identifiant, unites consommees et achetees. #>
    [CmdletBinding()] param($Sku)

    $prepaid = Get-CceLicenceValue -InputObject $Sku -Name 'PrepaidUnits'

    [pscustomobject]@{
        Name     = "$(Get-CceLicenceValue -InputObject $Sku -Name 'SkuPartNumber')"
        Id       = "$(Get-CceLicenceValue -InputObject $Sku -Name 'SkuId')"
        Consumed = [int] (Get-CceLicenceValue -InputObject $Sku -Name 'ConsumedUnits')
        Enabled  = [int] (Get-CceLicenceValue -InputObject $prepaid -Name 'Enabled')
    }
}

function Test-CceEligibleBaseSku {
    <#
    .SYNOPSIS
        Vrai si le SkuPartNumber figure parmi les plans de base eligibles a Copilot.
    #>
    [CmdletBinding()] param([string] $SkuPartNumber)

    if ([string]::IsNullOrWhiteSpace($SkuPartNumber)) { return $false }
    $name = $SkuPartNumber.Trim()

    # Le module complementaire Copilot n'est jamais son propre plan de base.
    if ($name -like (Get-CceCopilotSkuPattern)) { return $false }

    if ($script:CceEligibleBaseSkuName -contains $name) { return $true }

    foreach ($pattern in $script:CceEligibleBaseSkuPattern) {
        if ($name -match $pattern) { return $true }
    }

    $false
}

function Get-CceSkuNameMap {
    <#
    .SYNOPSIS
        Correspondance skuId -> SkuPartNumber du tenant.
    .DESCRIPTION
        assignedLicenses ne transporte que le skuId : la table de subscribedSkus est la
        seule source exacte pour le traduire, et elle ne peut pas devenir obsolete.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SkuNameMap')) { return $Context.Cache['SkuNameMap'] }

    $map = @{}
    foreach ($sku in @(Get-CceSubscribedSku -Context $Context)) {
        $summary = Get-CceSkuSummary -Sku $sku
        if ($summary.Id) { $map[$summary.Id.ToLowerInvariant()] = $summary.Name }
    }

    $Context.Cache['SkuNameMap'] = $map
    $map
}

function Get-CceUserSkuName {
    <# SkuPartNumber detenus par un utilisateur, resolus depuis assignedLicenses. #>
    [CmdletBinding()] param($User, $Map)

    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($licence in @(Get-CceLicenceValue -InputObject $User -Name 'AssignedLicenses')) {
        $id = "$(Get-CceLicenceValue -InputObject $licence -Name 'SkuId')"
        if (-not $id) { continue }

        $key = $id.ToLowerInvariant()
        if ($Map.ContainsKey($key)) { $names.Add($Map[$key]) } else { $names.Add($id) }
    }

    @($names | Sort-Object -Unique)
}

function Invoke-CceCheck01 {
    <# Plan de base eligible a Copilot detenu par chaque utilisateur licencie Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $summaries = @(foreach ($sku in @(Get-CceSubscribedSku -Context $Context)) { Get-CceSkuSummary -Sku $sku })

    # Aucun abonnement lisible : c'est un defaut de droits, pas un ecart de configuration.
    if ($summaries.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c01.obs.noskus') `
            -Evidence (T 'c01.ev.noskus') `
            -Remediation (T 'c01.rem.noskus')
    }

    $eligible = @($summaries | Where-Object { Test-CceEligibleBaseSku -SkuPartNumber $_.Name })
    $consumed = @($eligible | Where-Object { $_.Consumed -gt 0 })

    $users = @(Get-CceCopilotUser -Context $Context)

    # --- Cas 1 : aucune licence Copilot encore attribuee (audit d'avant-projet).
    # Le controle se rabat sur le tenant : au moins un plan de base eligible est-il attribue ?
    if ($users.Count -eq 0) {
        if ($consumed.Count -eq 0) {
            return New-CceResult -Status 'Non conforme' `
                -Observed (T 'c01.obs.none') `
                -Evidence ($summaries | ForEach-Object { (T 'c01.ev.line') -f $_.Name, $_.Consumed } | ConvertTo-CceText) `
                -Remediation (T 'c01.rem.none')
        }

        $detail = $consumed | ForEach-Object { (T 'c01.obs.line') -f $_.Name, $_.Consumed, $_.Enabled }

        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c01.obs.tenant') -f $consumed.Count, ($detail -join ' | ')) `
            -Evidence ($detail | ConvertTo-CceText)
    }

    # --- Cas 2 : des sieges Copilot sont attribues, on croise au niveau utilisateur.
    $map = Get-CceSkuNameMap -Context $Context
    $missing = [System.Collections.Generic.List[object]]::new()
    $holders = [System.Collections.Generic.List[object]]::new()

    foreach ($user in $users) {
        $names = @(Get-CceUserSkuName -User $user -Map $map)
        $base = @($names | Where-Object { Test-CceEligibleBaseSku -SkuPartNumber $_ })

        $entry = [pscustomobject]@{
            Upn  = "$(Get-CceLicenceValue -InputObject $user -Name 'UserPrincipalName')"
            All  = $names
            Base = $base
        }

        if ($base.Count -eq 0) { $missing.Add($entry) } else { $holders.Add($entry) }
    }

    if ($missing.Count -gt 0) {
        $lines = foreach ($entry in $missing) {
            $held = if ($entry.All.Count -gt 0) { $entry.All -join ', ' } else { T 'c01.val.nosku' }
            (T 'c01.ev.ko.line') -f $entry.Upn, $held
        }

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c01.obs.ko') -f $missing.Count, $users.Count) `
            -Evidence ($lines | ConvertTo-CceText -MaxItems 25) `
            -Remediation (T 'c01.rem.ko')
    }

    $families = @($holders | ForEach-Object { $_.Base } | Sort-Object -Unique)
    $evidence = $holders | Select-Object -First 25 | ForEach-Object { (T 'c01.ev.ok.line') -f $_.Upn, ($_.Base -join ', ') }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c01.obs.ok') -f $users.Count, ($families -join ', ')) `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 25)
}

function Invoke-CceCheck02 {
    <# SKU Microsoft 365 Copilot achete et visible sur le tenant #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $copilot = @(Get-CceCopilotSku -Context $Context)

    if (-not $copilot) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c02.obs.none') `
            -Evidence (T 'c02.ev.none') `
            -Remediation (T 'c02.rem.none')
    }

    $lines = $copilot | ForEach-Object {
        $available = $_.PrepaidUnits.Enabled - $_.ConsumedUnits
        (T 'c02.obs.line') -f $_.SkuPartNumber, $_.ConsumedUnits, $_.PrepaidUnits.Enabled, $available
    }

    $totalAvailable = ($copilot | ForEach-Object { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } | Measure-Object -Sum).Sum

    if ($totalAvailable -le 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c02.obs.warn') -f ($lines -join ' | ')) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c02.rem.warn')
    }

    New-CceResult -Status 'Conforme' -Observed ($lines -join ' | ') -Evidence ($lines | ConvertTo-CceText)
}

function Get-CceCopilotServicePlan {
    <#
    .SYNOPSIS
        Plans de service Copilot portes par chaque SKU Copilot du tenant, indexes par skuId.
    .DESCRIPTION
        subscribedSkus expose la composition de chaque abonnement : c'est la reference qui
        permet de savoir quels identifiants de plan sont susceptibles de figurer dans
        assignedLicenses[].disabledPlans cote utilisateur.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotServicePlans')) { return $Context.Cache['CopilotServicePlans'] }

    $index = @{}

    foreach ($sku in @(Get-CceCopilotSku -Context $Context)) {
        $skuId = "$(Get-CceLicenceValue -InputObject $sku -Name 'SkuId')"
        if (-not $skuId) { continue }

        $plans = [System.Collections.Generic.List[object]]::new()
        foreach ($plan in @(Get-CceLicenceValue -InputObject $sku -Name 'ServicePlans')) {
            $name = "$(Get-CceLicenceValue -InputObject $plan -Name 'ServicePlanName')"
            if ($name -notlike (Get-CceCopilotSkuPattern)) { continue }

            $plans.Add([pscustomobject]@{
                Id   = "$(Get-CceLicenceValue -InputObject $plan -Name 'ServicePlanId')".ToLowerInvariant()
                Name = $name
            })
        }

        $index[$skuId.ToLowerInvariant()] = @($plans)
    }

    $Context.Cache['CopilotServicePlans'] = $index
    $index
}

function Get-CceCopilotProvisioningSample {
    <#
    .SYNOPSIS
        Etat de provisionnement des plans Copilot sur un echantillon d'utilisateurs.
    .DESCRIPTION
        provisioningStatus n'existe que dans licenseDetails, qui se lit utilisateur par
        utilisateur : l'echantillon (25 par defaut, -CopilotLicenseSampleSize pour l'elargir)
        borne le cout de la collecte. Lecture seule stricte.
    #>
    [CmdletBinding()] param($Context, $Users)

    $size = 25
    if ($Context.Config -is [System.Collections.IDictionary] -and $Context.Config.Contains('CopilotLicenseSampleSize')) {
        $configured = [int] $Context.Config['CopilotLicenseSampleSize']
        if ($configured -gt 0) { $size = $configured }
    }

    $sample = @(@($Users | Where-Object { $_.AccountEnabled }) | Select-Object -First $size)
    if ($sample.Count -eq 0) { $sample = @(@($Users) | Select-Object -First $size) }

    $pending = [System.Collections.Generic.List[object]]::new()
    $checked = 0

    foreach ($user in $sample) {
        $id = "$(Get-CceLicenceValue -InputObject $user -Name 'Id')"
        if (-not $id) { continue }

        $response = Invoke-CceGraphRequest -Uri "https://graph.microsoft.com/v1.0/users/$id/licenseDetails" -Quiet
        if ($null -eq $response) { continue }
        $checked++

        foreach ($detail in @(Get-CceLicenceValue -InputObject $response -Name 'value')) {
            $skuName = "$(Get-CceLicenceValue -InputObject $detail -Name 'skuPartNumber')"
            if ($skuName -notlike (Get-CceCopilotSkuPattern)) { continue }

            foreach ($plan in @(Get-CceLicenceValue -InputObject $detail -Name 'servicePlans')) {
                $planName = "$(Get-CceLicenceValue -InputObject $plan -Name 'servicePlanName')"
                if ($planName -notlike (Get-CceCopilotSkuPattern)) { continue }

                $status = "$(Get-CceLicenceValue -InputObject $plan -Name 'provisioningStatus')"
                if ($status -match '^Pending') {
                    $pending.Add([pscustomobject]@{
                        Upn    = "$(Get-CceLicenceValue -InputObject $user -Name 'UserPrincipalName')"
                        Plan   = $planName
                        Status = $status
                    })
                }
            }
        }
    }

    [pscustomobject]@{
        Checked = $checked
        Pending = @($pending)
    }
}

function Invoke-CceCheck03 {
    <# Licence Copilot attribuee ET plan de service Copilot reellement provisionne #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = @(Get-CceCopilotUser -Context $Context)

    if ($users.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c03.obs.none') `
            -Evidence (T 'c03.ev.none') `
            -Remediation (T 'c03.rem.none')
    }

    $enabled = @($users | Where-Object { $_.AccountEnabled })
    $planIndex = Get-CceCopilotServicePlan -Context $Context

    # --- Plans desactives a l'attribution (disabledPlans) : analyse sur 100% des porteurs.
    $fullyDisabled = [System.Collections.Generic.List[object]]::new()
    $partlyDisabled = [System.Collections.Generic.List[object]]::new()

    foreach ($user in $users) {
        $off = [System.Collections.Generic.List[string]]::new()
        $total = 0

        foreach ($licence in @(Get-CceLicenceValue -InputObject $user -Name 'AssignedLicenses')) {
            $skuId = "$(Get-CceLicenceValue -InputObject $licence -Name 'SkuId')".ToLowerInvariant()
            if (-not $planIndex.ContainsKey($skuId)) { continue }

            $disabled = @(@(Get-CceLicenceValue -InputObject $licence -Name 'DisabledPlans') | ForEach-Object { "$_".ToLowerInvariant() })

            foreach ($plan in $planIndex[$skuId]) {
                $total++
                if ($disabled -contains $plan.Id) { $off.Add($plan.Name) }
            }
        }

        if ($total -eq 0 -or $off.Count -eq 0) { continue }

        $entry = [pscustomobject]@{
            Upn   = "$(Get-CceLicenceValue -InputObject $user -Name 'UserPrincipalName')"
            Plans = ($off -join ', ')
        }

        if ($off.Count -eq $total) { $fullyDisabled.Add($entry) } else { $partlyDisabled.Add($entry) }
    }

    # --- Etat de provisionnement (provisioningStatus) : echantillon borne.
    $sample = Get-CceCopilotProvisioningSample -Context $Context -Users $users
    $pendingUsers = @($sample.Pending | Select-Object -ExpandProperty Upn -Unique)

    $status = 'Conforme'
    $segments = [System.Collections.Generic.List[string]]::new()
    $remedies = [System.Collections.Generic.List[string]]::new()
    $evidence = [System.Collections.Generic.List[string]]::new()

    $segments.Add(((T 'c03.obs.ok') -f $users.Count, $enabled.Count))

    if ($fullyDisabled.Count -gt 0) {
        $status = 'Non conforme'
        $segments.Add(((T 'c03.obs.ko.disabled') -f $fullyDisabled.Count, $users.Count))
        $remedies.Add((T 'c03.rem.disabled'))
        foreach ($entry in $fullyDisabled) { $evidence.Add(((T 'c03.ev.disabled') -f $entry.Upn, $entry.Plans)) }
    }

    if ($partlyDisabled.Count -gt 0) {
        if ($status -eq 'Conforme') { $status = 'Attention' }
        $segments.Add(((T 'c03.obs.warn.partial') -f $partlyDisabled.Count, $users.Count))
        $remedies.Add((T 'c03.rem.partial'))
        foreach ($entry in $partlyDisabled) { $evidence.Add(((T 'c03.ev.partial') -f $entry.Upn, $entry.Plans)) }
    }

    if ($pendingUsers.Count -gt 0) {
        if ($status -eq 'Conforme') { $status = 'Attention' }
        $segments.Add(((T 'c03.obs.warn.pending') -f $pendingUsers.Count, $sample.Checked))
        $remedies.Add((T 'c03.rem.pending'))
        foreach ($entry in $sample.Pending) { $evidence.Add(((T 'c03.ev.pending') -f $entry.Upn, $entry.Plan, $entry.Status)) }
    }

    if ($status -eq 'Conforme') {
        $segments.Add(((T 'c03.obs.ok.plans') -f $sample.Checked))
        foreach ($user in @($users | Select-Object -First 15)) {
            $evidence.Add(((T 'c03.ev.line') -f $user.UserPrincipalName, $user.AccountEnabled, $user.UserType))
        }
    }

    $evidence.Add(((T 'c03.ev.coverage') -f $users.Count, $sample.Checked))

    New-CceResult -Status $status `
        -Observed ($segments -join ' | ') `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation ($remedies -join ' ')
}

function Invoke-CceCheck04 {
    <# Attribution des licences via groupe Entra ID (pas manuelle) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $skuIds = @(Get-CceCopilotSkuId -Context $Context)
    if (-not $skuIds -or $skuIds.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c04.obs.none') `
            -Remediation (T 'c04.rem.none')
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    $queried = 0

    foreach ($skuId in $skuIds) {
        $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=assignedLicenses/any(x:x/skuId eq $skuId)&`$select=id,displayName,assignedLicenses"
        $response = Invoke-CceGraphRequest -Uri $uri

        # Une requete en echec renvoie $null : sans ce garde-fou, la lecture de .value
        # leve sous Set-StrictMode Latest, et surtout une panne de lecture serait prise
        # pour une absence de groupe, donc pour un ecart avere.
        if ($null -eq $response -or -not $response.PSObject.Properties['value']) { continue }

        $queried++
        foreach ($g in (Get-CceResponseValue $response)) { $groups.Add($g) }
    }

    if ($queried -eq 0) {
        return New-CceNotEvaluated -Service Graph -Context $Context
    }

    if ($groups.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c04.obs.ko') `
            -Evidence (T 'c04.ev.ko') `
            -Remediation (T 'c04.rem.ko')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c04.obs.ok') -f $groups.Count, (($groups.displayName) -join ', ')) `
        -Evidence ($groups | ForEach-Object { "$($_.displayName) ($($_.id))" } | ConvertTo-CceText)
}

function Invoke-CceCheck05 {
    <# L'abonnement Copilot n'expire pas dans les 60 jours #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $response = Invoke-CceGraphRequest -Uri 'https://graph.microsoft.com/beta/directory/subscriptions' -Quiet
    $subs = (Get-CceResponseValue $response) | Where-Object { "$($_.skuPartNumber)" -like (Get-CceCopilotSkuPattern) }

    if (-not $subs -or $subs.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c05.obs.na') `
            -Evidence (T 'c05.ev.na') `
            -Remediation (T 'c05.rem.na')
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $worst = 'Conforme'

    foreach ($s in $subs) {
        $next = if ($s.nextLifecycleDateTime) { [datetime] $s.nextLifecycleDateTime } else { $null }
        $days = if ($next) { [int] ($next - (Get-Date)).TotalDays } else { $null }
        $auto = $s.isAutoRenewEnabled

        $lines.Add(((T 'c05.obs.line') -f `
            $s.skuPartNumber, $s.status, $auto, ($(if ($next) { $next.ToString('yyyy-MM-dd') } else { 'n/a' })), ($days ?? 'n/a')))

        if ($auto -eq $false) { $worst = 'Non conforme' }
        elseif ($null -ne $days -and $days -lt 60 -and $worst -ne 'Non conforme') { $worst = 'Attention' }
    }

    $remediation = switch ($worst) {
        'Non conforme' { T 'c05.rem.ko' }
        'Attention'    { T 'c05.rem.warn' }
        default        { '' }
    }

    New-CceResult -Status $worst -Observed ($lines -join ' | ') -Evidence ($lines | ConvertTo-CceText) -Remediation $remediation
}
