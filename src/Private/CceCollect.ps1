#Requires -Version 7.0
<#
    Collecteurs mutualises : les requetes couteuses (SKU, utilisateurs licencies,
    strategies d'acces conditionnel, parametres SPO/Teams) sont executees une seule
    fois et mises en cache dans le contexte.
#>

function Get-CceSubscribedSku {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('Skus')) { return $Context.Cache['Skus'] }
    if (-not $Context.Services.Graph) { return @() }

    $skus = Get-CceSafe { Get-MgSubscribedSku -All -ErrorAction Stop } -What 'Get-MgSubscribedSku'
    $Context.Cache['Skus'] = @($skus)
    $Context.Cache['Skus']
}

function Get-CceCopilotSku {
    [CmdletBinding()] param($Context)

    Get-CceSubscribedSku -Context $Context |
        Where-Object { $_.SkuPartNumber -like (Get-CceCopilotSkuPattern) }
}

function Get-CceCopilotSkuId {
    [CmdletBinding()] param($Context)

    @(Get-CceCopilotSku -Context $Context | Select-Object -ExpandProperty SkuId)
}

function Get-CceCopilotUser {
    <#
    .SYNOPSIS
        Tous les utilisateurs porteurs d'une licence Copilot (comptes actifs et desactives,
        membres et invites : les controles 14 et 15 s'appuient dessus).
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotUsers')) { return $Context.Cache['CopilotUsers'] }
    if (-not $Context.Services.Graph) { return @() }

    $skuIds = Get-CceCopilotSkuId -Context $Context
    if (-not $skuIds -or $skuIds.Count -eq 0) {
        $Context.Cache['CopilotUsers'] = @()
        return @()
    }

    $users = [System.Collections.Generic.List[object]]::new()
    foreach ($skuId in $skuIds) {
        $filter = "assignedLicenses/any(x:x/skuId eq $skuId)"
        $batch = Get-CceSafe {
            Get-MgUser -Filter $filter -All -ConsistencyLevel eventual -CountVariable cv `
                -Property Id, DisplayName, UserPrincipalName, AccountEnabled, UserType, Mail, AssignedLicenses `
                -ErrorAction Stop
        } -What "Get-MgUser (licence $skuId)"

        foreach ($u in @($batch)) { $users.Add($u) }
    }

    $Context.Cache['CopilotUsers'] = @($users | Sort-Object Id -Unique)
    $Context.Cache['CopilotUsers']
}

function Get-CceConditionalAccessPolicy {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CaPolicies')) { return $Context.Cache['CaPolicies'] }
    if (-not $Context.Services.Graph) { return @() }

    $policies = Invoke-CceGraphRequest -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'

    $Context.Cache['CaPolicies'] = @($policies.value)
    $Context.Cache['CaPolicies']
}

function Get-CceSpoTenant {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('SpoTenant')) { return $Context.Cache['SpoTenant'] }
    if (-not $Context.Services.SharePoint) { return $null }

    $tenant = Get-CceSafe { Get-SPOTenant -ErrorAction Stop } -What 'Get-SPOTenant'
    $Context.Cache['SpoTenant'] = $tenant
    $tenant
}

function Get-CceTeamsMeetingPolicy {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('TeamsMeetingPolicy')) { return $Context.Cache['TeamsMeetingPolicy'] }
    if (-not $Context.Services.Teams) { return $null }

    $policy = Get-CceSafe { Get-CsTeamsMeetingPolicy -Identity Global -ErrorAction Stop } -What 'Get-CsTeamsMeetingPolicy'
    $Context.Cache['TeamsMeetingPolicy'] = $policy
    $policy
}

function Invoke-CceGraphRequest {
    <#
    .SYNOPSIS
        Appel Graph brut tolerant a l'echec (endpoints beta ou droits partiels).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'GET',
        [switch] $Quiet
    )

    try {
        # -OutputType PSObject : les reponses sont manipulees comme des objets et non
        # comme des tables de hachage (indispensable pour l'introspection des proprietes).
        Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType PSObject -ErrorAction Stop
    }
    catch {
        if (-not $Quiet) { Write-CceLog "Graph $Method $Uri : $($_.Exception.Message)" -Level WARN }
        $null
    }
}
