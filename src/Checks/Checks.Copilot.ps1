#Requires -Version 7.0
<# Controles 33 a 42 - ACTIVATION ET CONFIGURATION COPILOT #>

function Get-CceCopilotUsageReport {
    <#
    .SYNOPSIS
        Rapport d'usage Copilot par utilisateur (30 jours).
    .DESCRIPTION
        Seule source tenant permettant de constater qu'un workload Copilot est
        reellement actif : les bascules du centre d'administration Copilot ne sont
        pas exposees par une API publique.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotUsage')) { return $Context.Cache['CopilotUsage'] }
    if (-not $Context.Services.Graph) { return $null }

    $response = Invoke-CceGraphRequest -Quiet `
        -Uri "https://graph.microsoft.com/beta/reports/getMicrosoft365CopilotUsageUserDetail(period='D30')?`$format=application/json"

    $rows = if ($response) { @($response.value) } else { $null }
    $Context.Cache['CopilotUsage'] = $rows
    $rows
}

function Get-CceCopilotAdminSetting {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotAdminSettings')) { return $Context.Cache['CopilotAdminSettings'] }
    if (-not $Context.Services.Graph) { return $null }

    $settings = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/beta/copilot/admin/settings'
    $Context.Cache['CopilotAdminSettings'] = $settings
    $settings
}

function Get-CceWorkloadActivity {
    <#
    .SYNOPSIS
        Compte les utilisateurs ayant une activite Copilot par application sur 30 jours.
    #>
    [CmdletBinding()] param($Rows)

    $map = [ordered]@{
        'Copilot Chat' = 'copilotChatLastActivityDate'
        'Teams'        = 'microsoftTeamsCopilotLastActivityDate'
        'Word'         = 'wordCopilotLastActivityDate'
        'Excel'        = 'excelCopilotLastActivityDate'
        'PowerPoint'   = 'powerPointCopilotLastActivityDate'
        'Outlook'      = 'outlookCopilotLastActivityDate'
        'OneNote'      = 'oneNoteCopilotLastActivityDate'
        'Loop'         = 'loopCopilotLastActivityDate'
    }

    $result = [ordered]@{}
    foreach ($entry in $map.GetEnumerator()) {
        $count = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace("$($_.($entry.Value))") }).Count
        $result[$entry.Key] = $count
    }
    $result
}

function Invoke-CceCheck33 {
    <# Activer Copilot globalement au niveau du tenant #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context
    $settings = Get-CceCopilotAdminSetting -Context $Context

    $evidenceParts = [System.Collections.Generic.List[string]]::new()
    if ($settings) { $evidenceParts.Add("beta/copilot/admin/settings : " + ($settings | ConvertTo-Json -Depth 4 -Compress)) }

    if ($null -ne $rows) {
        $active = @($rows | Where-Object {
            $_.PSObject.Properties.Name -match 'LastActivityDate' -and
            @($_.PSObject.Properties | Where-Object { $_.Name -match 'LastActivityDate' -and -not [string]::IsNullOrWhiteSpace("$($_.Value)") }).Count -gt 0
        })

        $evidenceParts.Add("Rapport d'usage Copilot (30 j) : $($rows.Count) utilisateur(s) remontes, $($active.Count) avec au moins une activite.")

        if ($active.Count -gt 0) {
            return New-CceResult -Status 'Conforme' `
                -Observed ("Copilot operationnel : {0} utilisateur(s) actif(s) sur 30 jours" -f $active.Count) `
                -Evidence ($evidenceParts | ConvertTo-CceText)
        }

        return New-CceResult -Status 'Attention' `
            -Observed ("Aucune activite Copilot sur 30 jours ({0} utilisateur(s) dans le rapport)" -f $rows.Count) `
            -Evidence ($evidenceParts | ConvertTo-CceText) `
            -Remediation "Verifier l'activation dans admin.cloud.microsoft > Parametres > Copilot, puis confirmer avec un utilisateur pilote."
    }

    New-CceResult -Status 'Manuel' `
        -Observed "Bascule tenant non exposee par API" `
        -Evidence (($evidenceParts + "Le rapport d'usage Copilot n'a pas repondu (droits Reports.Read.All ou aucune donnee).") | ConvertTo-CceText) `
        -Remediation "Verifier manuellement : admin.cloud.microsoft > Parametres > Copilot."
}

function Invoke-CceCheck34 {
    <# Activer tous les workloads Copilot #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Manuel' `
            -Observed 'Etat des workloads non exposee par API' `
            -Evidence "Le rapport d'usage Copilot n'est pas disponible." `
            -Remediation "Verifier chaque workload dans admin.cloud.microsoft > Parametres > Copilot."
    }

    $activity = Get-CceWorkloadActivity -Rows $rows
    $core = @('Word', 'Excel', 'PowerPoint', 'Outlook', 'Teams')
    $silent = @($core | Where-Object { $activity[$_] -eq 0 })
    $observed = ($activity.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '

    if ($silent.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("Activite constatee sur tous les workloads cles : {0}" -f $observed) `
            -Evidence ($activity.GetEnumerator() | ForEach-Object { "$($_.Key) : $($_.Value) utilisateur(s) actif(s) sur 30 j" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed ("Aucune activite sur : {0} ({1})" -f ($silent -join ', '), $observed) `
        -Evidence (($activity.GetEnumerator() | ForEach-Object { "$($_.Key) : $($_.Value) utilisateur(s) actif(s) sur 30 j" }) +
                   @("Une activite nulle peut traduire un workload desactive ou simplement non adopte.") | ConvertTo-CceText) `
        -Remediation "Confirmer l'activation des workloads sans activite dans admin.cloud.microsoft > Parametres > Copilot avant de conclure a un defaut d'adoption."
}

function Invoke-CceCheck35 {
    <# Activer Copilot Chat (Microsoft 365 Chat) #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Manuel' `
            -Observed 'Etat de Copilot Chat non exposee par API' `
            -Evidence "Rapport d'usage indisponible." `
            -Remediation "Tester copilot.microsoft.com avec un utilisateur licencie."
    }

    $chatUsers = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace("$($_.copilotChatLastActivityDate)") })

    if ($chatUsers.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("{0} utilisateur(s) actif(s) sur Copilot Chat (30 j)" -f $chatUsers.Count) `
            -Evidence ($chatUsers | Select-Object -First 15 |
                ForEach-Object { "$($_.userPrincipalName) : $($_.copilotChatLastActivityDate)" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed ("Aucune activite Copilot Chat sur 30 jours ({0} utilisateur(s) dans le rapport)" -f $rows.Count) `
        -Evidence "Aucune valeur copilotChatLastActivityDate renseignee." `
        -Remediation "Verifier l'acces a copilot.microsoft.com avec un utilisateur licencie et l'activation de Microsoft 365 Chat."
}

function Invoke-CceCheck36 {
    <# Acces au contenu web et source de donnees Copilot Chat #>
    [CmdletBinding()] param($Context)

    $settings = Get-CceCopilotAdminSetting -Context $Context

    New-CceResult -Status 'Manuel' `
        -Observed "Decision de gouvernance a documenter" `
        -Evidence ($(if ($settings) { "beta/copilot/admin/settings : " + ($settings | ConvertTo-Json -Depth 4 -Compress) } else { "Aucun parametre Copilot lisible via Graph." })) `
        -Remediation "Trancher et documenter : Copilot Chat limite aux donnees M365 ou etendu au web. Portail : admin.cloud.microsoft > Copilot > Contenu web."
}

function Invoke-CceCheck37 {
    <# Verifier la propagation de Copilot sur un utilisateur test #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Manuel' `
            -Observed 'Test fonctionnel requis' `
            -Evidence "Rapport d'usage indisponible : la propagation ne peut pas etre constatee a distance." `
            -Remediation "Ouvrir Word, Outlook et Teams avec un utilisateur licencie et verifier la presence du bouton Copilot."
    }

    $active = @($rows | Where-Object {
        @($_.PSObject.Properties | Where-Object { $_.Name -match 'LastActivityDate' -and -not [string]::IsNullOrWhiteSpace("$($_.Value)") }).Count -gt 0
    })

    if ($active.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("Propagation confirmee : {0} utilisateur(s) ont utilise Copilot sur 30 jours" -f $active.Count) `
            -Evidence ($active | Select-Object -First 10 | ForEach-Object { $_.userPrincipalName } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed 'Aucune utilisation constatee : propagation non confirmee' `
        -Evidence ("{0} utilisateur(s) licencie(s) remontes, aucun avec activite." -f $rows.Count) `
        -Remediation "Effectuer un test manuel avec un utilisateur licencie (delai de propagation possible jusqu'a 72 h apres attribution)."
}

function Invoke-CceCheck38 {
    <# Activer et consulter les rapports d'utilisation Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Non conforme' `
            -Observed "Rapports d'utilisation Copilot inaccessibles" `
            -Evidence "L'appel a getMicrosoft365CopilotUsageUserDetail a echoue (droits Reports.Read.All manquants ou rapports desactives)." `
            -Remediation "Accorder Reports.Read.All et verifier que l'anonymisation des rapports n'empeche pas l'analyse : admin.cloud.microsoft > Parametres > Rapports."
    }

    $anonymised = @($rows | Where-Object { "$($_.userPrincipalName)" -match '^[A-F0-9]{40,}$' }).Count

    if ($anonymised -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ("Rapports accessibles mais anonymises ({0} lignes)" -f $rows.Count) `
            -Evidence "Les identifiants utilisateurs sont masques : le suivi nominatif d'adoption est impossible." `
            -Remediation "Desactiver l'anonymisation : admin.cloud.microsoft > Parametres > Parametres de l'organisation > Rapports."
    }

    New-CceResult -Status 'Conforme' `
        -Observed ("Rapports d'utilisation Copilot accessibles : {0} ligne(s) sur 30 jours" -f $rows.Count) `
        -Evidence "Endpoint getMicrosoft365CopilotUsageUserDetail(period='D30') interroge avec succes."
}

function Invoke-CceCheck39 {
    <# Configurer Viva Insights pour le suivi d'adoption Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Tableau de bord Viva Insights a verifier' `
        -Evidence "Le tableau de bord d'adoption Copilot de Viva Insights n'expose pas d'API d'etat." `
        -Remediation "Ouvrir insights.viva.office.com > Copilot dashboard et confirmer la presence de donnees."
}

function Invoke-CceCheck40 {
    <# Configurer la generation d'images Copilot (Designer) #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Decision de gouvernance a documenter' `
        -Evidence "Bascule non exposee par API publique." `
        -Remediation "Trancher et documenter le choix : admin.cloud.microsoft > Copilot > Parametres > Generation d'images."
}

function Invoke-CceCheck41 {
    <# Configurer Copilot dans Bing, Microsoft Edge et Windows #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Decision de gouvernance a documenter' `
        -Evidence "Bascule non exposee par API publique." `
        -Remediation "Aligner le parametre sur la politique de l'organisation : admin.cloud.microsoft > Copilot > Parametres > Copilot dans Bing, Edge et Windows."
}

function Invoke-CceCheck42 {
    <# Configurer la clause d'exclusion de responsabilite IA Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Clause de responsabilite IA a verifier' `
        -Evidence "Parametre non expose par API publique." `
        -Remediation "Activer et valider le libelle : admin.cloud.microsoft > Copilot > Parametres > Clause d'exclusion de responsabilite."
}
