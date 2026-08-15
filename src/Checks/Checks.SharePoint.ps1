#Requires -Version 7.0
<# Controles 16 a 23 - SHAREPOINT ET ONEDRIVE #>

$script:CceSensitiveSiteKeywords = 'rh|hr|paie|payroll|finance|comptab|direction|board|legal|juridique|confidentiel'

function Get-CceAllSpoSite {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SpoSites')) { return $Context.Cache['SpoSites'] }
    if (-not $Context.Services.SharePoint) { return @() }

    Write-CceLog (T 'collect.spo.sites') -Level INFO
    $sites = Get-CceSafe { Get-SPOSite -Limit All -ErrorAction Stop } -What 'Get-SPOSite'
    $Context.Cache['SpoSites'] = @($sites)
    $Context.Cache['SpoSites']
}

function Invoke-CceCheck16 {
    <# Partage global SharePoint en mode securise #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $sharing = "$($tenant.SharingCapability)"
    $linkType = "$($tenant.DefaultSharingLinkType)"
    $linkPerm = "$($tenant.DefaultLinkPermission)"

    $observed = "SharingCapability=$sharing | DefaultSharingLinkType=$linkType | DefaultLinkPermission=$linkPerm"
    $issues = [System.Collections.Generic.List[string]]::new()

    if ($sharing -eq 'ExternalUserAndGuestSharing') { $issues.Add((T 'c16.ev.anon')) }
    elseif ($sharing -eq 'ExternalUserSharingOnly') { $issues.Add((T 'c16.ev.external')) }

    if ($linkType -ne 'Internal' -and $linkType -ne 'Direct') { $issues.Add(((T 'c16.ev.linktype') -f $linkType)) }

    if ($issues.Count -eq 0) {
        return New-CceResult -Status 'Conforme' -Observed $observed -Evidence $observed
    }

    $status = if ($sharing -eq 'ExternalUserAndGuestSharing') { 'Non conforme' } else { 'Attention' }

    New-CceResult -Status $status -Observed $observed `
        -Evidence (($issues + $observed) | ConvertTo-CceText) `
        -Remediation "Set-SPOTenant -SharingCapability ExistingExternalUserSharingOnly -DefaultSharingLinkType Internal"
}

function Invoke-CceCheck17 {
    <# Expiration des liens anonymes a 7 jours maximum #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $days = $tenant.RequireAnonymousLinksExpireInDays
    $sharing = "$($tenant.SharingCapability)"

    if ($sharing -ne 'ExternalUserAndGuestSharing') {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c17.obs.na') -f $sharing) `
            -Evidence ((T 'c17.ev.na') -f $days)
    }

    if ($days -gt 0 -and $days -le 7) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("RequireAnonymousLinksExpireInDays = {0}" -f $days) -Evidence ((T 'c17.ev.ok') -f $days)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ("RequireAnonymousLinksExpireInDays = {0}" -f $days) `
        -Evidence ((T 'c17.ev.ko') -f $days) `
        -Remediation "Set-SPOTenant -RequireAnonymousLinksExpireInDays 7"
}

function Invoke-CceCheck18 {
    <# Identifier et restreindre les sites SharePoint sur-partages #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $sites = Get-CceAllSpoSite -Context $Context
    if (-not $sites -or $sites.Count -eq 0) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $overshared = @($sites | Where-Object { "$($_.SharingCapability)" -eq 'ExternalUserAndGuestSharing' })
    $sensitive = @($overshared | Where-Object { "$($_.Title) $($_.Url)" -match $script:CceSensitiveSiteKeywords })

    if ($overshared.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c18.obs.ok') -f $sites.Count) `
            -Evidence (T 'c18.ev.ok')
    }

    $status = if ($sensitive.Count -gt 0) { 'Non conforme' } else { 'Attention' }

    New-CceResult -Status $status `
        -Observed ((T 'c18.obs.ko') -f $overshared.Count, $sites.Count, $sensitive.Count) `
        -Evidence (@($sensitive | ForEach-Object { (T 'c18.ev.sensitive') -f $_.Title, $_.Url }) +
                   @($overshared | Where-Object { $_ -notin $sensitive } | ForEach-Object { "$($_.Title) - $($_.Url)" }) | ConvertTo-CceText -MaxItems 30) `
        -Remediation (T 'c18.rem.ko')
}

function Invoke-CceCheck19 {
    <# Provisionner OneDrive pour tous les utilisateurs Copilot #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }
    if (-not $Context.Services.Graph) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = @(Get-CceCopilotUser -Context $Context | Where-Object { $_.AccountEnabled -and "$($_.UserType)" -ne 'Guest' })
    if ($users.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' -Observed (T 'c19.obs.none') `
            -Evidence (T 'c19.ev.none')
    }

    $personal = Get-CceSafe {
        Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'" -ErrorAction Stop
    } -What 'Get-SPOSite (OneDrive)'

    if ($null -eq $personal) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $owners = @($personal | ForEach-Object { "$($_.Owner)".ToLower() })
    $missing = @($users | Where-Object { $owners -notcontains $_.UserPrincipalName.ToLower() })

    if ($missing.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c19.obs.ok') -f $users.Count) `
            -Evidence ((T 'c19.ev.ok') -f @($personal).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c19.obs.ko') -f $missing.Count, $users.Count) `
        -Evidence ($missing | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation (T 'c19.rem.ko')
}

function Invoke-CceCheck20 {
    <# Microsoft Search active et fonctionnelle #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    $evidence = if ($tenant) { "SearchResolveExactEmailOrUPN=$($tenant.SearchResolveExactEmailOrUPN)" } else { '' }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c20.obs.manual') `
        -Evidence ((T 'c20.ev.manual') -f $evidence) `
        -Remediation (T 'c20.rem.manual')
}

function Invoke-CceCheck21 {
    <# NoCrawl desactive sur les sites critiques #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c21.obs.manual') `
        -Evidence (T 'c21.ev.manual') `
        -Remediation (T 'c21.rem.manual')
}

function Invoke-CceCheck22 {
    <# Configuration de Restricted SharePoint Search #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $mode = Get-CceSafe { Get-SPOTenantRestrictedSearchMode -ErrorAction Stop } -What 'Get-SPOTenantRestrictedSearchMode'

    if ($null -ne $mode) {
        $value = "$($mode.RestrictedSearchMode ?? $mode)"
        $isEnabled = $value -match 'Enabled|True'

        return New-CceResult -Status $(if ($isEnabled) { 'Attention' } else { 'Conforme' }) `
            -Observed ((T 'c22.obs.mode') -f $value) `
            -Evidence "Get-SPOTenantRestrictedSearchMode : $value" `
            -Remediation $(if ($isEnabled) {
                T 'c22.rem.enabled'
            } else { '' })
    }

    $tenant = Get-CceSpoTenant -Context $Context
    if ($tenant -and $null -ne $tenant.IsContentAccessGoverned) {
        $governed = [bool] $tenant.IsContentAccessGoverned
        return New-CceResult -Status $(if ($governed) { 'Attention' } else { 'Conforme' }) `
            -Observed ("IsContentAccessGoverned = {0}" -f $governed) `
            -Evidence "Get-SPOTenant : IsContentAccessGoverned = $governed"
    }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c22.obs.manual') `
        -Evidence (T 'c22.ev.manual') `
        -Remediation (T 'c22.rem.manual')
}

function Invoke-CceCheck23 {
    <# Quota OneDrive a 1 To minimum #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $quota = [int64] $tenant.OneDriveStorageQuota
    $ok = $quota -ge 1048576

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c23.obs.value') -f $quota, ($quota / 1048576)) `
        -Evidence ((T 'c23.ev.value') -f $quota) `
        -Remediation $(if ($ok) { '' } else { "Set-SPOTenant -OneDriveStorageQuota 1048576" })
}
