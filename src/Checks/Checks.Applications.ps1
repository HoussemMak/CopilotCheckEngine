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

    $channel = (T 'h.get-cceofficelocalconfiguration.obs.unknown')
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
            -Observed ((T 'c06.obs.local') -f $local.ProductIds, $local.Version) `
            -Evidence ((T 'c06.ev.local') -f "$($local.ProductIds)", "$($local.Version)", "$($local.Platform)") `
            -Remediation $(if ($status -eq 'Conforme') { '' } else { (T 'c06.rem.local') })
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
            -Observed ((T 'c06.obs.report') -f $rows.Count) `
            -Evidence ((T 'c06.ev.report') -f $rows.Count, $withDesktop.Count) `
            -Remediation (T 'c06.rem.report')
    }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c06.obs.manual') `
        -Evidence (T 'c06.ev.manual') `
        -Remediation (T 'c06.rem.manual')
}

function Invoke-CceCheck07 {
    <# Canal de mise a jour = Current Channel ou Monthly Enterprise #>
    [CmdletBinding()] param($Context)

    $local = if ($Context.Config.IncludeLocalChecks) { Get-CceOfficeLocalConfiguration } else { $null }

    if ($local) {
        $ok = $local.Channel -in @('Current Channel', 'Monthly Enterprise Channel')
        return New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Non conforme' }) `
            -Observed ((T 'c07.obs.local') -f $local.Channel) `
            -Evidence ((T 'c07.ev.local') -f "$($local.CdnBaseUrl)", "$($local.Channel)", "$($local.Version)") `
            -Remediation $(if ($ok) { '' } else { (T 'c07.rem.local') })
    }

    if (-not $Context.Services.Graph) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $options = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/beta/admin/microsoft365Apps/installationOptions'

    if (-not $options) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c07.obs.unreadable') `
            -Evidence (T 'c07.ev.unreadable') `
            -Remediation (T 'c07.rem.unreadable')
    }

    $channel = "$($options.updateChannel)"
    $ok = $channel -in @('current', 'monthlyEnterprise')

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c07.obs.tenant') -f $channel) `
        -Evidence ((T 'c07.ev.tenant') -f $channel, "$($options.appsForWindows | ConvertTo-Json -Compress)") `
        -Remediation $(if ($ok) { '' } else { (T 'c07.rem.tenant') })
}

function Invoke-CceCheck08 {
    <# Modern Authentication (OAuth2) activee sur le tenant #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $org = Get-CceSafe { Get-OrganizationConfig -ErrorAction Stop } -What 'Get-OrganizationConfig'
    if (-not $org) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $enabled = [bool] $org.OAuth2ClientProfileEnabled

    New-CceResult -Status $(if ($enabled) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ((T 'c08.obs.default') -f $enabled) `
        -Evidence ((T 'c08.ev.default') -f $enabled) `
        -Remediation $(if ($enabled) { '' } else { (T 'c08.rem.ko') })
}

function Invoke-CceCheck09 {
    <# Experiences connectees (Connected Experiences) activees #>
    [CmdletBinding()] param($Context)

    if ($Context.Config.IncludeLocalChecks -and $IsWindows) {
        $key = 'HKCU:\Software\Policies\Microsoft\office\16.0\common\privacy'
        if (Test-Path $key) {
            $p = Get-CceSafe { Get-ItemProperty -Path $key -ErrorAction Stop } -What 'registre privacy Office'
            $blocked = @()
            if ($p.disconnectedstate -eq 2)         { $blocked += (T 'c09.ev.disconnected') }
            if ($p.usercontentdisabled -eq 1)       { $blocked += (T 'c09.ev.usercontent') }
            if ($p.downloadcontentdisabled -eq 1)   { $blocked += (T 'c09.ev.downloadcontent') }
            if ($p.controllerconnectedservicesenabled -eq 0) { $blocked += (T 'c09.ev.optional') }

            if ($blocked.Count -gt 0) {
                return New-CceResult -Status 'Non conforme' `
                    -Observed ((T 'c09.obs.blocked') -f $blocked.Count) `
                    -Evidence ($blocked | ConvertTo-CceText) `
                    -Remediation (T 'c09.rem.blocked')
            }

            return New-CceResult -Status 'Conforme' `
                -Observed (T 'c09.obs.ok') `
                -Evidence ((T 'c09.ev.ok') -f $key)
        }

        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c09.obs.nopolicy') `
            -Evidence ((T 'c09.ev.nopolicy') -f $key)
    }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c09.obs.manual') `
        -Evidence (T 'c09.ev.manual') `
        -Remediation (T 'c09.rem.manual')
}
