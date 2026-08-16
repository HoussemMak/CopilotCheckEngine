#Requires -Version 7.0
<#
    Controles 68 a 71 - RESEAU ET POSTE DE TRAVAIL

    Ce domaine est le seul qui explique le cas "tout est vert dans le tenant et Copilot
    ne fonctionne pas". Blocage du protocole WebSocket par le perimetre reseau, re-signature
    TLS par un boitier d'inspection, tache planifiee Office Feature Updates desactivee,
    runtime WebView2 absent, cookies tiers bloques par strategie de navigateur, activation
    d'Office par licence d'appareil : aucun de ces six points n'est visible depuis une
    console d'administration Microsoft 365, et tous cassent Copilot sur un tenant par
    ailleurs parfaitement configure.

    PORTEE DE PREUVE. Ces controles mesurent LE POSTE COURANT et le chemin reseau emprunte
    par ce poste. Un poste conforme ne vaut pas pour le parc : le resultat doit etre lu
    comme celui d'un poste de reference, jamais comme une mesure de population.

    EXECUTION. Les quatre controles exigent $Context.Config.IncludeLocalChecks. Sans ce
    commutateur, ils rendent 'Manuel' avec la procedure a derouler sur un poste de reference.

    LECTURE SEULE STRICTE. Aucune connexion applicative n'est ouverte, aucun paquet n'est
    telecharge, aucune valeur de registre et aucune tache planifiee n'est modifiee. Les
    sondes reseau se limitent a une ouverture TCP, a une negociation TLS dont seul
    l'emetteur du certificat presente est lu, et a un handshake WebSocket immediatement
    abandonne. Tous les appels sortants portent un delai d'expiration court, sont plafonnes
    en nombre d'hotes, et retombent sur un resultat exploitable au lieu de lever.
#>

# Hierarchie des statuts mesures par ce domaine : un controle ne peut que se degrader
# au fil des sondes, jamais remonter.
$script:CceNetStatusRank = @{ 'Conforme' = 0; 'Attention' = 1; 'Non conforme' = 2 }

# Emetteurs de certificat legitimes pour un hote Microsoft 365.
# Le motif Microsoft est volontairement ancre sur l'organisation et non sur le simple mot
# 'microsoft' : une autorite d'entreprise interne peut porter ce mot dans son nom sans etre
# Microsoft. Le second motif liste les autorites publiques que Microsoft documente comme
# racines de confiance pour Microsoft 365 : les rencontrer est normal et n'est en aucun cas
# une preuve d'inspection TLS. Seul un emetteur hors de ces deux ensembles revele un
# boitier qui dechiffre et re-signe le trafic.
$script:CceNetMicrosoftIssuerPattern = '(?i)o=microsoft corporation|cn=microsoft'
$script:CceNetPublicIssuerPattern = '(?i)digicert|baltimore|globalsign|entrust|geotrust|sectigo|verisign|thawte|godaddy|amazon|isrg|let''s encrypt'

# Domaines Microsoft 365 dont le blocage de cookies casse Copilot dans les applications web.
$script:CceNetM365CookiePattern = '(?i)microsoft|office|sharepoint|onedrive|live\.com|cloud\.microsoft|officeapps'

function Get-CceNetProperty {
    <#
    .SYNOPSIS
        Lecture defensive d'une propriete, sur un objet comme sur un dictionnaire.
    .DESCRIPTION
        Le moteur tourne en Set-StrictMode Latest : referencer une propriete absente leve.
        Les reponses de endpoints.office.com, les exceptions .NET et les cles de registre
        n'exposent pas toujours les memes membres selon la version : tout passe par ici.
    #>
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory)] [string] $Name)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function Get-CceNetworkOption {
    <#
    .SYNOPSIS
        Option d'execution du domaine reseau, avec valeur par defaut.
    #>
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory)] [string] $Name, $Default = $null)

    if ($null -eq $Context) { return $Default }

    $config = Get-CceNetProperty -InputObject $Context -Name 'Config'
    if ($null -eq $config) { return $Default }

    $value = Get-CceNetProperty -InputObject $config -Name $Name
    if ($null -eq $value) { return $Default }
    if ("$value".Trim().Length -eq 0) { return $Default }

    $value
}

function Test-CceLocalScope {
    <# Vrai si l'execution est autorisee a inspecter le poste courant. #>
    [CmdletBinding()] param($Context)

    [bool] (Get-CceNetworkOption -Context $Context -Name 'IncludeLocalChecks' -Default $false)
}

function Get-CceNetworkTimeout {
    <# Delai d'expiration des sondes sortantes, en secondes (1 a 30, defaut 8). #>
    [CmdletBinding()] param($Context)

    $value = Get-CceNetworkOption -Context $Context -Name 'NetworkTimeoutSeconds' -Default 8
    $parsed = 0
    if ([int]::TryParse("$value", [ref] $parsed) -and $parsed -ge 1 -and $parsed -le 30) { return $parsed }
    8
}

function Get-CceWorstNetStatus {
    <# Combine deux statuts : le plus degrade l'emporte. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Current, [Parameter(Mandatory)] [string] $Candidate)

    if (-not $script:CceNetStatusRank.ContainsKey($Current)) { return $Candidate }
    if (-not $script:CceNetStatusRank.ContainsKey($Candidate)) { return $Current }
    if ($script:CceNetStatusRank[$Candidate] -gt $script:CceNetStatusRank[$Current]) { return $Candidate }
    $Current
}

function Get-CceRegistryItem {
    <# Contenu d'une cle de registre, ou $null si absente ou illisible. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Path)

    if (-not $IsWindows) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    Get-CceSafe { Get-ItemProperty -LiteralPath $Path -ErrorAction Stop } -What $Path
}

function Get-CceRegistryValue {
    <# Valeur de registre, ou $null si la cle ou la valeur est absente. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Name)

    Get-CceNetProperty -InputObject (Get-CceRegistryItem -Path $Path) -Name $Name
}

function Test-CceTcpEndpoint {
    <#
    .SYNOPSIS
        Ouverture TCP simple vers un hote, sans echange applicatif.
    .DESCRIPTION
        La socket est fermee immediatement apres l'etablissement : aucune requete n'est
        emise. Test-NetConnection n'est pas utilise, il n'existe pas hors Windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostName,
        [int] $Port = 443,
        [int] $TimeoutSeconds = 8
    )

    $result = [pscustomobject]@{
        HostName = $HostName
        Port     = $Port
        Success  = $false
        TimedOut = $false
        Error    = ''
    }

    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostName, $Port)

        if ($task.Wait([timespan]::FromSeconds($TimeoutSeconds))) {
            $result.Success = [bool] $client.Connected
        }
        else {
            $result.TimedOut = $true
        }
    }
    catch {
        $result.Error = "$($_.Exception.Message)"
    }
    finally {
        if ($null -ne $client) { try { $client.Dispose() } catch { Write-Debug 'Echec de liberation de ressource, ignore.' } }
    }

    $result
}

function Get-CceTlsIssuer {
    <#
    .SYNOPSIS
        Emetteur du certificat presente par un hote en TLS.
    .DESCRIPTION
        Le rappel de validation accepte toute chaine : l'objectif est precisement
        d'observer un certificat qui ne serait PAS approuve, signature d'un boitier
        d'inspection qui dechiffre et re-signe le trafic. Aucune requete applicative
        n'est emise apres la negociation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostName,
        [int] $Port = 443,
        [int] $TimeoutSeconds = 8
    )

    $result = [pscustomobject]@{
        HostName = $HostName
        Port     = $Port
        Success  = $false
        TimedOut = $false
        Issuer   = ''
        Subject  = ''
        Error    = ''
    }

    $client = $null
    $stream = $null
    $ssl = $null

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($HostName, $Port)

        if (-not $task.Wait([timespan]::FromSeconds($TimeoutSeconds))) {
            $result.TimedOut = $true
            return $result
        }
        if (-not $client.Connected) { return $result }

        $client.ReceiveTimeout = $TimeoutSeconds * 1000
        $client.SendTimeout = $TimeoutSeconds * 1000

        $accept = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($origin, $certificate, $chain, $errors)
            $true
        }

        $stream = $client.GetStream()
        $ssl = [System.Net.Security.SslStream]::new($stream, $false, $accept)
        $ssl.AuthenticateAsClient($HostName)

        $certificate = $ssl.RemoteCertificate
        if ($null -ne $certificate) {
            $result.Issuer = "$($certificate.Issuer)"
            $result.Subject = "$($certificate.Subject)"
            $result.Success = $true
        }
    }
    catch {
        $result.Error = "$($_.Exception.Message)"
    }
    finally {
        foreach ($disposable in @($ssl, $stream, $client)) {
            if ($null -ne $disposable) { try { $disposable.Dispose() } catch { Write-Debug 'Echec de liberation de ressource, ignore.' } }
        }
    }

    $result
}

function Test-CceWebSocketEndpoint {
    <#
    .SYNOPSIS
        Handshake WebSocket (WSS) vers un hote, immediatement abandonne.
    .DESCRIPTION
        Trois issues sont distinguees, parce qu'elles ne se remedient pas de la meme facon :
        - Connected : la negociation 101 a abouti, le protocole WSS traverse le perimetre ;
        - Answered  : le serveur a repondu par un code HTTP (refus applicatif), ce qui
          prouve malgre tout que la demande d'Upgrade a traverse le proxy ;
        - ni l'un ni l'autre : echec au niveau transport, seul cas reellement suspect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri, [int] $TimeoutSeconds = 8)

    $result = [pscustomobject]@{
        Uri        = $Uri
        Connected  = $false
        Answered   = $false
        HttpStatus = ''
        Error      = ''
    }

    $socket = $null
    $cancellation = $null

    try {
        $target = [uri] $Uri
        $socket = [System.Net.WebSockets.ClientWebSocket]::new()
        $cancellation = [System.Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSeconds))

        # La tache est inspectee plutot qu'attendue par GetResult : PowerShell enveloppe
        # sinon l'exception et masque la WebSocketException, seule porteuse du code HTTP
        # reellement renvoye. Sans cette precaution, un refus applicatif serait pris pour
        # un blocage de protocole, c'est-a-dire un verdict faux.
        $task = $socket.ConnectAsync($target, $cancellation.Token)

        # Wait leve lui-meme une AggregateException quand la tache echoue : l'etat de la
        # tache est donc inspecte apres coup, jamais depuis le bloc catch, sans quoi le
        # message .NET utile reste enfoui sous l'enveloppe PowerShell.
        $completed = $false
        try { $completed = $task.Wait([timespan]::FromSeconds($TimeoutSeconds + 2)) }
        catch { $completed = $task.IsCompleted }

        if (-not $completed) {
            # Delai depasse sans reponse : ni connexion, ni refus. Error reste vide,
            # l'appelant distingue ce cas d'un refus documente par un message .NET.
            $result.Connected = $false
        }
        elseif ($task.IsFaulted -or $task.IsCanceled) {
            $errors = [System.Collections.Generic.List[string]]::new()

            if ($null -ne $task.Exception) {
                foreach ($item in @($task.Exception.Flatten().InnerExceptions)) {
                    if ($null -eq $item) { continue }
                    $errors.Add("$($item.Message)")

                    $status = Get-CceNetProperty -InputObject $item -Name 'HttpStatusCode'
                    if ($null -ne $status -and "$status".Trim().Length -gt 0 -and "$status" -ne '0') {
                        $result.Answered = $true
                        $result.HttpStatus = "$status"
                    }
                }
            }

            $result.Error = ($errors -join ' / ')

            # Repli : .NET ne renseigne pas toujours HttpStatusCode, mais le message porte
            # le code renvoye. Un code autre que 101 prouve que la demande d'Upgrade a
            # atteint un serveur, donc que le protocole WSS n'est pas filtre en transit.
            if (-not $result.Answered) {
                foreach ($match in [regex]::Matches($result.Error, "status code '(\d{3})'")) {
                    $code = $match.Groups[1].Value
                    if ($code -ne '101') {
                        $result.Answered = $true
                        $result.HttpStatus = $code
                        break
                    }
                }
            }
        }
        else {
            $result.Connected = $true
            $result.Answered = $true
        }
    }
    catch {
        $result.Error = "$($_.Exception.Message)"
    }
    finally {
        if ($null -ne $socket) {
            try { $socket.Abort() } catch { Write-Debug 'Echec de liberation de ressource, ignore.' }
            try { $socket.Dispose() } catch { Write-Debug 'Echec de liberation de ressource, ignore.' }
        }
        if ($null -ne $cancellation) { try { $cancellation.Dispose() } catch { Write-Debug 'Echec de liberation de ressource, ignore.' } }
    }

    $result
}

function Get-CceOfficeEndpointList {
    <#
    .SYNOPSIS
        Liste de reference des endpoints Microsoft 365 (API publique, sans authentification).
    .DESCRIPTION
        Un seul appel par execution, mis en cache dans le contexte : les controles 68 et 69
        exploitent la meme reponse. Delai d'expiration court, echec silencieux.
    #>
    [CmdletBinding()] param($Context)

    if ($null -ne $Context -and $Context.Cache.ContainsKey('OfficeEndpoints')) {
        return $Context.Cache['OfficeEndpoints']
    }

    $timeout = Get-CceNetworkTimeout -Context $Context
    $uri = "https://endpoints.office.com/endpoints/worldwide?clientrequestid=$([guid]::NewGuid().ToString())"

    $data = Get-CceSafe {
        Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $timeout -MaximumRedirection 2 -ErrorAction Stop
    } -What 'endpoints.office.com'

    $list = if ($null -eq $data) { @() } else { @($data) }
    if ($null -ne $Context) { $Context.Cache['OfficeEndpoints'] = $list }
    $list
}

function Get-CceOfficeEndpointEntry {
    <# Entree du service d'endpoints Microsoft 365 portant l'identifiant demande. #>
    [CmdletBinding()] param($Endpoints, [Parameter(Mandatory)] [int] $Id)

    foreach ($entry in @($Endpoints)) {
        if ($null -eq $entry) { continue }
        $value = "$(Get-CceNetProperty -InputObject $entry -Name 'id')"
        if ($value -match '^\d+$' -and [int] $value -eq $Id) { return $entry }
    }

    $null
}

function Get-CceTestableEndpointHost {
    <#
    .SYNOPSIS
        Noms d'hote reellement testables d'une entree d'endpoints.
    .DESCRIPTION
        Les entrees publiees sont majoritairement des jokers (*.cloud.microsoft) : ils ne
        peuvent pas etre resolus. Le moteur ne fabrique aucun nom d'hote et se limite aux
        FQDN exacts, plafonnes pour borner le cout.
    #>
    [CmdletBinding()] param($Entry, [int] $Max = 2)

    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($url in @(Get-CceNetProperty -InputObject $Entry -Name 'urls')) {
        $name = "$url".Trim()
        if ($name.Length -eq 0) { continue }
        if ($name.Contains('*')) { continue }
        if ($result.Contains($name)) { continue }

        $result.Add($name)
        if ($result.Count -ge $Max) { break }
    }

    @($result)
}

function Format-CceProbeFailure {
    <#
    .SYNOPSIS
        Ligne de preuve normalisee pour une sonde reseau en echec.
    .DESCRIPTION
        Les gabarits sont recus resolus, et non construits depuis un prefixe de cle : c'est
        ce qui permet a l'outillage d'internationalisation du projet de retrouver
        statiquement chacune des cles employees par ce fichier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Probe,
        [Parameter(Mandatory)] [string] $TimeoutTemplate,
        [Parameter(Mandatory)] [string] $ErrorTemplate,
        [Parameter(Mandatory)] [string] $RefusedTemplate
    )

    $hostName = "$(Get-CceNetProperty -InputObject $Probe -Name 'HostName')"
    $port = "$(Get-CceNetProperty -InputObject $Probe -Name 'Port')"
    $timedOut = [bool] (Get-CceNetProperty -InputObject $Probe -Name 'TimedOut')
    $failure = "$(Get-CceNetProperty -InputObject $Probe -Name 'Error')"

    if ($timedOut) { return $TimeoutTemplate -f $hostName, $port }
    if ($failure.Trim().Length -gt 0) { return $ErrorTemplate -f $hostName, $port, $failure }
    $RefusedTemplate -f $hostName, $port
}

function Invoke-CceCheck68 {
    <# Connectivite Copilot : endpoints requis, WebSocket (WSS) et absence d'inspection TLS #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceLocalScope -Context $Context)) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c68.obs.manual') `
            -Evidence (T 'c68.ev.manual') `
            -Remediation (T 'c68.rem.manual')
    }

    $timeout = Get-CceNetworkTimeout -Context $Context
    $status = 'Conforme'
    $segments = [System.Collections.Generic.List[string]]::new()
    $evidence = [System.Collections.Generic.List[string]]::new()
    $remedies = [System.Collections.Generic.List[string]]::new()

    # --- 1. Liste de reference publiee par Microsoft (API publique, sans authentification).
    $endpoints = @(Get-CceOfficeEndpointList -Context $Context)

    if ($endpoints.Count -eq 0) {
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Attention'
        $evidence.Add((T 'c68.ev.catalog.ko'))
        $remedies.Add((T 'c68.rem.catalog'))
    }
    else {
        $evidence.Add(((T 'c68.ev.catalog.ok') -f $endpoints.Count))

        $entry = Get-CceOfficeEndpointEntry -Endpoints $endpoints -Id 184
        if ($null -eq $entry) {
            $evidence.Add((T 'c68.ev.entry184.missing'))
        }
        else {
            $urls = @(Get-CceNetProperty -InputObject $entry -Name 'urls') -join ', '
            $required = "$(Get-CceNetProperty -InputObject $entry -Name 'required')"
            $ports = @(Get-CceNetProperty -InputObject $entry -Name 'tcpPorts') -join ', '
            $evidence.Add(((T 'c68.ev.entry184') -f $urls, $required, $ports))
        }
    }

    # --- 2. Negociation TLS : l'emetteur du certificat revele une eventuelle re-signature.
    # Les entrees publiees etant des jokers, la sonde porte sur des hotes exacts, plafonnes
    # a quatre et surchargeables par configuration.
    $probeHosts = @(Get-CceNetworkOption -Context $Context -Name 'CopilotTlsProbeHost' `
            -Default @('m365.cloud.microsoft', 'login.microsoftonline.com', 'outlook.office.com'))

    if ($probeHosts.Count -eq 1 -and "$($probeHosts[0])".Contains(',')) {
        $probeHosts = @("$($probeHosts[0])".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    }
    $probeHosts = @($probeHosts | Select-Object -First 4)

    $reachable = 0
    $trusted = 0
    $publicIssuer = 0
    $inspected = 0

    foreach ($probeHost in $probeHosts) {
        $tls = Get-CceTlsIssuer -HostName "$probeHost" -Port 443 -TimeoutSeconds $timeout

        if (-not $tls.Success) {
            $evidence.Add((Format-CceProbeFailure -Probe $tls `
                        -TimeoutTemplate (T 'c68.ev.tcp.timeout') `
                        -ErrorTemplate (T 'c68.ev.tcp.error') `
                        -RefusedTemplate (T 'c68.ev.tcp.refused')))
            continue
        }

        $reachable++

        if ($tls.Issuer -match $script:CceNetMicrosoftIssuerPattern) {
            $trusted++
            $evidence.Add(((T 'c68.ev.tls.ok') -f $tls.HostName, $tls.Issuer))
        }
        elseif ($tls.Issuer -match $script:CceNetPublicIssuerPattern) {
            $publicIssuer++
            $evidence.Add(((T 'c68.ev.tls.public') -f $tls.HostName, $tls.Issuer))
        }
        else {
            $inspected++
            $evidence.Add(((T 'c68.ev.tls.inspect') -f $tls.HostName, $tls.Issuer))
        }
    }

    $segments.Add(((T 'c68.obs.seg.hosts') -f $reachable, $probeHosts.Count))

    if ($reachable -lt $probeHosts.Count) {
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Non conforme'
        $remedies.Add((T 'c68.rem.unreachable'))
    }

    # Une autorite publique documentee par Microsoft n'est pas un ecart : elle est signalee
    # pour la lecture, sans degrader le verdict. Seul un emetteur inconnu vaut ecart.
    if ($inspected -gt 0) {
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Non conforme'
        $segments.Add(((T 'c68.obs.seg.tls.ko') -f $inspected))
        $remedies.Add((T 'c68.rem.inspect'))
    }

    if ($trusted -gt 0) { $segments.Add(((T 'c68.obs.seg.tls.ok') -f $trusted)) }
    if ($publicIssuer -gt 0) { $segments.Add(((T 'c68.obs.seg.tls.public') -f $publicIssuer)) }

    # --- 3. WebSocket (WSS) : le protocole que les perimetres reseau bloquent le plus souvent.
    $wssUri = "$(Get-CceNetworkOption -Context $Context -Name 'CopilotWssUri' -Default 'wss://m365.cloud.microsoft/')"
    $wss = Test-CceWebSocketEndpoint -Uri $wssUri -TimeoutSeconds $timeout

    if ($wss.Connected) {
        $segments.Add((T 'c68.obs.seg.wss.ok'))
        $evidence.Add(((T 'c68.ev.wss.ok') -f $wss.Uri))
    }
    elseif ($wss.Answered) {
        $segments.Add(((T 'c68.obs.seg.wss.answered') -f $wss.HttpStatus))
        $evidence.Add(((T 'c68.ev.wss.answered') -f $wss.Uri, $wss.HttpStatus))
    }
    else {
        # Un echec de handshake ne prouve rien tant que l'hote lui-meme n'est pas joignable :
        # le verdict n'est rendu que si le port 443 du meme hote repond.
        $wssHost = ''
        try { $wssHost = "$(([uri] $wssUri).Host)" } catch { $wssHost = '' }

        $reachableHost = $false
        if ($wssHost.Length -gt 0) {
            $tcp = Test-CceTcpEndpoint -HostName $wssHost -Port 443 -TimeoutSeconds $timeout
            $reachableHost = [bool] $tcp.Success
        }

        $detail = "$($wss.Error)".Trim()

        if ($reachableHost) {
            $status = Get-CceWorstNetStatus -Current $status -Candidate 'Non conforme'
            $segments.Add((T 'c68.obs.seg.wss.ko'))
            $remedies.Add((T 'c68.rem.wss'))
        }
        else {
            $status = Get-CceWorstNetStatus -Current $status -Candidate 'Attention'
            $segments.Add((T 'c68.obs.seg.wss.unknown'))
            $remedies.Add((T 'c68.rem.wss.unknown'))
        }

        if ($detail.Length -eq 0) {
            $evidence.Add(((T 'c68.ev.wss.timeout') -f $wss.Uri))
        }
        elseif ($reachableHost) {
            $evidence.Add(((T 'c68.ev.wss.blocked') -f $wss.Uri, $detail))
        }
        else {
            $evidence.Add(((T 'c68.ev.wss.unknown') -f $wss.Uri, $detail))
        }
    }

    # --- 4. Duree de vie absolue des flux proxy : non mesurable par une sonde ponctuelle.
    $evidence.Add((T 'c68.ev.timeout.note'))
    $remedies.Add((T 'c68.rem.timeout'))

    New-CceResult -Status $status `
        -Observed ($segments -join ' | ') `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 30) `
        -Remediation ($remedies -join ' ')
}

function Invoke-CceCheck69 {
    <# Tache planifiee Office Feature Updates active et CDN des experiences connectees joignable #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceLocalScope -Context $Context)) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c69.obs.manual') `
            -Evidence (T 'c69.ev.manual') `
            -Remediation (T 'c69.rem.manual')
    }

    if (-not $IsWindows) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c69.obs.os') `
            -Evidence (T 'c69.ev.os') `
            -Remediation (T 'c69.rem.os')
    }

    if ($null -eq (Get-CceRegistryItem -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration')) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c69.obs.nooffice') `
            -Evidence (T 'c69.ev.nooffice') `
            -Remediation (T 'c69.rem.nooffice')
    }

    $timeout = Get-CceNetworkTimeout -Context $Context
    $status = 'Conforme'
    $segments = [System.Collections.Generic.List[string]]::new()
    $evidence = [System.Collections.Generic.List[string]]::new()
    $remedies = [System.Collections.Generic.List[string]]::new()

    # --- 1. Taches planifiees Office Feature Updates (processus SDXHelper.exe).
    if (-not (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c69.obs.manual') `
            -Evidence (T 'c69.ev.task.unreadable') `
            -Remediation (T 'c69.rem.manual')
    }

    $tasks = Get-CceSafe { Get-ScheduledTask -TaskPath '\Microsoft\Office\' -ErrorAction Stop } -What 'Get-ScheduledTask'
    $featureTasks = @(@($tasks) | Where-Object { $null -ne $_ -and "$($_.TaskName)" -like 'Office Feature Updates*' })

    if ($featureTasks.Count -eq 0) {
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Attention'
        $segments.Add((T 'c69.obs.warn.missing'))
        $evidence.Add(((T 'c69.ev.task.missing') -f '\Microsoft\Office\'))
        $remedies.Add((T 'c69.rem.missing'))
    }
    else {
        $disabled = @($featureTasks | Where-Object { "$($_.State)" -eq 'Disabled' })

        foreach ($task in $featureTasks) {
            $evidence.Add(((T 'c69.ev.task.line') -f "$($task.TaskName)", "$($task.State)"))
        }

        if ($disabled.Count -gt 0) {
            $status = Get-CceWorstNetStatus -Current $status -Candidate 'Non conforme'
            $segments.Add(((T 'c69.obs.ko') -f $disabled.Count, $featureTasks.Count))
            $remedies.Add((T 'c69.rem.ko'))
        }
        else {
            $segments.Add(((T 'c69.obs.ok') -f $featureTasks.Count))
        }
    }

    # --- 2. CDN des experiences connectees : entrees 46 et 47 du service d'endpoints.
    $endpoints = @(Get-CceOfficeEndpointList -Context $Context)

    if ($endpoints.Count -eq 0) {
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Attention'
        $segments.Add((T 'c69.obs.seg.cdn.unknown'))
        $evidence.Add((T 'c69.ev.catalog.ko'))
        $remedies.Add((T 'c69.rem.cdn'))
    }
    else {
        $cdnHosts = [System.Collections.Generic.List[string]]::new()

        foreach ($id in @(46, 47)) {
            $entry = Get-CceOfficeEndpointEntry -Endpoints $endpoints -Id $id
            if ($null -eq $entry) { continue }

            foreach ($name in @(Get-CceTestableEndpointHost -Entry $entry -Max 2)) {
                if (-not $cdnHosts.Contains($name)) { $cdnHosts.Add($name) }
            }
        }

        if ($cdnHosts.Count -eq 0) {
            # Les entrees 46 et 47 ne publient que des jokers : le moteur ne fabrique pas
            # de nom d'hote et declare le volet non mesurable plutot que d'inventer un verdict.
            $segments.Add((T 'c69.obs.seg.cdn.unknown'))
            $evidence.Add((T 'c69.ev.cdn.nourl'))
        }
        else {
            $failed = 0
            foreach ($name in @($cdnHosts | Select-Object -First 4)) {
                $probe = Test-CceTcpEndpoint -HostName $name -Port 443 -TimeoutSeconds $timeout
                if ($probe.Success) {
                    $evidence.Add(((T 'c69.ev.cdn.ok') -f $name))
                }
                else {
                    $failed++
                    $evidence.Add((Format-CceProbeFailure -Probe $probe `
                                -TimeoutTemplate (T 'c69.ev.tcp.timeout') `
                                -ErrorTemplate (T 'c69.ev.tcp.error') `
                                -RefusedTemplate (T 'c69.ev.tcp.refused')))
                }
            }

            $tested = [Math]::Min($cdnHosts.Count, 4)
            if ($failed -gt 0) {
                $status = Get-CceWorstNetStatus -Current $status -Candidate 'Attention'
                $segments.Add(((T 'c69.obs.seg.cdn.ko') -f $failed, $tested))
                $remedies.Add((T 'c69.rem.cdn'))
            }
            else {
                $segments.Add(((T 'c69.obs.seg.cdn.ok') -f $tested))
            }
        }
    }

    New-CceResult -Status $status `
        -Observed ($segments -join ' | ') `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 25) `
        -Remediation ($remedies -join ' ')
}

function Get-CceWebView2Runtime {
    <#
    .SYNOPSIS
        Version du runtime Microsoft Edge WebView2 installe sur le poste.
    .DESCRIPTION
        Methode de detection documentee par Microsoft : la valeur 'pv' sous la cle
        EdgeUpdate\Clients du GUID du runtime Evergreen, en machine puis en utilisateur.
    #>
    [CmdletBinding()] param()

    $clientKey = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $paths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$clientKey",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$clientKey",
        "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$clientKey"
    )

    foreach ($path in $paths) {
        $version = "$(Get-CceRegistryValue -Path $path -Name 'pv')".Trim()
        if ($version.Length -gt 0 -and $version -ne '0.0.0.0') {
            return [pscustomobject]@{ Installed = $true; Version = $version; Path = $path }
        }
    }

    [pscustomobject]@{ Installed = $false; Version = ''; Path = '' }
}

function Get-CceBrowserCookiePolicy {
    <#
    .SYNOPSIS
        Strategies de cookies d'un navigateur gere (Edge ou Chrome), pour une ruche donnee.
    .DESCRIPTION
        Trois reglages cassent la validation de licence Copilot dans Word, Excel et
        PowerPoint pour le web : BlockThirdPartyCookies a 1, DefaultCookiesSetting a 2
        (blocage total), et une entree CookiesBlockedForUrls couvrant un domaine
        Microsoft 365. Lecture seule, aucune strategie n'est modifiee.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Path)

    $item = Get-CceRegistryItem -Path $Path

    $blockedUrls = [System.Collections.Generic.List[string]]::new()
    $urlItem = Get-CceRegistryItem -Path "$Path\CookiesBlockedForUrls"
    if ($null -ne $urlItem) {
        foreach ($property in $urlItem.PSObject.Properties) {
            if ($property.Name -notmatch '^\d+$') { continue }
            $value = "$($property.Value)".Trim()
            if ($value.Length -gt 0) { $blockedUrls.Add($value) }
        }
    }

    [pscustomobject]@{
        Path        = $Path
        Present     = ($null -ne $item -or $null -ne $urlItem)
        BlockThird  = Get-CceNetProperty -InputObject $item -Name 'BlockThirdPartyCookies'
        DefaultSet  = Get-CceNetProperty -InputObject $item -Name 'DefaultCookiesSetting'
        BlockedUrls = @($blockedUrls)
    }
}

function Invoke-CceCheck70 {
    <# Runtime WebView2 present et cookies tiers autorises pour les applications Office web #>
    [CmdletBinding()] param($Context)

    if (-not (Test-CceLocalScope -Context $Context)) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c70.obs.manual') `
            -Evidence (T 'c70.ev.manual') `
            -Remediation (T 'c70.rem.manual')
    }

    if (-not $IsWindows) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c70.obs.os') `
            -Evidence (T 'c70.ev.os') `
            -Remediation (T 'c70.rem.os')
    }

    $status = 'Conforme'
    $issues = 0
    $evidence = [System.Collections.Generic.List[string]]::new()
    $remedies = [System.Collections.Generic.List[string]]::new()

    # --- 1. Runtime WebView2 : support d'affichage du volet Copilot dans les applications Office.
    $runtime = Get-CceWebView2Runtime

    if ($runtime.Installed) {
        $evidence.Add(((T 'c70.ev.webview.ok') -f $runtime.Version, $runtime.Path))
    }
    else {
        $issues++
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Non conforme'
        $evidence.Add((T 'c70.ev.webview.missing'))
        $remedies.Add((T 'c70.rem.webview'))
    }

    # --- 2. Strategies de cookies : quatre emplacements au plus, machine et utilisateur.
    $policyPaths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
        'HKCU:\SOFTWARE\Policies\Microsoft\Edge',
        'HKLM:\SOFTWARE\Policies\Google\Chrome',
        'HKCU:\SOFTWARE\Policies\Google\Chrome'
    )

    $scanned = 0
    $cookieIssue = $false
    $cookieWarning = $false

    foreach ($path in $policyPaths) {
        $policy = Get-CceBrowserCookiePolicy -Path $path
        if (-not $policy.Present) { continue }
        $scanned++

        if ($null -ne $policy.BlockThird -and "$($policy.BlockThird)" -eq '1') {
            $cookieIssue = $true
            $evidence.Add(((T 'c70.ev.cookie.block') -f $policy.Path, "$($policy.BlockThird)"))
        }

        if ($null -ne $policy.DefaultSet -and "$($policy.DefaultSet)" -eq '2') {
            $cookieIssue = $true
            $evidence.Add(((T 'c70.ev.cookie.default') -f $policy.Path, "$($policy.DefaultSet)"))
        }

        if ($policy.BlockedUrls.Count -gt 0) {
            $m365 = @($policy.BlockedUrls | Where-Object { $_ -match $script:CceNetM365CookiePattern })
            if ($m365.Count -gt 0) {
                $cookieIssue = $true
                $evidence.Add(((T 'c70.ev.cookie.urls') -f $policy.Path, ($m365 -join ', ')))
            }
            else {
                $cookieWarning = $true
                $evidence.Add(((T 'c70.ev.cookie.urls.other') -f $policy.Path, (@($policy.BlockedUrls | Select-Object -First 10) -join ', ')))
            }
        }
    }

    if ($scanned -eq 0) { $evidence.Add((T 'c70.ev.policy.none')) }

    if ($cookieIssue) {
        $issues++
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Non conforme'
        $remedies.Add((T 'c70.rem.cookies'))
    }
    elseif ($cookieWarning) {
        $status = Get-CceWorstNetStatus -Current $status -Candidate 'Attention'
        $remedies.Add((T 'c70.rem.cookies.other'))
    }
    else {
        $evidence.Add(((T 'c70.ev.cookie.ok') -f $scanned))
    }

    $observed = switch ($status) {
        'Non conforme' { (T 'c70.obs.ko') -f $issues }
        'Attention'    { T 'c70.obs.warn' }
        default        { T 'c70.obs.ok' }
    }

    New-CceResult -Status $status `
        -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 25) `
        -Remediation ($remedies -join ' ')
}

function Get-CceDeviceBasedLicensingSku {
    <#
    .SYNOPSIS
        Abonnements Microsoft 365 Apps en licence d'appareil detenus par le tenant.
    .DESCRIPTION
        Le moteur n'invente aucun SkuPartNumber : il retient les abonnements dont le nom
        porte a la fois la marque d'une licence d'appareil et celle d'une suite Office.
        La presence d'un tel abonnement n'est pas un ecart en soi ; c'est un signal a
        croiser avec la population licenciee Copilot.
    #>
    [CmdletBinding()] param($Context)

    if ($null -eq $Context) { return @() }
    if (-not $Context.Services.Graph) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($sku in @(Get-CceSubscribedSku -Context $Context)) {
        $name = "$(Get-CceNetProperty -InputObject $sku -Name 'SkuPartNumber')"
        if ($name.Length -eq 0) { continue }
        if ($name -notmatch '(?i)device') { continue }
        if ($name -notmatch '(?i)office|apps|proplus|m365edu|o365') { continue }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }

    @($names)
}

function Invoke-CceCheck71 {
    <# Aucune activation par licence d'appareil (device-based licensing) sur les postes Copilot #>
    [CmdletBinding()] param($Context)

    # Volet tenant : lisible sans le poste, il enrichit meme le resultat 'Manuel'.
    $graph = $false
    if ($null -ne $Context) { $graph = [bool] $Context.Services.Graph }

    $deviceSkus = @(Get-CceDeviceBasedLicensingSku -Context $Context)
    $tenantEvidence = if (-not $graph) {
        T 'c71.ev.tenant.skipped'
    }
    elseif ($deviceSkus.Count -gt 0) {
        (T 'c71.ev.tenant.sku') -f ($deviceSkus -join ', ')
    }
    else {
        T 'c71.ev.tenant.none'
    }

    if (-not (Test-CceLocalScope -Context $Context)) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c71.obs.manual') `
            -Evidence (@((T 'c71.ev.manual'), $tenantEvidence) | ConvertTo-CceText) `
            -Remediation (T 'c71.rem.manual')
    }

    if (-not $IsWindows) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c71.obs.os') `
            -Evidence (@((T 'c71.ev.os'), $tenantEvidence) | ConvertTo-CceText) `
            -Remediation (T 'c71.rem.os')
    }

    $configuration = Get-CceRegistryItem -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if ($null -eq $configuration) {
        return New-CceResult -Status 'Manuel' `
            -Observed (T 'c71.obs.nooffice') `
            -Evidence (@((T 'c71.ev.nooffice'), $tenantEvidence) | ConvertTo-CceText) `
            -Remediation (T 'c71.rem.nooffice')
    }

    $status = 'Conforme'
    $evidence = [System.Collections.Generic.List[string]]::new()
    $remedies = [System.Collections.Generic.List[string]]::new()
    $active = [System.Collections.Generic.List[string]]::new()

    # Le nom de la valeur est prefixe par le produit (O365ProPlusRetail, O365BusinessRetail,
    # declinaisons education) : le moteur balaye toutes les valeurs correspondantes.
    $properties = @($configuration.PSObject.Properties | Where-Object { $_.Name -like '*DeviceBasedLicensing' })

    if ($properties.Count -eq 0) {
        $evidence.Add((T 'c71.ev.local.absent'))
    }
    else {
        foreach ($property in $properties) {
            $value = "$($property.Value)".Trim()
            if ($value -eq '1') {
                $active.Add($property.Name)
                $evidence.Add(((T 'c71.ev.local.on') -f $property.Name, $value))
            }
            else {
                $evidence.Add(((T 'c71.ev.local.off') -f $property.Name, $value))
            }
        }
    }

    $evidence.Add($tenantEvidence)

    if ($active.Count -gt 0) {
        $status = 'Non conforme'
        $observed = (T 'c71.obs.ko') -f ($active -join ', ')
        $remedies.Add((T 'c71.rem.ko'))
    }
    elseif ($deviceSkus.Count -gt 0) {
        $status = 'Attention'
        $observed = (T 'c71.obs.warn') -f ($deviceSkus -join ', ')
        $remedies.Add((T 'c71.rem.sku'))
    }
    else {
        $observed = T 'c71.obs.ok'
    }

    New-CceResult -Status $status `
        -Observed $observed `
        -Evidence ($evidence | ConvertTo-CceText -MaxItems 20) `
        -Remediation ($remedies -join ' ')
}
