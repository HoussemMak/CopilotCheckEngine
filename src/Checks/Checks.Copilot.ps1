#Requires -Version 7.0
<# Controles 33 a 42 - ACTIVATION ET CONFIGURATION COPILOT #>

function Get-CceCopilotUsageReport {
    <#
    .SYNOPSIS
        Rapport d'usage Copilot par utilisateur (30 jours).
    .DESCRIPTION
        Seule source tenant permettant de constater qu'un workload Copilot est
        reellement actif : les bascules du centre d'administration Copilot ne sont
        pas exposees par une API publique.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotUsage')) { return $Context.Cache['CopilotUsage'] }
    if (-not $Context.Services.Graph) { return $null }

    $response = Invoke-CceGraphRequest -Quiet `
        -Uri "https://graph.microsoft.com/beta/reports/getMicrosoft365CopilotUsageUserDetail(period='D30')?`$format=application/json"

    $rows = if ($response) { @($response.value) } else { $null }
    $Context.Cache['CopilotUsage'] = $rows
    $rows
}

function Get-CceCopilotAdminSetting {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotAdminSettings')) { return $Context.Cache['CopilotAdminSettings'] }
    if (-not $Context.Services.Graph) { return $null }

    $settings = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/beta/copilot/admin/settings'
    $Context.Cache['CopilotAdminSettings'] = $settings
    $settings
}

function Get-CceWorkloadActivity {
    <#
    .SYNOPSIS
        Compte les utilisateurs ayant une activite Copilot par application sur 30 jours.
    #>
    [CmdletBinding()] param($Rows)

    $map = [ordered]@{
        'Copilot Chat' = 'copilotChatLastActivityDate'
        'Teams'        = 'microsoftTeamsCopilotLastActivityDate'
        'Word'         = 'wordCopilotLastActivityDate'
        'Excel'        = 'excelCopilotLastActivityDate'
        'PowerPoint'   = 'powerPointCopilotLastActivityDate'
        'Outlook'      = 'outlookCopilotLastActivityDate'
        'OneNote'      = 'oneNoteCopilotLastActivityDate'
        'Loop'         = 'loopCopilotLastActivityDate'
    }

    $result = [ordered]@{}
    foreach ($entry in $map.GetEnumerator()) {
        $count = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace("$($_.($entry.Value))") }).Count
        $result[$entry.Key] = $count
    }
    $result
}

function Invoke-CceCheck33 {
    <# Activer Copilot globalement au niveau du tenant #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context
    $settings = Get-CceCopilotAdminSetting -Context $Context

    $evidenceParts = [System.Collections.Generic.List[string]]::new()
    if ($settings) { $evidenceParts.Add("beta/copilot/admin/settings : " + ($settings | ConvertTo-Json -Depth 4 -Compress)) }

    if ($null -ne $rows) {
        $active = @($rows | Where-Object {
            $_.PSObject.Properties.Name -match 'LastActivityDate' -and
            @($_.PSObject.Properties | Where-Object { $_.Name -match 'LastActivityDate' -and -not [string]::IsNullOrWhiteSpace("$($_.Value)") }).Count -gt 0
        })

        $evidenceParts.Add(((T 'c33.ev.usage') -f $rows.Count, $active.Count))

        if ($active.Count -gt 0) {
            return New-CceResult -Status 'Conforme' `
                -Observed ((T 'c33.obs.ok') -f $active.Count) `
                -Evidence ($evidenceParts | ConvertTo-CceText)
        }

        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c33.obs.warn') -f $rows.Count) `
            -Evidence ($evidenceParts | ConvertTo-CceText) `
            -Remediation (T 'c33.rem.warn')
    }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c33.obs.manual') `
        -Evidence (($evidenceParts + (T 'c33.ev.manual')) | ConvertTo-CceText) `
        -Remediation (T 'c33.rem.manual')
}

function Invoke-CceCheck34 {
    <# Activer tous les workloads Copilot #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c34.obs.manual') `
            -Evidence (T 'c34.ev.manual') `
            -Remediation (T 'c34.rem.manual')
    }

    $activity = Get-CceWorkloadActivity -Rows $rows
    $core = @('Word', 'Excel', 'PowerPoint', 'Outlook', 'Teams')
    $silent = @($core | Where-Object { $activity[$_] -eq 0 })
    $observed = ($activity.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '

    if ($silent.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c34.obs.ok') -f $observed) `
            -Evidence ($activity.GetEnumerator() | ForEach-Object { (T 'c34.ev.line') -f $_.Key, $_.Value } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c34.obs.warn') -f ($silent -join ', '), $observed) `
        -Evidence (($activity.GetEnumerator() | ForEach-Object { (T 'c34.ev.line') -f $_.Key, $_.Value }) +
                   @(T 'c34.ev.note') | ConvertTo-CceText) `
        -Remediation (T 'c34.rem.warn')
}

function Invoke-CceCheck35 {
    <# Activer Copilot Chat (Microsoft 365 Chat) #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c35.obs.manual') `
            -Evidence (T 'c35.ev.manual') `
            -Remediation (T 'c35.rem.manual')
    }

    $chatUsers = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace("$($_.copilotChatLastActivityDate)") })

    if ($chatUsers.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c35.obs.ok') -f $chatUsers.Count) `
            -Evidence ($chatUsers | Select-Object -First 15 |
                ForEach-Object { "$($_.userPrincipalName) : $($_.copilotChatLastActivityDate)" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c35.obs.warn') -f $rows.Count) `
        -Evidence (T 'c35.ev.warn') `
        -Remediation (T 'c35.rem.warn')
}

function Invoke-CceCheck36 {
    <# Acces au contenu web et source de donnees Copilot Chat #>
    [CmdletBinding()] param($Context)

    $settings = Get-CceCopilotAdminSetting -Context $Context

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c36.obs.manual') `
        -Evidence ($(if ($settings) { "beta/copilot/admin/settings : " + ($settings | ConvertTo-Json -Depth 4 -Compress) } else { T 'c36.ev.none' })) `
        -Remediation (T 'c36.rem.manual')
}

function Invoke-CceCheck37 {
    <# Verifier la propagation de Copilot sur un utilisateur test #>
    [CmdletBinding()] param($Context)

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c37.obs.manual') `
            -Evidence (T 'c37.ev.manual') `
            -Remediation (T 'c37.rem.manual')
    }

    $active = @($rows | Where-Object {
        @($_.PSObject.Properties | Where-Object { $_.Name -match 'LastActivityDate' -and -not [string]::IsNullOrWhiteSpace("$($_.Value)") }).Count -gt 0
    })

    if ($active.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c37.obs.ok') -f $active.Count) `
            -Evidence ($active | Select-Object -First 10 | ForEach-Object { $_.userPrincipalName } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Attention' `
        -Observed (T 'c37.obs.warn') `
        -Evidence ((T 'c37.ev.warn') -f $rows.Count) `
        -Remediation (T 'c37.rem.warn')
}

function Invoke-CceCheck38 {
    <# Activer et consulter les rapports d'utilisation Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $rows = Get-CceCopilotUsageReport -Context $Context

    if ($null -eq $rows) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c38.obs.ko') `
            -Evidence (T 'c38.ev.ko') `
            -Remediation (T 'c38.rem.ko')
    }

    $anonymised = @($rows | Where-Object { "$($_.userPrincipalName)" -match '^[A-F0-9]{40,}$' }).Count

    if ($anonymised -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c38.obs.warn') -f $rows.Count) `
            -Evidence (T 'c38.ev.warn') `
            -Remediation (T 'c38.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c38.obs.ok') -f $rows.Count) `
        -Evidence (T 'c38.ev.ok')
}

function Invoke-CceCheck39 {
    <# Configurer Viva Insights pour le suivi d'adoption Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c39.obs.manual') `
        -Evidence (T 'c39.ev.manual') `
        -Remediation (T 'c39.rem.manual')
}

function Invoke-CceCheck40 {
    <# Configurer la generation d'images Copilot (Designer) #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c40.obs.manual') `
        -Evidence (T 'c40.ev.manual') `
        -Remediation (T 'c40.rem.manual')
}

function Invoke-CceCheck41 {
    <# Configurer Copilot dans Bing, Microsoft Edge et Windows #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c41.obs.manual') `
        -Evidence (T 'c41.ev.manual') `
        -Remediation (T 'c41.rem.manual')
}

function Invoke-CceCheck42 {
    <# Configurer la clause d'exclusion de responsabilite IA Copilot #>
    [CmdletBinding()] param($Context)

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c42.obs.manual') `
        -Evidence (T 'c42.ev.manual') `
        -Remediation (T 'c42.rem.manual')
}
