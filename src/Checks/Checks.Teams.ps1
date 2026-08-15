#Requires -Version 7.0
<# Controles 27 a 32 - MICROSOFT TEAMS POUR COPILOT #>

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

    $apps = @($response.value) | Where-Object { "$($_.displayName)" -match 'copilot' }
    $Context.Cache['CopilotTeamsApps'] = @($apps)
    $Context.Cache['CopilotTeamsApps']
}

function Invoke-CceCheck27 {
    <# Autoriser l'application Copilot dans les strategies Teams #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Teams -Context $Context)) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $policy = Get-CceSafe { Get-CsTeamsAppPermissionPolicy -Identity Global -ErrorAction Stop } -What 'Get-CsTeamsAppPermissionPolicy'
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $mode = "$($policy.DefaultCatalogAppsType)"
    $globalMode = "$($policy.GlobalCatalogAppsType)"
    $blocked = @($policy.DefaultCatalogApps) + @($policy.GlobalCatalogApps)
    $copilotApps = Get-CceCopilotTeamsApp -Context $Context
    $copilotIds = @($copilotApps.id)

    $blockedCopilot = @($blocked | Where-Object { $copilotIds -contains "$($_.Id)" })

    $observed = "DefaultCatalogAppsType=$mode | GlobalCatalogAppsType=$globalMode"

    if ($mode -eq 'BlockedAppList' -and $blockedCopilot.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c27.obs.ok') -f $observed) `
            -Evidence ((T 'c27.ev.ok') -f (($copilotApps.displayName) -join ', '))
    }

    if ($blockedCopilot.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c27.obs.ko') -f $observed) `
            -Evidence ($blockedCopilot | ForEach-Object { (T 'c27.ev.line.blocked') -f $_.Id } | ConvertTo-CceText) `
            -Remediation (T 'c27.rem.ko')
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c27.obs.warn') -f $observed) `
        -Evidence (@((T 'c27.ev.warn.header') -f (($copilotApps.displayName) -join ', ')) +
                   @($blocked | ForEach-Object { (T 'c27.ev.warn.line') -f $_.Id }) | ConvertTo-CceText) `
        -Remediation (T 'c27.rem.warn')
}

function Invoke-CceCheck28 {
    <# Epingler Copilot dans la barre laterale Teams #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Teams -Context $Context)) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $policy = Get-CceSafe { Get-CsTeamsAppSetupPolicy -Identity Global -ErrorAction Stop } -What 'Get-CsTeamsAppSetupPolicy'
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $pinned = @($policy.PinnedAppBarApps)
    $copilotApps = Get-CceCopilotTeamsApp -Context $Context
    $copilotIds = @($copilotApps.id)

    $pinnedCopilot = @($pinned | Where-Object { $copilotIds -contains "$($_.Id)" })

    if ($copilotIds.Count -eq 0) {
        return New-CceResult -Status 'Manuel' `
            -Observed ((T 'c28.obs.manual') -f $pinned.Count) `
            -Evidence ($pinned | ForEach-Object { (T 'c28.ev.line.order') -f $_.Id, $_.Order } | ConvertTo-CceText) `
            -Remediation (T 'c28.rem.manual')
    }

    if ($pinnedCopilot.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c28.obs.ok') -f $pinned.Count) `
            -Evidence ($pinnedCopilot | ForEach-Object { (T 'c28.ev.line.pinned') -f $_.Id } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c28.obs.ko') -f $pinned.Count) `
        -Evidence (@((T 'c28.ev.ko.header') -f (($copilotApps.displayName) -join ', ')) +
                   @($pinned | ForEach-Object { (T 'c28.ev.line.pinned') -f $_.Id }) | ConvertTo-CceText) `
        -Remediation (T 'c28.rem.ko')
}

function Invoke-CceCheck29 {
    <# Transcription des reunions activee #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $value = [bool] $policy.AllowTranscription

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

    $value = [bool] $policy.AllowCloudRecording

    New-CceResult -Status $(if ($value) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c30.obs.default') -f $value) `
        -Evidence ((T 'c30.ev.default') -f $value) `
        -Remediation $(if ($value) { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -AllowCloudRecording `$true" })
}

function Invoke-CceCheck31 {
    <# Mode Copilot pour les reunions #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $mode = "$($policy.CopilotMode)"

    if ([string]::IsNullOrWhiteSpace($mode)) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c31.obs.na') `
            -Evidence (T 'c31.ev.na') `
            -Remediation (T 'c31.rem.na')
    }

    $status = switch -Regex ($mode) {
        'Disabled'                     { 'Non conforme' }
        'EnabledWithMeetingTranscript' { 'Conforme' }
        'Enabled'                      { 'Conforme' }
        default                        { 'Attention' }
    }

    New-CceResult -Status $status `
        -Observed ((T 'c31.obs.default') -f $mode) `
        -Evidence ((T 'c31.ev.default') -f $mode) `
        -Remediation $(if ($status -eq 'Conforme') { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -CopilotMode Enabled" })
}

function Invoke-CceCheck32 {
    <# Sous-titres en direct actives #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $cart = [bool] $policy.AllowCartCaptions
    $live = "$($policy.LiveCaptionsEnabledType)"
    $ok = $cart -or ($live -match 'Enabled')

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Attention' }) `
        -Observed ((T 'c32.obs.default') -f $cart, $live) `
        -Evidence ((T 'c32.ev.default') -f $cart, $live) `
        -Remediation $(if ($ok) { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -LiveCaptionsEnabledType EnabledUserOverride" })
}
