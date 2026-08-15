#Requires -Version 7.0
<# Controles 6 a 9 - APPLICATIONS ET AUTHENTIFICATION #>

function Get-CceOfficeLocalConfiguration {
    <#
    .SYNOPSIS
        Lit la configuration Office du poste courant (canal de mise a jour, produit).
        Utilise uniquement lorsque -IncludeLocalChecks est demande.
    #>
    [CmdletBinding()] param()

    if (-not $IsWindows) { return $null }

    $key = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (-not (Test-Path $key)) { return $null }

    $cfg = Get-CceSafe { Get-ItemProperty -Path $key -ErrorAction Stop } -What 'registre ClickToRun'
    if (-not $cfg) { return $null }

    $channelMap = @{
        '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
        '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
        '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
        'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Current Channel (Preview)'
        'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'Semi-Annual Enterprise Channel (Preview)'
    }

    $channel = 'Inconnu'
    foreach ($guid in $channelMap.Keys) {
        if ("$($cfg.CDNBaseUrl)" -match $guid) { $channel = $channelMap[$guid]; break }
    }

    [pscustomobject]@{
        ProductIds    = $cfg.ProductReleaseIds
        Channel       = $channel
        CdnBaseUrl    = $cfg.CDNBaseUrl
        Version       = $cfg.VersionToReport
        Platform      = $cfg.Platform
    }
}

function Invoke-CceCheck06 {
    <# Microsoft 365 Apps for Enterprise deploye sur les postes #>
    [CmdletBinding()] param($Context)

    $local = if ($Context.Config.IncludeLocalChecks) { Get-CceOfficeLocalConfiguration } else { $null }

    if ($local) {
        # Seuls O365ProPlusRetail / O365BusinessRetail correspondent a Microsoft 365 Apps ;
        # les ProductIds *Volume designent Office 2019/2021, incompatibles avec Copilot.
        $status = if ("$($local.ProductIds)" -match 'O365ProPlusRetail|O365BusinessRetail') { 'Conforme' } else { 'Non conforme' }

        return New-CceResult -Status $status `
            -Observed ("Poste local : produit={0}, version={1}" -f $local.ProductIds, $local.Version) `
            -Evidence ("Registre ClickToRun du poste executant le moteur.`nProduits : $($local.ProductIds)`nVersion : $($local.Version)`nPlateforme : $($local.Platform)") `
            -Remediation $(if ($status -eq 'Conforme') { '' } else { "Le poste execute une version perpetuelle d'Office : deployer Microsoft 365 Apps for Enterprise (canal Current ou Monthly Enterprise)." })
    }

    # Signal tenant : rapport d'usage des applications M365 (indique les applications reellement utilisees).
    $report = $null
    if ($Context.Services.Graph) {
        $report = Invoke-CceGraphRequest -Quiet `
            -Uri "https://graph.microsoft.com/v1.0/reports/getM365AppUserDetail(period='D30')?`$format=application/json"
    }

    if ($report -and $report.value) {
        $rows = @($report.value)
        $withDesktop = @($rows | Where-Object { "$($_.appVersion)" -match '16\.0' -or $_.word -eq $true })
        return New-CceResult -Status 'Manuel' `
            -Observed ("{0} utilisateur(s) remontent dans le rapport d'usage M365 Apps (30 j)" -f $rows.Count) `
            -Evidence ("Le rapport Graph getM365AppUserDetail ne distingue pas Office perpetuel de Microsoft 365 Apps.`nUtilisateurs actifs remontes : $($rows.Count) (dont $($withDesktop.Count) avec activite bureau).") `
            -Remediation "Verifier le canal et le produit sur un poste de reference (Word > Fichier > Compte) ou via l'inventaire Intune. Relancer le moteur avec -IncludeLocalChecks pour auditer le poste courant."
    }

    New-CceResult -Status 'Manuel' `
        -Observed 'Non determinable a distance' `
        -Evidence "Le produit Office installe est une donnee poste, non exposee par une API tenant." `
        -Remediation "Controler via Intune / inventaire logiciel, ou relancer le moteur avec -IncludeLocalChecks sur un poste de reference."
}

function Invoke-CceCheck07 {
    <# Canal de mise a jour = Current Channel ou Monthly Enterprise #>
    [CmdletBinding()] param($Context)

    $local = if ($Context.Config.IncludeLocalChecks) { Get-CceOfficeLocalConfiguration } else { $null }

    if ($local) {
        $ok = $local.Channel -in @('Current Channel', 'Monthly Enterprise Channel')
        return New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Non conforme' }) `
            -Observed ("Poste local : canal = {0}" -f $local.Channel) `
            -Evidence ("CDNBaseUrl : $($local.CdnBaseUrl)`nCanal resolu : $($local.Channel)`nVersion : $($local.Version)") `
            -Remediation $(if ($ok) { '' } else { "Basculer le poste sur Current Channel ou Monthly Enterprise Channel (Office Deployment Tool ou strategie Intune / ADMX)." })
    }

    if (-not $Context.Services.Graph) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $options = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/beta/admin/microsoft365Apps/installationOptions'

    if (-not $options) {
        return New-CceResult -Status 'Manuel' `
            -Observed 'Canal de mise a jour non lisible via Graph' `
            -Evidence "L'endpoint beta/admin/microsoft365Apps/installationOptions n'est pas accessible (droits ou tenant)." `
            -Remediation "Verifier le canal dans admin.cloud.microsoft > Parametres > Parametres de l'organisation > Installations Microsoft 365, ou via la strategie Intune."
    }

    $channel = "$($options.updateChannel)"
    $ok = $channel -in @('current', 'monthlyEnterprise')

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ("Canal d'installation par defaut du tenant : {0}" -f $channel) `
        -Evidence ("updateChannel : $channel`nWindows : $($options.appsForWindows | ConvertTo-Json -Compress)`nRemarque : ce parametre couvre les installations libre-service ; les postes geres suivent la strategie Intune / ODT.") `
        -Remediation $(if ($ok) { '' } else { "Positionner le canal sur Current Channel ou Monthly Enterprise Channel : Copilot n'est pas livre sur Semi-Annual." })
}

function Invoke-CceCheck08 {
    <# Modern Authentication (OAuth2) activee sur le tenant #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $org = Get-CceSafe { Get-OrganizationConfig -ErrorAction Stop } -What 'Get-OrganizationConfig'
    if (-not $org) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $enabled = [bool] $org.OAuth2ClientProfileEnabled

    New-CceResult -Status $(if ($enabled) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ("OAuth2ClientProfileEnabled = {0}" -f $enabled) `
        -Evidence ("Get-OrganizationConfig : OAuth2ClientProfileEnabled = $enabled") `
        -Remediation $(if ($enabled) { '' } else { "Executer : Set-OrganizationConfig -OAuth2ClientProfileEnabled `$true" })
}

function Invoke-CceCheck09 {
    <# Experiences connectees (Connected Experiences) activees #>
    [CmdletBinding()] param($Context)

    if ($Context.Config.IncludeLocalChecks -and $IsWindows) {
        $key = 'HKCU:\Software\Policies\Microsoft\office\16.0\common\privacy'
        if (Test-Path $key) {
            $p = Get-CceSafe { Get-ItemProperty -Path $key -ErrorAction Stop } -What 'registre privacy Office'
            $blocked = @()
            if ($p.disconnectedstate -eq 2)         { $blocked += 'Toutes les experiences connectees desactivees' }
            if ($p.usercontentdisabled -eq 1)       { $blocked += 'Experiences analysant le contenu desactivees' }
            if ($p.downloadcontentdisabled -eq 1)   { $blocked += 'Experiences telechargeant du contenu desactivees' }
            if ($p.controllerconnectedservicesenabled -eq 0) { $blocked += 'Experiences connectees optionnelles desactivees' }

            if ($blocked.Count -gt 0) {
                return New-CceResult -Status 'Non conforme' `
                    -Observed ("Poste local : {0} restriction(s) de confidentialite bloquante(s)" -f $blocked.Count) `
                    -Evidence ($blocked | ConvertTo-CceText) `
                    -Remediation "Reactiver les experiences connectees (strategie de groupe / Intune : Parametres de confidentialite Office)."
            }

            return New-CceResult -Status 'Conforme' `
                -Observed 'Poste local : aucune restriction de confidentialite bloquant Copilot' `
                -Evidence "Cle $key presente sans valeur bloquante."
        }

        return New-CceResult -Status 'Conforme' `
            -Observed 'Poste local : aucune strategie de confidentialite Office restrictive' `
            -Evidence "Cle $key absente : les experiences connectees suivent la valeur par defaut (activees)."
    }

    New-CceResult -Status 'Manuel' `
        -Observed 'Parametre poste / strategie de groupe' `
        -Evidence "Les experiences connectees sont pilotees par strategie ADMX ou Intune, sans API tenant." `
        -Remediation "Verifier la strategie 'Parametres de confidentialite Office' (Intune ou GPO) et relancer avec -IncludeLocalChecks sur un poste de reference."
}
