#Requires -Version 7.0
<# Controles 43 a 51 - AGENTS, PLUGINS ET GOUVERNANCE COPILOT #>

function Invoke-CceCheck43 {
    <# Restreindre la creation d'agents Copilot aux administrateurs #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c43.obs.manual') `
        -Evidence (T 'c43.ev.manual') `
        -Remediation (T 'c43.rem.manual')
}

function Invoke-CceCheck44 {
    <# Definir qui peut publier des agents dans l'organisation #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c44.obs.manual') `
        -Evidence (T 'c44.ev.manual') `
        -Remediation (T 'c44.rem.manual')
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

    $apps = @($response.value)
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

function Invoke-CceCheck46 {
    <# Controler les connecteurs Microsoft Graph autorises #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $response = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/v1.0/external/connections'

    if (-not $response) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c46.obs.error') `
            -Evidence (T 'c46.ev.error') `
            -Remediation (T 'c46.rem.error')
    }

    $connections = @($response.value)

    if ($connections.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c46.obs.none') `
            -Evidence (T 'c46.ev.none')
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c46.obs.ko') -f $connections.Count) `
        -Evidence ($connections | ForEach-Object { (T 'c46.ev.line') -f $_.name, $_.id, $_.state } | ConvertTo-CceText) `
        -Remediation (T 'c46.rem.ko')
}

function Invoke-CceCheck47 {
    <# Activer l'audit des interactions avec les agents Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $start = (Get-Date).AddDays(-7)
    $end = Get-Date

    $records = Get-CceSafe {
        Search-UnifiedAuditLog -RecordType CopilotInteraction -StartDate $start -EndDate $end -ResultSize 50 -ErrorAction Stop
    } -What 'Search-UnifiedAuditLog (CopilotInteraction)'

    if ($null -eq $records) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c47.obs.na') `
            -Evidence (T 'c47.ev.na') `
            -Remediation (T 'c47.rem.na')
    }

    $count = @($records).Count

    if ($count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c47.obs.ok') -f $count) `
            -Evidence ($records | Select-Object -First 10 |
                ForEach-Object { (T 'c47.ev.line') -f $_.CreationDate, $_.UserIds, $_.Operations } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed (T 'c47.obs.none') `
        -Evidence (T 'c47.ev.none') `
        -Remediation (T 'c47.rem.none')
}

function Invoke-CceCheck48 {
    <# Etablir une convention de nommage pour les agents #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c48.obs.manual') `
        -Evidence (T 'c48.ev.manual') `
        -Remediation (T 'c48.rem.manual')
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
    <# Revue periodique des agents deployes (trimestrielle) #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c51.obs.manual') `
        -Evidence (T 'c51.ev.manual') `
        -Remediation (T 'c51.rem.manual')
}
