#Requires -Version 7.0
<# Controles 52 a 59 - SECURITE ET PROTECTION DES DONNEES #>

function Invoke-CceCheck52 {
    <# Configurer les labels de sensibilite (minimum 3 niveaux) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $labels = Get-CceSafe { Get-Label -ErrorAction Stop } -What 'Get-Label'
    if ($null -eq $labels) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $active = @($labels | Where-Object { -not $_.Disabled })

    New-CceResult -Status $(if ($active.Count -ge 3) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ((T 'c52.obs.main') -f $active.Count, @($labels).Count) `
        -Evidence ($active | Sort-Object Priority |
            ForEach-Object { (T 'c52.ev.line') -f $_.Priority, ($_.DisplayName ?? $_.Name) } | ConvertTo-CceText) `
        -Remediation $(if ($active.Count -ge 3) { '' } else {
            (T 'c52.rem.ko')
        })
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
    <# Politiques DLP couvrant les 4 workloads #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSafe { Get-DlpCompliancePolicy -ErrorAction Stop } -What 'Get-DlpCompliancePolicy'
    if ($null -eq $policies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $enabled = @($policies | Where-Object { $_.Enabled -and "$($_.Mode)" -notmatch 'Disable' })

    if ($enabled.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c55.obs.none') `
            -Evidence ((T 'c55.ev.none') -f @($policies).Count) `
            -Remediation (T 'c55.rem.none')
    }

    $required = @('Exchange', 'SharePoint', 'OneDrive', 'Teams')
    $covered = @()
    foreach ($w in $required) {
        if (@($enabled | Where-Object { "$($_.Workload)" -match $w }).Count -gt 0) { $covered += $w }
    }
    $missing = @($required | Where-Object { $_ -notin $covered })

    if ($missing.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c55.obs.ok') -f $enabled.Count) `
            -Evidence ($enabled | ForEach-Object { (T 'c55.ev.line') -f $_.Name, $_.Mode, $_.Workload } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c55.obs.partial') -f $enabled.Count, ($missing -join ', ')) `
        -Evidence ($enabled | ForEach-Object { (T 'c55.ev.line') -f $_.Name, $_.Mode, $_.Workload } | ConvertTo-CceText) `
        -Remediation ((T 'c55.rem.partial') -f ($missing -join ', '))
}

function Invoke-CceCheck56 {
    <# Retention des interactions Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSafe { Get-RetentionCompliancePolicy -ErrorAction Stop } -What 'Get-RetentionCompliancePolicy'
    if ($null -eq $policies) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $copilot = @($policies | Where-Object { "$($_.Workload)" -match 'Copilot|TeamsChat|MicrosoftCopilot' })

    if ($copilot.Count -eq 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c56.obs.none') -f @($policies).Count) `
            -Evidence ($policies | ForEach-Object { (T 'c56.ev.lineall') -f $_.Name, $_.Workload } | ConvertTo-CceText) `
            -Remediation (T 'c56.rem.none')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c56.obs.ok') -f $copilot.Count) `
        -Evidence ($copilot | ForEach-Object { (T 'c56.ev.line') -f $_.Name, $_.Enabled, $_.Workload } | ConvertTo-CceText)
}

function Invoke-CceCheck57 {
    <# Retention des logs d'audit (>= 90 jours) #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Purview -Context $Context)) { return New-CceNotEvaluated -Service Purview -Context $Context }

    $policies = Get-CceSafe { Get-UnifiedAuditLogRetentionPolicy -ErrorAction Stop } -What 'Get-UnifiedAuditLogRetentionPolicy'

    $durationDays = @{
        'ThreeMonths' = 90; 'SixMonths' = 180; 'NineMonths' = 270
        'TwelveMonths' = 365; 'OneYear' = 365; 'TenYears' = 3650
    }

    if ($null -eq $policies -or @($policies).Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed (T 'c57.obs.none') `
            -Evidence (T 'c57.ev.none') `
            -Remediation (T 'c57.rem.none')
    }

    $lines = @($policies | ForEach-Object { (T 'c57.ev.line') -f $_.Name, $_.RetentionDuration, $_.Priority })
    $tooShort = @($policies | Where-Object {
        $d = $durationDays["$($_.RetentionDuration)"]
        $null -ne $d -and $d -lt 90
    })

    New-CceResult -Status $(if ($tooShort.Count -eq 0) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ((T 'c57.obs.main') -f @($policies).Count, ($lines -join ' | ')) `
        -Evidence ($lines | ConvertTo-CceText) `
        -Remediation $(if ($tooShort.Count -eq 0) { '' } else {
            ((T 'c57.rem.ko') -f (($tooShort.Name) -join ', '))
        })
}

function Invoke-CceCheck58 {
    <# Configurer eDiscovery pour les donnees Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c58.obs.manual') `
        -Evidence (T 'c58.ev.manual') `
        -Remediation (T 'c58.rem.manual')
}

function Invoke-CceCheck59 {
    <# Activer Microsoft Purview Data Access Governance pour SharePoint #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c59.obs.manual') `
        -Evidence (T 'c59.ev.manual') `
        -Remediation (T 'c59.rem.manual')
}
