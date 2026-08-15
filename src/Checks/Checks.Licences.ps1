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
            -Observed (T 'c01.obs.none') `
            -Evidence (Get-CceSubscribedSku -Context $Context |
                ForEach-Object { (T 'c01.ev.line') -f $_.SkuPartNumber, $_.ConsumedUnits } | ConvertTo-CceText) `
            -Remediation (T 'c01.rem.none')
    }

    $detail = $base | ForEach-Object { (T 'c01.obs.line') -f $_.SkuPartNumber, $_.ConsumedUnits, $_.PrepaidUnits.Enabled }

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

function Invoke-CceCheck03 {
    <# Licence Copilot attribuee individuellement ou via groupe #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = Get-CceCopilotUser -Context $Context

    if (-not $users -or $users.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c03.obs.none') `
            -Evidence (T 'c03.ev.none') `
            -Remediation (T 'c03.rem.none')
    }

    $enabled = @($users | Where-Object { $_.AccountEnabled })

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c03.obs.ok') -f $users.Count, $enabled.Count) `
        -Evidence ($users | Select-Object -First 25 |
            ForEach-Object { (T 'c03.ev.line') -f $_.UserPrincipalName, $_.AccountEnabled, $_.UserType } | ConvertTo-CceText -MaxItems 25)
}

function Invoke-CceCheck04 {
    <# Attribution des licences via groupe Entra ID (pas manuelle) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $skuIds = Get-CceCopilotSkuId -Context $Context
    if (-not $skuIds -or $skuIds.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c04.obs.none') `
            -Remediation (T 'c04.rem.none')
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($skuId in $skuIds) {
        $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=assignedLicenses/any(x:x/skuId eq $skuId)&`$select=id,displayName,assignedLicenses"
        $response = Invoke-CceGraphRequest -Uri $uri
        foreach ($g in @($response.value)) { $groups.Add($g) }
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
    $subs = @($response.value) | Where-Object { "$($_.skuPartNumber)" -like (Get-CceCopilotSkuPattern) }

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
