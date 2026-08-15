#Requires -Version 7.0
<# Controles 1 a 5 - LICENCES COPILOT #>

$script:CceBaseSkuPattern = 'SPE_E3|SPE_E5|SPE_F|ENTERPRISEPACK|ENTERPRISEPREMIUM|Microsoft_365_E3|Microsoft_365_E5|SPB|O365_BUSINESS_PREMIUM'

function Invoke-CceCheck01 {
    <# Licence M365 E3/E5 ou Business Premium attribuee aux utilisateurs cibles #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $base = Get-CceSubscribedSku -Context $Context |
        Where-Object { $_.SkuPartNumber -match $script:CceBaseSkuPattern -and $_.ConsumedUnits -gt 0 }

    if (-not $base) {
        return New-CceResult -Status 'Non conforme' `
            -Observed 'Aucun SKU E3 / E5 / Business Premium avec des licences attribuees' `
            -Evidence (Get-CceSubscribedSku -Context $Context |
                ForEach-Object { "$($_.SkuPartNumber) : $($_.ConsumedUnits) attribuee(s)" } | ConvertTo-CceText) `
            -Remediation "Acquerir et attribuer une licence M365 E3, E5 ou Business Premium aux utilisateurs cibles Copilot."
    }

    $detail = $base | ForEach-Object { "$($_.SkuPartNumber) : $($_.ConsumedUnits)/$($_.PrepaidUnits.Enabled) attribuee(s)" }

    New-CceResult -Status 'Conforme' `
        -Observed ($detail -join ' | ') `
        -Evidence ($detail | ConvertTo-CceText)
}

function Invoke-CceCheck02 {
    <# SKU Microsoft 365 Copilot achete et visible sur le tenant #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $copilot = Get-CceCopilotSku -Context $Context

    if (-not $copilot) {
        return New-CceResult -Status 'Non conforme' `
            -Observed 'Aucun SKU Copilot present sur le tenant' `
            -Evidence 'Aucun SkuPartNumber correspondant a *COPILOT* dans Get-MgSubscribedSku.' `
            -Remediation "Acheter l'abonnement Microsoft 365 Copilot depuis admin.cloud.microsoft > Facturation > Services d'achat."
    }

    $lines = $copilot | ForEach-Object {
        $available = $_.PrepaidUnits.Enabled - $_.ConsumedUnits
        "$($_.SkuPartNumber) : $($_.ConsumedUnits)/$($_.PrepaidUnits.Enabled) utilisee(s), $available disponible(s)"
    }

    $totalAvailable = ($copilot | ForEach-Object { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } | Measure-Object -Sum).Sum

    if ($totalAvailable -le 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ("SKU Copilot present mais 0 licence disponible ({0})" -f ($lines -join ' | ')) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation "Toutes les licences Copilot sont consommees : prevoir des unites supplementaires avant d'onboarder de nouveaux utilisateurs."
    }

    New-CceResult -Status 'Conforme' -Observed ($lines -join ' | ') -Evidence ($lines | ConvertTo-CceText)
}

function Invoke-CceCheck03 {
    <# Licence Copilot attribuee individuellement ou via groupe #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context

    if (-not $users -or $users.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed '0 utilisateur porteur d''une licence Copilot' `
            -Evidence 'Aucun utilisateur ne possede de licence Copilot assignee.' `
            -Remediation "Attribuer la licence Copilot aux utilisateurs cibles (de preference via un groupe Entra ID)."
    }

    $enabled = @($users | Where-Object { $_.AccountEnabled })

    New-CceResult -Status 'Conforme' `
        -Observed ("{0} utilisateur(s) licencie(s) Copilot, dont {1} compte(s) actif(s)" -f $users.Count, $enabled.Count) `
        -Evidence ($users | Select-Object -First 25 |
            ForEach-Object { "$($_.UserPrincipalName) (actif=$($_.AccountEnabled), type=$($_.UserType))" } | ConvertTo-CceText -MaxItems 25)
}

function Invoke-CceCheck04 {
    <# Attribution des licences via groupe Entra ID (pas manuelle) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $skuIds = Get-CceCopilotSkuId -Context $Context
    if (-not $skuIds -or $skuIds.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed 'Aucun SKU Copilot : attribution par groupe impossible' `
            -Remediation "Acheter le SKU Copilot puis creer un groupe de licence dedie."
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($skuId in $skuIds) {
        $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=assignedLicenses/any(x:x/skuId eq $skuId)&`$select=id,displayName,assignedLicenses"
        $response = Invoke-CceGraphRequest -Uri $uri
        foreach ($g in @($response.value)) { $groups.Add($g) }
    }

    if ($groups.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed "Aucun groupe Entra ID ne porte la licence Copilot (attribution manuelle)" `
            -Evidence "Aucun groupe ne possede la licence Copilot dans assignedLicenses." `
            -Remediation "Creer un groupe de securite (ex. GRP-Copilot-Users) et lui affecter la licence Copilot, puis retirer les attributions individuelles."
    }

    New-CceResult -Status 'Conforme' `
        -Observed ("{0} groupe(s) porteur(s) de la licence Copilot : {1}" -f $groups.Count, (($groups.displayName) -join ', ')) `
        -Evidence ($groups | ForEach-Object { "$($_.displayName) ($($_.id))" } | ConvertTo-CceText)
}

function Invoke-CceCheck05 {
    <# L'abonnement Copilot n'expire pas dans les 60 jours #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $response = Invoke-CceGraphRequest -Uri 'https://graph.microsoft.com/beta/directory/subscriptions' -Quiet
    $subs = @($response.value) | Where-Object { "$($_.skuPartNumber)" -like (Get-CceCopilotSkuPattern) }

    if (-not $subs -or $subs.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' `
            -Observed "Cycle de vie de l'abonnement Copilot non lisible via Graph" `
            -Evidence "L'endpoint beta/directory/subscriptions n'a rien retourne (droits insuffisants ou abonnement absent)." `
            -Remediation "Verifier manuellement : admin.cloud.microsoft > Facturation > Vos produits > Microsoft 365 Copilot."
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $worst = 'Conforme'

    foreach ($s in $subs) {
        $next = if ($s.nextLifecycleDateTime) { [datetime] $s.nextLifecycleDateTime } else { $null }
        $days = if ($next) { [int] ($next - (Get-Date)).TotalDays } else { $null }
        $auto = $s.isAutoRenewEnabled

        $lines.Add(("{0} : statut={1}, renouvellement auto={2}, prochaine echeance={3} ({4} jour(s))" -f `
            $s.skuPartNumber, $s.status, $auto, ($(if ($next) { $next.ToString('yyyy-MM-dd') } else { 'n/a' })), ($days ?? 'n/a')))

        if ($auto -eq $false) { $worst = 'Non conforme' }
        elseif ($null -ne $days -and $days -lt 60 -and $worst -ne 'Non conforme') { $worst = 'Attention' }
    }

    $remediation = switch ($worst) {
        'Non conforme' { "Reactiver le renouvellement automatique : admin.cloud.microsoft > Facturation > Vos produits > Microsoft 365 Copilot." }
        'Attention'    { "Echeance a moins de 60 jours : declencher le processus de renouvellement aupres des achats." }
        default        { '' }
    }

    New-CceResult -Status $worst -Observed ($lines -join ' | ') -Evidence ($lines | ConvertTo-CceText) -Remediation $remediation
}
