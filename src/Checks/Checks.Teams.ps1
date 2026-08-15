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
            -Observed "$observed - aucune application Copilot bloquee" `
            -Evidence ("Applications Copilot du catalogue detectees : " + (($copilotApps.displayName) -join ', '))
    }

    if ($blockedCopilot.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed "$observed - application Copilot explicitement bloquee" `
            -Evidence ($blockedCopilot | ForEach-Object { "Bloquee : $($_.Id)" } | ConvertTo-CceText) `
            -Remediation "Retirer l'application Copilot de la liste bloquee dans la strategie d'autorisation d'applications Teams."
    }

    New-CceResult -Status 'Attention' `
        -Observed "$observed - strategie en liste blanche : verifier que Copilot y figure" `
        -Evidence (@("Applications Copilot du catalogue : " + (($copilotApps.displayName) -join ', ')) +
                   @($blocked | ForEach-Object { "Entree strategie : $($_.Id)" }) | ConvertTo-CceText) `
        -Remediation "La strategie fonctionne en liste d'autorisation : ajouter explicitement Microsoft 365 Copilot aux applications autorisees."
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
            -Observed ("{0} application(s) epinglee(s) - catalogue Copilot non resolu" -f $pinned.Count) `
            -Evidence ($pinned | ForEach-Object { "$($_.Id) (ordre $($_.Order))" } | ConvertTo-CceText) `
            -Remediation "Verifier dans le centre d'administration Teams que Microsoft 365 Copilot est epingle dans la strategie de configuration d'applications."
    }

    if ($pinnedCopilot.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ("Copilot epingle ({0} application(s) epinglee(s) au total)" -f $pinned.Count) `
            -Evidence ($pinnedCopilot | ForEach-Object { "Epinglee : $($_.Id)" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ("Copilot non epingle ({0} application(s) epinglee(s))" -f $pinned.Count) `
        -Evidence (@("Applications Copilot disponibles : " + (($copilotApps.displayName) -join ', ')) +
                   @($pinned | ForEach-Object { "Epinglee : $($_.Id)" }) | ConvertTo-CceText) `
        -Remediation "Ajouter Microsoft 365 Copilot aux applications epinglees de la strategie de configuration globale Teams."
}

function Invoke-CceCheck29 {
    <# Transcription des reunions activee #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $value = [bool] $policy.AllowTranscription

    New-CceResult -Status $(if ($value) { 'Conforme' } else { 'Non conforme' }) `
        -Observed ("AllowTranscription = {0} (strategie Global)" -f $value) `
        -Evidence "Get-CsTeamsMeetingPolicy -Identity Global : AllowTranscription = $value" `
        -Remediation $(if ($value) { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -AllowTranscription `$true (prerequis des resumes de reunion Copilot)" })
}

function Invoke-CceCheck30 {
    <# Enregistrement cloud des reunions active #>
    [CmdletBinding()] param($Context)

    $policy = Get-CceTeamsMeetingPolicy -Context $Context
    if (-not $policy) { return New-CceNotEvaluated -Service Teams -Context $Context }

    $value = [bool] $policy.AllowCloudRecording

    New-CceResult -Status $(if ($value) { 'Conforme' } else { 'Attention' }) `
        -Observed ("AllowCloudRecording = {0} (strategie Global)" -f $value) `
        -Evidence "Get-CsTeamsMeetingPolicy -Identity Global : AllowCloudRecording = $value" `
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
            -Observed 'Propriete CopilotMode absente de la strategie' `
            -Evidence "La strategie Global ne remonte pas CopilotMode (module MicrosoftTeams a mettre a jour ou tenant sans Copilot)." `
            -Remediation "Mettre a jour le module MicrosoftTeams puis verifier CopilotMode."
    }

    $status = switch -Regex ($mode) {
        'Disabled'                     { 'Non conforme' }
        'EnabledWithMeetingTranscript' { 'Conforme' }
        'Enabled'                      { 'Conforme' }
        default                        { 'Attention' }
    }

    New-CceResult -Status $status `
        -Observed ("CopilotMode = {0} (strategie Global)" -f $mode) `
        -Evidence "Get-CsTeamsMeetingPolicy -Identity Global : CopilotMode = $mode" `
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
        -Observed ("AllowCartCaptions = {0} | LiveCaptionsEnabledType = {1}" -f $cart, $live) `
        -Evidence "Get-CsTeamsMeetingPolicy -Identity Global : AllowCartCaptions = $cart, LiveCaptionsEnabledType = $live" `
        -Remediation $(if ($ok) { '' } else { "Set-CsTeamsMeetingPolicy -Identity Global -LiveCaptionsEnabledType EnabledUserOverride" })
}
