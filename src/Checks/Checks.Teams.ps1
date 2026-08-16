#Requires -Version 7.0
<# Controles 27 a 32 - MICROSOFT TEAMS POUR COPILOT #>

function Get-CceTeamsValue {
    <#
    .SYNOPSIS
        Lit une propriete d'un objet Teams ou Graph sans supposer sa presence.
    .DESCRIPTION
        Deux realites imposent cette prudence, toutes deux constatees en production :
        les entrees de strategie Teams n'exposent pas toujours Id, et le jeu de
        proprietes d'une strategie de reunion varie selon la version du module
        MicrosoftTeams deployee. Sous Set-StrictMode Latest, l'acces direct a une
        propriete absente arrete le controle au lieu de rendre un verdict.
        La recherche est insensible a la casse : Graph expose 'id', les cmdlets Teams 'Id'.
    #>
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ("$key" -ieq $Name) { return $InputObject[$key] }
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }

    foreach ($candidate in $InputObject.PSObject.Properties) {
        if ($candidate.Name -ieq $Name) { return $candidate.Value }
    }

    $null
}

function Get-CceTeamsIdList {
    <# Identifiants d'une collection d'applications, en ignorant les entrees sans Id. #>
    [CmdletBinding()]
    param($Items)

    @(foreach ($item in @($Items)) {
        $id = "$(Get-CceTeamsValue -InputObject $item -Name 'id')".Trim()
        if ($id -ne '') { $id }
    })
}

function Get-CceCopilotTeamsApp {
    <#
    .SYNOPSIS
        Resout les identifiants des applications Copilot du catalogue Teams via Graph
        (evite de coder en dur des GUID susceptibles de changer).
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotTeamsApps')) { return $Context.Cache['CopilotTeamsApps'] }
    if (-not $Context.Services.Graph) { return @() }

    $response = Invoke-CceGraphRequest -Quiet `
        -Uri "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?`$filter=distributionMethod eq 'store'&`$top=999"

    $apps = (Get-CceResponseValue $response) | Where-Object { "$(Get-CceTeamsValue -InputObject $_ -Name 'displayName')" -match 'copilot' }
    $Context.Cache['CopilotTeamsApps'] = @($apps)
    $Context.Cache['CopilotTeamsApps']
}

function Invoke-CceCheck27 {
    <# Autoriser l'application Copilot dans les strategies Teams #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Teams -Context $Context)) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $policy = Get-CceSafe { Get-CsTeamsAppPermissionPolicy -Identity Global -ErrorAction Stop } -What 'Get-CsTeamsAppPermissionPolicy'
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $mode = "$(Get-CceTeamsValue -InputObject $policy -Name 'DefaultCatalogAppsType')"
    $globalMode = "$(Get-CceTeamsValue -InputObject $policy -Name 'GlobalCatalogAppsType')"
    $blocked = @(Get-CceTeamsValue -InputObject $policy -Name 'DefaultCatalogApps') + @(Get-CceTeamsValue -InputObject $policy -Name 'GlobalCatalogApps')
    $copilotApps = @(Get-CceCopilotTeamsApp -Context $Context)
    $copilotIds = @(Get-CceTeamsIdList -Items $copilotApps)

    $blockedCopilot = @($blocked | Where-Object { $copilotIds -contains "$(Get-CceTeamsValue -InputObject $_ -Name 'id')" })

    $observed = "DefaultCatalogAppsType=$mode | GlobalCatalogAppsType=$globalMode"

    if ($mode -eq 'BlockedAppList' -and $blockedCopilot.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c27.obs.ok') -f $observed) `
            -Evidence ((T 'c27.ev.ok') -f ((@(foreach ($a in $copilotApps) { "$(Get-CceTeamsValue -InputObject $a -Name 'displayName')" })) -join ', '))
    }

    if ($blockedCopilot.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c27.obs.ko') -f $observed) `
            -Evidence ($blockedCopilot | ForEach-Object { (T 'c27.ev.line.blocked') -f (Get-CceTeamsValue -InputObject $_ -Name 'id') } | ConvertTo-CceText) `
            -Remediation (T 'c27.rem.ko')
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c27.obs.warn') -f $observed) `
        -Evidence (@((T 'c27.ev.warn.header') -f ((@(foreach ($a in $copilotApps) { "$(Get-CceTeamsValue -InputObject $a -Name 'displayName')" })) -join ', ')) +
                   @($blocked | ForEach-Object { (T 'c27.ev.warn.line') -f (Get-CceTeamsValue -InputObject $_ -Name 'id') }) | ConvertTo-CceText) `
        -Remediation (T 'c27.rem.warn')
}

function Invoke-CceCheck28 {
    <# Epingler Copilot dans la barre laterale Teams #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Teams -Context $Context)) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $policy = Get-CceSafe { Get-CsTeamsAppSetupPolicy -Identity Global -ErrorAction Stop } -What 'Get-CsTeamsAppSetupPolicy'
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $pinned = @(Get-CceTeamsValue -InputObject $policy -Name 'PinnedAppBarApps')
    $copilotApps = @(Get-CceCopilotTeamsApp -Context $Context)
    $copilotIds = @(Get-CceTeamsIdList -Items $copilotApps)

    $pinnedCopilot = @($pinned | Where-Object { $copilotIds -contains "$(Get-CceTeamsValue -InputObject $_ -Name 'id')" })

    if ($copilotIds.Count -eq 0) {
        return New-CceResult -Status 'Manuel' `
            -Observed ((T 'c28.obs.manual') -f $pinned.Count) `
            -Evidence ($pinned | ForEach-Object { (T 'c28.ev.line.order') -f (Get-CceTeamsValue -InputObject $_ -Name 'id'), (Get-CceTeamsValue -InputObject $_ -Name 'order') } | ConvertTo-CceText) `
            -Remediation (T 'c28.rem.manual')
    }

    if ($pinnedCopilot.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c28.obs.ok') -f $pinned.Count) `
            -Evidence ($pinnedCopilot | ForEach-Object { (T 'c28.ev.line.pinned') -f (Get-CceTeamsValue -InputObject $_ -Name 'id') } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c28.obs.ko') -f $pinned.Count) `
        -Evidence (@((T 'c28.ev.ko.header') -f ((@(foreach ($a in $copilotApps) { "$(Get-CceTeamsValue -InputObject $a -Name 'displayName')" })) -join ', ')) +
                   @($pinned | ForEach-Object { (T 'c28.ev.line.pinned') -f (Get-CceTeamsValue -InputObject $_ -Name 'id') }) | ConvertTo-CceText) `
        -Remediation (T 'c28.rem.ko')
}

function Invoke-CceCheck29 {
    <# Transcription des reunions activee #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $value = [bool] (Get-CceTeamsValue -InputObject $policy -Name 'AllowTranscription')

    New-CceResult -Status $(if ($value) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ((T 'c29.obs.default') -f $value) `
        -Evidence ((T 'c29.ev.default') -f $value) `
        -Remediation $(if ($value) { '' } else { T 'c29.rem.ko' })
}

function Invoke-CceCheck30 {
    <# Enregistrement cloud des reunions active #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $value = [bool] (Get-CceTeamsValue -InputObject $policy -Name 'AllowCloudRecording')

    New-CceResult -Status $(if ($value) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c30.obs.default') -f $value) `
        -Evidence ((T 'c30.ev.default') -f $value) `
        -Remediation $(if ($value) { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -AllowCloudRecording `$true" })
}

function Get-CceTeamsMeetingPolicyFlag {
    <#
    .SYNOPSIS
        Lecture tolerante d'un booleen de strategie de reunion.
    .DESCRIPTION
        Les proprietes exposees varient d'une version a l'autre du module MicrosoftTeams :
        une propriete absente vaut $false au lieu de faire echouer le controle.
    #>
    [CmdletBinding()]
    param(
        $Policy,
        [Parameter(Mandatory)] [string] $Name
    )

    if (-not $Policy) { return $false }

    $property = $Policy.PSObject.Properties[$Name]
    if ($null -eq $property) { return $false }

    [bool] $property.Value
}

function Get-CceTeamsCopilotMeetingMode {
    <#
    .SYNOPSIS
        Mode Copilot d'une strategie de reunion Teams.
    .DESCRIPTION
        Le parametre officiel de Set/Get-CsTeamsMeetingPolicy est -Copilot ; les versions
        anciennes du module exposent la meme valeur sous le nom CopilotMode. Les deux noms
        sont lus, dans cet ordre. Chaine vide si aucun des deux n'est expose.
    #>
    [CmdletBinding()] param($Policy)

    if (-not $Policy) { return '' }

    foreach ($name in @('Copilot', 'CopilotMode')) {
        $property = $Policy.PSObject.Properties[$name]
        if ($null -eq $property) { continue }

        $value = "$($property.Value)".Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    ''
}

function Get-CceCopilotMeetingModeRank {
    <#
    .SYNOPSIS
        Classe une valeur de mode Copilot selon la matrice officielle.
    .DESCRIPTION
        'target'  : EnabledWithTranscript / EnabledWithTranscriptDefaultOn (et l'ancien
                    libelle EnabledWithMeetingTranscript) - la transcription est conservee,
                    donc le recapitulatif apres reunion est produit.
        'weak'    : Enabled - Copilot est actif mais le defaut de l'organisateur reste
                    "uniquement pendant la reunion" : rien n'est conserve, pas de recapitulatif.
        'off'     : Disabled.
        'unknown' : valeur inconnue du moteur (nouvelle valeur de service).
    #>
    [CmdletBinding()] param([AllowEmptyString()] [string] $Mode)

    if ([string]::IsNullOrWhiteSpace($Mode)) { return 'unknown' }
    if ($Mode -match '^EnabledWith(Meeting)?Transcript') { return 'target' }
    if ($Mode -eq 'Enabled') { return 'weak' }
    if ($Mode -eq 'Disabled') { return 'off' }

    'unknown'
}

function Get-CceTeamsMeetingPolicyScope {
    <#
    .SYNOPSIS
        Strategies de reunion non globales assignees a un groupe, avec leur mode Copilot.
    .DESCRIPTION
        Un pilote Copilot recoit tres souvent sa propre strategie de reunion : lire la seule
        strategie Global donnerait un verdict faux pour les utilisateurs concernes.
        Lecture seule ; toute indisponibilite (module ancien, droits insuffisants) se traduit
        par Readable = $false, jamais par une exception.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('TeamsMeetingPolicyScope')) { return $Context.Cache['TeamsMeetingPolicyScope'] }

    $scope = [pscustomobject]@{ Readable = $false; Policies = @() }
    $Context.Cache['TeamsMeetingPolicyScope'] = $scope

    if (-not (Test-CceService -Service Teams -Context $Context)) { return $scope }

    # L'enveloppe [pscustomobject] distingue "aucune assignation" (Items vide) de
    # "lecture impossible" (Get-CceSafe renvoie $null).
    $assignments = Get-CceSafe {
        [pscustomobject]@{ Items = @(Get-CsGroupPolicyAssignment -PolicyType TeamsMeetingPolicy -ErrorAction Stop) }
    } -What 'Get-CsGroupPolicyAssignment'
    if ($null -eq $assignments) { return $scope }

    $scope.Readable = $true

    $assigned = @(@($assignments.Items) |
        ForEach-Object { ("$($_.PolicyName)".Trim()) -replace '^Tag:', '' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    if ($assigned.Count -eq 0) { return $scope }

    $all = Get-CceSafe {
        [pscustomobject]@{ Items = @(Get-CsTeamsMeetingPolicy -ErrorAction Stop) }
    } -What 'Get-CsTeamsMeetingPolicy'
    if ($null -eq $all) {
        $scope.Readable = $false
        return $scope
    }

    $scope.Policies = @(@($all.Items) | ForEach-Object {
        $name = "$($_.Identity)" -replace '^Tag:', ''
        if ($name -eq 'Global' -or $assigned -notcontains $name) { return }

        $scopedMode = Get-CceTeamsCopilotMeetingMode -Policy $_
        [pscustomobject]@{
            Name          = $name
            Mode          = $scopedMode
            Rank          = Get-CceCopilotMeetingModeRank -Mode $scopedMode
            Transcription = Get-CceTeamsMeetingPolicyFlag -Policy $_ -Name 'AllowTranscription'
        }
    })

    $scope
}

function Invoke-CceCheck31 {
    <# Mode Copilot des reunions : cible EnabledWithTranscript, croisee avec AllowTranscription #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $mode = Get-CceTeamsCopilotMeetingMode -Policy $policy

    if ([string]::IsNullOrWhiteSpace($mode)) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c31.obs.na') `
            -Evidence (T 'c31.ev.na') `
            -Remediation (T 'c31.rem.na')
    }

    $identityProperty = $policy.PSObject.Properties['Identity']
    $identity = if ($null -ne $identityProperty) { "$($identityProperty.Value)" -replace '^Tag:', '' } else { 'Global' }
    $transcription = Get-CceTeamsMeetingPolicyFlag -Policy $policy -Name 'AllowTranscription'
    $rank = Get-CceCopilotMeetingModeRank -Mode $mode

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c31.ev.default') -f $identity, $mode, $transcription))
    $evidence.Add((T 'c31.ev.target'))

    $scope = Get-CceTeamsMeetingPolicyScope -Context $Context
    $scoped = @($scope.Policies)

    if (-not $scope.Readable) {
        $evidence.Add((T 'c31.ev.scope.unknown'))
    }
    elseif ($scoped.Count -eq 0) {
        $evidence.Add((T 'c31.ev.scope.none'))
    }
    else {
        $evidence.Add(((T 'c31.ev.scope.header') -f $scoped.Count))
        foreach ($entry in $scoped) {
            $evidence.Add(((T 'c31.ev.scope.line') -f $entry.Name, $entry.Mode, $entry.Transcription))
        }
    }

    if ($rank -eq 'target' -and $transcription) {
        $status = 'Conforme'
        $observed = (T 'c31.obs.default') -f $mode, $transcription
        $remediation = ''
    }
    elseif ($rank -eq 'target') {
        # Le mode reclame une transcription que la strategie interdit : Copilot reste inoperant.
        $status = 'Non conforme'
        $observed = (T 'c31.obs.notranscript') -f $mode
        $evidence.Add(((T 'c31.ev.notranscript') -f $mode))
        $remediation = (T 'c31.rem.notranscript') -f $mode
    }
    elseif ($rank -eq 'weak') {
        # Enabled : mode actif le plus faible, sans transcription conservee donc sans
        # recapitulatif apres reunion, alors que les invites restent soumises a Purview.
        $status = 'Attention'
        $observed = (T 'c31.obs.weak') -f $mode
        $evidence.Add((T 'c31.ev.weak'))
        $evidence.Add((T 'c31.ev.compliance'))
        if (-not $transcription) { $evidence.Add(((T 'c31.ev.notranscript') -f $mode)) }
        $remediation = T 'c31.rem.weak'
    }
    elseif ($rank -eq 'off') {
        $status = 'Non conforme'
        $observed = (T 'c31.obs.off') -f $mode
        $evidence.Add((T 'c31.ev.off'))
        $remediation = T 'c31.rem.off'
    }
    else {
        $status = 'Attention'
        $observed = (T 'c31.obs.unknown') -f $mode
        $evidence.Add(((T 'c31.ev.unknown') -f $mode))
        $remediation = T 'c31.rem.unknown'
    }

    # Strategie Global en ecart alors qu'une strategie ciblee atteint la cible : le verdict
    # ne peut pas etre un echec franc, le perimetre reel depend de l'appartenance aux groupes.
    $covering = @($scoped | Where-Object { $_.Rank -eq 'target' -and $_.Transcription })
    if ($status -eq 'Non conforme' -and $covering.Count -gt 0) {
        $status = 'Attention'
        $observed = (T 'c31.obs.scope') -f $mode, $covering.Count
        $evidence.Add((T 'c31.ev.scope.covers'))
        $remediation = T 'c31.rem.scope'
    }

    New-CceResult -Status $status `
        -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText) `
        -Remediation $remediation
}

function Invoke-CceCheck32 {
    <# Sous-titres en direct actives #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $cart = [bool] (Get-CceTeamsValue -InputObject $policy -Name 'AllowCartCaptions')
    $live = "$(Get-CceTeamsValue -InputObject $policy -Name 'LiveCaptionsEnabledType')"
    $ok = $cart -or ($live -match 'Enabled')

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c32.obs.default') -f $cart, $live) `
        -Evidence ((T 'c32.ev.default') -f $cart, $live) `
        -Remediation $(if ($ok) { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -LiveCaptionsEnabledType EnabledUserOverride" })
}
