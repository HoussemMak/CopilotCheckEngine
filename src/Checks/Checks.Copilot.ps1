#Requires -Version 7.0
<# Controles 33 a 42 et 60 - ACTIVATION ET CONFIGURATION COPILOT #>

function Get-CceCopilotValue {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete : $null lorsqu'elle est absente.
    .DESCRIPTION
        Le schema des rapports d'usage et des reglages Copilot varie d'une version a
        l'autre (rapport v1 ou v2, endpoint beta ou v1.0). Sous Set-StrictMode, l'acces
        direct a une propriete absente leve une exception : elle ferait echouer le
        controle au lieu de simplement retirer une ligne de preuve.
    #>
    [CmdletBinding()] param($InputObject, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Get-CceCopilotOption {
    <#
    .SYNOPSIS
        Valeur d'un parametre d'execution, $null s'il n'a pas ete fourni.
    #>
    [CmdletBinding()] param($Context, [Parameter(Mandatory)] [string] $Name)

    if ($Context.Config -is [System.Collections.IDictionary] -and $Context.Config.Contains($Name)) {
        return $Context.Config[$Name]
    }
    $null
}

function Get-CceCopilotAdminPolicySetting {
    <#
    .SYNOPSIS
        Etat d'un reglage Copilot porte par le service de strategie cloud (Graph beta).
    .DESCRIPTION
        GET /beta/copilot/admin/policySettings/{id} distingue trois etats que le centre
        d'administration confond : valeur decidee, strategie tenant existante sans ce
        reglage, aucune strategie du tout. C'est exactement ce que les exigences 35, 36,
        40 et 60 demandent de constater.

        L'appel n'est volontairement pas passe par le collecteur mutualise : ici le code
        d'erreur porte l'information. Un 422 signale un reglage porte par une strategie
        de groupe, que l'API ne sait pas lire et qui reste donc a verifier manuellement ;
        un 403 signale une portee absente, ce qui n'est pas du tout le meme verdict.

        Lecture seule, resultat mis en cache : quatre controles interrogent cet endpoint.
    #>
    [CmdletBinding()] param($Context, [Parameter(Mandatory)] [string] $SettingId)

    if (-not $Context.Cache.ContainsKey('CopilotPolicySettings')) { $Context.Cache['CopilotPolicySettings'] = @{} }
    $store = $Context.Cache['CopilotPolicySettings']
    if ($store.ContainsKey($SettingId)) { return $store[$SettingId] }

    $entry = [pscustomobject]@{
        Id       = $SettingId
        Ok       = $false
        Decided  = $false
        Value    = ''
        PolicyId = ''
        Reason   = 'service'
        Detail   = ''
        Json     = ''
    }

    if ($Context.Services.Graph) {
        # Aucune permission applicative n'existe pour CopilotPolicySettings.Read :
        # en app-only, l'appel echouerait sans que la cause soit lisible dans la reponse.
        if ("$(Get-CceCopilotOption -Context $Context -Name 'AuthMode')" -eq 'application') {
            $entry.Reason = 'authmode'
        }
        else {
            try {
                $response = Invoke-MgGraphRequest -Method GET -OutputType PSObject -ErrorAction Stop `
                    -Uri ('https://graph.microsoft.com/beta/copilot/admin/policySettings/{0}' -f $SettingId)

                $entry.Ok = $true
                $entry.Reason = 'ok'
                $entry.Value = "$(Get-CceCopilotValue -InputObject $response -Name 'value')"
                $entry.PolicyId = "$(Get-CceCopilotValue -InputObject $response -Name 'policyId')"
                $entry.Decided = -not [string]::IsNullOrWhiteSpace($entry.Value)
                $entry.Json = "$(Get-CceSafe { $response | ConvertTo-Json -Depth 4 -Compress } -What $SettingId)"
            }
            catch {
                $detail = "$($_.Exception.Message)"
                if ($_.ErrorDetails) { $detail = ($detail + ' ' + "$($_.ErrorDetails.Message)").Trim() }

                $entry.Detail = $detail
                $entry.Reason = switch -Regex ($detail) {
                    'groupScopedSettingNotSupported|UnprocessableEntity|\b422\b'  { 'grouppolicy'; break }
                    'tooManyGroupPolicies|BadGateway|\b502\b'                     { 'toomany';     break }
                    'unsupportedSetting|NotFound|\b404\b'                         { 'unsupported'; break }
                    'Authorization_RequestDenied|AccessDenied|Forbidden|\b403\b'  { 'denied';      break }
                    default                                                       { 'error' }
                }
            }
        }
    }

    $store[$SettingId] = $entry
    $entry
}

function Get-CceCopilotUsageDetail {
    <#
    .SYNOPSIS
        Rapport d'usage Copilot par utilisateur : endpoint v1.0 et metriques v2.
    .DESCRIPTION
        Les rapports Copilot sont publies en v1.0 sous /copilot/reports et acceptent
        version='v2', qui ajoute les prompts soumis, les jours d'usage actif et une date
        de derniere activite par application (Copilot Chat travail et web, Edge, agents).

        Trois tentatives en cascade : v1.0 avec v2, v1.0 seul, puis l'ancien endpoint
        beta. Un tenant ou la version v2 n'est pas encore deployee continue ainsi d'etre
        mesure au lieu de basculer en "non evalue".

        L'enveloppe distingue un rapport vide d'une lecture impossible : PowerShell
        deroule un tableau vide en $null a la sortie d'une fonction, ce qui confondrait
        les deux.
    #>
    [CmdletBinding()] param($Context, [ValidateSet('D7', 'D28')] [string] $Period = 'D28')

    $cacheKey = "CopilotUsage.$Period"
    if ($Context.Cache.ContainsKey($cacheKey)) { return $Context.Cache[$cacheKey] }

    $detail = [pscustomobject]@{
        Ok          = $false
        Rows        = @()
        Source      = ''
        Period      = $Period
        Version     = ''
        RefreshDate = ''
    }

    if (-not $Context.Services.Graph) {
        $Context.Cache[$cacheKey] = $detail
        return $detail
    }

    # L'ancien endpoint beta ne connait pas la fenetre de 28 jours : le repli reprend
    # la fenetre historique plutot que de renvoyer une erreur de parametre.
    $legacyPeriod = if ($Period -eq 'D7') { 'D7' } else { 'D30' }

    $attempts = @(
        [pscustomobject]@{
            Source  = 'v1.0 version=v2'
            Version = 'v2'
            Period  = $Period
            Uri     = "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='$Period', version='v2')?`$format=application/json"
        }
        [pscustomobject]@{
            Source  = 'v1.0'
            Version = 'v1'
            Period  = $Period
            Uri     = "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='$Period')?`$format=application/json"
        }
        [pscustomobject]@{
            Source  = 'beta'
            Version = 'v1'
            Period  = $legacyPeriod
            Uri     = "https://graph.microsoft.com/beta/reports/getMicrosoft365CopilotUsageUserDetail(period='$legacyPeriod')?`$format=application/json"
        }
    )

    foreach ($attempt in $attempts) {
        $response = Invoke-CceGraphRequest -Quiet -Uri $attempt.Uri
        if ($null -eq $response) { continue }

        $rows = @(Get-CceCopilotValue -InputObject $response -Name 'value')
        if (@($rows).Count -eq 0 -and $response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
            $rows = @($response)
        }

        $detail.Ok = $true
        $detail.Source = $attempt.Source
        $detail.Version = $attempt.Version
        $detail.Period = $attempt.Period
        $detail.Rows = $rows

        foreach ($row in $rows) {
            $refresh = "$(Get-CceCopilotValue -InputObject $row -Name 'reportRefreshDate')"
            if ($refresh) { $detail.RefreshDate = $refresh; break }
        }

        break
    }

    $Context.Cache[$cacheKey] = $detail
    $detail
}

function Get-CceCopilotUsageReport {
    <#
    .SYNOPSIS
        Lignes du rapport d'usage Copilot, ou $null si le rapport n'est pas lisible.
    #>
    [CmdletBinding()] param($Context)

    $detail = Get-CceCopilotUsageDetail -Context $Context
    if (-not $detail.Ok) { return $null }
    @($detail.Rows)
}

function Get-CceCopilotAdminSetting {
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('CopilotAdminSettings')) { return $Context.Cache['CopilotAdminSettings'] }
    if (-not $Context.Services.Graph) { return $null }

    $settings = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/beta/copilot/admin/settings'
    $Context.Cache['CopilotAdminSettings'] = $settings
    $settings
}

function Get-CceReportSetting {
    <#
    .SYNOPSIS
        Parametres d'anonymisation des rapports d'utilisation du tenant.
    .DESCRIPTION
        displayConcealedNames a $true masque les identifiants dans tous les rapports
        d'usage : le pilotage nominatif de l'adoption devient impossible, et le rapport
        Copilot ne peut plus etre croise avec les licences attribuees.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('AdminReportSettings')) { return $Context.Cache['AdminReportSettings'] }

    $settings = $null
    if ($Context.Services.Graph) {
        $settings = Invoke-CceGraphRequest -Quiet -Uri 'https://graph.microsoft.com/v1.0/admin/reportSettings'
    }

    $Context.Cache['AdminReportSettings'] = $settings
    $settings
}

function Get-CceWorkloadActivity {
    <#
    .SYNOPSIS
        Nombre d'utilisateurs ayant une activite Copilot, application par application.
    .DESCRIPTION
        Les colonnes different entre la version v1 et la version v2 du rapport : la
        correspondance se fait par motif sur le nom de propriete, et une application
        dont aucune colonne n'est presente est simplement omise. Compter zero sur une
        colonne inexistante produirait un faux blocage de workload.
    #>
    [CmdletBinding()] param($Rows)

    $map = [ordered]@{
        'Copilot Chat'          = '^copilotchat(work)?lastactivitydate$'
        'Copilot Chat web'      = '^copilotchatweblastactivitydate$'
        'Microsoft 365 Copilot' = '^microsoft365copilotlastactivitydate$'
        'Teams'                 = 'teamscopilotlastactivitydate$'
        'Word'                  = '^wordcopilotlastactivitydate$'
        'Excel'                 = '^excelcopilotlastactivitydate$'
        'PowerPoint'            = '^powerpointcopilotlastactivitydate$'
        'Outlook'               = '^outlookcopilotlastactivitydate$'
        'OneNote'               = '^onenotecopilotlastactivitydate$'
        'Loop'                  = '^loopcopilotlastactivitydate$'
        'Edge'                  = '^edge.*lastactivitydate$'
        'Agents Copilot'        = 'agent.*lastactivitydate$'
    }

    $result = [ordered]@{}
    $rowList = @($Rows)
    if ($rowList.Count -eq 0) { return $result }

    $names = @($rowList[0].PSObject.Properties.Name)

    foreach ($entry in $map.GetEnumerator()) {
        $columns = @($names | Where-Object { $_ -match "(?i)$($entry.Value)" })
        if ($columns.Count -eq 0) { continue }

        $count = @($rowList | Where-Object {
            $row = $_
            @($columns | Where-Object {
                -not [string]::IsNullOrWhiteSpace("$(Get-CceCopilotValue -InputObject $row -Name $_)")
            }).Count -gt 0
        }).Count

        $result[$entry.Key] = $count
    }

    $result
}

function Measure-CceCopilotPromptVolume {
    <#
    .SYNOPSIS
        Volume de prompts soumis, expose par la version v2 du rapport ; $null sinon.
    .DESCRIPTION
        La colonne retenue est celle qui agrege toutes les applications lorsqu'elle
        existe : additionner toutes les colonnes de prompts compterait deux fois les
        prompts de Copilot Chat. Sert de preuve d'intensite d'usage, jamais de verdict :
        un changement de nom de colonne retire la ligne, il ne cree pas d'ecart.
    #>
    [CmdletBinding()] param($Rows)

    $rowList = @($Rows)
    if ($rowList.Count -eq 0) { return $null }

    $candidates = @($rowList[0].PSObject.Properties.Name | Where-Object { $_ -match '(?i)prompt' })
    if ($candidates.Count -eq 0) { return $null }

    $column = @($candidates | Where-Object { $_ -match '(?i)all' }) | Select-Object -First 1
    if (-not $column) { $column = $candidates[0] }

    $total = 0
    $users = 0

    foreach ($row in $rowList) {
        $parsed = 0
        if ([int]::TryParse("$(Get-CceCopilotValue -InputObject $row -Name $column)", [ref] $parsed)) {
            $total += $parsed
            if ($parsed -gt 0) { $users++ }
        }
    }

    [pscustomobject]@{ Column = $column; Prompts = $total; ActiveUsers = $users }
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

        $evidenceParts.Add(((T 'c33.ev.usage') -f @($rows).Count, $active.Count))

        if ($active.Count -gt 0) {
            return New-CceResult -Status 'Conforme' `
                -Observed ((T 'c33.obs.ok') -f $active.Count) `
                -Evidence ($evidenceParts | ConvertTo-CceText)
        }

        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c33.obs.warn') -f @($rows).Count) `
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
    # Une application absente du rapport n'est pas une application silencieuse :
    # seule une colonne presente et a zero constitue un constat.
    $silent = @($core | Where-Object { $activity.Contains($_) -and $activity[$_] -eq 0 })
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
    <#
        Epinglage de Microsoft 365 Copilot Chat.

        L'etat de configuration est desormais lu directement (microsoft.copilot.copilotchatpinning)
        au lieu d'etre deduit de l'usage : un tenant fraichement configure n'a aucune activite
        et etait signale en ecart, tandis qu'un tenant desepingle conservait de l'activite
        residuelle pendant des semaines. L'usage ne sert plus que de confirmation.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $setting = Get-CceCopilotAdminPolicySetting -Context $Context -SettingId 'microsoft.copilot.copilotchatpinning'
    $rows = Get-CceCopilotUsageReport -Context $Context

    $chatUsers = @()
    if ($null -ne $rows) {
        $chatUsers = @($rows | Where-Object {
            $row = $_
            @($row.PSObject.Properties | Where-Object {
                $_.Name -match '(?i)^copilotchat.*lastactivitydate$' -and -not [string]::IsNullOrWhiteSpace("$($_.Value)")
            }).Count -gt 0
        })
    }

    $evidence = [System.Collections.Generic.List[string]]::new()
    if ($setting.Ok) { $evidence.Add(((T 'c35.ev.raw') -f $setting.Id, $setting.Json)) }
    if ($null -ne $rows) { $evidence.Add(((T 'c35.ev.usage') -f $chatUsers.Count, @($rows).Count)) }
    $evidence.Add((T 'c35.ev.scope'))

    if ($setting.Ok) {
        if ($setting.Decided) {
            if ("$($setting.Value)" -match '^(0|false|disabled)$') {
                return New-CceResult -Status 'Attention' `
                    -Observed ((T 'c35.obs.unpinned') -f $setting.Value) `
                    -Evidence ($evidence | ConvertTo-CceText) `
                    -Remediation (T 'c35.rem.unpinned')
            }

            return New-CceResult -Status 'Conforme' `
                -Observed ((T 'c35.obs.pinned') -f $setting.Value) `
                -Evidence ($evidence | ConvertTo-CceText)
        }

        # Aucune valeur ecrite : l'epinglage par defaut s'applique, Copilot Chat reste
        # accessible. C'est un constat, pas une absence de mesure.
        $evidence.Add((T 'c35.ev.default'))

        return New-CceResult -Status 'Conforme' `
            -Observed (T 'c35.obs.default') `
            -Evidence ($evidence | ConvertTo-CceText)
    }

    # Reglage illisible : repli sur le constat d'usage, plus tardif mais reel.
    $reason = if ($setting.Reason -eq 'authmode') { T 'core.authmode.delegated' } else { $setting.Detail }
    $evidence.Add(((T 'c35.ev.probe') -f $setting.Id, $reason))

    if ($chatUsers.Count -gt 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c35.obs.ok') -f $chatUsers.Count) `
            -Evidence ((@($evidence) + @($chatUsers | Select-Object -First 10 |
                ForEach-Object { "$(Get-CceCopilotValue -InputObject $_ -Name 'userPrincipalName')" })) | ConvertTo-CceText -MaxItems 20)
    }

    if ($setting.Reason -eq 'grouppolicy') {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c35.obs.manual') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c35.rem.manual')
    }

    if ($null -eq $rows) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c35.obs.ne') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c35.rem.ne')
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c35.obs.warn') -f @($rows).Count) `
        -Evidence ((@($evidence) + @(T 'c35.ev.warn')) | ConvertTo-CceText) `
        -Remediation (T 'c35.rem.warn')
}

function Invoke-CceCheck36 {
    <#
        Acces au contenu web de Microsoft 365 Copilot et de Copilot Chat.

        Le reglage microsoft.copilot.allowwebsearch est lu directement : la decision est
        soit ecrite dans une strategie tenant, soit jamais prise. Point documente par
        Microsoft : sans strategie, la recherche web est ACTIVE par defaut. Une
        organisation qui n'a rien configure n'a donc pas un perimetre "M365 uniquement".
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $setting = Get-CceCopilotAdminPolicySetting -Context $Context -SettingId 'microsoft.copilot.allowwebsearch'
    $evidence = [System.Collections.Generic.List[string]]::new()

    if ($setting.Ok) {
        $evidence.Add(((T 'c36.ev.raw') -f $setting.Id, $setting.Json))

        if ($setting.Decided) {
            if ("$($setting.Value)" -match '^(0|false|disabled)$') { $evidence.Add((T 'c36.ev.off')) }
            elseif ("$($setting.Value)" -match '^(1|true|enabled)$') { $evidence.Add((T 'c36.ev.on')) }

            return New-CceResult -Status 'Conforme' `
                -Observed ((T 'c36.obs.ok') -f $setting.Value) `
                -Evidence ($evidence | ConvertTo-CceText)
        }

        $evidence.Add((T 'c36.ev.default'))

        if ($setting.PolicyId) {
            $evidence.Add(((T 'c36.ev.unset') -f $setting.PolicyId))

            return New-CceResult -Status 'Attention' `
                -Observed (T 'c36.obs.unset') `
                -Evidence ($evidence | ConvertTo-CceText) `
                -Remediation (T 'c36.rem.decide')
        }

        $evidence.Add((T 'c36.ev.none'))

        return New-CceResult -Status 'Attention' `
            -Observed (T 'c36.obs.nopolicy') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c36.rem.decide')
    }

    if ($setting.Reason -eq 'grouppolicy') {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c36.obs.manual') `
            -Evidence ((T 'c36.ev.group') -f $setting.Detail) `
            -Remediation (T 'c36.rem.manual')
    }

    if ($setting.Reason -eq 'authmode') {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c36.obs.ne') `
            -Evidence (T 'core.authmode.delegated') `
            -Remediation (T 'c36.rem.auth')
    }

    New-CceResult -Status 'Non evalue' `
        -Observed (T 'c36.obs.ne') `
        -Evidence ((T 'c36.ev.ne') -f $setting.Detail) `
        -Remediation (T 'c36.rem.ne')
}

function Invoke-CceCheck37 {
    <#
        Propagation de Copilot demontree workload par workload.

        La version v2 du rapport expose une date de derniere activite par application :
        le controle ne se contente plus d'une activite globale, il distingue un blocage
        Outlook d'un blocage Teams. Fenetre de 7 jours conforme a la sonde documentee.

        Deux delais encadrent l'interpretation : Copilot peut mettre 24 heures a
        apparaitre dans une application apres l'attribution de la licence, et le rapport
        lui-meme accuse jusqu'a 72 heures de latence.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $usage = Get-CceCopilotUsageDetail -Context $Context -Period 'D7'

    if (-not $usage.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c37.obs.manual') `
            -Evidence (T 'c37.ev.manual') `
            -Remediation (T 'c37.rem.manual')
    }

    $rows = @($usage.Rows)
    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c37.ev.source') -f $usage.Source, $usage.Period, @($rows).Count))

    if (@($rows).Count -eq 0) {
        $evidence.Add((T 'c37.ev.latency'))

        return New-CceResult -Status 'Attention' `
            -Observed (T 'c37.obs.none') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c37.rem.none')
    }

    $activity = Get-CceWorkloadActivity -Rows $rows
    foreach ($entry in $activity.GetEnumerator()) {
        $evidence.Add(((T 'c37.ev.line') -f $entry.Key, $entry.Value, @($rows).Count))
    }

    $volume = Measure-CceCopilotPromptVolume -Rows $rows
    if ($null -ne $volume) { $evidence.Add(((T 'c37.ev.prompts') -f $volume.Prompts, $volume.ActiveUsers, $volume.Column)) }

    $chat = 0
    foreach ($key in @('Copilot Chat', 'Copilot Chat web', 'Microsoft 365 Copilot')) {
        if ($activity.Contains($key)) { $chat += [int] $activity[$key] }
    }

    $core = @('Word', 'Outlook', 'Teams')
    $live = @($core | Where-Object { $activity.Contains($_) -and [int] $activity[$_] -gt 0 })
    $silent = @($core | Where-Object { $activity.Contains($_) -and [int] $activity[$_] -eq 0 })

    $summary = ($activity.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '
    $evidence.Add((T 'c37.ev.latency'))

    # Attendu : Copilot Chat plus au moins deux applications parmi Word, Outlook et Teams.
    if ($chat -gt 0 -and $live.Count -ge 2) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c37.obs.ok') -f $summary) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30)
    }

    if ($chat -eq 0 -and $live.Count -eq 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c37.obs.warn') -f @($rows).Count) `
            -Evidence ((@($evidence) + @((T 'c37.ev.warn') -f @($rows).Count)) | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c37.rem.warn')
    }

    # Une application dont la colonne est absente du rapport reste a verifier au meme
    # titre qu'une colonne a zero : le silence ne prouve pas la propagation.
    $pending = @($core | Where-Object { $_ -notin $live })
    if ($silent.Count -gt 0) { $pending = $silent }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c37.obs.partial') -f $summary) `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation ((T 'c37.rem.partial') -f ($pending -join ', '))
}

function Invoke-CceCheck38 {
    <#
        Rapports d'utilisation Copilot : disponibilite, fraicheur et anonymisation.

        Trois constats sont produits ensemble parce qu'un seul ne suffit pas a conclure :
        l'endpoint v1.0 repond (le rapport existe), reportRefreshDate est recent (les
        donnees affichees sont celles du deploiement en cours), et displayConcealedNames
        est connu (un rapport anonymise interdit tout pilotage nominatif de l'adoption).
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $usage = Get-CceCopilotUsageDetail -Context $Context -Period 'D28'

    if (-not $usage.Ok) {
        return New-CceResult -Status 'Non conforme' `
            -Observed (T 'c38.obs.ko') `
            -Evidence (T 'c38.ev.ko') `
            -Remediation (T 'c38.rem.ko')
    }

    $rows = @($usage.Rows)
    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c38.ev.source') -f $usage.Source, $usage.Period, @($rows).Count))

    # Second appel du meme namespace : il prouve que la synthese v1.0 repond elle aussi.
    $summary = Invoke-CceGraphRequest -Quiet `
        -Uri "https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUserCountSummary(period='D28', version='v2')?`$format=application/json"

    if ($summary) {
        $json = Get-CceSafe { $summary | ConvertTo-Json -Depth 4 -Compress } -What 'getMicrosoft365CopilotUserCountSummary'
        $evidence.Add(((T 'c38.ev.summary') -f "$json"))
    }
    else {
        $evidence.Add((T 'c38.ev.summary.ko'))
    }

    # Fraicheur : Microsoft annonce une mise a disposition sous 48 heures, au-dela de
    # trois jours le rapport ne decrit plus l'etat courant du deploiement.
    $age = $null
    if ($usage.RefreshDate) {
        $refreshed = [datetime]::MinValue
        if ([datetime]::TryParse($usage.RefreshDate, [ref] $refreshed)) {
            $age = [int] [math]::Floor(((Get-Date) - $refreshed).TotalDays)
        }
    }

    if ($null -ne $age) { $evidence.Add(((T 'c38.ev.refresh') -f $usage.RefreshDate, $age)) }
    else { $evidence.Add((T 'c38.ev.refresh.unknown')) }

    $reportSettings = Get-CceReportSetting -Context $Context
    $concealed = $null
    if ($reportSettings) {
        $flag = Get-CceCopilotValue -InputObject $reportSettings -Name 'displayConcealedNames'
        if ($null -ne $flag) { $concealed = [bool] $flag }
    }

    if ($concealed -eq $true) { $evidence.Add((T 'c38.ev.concealed.on')) }
    elseif ($concealed -eq $false) { $evidence.Add((T 'c38.ev.concealed.off')) }
    else { $evidence.Add((T 'c38.ev.concealed.unknown')) }

    # Repli si la portee ReportSettings.Read.All manque : un identifiant hache dans le
    # rapport trahit la meme anonymisation.
    $hashed = @($rows | Where-Object {
        "$(Get-CceCopilotValue -InputObject $_ -Name 'userPrincipalName')" -match '^[A-F0-9]{40,}$'
    }).Count

    if ($concealed -eq $true -or $hashed -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c38.obs.warn') -f @($rows).Count) `
            -Evidence ((@($evidence) + @(T 'c38.ev.warn')) | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c38.rem.warn')
    }

    if ($null -ne $age -and $age -gt 3) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c38.obs.stale') -f $usage.RefreshDate, $age) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c38.rem.stale')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c38.obs.ok') -f @($rows).Count, $usage.Source) `
        -Evidence ((@($evidence) + @(T 'c38.ev.ok')) | ConvertTo-CceText -MaxItems 20)
}

function Get-CceVivaInsightsFeature {
    <#
    .SYNOPSIS
        Inventaire des fonctionnalites Viva Insights et de leur etat d'acces (VFAM).
    .DESCRIPTION
        Le controle d'acces dedie "Copilot Dashboard" du centre d'administration et son
        ancienne commande PowerShell n'existent plus : l'acces au tableau de bord suit
        desormais celui de l'application web Viva Insights, lisible par Viva Feature
        Access Management depuis Exchange Online (module 3.2.0 et superieur).
        Lecture seule, resultat mis en cache.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('VivaInsightsFeatures')) { return $Context.Cache['VivaInsightsFeatures'] }

    $result = [pscustomobject]@{ Available = $false; Ok = $false; Features = @(); Detail = '' }

    if ($Context.Services.Exchange -and (Get-Command -Name 'Get-VivaModuleFeature' -ErrorAction SilentlyContinue)) {
        $result.Available = $true
        try {
            $features = Get-VivaModuleFeature -ModuleId VivaInsights -ErrorAction Stop
            $result.Ok = $true
            $result.Features = @($features)
        }
        catch {
            $result.Detail = "$($_.Exception.Message)"
        }
    }

    $Context.Cache['VivaInsightsFeatures'] = $result
    $result
}

function Invoke-CceCheck39 {
    <#
        Copilot Dashboard de Viva Insights : etat reel d'acces.

        Ce qui est mesure : aucune politique Viva Feature Access Management ne desactive
        l'application web Viva Insights ni les fonctionnalites de tableau de bord pour
        l'ensemble du tenant. Ce qui ne l'est pas, faute d'API : la taille minimale de
        groupe et le televersement des attributs organisationnels, sans lesquels le
        tableau de bord s'affiche mais reste vide de toute segmentation.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Exchange -Context $Context)) { return New-CceNotEvaluated -Service Exchange -Context $Context }

    $inventory = Get-CceVivaInsightsFeature -Context $Context

    if (-not $inventory.Available) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c39.obs.ne') `
            -Evidence (T 'c39.ev.module') `
            -Remediation (T 'c39.rem.module')
    }

    if (-not $inventory.Ok) {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c39.obs.ne') `
            -Evidence ((T 'c39.ev.ne') -f $inventory.Detail) `
            -Remediation (T 'c39.rem.ne')
    }

    $features = @($inventory.Features)
    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add(((T 'c39.ev.features') -f $features.Count))

    $targets = @($features | Where-Object {
        $label = "$(Get-CceCopilotValue -InputObject $_ -Name 'FeatureId') $(Get-CceCopilotValue -InputObject $_ -Name 'Name')"
        $label -match '(?i)(web ?app|dashboard|insight)'
    } | Select-Object -First 6)

    if ($targets.Count -eq 0) {
        $evidence.Add(((T 'c39.ev.nofeature') -f (@($features | ForEach-Object {
            "$(Get-CceCopilotValue -InputObject $_ -Name 'FeatureId')" }) -join ', ')))

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c39.obs.ne') `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
            -Remediation (T 'c39.rem.ne')
    }

    $blocked = [System.Collections.Generic.List[string]]::new()
    $scoped = [System.Collections.Generic.List[string]]::new()
    $unreadable = 0

    foreach ($feature in $targets) {
        $featureId = "$(Get-CceCopilotValue -InputObject $feature -Name 'FeatureId')"
        if (-not $featureId) { continue }

        $policies = Get-CceSafe { Get-VivaModuleFeaturePolicy -ModuleId VivaInsights -FeatureId $featureId -ErrorAction Stop } `
            -What "Get-VivaModuleFeaturePolicy $featureId"

        if ($null -eq $policies) {
            $unreadable++
            $evidence.Add(((T 'c39.ev.policy.unknown') -f $featureId))
            continue
        }

        $list = @($policies)
        if ($list.Count -eq 0) {
            $evidence.Add(((T 'c39.ev.policy.none') -f $featureId))
            continue
        }

        foreach ($policy in $list) {
            $name = "$(Get-CceCopilotValue -InputObject $policy -Name 'PolicyName')"
            if (-not $name) { $name = "$(Get-CceCopilotValue -InputObject $policy -Name 'Name')" }
            if (-not $name) { $name = "$(Get-CceCopilotValue -InputObject $policy -Name 'PolicyId')" }

            $enabled = Get-CceCopilotValue -InputObject $policy -Name 'IsFeatureEnabled'
            $everyone = Get-CceCopilotValue -InputObject $policy -Name 'Everyone'

            if ($enabled -eq $false) {
                if ($everyone -eq $true) {
                    $blocked.Add("$featureId / $name")
                    $evidence.Add(((T 'c39.ev.policy.block') -f $featureId, $name))
                }
                else {
                    $scoped.Add("$featureId / $name")
                    $evidence.Add(((T 'c39.ev.policy.scoped') -f $featureId, $name))
                }
            }
            else {
                $evidence.Add(((T 'c39.ev.policy.ok') -f $featureId, $name))
            }
        }
    }

    if ($unreadable -gt 0) { $evidence.Add(((T 'c39.ev.partial') -f $unreadable)) }
    $evidence.Add((T 'c39.ev.manual'))

    if ($blocked.Count -gt 0) {
        return New-CceResult -Status 'Non conforme' `
            -Observed ((T 'c39.obs.ko') -f $blocked.Count) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c39.rem.ko')
    }

    if ($scoped.Count -gt 0) {
        return New-CceResult -Status 'Attention' `
            -Observed ((T 'c39.obs.warn') -f $scoped.Count) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
            -Remediation (T 'c39.rem.warn')
    }

    New-CceResult -Status 'Conforme' `
        -Observed ((T 'c39.obs.ok') -f $targets.Count) `
        -Evidence ((@($evidence) + @(T 'c39.rem.manual')) | ConvertTo-CceText -MaxItems 30)
}

function Invoke-CceCheck40 {
    <#
        Generation d'images Copilot (Designer).

        Meme mecanique que le controle 36, sur l'identifiant microsoft.copilot.imagegeneration :
        la fonctionnalite est active par defaut et exposee dans PowerPoint comme dans
        Copilot Chat, donc l'absence de decision est un constat a porter au rapport.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $setting = Get-CceCopilotAdminPolicySetting -Context $Context -SettingId 'microsoft.copilot.imagegeneration'
    $evidence = [System.Collections.Generic.List[string]]::new()

    if ($setting.Ok) {
        $evidence.Add(((T 'c40.ev.raw') -f $setting.Id, $setting.Json))

        if ($setting.Decided) {
            if ("$($setting.Value)" -match '^(0|false|disabled)$') { $evidence.Add((T 'c40.ev.off')) }
            elseif ("$($setting.Value)" -match '^(1|true|enabled)$') { $evidence.Add((T 'c40.ev.on')) }

            return New-CceResult -Status 'Conforme' `
                -Observed ((T 'c40.obs.ok') -f $setting.Value) `
                -Evidence ($evidence | ConvertTo-CceText)
        }

        $evidence.Add((T 'c40.ev.manual'))

        if ($setting.PolicyId) {
            $evidence.Add(((T 'c40.ev.unset') -f $setting.PolicyId))

            return New-CceResult -Status 'Attention' `
                -Observed (T 'c40.obs.unset') `
                -Evidence ($evidence | ConvertTo-CceText) `
                -Remediation (T 'c40.rem.decide')
        }

        $evidence.Add((T 'c40.ev.none'))

        return New-CceResult -Status 'Attention' `
            -Observed (T 'c40.obs.nopolicy') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c40.rem.decide')
    }

    if ($setting.Reason -eq 'grouppolicy') {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c40.obs.manual') `
            -Evidence ((T 'c40.ev.group') -f $setting.Detail) `
            -Remediation (T 'c40.rem.manual')
    }

    if ($setting.Reason -eq 'authmode') {
        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c40.obs.ne') `
            -Evidence (T 'core.authmode.delegated') `
            -Remediation (T 'c40.rem.auth')
    }

    New-CceResult -Status 'Non evalue' `
        -Observed (T 'c40.obs.ne') `
        -Evidence ((T 'c40.ev.ne') -f $setting.Detail) `
        -Remediation (T 'c40.rem.ne')
}

function Test-CceIntuneEntitlement {
    <#
    .SYNOPSIS
        Vrai si le tenant detient un plan de service Intune actif.
    .DESCRIPTION
        Sert au controle 41 a distinguer deux echecs de lecture que rien ne separe
        cote Graph : un droit manquant (a corriger, donc "Non evalue") et un tenant
        sans Intune, dont la strategie Edge est alors portee par le service de gestion
        Microsoft Edge du centre d'administration, qui n'expose aucun endpoint public.
    #>
    [CmdletBinding()] param($Context)

    foreach ($sku in @(Get-CceSubscribedSku -Context $Context)) {
        $enabled = if ($sku.PrepaidUnits -and $null -ne $sku.PrepaidUnits.Enabled) { [int] $sku.PrepaidUnits.Enabled } else { 1 }
        if ($enabled -le 0) { continue }

        foreach ($plan in @($sku.ServicePlans)) {
            # INTUNE_O365 est la gestion des appareils mobiles incluse dans Office 365 :
            # elle ne donne pas acces au catalogue de parametres, donc elle ne compte pas.
            $name = "$($plan.ServicePlanName)"
            if ($name -match '(?i)INTUNE' -and $name -notmatch '(?i)INTUNE_O365') { return $true }
        }
    }

    $false
}

function Get-CceIntuneConfigurationPolicy {
    <#
    .SYNOPSIS
        Strategies du catalogue de parametres Intune, parametres inclus.
    .DESCRIPTION
        Renvoie toujours un objet enveloppe : le drapeau Ok distingue l'echec de lecture
        d'un tenant reellement depourvu de strategie, distinction qu'un tableau vide
        perdrait (PowerShell deroule @() en $null a la sortie d'une fonction).
        Repli sans $expand si l'expansion echoue, puis lecture des parametres strategie
        par strategie, plafonnee pour ne pas exploser le nombre d'appels.
    #>
    [CmdletBinding()] param($Context)

    if ($Context.Cache.ContainsKey('IntuneConfigPolicies')) { return $Context.Cache['IntuneConfigPolicies'] }

    $failed = [pscustomobject]@{ Ok = $false; Policies = @(); Expanded = $false; Truncated = 0 }

    if (-not $Context.Services.Graph) {
        $Context.Cache['IntuneConfigPolicies'] = $failed
        return $failed
    }

    $base = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'
    $expanded = $true
    $response = Invoke-CceGraphRequest -Quiet -Uri ($base + '?$expand=settings&$top=100')

    if ($null -eq $response) {
        $expanded = $false
        $response = Invoke-CceGraphRequest -Quiet -Uri ($base + '?$top=100')
    }

    if ($null -eq $response) {
        $Context.Cache['IntuneConfigPolicies'] = $failed
        return $failed
    }

    $policies = [System.Collections.Generic.List[object]]::new()
    $page = 0
    while ($response -and $page -lt 5) {
        foreach ($policy in (Get-CceResponseValue $response)) { $policies.Add($policy) }
        $page++

        $next = $response.'@odata.nextLink'
        if (-not $next) { break }
        $response = Invoke-CceGraphRequest -Quiet -Uri $next
    }

    $truncated = 0
    if (-not $expanded) {
        $inspected = 0
        foreach ($policy in $policies) {
            if ($inspected -ge 20) { $truncated++; continue }
            $inspected++

            $detail = Invoke-CceGraphRequest -Quiet -Uri ('{0}/{1}/settings' -f $base, $policy.id)
            if ($detail) {
                Get-CceSafe { $policy | Add-Member -NotePropertyName 'settings' -NotePropertyValue (Get-CceResponseValue $detail) -Force } `
                    -What 'configurationPolicies/settings' | Out-Null
            }
        }
    }

    $result = [pscustomobject]@{ Ok = $true; Policies = @($policies); Expanded = $expanded; Truncated = $truncated }
    $Context.Cache['IntuneConfigPolicies'] = $result
    $result
}

function Get-CceCopilotPolicySettingId {
    <#
    .SYNOPSIS
        Identifiants de parametres lies a Copilot portes par une strategie Intune.
    .DESCRIPTION
        Les instances de parametres du catalogue sont imbriquees (groupes, choix,
        collections) : la lecture par expression reguliere sur la representation JSON
        est la seule facon fiable d'atteindre tous les settingDefinitionId.
    #>
    [CmdletBinding()] param($Policy)

    $json = Get-CceSafe { $Policy.settings | ConvertTo-Json -Depth 25 -Compress } -What 'configurationPolicies/settings'
    if (-not $json) { return @() }

    @([regex]::Matches($json, '(?i)"settingDefinitionId"\s*:\s*"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -match '(?i)copilot' } |
        Sort-Object -Unique)
}

function Get-CceConfigurationPolicyAssignmentCount {
    <#
    .SYNOPSIS
        Nombre d'affectations d'une strategie Intune ; $null si la lecture echoue.
    #>
    [CmdletBinding()] param($PolicyId)

    $response = Invoke-CceGraphRequest -Quiet `
        -Uri ('https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{0}/assignments' -f $PolicyId)

    if ($null -eq $response) { return $null }
    (Get-CceResponseValue $response).Count
}

function Invoke-CceCheck41 {
    <#
        Strategie de configuration Microsoft Edge couvrant les parametres Copilot.

        Le scenario "Copilot dans Bing, Microsoft Edge et Windows" de la page Copilot du
        centre d'administration n'est pas configurable : c'est une page informative, et
        Copilot dans Windows a ete retire pour les comptes commerciaux. Le seul levier
        reel est la strategie de configuration Edge, lisible via le catalogue de
        parametres Intune lorsqu'elle y est deployee.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $intune = Test-CceIntuneEntitlement -Context $Context
    $fetch = Get-CceIntuneConfigurationPolicy -Context $Context
    $evidence = [System.Collections.Generic.List[string]]::new()

    if (-not $fetch -or -not $fetch.Ok) {
        # Intune present mais illisible : c'est un droit qui manque, pas une capacite absente.
        if ($intune) {
            $evidence.Add(((T 'c41.ev.ne') -f 'beta/deviceManagement/configurationPolicies'))
            $evidence.Add((T 'c41.ev.note'))

            return New-CceResult -Status 'Non evalue' `
                -Observed (T 'c41.obs.ne') `
                -Evidence ($evidence | ConvertTo-CceText) `
                -Remediation (T 'c41.rem.ne')
        }

        $evidence.Add((T 'c41.ev.manual'))
        $evidence.Add((T 'c41.ev.note'))

        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c41.obs.manual') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c41.rem.manual')
    }

    $policies = @($fetch.Policies)
    $matched = [System.Collections.Generic.List[object]]::new()
    $settingCount = 0

    foreach ($policy in $policies) {
        $edgeIds = @(Get-CceCopilotPolicySettingId -Policy $policy | Where-Object { $_ -match '(?i)edge' })
        if ($edgeIds.Count -eq 0) { continue }

        $settingCount += $edgeIds.Count
        $matched.Add([pscustomobject]@{ Id = "$($policy.id)"; Name = "$($policy.name)"; Settings = $edgeIds })
    }

    if ($fetch.Truncated -gt 0) { $evidence.Add(((T 'c41.ev.truncated') -f $fetch.Truncated)) }

    if ($matched.Count -eq 0) {
        $evidence.Add((T 'c41.ev.note'))

        # Sans Intune, l'absence de strategie ne prouve rien : le service de gestion Edge
        # du centre d'administration peut en porter une, sans API pour la lire.
        if (-not $intune) {
            $evidence.Add((T 'c41.ev.manual'))

            return New-CceResult -Status 'Manuel' `
                -Observed (T 'c41.obs.manual') `
                -Evidence ($evidence | ConvertTo-CceText) `
                -Remediation (T 'c41.rem.manual')
        }

        $observed = if ($policies.Count -eq 0) { T 'c41.obs.warn.none' } else { (T 'c41.obs.warn.nocopilot') -f $policies.Count }

        return New-CceResult -Status 'Attention' `
            -Observed $observed `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c41.rem.warn')
    }

    $assigned = 0
    $unassigned = 0
    $unknown = 0

    foreach ($entry in ($matched | Select-Object -First 10)) {
        $evidence.Add(((T 'c41.ev.policy') -f $entry.Name, $entry.Settings.Count, ($entry.Settings -join ', ')))

        $count = Get-CceConfigurationPolicyAssignmentCount -PolicyId $entry.Id
        if ($null -eq $count) {
            $unknown++
            $evidence.Add(((T 'c41.ev.assign.unknown') -f $entry.Name))
        }
        elseif ($count -gt 0) {
            $assigned++
            $evidence.Add(((T 'c41.ev.assign.ok') -f $entry.Name, $count))
        }
        else {
            $unassigned++
            $evidence.Add(((T 'c41.ev.assign.none') -f $entry.Name))
        }
    }

    $evidence.Add((T 'c41.ev.note'))

    # Affectations illisibles : on ne degrade pas le verdict d'une limite de lecture,
    # la strategie attendue existe. Seule une strategie explicitement non affectee alerte.
    if ($assigned -gt 0 -or $unassigned -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c41.obs.ok') -f $matched.Count, $settingCount) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 30)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c41.obs.warn.unassigned') -f $matched.Count) `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation (T 'c41.rem.warn.unassigned')
}

function Invoke-CceCheck42 {
    <#
        Vision (partage d'ecran et de camera) et rappel IA porte par la charte d'usage.

        Aucun parametre "clause d'exclusion de responsabilite IA" n'existe dans le
        centre d'administration : les scenarios reellement offerts sous "Actions Copilot"
        sont la generation d'images, Vision et Copilot dans les reunions Teams. Vision est
        actif par defaut et n'est expose par aucune API publique : le controle reste donc
        manuel, mais il porte enfin sur un reglage qui existe.
    #>
    [CmdletBinding()] param($Context)

    $evidence = [System.Collections.Generic.List[string]]::new()
    $evidence.Add((T 'c42.ev.manual'))

    $settings = Get-CceCopilotAdminSetting -Context $Context
    if ($settings) {
        $json = Get-CceSafe { $settings | ConvertTo-Json -Depth 4 -Compress } -What 'copilot/admin/settings'
        if ($json) { $evidence.Add(((T 'c42.ev.settings') -f $json)) }
    }

    # Sonde de courtoisie : si Microsoft expose un jour un identifiant Vision, la preuve
    # le remontera sans que le verdict, lui, se fonde sur une hypothese.
    if ($Context.Services.Graph) {
        $probe = 'beta/copilot/admin/policySettings'
        $policySettings = Invoke-CceGraphRequest -Quiet -Uri "https://graph.microsoft.com/$probe"

        $candidates = @()
        if ($policySettings) {
            $raw = Get-CceSafe { $policySettings | ConvertTo-Json -Depth 6 -Compress } -What 'copilot/admin/policySettings'
            if ($raw) {
                $candidates = @([regex]::Matches($raw, '(?i)"(?:id|displayName)"\s*:\s*"([^"]*(?:vision|screen|camera)[^"]*)"') |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            }
        }

        if ($candidates.Count -gt 0) {
            $evidence.Add(((T 'c42.ev.found') -f $probe, $candidates.Count, ($candidates -join ', ')))
        }
        else {
            $evidence.Add(((T 'c42.ev.probe') -f $probe))
        }
    }

    New-CceResult -Status 'Manuel' `
        -Observed (T 'c42.obs.manual') `
        -Evidence ($evidence | ConvertTo-CceText) `
        -Remediation (T 'c42.rem.manual')
}

function Invoke-CceCheck88 {
    <#
        Deux reglages Copilot que le referentiel ne couvrait pas.

        microsoft.copilot.blockaccesstoopenfiles gouverne le contenu du fichier ou de la
        page ouverte a l'ecran : c'est le symetrique du sur-partage. La decouverte
        restreinte, la recherche SharePoint restreinte et les etiquettes de confidentialite
        agissent sur l'index, pas sur un document deja ouvert par l'utilisateur.

        microsoft.copilot.allowinadmincenters gouverne Copilot a l'interieur des consoles
        d'administration, donc une surface manipulee par des comptes a privileges eleves.

        Les deux sont actionnables dans le meme ecran et lus par le meme endpoint : le
        cout marginal du second constat est nul.
    #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceService -Service Graph -Context $Context)) { return New-CceNotEvaluated -Service Graph -Context $Context }

    $settingIds = @('microsoft.copilot.blockaccesstoopenfiles', 'microsoft.copilot.allowinadmincenters')

    $evidence = [System.Collections.Generic.List[string]]::new()
    $decided = [System.Collections.Generic.List[string]]::new()
    $undecided = [System.Collections.Generic.List[string]]::new()
    $unreadable = 0
    $grouped = 0
    $delegated = 0

    foreach ($settingId in $settingIds) {
        $setting = Get-CceCopilotAdminPolicySetting -Context $Context -SettingId $settingId

        if ($setting.Ok) {
            $evidence.Add(((T 'c88.ev.raw') -f $settingId, $setting.Json))

            if ($setting.Decided) {
                $decided.Add($settingId)
                $evidence.Add(((T 'c88.ev.decided') -f $settingId, $setting.Value))
            }
            elseif ($setting.PolicyId) {
                $undecided.Add($settingId)
                $evidence.Add(((T 'c88.ev.unset') -f $settingId, $setting.PolicyId))
            }
            else {
                $undecided.Add($settingId)
                $evidence.Add(((T 'c88.ev.nopolicy') -f $settingId))
            }

            continue
        }

        $unreadable++

        if ($setting.Reason -eq 'grouppolicy') {
            $grouped++
            $evidence.Add(((T 'c88.ev.group') -f $settingId, $setting.Detail))
        }
        elseif ($setting.Reason -eq 'authmode') {
            $delegated++
            $evidence.Add(((T 'c88.ev.auth') -f $settingId))
        }
        else {
            $evidence.Add(((T 'c88.ev.ne') -f $settingId, $setting.Detail))
        }
    }

    if ($unreadable -eq $settingIds.Count) {
        if ($delegated -gt 0) {
            return New-CceResult -Status 'Non evalue' `
                -Observed (T 'c88.obs.ne') `
                -Evidence ((@($evidence) + @(T 'core.authmode.delegated')) | ConvertTo-CceText) `
                -Remediation (T 'c88.rem.auth')
        }

        if ($grouped -eq $settingIds.Count) {
            return New-CceResult -Status 'Manuel' `
                -Observed (T 'c88.obs.manual') `
                -Evidence ($evidence | ConvertTo-CceText) `
                -Remediation (T 'c88.rem.manual')
        }

        return New-CceResult -Status 'Non evalue' `
            -Observed (T 'c88.obs.ne') `
            -Evidence ($evidence | ConvertTo-CceText) `
            -Remediation (T 'c88.rem.ne')
    }

    if ($undecided.Count -eq 0) {
        return New-CceResult -Status 'Conforme' `
            -Observed ((T 'c88.obs.ok') -f ($decided -join ', ')) `
            -Evidence ($evidence | ConvertTo-CceText -MaxItems 20)
    }

    New-CceResult -Status 'Attention' `
        -Observed ((T 'c88.obs.warn') -f $undecided.Count, ($undecided -join ', ')) `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
        -Remediation (T 'c88.rem.decide')
}
