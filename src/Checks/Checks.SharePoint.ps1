#Requires -Version 7.0
<# Controles 16 a 23 - SHAREPOINT ET ONEDRIVE #>

$script:CceSensitiveSiteKeywords = 'rh|hr|paie|payroll|finance|comptab|direction|board|legal|juridique|confidentiel'

function Get-CceAllSpoSite {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SpoSites')) { return $Context.Cache['SpoSites'] }
    if (-not $Context.Services.SharePoint) { return @() }

    Write-CceLog 'Inventaire des sites SharePoint (peut prendre du temps)...' -Level INFO
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

    if ($sharing -eq 'ExternalUserAndGuestSharing') { $issues.Add("Le partage anonyme (liens 'Tout le monde') est autorise au niveau tenant.") }
    elseif ($sharing -eq 'ExternalUserSharingOnly') { $issues.Add('Le partage avec de nouveaux utilisateurs externes est autorise.') }

    if ($linkType -ne 'Internal' -and $linkType -ne 'Direct') { $issues.Add("Le type de lien par defaut est '$linkType' au lieu de 'Internal'.") }

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
            -Observed ("Sans objet : partage anonyme desactive (SharingCapability={0})" -f $sharing) `
            -Evidence "RequireAnonymousLinksExpireInDays=$days, mais aucun lien anonyme ne peut etre cree."
    }

    if ($days -gt 0 -and $days -le 7) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("RequireAnonymousLinksExpireInDays = {0}" -f $days) -Evidence "Expiration des liens anonymes : $days jour(s)."
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ("RequireAnonymousLinksExpireInDays = {0}" -f $days) `
        -Evidence "Le partage anonyme est actif et l'expiration est de $days jour(s) (valeur -1 = jamais)." `
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
            -Observed ("0 site en partage anonyme sur {0} site(s) analyses" -f $sites.Count) `
            -Evidence "Aucun site avec SharingCapability = ExternalUserAndGuestSharing."
    }

    $status = if ($sensitive.Count -gt 0) { 'Non conforme' } else { 'Attention' }

    New-CceResult -Status $status `
        -Observed ("{0} site(s) en partage anonyme sur {1}, dont {2} site(s) a intitule sensible" -f $overshared.Count, $sites.Count, $sensitive.Count) `
        -Evidence (@($sensitive | ForEach-Object { "[SENSIBLE] $($_.Title) - $($_.Url)" }) +
                   @($overshared | Where-Object { $_ -notin $sensitive } | ForEach-Object { "$($_.Title) - $($_.Url)" }) | ConvertTo-CceText -MaxItems 30) `
        -Remediation "Restreindre les sites concernes : Set-SPOSite -Identity <url> -SharingCapability ExistingExternalUserSharingOnly. Traiter en priorite les sites RH / Finance / Direction."
}

function Invoke-CceCheck19 {
    <# Provisionner OneDrive pour tous les utilisateurs Copilot #>
    [CmdletBinding()] param($Context)

    if (-not $Context.Services.SharePoint) { return New-CceNotEvaluated -Service SharePoint -Context $Context }
    if (-not $Context.Services.Graph) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $users = @(Get-CceCopilotUser -Context $Context | Where-Object { $_.AccountEnabled -and "$($_.UserType)" -ne 'Guest' })
    if ($users.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' -Observed 'Aucun utilisateur Copilot actif a controler' `
            -Evidence 'Le controle 3 doit etre conforme avant de verifier le provisionnement OneDrive.'
    }

    $personal = Get-CceSafe {
        Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'" -ErrorAction Stop
    } -What 'Get-SPOSite (OneDrive)'

    if ($null -eq $personal) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $owners = @($personal | ForEach-Object { "$($_.Owner)".ToLower() })
    $missing = @($users | Where-Object { $owners -notcontains $_.UserPrincipalName.ToLower() })

    if ($missing.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("{0}/{0} utilisateur(s) Copilot disposent d'un OneDrive" -f $users.Count) `
            -Evidence ("{0} site(s) OneDrive detectes sur le tenant." -f @($personal).Count)
    }

    New-CceResult -Status 'Attention' `
        -Observed ("{0} utilisateur(s) Copilot sur {1} sans OneDrive provisionne" -f $missing.Count, $users.Count) `
        -Evidence ($missing | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
        -Remediation "Provisionner les OneDrive : Request-SPOPersonalSite -UserEmails <upn>, ou faire ouvrir OneDrive une fois par l'utilisateur."
}

function Invoke-CceCheck20 {
    <# Microsoft Search active et fonctionnelle #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    $evidence = if ($tenant) { "SearchResolveExactEmailOrUPN=$($tenant.SearchResolveExactEmailOrUPN)" } else { '' }

    New-CceResult -Status 'Manuel' `
        -Observed "Test fonctionnel requis (aucune API d'etat de l'index)" `
        -Evidence ("La sante de l'index Microsoft Search n'est pas exposee par cmdlet.`n$evidence") `
        -Remediation "Se connecter a microsoft365.com/search avec un compte licencie et valider que les resultats SharePoint, OneDrive et Exchange remontent."
}

function Invoke-CceCheck21 {
    <# NoCrawl desactive sur les sites critiques #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed 'Verification par site requise (PnP.PowerShell)' `
        -Evidence "La propriete NoCrawl se lit site par site : Connect-PnPOnline -Url <site> ; Get-PnPWeb -Includes NoCrawl. Une application Entra ID dediee est necessaire pour PnP." `
        -Remediation "Auditer NoCrawl sur les sites metier critiques et le repositionner a False pour qu'ils soient indexes par Copilot."
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
            -Observed ("Restricted SharePoint Search : {0}" -f $value) `
            -Evidence "Get-SPOTenantRestrictedSearchMode : $value" `
            -Remediation $(if ($isEnabled) {
                "Restricted Search est actif : Copilot ne verra que les sites de la liste autorisee. Verifier Get-SPOTenantRestrictedSearchAllowedList et y inclure les sites metier critiques."
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
        -Observed 'Mode de recherche restreinte non lisible sur ce tenant' `
        -Evidence "Ni Get-SPOTenantRestrictedSearchMode ni la propriete IsContentAccessGoverned ne sont disponibles." `
        -Remediation "Verifier Restricted SharePoint Search dans le centre d'administration SharePoint."
}

function Invoke-CceCheck23 {
    <# Quota OneDrive a 1 To minimum #>
    [CmdletBinding()] param($Context)

    $tenant = Get-CceSpoTenant -Context $Context
    if (-not $tenant) { return New-CceNotEvaluated -Service SharePoint -Context $Context }

    $quota = [int64] $tenant.OneDriveStorageQuota
    $ok = $quota -ge 1048576

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ("OneDriveStorageQuota = {0} Mo ({1:N2} To)" -f $quota, ($quota / 1048576)) `
        -Evidence "Get-SPOTenant : OneDriveStorageQuota = $quota Mo" `
        -Remediation $(if ($ok) { '' } else { "Set-SPOTenant -OneDriveStorageQuota 1048576" })
}
