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
        -Observed ("{0} label(s) de sensibilite actif(s) sur {1} defini(s)" -f $active.Count, @($labels).Count) `
        -Evidence ($active | Sort-Object Priority |
            ForEach-Object { "[$($_.Priority)] $($_.DisplayName ?? $_.Name)" } | ConvertTo-CceText) `
        -Remediation $(if ($active.Count -ge 3) { '' } else {
            "Creer au minimum 3 labels hierarchises (ex. Public / Interne / Confidentiel) : purview.microsoft.com > Protection des informations."
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
            -Observed 'Aucune strategie de publication de labels' `
            -Evidence "Get-LabelPolicy retourne 0 element : les labels ne sont visibles par aucun utilisateur." `
            -Remediation "Publier les labels vers les utilisateurs Copilot : purview.microsoft.com > Protection des informations > Strategies d'etiquette."
    }

    New-CceResult -Status 'Conforme' `
        -Observed ("{0} strategie(s) de publication de labels" -f $count) `
        -Evidence ($policies | ForEach-Object { "$($_.Name) : $(@($_.Labels) -join ', ')" } | ConvertTo-CceText)
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
            -Observed "Aucune strategie d'etiquetage automatique" `
            -Evidence "Get-AutoSensitivityLabelPolicy retourne 0 strategie exploitable." `
            -Remediation "Creer au moins une strategie d'auto-labeling (mode simulation accepte) : purview.microsoft.com > Protection des informations > Etiquetage automatique."
    }

    $enforcing = @($usable | Where-Object { "$($_.Mode)" -match 'Enable' })
    $status = if ($enforcing.Count -gt 0) { 'Conforme' } else { 'Attention' }

    New-CceResult -Status $status `
        -Observed ("{0} strategie(s) d'auto-labeling, dont {1} en application" -f $usable.Count, $enforcing.Count) `
        -Evidence ($usable | ForEach-Object { "$($_.Name) : mode = $($_.Mode)" } | ConvertTo-CceText) `
        -Remediation $(if ($status -eq 'Conforme') { '' } else { "Les strategies sont en simulation : les basculer en application apres validation des resultats." })
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
            -Observed 'Aucune politique DLP active' `
            -Evidence ("{0} politique(s) DLP definies, aucune active." -f @($policies).Count) `
            -Remediation "Creer une politique DLP couvrant Exchange, SharePoint, OneDrive et Teams : purview.microsoft.com > Protection contre la perte de donnees."
    }

    $required = @('Exchange', 'SharePoint', 'OneDrive', 'Teams')
    $covered = @()
    foreach ($w in $required) {
        if (@($enabled | Where-Object { "$($_.Workload)" -match $w }).Count -gt 0) { $covered += $w }
    }
    $missing = @($required | Where-Object { $_ -notin $covered })

    if ($missing.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("{0} politique(s) DLP active(s) couvrant les 4 workloads" -f $enabled.Count) `
            -Evidence ($enabled | ForEach-Object { "$($_.Name) : mode=$($_.Mode), workloads=$($_.Workload)" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed ("{0} politique(s) DLP active(s) - workload(s) non couvert(s) : {1}" -f $enabled.Count, ($missing -join ', ')) `
        -Evidence ($enabled | ForEach-Object { "$($_.Name) : mode=$($_.Mode), workloads=$($_.Workload)" } | ConvertTo-CceText) `
        -Remediation ("Etendre la couverture DLP aux workloads manquants : {0}." -f ($missing -join ', '))
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
            -Observed ("Aucune strategie de retention couvrant Copilot ({0} strategie(s) au total)" -f @($policies).Count) `
            -Evidence ($policies | ForEach-Object { "$($_.Name) : workloads=$($_.Workload)" } | ConvertTo-CceText) `
            -Remediation "Creer une strategie de retention incluant les interactions Copilot : purview.microsoft.com > Gestion du cycle de vie des donnees."
    }

    New-CceResult -Status 'Conforme' `
        -Observed ("{0} strategie(s) de retention couvrant Copilot" -f $copilot.Count) `
        -Evidence ($copilot | ForEach-Object { "$($_.Name) : active=$($_.Enabled), workloads=$($_.Workload)" } | ConvertTo-CceText)
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
            -Observed "Aucune strategie de retention d'audit personnalisee (retention par defaut appliquee)" `
            -Evidence "Get-UnifiedAuditLogRetentionPolicy retourne 0 element. Par defaut : 180 jours (E5) ou 180 jours (E3, Audit standard)." `
            -Remediation "Creer une strategie de retention d'audit d'au moins 90 jours (365 recommande avec E5) : purview.microsoft.com > Audit > Strategies de retention."
    }

    $lines = @($policies | ForEach-Object { "$($_.Name) : $($_.RetentionDuration), priorite $($_.Priority)" })
    $tooShort = @($policies | Where-Object {
        $d = $durationDays["$($_.RetentionDuration)"]
        $null -ne $d -and $d -lt 90
    })

    New-CceResult -Status $(if ($tooShort.Count -eq 0) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ("{0} strategie(s) de retention d'audit : {1}" -f @($policies).Count, ($lines -join ' | ')) `
        -Evidence ($lines | ConvertTo-CceText) `
        -Remediation $(if ($tooShort.Count -eq 0) { '' } else {
            ("Allonger la retention des strategies suivantes a 90 jours minimum : {0}." -f (($tooShort.Name) -join ', '))
        })
}

function Invoke-CceCheck58 {
    <# Configurer eDiscovery pour les donnees Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Test fonctionnel eDiscovery requis' `
        -Evidence "La capacite a rechercher et exporter les interactions Copilot se valide par un cas de test reel." `
        -Remediation "Creer un cas eDiscovery de test, rechercher les interactions Copilot d'un utilisateur pilote et valider l'export : purview.microsoft.com > eDiscovery."
}

function Invoke-CceCheck59 {
    <# Activer Microsoft Purview Data Access Governance pour SharePoint #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Rapport DAG a executer' `
        -Evidence "Les rapports de gouvernance d'acces aux donnees ne sont pas exposes par cmdlet." `
        -Remediation "Executer les rapports DAG (partage excessif, liens partages) et traiter les sites remontes : purview.microsoft.com > Gouvernance de l'acces aux donnees."
}
