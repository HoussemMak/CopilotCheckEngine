#Requires -Version 7.0
<#
    Gestion des connexions aux services Microsoft 365.
    Chaque service se connecte independamment : l'echec de l'un n'empeche pas les
    controles portes par les autres (les controles concernes passent en "Non evalue").
#>

# Chaque scope correspond a un endpoint reellement appele par un controle.
# Un scope manquant ne fait pas echouer le moteur : l'appel retombe en "Non evalue",
# ce qui se lit a tort comme une absence d'API. D'ou la correspondance explicite.
$script:CceGraphScopes = @(
    'Organization.Read.All'          # Get-MgOrganization, SKU
    'Directory.Read.All'             # abonnements, annuaire
    'User.Read.All'                  # utilisateurs licencies
    'Group.Read.All'                 # licences par groupe
    'Policy.Read.All'                # acces conditionnel
    'Reports.Read.All'               # rapports d'usage Copilot et M365 Apps
    'Application.Read.All'           # principaux de service, applications integrees
    'AppCatalog.Read.All'            # /appCatalogs/teamsApps (controles 27 et 28)
    'ExternalConnection.Read.All'    # /external/connections (controle 46)
    'Files.Read.All'                 # sonde de l'index semantique (/copilot/retrieval)
    'RoleManagement.Read.Directory'  # attributions de roles d'administration
)

function Connect-CceGraph {
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'Microsoft Graph') -Level STEP

    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

        if ($Auth.ClientId -and $Auth.CertificateThumbprint) {
            Connect-MgGraph -TenantId $Auth.TenantId -ClientId $Auth.ClientId `
                -CertificateThumbprint $Auth.CertificateThumbprint -NoWelcome -ErrorAction Stop
        }
        elseif ($Auth.ClientId -and $Auth.ClientSecret) {
            $secure = ConvertTo-SecureString $Auth.ClientSecret -AsPlainText -Force
            $cred = [pscredential]::new($Auth.ClientId, $secure)
            Connect-MgGraph -TenantId $Auth.TenantId -ClientSecretCredential $cred -NoWelcome -ErrorAction Stop
        }
        else {
            $params = @{ Scopes = $script:CceGraphScopes; NoWelcome = $true; ErrorAction = 'Stop' }
            if ($Auth.TenantId) { $params.TenantId = $Auth.TenantId }
            Connect-MgGraph @params
        }

        $ctx = Get-MgContext
        $org = Get-CceSafe { Get-MgOrganization -ErrorAction Stop } -What 'Get-MgOrganization'

        $Context.Tenant.Id = $ctx.TenantId
        if ($org) {
            $Context.Tenant.Name = $org.DisplayName
            $Context.Tenant.DefaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsInitial }).Name
        }

        $Context.Services.Graph = $true
        Write-CceLog ((T 'conn.graph.ok') -f $Context.Tenant.Name, $Context.Tenant.Id) -Level OK
    }
    catch {
        $Context.ServiceError['Graph'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'Microsoft Graph', $_.Exception.Message) -Level ERROR
    }
}

function Connect-CceExchange {
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'Exchange Online') -Level STEP

    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop

        $params = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($Auth.ClientId -and $Auth.CertificateThumbprint -and $Auth.Organization) {
            $params.AppId = $Auth.ClientId
            $params.CertificateThumbprint = $Auth.CertificateThumbprint
            $params.Organization = $Auth.Organization
        }
        elseif ($Auth.AdminUpn) {
            $params.UserPrincipalName = $Auth.AdminUpn
        }

        Connect-ExchangeOnline @params
        $Context.Services.Exchange = $true
        Write-CceLog ((T 'conn.ok') -f 'Exchange Online') -Level OK
    }
    catch {
        $Context.ServiceError['Exchange'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'Exchange Online', $_.Exception.Message) -Level ERROR
    }
}

function Connect-CcePurview {
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'Purview (Security & Compliance)') -Level STEP

    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop

        $params = @{ ErrorAction = 'Stop' }
        if ($Auth.ClientId -and $Auth.CertificateThumbprint -and $Auth.Organization) {
            $params.AppId = $Auth.ClientId
            $params.CertificateThumbprint = $Auth.CertificateThumbprint
            $params.Organization = $Auth.Organization
        }
        elseif ($Auth.AdminUpn) {
            $params.UserPrincipalName = $Auth.AdminUpn
        }

        Connect-IPPSSession @params
        $Context.Services.Purview = $true
        Write-CceLog ((T 'conn.ok') -f 'Purview') -Level OK
    }
    catch {
        $Context.ServiceError['Purview'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'Purview', $_.Exception.Message) -Level ERROR
    }
}

function Connect-CceSharePoint {
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'SharePoint Online') -Level STEP

    $adminUrl = $Auth.SharePointAdminUrl
    if (-not $adminUrl -and $Context.Tenant.DefaultDomain) {
        $prefix = $Context.Tenant.DefaultDomain -replace '\.onmicrosoft\.com$', ''
        $adminUrl = "https://$prefix-admin.sharepoint.com"
    }

    if (-not $adminUrl) {
        $Context.ServiceError['SharePoint'] = T 'conn.spo.nourl'
        Write-CceLog $Context.ServiceError['SharePoint'] -Level ERROR
        return
    }

    $Context.Cache['SpoAdminUrl'] = $adminUrl

    try {
        # PowerShell 7 : le module SPO doit tourner en mode compatibilite Windows PowerShell.
        Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop

        $params = @{ Url = $adminUrl; ErrorAction = 'Stop' }
        if ($Auth.AdminUpn) { $params.Credential = $null }

        Connect-SPOService @params
        $Context.Services.SharePoint = $true
        Write-CceLog ((T 'conn.spo.ok') -f $adminUrl) -Level OK
    }
    catch {
        $Context.ServiceError['SharePoint'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'SharePoint Online', $_.Exception.Message) -Level ERROR
    }
}

function Connect-CceTeams {
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'Microsoft Teams') -Level STEP

    try {
        Import-Module MicrosoftTeams -ErrorAction Stop

        $params = @{ ErrorAction = 'Stop' }
        if ($Auth.ClientId -and $Auth.CertificateThumbprint -and $Auth.TenantId) {
            $params.ApplicationId = $Auth.ClientId
            $params.CertificateThumbprint = $Auth.CertificateThumbprint
            $params.TenantId = $Auth.TenantId
        }

        Connect-MicrosoftTeams @params | Out-Null
        $Context.Services.Teams = $true
        Write-CceLog ((T 'conn.ok') -f 'Microsoft Teams') -Level OK
    }
    catch {
        $Context.ServiceError['Teams'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'Microsoft Teams', $_.Exception.Message) -Level ERROR
    }
}

function Connect-CcePowerPlatform {
    <#
    .SYNOPSIS
        Connexion optionnelle a Power Platform (inventaire des agents Copilot Studio).
    .DESCRIPTION
        Module absent ou role manquant : le service reste non connecte et les controles
        concernes ressortent en "Non applicable" plutot que de faire echouer l'audit.
        Ce domaine d'administration est distinct de Microsoft 365 : il exige son propre
        role, d'ou son caractere optionnel.
    #>
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'Power Platform') -Level STEP

    try {
        Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop

        if ($Auth.ClientId -and $Auth.ClientSecret -and $Auth.TenantId) {
            Add-PowerAppsAccount -TenantID $Auth.TenantId -ApplicationId $Auth.ClientId `
                -ClientSecret $Auth.ClientSecret -ErrorAction Stop | Out-Null
        }
        else {
            Add-PowerAppsAccount -ErrorAction Stop | Out-Null
        }

        $Context.Services.PowerPlatform = $true
        Write-CceLog ((T 'conn.ok') -f 'Power Platform') -Level OK
    }
    catch {
        $Context.ServiceError['PowerPlatform'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'Power Platform', $_.Exception.Message) -Level WARN
    }
}

function Connect-CceCommerce {
    <#
    .SYNOPSIS
        Connexion optionnelle a MSCommerce (achats en libre-service).
    .DESCRIPTION
        Aucun endpoint Graph n'expose la strategie d'achat en libre-service : ce module
        est la seule source. Son absence n'interrompt pas l'audit.
    #>
    [CmdletBinding()]
    param($Context, [hashtable] $Auth)

    Write-CceLog ((T 'conn.start') -f 'MSCommerce') -Level STEP

    try {
        Import-Module MSCommerce -ErrorAction Stop
        Connect-MSCommerce -ErrorAction Stop | Out-Null

        $Context.Services.Commerce = $true
        Write-CceLog ((T 'conn.ok') -f 'MSCommerce') -Level OK
    }
    catch {
        $Context.ServiceError['Commerce'] = $_.Exception.Message
        Write-CceLog ((T 'conn.failed') -f 'MSCommerce', $_.Exception.Message) -Level WARN
    }
}

function Connect-CceServices {
    <#
    .SYNOPSIS
        Etablit toutes les connexions demandees, dans l'ordre (Graph en premier :
        il fournit le domaine par defaut necessaire a SharePoint).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [hashtable] $Auth,
        [string[]] $Services = @('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams')
    )

    if ($Services -contains 'Graph')          { Connect-CceGraph         -Context $Context -Auth $Auth }
    if ($Services -contains 'Exchange')       { Connect-CceExchange      -Context $Context -Auth $Auth }
    if ($Services -contains 'Purview')        { Connect-CcePurview       -Context $Context -Auth $Auth }
    if ($Services -contains 'SharePoint')     { Connect-CceSharePoint    -Context $Context -Auth $Auth }
    if ($Services -contains 'Teams')          { Connect-CceTeams         -Context $Context -Auth $Auth }
    if ($Services -contains 'PowerPlatform')  { Connect-CcePowerPlatform -Context $Context -Auth $Auth }
    if ($Services -contains 'Commerce')       { Connect-CceCommerce      -Context $Context -Auth $Auth }

    $connected = ($Context.Services.GetEnumerator() | Where-Object { $_.Value }).Count
    Write-CceLog ((T 'conn.summary') -f $connected, $Context.Services.Count) -Level INFO
}

function Disconnect-CceServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    Write-CceLog (T 'conn.disconnect') -Level STEP

    if ($Context.Services.Graph)      { Get-CceSafe { Disconnect-MgGraph -ErrorAction Stop } -What 'Disconnect-MgGraph' | Out-Null }
    if ($Context.Services.Exchange -or $Context.Services.Purview) {
        Get-CceSafe { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop } -What 'Disconnect-ExchangeOnline' | Out-Null
    }
    if ($Context.Services.SharePoint) { Get-CceSafe { Disconnect-SPOService -ErrorAction Stop } -What 'Disconnect-SPOService' | Out-Null }
    if ($Context.Services.Teams)      { Get-CceSafe { Disconnect-MicrosoftTeams -Confirm:$false -ErrorAction Stop } -What 'Disconnect-MicrosoftTeams' | Out-Null }
}
