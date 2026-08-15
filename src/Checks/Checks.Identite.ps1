#Requires -Version 7.0
<# Controles 10 a 15 - IDENTITE ET ACCES CONDITIONNEL #>

$script:CceGraphAppId    = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
$script:CceOfficeAppIds  = @(
    'Office365'
    '00000002-0000-0ff1-ce00-000000000000'  # Exchange Online
    '00000003-0000-0ff1-ce00-000000000000'  # SharePoint Online
    'All'
)

function Test-CcePolicyBlocks {
    <#
    .SYNOPSIS
        Determine si une strategie CA activee bloque un ensemble d'applications donne.
    #>
    [CmdletBinding()]
    param($Policy, [string[]] $AppIds)

    if ("$($Policy.state)" -ne 'enabled') { return $false }

    $controls = @($Policy.grantControls.builtInControls)
    if ($controls -notcontains 'block') { return $false }

    $included = @($Policy.conditions.applications.includeApplications)
    foreach ($app in $AppIds) {
        if ($included -contains $app) { return $true }
    }
    return $false
}

function Invoke-CceCheck10 {
    <# MFA activee pour tous les utilisateurs Copilot via Acces conditionnel #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $policies = Get-CceConditionalAccessPolicy -Context $Context
    if (-not $policies -or $policies.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed 'Aucune strategie d''acces conditionnel sur le tenant' `
            -Evidence 'identity/conditionalAccess/policies retourne 0 element.' `
            -Remediation "Creer une strategie d'acces conditionnel exigeant le MFA pour les utilisateurs Copilot."
    }

    $mfaPolicies = @($policies | Where-Object {
        "$($_.state)" -eq 'enabled' -and (
            (@($_.grantControls.builtInControls) -contains 'mfa') -or
            ($null -ne $_.grantControls.authenticationStrength)
        )
    })

    $enabledCount = @($policies | Where-Object { "$($_.state)" -eq 'enabled' }).Count

    if ($mfaPolicies.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ("{0} strategie(s) activee(s), aucune n'exige le MFA" -f $enabledCount) `
            -Evidence ($policies | ForEach-Object { "$($_.displayName) [$($_.state)]" } | ConvertTo-CceText) `
            -Remediation "Creer une strategie CA exigeant le MFA (ou une force d'authentification) pour le groupe des utilisateurs Copilot."
    }

    $coversAllUsers = @($mfaPolicies | Where-Object {
        @($_.conditions.users.includeUsers) -contains 'All'
    }).Count -gt 0

    $status = if ($coversAllUsers) { 'Conforme' } else { 'Attention' }
    $observed = "{0} strategie(s) MFA activee(s) sur {1} strategie(s) actives" -f $mfaPolicies.Count, $enabledCount
    if (-not $coversAllUsers) { $observed += ' - perimetre cible (groupes) a valider' }

    New-CceResult -Status $status `
        -Observed $observed `
        -Evidence ($mfaPolicies | ForEach-Object {
            "$($_.displayName) | users=$(@($_.conditions.users.includeUsers) -join ',') | apps=$(@($_.conditions.applications.includeApplications) -join ',') | controls=$(@($_.grantControls.builtInControls) -join ',')"
        } | ConvertTo-CceText) `
        -Remediation $(if ($coversAllUsers) { '' } else { "Verifier que le groupe des utilisateurs Copilot est bien inclus dans le perimetre d'au moins une strategie MFA." })
}

function Invoke-CceCheck11 {
    <# Aucune strategie CA ne bloque Microsoft Graph #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $policies = Get-CceConditionalAccessPolicy -Context $Context
    $blocking = @($policies | Where-Object { Test-CcePolicyBlocks -Policy $_ -AppIds @($script:CceGraphAppId, 'All') })

    if ($blocking.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed 'Aucune strategie activee ne bloque Microsoft Graph' `
            -Evidence ("{0} strategie(s) analysee(s), aucune avec un controle 'block' sur Graph ou sur toutes les applications." -f @($policies).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ("{0} strategie(s) de blocage susceptibles d'impacter Microsoft Graph" -f $blocking.Count) `
        -Evidence ($blocking | ForEach-Object {
            "$($_.displayName) | users=$(@($_.conditions.users.includeUsers) -join ',') | apps=$(@($_.conditions.applications.includeApplications) -join ',') | exclusions=$(@($_.conditions.users.excludeGroups) -join ',')"
        } | ConvertTo-CceText) `
        -Remediation "Executer l'outil What If (entra.microsoft.com > Acces conditionnel > What If) pour un utilisateur Copilot et l'application Microsoft Graph, puis exclure le groupe Copilot si necessaire."
}

function Invoke-CceCheck12 {
    <# Aucune CA policy ne bloque Office 365 #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $policies = Get-CceConditionalAccessPolicy -Context $Context
    $blocking = @($policies | Where-Object { Test-CcePolicyBlocks -Policy $_ -AppIds $script:CceOfficeAppIds })

    if ($blocking.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed 'Aucune strategie activee ne bloque Office 365 / Exchange / SharePoint' `
            -Evidence ("{0} strategie(s) analysee(s)." -f @($policies).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ("{0} strategie(s) de blocage sur Office 365 / Exchange / SharePoint" -f $blocking.Count) `
        -Evidence ($blocking | ForEach-Object {
            "$($_.displayName) | apps=$(@($_.conditions.applications.includeApplications) -join ',') | plateformes=$(@($_.conditions.platforms.includePlatforms) -join ',')"
        } | ConvertTo-CceText) `
        -Remediation "Valider via What If que les utilisateurs Copilot accedent bien a Office 365, Exchange Online et SharePoint Online."
}

function Invoke-CceCheck13 {
    <# UPN des utilisateurs = adresse email principale (pas .local) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context
    $scope = 'utilisateurs Copilot'

    if (-not $users -or $users.Count -eq 0) {
        $users = Get-CceSafe {
            Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AccountEnabled, UserType -ErrorAction Stop
        } -What 'Get-MgUser (tous)'
        $scope = 'tous les utilisateurs'
    }

    $bad = @($users | Where-Object { $_.UserPrincipalName -match '\.local$|\.internal$|\.lan$|onmicrosoft\.com$' -and $_.UserPrincipalName -notmatch '#EXT#' })
    $nonRoutable = @($bad | Where-Object { $_.UserPrincipalName -match '\.local$|\.internal$|\.lan$' })

    if ($nonRoutable.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ("{0} UPN non routable(s) (.local/.internal/.lan) sur {1}" -f $nonRoutable.Count, $scope) `
            -Evidence ($nonRoutable | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
            -Remediation "Ajouter un suffixe UPN routable dans AD DS puis reaffecter les UPN concernes avant la synchronisation."
    }

    $onmicrosoft = @($bad | Where-Object { $_.UserPrincipalName -match 'onmicrosoft\.com$' })
    if ($onmicrosoft.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ("{0} UPN en .onmicrosoft.com sur {1}" -f $onmicrosoft.Count, $scope) `
            -Evidence ($onmicrosoft | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
            -Remediation "Aligner l'UPN sur le domaine de messagerie principal pour eviter les incoherences d'identite dans Copilot."
    }

    New-CceResult -Status 'Conforme' `
        -Observed ("Aucun UPN non routable detecte ({0} : {1} compte(s))" -f $scope, @($users).Count) `
        -Evidence "Controle des suffixes .local / .internal / .lan / .onmicrosoft.com sur $scope."
}

function Invoke-CceCheck14 {
    <# Retirer les licences Copilot des comptes desactives #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context
    $disabled = @($users | Where-Object { -not $_.AccountEnabled })

    if ($disabled.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed '0 compte desactive porteur d''une licence Copilot' `
            -Evidence ("{0} utilisateur(s) licencie(s) analyses." -f @($users).Count)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ("{0} compte(s) desactive(s) consomment une licence Copilot" -f $disabled.Count) `
        -Evidence ($disabled | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation "Retirer la licence Copilot de ces comptes (ou les sortir du groupe de licence) pour liberer les unites."
}

function Invoke-CceCheck15 {
    <# Retirer les licences Copilot des comptes invites (B2B) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context
    $guests = @($users | Where-Object { "$($_.UserType)" -eq 'Guest' })

    if ($guests.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed '0 invite porteur d''une licence Copilot' `
            -Evidence ("{0} utilisateur(s) licencie(s) analyses." -f @($users).Count)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ("{0} compte(s) invite(s) consomment une licence Copilot" -f $guests.Count) `
        -Evidence ($guests | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation "Retirer la licence Copilot des comptes invites : Copilot n'est pas supporte pour les identites B2B."
}
