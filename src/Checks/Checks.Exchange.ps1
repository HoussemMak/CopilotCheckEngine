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

function Get-CceExoMailboxIndex {
    <#
    .SYNOPSIS
        Inventaire des boites aux lettres du tenant, indexe par UPN.
    .DESCRIPTION
        Un seul appel pagine (Get-EXOMailbox, transport REST) alimente une table
        UPN en minuscules -> RecipientTypeDetails, mise en cache dans le contexte.
        Renvoie $null si l'inventaire n'a pas pu etre construit ou revient vide :
        un index absent ne doit jamais etre confondu avec un tenant sans boite,
        sinon tous les utilisateurs seraient declares sans boite aux lettres.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('ExoMailboxIndex')) { return $Context.Cache['ExoMailboxIndex'] }
    if (-not $Context.Services.Exchange) { return $null }

    if (-not (Get-Command -Name 'Get-EXOMailbox' -ErrorAction SilentlyContinue)) {
        $Context.Cache['ExoMailboxIndex'] = $null
        return $null
    }

    Write-CceLog (T 'collect.exo.inventory') -Level INFO

    # La construction complete est enfermee dans Get-CceSafe : une propriete absente
    # ou un refus de la commande retombe sur $null, donc sur la resolution unitaire.
    $index = Get-CceSafe {
        $map = @{}
        foreach ($m in @(Get-EXOMailbox -ResultSize Unlimited -PropertySets Minimum -ErrorAction Stop)) {
            $upn = [string] $m.UserPrincipalName
            if ([string]::IsNullOrWhiteSpace($upn)) { continue }
            $map[$upn.ToLowerInvariant()] = [string] $m.RecipientTypeDetails
        }
        $map
    } -What 'Get-EXOMailbox'

    if ($index -isnot [hashtable] -or $index.Count -eq 0) { $index = $null }

    $Context.Cache['ExoMailboxIndex'] = $index
    $index
}

function Get-CceCopilotMailboxState {
    <#
    .SYNOPSIS
        Croise la population licenciee Copilot avec l'inventaire Exchange Online.
    .DESCRIPTION
        Population reduite (jusqu'a MailboxLookupMax, 200 par defaut) : une resolution
        unitaire par UPN, moins couteuse qu'un inventaire complet sur un grand tenant.
        Population large : inventaire complet du tenant, puis confirmation unitaire des
        seuls UPN absents de l'inventaire, pour qu'un UPN desynchronise ne soit pas
        compte a tort comme utilisateur sans boite aux lettres.
        Type = $null signifie "aucune boite aux lettres trouvee".
    #>
    [CmdletBinding()] param($Context, $Users)

    $people = @($Users)
    $max = [int] ($Context.Config['MailboxLookupMax'] ?? 200)
    $index = if ($people.Count -gt $max) { Get-CceExoMailboxIndex -Context $Context } else { $null }
    $useExo = [bool] (Get-Command -Name 'Get-EXOMailbox' -ErrorAction SilentlyContinue)

    $rows = [System.Collections.Generic.List[object]]::new()
    $confirmations = 0

    foreach ($u in $people) {
        $upn = [string] $u.UserPrincipalName
        if ([string]::IsNullOrWhiteSpace($upn)) { continue }

        $key = $upn.ToLowerInvariant()
        $type = $null

        if ($null -ne $index -and $index.ContainsKey($key)) {
            $type = $index[$key]
        }
        elseif ($null -eq $index -or $confirmations -lt $max) {
            if ($null -ne $index) { $confirmations++ }

            $type = if ($useExo) {
                Get-CceSafe { [string] (Get-EXOMailbox -Identity $upn -PropertySets Minimum -ErrorAction Stop).RecipientTypeDetails } -What "Get-EXOMailbox $upn"
            }
            else {
                Get-CceSafe { [string] (Get-Mailbox -Identity $upn -ErrorAction Stop).RecipientTypeDetails } -What "Get-Mailbox $upn"
            }
        }

        if ([string]::IsNullOrWhiteSpace($type)) { $type = $null }

        $rows.Add([pscustomobject]@{
            Upn     = $upn
            Enabled = [bool] $u.AccountEnabled
            Type    = $type
        })
    }

    [pscustomobject]@{
        Rows    = @($rows)
        Indexed = ($null -ne $index)
    }
}

function Invoke-CceCheck24 {
    <# Boite aux lettres principale UserMailbox dans Exchange Online pour chaque licencie Copilot #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    # Comparaison ensembliste avec la population licenciee : c'est le seul moyen de voir
    # l'utilisateur licencie qui n'a aucune boite, ou la licence Copilot posee sur une boite
    # partagee ou une ressource. Un comptage de RecipientTypeDetails ne les montre jamais.
    $licensed = @(Get-CceCopilotUser -Context $Context | Where-Object { $_.UserPrincipalName })

    if ($licensed.Count -gt 0) {
        $state = Get-CceCopilotMailboxState -Context $Context -Users $licensed
        $rows = @($state.Rows)
        $resolved = @($rows | Where-Object { $_.Type })

        # Resolution unitaire totalement muette : l'absence de boite ne se distingue pas
        # d'un refus de la commande, donc on ne tranche pas.
        if ((-not $state.Indexed) -and $rows.Count -gt 0 -and $resolved.Count -eq 0) {
            return New-CceResult -Status 'Non evalue' `
                -Observed ((T 'c24.obs.unresolved') -f $rows.Count) `
                -Evidence ((T 'c24.ev.unresolved') -f $rows.Count) `
                -Remediation (T 'c24.rem.unresolved')
        }

        $missing = @($rows | Where-Object { -not $_.Type })
        $wrong = @($rows | Where-Object { $_.Type -and $_.Type -ne 'UserMailbox' })
        $anomalies = @($missing) + @($wrong)
        $blocking = @($anomalies | Where-Object { $_.Enabled })
        $dormant = @($anomalies | Where-Object { -not $_.Enabled })

        if ($anomalies.Count -eq 0) {
            return New-CceResult -Status 'Conforme' `
                -Observed ((T 'c24.obs.userok') -f $rows.Count) `
                -Evidence ((T 'c24.ev.userok') -f $rows.Count)
        }

        $lines = foreach ($r in $anomalies) {
            $label = if ($r.Type) { $r.Type } else { T 'c24.ev.nomailbox' }
            if ($r.Enabled) { (T 'c24.ev.line') -f $r.Upn, $label }
            else { (T 'c24.ev.linedisabled') -f $r.Upn, $label }
        }

        # Aucun compte actif en defaut : la licence est gachee, Copilot n'est pas en panne.
        if ($blocking.Count -eq 0) {
            return New-CceResult -Status 'Attention' `
                -Observed ((T 'c24.obs.userwarn') -f $dormant.Count, $rows.Count) `
                -Evidence ($lines | ConvertTo-CceText) `
                -Remediation (T 'c24.rem.userwarn')
        }

        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c24.obs.userko') -f $anomalies.Count, $rows.Count, $missing.Count, $wrong.Count) `
            -Evidence ($lines | ConvertTo-CceText) `
            -Remediation (T 'c24.rem.userko')
    }

    # Repli : population licenciee inconnue (Microsoft Graph non connecte, ou aucune licence
    # Copilot attribuee). On conserve le signal historique sur un echantillon de boites, en
    # annoncant la limite dans la preuve.
    $sample = Get-CceMailboxSample -Context $Context
    if (-not $sample -or $sample.Count -eq 0) {
        return New-CceResult -Status 'Non evalue' -Observed (T 'c24.obs.none') `
            -Evidence (T 'c24.ev.none')
    }

    $groups = $sample | Group-Object RecipientTypeDetails | Sort-Object Count -Descending
    $onPrem = @($sample | Where-Object { $_.RecipientTypeDetails -in @('RemoteUserMailbox', 'MailUser', 'NotFound') })

    $observed = ($groups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' | '
    $note = T 'c24.ev.fallback'

    if ($onPrem.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c24.obs.ok') -f $sample.Count, $observed) `
            -Evidence (@($note) + @($groups | ForEach-Object { "$($_.Name) : $($_.Count)" }) | ConvertTo-CceText)
    }

    New-CceResult -Status 'Non conforme' `
        -Observed ((T 'c24.obs.ko') -f $onPrem.Count, $sample.Count, $observed) `
        -Evidence (@($note) + @($onPrem | ForEach-Object { "$($_.Upn) : $($_.RecipientTypeDetails)" }) | ConvertTo-CceText) `
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
