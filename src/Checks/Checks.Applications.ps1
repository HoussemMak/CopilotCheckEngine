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
        $rows = (Get-CceResponseValue $report)
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

function Get-CceConnectedExperienceSetting {
    <#
    .SYNOPSIS
        Les quatre strategies de confidentialite Office qui conditionnent Copilot.
    .DESCRIPTION
        Pour chacune : le nom officiel de la strategie, la valeur de registre associee et
        le motif qui permet de la reconnaitre dans un profil Intune (identifiant ADMX ou
        OMA-URI). L'ordre est significatif : le motif le plus specifique est teste d'abord,
        le motif generique 'connectedexperiences' vient en dernier.
        Valeurs officielles de registre : 1 = Enabled, 2 = Disabled.
        Source : learn.microsoft.com/microsoft-365-apps/privacy/manage-privacy-controls
    #>
    [CmdletBinding()] param()

    @(
        [pscustomobject]@{
            Registry = 'usercontentdisabled'
            Name     = (T 'c09.ev.usercontent')
            Pattern  = 'usercontentdisabled|thatanalyzecontent|analyzecontent'
        }
        [pscustomobject]@{
            Registry = 'downloadcontentdisabled'
            Name     = (T 'c09.ev.downloadcontent')
            Pattern  = 'downloadcontentdisabled|downloadonlinecontent'
        }
        [pscustomobject]@{
            Registry = 'controllerconnectedservicesenabled'
            Name     = (T 'c09.ev.optional')
            Pattern  = 'controllerconnectedservices|optionalconnectedexperiences'
        }
        [pscustomobject]@{
            Registry = 'disconnectedstate'
            Name     = (T 'c09.ev.disconnected')
            Pattern  = 'disconnectedstate|connectedexperiences'
        }
    )
}

function Get-CceOfficePrivacyPolicy {
    <#
    .SYNOPSIS
        Etat effectif des strategies de confidentialite Office sur le poste courant.
    .DESCRIPTION
        Deux emplacements sont lus, en lecture seule : la strategie de groupe (ADMX) et le
        miroir local du Cloud Policy service, documente sous
        HKCU\Software\Policies\Microsoft\Cloud\Office\16.0. Cloud Policy l'emporte sur la
        strategie de groupe : sa valeur ecrase donc celle de l'ADMX.
        Les valeurs sont 1 = Enabled et 2 = Disabled : toute autre valeur n'est pas probante
        et n'est donc pas comptee (l'ancienne implementation lisait 1 et 0 comme des
        blocages, ce qui declarait non conforme un poste correctement configure).
    #>
    [CmdletBinding()] param()

    if (-not $IsWindows) { return $null }

    $scopes = @(
        [pscustomobject]@{ Path = 'HKCU:\Software\Policies\Microsoft\office\16.0\common\privacy';       Source = (T 'c09.src.gpo') }
        [pscustomobject]@{ Path = 'HKCU:\Software\Policies\Microsoft\Cloud\Office\16.0\common\privacy'; Source = (T 'c09.src.cloud') }
    )

    $settings = Get-CceConnectedExperienceSetting
    $state = [ordered]@{}
    $keyPresent = $false
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($scope in $scopes) {
        $paths.Add($scope.Path)
        if (-not (Test-Path -Path $scope.Path)) { continue }

        $properties = Get-CceSafe { Get-ItemProperty -Path $scope.Path -ErrorAction Stop } -What $scope.Path
        if (-not $properties) { continue }
        $keyPresent = $true

        foreach ($setting in $settings) {
            $property = $properties.PSObject.Properties[$setting.Registry]
            if (-not $property) { continue }

            $number = 0
            if (-not [int]::TryParse("$($property.Value)", [ref] $number)) { continue }
            if ($number -ne 1 -and $number -ne 2) { continue }

            $state[$setting.Registry] = [pscustomobject]@{
                Value  = $number
                Source = $scope.Source
                Name   = $setting.Name
            }
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $blocked = [System.Collections.Generic.List[string]]::new()

    foreach ($registry in $state.Keys) {
        $entry = $state[$registry]
        $label = if ($entry.Value -eq 2) { T 'c09.state.disabled' } else { T 'c09.state.enabled' }
        $line = (T 'c09.ev.local.item') -f $entry.Name, $label, $entry.Source
        $lines.Add($line)
        if ($entry.Value -eq 2) { $blocked.Add($line) }
    }

    [pscustomobject]@{
        KeyPresent = $keyPresent
        Decided    = $lines.Count
        Lines      = $lines
        Blocked    = $blocked
        Paths      = ($paths -join ' ; ')
    }
}

function Get-CceIntuneConnectedExperiencePolicy {
    <#
    .SYNOPSIS
        Strategies d'experiences connectees portees par le catalogue de parametres Intune.
    .DESCRIPTION
        Le Cloud Policy service (config.office.com) n'expose aucune API publique : Intune
        est le seul chemin de lecture cote tenant, et il ne repond que si l'organisation y
        porte la strategie. L'endpoint du catalogue de parametres n'existe qu'en beta et
        exige DeviceManagementConfiguration.Read.All.
        Renvoie $null si l'endpoint n'est pas lisible (Intune absent, droits manquants) :
        le controle retombe alors sur le poste de reference.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return $null }

    $settings = Get-CceConnectedExperienceSetting
    $uri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$expand=settings&$top=100'

    $lines = [System.Collections.Generic.List[string]]::new()
    $blocked = [System.Collections.Generic.List[string]]::new()
    $enabled = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $policyCount = 0
    $page = 0
    $read = $false

    while ($uri -and $page -lt 10) {
        $page++
        $response = Invoke-CceGraphRequest -Quiet -Uri $uri
        if (-not $response) { break }
        $read = $true

        $uri = $null
        $next = $response.PSObject.Properties['@odata.nextLink']
        if ($next -and $next.Value) { $uri = [string] $next.Value }

        $collection = $response.PSObject.Properties['value']
        if (-not $collection) { continue }

        foreach ($policy in @($collection.Value)) {
            if (-not $policy) { continue }
            $policyCount++

            $policyName = ''
            foreach ($candidate in 'name', 'id') {
                $property = $policy.PSObject.Properties[$candidate]
                if ($property -and $property.Value) { $policyName = [string] $property.Value; break }
            }

            $inner = $policy.PSObject.Properties['settings']
            if (-not $inner) { continue }

            foreach ($setting in @($inner.Value)) {
                if (-not $setting) { continue }

                $json = Get-CceSafe { $setting | ConvertTo-Json -Depth 12 -Compress } -What 'configurationPolicies/settings'
                if (-not $json) { continue }
                $flat = ([string] $json).ToLowerInvariant()

                $match = $settings | Where-Object { $flat -match $_.Pattern } | Select-Object -First 1
                if (-not $match) { continue }

                # Catalogue de parametres : la valeur retenue se termine par _1 (Enabled) ou
                # _0 (Disabled). ADMX ingere : la valeur porte <enabled/> ou <disabled/>.
                $decision = 'unknown'
                $choice = [regex]::Match($flat, '"value"\s*:\s*"[^"]*(?:connectedexperiences|disconnectedstate|usercontentdisabled|downloadcontentdisabled|controllerconnectedservices)[^"]*_(\d)"')
                if ($choice.Success) {
                    $decision = if ($choice.Groups[1].Value -eq '1') { 'enabled' } else { 'disabled' }
                }
                elseif ($flat -match '<enabled\s*/>') { $decision = 'enabled' }
                elseif ($flat -match '<disabled\s*/>') { $decision = 'disabled' }

                $label = switch ($decision) {
                    'enabled'  { T 'c09.state.enabled' }
                    'disabled' { T 'c09.state.disabled' }
                    default    { T 'c09.state.unknown' }
                }

                $line = (T 'c09.ev.intune.item') -f $match.Name, $label, $policyName
                $lines.Add($line)

                if ($decision -eq 'disabled') { $blocked.Add($line) }
                elseif ($decision -eq 'enabled') { $enabled.Add($line) }
                else { $unknown.Add($line) }
            }
        }
    }

    if (-not $read) { return $null }

    [pscustomobject]@{
        PolicyCount = $policyCount
        Lines       = $lines
        Blocked     = $blocked
        Enabled     = $enabled
        Unknown     = $unknown
    }
}

function Invoke-CceCheck09 {
    <# Experiences connectees (Connected Experiences) activees #>
    [CmdletBinding()] param($Context)

    # Deux sources, deux niveaux de preuve. Une valeur bloquante sur le poste de reference
    # est l'etat reellement applique : elle tranche en 'Non conforme'. Un profil Intune
    # bloquant est une preuve moins forte, car sa portee d'affectation n'est pas verifiee
    # ici : il donne 'Attention'. Sans blocage, toute valeur explicite vaut 'Conforme',
    # l'absence de strategie aussi puisque la valeur par defaut est "experiences activees".
    $intune = Get-CceIntuneConnectedExperiencePolicy -Context $Context

    $local = $null
    if ($Context.Config.IncludeLocalChecks) { $local = Get-CceOfficePrivacyPolicy }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($local) { foreach ($line in $local.Lines) { $lines.Add($line) } }
    if ($intune) { foreach ($line in $intune.Lines) { $lines.Add($line) } }

    if ($local -and $local.Blocked.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c09.obs.blocked') -f $local.Blocked.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c09.rem.blocked')
    }

    if ($intune -and $intune.Blocked.Count -gt 0) {
        $lines.Add((T 'c09.ev.intune.scope'))
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c09.obs.intune.blocked') -f $intune.Blocked.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c09.rem.blocked')
    }

    $decided = 0
    if ($local) { $decided += $local.Decided }
    if ($intune) { $decided += $intune.Enabled.Count }

    if ($decided -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c09.obs.ok') -f $decided) `
            -Evidence ($lines | ConvertTo-CceText)
    }

    if ($local) {
        # Poste lu, aucune valeur probante : les experiences connectees restent a leur
        # valeur par defaut, c'est-a-dire activees.
        $evidence = if ($local.KeyPresent) { (T 'c09.ev.ok') -f $local.Paths } else { (T 'c09.ev.nopolicy') -f $local.Paths }
        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c09.obs.nopolicy') `
            -Evidence $evidence
    }

    $trace = if ($intune -and $intune.Unknown.Count -gt 0) { $lines | ConvertTo-CceText }
    elseif ($intune) { (T 'c09.ev.intune.none') -f $intune.PolicyCount }
    else { T 'c09.ev.manual' }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c09.obs.manual') `
        -Evidence $trace `
        -Remediation (T 'c09.rem.manual')
}
