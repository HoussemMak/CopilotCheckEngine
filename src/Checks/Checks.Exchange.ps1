#Requires -Version 7.0
<# Controles 24 a 26 - EXCHANGE ONLINE #>

function Get-CceMailboxSample {
    <#
    .SYNOPSIS
        Echantillon de boites aux lettres des utilisateurs Copilot (taille pilotee par -MailboxSampleSize).
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('MailboxSample')) { return $Context.Cache['MailboxSample'] }
    if (-not $Context.Services.Exchange) { return @() }

    $size = [int] ($Context.Config.MailboxSampleSize ?? 100)
    $users = @(Get-CceCopilotUser -Context $Context | Where-Object { $_.AccountEnabled } | Select-Object -First $size)

    $result = [System.Collections.Generic.List[object]]::new()

    if ($users.Count -gt 0) {
        Write-CceLog ((T 'collect.exo.mailboxes') -f $users.Count) -Level INFO
        foreach ($u in $users) {
            $mbx = Get-CceSafe { Get-Mailbox -Identity $u.UserPrincipalName -ErrorAction Stop } -What "Get-Mailbox $($u.UserPrincipalName)"
            if ($mbx) {
                $result.Add([pscustomobject]@{
                    Upn                  = $u.UserPrincipalName
                    RecipientTypeDetails = "$($mbx.RecipientTypeDetails)"
                    Identity             = $mbx.Identity
                })
            }
            else {
                # Sentinelle technique : elle voisine les valeurs Exchange (UserMailbox,
                # RemoteUserMailbox) dans la colonne constatee, donc elle reste en anglais
                # comme elles et n'est pas localisee.
                $result.Add([pscustomobject]@{
                    Upn                  = $u.UserPrincipalName
                    RecipientTypeDetails = 'NotFound'
                    Identity             = $null
                })
            }
        }
    }
    else {
        # Aucun utilisateur licencie : on echantillonne le tenant pour donner un signal.
        $mbxs = Get-CceSafe { Get-Mailbox -ResultSize $size -ErrorAction Stop } -What 'Get-Mailbox (echantillon)'
        foreach ($m in @($mbxs)) {
            $result.Add([pscustomobject]@{
                Upn                  = $m.UserPrincipalName
                RecipientTypeDetails = "$($m.RecipientTypeDetails)"
                Identity             = $m.Identity
            })
        }
    }

    $Context.Cache['MailboxSample'] = @($result)
    $Context.Cache['MailboxSample']
}

function Invoke-CceCheck24 {
    <# Les boites aux lettres sont dans Exchange Online #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $sample = Get-CceMailboxSample -Context $Context
    if (-not $sample -or $sample.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' -Observed (T 'c24.obs.none') `
            -Evidence (T 'c24.ev.none')
    }

    $groups = $sample | Group-Object RecipientTypeDetails | Sort-Object Count -Descending
    $onPrem = @($sample | Where-Object { $_.RecipientTypeDetails -in @('RemoteUserMailbox', 'MailUser', 'NotFound') })

    $observed = ($groups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' | '

    if ($onPrem.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c24.obs.ok') -f $sample.Count, $observed) `
            -Evidence ($groups | ForEach-Object { "$($_.Name) : $($_.Count)" } | ConvertTo-CceText)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c24.obs.ko') -f $onPrem.Count, $sample.Count, $observed) `
        -Evidence ($onPrem | ForEach-Object { "$($_.Upn) : $($_.RecipientTypeDetails)" } | ConvertTo-CceText) `
        -Remediation (T 'c24.rem.ko')
}

function Invoke-CceCheck25 {
    <# MAPI active sur les boites Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $sample = @(Get-CceMailboxSample -Context $Context | Where-Object { $_.Identity })
    if ($sample.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' -Observed (T 'c25.obs.none') -Evidence (T 'c25.ev.none')
    }

    $disabled = [System.Collections.Generic.List[string]]::new()

    foreach ($m in $sample) {
        $cas = Get-CceSafe { Get-CASMailbox -Identity $m.Identity -ErrorAction Stop } -What "Get-CASMailbox $($m.Upn)"
        if ($cas -and -not $cas.MAPIEnabled) { $disabled.Add($m.Upn) }
    }

    if ($disabled.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c25.obs.ok') -f $sample.Count) `
            -Evidence (T 'c25.ev.ok')
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c25.obs.ko') -f $disabled.Count, $sample.Count) `
        -Evidence ($disabled | ConvertTo-CceText) `
        -Remediation "Set-CASMailbox -Identity <upn> -MAPIEnabled `$true"
}

function Invoke-CceCheck26 {
    <# Audit unifie et audit des boites aux lettres actives #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $auditCfg = Get-CceSafe { Get-AdminAuditLogConfig -ErrorAction Stop } -What 'Get-AdminAuditLogConfig'
    $orgCfg = Get-CceSafe { Get-OrganizationConfig -ErrorAction Stop } -What 'Get-OrganizationConfig'

    if (-not $auditCfg) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $unified = [bool] $auditCfg.UnifiedAuditLogIngestionEnabled
    $mailboxAuditDisabled = if ($orgCfg) { [bool] $orgCfg.AuditDisabled } else { $null }

    $observed = "UnifiedAuditLogIngestionEnabled=$unified | AuditDisabled=$mailboxAuditDisabled"
    $ok = $unified -and ($mailboxAuditDisabled -ne $true)

    New-CceResult -Status $(if ($ok) { 'Conforme' } else { 'Non conforme' }) `
        -Observed $observed -Evidence $observed `
        -Remediation $(if ($ok) { '' } else { T 'c26.rem.ko' })
}
