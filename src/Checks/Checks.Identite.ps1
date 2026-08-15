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
            -Observed (T 'c10.obs.none') `
            -Evidence (T 'c10.ev.none') `
            -Remediation (T 'c10.rem.none')
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
            -Observed ((T 'c10.obs.nomfa') -f $enabledCount) `
            -Evidence ($policies | ForEach-Object { "$($_.displayName) [$($_.state)]" } | ConvertTo-CceText) `
            -Remediation (T 'c10.rem.nomfa')
    }

    $coversAllUsers = @($mfaPolicies | Where-Object {
        @($_.conditions.users.includeUsers) -contains 'All'
    }).Count -gt 0

    $status = if ($coversAllUsers) { 'Conforme' } else { 'Attention' }
    $observed = (T 'c10.obs.ok') -f $mfaPolicies.Count, $enabledCount
    if (-not $coversAllUsers) { $observed += (T 'c10.obs.scopewarn') }

    New-CceResult -Status $status `
        -Observed $observed `
        -Evidence ($mfaPolicies | ForEach-Object {
            "$($_.displayName) | users=$(@($_.conditions.users.includeUsers) -join ',') | apps=$(@($_.conditions.applications.includeApplications) -join ',') | controls=$(@($_.grantControls.builtInControls) -join ',')"
        } | ConvertTo-CceText) `
        -Remediation $(if ($coversAllUsers) { '' } else { (T 'c10.rem.scopewarn') })
}

function Invoke-CceCheck11 {
    <# Aucune strategie CA ne bloque Microsoft Graph #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $policies = Get-CceConditionalAccessPolicy -Context $Context
    $blocking = @($policies | Where-Object { Test-CcePolicyBlocks -Policy $_ -AppIds @($script:CceGraphAppId, 'All') })

    if ($blocking.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c11.obs.ok') `
            -Evidence ((T 'c11.ev.ok') -f @($policies).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c11.obs.ko') -f $blocking.Count) `
        -Evidence ($blocking | ForEach-Object {
            "$($_.displayName) | users=$(@($_.conditions.users.includeUsers) -join ',') | apps=$(@($_.conditions.applications.includeApplications) -join ',') | exclusions=$(@($_.conditions.users.excludeGroups) -join ',')"
        } | ConvertTo-CceText) `
        -Remediation (T 'c11.rem.ko')
}

function Invoke-CceCheck12 {
    <# Aucune CA policy ne bloque Office 365 #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $policies = Get-CceConditionalAccessPolicy -Context $Context
    $blocking = @($policies | Where-Object { Test-CcePolicyBlocks -Policy $_ -AppIds $script:CceOfficeAppIds })

    if ($blocking.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c12.obs.ok') `
            -Evidence ((T 'c12.ev.ok') -f @($policies).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c12.obs.ko') -f $blocking.Count) `
        -Evidence ($blocking | ForEach-Object {
            (T 'c12.ev.line') -f $_.displayName, (@($_.conditions.applications.includeApplications) -join ','), (@($_.conditions.platforms.includePlatforms) -join ',')
        } | ConvertTo-CceText) `
        -Remediation (T 'c12.rem.ko')
}

function Invoke-CceCheck13 {
    <# UPN des utilisateurs = adresse email principale (pas .local) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context
    $scope = (T 'c13.obs.scopecopilot')

    if (-not $users -or $users.Count -eq 0) {
        $users = Get-CceSafe {
            Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AccountEnabled, UserType -ErrorAction Stop
        } -What 'Get-MgUser (tous)'
        $scope = (T 'c13.obs.scopeall')
    }

    $bad = @($users | Where-Object { $_.UserPrincipalName -match '\.local$|\.internal$|\.lan$|onmicrosoft\.com$' -and $_.UserPrincipalName -notmatch '#EXT#' })
    $nonRoutable = @($bad | Where-Object { $_.UserPrincipalName -match '\.local$|\.internal$|\.lan$' })

    if ($nonRoutable.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c13.obs.ko') -f $nonRoutable.Count, $scope) `
            -Evidence ($nonRoutable | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
            -Remediation (T 'c13.rem.ko')
    }

    $onmicrosoft = @($bad | Where-Object { $_.UserPrincipalName -match 'onmicrosoft\.com$' })
    if ($onmicrosoft.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c13.obs.warn') -f $onmicrosoft.Count, $scope) `
            -Evidence ($onmicrosoft | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
            -Remediation (T 'c13.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c13.obs.ok') -f $scope, @($users).Count) `
        -Evidence ((T 'c13.ev.ok') -f $scope)
}

function Invoke-CceCheck14 {
    <# Retirer les licences Copilot des comptes desactives #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context
    $disabled = @($users | Where-Object { -not $_.AccountEnabled })

    if ($disabled.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c14.obs.ok') `
            -Evidence ((T 'c14.ev.ok') -f @($users).Count)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c14.obs.ko') -f $disabled.Count) `
        -Evidence ($disabled | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation (T 'c14.rem.ko')
}

function Invoke-CceCheck15 {
    <# Retirer les licences Copilot des comptes invites (B2B) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context
    $guests = @($users | Where-Object { "$($_.UserType)" -eq 'Guest' })

    if ($guests.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c15.obs.ok') `
            -Evidence ((T 'c15.ev.ok') -f @($users).Count)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c15.obs.ko') -f $guests.Count) `
        -Evidence ($guests | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation (T 'c15.rem.ko')
}
