#Requires -Version 7.0
<# Controles 43 a 51 - AGENTS, PLUGINS ET GOUVERNANCE COPILOT #>

function Invoke-CceCheck43 {
    <# Restreindre la creation d'agents Copilot aux administrateurs #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed "Parametre de gouvernance non expose par API" `
        -Evidence "Le perimetre de creation d'agents se pilote depuis le centre d'administration Copilot, sans cmdlet publique." `
        -Remediation "Restreindre la creation d'agents a un groupe dedie : admin.cloud.microsoft > Copilot > Agents."
}

function Invoke-CceCheck44 {
    <# Definir qui peut publier des agents dans l'organisation #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed "Parametre de gouvernance non expose par API" `
        -Evidence "La delegation de publication d'agents n'est pas lisible par script." `
        -Remediation "Limiter la publication aux administrateurs ou a un groupe designe : admin.cloud.microsoft > Copilot > Agents."
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
            -Observed 'Inventaire des applications non lisible' `
            -Evidence "L'appel servicePrincipals a echoue (droits Application.Read.All)." `
            -Remediation "Auditer les applications integrees : admin.cloud.microsoft > Parametres > Applications integrees."
    }

    $apps = @($response.value)
    $thirdParty = @($apps | Where-Object {
        "$($_.publisherName)" -notmatch 'Microsoft' -and @($_.tags) -contains 'WindowsAzureActiveDirectoryIntegratedApp'
    })

    New-CceResult -Status $(if ($thirdParty.Count -eq 0) { 'Conforme' } else { 'Attention' }) `
        -Observed ("{0} application(s) tierce(s) integree(s) sur {1} principal(aux) de service actifs" -f $thirdParty.Count, $apps.Count) `
        -Evidence ($thirdParty | Select-Object -First 25 |
            ForEach-Object { "$($_.displayName) - editeur : $($_.publisherName)" } | ConvertTo-CceText -MaxItems 25) `
        -Remediation $(if ($thirdParty.Count -eq 0) { '' } else {
            "Passer en revue ces applications et desactiver celles qui ne sont pas explicitement approuvees : admin.cloud.microsoft > Parametres > Applications integrees."
        })
}

function Invoke-CceCheck46 {
    <# Controler les connecteurs Microsoft Graph autorises #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $response = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/v1.0/external/connections'

    if (-not $response) {
        return New-CceResult -Status 'Manuel' `
            -Observed 'Connecteurs Graph non lisibles' `
            -Evidence "L'appel external/connections a echoue (droit ExternalConnection.Read.All requis)." `
            -Remediation "Auditer les connecteurs : admin.cloud.microsoft > Recherche et intelligence > Connecteurs de donnees."
    }

    $connections = @($response.value)

    if ($connections.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed 'Aucun connecteur Microsoft Graph actif' `
            -Evidence "external/connections retourne 0 element : aucune source externe n'alimente l'index Copilot."
    }

    New-CceResult -Status 'Attention' `
        -Observed ("{0} connecteur(s) Microsoft Graph actif(s) a valider" -f $connections.Count) `
        -Evidence ($connections | ForEach-Object { "$($_.name) ($($_.id)) - etat : $($_.state)" } | ConvertTo-CceText) `
        -Remediation "Faire valider chaque connecteur par l'equipe securite : leur contenu devient interrogeable par Copilot."
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
            -Observed "Recherche dans le journal d'audit impossible" `
            -Evidence "Search-UnifiedAuditLog a echoue : role 'Journaux d'audit avec affichage seul' requis." `
            -Remediation "Attribuer le role d'audit puis relancer, ou verifier via purview.microsoft.com > Audit."
    }

    $count = @($records).Count

    if ($count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("{0} interaction(s) Copilot journalisee(s) sur 7 jours" -f $count) `
            -Evidence ($records | Select-Object -First 10 |
                ForEach-Object { "$($_.CreationDate) - $($_.UserIds) - $($_.Operations)" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed 'Aucune interaction Copilot dans le journal d''audit sur 7 jours' `
        -Evidence "Le journal repond mais ne contient aucun enregistrement CopilotInteraction : audit recemment active ou aucun usage." `
        -Remediation "Confirmer que l'audit unifie est actif (controle 26) puis reverifier apres une utilisation reelle de Copilot."
}

function Invoke-CceCheck48 {
    <# Etablir une convention de nommage pour les agents #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Livrable documentaire' `
        -Evidence "Aucune source technique : depend d'un document interne." `
        -Remediation "Formaliser une convention de nommage des agents et la publier aux equipes."
}

function Invoke-CceCheck49 {
    <# Creer un processus d'approbation pour les nouveaux agents #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Livrable organisationnel' `
        -Evidence "Aucune source technique : depend d'un processus interne." `
        -Remediation "Definir et outiller un circuit d'approbation avant publication d'un agent."
}

function Invoke-CceCheck50 {
    <# Documenter une politique d'usage des agents Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Livrable documentaire' `
        -Evidence "Aucune source technique : depend d'un document interne." `
        -Remediation "Rediger, publier et communiquer la politique d'usage des agents Copilot."
}

function Invoke-CceCheck51 {
    <# Revue periodique des agents deployes (trimestrielle) #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Rituel de gouvernance' `
        -Evidence "Aucune source technique : depend d'un rituel planifie." `
        -Remediation "Planifier une revue trimestrielle des agents deployes et en conserver la trace."
}
